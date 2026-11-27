"""Keeps the Pager's screen lit while Quartermaster runs, or turns it off after the timeout chosen in Settings.

Any button lights it again, and that press only wakes the screen."""

import time

TIMEOUTS = [(0, "Never"), (30, "30 s"), (60, "1 min"), (120, "2 min"), (300, "5 min"), (600, "10 min")]
SETTING = ("screen_timeout", "Screen timeout", TIMEOUTS,
           "Never keeps the screen lit. Otherwise it turns off when no button is pressed, and any button wakes it.")


class ScreenKeeper:
    def __init__(self, backlight, timeout, clock=time.monotonic):
        self.backlight, self.timeout, self.clock = backlight, timeout, clock
        self.start = backlight.level()
        top = backlight.top
        self.bright = self.start if self.start and self.start * 4 >= top else top
        self.last = clock()
        self.asleep = False
        self.done = False

    def touch(self):
        self.last = self.clock()
        if not self.asleep:
            return False
        self.asleep = False
        self.backlight.set(self.bright)
        return True

    def tick(self):
        if self.done or not self.backlight.present():
            return
        seconds = self.timeout() or 0
        if seconds and not self.asleep and self.clock() - self.last >= seconds:
            self.asleep = True
            self.backlight.set(0)
        elif not self.asleep:
            level = self.backlight.level()
            if level is not None and level < self.bright:
                self.backlight.set(self.bright)

    def run(self, stopped, every=0.5):
        while not stopped.wait(every):
            try:
                self.tick()
            except Exception:
                pass

    def restore(self):
        self.done = True
        self.backlight.set(self.start if self.start else self.bright)
