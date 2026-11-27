"""Flashes the node firmware onto an ESP32-C5 through the loader in its ROM, over pyserial alone.

Follows Espressif's documented serial protocol: SLIP frames, the ROM's commands and its reset lines.
"""

import functools
import hashlib
import json
import operator
import os
import struct
import time
import zlib

MANIFEST = os.path.join(os.path.dirname(__file__), "assets", "node", "quartermaster-node.json")

FLASH_BEGIN, FLASH_DATA, SYNC, WRITE_REG, READ_REG = 0x02, 0x03, 0x08, 0x09, 0x0A
SPI_SET_PARAMS, SPI_ATTACH, CHANGE_BAUDRATE = 0x0B, 0x0D, 0x0F
DEFL_BEGIN, DEFL_DATA, FLASH_MD5, SECURITY_INFO = 0x10, 0x11, 0x13, 0x14
INVALID = 0x05

C5_ID = 23
C5_MAGIC = (0x1101406F, 0x63E1406F, 0x5FD1406F, 0x30E1706F)
MAGIC_REG = 0x40001000
EFUSE_REVISION = 0x600B4800 + 0x44 + 8
UART_CLKDIV = 0x60000014
PCR_SYSCLK = 0x60096110
SPI = 0x60003000
SPI_USR, SPI_USR2, SPI_MISO_DLEN, SPI_W0 = SPI + 0x18, SPI + 0x20, SPI + 0x28, SPI + 0x58
SPI_CMD_USR = 1 << 18
LP_WDT = 0x600B1C00
WDT_KEY = 0x50D83AA1

ROM_BAUD = 115200
NODE_BAUD = 921600
BLOCK = 0x400
SECTOR = 0x1000
OTADATA_SIZE = 0x2000
TABLE_SIZE = 0xC00
ATTEMPTS = 3


def classic(delay):
    return (("dtr", False), ("rts", True), 0.1, ("dtr", True), ("rts", False), delay, ("dtr", False))


CLASSIC, CLASSIC_SLOW = classic(0.05), classic(0.55)
USB_JTAG = (("rts", False), ("dtr", False), 0.1, ("dtr", True), ("rts", False), 0.1,
            ("rts", True), ("dtr", False), ("rts", True), 0.1, ("dtr", False), ("rts", False))

NO_ANSWER = "No ESP32-C5 answered. Hold BOOT, plug the board in again, and retry."
NO_PORT = "The board's port could not be opened. Plug the board in again and retry."
LOST = "The board stopped answering. Plug it in again and retry."
NOT_C5 = "This is not an ESP32-C5."
EARLY = "This ESP32-C5 is an early sample (revision %d.%d) and cannot run the node firmware."
NEWER = "This ESP32-C5 is a newer revision (%d.%d) than the node firmware knows. Update Quartermaster."
UNREADY = "The board answered but would not get ready for flashing. Plug it in again and retry."
NO_SERIAL = "A part of Quartermaster is missing (python3-serial). Reinstall Quartermaster."
TOO_BIG = "The node firmware does not fit on this board."
LOCKED = "This ESP32-C5 is locked against flashing (secure download mode)."
NO_FLASH = "The flash chip of this board did not answer."
SMALL = "This board has %s of flash. A node needs 4 MB or more."
DAMAGED = "The node firmware that came with Quartermaster is damaged. Reinstall Quartermaster."
LAYOUT = "This node was set up another way. Use a first install, which also clears its settings."
FAILED = "Writing the firmware failed. Plug the board in again and retry."
MISMATCH = "The firmware on the board did not check out after writing. Retry."


class FlashError(Exception):
    """A failure in words the user can act on."""


class Refused(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


class Silent(Exception):
    pass


def slip(packet):
    return b"\xc0" + packet.replace(b"\xdb", b"\xdb\xdd").replace(b"\xc0", b"\xdb\xdc") + b"\xc0"


def unslip(frame):
    return frame.replace(b"\xdb\xdc", b"\xc0").replace(b"\xdb\xdd", b"\xdb")


def checksum(data):
    return functools.reduce(operator.xor, data, 0xEF)


def per_mb(seconds, size):
    return max(3.0, seconds * size / 1e6)


def flash_bytes(jedec):
    size_id = (jedec >> 16) & 0xFF
    if 0x12 <= size_id <= 0x1C:
        return 1 << size_id
    if 0x32 <= size_id <= 0x3C:
        return 1 << (size_id - 0x20)
    return 0


def megabytes(size):
    return "%d MB" % (size >> 20) if size >= 1 << 20 else "%d KB" % (size >> 10)


def load(manifest_path=MANIFEST):
    """The manifest and a reader of its pieces, each checked against its size and SHA-256."""
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError) as e:
        raise FlashError(DAMAGED) from e
    folder = os.path.dirname(os.path.abspath(manifest_path))

    def piece(name):
        try:
            entry = manifest[name]
            with open(os.path.join(folder, os.path.basename(entry["file"])), "rb") as f:
                data = f.read()
            ok = len(data) == entry["size"] and hashlib.sha256(data).hexdigest() == entry["sha256"]
            offset = int(entry["offset"])
        except (OSError, KeyError, TypeError, ValueError) as e:
            raise FlashError(DAMAGED) from e
        if not ok or offset % SECTOR:
            raise FlashError(DAMAGED)
        return data, offset
    return manifest, piece


