"""MeshToad, MeshStick, the Glytch Mesh Mod and other CH341 LoRa sticks (USB 1a86:5512 with an SX1262).

The CH341 turns USB into SPI and a few pins. The pins are Meshtastic's for these sticks: chip select on D0, BUSY on
D4 and DIO1 on D6, with reset and the receive switch on D1 and D2 (most sticks reset on D2, the uMesh on D1). Both
are held high, so the receive switch is on, and each is tried as reset in turn. The SX1262 is then driven by the same
receive-only code as the Cap LoRa-1262.
"""

import errno
from contextlib import ExitStack
import time

from quartermaster import lora

from . import usbfs

VENDOR, PRODUCT = "1a86", "5512"
OUT, IN = 0x02, 0x82
PACKET = 32
SPI_STREAM, UIO_STREAM, I2C_STREAM, STATUS = 0xA8, 0xAB, 0xAA, 0xA0
UIO_OUT, UIO_DIR, UIO_END = 0x80, 0x40, 0x20
I2C_SET, I2C_END = 0x60, 0x00
CS, BUSY_PIN, IRQ_PIN = 0, 4, 6
DIRECTION = 0b101111
LAYOUTS = ((2, 1), (1, 2))
REVERSED = bytes(int("{:08b}".format(n)[::-1], 2) for n in range(256))


def sticks(root=usbfs.SYS_USB):
    return usbfs.find(VENDOR, PRODUCT, root)


class Ch341:
    """SPI mode 0 and the D0 to D7 pins of one CH341."""

    def __init__(self, usb):
        self.usb = usb
        self.level = 0b100111

    @classmethod
    def open(cls, node, opener=usbfs.Device):
        chip = cls(opener(node))
        chip.usb.write(OUT, bytes((I2C_STREAM, I2C_SET | 1, I2C_END)))
        chip.pins()
        return chip

    def pins(self):
        self.usb.write(OUT, bytes((UIO_STREAM, UIO_OUT | (self.level & 0x3F), UIO_DIR | DIRECTION, UIO_END)))

    def set(self, pin, high):
        self.level = self.level | (1 << pin) if high else self.level & ~(1 << pin)
        self.pins()

    def inputs(self):
        self.usb.write(OUT, bytes((STATUS,)))
        status = self.usb.read(IN, PACKET)
        if len(status) < 1:
            raise OSError(errno.EIO, "no pin status")
        return status[0]

    def high(self, pin):
        return bool(self.inputs() >> pin & 1)

    def xfer2(self, data):
        data = bytes(data)
        self.set(CS, False)
        out = bytearray()
        try:
            for start in range(0, len(data), PACKET - 1):
                chunk = data[start:start + PACKET - 1]
                self.usb.write(OUT, bytes((SPI_STREAM,)) + chunk.translate(REVERSED))
                got = b""
                while len(got) < len(chunk):
                    part = self.usb.read(IN, PACKET)
                    if not part:
                        raise OSError(errno.EIO, "short SPI read")
                    got += part
                out += got[:len(chunk)].translate(REVERSED)
        finally:
            self.set(CS, True)
        return list(out)

    def close(self):
        self.usb.close()


class _Pins:
    def __init__(self, chip, reset):
        self.chip, self.reset = chip, reset

    def active(self, pin):
        return self.chip.high({lora.BUSY: BUSY_PIN, lora.IRQ: IRQ_PIN}[pin])

    def pulse_reset(self, stack):
        self.chip.set(self.reset, False)
        time.sleep(0.002)
        self.chip.set(self.reset, True)


class Ch341Radio(lora.CapRadio):
    """The stick's SX1262 in continuous receive, with the Cap's commands."""

    def __init__(self, node, opener=usbfs.Device):
        super().__init__(rails=None)
        self.node, self.opener = node, opener

    def open(self, profile=None):
        if self._resources is not None:
            return self
        with ExitStack() as stack:
            try:
                chip = Ch341.open(self.node, self.opener)
            except PermissionError:
                raise lora.RadioError(lora.DENIED) from None
            except OSError as exc:
                raise lora.RadioError(lora.BUSY_ELSEWHERE if exc.errno == errno.EBUSY else lora.ABSENT) from None
            stack.callback(chip.close)
            self._spi = chip
            for reset, _ in LAYOUTS:
                self._gpio = _Pins(chip, reset)
                try:
                    self._wake()
                    break
                except (lora.RadioError, OSError):
                    continue
            else:
                raise lora.RadioError(lora.ABSENT)
            try:
                stack.callback(self._command, 0x80, b"\x00")
                if profile is not None:
                    self._tune(profile)
            except OSError:
                raise lora.RadioError(lora.ABSENT) from None
            self._resources = stack.pop_all()
        return self

    def _wake(self):
        with ExitStack() as scratch:
            self._gpio.pulse_reset(scratch)
        time.sleep(0.010)
        self._command(0x80, b"\x00")
        self._command(0x97, b"\x02\x00\x01\x40")
        self._command(0x89, b"\x7f")
        time.sleep(0.005)
        self._command(0x96, b"\x01")
        self._command(0x8A, b"\x01")
        if self._command(0x11, read=1) != b"\x01":
            raise lora.RadioError(lora.ABSENT)
        self._command(0x9D, b"\x01")
        self._command(0x8F, b"\x00\x00")
