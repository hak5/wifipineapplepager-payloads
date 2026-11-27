"""Theme, fonts and drawing primitives for the 320x170 CardputerZero screen.

Near-black ground with brass-gold accents from the Quartermaster spyglass.
"""

from functools import lru_cache
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from ..names import one_line

W, H = 320, 170
ASSETS = Path(__file__).resolve().parent.parent / "assets"

BG = (4, 7, 10)
SURFACE = (13, 19, 23)
SURFACE_2 = (20, 29, 35)
LINE = (32, 45, 52)
GREEN = (77, 255, 77)
TEXT = (234, 241, 237)
MUTED = (136, 153, 146)
FAINT = (86, 100, 95)
AMBER = (255, 178, 36)
RED = (255, 84, 84)
CYAN = (64, 214, 255)
GOLD = (245, 179, 1)
GOLD_DIM = (96, 70, 4)
GOLD_INK = (26, 18, 0)
VIOLET = (178, 140, 255)

BAND_COLOR = {"2.4": GREEN, "5": CYAN, "6": VIOLET}

STATUS_H = 18
FOOTER_H = 15
CONTENT_TOP = STATUS_H + 1
CONTENT_BOTTOM = H - FOOTER_H - 1


@lru_cache(maxsize=None)
def font(kind="ui", size=11):
    files = {
        "display": "InterDisplay-ExtraBold.otf",
        "ui": "Inter-SemiBold.otf",
        "bold": "Inter-Bold.otf",
        "mono": "JetBrainsMono-Regular.ttf",
        "monob": "JetBrainsMono-Bold.ttf",
    }
    try:
        return ImageFont.truetype(str(ASSETS / "fonts" / files[kind]), size)
    except OSError:
        return ImageFont.load_default()


@lru_cache(maxsize=None)
def image(name, size=None):
    path = ASSETS / name
    with Image.open(path) as source:
        result = source.convert("RGBA")
    if size:
        result.thumbnail(size, Image.Resampling.LANCZOS)
    return result


@lru_cache(maxsize=8192)
def _length(f, text):
    return f.getlength(text, "L")


@lru_cache(maxsize=1024)
def _stamp(f, text, anchor, fx, fy):
    """The text as a mask, and where its corner goes from the drawing point.

    Drawing glyphs is by far the slowest part of a frame and most strings are the same on the
    next frame, so each is drawn once and pasted from then on.
    """
    left, top, right, bottom = f.getbbox(text, anchor=anchor)
    ox, oy = 1 - min(left, 0), 1 - min(top, 0)
    mask = Image.new("L", (ox + max(right, 0) + 2, oy + max(bottom, 0) + 2))
    ImageDraw.Draw(mask).text((ox + fx, oy + fy), text, font=f, fill=255, anchor=anchor)
    box = mask.getbbox()
    if box is None:
        return None
    return mask.crop(box), box[0] - ox, box[1] - oy


