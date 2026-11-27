"""Keyboard input from Linux evdev, mapped to logical keys.

The CardputerZero's own keyboard applies Shift, Sym and Fn in its driver: Fn sends the
real arrow codes and Sym sends a code of its own for every symbol. Any other keyboard is
read as a US layout. Screens that are not reading text also take F, X, Z and C as the
arrows printed on them, without Fn.
"""

import fcntl
import os
from pathlib import Path
import re
import select
import struct

EVENT = struct.Struct("llHHi")
EV_KEY = 1
SHIFTS = (42, 54)
CAPS_LOCK = 58
# linux/input.h: EVIOCGKEY and EVIOCGLED for 96 bytes, and LED_CAPSL
KEYS_DOWN, LIGHTS_ON, CAPS_LIGHT = 0x80604518, 0x80604519, 1
INTERNAL = "/dev/input/cardputer-zero-internal"
KEYMAP = "/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map"

# linux/input-event-codes.h
CODES = {
    1: "ESC", 14: "BACKSPACE", 15: "TAB", 28: "ENTER", 57: "SPACE", 96: "ENTER",
    103: "UP", 108: "DOWN", 105: "LEFT", 106: "RIGHT", 102: "HOME", 107: "END",
    104: "PAGEUP", 109: "PAGEDOWN", 111: "DELETE",
}
CHARS = {
    2: "1!", 3: "2@", 4: "3#", 5: "4$", 6: "5%", 7: "6^", 8: "7&", 9: "8*", 10: "9(", 11: "0)",
    12: "-_", 13: "=+", 16: "qQ", 17: "wW", 18: "eE", 19: "rR", 20: "tT", 21: "yY", 22: "uU",
    23: "iI", 24: "oO", 25: "pP", 26: "[{", 27: "]}", 30: "aA", 31: "sS", 32: "dD", 33: "fF",
    34: "gG", 35: "hH", 36: "jJ", 37: "kK", 38: "lL", 39: ";:", 40: "'\"", 41: "`~", 43: "\\|",
    44: "zZ", 45: "xX", 46: "cC", 47: "vV", 48: "bB", 49: "nN", 50: "mM", 51: ",<", 52: ".>",
    53: "/?",
}
# What Sym sends on the built-in keyboard, as KEYMAP lists it. Several of these codes mean
# another character on a US keyboard.
BUILT_IN_SYMBOLS = {
    26: "!", 27: "@", 39: "#", 40: "$", 41: "%", 43: "^", 51: "&", 52: "*", 53: "(", 94: ")",
    55: "~", 69: "`", 70: "_", 71: "-", 72: "+", 73: "=", 74: "[", 75: "]", 76: "{", 77: "}",
    79: ";", 80: ":", 81: "'", 82: '"', 83: "<", 85: ">", 86: "\\", 89: "|",
    90: ",", 91: ".", 92: "/", 93: "?",
}
# The codes of older system images.
BUILT_IN_SYMBOLS.update({
    183: "!", 184: "@", 185: "#", 186: "$", 187: "%", 188: "^", 189: "&", 190: "*", 191: "(", 192: ")",
    193: "~", 194: "`", 195: "+", 196: "-", 197: "/", 198: "\\", 199: "{", 200: "}", 201: "[", 202: "]",
    209: "=", 210: ":", 211: ";", 212: "_", 213: "?", 214: "<", 215: ">", 216: "'", 217: '"',
    231: ",", 232: ".", 233: "|",
})
KEYSYMS = {
    "exclam": "!", "at": "@", "numbersign": "#", "dollar": "$", "percent": "%", "asciicircum": "^",
    "ampersand": "&", "asterisk": "*", "parenleft": "(", "parenright": ")", "asciitilde": "~", "grave": "`",
    "underscore": "_", "minus": "-", "plus": "+", "equal": "=", "bracketleft": "[", "bracketright": "]",
    "braceleft": "{", "braceright": "}", "semicolon": ";", "colon": ":", "apostrophe": "'", "quotedbl": '"',
    "less": "<", "greater": ">", "backslash": "\\", "bar": "|", "comma": ",", "period": ".", "slash": "/",
    "question": "?",
}
ARROWS = {"f": "UP", "x": "DOWN", "z": "LEFT", "c": "RIGHT"}


class Key:
    """A key press: `name` is logical (UP, ENTER, A...), `char` is typed text."""

    __slots__ = ("name", "char", "repeat")

    def __init__(self, name, char="", repeat=False):
        self.name, self.char, self.repeat = name, char, repeat

    def __eq__(self, other):
        return self.name == other if isinstance(other, str) else NotImplemented

    def __hash__(self):
        return hash(self.name)

    def __repr__(self):
        return "Key(%r)" % self.name


def navigation(key):
    """F, X, Z and C as arrows, for a screen that is not reading text."""
    name = ARROWS.get(key.char.lower())
    return Key(name, repeat=key.repeat) if name else key


