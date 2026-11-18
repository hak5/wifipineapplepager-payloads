"""Receive-only SX1262 adapter for the Glytch Mesh CH341 USB module.

The public API never exposes a transmit operation. The SPI command gate also
rejects TX, continuous-wave and infinite-preamble opcodes. LoRa packet bytes
are preserved before protocol interpretation, as with LoRaPipe RXLOG.
"""

import struct
import time

from .profiles import validate_profile


class RadioError(RuntimeError):
    pass


class GlytchRadio:
    # Glytch Pager-Mod-Docs/Mesh/payload.sh: Meshtoad E22 board profile.
    CS, RXEN, RESET, BUSY, IRQ = 0, 1, 2, 4, 6
    MAX_PACKET = 255
    # Semtech SX1261/2 command set: these three commands can emit RF.
    _FORBIDDEN = {0x83, 0xD1, 0xD2}
    _BW = {62500: 0x03, 125000: 0x04, 250000: 0x05, 500000: 0x06}

    def __init__(self, profile, usb_bus=None, usb_address=None, *, transport=None):
        self.profile = validate_profile(profile)
        self.usb_bus, self.usb_address = usb_bus, usb_address
        self._transport = transport
        self._opened = False
        self.diagnostics = {"received": 0, "crc_errors": 0, "header_errors": 0,
                            "timeouts": 0, "retunes": 0, "malformed": 0}

    def _wait_ready(self):
        deadline = time.monotonic() + 0.5
        while self._transport.gpio_get(self.BUSY):
            if time.monotonic() >= deadline:
                raise RadioError("SX1262 BUSY did not clear")
            time.sleep(0.001)

    def _command(self, opcode, args=b"", read=0):
        if opcode in self._FORBIDDEN:
            raise RadioError("Transmit is disabled")
        if len(args) > 260 or not 0 <= read <= 256:
            raise RadioError("Invalid SPI transfer length")
        self._wait_ready()
        self._transport.gpio_set(self.CS, False)
        try:
            # SX1262 reads include a dummy/status byte after the arguments.
            outgoing = bytes([opcode]) + bytes(args)
            if read:
                outgoing += b"\x00" * (read + 1)
            reply = self._transport.spi_transfer_async(outgoing)
            if len(reply) != len(outgoing):
                raise RadioError("Short SX1262 SPI transfer")
            return bytes(reply[-read:]) if read else b""
        finally:
            self._transport.gpio_set(self.CS, True)

    def _register_read(self, address, count=1):
        return self._command(0x1D, struct.pack(">H", address), count)

    def _register_write(self, address, values):
        self._command(0x0D, struct.pack(">H", address) + bytes(values))

    def open(self):
        if self._opened:
            return self
        if self._transport is None:
            try:
                from .vendor.ch341 import CH341Async
            except ImportError as exc:
                raise RadioError("Native capture needs Python PyUSB and libusb") from exc
            self._transport = CH341Async.get_instance(bus=self.usb_bus, address=self.usb_address)
            self._transport.USB_TIMEOUT = 500
        try:
            for pin in (self.CS, self.RESET, self.RXEN):
                self._transport.gpio_set_direction(pin, True)
            for pin in (self.BUSY, self.IRQ):
                self._transport.gpio_set_direction(pin, False)
            self._transport.gpio_set(self.CS, True)
            self._transport.gpio_set(self.RXEN, False)
            self._transport.gpio_set(self.RESET, False)
            time.sleep(0.002)
            self._transport.gpio_set(self.RESET, True)
            time.sleep(0.010)
            self._command(0x80, b"\x00")  # STDBY_RC
            # Glytch DIO3_TCXO_VOLTAGE:true maps to Meshtastic's 1.8 V default.
            self._command(0x97, b"\x02\x00\x01\x40")  # 1.8 V, 5 ms
            self._command(0x89, b"\x7f")
            self._command(0x96, b"\x01")  # DC-DC regulator
            self._command(0x8A, b"\x01")  # LoRa packet type
            self._command(0x9D, b"\x01")  # DIO2 RF switch
            # Verify chip register communication before claiming it is ready.
            if self._command(0x11, read=1) != b"\x01":
                raise RadioError("SX1262 did not confirm LoRa packet mode")
            self._command(0x8F, b"\x00\x00")  # RX buffer starts at zero
            self._opened = True
            self.tune(self.profile)
            return self
        except Exception:
            self.close()
            raise

    def tune(self, profile):
        profile = validate_profile(profile)
        if not self._opened:
            raise RadioError("Radio is not open")
        self._command(0x80, b"\x00")
        self._command(0x98, b"\xe1\xe9" if profile.frequency_hz >= 902000000 else b"\xd7\xdb")
        word = (profile.frequency_hz * (1 << 25) + 16000000) // 32000000
        self._command(0x86, struct.pack(">I", word))
        ldro = int((2 ** profile.spreading_factor) / profile.bandwidth_hz > 0.016)
        self._command(0x8B, bytes([profile.spreading_factor, self._BW[profile.bandwidth_hz],
                                   profile.coding_rate - 4, ldro]))
        # Explicit header, full FIFO capacity, CRC enabled, normal IQ.
        self._command(0x8C, struct.pack(">HBBBB", profile.preamble_symbols, 0, 255, 1, 0))
        sync = bytes([(profile.sync_word & 0xF0) | 0x04, ((profile.sync_word & 0x0F) << 4) | 0x04])
        self._register_write(0x0740, sync)
        if self._register_read(0x0740, 2) != sync:
            raise RadioError("SX1262 sync-word verification failed")
        self._register_write(0x08AC, b"\x96")  # boosted receive gain
        # Semtech normal-IQ and antenna-resistance workarounds.
        self._register_write(0x0736, bytes([self._register_read(0x0736)[0] | 0x04]))
        self._register_write(0x08D8, bytes([self._register_read(0x08D8)[0] | 0x1E]))
        self._command(0x08, struct.pack(">HHHH", 0x0262, 0x0262, 0, 0))
        self._command(0x02, b"\xff\xff")
        self._transport.gpio_set(self.RXEN, True)
        self._command(0x82, b"\xff\xff\xff")  # continuous receive
        self.profile = profile
        self.diagnostics["retunes"] += 1

    def receive(self, timeout=0.25):
        if not self._opened:
            raise RadioError("Radio is not open")
        deadline = time.monotonic() + min(max(float(timeout), 0), 2)
        while True:
            irq = int.from_bytes(self._command(0x12, read=2), "big")
            if irq & 0x0262:
                self._command(0x02, irq.to_bytes(2, "big"))
                if irq & 0x0200:
                    self.diagnostics["timeouts"] += 1
                if irq & 0x0020:
                    self.diagnostics["header_errors"] += 1
                if irq & 0x0040:
                    self.diagnostics["crc_errors"] += 1
                if irq & 0x0002:
                    length, offset = self._command(0x13, read=2)
                    if not 1 <= length <= self.MAX_PACKET:
                        self.diagnostics["malformed"] += 1
                        return None
                    raw = self._command(0x1E, bytes([offset]), length)
                    rssi, snr, _ = self._command(0x14, read=3)
                    snr = snr - 256 if snr & 0x80 else snr
                    crc_ok = not bool(irq & 0x0060)
                    self.diagnostics["received"] += 1
                    return {"timestamp": time.time(), "profile": self.profile.to_dict(),
                            "raw_hex": raw.hex(), "rssi_dbm": -rssi / 2.0,
                            "snr_db": snr / 4.0, "crc_ok": crc_ok}
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.020)

    def close(self):
        if self._transport is not None:
            try:
                if self._opened:
                    self._command(0x80, b"\x00")
                self._transport.gpio_set(self.RXEN, False)
            except Exception:
                pass
            try:
                self._transport.close()
            finally:
                self._transport = None
        self._opened = False

    def __enter__(self):
        return self.open()

    def __exit__(self, *_):
        self.close()
