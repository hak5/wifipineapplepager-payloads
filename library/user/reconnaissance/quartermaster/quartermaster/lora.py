"""The Cap LoRa-1262: its SX1262 radio, found at start, and the mesh settings it listens on.

The radio sits on SPI0 CE1 (/dev/spidev0.1), next to the screen on CE0, with BUSY on GPIO22, DIO1 on GPIO23, reset on
GPIO26, a 3.0 V TCXO on DIO3 and its antenna switch on I2C1 at 0x43. It only runs on the cap's 5 V supply, which is
switched on through the same Rails the GPS uses, so the two never switch it off under each other. The cap cannot be
plugged in while the Cardputer runs, so it is looked for once, when Quartermaster opens.

Only receive is possible: the commands that transmit are not in the list this driver sends.

The driver, the receive settings and the region tables are adapted from LORA Tunnel for the CardputerZero
(Copyright 2026 Valleytech Solutions, MIT), whose tables come from Meshtastic's region and default channel
definitions and MeshCore's regional presets.
"""

from contextlib import ExitStack
from dataclasses import dataclass
import errno
from pathlib import Path
import struct
import threading
import time

from . import power

SPI_DEVICE = Path("/dev/spidev0.1")
MUX = Path("/sys/class/leds/ext_usb_gpio_fun/brightness")
RESET, IRQ, BUSY = 26, 23, 22
EXPANDER = 0x43
IRQ_MASK = 0x0262
BANDWIDTHS = {62500: 0x03, 125000: 0x04, 250000: 0x05, 500000: 0x06}
COMMANDS = frozenset({0x02, 0x08, 0x0D, 0x11, 0x12, 0x13, 0x14, 0x1D, 0x1E, 0x80, 0x82, 0x86, 0x89, 0x8A, 0x8B,
                      0x8C, 0x8F, 0x96, 0x97, 0x98, 0x9D})
POLL = 0.02
BAND_MHZ = (868.0, 923.0)
DWELL_SECONDS = 30.0
MESHTASTIC_SYNC, MESHCORE_SYNC, LORAWAN_SYNC = 0x2B, 0x12, 0x34

CHECKING, FOUND, ABSENT, MISSING, DENIED, BUSY_ELSEWHERE, OFF = (
    "checking", "found", "absent", "missing", "denied", "busy", "off")


class RadioError(RuntimeError):
    pass


@dataclass(frozen=True)
class Profile:
    protocol: str
    label: str
    frequency_hz: int
    bandwidth_hz: int
    spreading_factor: int
    coding_rate: int
    sync_word: int
    preamble_symbols: int

    @property
    def name(self):
        return {"meshtastic": "Meshtastic ", "meshcore": "MeshCore ", "lorawan": "LoRaWAN "}[self.protocol] + self.label

    @property
    def short(self):
        return "%s %.3f MHz" % (self.name, self.frequency_hz / 1e6)

    def fits(self):
        half, mhz = self.bandwidth_hz / 2e6, self.frequency_hz / 1e6
        return mhz - half >= BAND_MHZ[0] - 1e-6 and mhz + half <= BAND_MHZ[1] + 1e-6


# Meshtastic region: (lowest MHz, highest MHz). LongFast: 250 kHz, SF11, CR 4/5.
REGIONS = {"US": (902.0, 928.0), "EU_868": (869.4, 869.65), "ANZ": (915.0, 928.0), "NZ": (915.0, 928.0),
           "JP": (920.5, 923.5), "KR": (920.0, 923.0), "TW": (920.0, 925.0), "IN": (865.0, 867.0),
           "BR_902": (902.0, 907.5)}
REGION_NAMES = {"US": "US 915", "EU_868": "EU 868", "ANZ": "AU 915", "NZ": "NZ 915", "JP": "JP 920", "KR": "KR 920",
                "TW": "TW 920", "IN": "IN 865", "BR_902": "BR 902"}
# MeshCore's default public settings per region, the first of LORA Tunnel's list: (MHz, kHz, SF, CR).
MESHCORE = {"US": (910.525, 62.5, 7, 5), "EU_868": (869.618, 62.5, 8, 8), "ANZ": (915.800, 250, 10, 5),
            "NZ": (917.375, 62.5, 7, 5), "BR_902": (923.125, 62.5, 8, 8)}
