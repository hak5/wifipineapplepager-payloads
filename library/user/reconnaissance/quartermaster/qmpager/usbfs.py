"""USB devices through Linux usbfs, with no library: what the CH341 LoRa sticks need, and nothing more."""

import ctypes
import errno
import fcntl
import os
import platform

SYS_USB = "/sys/bus/usb/devices"


def _encoding():
    if platform.machine().lower().startswith(("mips", "ppc", "powerpc", "sparc")):
        return 13, 1, 2, 4
    return 14, 0, 2, 1


def _ioc(direction, number, size):
    size_bits, none, read, write = _encoding()
    bits = {"": none, "r": read, "w": write, "rw": read | write}[direction]
    return (bits << (16 + size_bits)) | (size << 16) | (ord("U") << 8) | number


class _Bulk(ctypes.Structure):
    _fields_ = [("ep", ctypes.c_uint), ("len", ctypes.c_uint), ("timeout", ctypes.c_uint),
                ("data", ctypes.c_void_p)]


class _Ioctl(ctypes.Structure):
    _fields_ = [("ifno", ctypes.c_int), ("ioctl_code", ctypes.c_int), ("data", ctypes.c_void_p)]


BULK = _ioc("rw", 2, ctypes.sizeof(_Bulk))
CLAIM = _ioc("r", 15, ctypes.sizeof(ctypes.c_uint))
RELEASE = _ioc("r", 16, ctypes.sizeof(ctypes.c_uint))
IOCTL = _ioc("rw", 18, ctypes.sizeof(_Ioctl))
DISCONNECT = _ioc("", 22, 0)


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def find(vendor, product, root=SYS_USB):
    """Each plugged-in device with this id, as {"sys", "node", "label"}."""
    found = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return found
    for name in names:
        base = os.path.join(root, name)
        if ":" in name or _read(os.path.join(base, "idVendor")).lower() != vendor or \
                _read(os.path.join(base, "idProduct")).lower() != product:
            continue
        bus, dev = _read(os.path.join(base, "busnum")), _read(os.path.join(base, "devnum"))
        if not (bus.isdigit() and dev.isdigit()):
            continue
        label = " ".join(x for x in (_read(os.path.join(base, "manufacturer")), _read(os.path.join(base, "product")))
                         if x)
        found.append({"sys": base, "node": "/dev/bus/usb/%03d/%03d" % (int(bus), int(dev)), "label": label,
                      "driver": os.path.basename(os.path.realpath(os.path.join(base, name + ":1.0", "driver")))
                      if os.path.exists(os.path.join(base, name + ":1.0", "driver")) else ""})
    return found


class Device:
    """One interface of one device, claimed for this process. Another owner gives EBUSY on open."""

    def __init__(self, node, interface=0, detach=False):
        self.interface = interface
        self.fd = os.open(node, os.O_RDWR)
        try:
            if detach:
                self._detach()
            fcntl.ioctl(self.fd, CLAIM, ctypes.c_uint(interface))
        except OSError:
            os.close(self.fd)
            self.fd = None
            raise

    def _detach(self):
        request = _Ioctl(self.interface, DISCONNECT, None)
        try:
            fcntl.ioctl(self.fd, IOCTL, request)
        except OSError as exc:
            if exc.errno not in (errno.ENODATA, errno.ENOENT, errno.EINVAL):
                raise

    def bulk(self, endpoint, data=b"", size=0, timeout_ms=1000):
        buffer = ctypes.create_string_buffer(bytes(data), len(data)) if data else ctypes.create_string_buffer(size)
        length = len(data) if data else size
        request = _Bulk(endpoint, length, timeout_ms, ctypes.cast(buffer, ctypes.c_void_p))
        count = fcntl.ioctl(self.fd, BULK, request)
        return buffer.raw[:count]

    def write(self, endpoint, data, timeout_ms=1000):
        if len(self.bulk(endpoint, data, timeout_ms=timeout_ms)) != len(data):
            raise OSError(errno.EIO, "short write")

    def read(self, endpoint, size, timeout_ms=1000):
        return self.bulk(endpoint, size=size, timeout_ms=timeout_ms)

    def close(self):
        if self.fd is None:
            return
        try:
            fcntl.ioctl(self.fd, RELEASE, ctypes.c_uint(self.interface))
        except OSError:
            pass
        os.close(self.fd)
        self.fd = None
