"""Meshtastic radios that keep their own firmware: a board on USB serial, or meshtasticd on the Pager itself.

Both speak Meshtastic's stream API (0x94 0xC3, a two-byte length, then a FromRadio message). Quartermaster only
asks for the packets the radio hears and never sends a packet or changes a setting. Each heard packet is turned
back into the frame that was on the air, so the same decoder the Cap uses reads it.
"""

import os
import random
import select
import socket
import struct
import termios
import time

from quartermaster import lora, meshpackets

from . import aes

START1, START2 = 0x94, 0xC3
TCP_PORT = 4403
MAX = 512
LONG_FAST = meshpackets.channel_hash("LongFast")


def frame(message):
    return bytes((START1, START2)) + struct.pack(">H", len(message)) + message


def _key(number, wire):
    return _varint(number << 3 | wire)


def _varint(value):
    value &= (1 << 64) - 1
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def want_config(nonce):
    return _key(3, 0) + _varint(nonce)


def _signed(value):
    value &= (1 << 64) - 1
    return value - (1 << 64) if value >> 63 else value


class Frames:
    """Whole messages out of a byte stream, skipping the debug text a board prints between them."""

    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer += data
        out = []
        while True:
            start = self.buffer.find(bytes((START1, START2)))
            if start < 0:
                del self.buffer[:max(0, len(self.buffer) - 1)]
                return out
            del self.buffer[:start]
            if len(self.buffer) < 4:
                return out
            size = struct.unpack(">H", self.buffer[2:4])[0]
            if size > MAX:
                del self.buffer[:2]
                continue
            if len(self.buffer) < 4 + size:
                return out
            out.append(bytes(self.buffer[4:4 + size]))
            del self.buffer[:4 + size]


def my_number(message):
    try:
        info = meshpackets._get(meshpackets.fields(message), 3, 2)
        return meshpackets._get(meshpackets.fields(info), 1, 0) if info is not None else None
    except (meshpackets.Malformed, struct.error):
        return None


def heard(message, me=None):
    """(frame as on the air, rssi, snr) for a FromRadio that carries a packet off the air, else None."""
    try:
        top = meshpackets.fields(message)
        packet = meshpackets._get(top, 2, 2)
        if packet is None:
            return None
        p = meshpackets.fields(packet)
        source = meshpackets._get(p, 1, 5)
        if source is None:
            return None
        source = struct.unpack("<I", source)[0]
        if source == me:
            return None
        dest = struct.unpack("<I", meshpackets._get(p, 2, 5) or b"\xff\xff\xff\xff")[0]
        packet_id = struct.unpack("<I", meshpackets._get(p, 6, 5) or b"\0\0\0\0")[0]
        if not meshpackets._get(p, 7, 5) and not meshpackets._get(p, 12, 0):
            return None
        hop_limit = (meshpackets._get(p, 9, 0) or 0) & 7
        hop_start = (meshpackets._get(p, 15, 0) or 0) & 7
        flags = hop_limit | (0x08 if meshpackets._get(p, 10, 0) else 0) | \
            (0x10 if meshpackets._get(p, 14, 0) else 0) | hop_start << 5
        next_hop, relay = (meshpackets._get(p, 18, 0) or 0) & 0xFF, (meshpackets._get(p, 19, 0) or 0) & 0xFF
        encrypted, decoded = meshpackets._get(p, 5, 2), meshpackets._get(p, 4, 2)
        channel = meshpackets._get(p, 3, 0) or 0
        if decoded is not None:
            data = meshpackets.fields(decoded)
            port, body = meshpackets._get(data, 1, 0), meshpackets._get(data, 2, 2) or b""
            if port is None:
                return None
            plain = _key(1, 0) + _varint(port) + _key(2, 2) + _varint(len(body)) + body
            nonce = struct.pack("<QII", packet_id, source, 0)
            body = meshpackets._aes_ctr(meshpackets.DEFAULT_KEY, nonce, plain) or \
                aes.ctr(meshpackets.DEFAULT_KEY, nonce, plain)
            channel = LONG_FAST
        elif encrypted is not None:
            body = encrypted
        else:
            return None
        raw = struct.pack("<IIIBBBB", dest, source, packet_id, flags, channel & 0xFF, next_hop, relay) + body
        snr = meshpackets._get(p, 8, 5)
        rssi = meshpackets._get(p, 12, 0)
        return raw[:255], float(_signed(rssi)) if rssi else 0.0, struct.unpack("<f", snr)[0] if snr else 0.0
    except (meshpackets.Malformed, struct.error, IndexError):
        return None


