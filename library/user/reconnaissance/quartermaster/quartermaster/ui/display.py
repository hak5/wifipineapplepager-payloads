"""The CardputerZero screen: a 320x170 RGB565 framebuffer."""

import fcntl
import mmap
import os
import struct

FBIOGET_VSCREENINFO = 0x4600
FBIOGET_FSCREENINFO = 0x4602


def to_rgb565(img):
    try:
        import numpy as np
        a = np.asarray(img.convert("RGB"), dtype=np.uint16)
        value = ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)
        return value.astype("<u2").tobytes()
    except ImportError:
        # Pillow's packer is fast enough when numpy is missing.
        return img.convert("RGB").tobytes("raw", "BGR;16")


class FramebufferDisplay:
    def __init__(self, device=None):
        self.device = device or os.environ.get("APPLAUNCH_LINUX_FBDEV_DEVICE", "/dev/fb0")
        self.fd = os.open(self.device, os.O_RDWR)
        try:
            var = bytearray(160)
            fcntl.ioctl(self.fd, FBIOGET_VSCREENINFO, var)
            self.width, self.height, _, _, _, _, self.bpp = struct.unpack_from("7I", var, 0)
            fix_format = "16sL" + "I" * 6 + "HHHI"
            fix = bytearray(struct.calcsize(fix_format))
            fcntl.ioctl(self.fd, FBIOGET_FSCREENINFO, fix)
            fields = struct.unpack(fix_format, fix)
            self.size, self.stride = fields[2], fields[8]
            if self.bpp != 16:
                raise OSError("Expected a 16-bit framebuffer")
            self.map = mmap.mmap(self.fd, self.size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
        except Exception:
            os.close(self.fd)
            raise

    def show(self, img):
        if img.size != (self.width, self.height):
            img = img.resize((self.width, self.height))
        data = to_rgb565(img)
        row = self.width * 2
        if self.stride == row:
            self.map.seek(0)
            self.map.write(data)
        else:
            for y in range(self.height):
                self.map.seek(y * self.stride)
                self.map.write(data[y * row:(y + 1) * row])

    def close(self):
        try:
            self.map.seek(0)
            self.map.write(b"\x00" * min(self.size, self.stride * self.height))
            self.map.close()
        finally:
            os.close(self.fd)