class Canvas:
    """A PIL image with the handful of primitives the screens need."""

    def __init__(self, size=(W, H)):
        self.image = Image.new("RGB", size, BG)
        self.draw = ImageDraw.Draw(self.image)
        self.selected_row = None

    def text_width(self, text, f):
        return _length(f, one_line(text))

    def put(self, xy, text, f, fill=TEXT, anchor="la"):
        """Draw the text exactly as given, at the anchor."""
        text = one_line(text)
        x, y = xy
        fx, fy = math.modf(x)[0], math.modf(y)[0]
        if fx < 0 or fy < 0 or not isinstance(f, ImageFont.FreeTypeFont):
            self.draw.text(xy, text, font=f, fill=fill, anchor=anchor)
            return
        stamp = _stamp(f, text, anchor, fx, fy)
        if stamp:
            mask, dx, dy = stamp
            self.draw.bitmap((int(x) + dx, int(y) + dy), mask, fill)

    def fit(self, text, width, f):
        text = one_line(text)
        if self.text_width(text, f) <= width:
            return text
        lo, hi = 0, len(text)
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.text_width(text[:mid] + "…", f) <= width:
                lo = mid
            else:
                hi = mid - 1
        return text[:lo].rstrip() + "…"

    def text(self, xy, text, f, fill=TEXT, width=None, anchor="la"):
        if width is not None:
            text = self.fit(text, width, f)
        self.put(xy, text, f, fill, anchor)
        return self.text_width(text, f)

    def text_right(self, x, y, text, f, fill=TEXT):
        self.put((x, y), text, f, fill, "ra")

    def text_center(self, x, y, text, f, fill=TEXT):
        self.put((x, y), text, f, fill, "ma")

    def wrap(self, text, width, f):
        lines = []
        for paragraph in str(text).split("\n"):
            words, line = paragraph.split(" "), ""
            for word in words:
                trial = (line + " " + word).strip()
                if self.text_width(trial, f) <= width:
                    line = trial
                    continue
                if line:
                    lines.append(line)
                while self.text_width(word, f) > width:
                    cut = len(self.fit(word, width, f).rstrip("…")) or 1
                    lines.append(word[:cut])
                    word = word[cut:]
                line = word
            lines.append(line)
        return lines

    def rect(self, box, fill=None, outline=None, radius=0, width=1):
        if radius:
            self.draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)
        else:
            self.draw.rectangle(box, fill=fill, outline=outline, width=width)

    def line(self, points, fill=LINE, width=1):
        self.draw.line(points, fill=fill, width=width)

    def paste(self, img, xy):
        self.image.paste(img, (int(xy[0]), int(xy[1])), img if img.mode == "RGBA" else None)

    def select(self, y, height=15, x0=4, x1=W - 8):
        """Highlight behind the chosen row of a list."""
        self.selected_row = (y, y + height)
        self.rect((x0, y, x1, y + height), fill=SURFACE_2, radius=3)
        self.rect((x0, y + 2, x0 + 1, y + height - 2), fill=GOLD)

    def pill(self, x, y, text, f, fg, bg, pad=4, height=None):
        w = int(self.text_width(text, f)) + pad * 2
        h = height or (f.size + 4)
        self.rect((x, y, x + w, y + h), fill=bg, radius=h // 2)
        self.put((x + pad, y + h / 2), text, f, fg, "lm")
        return w

    def tag(self, x, y, text, color, width=19):
        self.rect((x, y, x + width, y + 11), fill=color, radius=3)
        self.put((x + width / 2 + 0.5, y + 6), text, font("monob", 9), BG, "mm")
        return width + 2

    def keycap(self, x, y, key, label):
        f = font("monob", 8)
        w = int(self.text_width(key, f)) + 6
        self.rect((x, y, x + w, y + 10), fill=SURFACE_2, outline=LINE, radius=2)
        self.put((x + w / 2, y + 5), key, f, TEXT, "mm")
        x += w + 3
        t = font("ui", 9)
        self.put((x, y + 5), label, t, MUTED, "lm")
        return w + 3 + int(self.text_width(label, t)) + 8

    def progress(self, box, fraction, fg=GOLD, bg=SURFACE_2):
        x0, y0, x1, y1 = box
        self.rect(box, fill=bg, radius=(y1 - y0) // 2)
        fraction = max(0.0, min(1.0, fraction))
        if fraction > 0:
            self.rect((x0, y0, x0 + max(y1 - y0, int((x1 - x0) * fraction)), y1), fill=fg, radius=(y1 - y0) // 2)

    def battery(self, x, y, percent, color, edge):
        """A battery 22 wide and 10 high, filled from the left up to the percentage."""
        self.rect((x, y, x + 19, y + 9), outline=edge, radius=2)
        self.rect((x + 20, y + 3, x + 21, y + 6), fill=edge)
        if percent > 0:
            self.rect((x + 2, y + 2, x + 1 + max(1, round(16 * percent / 100)), y + 7), fill=color)
        return 22

    def signal_bars(self, x, y, rssi, color=None):
        """Four ascending bars; -95 dBm is one, -55 dBm or better is all four."""
        level = 0 if rssi is None else max(1, min(4, int((rssi + 95) / 13) + 1))
        color = color or (GREEN if level >= 3 else AMBER if level == 2 else RED)
        for i in range(4):
            h = 3 + i * 2
            self.rect((x + i * 4, y + 9 - h, x + i * 4 + 2, y + 9), fill=color if i < level else LINE)
        return 16


def rssi_color(rssi):
    if rssi is None:
        return FAINT
    if rssi >= -67:
        return GREEN
    if rssi >= -82:
        return AMBER
    return RED


def ago(seconds):
    if seconds is None:
        return "—"
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm" % (seconds // 60)
    if seconds < 86400:
        return "%dh" % (seconds // 3600)
    return "%dd" % (seconds // 86400)


def clock(seconds):
    seconds = int(seconds)
    return "%02d:%02d:%02d" % (seconds // 3600, seconds // 60 % 60, seconds % 60)


def distance_m(a, b):
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


def bearing(a, b):
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    y = math.sin(lon2 - lon1) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def compass(degrees):
    return ("N", "NE", "E", "SE", "S", "SW", "W", "NW")[int((degrees + 22.5) // 45) % 8]


def human_distance(meters):
    if meters < 1000:
        return "%d m" % meters
    return "%.1f km" % (meters / 1000)