class Tcp:
    def __init__(self, host="127.0.0.1", port=TCP_PORT, timeout=1.0):
        self.sock = socket.create_connection((host, port), timeout)
        self.sock.setblocking(False)

    def fileno(self):
        return self.sock.fileno()

    def write(self, data):
        self.sock.setblocking(True)
        try:
            self.sock.sendall(data)
        finally:
            self.sock.setblocking(False)

    def read(self):
        try:
            data = self.sock.recv(4096)
        except BlockingIOError:
            return b""
        if not data:
            raise OSError("closed")
        return data

    def close(self):
        self.sock.close()


class Serial:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            attrs = termios.tcgetattr(self.fd)
            attrs[0] = 0
            attrs[1] = 0
            attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            attrs[3] = 0
            attrs[4] = attrs[5] = termios.B115200
            attrs[6][termios.VMIN], attrs[6][termios.VTIME] = 0, 0
            termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
            termios.tcflush(self.fd, termios.TCIOFLUSH)
        except (termios.error, OSError):
            os.close(self.fd)
            raise OSError("not a serial port")

    def fileno(self):
        return self.fd

    def write(self, data):
        view = memoryview(data)
        deadline = time.monotonic() + 1.0
        while view:
            try:
                view = view[os.write(self.fd, view):]
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise OSError("serial write stalled")
                time.sleep(0.01)

    def read(self):
        try:
            return os.read(self.fd, 4096)
        except BlockingIOError:
            return b""

    def close(self):
        os.close(self.fd)


def hello(link):
    link.write(bytes((START2,)) * 32)
    time.sleep(0.1)
    link.write(frame(want_config(random.randint(1, 0x7FFFFFFF))))


def answers(link, seconds=3.0):
    """True once the far end sends a whole stream API message."""
    frames, deadline = Frames(), time.monotonic() + seconds
    hello(link)
    while time.monotonic() < deadline:
        ready, _, _ = select.select([link], [], [], 0.1)
        if ready and frames.feed(link.read()):
            return True
    return False


class StreamRadio:
    """Stands where the Cap's radio stands. The radio keeps its own channel, so tune() changes nothing and the
    wardrive listens on Meshtastic alone."""

    meshtastic_only = True

    def __init__(self, connect):
        self.connect = connect
        self.link = None
        self.profile = None
        self.frames = Frames()
        self.counts = dict(received=0, crc_errors=0, header_errors=0)
        self.queue = []
        self.me = None
        self._heartbeat = 0.0

    def open(self, profile=None):
        if self.link is not None:
            return self
        try:
            self.link = self.connect()
            hello(self.link)
        except PermissionError:
            raise lora.RadioError(lora.DENIED) from None
        except OSError:
            self.link = None
            raise lora.RadioError(lora.ABSENT) from None
        self._heartbeat = time.monotonic()
        self.profile = profile
        return self

    def tune(self, profile):
        if self.link is None:
            raise lora.RadioError("closed")
        self.profile = profile

    def receive(self, timeout=0.25, wait=None):
        if self.link is None:
            raise lora.RadioError("closed")
        wait = wait or time.sleep
        deadline = time.monotonic() + timeout
        while not self.queue:
            try:
                ready, _, _ = select.select([self.link], [], [], 0)
                if ready:
                    for message in self.frames.feed(self.link.read()):
                        self.me = my_number(message) or self.me
                        found = heard(message, self.me)
                        if found is not None:
                            self.queue = (self.queue + [found])[-64:]
                if time.monotonic() - self._heartbeat > 60:
                    self._heartbeat = time.monotonic()
                    self.link.write(frame(_key(7, 2) + b"\x00"))
            except OSError:
                raise lora.RadioError(lora.ABSENT) from None
            if self.queue:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            if wait(min(lora.POLL * 5, remaining)):
                return None
        raw, rssi, snr = self.queue.pop(0)
        if self.profile is not None and self.profile.protocol != "meshtastic":
            return None
        self.counts["received"] += 1
        return raw, rssi, snr, True

    def close(self):
        link, self.link = self.link, None
        self.queue = []
        if link is not None:
            try:
                link.close()
            except OSError:
                pass
