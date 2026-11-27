"""Display and controls on Waveshare's 1.44-inch and 1.3-inch Raspberry Pi LCD HATs."""

import select
import socket
from contextlib import ExitStack
from functools import partial

from .keys import EvdevInput, Key


# BCM numbers. Both HATs have the same joystick and three active-low buttons.
BUTTONS = {6: "UP", 19: "DOWN", 5: "LEFT", 26: "RIGHT", 13: "ENTER",
           21: "ENTER", 20: "ESC", 16: "TAB"}


class HatDisplay:
    def __init__(self, profile):
        if profile not in ("st7735-128", "st7789-240"):
            raise ValueError("Unknown Waveshare display profile: %s" % profile)
        self.profile = profile
        try:
            import RPi.GPIO as gpio
            from spidev import SpiDev
            from luma.core.interface.serial import spi
            from luma.lcd.device import st7735, st7789

            with ExitStack() as opened:
                self._resources = opened
                gpio.setmode(gpio.BCM)
                # Scope cleanup to the display; the button reader owns different pins.
                opened.callback(gpio.cleanup, [25, 27, 24])
                bus = SpiDev()
                opened.callback(bus.close)
                small = profile == "st7735-128"
                serial = spi(spi=bus, gpio=gpio, port=0, device=0, gpio_DC=25, gpio_RST=27,
                             reset_hold_time=0.1, reset_release_time=0.12,
                             bus_speed_hz=8000000 if small else 32000000)
                controller = st7735 if small else st7789
                side = 128 if small else 240
                options = dict(width=side, height=side, gpio=gpio, gpio_LIGHT=24, active_low=False)
                if small:
                    # With the joystick at the left the ST7735S glass starts at column 1, row 2.
                    options.update(h_offset=1, v_offset=2, bgr=True)

                class Panel(controller):
                    # Luma registers this hook before initialization finishes. Use the same
                    # idempotent cleanup as the launcher, even if the controller fails to start.
                    cleanup = staticmethod(self.close)

                self.panel = Panel(serial, **options)
                opened.callback(self.panel.backlight, False)
                self.width, self.height = self.panel.size
                self._resources = opened.pop_all()
        except Exception as exc:
            raise OSError("Cannot open %s on SPI0 CE0: %s" % (profile, exc)) from exc

    def show(self, img):
        if img.size != (self.width, self.height):
            raise ValueError("Expected a native %dx%d frame" % (self.width, self.height))
        self.panel.display(img if img.mode == "RGB" else img.convert("RGB"))

    def close(self):
        self._resources.close()


class HatInput:
    """Deliver button presses even while a frame is being drawn, alongside USB keyboard events."""

    def __init__(self):
        try:
            from gpiozero import Button

            with ExitStack() as opened:
                self.keyboard = EvdevInput()
                opened.callback(self.keyboard.close)
                self._read, self._write = socket.socketpair()
                opened.callback(self._read.close)
                opened.callback(self._write.close)
                self._read.setblocking(False)
                self._write.setblocking(False)
                for pin in BUTTONS:
                    button = Button(pin, pull_up=True, bounce_time=0.04)
                    opened.callback(button.close)
                    button.when_pressed = partial(self._pressed, pin)
                self._resources = opened.pop_all()
        except Exception as exc:
            raise OSError("Cannot open the Waveshare joystick and buttons: %s" % exc) from exc

    def _pressed(self, pin):
        try:
            self._write.send(bytes([pin]))
        except OSError:
            # Input can be discarded when the socket is full or the app is closing.
            pass

    def _read_buttons(self):
        try:
            return self._read.recv(4096)
        except BlockingIOError:
            return b""

    def poll(self, timeout):
        ready, _, _ = select.select([self._read, *self.keyboard.devices], [], [], timeout)
        keys = []
        if self._read in ready:
            ready.remove(self._read)
            keys = [Key(BUTTONS[pin]) for pin in self._read_buttons()]
        if ready:
            keys.extend(self.keyboard.poll(0))
        return keys

    def flush(self):
        while self._read_buttons():
            pass
        self.keyboard.flush()

    def close(self):
        self._resources.close()