# One LoRaWAN uplink channel per region at SF7, the busiest data rate, as SquachWatch lists first: MHz.
LORAWAN = {"US": 903.9, "EU_868": 868.1, "ANZ": 916.8, "NZ": 916.8, "KR": 922.1, "BR_902": 916.8}
EU = ("GB", "DE", "FR", "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "GR", "HU", "IS", "IE", "IT", "LV",
      "LI", "LT", "LU", "MT", "NL", "NO", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "CH")
COUNTRY_REGION = dict({country: "EU_868" for country in EU}, US="US", CA="US", MX="US", AU="ANZ", NZ="NZ",
                      JP="JP", KR="KR", TW="TW", IN="IN", BR="BR_902")


def _djb2(text):
    value = 5381
    for byte in text.encode("ascii"):
        value = (value * 33 + byte) & 0xFFFFFFFF
    return value


def meshtastic(region):
    """The LongFast default channel of a Meshtastic region: the slot its name hashes to."""
    low, high = REGIONS[region]
    slots = int((high - low + 1e-7) // 0.25)
    slot = 1 + _djb2("LongFast") % slots
    mhz = low + (slot - 0.5) * 0.25
    return Profile("meshtastic", "LongFast", int(round(mhz * 1e6)), 250000, 11, 5, MESHTASTIC_SYNC, 16)


def meshcore(region):
    mhz, khz, sf, cr = MESHCORE[region]
    return Profile("meshcore", "Public", int(round(mhz * 1e6)), int(khz * 1000), sf, cr, MESHCORE_SYNC,
                   32 if sf <= 8 else 16)


def lorawan(region):
    return Profile("lorawan", "uplinks", int(round(LORAWAN[region] * 1e6)), 125000, 7, 5, LORAWAN_SYNC, 8)


def plan(country, lorawan_too=False):
    """What the cap listens on in a country, in turn: Meshtastic LongFast, then MeshCore, then LoRaWAN uplinks when
    lorawan_too. Empty without a band."""
    region = COUNTRY_REGION.get(country)
    if region is None:
        return []
    found = [meshtastic(region)] + ([meshcore(region)] if region in MESHCORE else [])
    if lorawan_too and region in LORAWAN:
        found.append(lorawan(region))
    return [profile for profile in found if profile.fits()]


def region_name(country):
    return REGION_NAMES.get(COUNTRY_REGION.get(country), "")


def _set(path, value, stack):
    original = path.read_text().strip()
    if original != value:
        path.write_text(value)
        stack.callback(path.write_text, original)


def _set_p0(bus, register, bit):
    previous = bus.read_byte_data(EXPANDER, register)
    value = (previous & 0xFE) | bit
    if previous != value:
        bus.write_byte_data(EXPANDER, register, value)
    return previous & 1


def _antenna(bus, stack):
    """The PI4IOE5V6408 antenna switch: preload high, make P0 an output, then let go of high impedance."""
    if bus.read_byte_data(EXPANDER, 0x01) >> 5 != 0b101:
        raise RadioError(ABSENT)
    for register, bit in ((0x05, 1), (0x03, 1), (0x07, 0)):
        original = _set_p0(bus, register, bit)
        if original != bit:
            stack.callback(_set_p0, bus, register, original)


class _GpioV1:
    """libgpiod 1.6 (Debian 12)."""

    def __init__(self, gpiod, stack):
        chip = gpiod.Chip("/dev/gpiochip0")
        stack.callback(chip.close)
        self.lines = {}
        for pin in (BUSY, IRQ, RESET):
            line = chip.get_line(pin)
            line.request(consumer="quartermaster", type=gpiod.LINE_REQ_DIR_IN)
            stack.callback(line.release)
            self.lines[pin] = line

    def active(self, pin):
        return bool(self.lines[pin].get_value())

    def pulse_reset(self, stack):
        reset = self.lines[RESET]
        reset.set_direction_output(0)
        stack.callback(reset.set_direction_input)
        time.sleep(0.002)
        reset.set_value(1)


class _GpioV2:
    """libgpiod 2 (Debian 13)."""

    def __init__(self, gpiod, stack):
        self.gpiod = gpiod
        self.inputs = gpiod.LineSettings(direction=gpiod.line.Direction.INPUT)
        self.lines = gpiod.request_lines("/dev/gpiochip0", consumer="quartermaster",
                                         config={(RESET, BUSY, IRQ): self.inputs})
        stack.callback(self.lines.release)

    def active(self, pin):
        return self.lines.get_value(pin) == self.gpiod.line.Value.ACTIVE

    def pulse_reset(self, stack):
        gpiod = self.gpiod
        self.lines.reconfigure_lines({
            RESET: gpiod.LineSettings(direction=gpiod.line.Direction.OUTPUT, output_value=gpiod.line.Value.INACTIVE),
            (BUSY, IRQ): self.inputs,
        })
        stack.callback(self.lines.reconfigure_lines, {(RESET, BUSY, IRQ): self.inputs})
        time.sleep(0.002)
        self.lines.set_value(RESET, gpiod.line.Value.ACTIVE)


def _modules():
    try:
        import gpiod
        import spidev
        try:
            from smbus import SMBus
        except ImportError:
            from smbus2 import SMBus
    except ImportError:
        raise RadioError(MISSING) from None
    return gpiod, spidev, SMBus


class CapRadio:
    """The SX1262 in continuous receive. One thread uses it: the one that opened it."""

    def __init__(self, rails, supply=power.RAILS[0], spi=SPI_DEVICE, mux=MUX):
        self.rails, self.supply, self.spi_path, self.mux = rails, Path(supply), Path(spi), Path(mux)
        self.profile = None
        self.counts = dict(received=0, crc_errors=0, header_errors=0)
        self._resources = None
        self._spi = self._gpio = None

    def open(self, profile=None):
        """Power the cap, wake the radio and check that it answers as an SX1262 in LoRa mode."""
        if self._resources is not None:
            return self
        if not self.spi_path.exists() or not self.supply.is_file():
            raise RadioError(ABSENT)
        gpiod, spidev, SMBus = _modules()
        with ExitStack() as stack:
            try:
                self._gpio = (_GpioV2 if hasattr(gpiod, "request_lines") else _GpioV1)(gpiod, stack)
            except PermissionError:
                raise RadioError(DENIED) from None
            except OSError as exc:
                raise RadioError(BUSY_ELSEWHERE if exc.errno == errno.EBUSY else ABSENT) from None
            try:
                spi = spidev.SpiDev()
                stack.callback(spi.close)
                spi.open(0, 1)
                spi.mode = 0
                spi.max_speed_hz = 1_000_000
            except PermissionError:
                raise RadioError(DENIED) from None
            except OSError:
                raise RadioError(ABSENT) from None
            self.rails.on("lora", [self.supply])
            stack.callback(self.rails.restore, "lora")
            try:
                if self.supply.read_text().strip() == "0":
                    raise RadioError(DENIED)
            except OSError:
                raise RadioError(DENIED) from None
            time.sleep(0.15)
            try:
                bus = SMBus(1)
                stack.callback(bus.close)
                _antenna(bus, stack)
            except PermissionError:
                raise RadioError(DENIED) from None
            except OSError:
                raise RadioError(ABSENT) from None
            if self.mux.exists():
                try:
                    _set(self.mux, "0", stack)
                except OSError:
                    raise RadioError(DENIED) from None
            self._spi = spi
            try:
                self._gpio.pulse_reset(stack)
                time.sleep(0.010)
                self._command(0x80, b"\x00")
                self._command(0x97, b"\x06\x00\x01\x40")
                self._command(0x89, b"\x7f")
                self._command(0x96, b"\x01")
                self._command(0x8A, b"\x01")
                if self._command(0x11, read=1) != b"\x01":
                    raise RadioError(ABSENT)
                stack.callback(self._command, 0x80, b"\x00")
                self._command(0x9D, b"\x01")
                self._command(0x8F, b"\x00\x00")
                if profile is not None:
                    self._tune(profile)
            except OSError:
                raise RadioError(ABSENT) from None
            self._resources = stack.pop_all()
        return self

    def _command(self, opcode, args=b"", read=0):
        if opcode not in COMMANDS:
            raise RadioError("Unsupported radio operation")
        deadline = time.monotonic() + 0.5
        while self._gpio.active(BUSY):
            if time.monotonic() >= deadline:
                raise RadioError(ABSENT)
            time.sleep(0.001)
        data = bytes([opcode]) + args
        if read:
            data += bytes(1 + read)
        result = self._spi.xfer2(list(data))
        if len(result) != len(data):
            raise RadioError(ABSENT)
        return bytes(result[-read:]) if read else b""

    def _read_register(self, address, count=1):
        return self._command(0x1D, struct.pack(">H", address), count)

    def _write_register(self, address, data):
        self._command(0x0D, struct.pack(">H", address) + data)

    def tune(self, profile):
        if self._resources is None:
            raise RadioError("closed")
        self._tune(profile)

    def _tune(self, profile):
        self._command(0x80, b"\x00")
        self._command(0x98, b"\xe1\xe9" if profile.frequency_hz >= 902000000 else b"\xd7\xdb")
        self._command(0x86, struct.pack(">I", (profile.frequency_hz * (1 << 25) + 16000000) // 32000000))
        ldro = (2 ** profile.spreading_factor) / profile.bandwidth_hz > 0.016
        self._command(0x8B, bytes((profile.spreading_factor, BANDWIDTHS[profile.bandwidth_hz],
                                  profile.coding_rate - 4, ldro)))
        sync = bytes(((profile.sync_word & 0xF0) | 4, ((profile.sync_word & 0x0F) << 4) | 4))
        self._write_register(0x0740, sync)
        if self._read_register(0x0740, 2) != sync:
            raise RadioError(ABSENT)
        self._write_register(0x08AC, b"\x96")
        self._write_register(0x0736, bytes([self._read_register(0x0736)[0] | 0x04]))
        self._write_register(0x08D8, bytes([self._read_register(0x08D8)[0] | 0x1E]))
        self.profile = profile
        self._command(0x8C, struct.pack(">HBBBB", profile.preamble_symbols, 0, 255, 1, 0))
        self._command(0x08, struct.pack(">HHHH", IRQ_MASK, IRQ_MASK, 0, 0))
        self._command(0x02, b"\xff\xff")
        self._command(0x82, b"\xff\xff\xff")

    def receive(self, timeout=0.25, wait=None):
        """One packet as (bytes, rssi dBm, snr dB, crc ok), or None when none came in time. wait() returning True
        ends the wait at once."""
        if self._resources is None:
            raise RadioError("closed")
        wait = wait or time.sleep
        deadline = time.monotonic() + timeout
        while not self._gpio.active(IRQ):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            if wait(min(POLL, remaining)):
                return None
        irq = int.from_bytes(self._command(0x12, read=2), "big")
        self._command(0x02, irq.to_bytes(2, "big"))
        if irq & 0x0020:
            self.counts["header_errors"] += 1
        if irq & 0x0040:
            self.counts["crc_errors"] += 1
        if not irq & 0x0002:
            return None
        length, offset = self._command(0x13, read=2)
        if not length:
            return None
        raw = self._command(0x1E, bytes([offset]), length)
        rssi, snr, _ = struct.unpack(">BbB", self._command(0x14, read=3))
        self.counts["received"] += 1
        return raw, -rssi / 2, snr / 4, not irq & 0x0060

    def close(self):
        resources, self._resources = self._resources, None
        if resources is not None:
            resources.close()


WORDS = {CHECKING: "Looking for it", ABSENT: "Not found. Plug it in, then switch on.",
         MISSING: "Parts are missing. Reinstall Quartermaster.", DENIED: "No permission yet. Restart once.",
         BUSY_ELSEWHERE: "In use by another app", OFF: "Off in Settings"}


class Cap:
    """Whether the Cap LoRa-1262 is fitted, looked for once on a thread of its own. Without a cap nothing is
    touched but a file test: the supply, the antenna switch and the radio are only reached when /dev/spidev0.1 is
    there."""

    def __init__(self, rails=None, spi=SPI_DEVICE, supply=power.RAILS[0], mux=MUX, radio=CapRadio, *, cardputer=True):
        self.rails = rails if rails is not None else power.Rails()
        self.spi, self.supply, self.mux, self.radio_class = Path(spi), Path(supply), Path(mux), radio
        self.cardputer = cardputer
        self.state = CHECKING if cardputer else ABSENT
        self._thread = None

    @property
    def found(self):
        return self.state == FOUND

    def start(self, wanted=True):
        if not self.cardputer:
            return
        if not wanted:
            self.state = OFF
            return
        if not self.spi.exists():
            self.state = ABSENT
            return
        if self._thread is None:
            self._thread = threading.Thread(target=self.look, daemon=True, name="lora-cap")
            self._thread.start()

    def look(self):
        """The answer is given only once the radio is let go, so a listener started on it finds the lines free."""
        radio, result = self.radio(), ABSENT
        try:
            radio.open()
            result = FOUND
        except RadioError as exc:
            result = str(exc) if str(exc) in WORDS else ABSENT
        except Exception:
            result = ABSENT
        finally:
            try:
                radio.close()
            except Exception:
                pass
        self.state = result

    def wait(self, seconds):
        if self._thread is not None:
            self._thread.join(seconds)

    def radio(self):
        if not self.cardputer:
            raise RadioError(ABSENT)
        return self.radio_class(self.rails, self.supply, self.spi, self.mux)
