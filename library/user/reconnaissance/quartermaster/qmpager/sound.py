"""Quartermaster's alert tones on the Pager's buzzer, with the vibration motor beside them.

The tones are the same sweeps the CardputerZero plays through its speaker, stepped through
the buzzer's frequency every few milliseconds. The queue and its rules are Quartermaster's own.
"""

import threading
import time

from quartermaster import tones

from .device import Buzzer, Vibrator

STEP_MS = 12
LEVELS = {"high": 255, "medium": 150, "low": 70}
BUZZ = {"siren": (400, 200, 400), "yelp": (150, 100, 150), "chirp": (120,), "shutter": (60,),
        "ping": (200,), "blip": (80,), "beep": (60,)}


def steps(tone):
    for f0, f1, ms, kind, level, curve in tones.TONES[tone][1]:
        count = max(1, int(ms // STEP_MS))
        for i in range(count):
            t = i / count
            if not f0 or not f1:
                hz = 0 if kind != "noise" else 3000 + (i * 7919) % 2000
            elif curve == "exp":
                hz = f0 * (f1 / f0) ** t
            else:
                hz = f0 + (f1 - f0) * t
            yield hz, level, ms / count


class Run:
    def __init__(self, tone, volume, buzzer, vibrator, vibrate, sleep=time.sleep):
        self.tone, self.volume = tone, volume
        self.buzzer, self.vibrator, self.vibrate = buzzer, vibrator, vibrate
        self.sleep = sleep
        self.stopping = False
        self.code = None
        self.thread = threading.Thread(target=self.run, daemon=True, name="buzzer")
        self.thread.start()

    def run(self):
        peak = LEVELS.get(self.volume, LEVELS["medium"])
        buzz = list(BUZZ.get(self.tone, ())) if self.vibrate else []
        buzz_left, buzz_on = (buzz.pop(0), True) if buzz else (0, False)
        if buzz_on:
            self.vibrator.set(True)
        try:
            for hz, level, ms in steps(self.tone):
                if self.stopping:
                    break
                if hz and level:
                    self.buzzer.on(hz, peak * level)
                else:
                    self.buzzer.off()
                self.sleep(ms / 1000)
                if buzz_left > 0:
                    buzz_left -= ms
                    if buzz_left <= 0:
                        buzz_on = not buzz_on
                        self.vibrator.set(buzz_on)
                        buzz_left = buzz.pop(0) if buzz else 0
        finally:
            self.buzzer.off()
            self.vibrator.set(False)
            self.code = 0

    def poll(self):
        return self.code

    def terminate(self):
        self.stopping = True


class BuzzerPlayer(tones.Player):
    """tones.Player with the buzzer in place of aplay."""

    def __init__(self, buzzer=None, vibrator=None, vibrate=lambda: True, clock=time.monotonic, sleep=time.sleep):
        self.buzzer = buzzer or Buzzer()
        self.vibrator = vibrator or Vibrator()
        self.vibrate = vibrate
        self.sleep = sleep
        super().__init__(popen=self.spawn, clock=clock)
        self.command = "buzzer" if self.buzzer.present() else None

    def path(self, tone, volume):
        return "%s:%s" % (tone, volume)

    def spawn(self, argv, **_):
        tone, volume = argv[-1].split(":")
        return Run(tone, volume, self.buzzer, self.vibrator, bool(self.vibrate()), self.sleep)