def find_keyboards():
    """Input devices whose key bitmap includes letters, from /proc/bus/input/devices."""
    paths = []
    try:
        blocks = Path("/proc/bus/input/devices").read_text(errors="replace").split("\n\n")
    except OSError:
        return paths
    for block in blocks:
        handlers = next((line for line in block.splitlines() if line.startswith("H: Handlers=")), "")
        keybits = next((line for line in block.splitlines() if line.startswith("B: KEY=")), "")
        events = [h for h in handlers.split("=", 1)[-1].split() if h.startswith("event")]
        if not events or not keybits:
            continue
        words = keybits.split("=", 1)[1].split()
        bits = int("".join(w.rjust(16, "0") for w in words), 16) if words else 0
        if bits >> 30 & 1 and bits >> 16 & 1:  # KEY_A and KEY_Q
            paths.append("/dev/input/" + events[0])
    return paths


def built_in_symbols(keymap=None):
    """BUILT_IN_SYMBOLS, corrected by the keymap file the system installs with the keyboard driver.

    An early driver sent the code of a right Shift key for ")". The left one is the keyboard's own Shift.
    """
    symbols = dict(BUILT_IN_SYMBOLS)
    try:
        text = Path(keymap or KEYMAP).read_text(errors="replace")
    except OSError:
        return symbols
    for code, keysym in re.findall(r"^[ \t]*keycode[ \t]+(\d{1,3})[ \t]*=[ \t]*(\w+)", text, re.MULTILINE):
        if keysym in KEYSYMS and int(code) != SHIFTS[0] and not CHARS.get(int(code), "!")[0].isalnum():
            symbols[int(code)] = KEYSYMS[keysym]
    return symbols


def is_built_in(path, sysfs="/sys/class/input"):
    """Whether `path` is the CardputerZero's own keyboard."""
    device = os.path.realpath(path)
    if device == os.path.realpath(INTERNAL):
        return True
    try:
        name = Path(sysfs, os.path.basename(device), "device", "name").read_text(errors="replace")
    except OSError:
        return False
    return name.startswith("tca8418")


def state(fd, request):
    """The keys held down or the lights lit on a keyboard right now, one bit each."""
    try:
        return int.from_bytes(fcntl.ioctl(fd, request, bytes(96)), "little")
    except OSError:
        return 0


class EvdevInput:
    def __init__(self, paths=None):
        self.devices = {}
        self.symbols = built_in_symbols()
        for path in paths or find_keyboards():
            try:
                self.devices[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = is_built_in(path)
            except OSError:
                continue
        self.look()

    def look(self):
        """Take Shift and Caps Lock from the keyboards as they are now.

        What happened before a keyboard was opened is never reported: a Shift that was locked in the
        launcher, or a Caps Lock that was already on. A keyboard that is unplugged takes its part along.
        """
        self.shift = self.caps = False
        for fd, built_in in self.devices.items():
            down = state(fd, KEYS_DOWN)
            self.shift |= any(down >> code & 1 for code in SHIFTS if not (built_in and code in self.symbols))
            self.caps |= bool(state(fd, LIGHTS_ON) >> CAPS_LIGHT & 1)

    def poll(self, timeout):
        """Return a list of Keys pressed within `timeout` seconds."""
        if not self.devices:
            select.select([], [], [], timeout)
            return []
        ready, _, _ = select.select(list(self.devices), [], [], timeout)
        keys = []
        for fd in ready:
            try:
                data = os.read(fd, EVENT.size * 32)
            except BlockingIOError:
                continue
            except OSError:
                data = b""
            if not data:
                self._drop(fd)
                continue
            for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _, _, kind, code, value = EVENT.unpack_from(data, offset)
                if kind != EV_KEY:
                    continue
                key = self.translate(code, value, self.devices[fd])
                if key is not None:
                    keys.append(key)
        return keys

    def flush(self):
        """Forget what was typed while the app could not listen."""
        for fd in list(self.devices):
            try:
                while os.read(fd, EVENT.size * 32):
                    pass
            except OSError:
                pass
        self.look()

    def translate(self, code, value, built_in=False):
        if code in SHIFTS and not (built_in and code in self.symbols):
            self.shift = value != 0
            return None
        if value == 0:
            return None
        repeat = value == 2
        if code == CAPS_LOCK:
            self.caps ^= not repeat
            return None
        name = CODES.get(code)
        if name:
            return Key(name, " " if name == "SPACE" else "", repeat)
        if built_in and code in self.symbols:
            char = self.symbols[code]
            return Key(char, char, repeat)
        if code in CHARS:
            plain, shifted = CHARS[code]
            char = shifted if self.shift != (self.caps and plain.isalpha()) else plain
            return Key(char.upper() if char.isalpha() else char, char, repeat)
        return None

    def _drop(self, fd):
        """An unplugged keyboard stays readable for ever: without this the app would spin on it."""
        del self.devices[fd]
        try:
            os.close(fd)
        except OSError:
            pass
        self.look()

    def close(self):
        for fd in list(self.devices):
            self._drop(fd)


class ScriptedInput:
    """Feeds a fixed key sequence; used by tests and the screenshot renderer."""

    def __init__(self, names=()):
        self.queue = []
        self.push(*names)

    def push(self, *names):
        self.queue.extend(Key(n, n if len(n) == 1 else (" " if n == "SPACE" else "")) for n in names)

    def type(self, text):
        self.queue.extend(Key(ch.upper() if ch.isalpha() else ch, ch) for ch in text)

    def poll(self, timeout):
        return [self.queue.pop(0)] if self.queue else []

    def close(self):
        pass
