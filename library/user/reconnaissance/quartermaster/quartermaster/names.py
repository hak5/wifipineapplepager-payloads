"""Names heard on the air can hold anything: line breaks, control characters, broken halves of characters."""

_UNSAFE = dict.fromkeys((*range(32), *range(127, 160), 0x2028, 0x2029, *range(0xD800, 0xE000)), " ")


def one_line(value):
    """The text with everything that could break a line of a log or of the screen turned into spaces."""
    text = str(value)
    return text if text.isprintable() else text.translate(_UNSAFE)
