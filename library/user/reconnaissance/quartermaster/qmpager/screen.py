"""The Pager's screen: a 222x480 RGB565 panel, drawn on as a 480x222 landscape screen."""

import os

from PIL import Image, ImageChops

from quartermaster.ui.display import FramebufferDisplay

WIDTH, HEIGHT = 480, 222
LOW_G = [((v >> 2) & 7) << 5 for v in range(256)]
LOW_B = [v >> 3 for v in range(256)]
HIGH_R = [(v >> 3) << 3 for v in range(256)]
HIGH_G = [v >> 5 for v in range(256)]


def to_rgb565(img):
    """Little-endian RGB565 with Pillow alone: the feed's Pillow has no 16-bit packer and there is no numpy."""
    r, g, b = img.convert("RGB").split()
    low = ImageChops.add(g.point(LOW_G), b.point(LOW_B))
    high = ImageChops.add(r.point(HIGH_R), g.point(HIGH_G))
    return Image.merge("LA", (low, high)).tobytes()


class PagerDisplay(FramebufferDisplay):
    profile = "pager"

    def __init__(self, device="/dev/fb0"):
        super().__init__(device)
        self.panel = (self.width, self.height)
        self.portrait = self.width < self.height
        self.width, self.height = WIDTH, HEIGHT
        self._last = None

    def frame(self, img):
        if img.size != (WIDTH, HEIGHT):
            img = img.resize((WIDTH, HEIGHT))
        img = img.convert("RGB")
        if self.portrait:
            img = img.transpose(Image.Transpose.ROTATE_270)
        if img.size != self.panel:
            img = img.resize(self.panel)
        return to_rgb565(img)

    def write(self, data):
        row = self.panel[0] * 2
        if self.stride != row:
            data = b"".join(data[y * row:(y + 1) * row].ljust(self.stride, b"\x00") for y in range(self.panel[1]))
        os.lseek(self.fd, 0, os.SEEK_SET)
        view = memoryview(data)
        while view:
            view = view[os.write(self.fd, view):]

    def show(self, img):
        raw = img.tobytes()
        if raw == self._last:
            return
        self._last = raw
        self.write(self.frame(img))

    def close(self):
        try:
            self.write(bytes(self.panel[0] * self.panel[1] * 2))
            self.map.close()
        finally:
            os.close(self.fd)