class Flasher:
    """connect(), then install() or write() and hard_reset(). Every failure is a FlashError in plain words."""

    def __init__(self, port_path, serial_factory=None, clock=time.monotonic, sleep=time.sleep, baud=460800):
        self.path, self.factory, self.clock, self.sleep, self.baud = port_path, serial_factory, clock, sleep, baud
        self.port = None
        self.rx = bytearray()
        self.native = False
        self.deflate = True
        self.revision = None
        self.flash_size = 0

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def open(self):
        """Linux raises DTR and RTS on open and pyserial then sets DTR before RTS. Keeping DTR up until RTS is down
        never shows the board RTS alone, which resets it on either kind of port."""
        factory = self.factory
        if factory is None:
            try:
                import serial
            except ImportError as e:
                raise FlashError(NO_SERIAL) from e
            factory = serial.Serial
        port = factory()
        port.port, port.baudrate, port.timeout, port.write_timeout = self.path, ROM_BAUD, 0.02, 10
        port.exclusive = True
        port.dtr = True
        port.rts = False
        try:
            port.open()
        except (OSError, ValueError) as e:
            raise FlashError(NO_PORT) from e
        self.port = port
        self._lines((("dtr", False),))

    def close(self):
        if self.port is not None:
            try:
                self.port.close()
            except OSError:
                pass
            self.port = None

    def connect(self, native_usb):
        """Asks a running node to restart into its ROM loader, else resets the board into it with the lines that fit
        the port, then the others. Then checks the board can take the node firmware."""
        self.native = native_usb
        if self.port is None:
            self.open()
        usb, uart = (USB_JTAG, USB_JTAG), (CLASSIC, CLASSIC_SLOW)
        for sequence in (None,) + (usb + uart if native_usb else uart + usb):
            if self._reset_and_sync(sequence):
                break
        else:
            raise FlashError(NO_ANSWER)
        try:
            self._identify()
            self._calm_watchdogs()
            if not native_usb and sequence is not USB_JTAG:
                self._speed_up()
            self._attach()
        except Silent as e:
            raise FlashError(LOST) from e
        except Refused as e:
            raise FlashError(UNREADY) from e

    def write(self, image, offset, progress=None):
        """Writes image at offset, compressed where the ROM takes it, and checks it with the ROM's MD5.
        progress(done, total) starts over once when a compressed write did not check out and is written plainly."""
        if self.port is None:
            raise FlashError(LOST)
        if offset % SECTOR or offset + len(image) > self.flash_size:
            raise FlashError(TOO_BIG)
        packed = zlib.compress(image, 9) if self.deflate else None
        try:
            if packed is not None and len(packed) < len(image):
                try:
                    self._send(image, offset, progress, packed)
                    if self._verified(image, offset):
                        return
                except Refused as e:
                    if e.reason != INVALID:
                        raise
                    self.deflate = False
            self._send(image, offset, progress)
            if not self._verified(image, offset):
                raise FlashError(MISMATCH)
        except Silent as e:
            raise FlashError(LOST) from e
        except Refused as e:
            raise FlashError(FAILED) from e

    def install(self, manifest_path=MANIFEST, mode="first", progress=None):
        """first: the whole image from offset 0. update: only the app into ota_0, keeping NVS. Then resets."""
        if self.port is None:
            raise FlashError(LOST)
        manifest, piece = load(manifest_path)
        merged, base = piece("merged")
        if mode == "first":
            parts = [(merged, base)]
        elif mode == "update":
            try:
                table = int(manifest.get("partition_table_offset", 0x8000))
                partitions = manifest["partition_offsets"]
                otadata, ota_0 = int(partitions["otadata"]), int(partitions["ota_0"])
                ota_1 = int(partitions.get("ota_1", self.flash_size))
            except (KeyError, TypeError, ValueError, AttributeError) as e:
                raise FlashError(DAMAGED) from e
            app = piece("app")
            expected = merged[table - base:table - base + TABLE_SIZE]
            if len(expected) != TABLE_SIZE or otadata % SECTOR or app[1] != ota_0 or ota_0 + len(app[0]) > ota_1:
                raise FlashError(DAMAGED)
            try:
                same = self._md5(table, TABLE_SIZE) == hashlib.md5(expected).hexdigest()
            except Silent as e:
                raise FlashError(LOST) from e
            except Refused as e:
                raise FlashError(FAILED) from e
            if not same:
                raise FlashError(LAYOUT)
            parts = [app, (b"\xff" * OTADATA_SIZE, otadata)]
        else:
            raise ValueError(mode)
        total, done = sum(len(data) for data, _ in parts), 0
        for data, offset in parts:
            self.write(data, offset, progress and (lambda n, _t, before=done: progress(before + n, total)))
            done += len(data)
        self.hard_reset()

    def hard_reset(self):
        """Pulses EN so the new firmware starts, then lets go of the port."""
        if self.port is None:
            return
        hold = 0.2 if self.native else 0.1
        try:
            self._lines((("dtr", False), ("rts", True), hold, ("rts", False)) + ((0.2,) if self.native else ()))
        finally:
            self.close()

    def _lines(self, steps):
        try:
            for step in steps:
                if isinstance(step, float):
                    self.sleep(step)
                else:
                    setattr(self.port, step[0], step[1])
        except OSError as e:
            raise FlashError(LOST) from e

    def _flush(self):
        try:
            self.port.reset_input_buffer()
        except OSError as e:
            raise FlashError(LOST) from e
        self.rx.clear()

    def _reset_and_sync(self, sequence):
        """sequence None asks the node firmware for its ROM loader, which it takes up to 2 s to reach."""
        if sequence is None:
            try:
                self.port.baudrate = NODE_BAUD
                self.port.write(b"#BOOTLOADER\n")
                self.port.flush()
                self.port.baudrate = ROM_BAUD
            except (OSError, ValueError) as e:
                raise FlashError(LOST) from e
        else:
            self._lines(sequence)
        self._flush()
        for _ in range(5 if sequence else 20):
            try:
                self._command(SYNC, b"\x07\x07\x12\x20" + b"\x55" * 32, timeout=0.1)
            except (Silent, Refused):
                continue
            self.sleep(0.05)
            self._flush()
            return True
        return False

    def _frame(self, deadline):
        rx = self.rx
        while True:
            start = rx.find(0xC0)
            if start < 0:
                rx.clear()
            else:
                end = rx.find(0xC0, start + 1)
                if end > 0:
                    frame = bytes(rx[start + 1:end])
                    del rx[:end]
                    if frame:
                        return unslip(frame)
                    continue
            if self.clock() > deadline:
                raise Silent()
            rx += self.port.read(max(1, self.port.in_waiting))

    def _command(self, op, data=b"", chk=0, timeout=3.0, size=0):
        """Sends one command; the value and the first size bytes of the answer. Refused carries the ROM's reason."""
        try:
            self.port.write(slip(struct.pack("<BBHI", 0, op, len(data), chk) + data))
            deadline = self.clock() + timeout
            while True:
                frame = self._frame(deadline)
                if len(frame) >= 8 and frame[0] == 1 and frame[1] == op:
                    break
        except OSError as e:
            raise FlashError(LOST) from e
        status = frame[8 + size:10 + size]
        if len(status) < 2 or status[0]:
            raise Refused(status[1] if len(status) == 2 else 0)
        return struct.unpack_from("<I", frame, 4)[0], frame[8:8 + size]

    def _read(self, address):
        return self._command(READ_REG, struct.pack("<I", address))[0]

    def _write_reg(self, address, value):
        self._command(WRITE_REG, struct.pack("<IIII", address, value, 0xFFFFFFFF, 0))

    def _identify(self):
        chip = None
        try:
            info = self._command(SECURITY_INFO, size=20)[1]
            flags, chip = struct.unpack_from("<I", info)[0], struct.unpack_from("<I", info, 12)[0]
        except Refused:
            flags = 0
        if chip is None:
            try:
                chip = C5_ID if self._read(MAGIC_REG) in C5_MAGIC else 0
            except Refused:
                chip = 0
        if chip != C5_ID:
            raise FlashError(NOT_C5)
        if flags & 1 << 2:
            raise FlashError(LOCKED)
        word = self._read(EFUSE_REVISION)
        self.revision = ((word >> 4) & 0x03, word & 0x0F)
        if self.revision[0] == 0:
            raise FlashError(EARLY % self.revision)
        if self.revision[0] >= 2:
            raise FlashError(NEWER % self.revision)

    def _calm_watchdogs(self):
        """The USB Serial/JTAG port leaves the RTC watchdogs running, and they would reset the board mid-write.
        Harmless on a UART boot, so it is done on every port in case the port was taken for the wrong kind."""
        self._write_reg(LP_WDT + 0x18, WDT_KEY)
        self._write_reg(LP_WDT, 0)
        self._write_reg(LP_WDT + 0x18, 0)
        self._write_reg(LP_WDT + 0x20, WDT_KEY)
        self._write_reg(LP_WDT + 0x1C, self._read(LP_WDT + 0x1C) | 1 << 18)
        self._write_reg(LP_WDT + 0x20, 0)

    def _speed_up(self):
        """The ROM may take a 48 MHz crystal for 40 MHz, or the reverse; the baud rate asked for allows for that."""
        if self.baud == ROM_BAUD:
            return
        expected = (self._read(PCR_SYSCLK) >> 24) & 0x7F
        seen = ROM_BAUD * (self._read(UART_CLKDIV) & 0xFFFFF) / 1e6
        crystal = 48 if seen > 45 else 40 if seen > 33 else 26
        asked = self.baud
        if (crystal, expected) in ((48, 40), (40, 48)):
            asked = self.baud * expected // crystal
        try:
            self._command(CHANGE_BAUDRATE, struct.pack("<II", asked, 0))
        except Refused:
            return
        try:
            self.port.baudrate = self.baud
        except (OSError, ValueError) as e:
            raise FlashError(LOST) from e
        self.sleep(0.05)
        self._flush()

    def _attach(self):
        self._command(SPI_ATTACH, struct.pack("<II", 0, 0))
        usr, usr2 = self._read(SPI_USR), self._read(SPI_USR2)
        self._write_reg(SPI_MISO_DLEN, 24 - 1)
        self._write_reg(SPI_USR, 1 << 31 | 1 << 28)
        self._write_reg(SPI_USR2, 7 << 28 | 0x9F)
        self._write_reg(SPI_W0, 0)
        self._write_reg(SPI, SPI_CMD_USR)
        if all(self._read(SPI) & SPI_CMD_USR for _ in range(10)):
            raise FlashError(NO_FLASH)
        jedec = self._read(SPI_W0) & 0xFFFFFF
        self._write_reg(SPI_USR, usr)
        self._write_reg(SPI_USR2, usr2)
        self.flash_size = flash_bytes(jedec)
        if not self.flash_size:
            raise FlashError(NO_FLASH)
        if self.flash_size < 4 << 20:
            raise FlashError(SMALL % megabytes(self.flash_size))
        self._command(SPI_SET_PARAMS, struct.pack("<IIIIII", 0, self.flash_size, 0x10000, SECTOR, 256, 0xFFFF))

    def _send(self, image, offset, progress, packed=None):
        data = image if packed is None else packed
        blocks = -(-len(data) // BLOCK)
        if packed is None:
            begin, op, size = FLASH_BEGIN, FLASH_DATA, len(image)
        else:
            begin, op, size = DEFL_BEGIN, DEFL_DATA, -(-len(image) // BLOCK) * BLOCK
            unpacked = zlib.decompressobj()
        self._command(begin, struct.pack("<IIIII", size, blocks, BLOCK, offset, 0), timeout=per_mb(40, size))
        done = 0
        for seq in range(blocks):
            block = data[seq * BLOCK:(seq + 1) * BLOCK]
            if packed is None:
                grown = len(block)
                block += b"\xff" * (BLOCK - grown)
            else:
                grown = len(unpacked.decompress(block))
            header = struct.pack("<IIII", len(block), seq, 0, 0)
            for attempt in range(ATTEMPTS):
                try:
                    self._command(op, header + block, checksum(block), timeout=per_mb(40, grown))
                    break
                except Refused:
                    if attempt == ATTEMPTS - 1:
                        raise
            done += grown
            if progress:
                progress(done, len(image))

    def _md5(self, offset, size):
        return self._command(FLASH_MD5, struct.pack("<IIII", offset, size, 0, 0), timeout=per_mb(8, size),
                             size=32)[1].decode("ascii", "replace")

    def _verified(self, image, offset):
        return self._md5(offset, len(image)) == hashlib.md5(image).hexdigest()
