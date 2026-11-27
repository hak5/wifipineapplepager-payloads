"""The Pager's buzzer, vibration motor and button lights, through sysfs."""

from pathlib import Path

LEDS = Path("/sys/class/leds")
VIBRATOR = Path("/sys/class/gpio/vibrator/value")
DPAD = ("up", "down", "left", "right")


def write(path, value):
    try:
        Path(path).write_text(str(value))
        return True
    except OSError:
        return False


class Buzzer:
    def __init__(self, root=LEDS):
        self.frequency = Path(root) / "buzzer" / "frequency"
        self.level = Path(root) / "buzzer" / "brightness"

    def present(self):
        return self.level.exists()

    def on(self, hz, level=255):
        write(self.frequency, max(20, int(hz)))
        write(self.level, max(0, min(255, int(level))))

    def off(self):
        write(self.level, 0)


class Vibrator:
    def __init__(self, path=VIBRATOR):
        self.path = Path(path)

    def present(self):
        return self.path.exists()

    def set(self, on):
        write(self.path, 1 if on else 0)


class Lights:
    def __init__(self, root=LEDS):
        self.root = Path(root)

    def dpad(self, color, sides=DPAD):
        r, g, b = color
        for side in sides:
            for name, value in (("red", r), ("green", g), ("blue", b)):
                write(self.root / ("%s-led-%s" % (side, name)) / "brightness", value)

    def button(self, name, on):
        write(self.root / ("%s-button-led" % name) / "brightness", 255 if on else 0)

    def off(self):
        self.dpad((0, 0, 0))
        self.button("a", False)
        self.button("b", False)
