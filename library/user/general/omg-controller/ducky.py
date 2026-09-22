"""Strict, bounded compiler for common O.MG v3 DuckyScript (US layout).

Unsupported syntax is an error, never silently omitted. This is not a complete
implementation of O.MG's browser compiler. See README for the supported subset.
"""
import binascii
import re


class CompileError(ValueError):
    pass


KEYS = {"ENTER": 0x28, "RETURN": 0x28, "ESC": 0x29, "ESCAPE": 0x29,
        "BACKSPACE": 0x2a, "TAB": 0x2b, "SPACE": 0x2c, "CAPSLOCK": 0x39,
        "PRINTSCREEN": 0x46, "SCROLLLOCK": 0x47, "PAUSE": 0x48,
        "INSERT": 0x49, "HOME": 0x4a, "PAGEUP": 0x4b, "DELETE": 0x4c,
        "END": 0x4d, "PAGEDOWN": 0x4e, "RIGHT": 0x4f, "RIGHTARROW": 0x4f,
        "LEFT": 0x50, "LEFTARROW": 0x50, "DOWN": 0x51, "DOWNARROW": 0x51,
        "UP": 0x52, "UPARROW": 0x52, "NUMLOCK": 0x53}
KEYS.update({"F%d" % n: 0x39 + n for n in range(1, 13)})
MODS = {"CTRL": 1, "CONTROL": 1, "SHIFT": 2, "ALT": 4, "OPTION": 4,
        "GUI": 8, "WINDOWS": 8, "WIN": 8, "COMMAND": 8, "CMD": 8,
        "RCTRL": 16, "RSHIFT": 32, "RALT": 64, "RGUI": 128}
MAX_HEX = 1008 * 255


def character(char):
    if "a" <= char.lower() <= "z":
        return (2 if char.isupper() else 0), ord(char.lower()) - 93
    if char in "1234567890":
        return 0, 0x1e + "1234567890".index(char)
    if char in "!@#$%^&*()":
        return 2, 0x1e + "!@#$%^&*()".index(char)
    plain = "-=[]\\;\'`,./"
    shifted = '_+{}|:"~<>?'
    codes = [0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38]
    if char in plain:
        return 0, codes[plain.index(char)]
    if char in shifted:
        return 2, codes[shifted.index(char)]
    if char == " ":
        return 0, 0x2c
    if char == "\t":
        return 0, 0x2b
    raise CompileError("Unsupported US character %r" % char)


def delay(arg):
    if not re.fullmatch(r"[0-9]+", arg) or int(arg) > 86400000:
        raise CompileError("Delay must be 0..86400000 milliseconds")
    ticks = int(arg) // 10
    return "1DFFFF" * (ticks // 65535) + "1D%04X" % (ticks % 65535)


def compile_source(source):
    output = []
    size = 0
    default_delay = ""
    char_delay = ""
    block = None

    def emit(code):
        nonlocal size
        size += len(code)
        if size > MAX_HEX:
            raise CompileError("Compiled payload exceeds 255 segments")
        output.append(code)

    def instruction(cmd, args):
        if cmd in ("STRING", "STRINGLN"):
            result = "".join(char_delay + "01%02X%02X" % character(ch) for ch in args)
            return result + ("010028" if cmd == "STRINGLN" else "")
        if cmd == "DELAY":
            return delay(args)
        if cmd in ("USB", "JIGGLER"):
            if args.upper() not in ("ON", "OFF", "0", "1"):
                raise CompileError(cmd + " requires ON or OFF")
            return ("10" if cmd == "USB" else "11") + "000" + ("1" if args.upper() in ("ON", "1") else "0")
        if cmd in ("USB_RESET", "CAPSLOCK_DISABLE") and not args:
            return {"USB_RESET": "1B2700", "CAPSLOCK_DISABLE": "350000"}[cmd]
        tokens = [cmd] + args.split()
        mods, key = 0, None
        for token in tokens:
            upper = token.upper()
            if upper in MODS:
                mods |= MODS[upper]
            elif key is not None:
                raise CompileError("Only one non-modifier key per chord is supported")
            elif upper in KEYS:
                key = KEYS[upper]
            elif len(token) == 1:
                modifier, key = character(token.lower())
                mods |= modifier
            else:
                raise CompileError("Unsupported command/key: " + token)
        if key is None and not mods:
            raise CompileError("Empty key chord")
        return "01%02X%02X" % (mods, key or 0)

    for number, original in enumerate(source.splitlines(), 1):
        try:
            line = original.lstrip()
            if block:
                if line.strip().upper() == "END_" + block:
                    block = None
                    continue
                if block == "REM":
                    continue
                emit(instruction(block, original) + default_delay)
                continue
            if not line.strip():
                continue
            match = re.match(r"([^\s]+)(?:[ \t](.*))?$", line)
            if not match:
                raise CompileError("Invalid line")
            cmd, args = match[1].upper(), match[2] or ""
            if cmd == "REM":
                continue
            if cmd in ("REM_BLOCK", "STRING_BLOCK", "STRINGLN_BLOCK") and not args:
                block = cmd[:-6]
                continue
            if cmd == "DUCKY_LANG":
                if args.upper() != "US":
                    raise CompileError("Only DUCKY_LANG US is supported; use the web UI for other layouts")
                continue
            if cmd in ("DEFAULT_DELAY", "DEFAULT_CHAR_DELAY"):
                code = delay(args)
                if cmd == "DEFAULT_DELAY":
                    default_delay = code
                else:
                    char_delay = code
                continue
            if cmd == "REPEAT":
                count_and_command = args.split(None, 1)
                if len(count_and_command) != 2 or not count_and_command[0].isdigit():
                    raise CompileError("O.MG REPEAT requires count and inline command")
                count = int(count_and_command[0])
                if not 1 <= count <= 1000:
                    raise CompileError("REPEAT count must be 1..1000")
                nested = count_and_command[1].split(None, 1)
                code = instruction(nested[0].upper(), nested[1] if len(nested) == 2 else "")
                for _ in range(count):
                    emit(code + default_delay)
                continue
            emit(instruction(cmd, args) + default_delay)
        except CompileError as exc:
            raise CompileError("Line %d: %s" % (number, exc)) from exc
    if block:
        raise CompileError("Unterminated %s_BLOCK" % block)
    code = "".join(output)
    if not code:
        raise CompileError("Payload has no executable instructions")
    checksum = binascii.crc_hqx(code.encode("ascii"), 0x1d0f)
    count = (len(code) + 1007) // 1008
    return ["CE[%04X]20%02X%02X%s30%02X%02X" % (
        checksum, i + 1, count, code[i * 1008:(i + 1) * 1008], i + 1, count)
        for i in range(count)]
