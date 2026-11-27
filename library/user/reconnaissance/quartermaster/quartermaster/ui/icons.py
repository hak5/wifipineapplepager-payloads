"""Small icons, drawn large and scaled down so their edges stay smooth at any size."""

from functools import lru_cache

from PIL import Image, ImageDraw

INK, HOLE = 255, 0


def _disc(d, cx, cy, r, fill=INK):
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill)


def _arc(d, cx, cy, r, start, end, width):
    d.arc((cx - r, cy - r, cx + r, cy + r), start, end, fill=INK, width=int(width))


def wifi(d, s):
    cx, cy = s * 0.5, s * 0.82
    for r in (0.70, 0.48, 0.26):
        _arc(d, cx, cy, s * r, 225, 315, max(1, s * 0.11))
    _disc(d, cx, cy - s * 0.02, s * 0.09)


def eye(d, s):
    d.chord((s * 0.04, s * 0.22, s * 0.96, s * 1.04), 200, 340, fill=INK)
    d.chord((s * 0.04, -s * 0.04, s * 0.96, s * 0.78), 20, 160, fill=INK)
    _disc(d, s * 0.5, s * 0.5, s * 0.18, HOLE)
    _disc(d, s * 0.5, s * 0.5, s * 0.08)


def folder(d, s):
    d.rounded_rectangle((s * 0.06, s * 0.18, s * 0.46, s * 0.42), radius=s * 0.06, fill=INK)
    d.rounded_rectangle((s * 0.06, s * 0.32, s * 0.94, s * 0.84), radius=s * 0.08, fill=INK)


def cloud(d, s):
    _disc(d, s * 0.27, s * 0.60, s * 0.19)
    _disc(d, s * 0.47, s * 0.42, s * 0.23)
    _disc(d, s * 0.72, s * 0.58, s * 0.21)
    d.rectangle((s * 0.27, s * 0.58, s * 0.72, s * 0.79), fill=INK)
    d.polygon([(s * 0.50, s * 0.36), (s * 0.67, s * 0.56), (s * 0.33, s * 0.56)], fill=HOLE)
    d.rectangle((s * 0.445, s * 0.54, s * 0.555, s * 0.72), fill=HOLE)


def chip(d, s):
    d.rounded_rectangle((s * 0.22, s * 0.22, s * 0.78, s * 0.78), radius=s * 0.08, fill=INK)
    d.rectangle((s * 0.37, s * 0.37, s * 0.63, s * 0.63), fill=HOLE)
    w = s * 0.045
    for t in (0.34, 0.50, 0.66):
        d.rectangle((s * t - w, s * 0.06, s * t + w, s * 0.22), fill=INK)
        d.rectangle((s * t - w, s * 0.78, s * t + w, s * 0.94), fill=INK)
        d.rectangle((s * 0.06, s * t - w, s * 0.22, s * t + w), fill=INK)
        d.rectangle((s * 0.78, s * t - w, s * 0.94, s * t + w), fill=INK)


def sliders(d, s):
    w = max(1, int(s * 0.09))
    for i, knob in enumerate((0.30, 0.68, 0.45)):
        y = s * (0.22 + i * 0.28)
        d.line((s * 0.08, y, s * 0.92, y), fill=INK, width=w)
        _disc(d, s * knob, y, s * 0.13)
        _disc(d, s * knob, y, s * 0.055, HOLE)


def key(d, s):
    _disc(d, s * 0.28, s * 0.50, s * 0.23)
    _disc(d, s * 0.25, s * 0.50, s * 0.09, HOLE)
    d.rectangle((s * 0.46, s * 0.44, s * 0.95, s * 0.56), fill=INK)
    d.rectangle((s * 0.68, s * 0.56, s * 0.77, s * 0.73), fill=INK)
    d.rectangle((s * 0.84, s * 0.56, s * 0.93, s * 0.68), fill=INK)


def anchor(d, s):
    w = max(1, int(s * 0.10))
    d.ellipse((s * 0.38, s * 0.04, s * 0.62, s * 0.28), outline=INK, width=max(1, int(s * 0.07)))
    d.line((s * 0.5, s * 0.26, s * 0.5, s * 0.92), fill=INK, width=w)
    d.line((s * 0.30, s * 0.40, s * 0.70, s * 0.40), fill=INK, width=w)
    _arc(d, s * 0.5, s * 0.54, s * 0.38, 15, 165, w)
    d.polygon([(s * 0.74, s * 0.56), (s * 0.98, s * 0.50), (s * 0.94, s * 0.76)], fill=INK)
    d.polygon([(s * 0.26, s * 0.56), (s * 0.02, s * 0.50), (s * 0.06, s * 0.76)], fill=INK)


def pin(d, s):
    _disc(d, s * 0.5, s * 0.38, s * 0.30)
    d.polygon([(s * 0.245, s * 0.52), (s * 0.755, s * 0.52), (s * 0.5, s * 0.96)], fill=INK)
    _disc(d, s * 0.5, s * 0.38, s * 0.12, HOLE)


def alert(d, s):
    d.polygon([(s * 0.5, s * 0.06), (s * 0.96, s * 0.90), (s * 0.04, s * 0.90)], fill=INK)
    d.line((s * 0.5, s * 0.36, s * 0.5, s * 0.62), fill=HOLE, width=max(1, int(s * 0.10)))
    _disc(d, s * 0.5, s * 0.75, s * 0.06, HOLE)


def record(d, s):
    _disc(d, s * 0.5, s * 0.5, s * 0.36)


def phone(d, s):
    d.rounded_rectangle((s * 0.26, s * 0.04, s * 0.74, s * 0.96), radius=s * 0.10, fill=INK)
    d.rectangle((s * 0.33, s * 0.16, s * 0.67, s * 0.76), fill=HOLE)
    _disc(d, s * 0.5, s * 0.86, s * 0.045, HOLE)


def bolt(d, s):
    d.polygon([(s * 0.60, s * 0.02), (s * 0.16, s * 0.58), (s * 0.46, s * 0.58), (s * 0.38, s * 0.98),
               (s * 0.84, s * 0.40), (s * 0.54, s * 0.40)], fill=INK)


ICONS = {"wifi": wifi, "eye": eye, "folder": folder, "cloud": cloud, "chip": chip, "sliders": sliders, "key": key,
         "anchor": anchor, "pin": pin, "alert": alert, "record": record, "phone": phone, "bolt": bolt}


@lru_cache(maxsize=256)
def render(name, size, color):
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    ICONS[name](ImageDraw.Draw(mask), size * scale)
    picture = Image.new("RGBA", (size, size), tuple(color) + (0,))
    picture.putalpha(mask.resize((size, size), Image.Resampling.LANCZOS))
    return picture


def draw(canvas, name, x, y, size, color):
    canvas.paste(render(name, int(size), tuple(color)), (x, y))
