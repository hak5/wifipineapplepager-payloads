"""Boot animation: a black and gold ship sails in and drops three sails."""

from functools import lru_cache
import math

from PIL import Image, ImageDraw

from .gfx import H, W, Canvas, font, image

SAIL_GOLD = (245, 179, 1)
SAIL_CREAM = (252, 240, 204)
HULL = (196, 138, 0)
NIGHT = (6, 6, 8)
STARS = ((18, 14), (47, 30), (71, 9), (96, 22), (222, 12), (251, 27), (283, 8), (305, 33), (14, 58), (309, 70),
         (140, 6), (190, 9))
SECONDS = 3.0
HOLD = 1.8


def ease(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


@lru_cache(maxsize=None)
def _sail(width, height, color, logo, logo_box):
    k = 4
    img = Image.new("RGBA", (width * k, height * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    w, h, inset, belly = width * k, height * k, width * k * 0.09, height * k * 0.07
    d.polygon([(inset, 0), (w - inset, 0), (w, h - belly), (w * 0.5, h), (0, h - belly)], fill=color)
    d.line([(inset, k), (w - inset, k)], fill=(0, 0, 0), width=k * 2)
    art = image(logo, (logo_box[0] * k, logo_box[1] * k))
    img.paste(art, ((w - art.width) // 2, int((h - belly - art.height) / 2) + k), art)
    return img.resize((width, height), Image.Resampling.LANCZOS)


@lru_cache(maxsize=None)
def _hull():
    k = 4
    img = Image.new("RGBA", (300 * k, 46 * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    body = [(4, 2), (44, 2), (44, 12), (252, 12), (284, 3), (262, 44), (30, 44)]
    d.polygon([(x * k, y * k) for x, y in body], fill=HULL)
    rail = [(4, 2), (44, 2), (44, 12), (252, 12), (284, 3)]
    d.line([(x * k, y * k) for x, y in rail], fill=SAIL_GOLD, width=3 * k, joint="curve")
    d.line([(276 * k, 5 * k), (299 * k, 0)], fill=SAIL_GOLD, width=2 * k)
    for x in (16, 30):
        d.rectangle((x * k, 7 * k, (x + 6) * k, 12 * k), fill=NIGHT)
    return img.resize((300, 46), Image.Resampling.LANCZOS)


def frame(t):
    """The animation at time t from 0 to 1: the ship glides in, its sails drop one by one
    carrying the three logos, and the name appears on the hull."""
    c = Canvas()
    c.rect((0, 0, W, H), fill=NIGHT)
    for i, (x, y) in enumerate(STARS):
        twinkle = 0.55 + 0.45 * math.sin(t * 9 + i * 1.7)
        c.rect((x, y, x + 1, y + 1), fill=tuple(int(v * twinkle) for v in SAIL_GOLD))
    dx = int(-300 * (1 - ease(t / 0.3)))
    bob = int(round(1.5 * math.sin(t * 10)))
    for mx, top in ((67, 30), (160, 8), (253, 30)):
        c.rect((mx - 1 + dx, top + bob, mx + 1 + dx, 108 + bob), fill=HULL)
    c.draw.polygon([(161 + dx, 8 + bob), (179 + dx, 12 + bob), (161 + dx, 17 + bob)], fill=SAIL_GOLD)
    sails = ((33, 36, 68, 66, SAIL_GOLD, "bwm-logo.png", (44, 44), 0.28),
             (109, 14, 102, 90, SAIL_CREAM, "quartermaster-logo.png", (92, 70), 0.40),
             (219, 36, 68, 66, SAIL_GOLD, "vts-logo.png", (44, 44), 0.52))
    for x, y, w, h, color, logo, box, start in sails:
        drop = ease((t - start) / 0.22)
        if drop > 0:
            c.paste(_sail(w, h, color, logo, box).crop((0, 0, w, max(1, int(h * drop)))), (x + dx, y + bob))
    c.paste(_hull(), (10 + dx, 96 + bob))
    name = ease((t - 0.72) / 0.2)
    if name > 0:
        f = font("display", 18)
        text, gap = "QUARTERMASTER", 3.0
        x = (W - sum(c.text_width(ch, f) for ch in text) - gap * (len(text) - 1)) / 2
        ink = tuple(int(v * (1 - name)) for v in HULL)
        for ch in text:
            c.text((x + 2, 113 + bob), ch, f, ink)
            x += c.text_width(ch, f) + gap
    for row, (base, amp, shade) in enumerate(((141, 2.5, 1.0), (152, 2.0, 0.7), (162, 1.6, 0.45))):
        phase = t * (14 - row * 3) + row * 1.3
        points = [(x, base + amp * math.sin(x / 9.0 + phase)) for x in range(-2, W + 4, 3)]
        if row == 0:
            c.draw.polygon(points + [(W + 4, H), (-2, H)], fill=(20, 14, 0))
        c.draw.line(points, fill=tuple(int(v * shade) for v in SAIL_GOLD), width=2)
    return c.image
