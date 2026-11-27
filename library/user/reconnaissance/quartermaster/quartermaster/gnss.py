"""Receiver position from any GPS: a USB dongle, the Cap LoRa-1262, a Grove GPS unit, or gpsd.

Ports are probed automatically: a port counts as GPS once it sends a
checksum-valid NMEA sentence.
"""

from datetime import datetime, timezone
import json
import math
import re
import socket
import threading
import time

from . import faults, hardware

UART_BAUDS = (115200, 9600, 38400, 460800)
STALE_SECONDS = 10
WAKE_SECONDS = 1.5
_USB_PORT = re.compile(r"tty(USB|ACM)\d+$")


def _coordinate(value, hemisphere, degrees):
    if hemisphere not in (("N", "S") if degrees == 2 else ("E", "W")):
        raise ValueError("Invalid coordinate hemisphere")
    if not re.fullmatch(rf"[0-9]{{{degrees + 2}}}(?:\.[0-9]+)?", value):
        raise ValueError("Invalid coordinate")
    minutes = float(value[degrees:])
    coordinate = int(value[:degrees]) + minutes / 60
    if minutes >= 60 or coordinate > (90 if degrees == 2 else 180):
        raise ValueError("Coordinate outside bounds")
    return -coordinate if hemisphere in ("S", "W") else coordinate


def nmea_fix(line):
    """Return a gpsd-style report for checksum-valid GGA/RMC sentences, else None."""
    if not line or len(line) > 128 or not line.startswith(b"$"):
        return None
    body, sep, expected = line[1:].rstrip(b"\r\n").partition(b"*")
    if not sep or not re.fullmatch(b"[0-9a-fA-F]{2}", expected):
        return None
    checksum = 0
    for byte in body:
        checksum ^= byte
    if checksum != int(expected, 16):
        return None
    try:
        fields = body.decode("ascii").split(",")
        if not re.fullmatch(r"G[A-Z](GGA|RMC)", fields[0]):
            return None
        result = {"class": "TPV", "mode": 1}
        if fields[0].endswith("RMC"):
            if fields[2] != "A":
                return result
            lat, ns, lon, ew = fields[3:7]
            clock = fields[1].split(".")[0]
            if re.fullmatch(r"[0-9]{6}", fields[9]) and re.fullmatch(r"[0-9]{6}", clock):
                utc = datetime.strptime(fields[9] + clock, "%d%m%y%H%M%S")
                result["time"] = utc.replace(tzinfo=timezone.utc).isoformat()
            if fields[7]:
                knots = float(fields[7])
                if math.isfinite(knots):
                    result["speed"] = knots * 0.514444
        else:
            if fields[7].isdigit():
                result["satellites"] = int(fields[7])
            if fields[8]:
                hdop = float(fields[8])
                if math.isfinite(hdop):
                    result["hdop"] = hdop
            if fields[6] not in {"1", "2", "3", "4", "5"}:
                return result
            lat, ns, lon, ew = fields[2:6]
            if fields[9] and fields[10] == "M":
                altitude = float(fields[9])
                if math.isfinite(altitude):
                    result["altMSL"] = altitude
        result.update(mode=2, lat=_coordinate(lat, ns, 2), lon=_coordinate(lon, ew, 3))
        return result
    except (ValueError, IndexError, UnicodeError):
        return None


def _mark_gpsd(message):
    """The ports where gpsd found a GPS are GPS ports: nothing else may write to them.

    gpsd says DEVICE as soon as it opens a port, which its hotplug rules do for any CP210x, before it knows what is
    there. Only a port with a driver, or one that gave a fix, is a GPS, and a port known to be a node stays one."""
    devices = message.get("devices") if message.get("class") == "DEVICES" else [message]
    for device in devices if isinstance(devices, list) else ():
        if not isinstance(device, dict):
            continue
        path = device.get("path") or device.get("device")
        found = bool(device.get("driver")) and device.get("activated") != 0 or \
            message.get("class") == "TPV" and device.get("mode") in (2, 3)
        if found and isinstance(path, str) and path.startswith("/") and hardware.port_mark(path) not in ("gps",
                                                                                                         "node"):
            hardware.mark_port(path, "gps")


class GPS:
    """Thread-safe latest fix with explicit freshness."""

    def __init__(self, source="auto", candidates=None, rails=None, power=True):
        """source: "auto", "gpsd", "off" or a serial port path. candidates() lists ports to probe.

        rails switches on the cap and Grove supplies before a port that is not USB is tried."""
        self.mode = source
        self.candidates = candidates
        self.rails = rails
        self.power = power
        self.source = "none"
        self.port = None
        self._fix = {}
        self._extra = {}
        self._updated = 0.0
        self._told = None
        self._lock = threading.Lock()

    def update(self, value, now=None):
        if value.get("class") != "TPV":
            return
        now = time.monotonic() if now is None else now
        with self._lock:
            for key in ("satellites", "hdop"):
                if key in value:
                    self._extra[key] = value[key]
        mode = value.get("mode", 0)
        # gpsd and NMEA can split an epoch. A partial report must not erase a
        # real fix or refresh its age.
        if type(mode) is int and mode in (2, 3) and not {"lat", "lon"} <= value.keys():
            return
        fix = {"mode": mode if type(mode) is int and mode in (0, 1, 2, 3) else 0, "valid": False}
        lat, lon = value.get("lat"), value.get("lon")
        if (fix["mode"] in (2, 3) and type(lat) in (float, int) and type(lon) in (float, int)
                and math.isfinite(lat) and math.isfinite(lon) and -90 <= lat <= 90 and -180 <= lon <= 180):
            fix.update(valid=True, latitude=lat, longitude=lon)
            for key in ("altHAE", "altMSL", "epx", "epy", "epv", "speed"):
                item = value.get(key)
                if isinstance(item, (int, float)) and math.isfinite(item):
                    fix[key] = item
            if isinstance(value.get("time"), str):
                fix["utc"] = value["time"][:64]
        with self._lock:
            self._fix, self._updated = fix, now
            if "utc" in fix:
                self._told = (fix["utc"], now)

    def told(self):
        """The UTC time of the last fix that carried one and the monotonic time it came at, or None. It stays after
        the fix is lost: the CardputerZero has no battery clock, so this is the best time it has."""
        with self._lock:
            return self._told

    def snapshot(self, now=None):
        now = time.monotonic() if now is None else now
        with self._lock:
            fix = dict(self._fix)
            fix.update(self._extra)
            age = max(0.0, now - self._updated) if self._updated else None
        fix["age_seconds"] = age
        fix["valid"] = bool(fix.get("valid") and age is not None and age <= STALE_SECONDS)
        fix["status"] = "fix" if fix["valid"] else ("stale" if age is not None and age > STALE_SECONDS else "no_fix")
        fix["source"] = self.source
        if not fix["valid"]:
            for key in ("latitude", "longitude", "utc", "altHAE", "altMSL", "speed"):
                fix.pop(key, None)
        return fix

    def run(self, stopped):
        try:
            while not stopped.is_set():
                try:
                    if self._search(stopped):
                        continue
                except Exception:
                    faults.note("GPS")
                stopped.wait(2)
        finally:
            self.unpower()

    def _search(self, stopped):
        """One round of looking for a receiver. True when a gpsd session just ended and is worth trying again."""
        if not self.power or self.mode in ("off", "gpsd") or _USB_PORT.search(self.mode):
            self.unpower()
        if self.mode == "off":
            return False
        if self.mode in ("auto", "gpsd") and self._gpsd(stopped):
            return True
        if self.mode != "gpsd" and not stopped.is_set():
            self._serial(stopped)
        return False

    def unpower(self):
        if self.rails is not None:
            self.rails.restore("gps")

    def _ports(self):
        if self.mode not in ("auto", "gpsd", "off"):
            return [{"path": self.mode, "label": "Custom port"}]
        if self.candidates is None:
            from .hardware import gps_candidates
            return gps_candidates()
        return self.candidates()

    def _gpsd(self, stopped):
        """Return True after a working gpsd session ends, False when unavailable."""
        try:
            with socket.create_connection(("127.0.0.1", 2947), 1) as sock:
                sock.settimeout(1)
                sock.sendall(b'?WATCH={"enable":true,"json":true};\n')
                buffer, deadline, working, mode = b"", time.monotonic() + 5, False, self.mode
                while not stopped.is_set() and self.mode == mode:
                    try:
                        part = sock.recv(8192)
                    except socket.timeout:
                        if not working and time.monotonic() >= deadline:
                            return False
                        continue
                    if not part:
                        return working
                    buffer += part
                    if len(buffer) > 65536:
                        return working
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        try:
                            message = json.loads(line)
                        except ValueError:
                            continue
                        if not isinstance(message, dict):
                            continue
                        if message.get("class") == "DEVICES" and message.get("devices") == []:
                            return False
                        if message.get("class") in ("DEVICES", "DEVICE", "TPV"):
                            _mark_gpsd(message)
                        if message.get("class") == "SKY":
                            used = [s for s in message.get("satellites", []) if isinstance(s, dict) and s.get("used")]
                            with self._lock:
                                self._extra["satellites"] = len(used)
                        if message.get("class") == "TPV":
                            working = True
                            self.source = "gpsd"
                            self.update(message)
        except OSError:
            return False
        finally:
            if self.source == "gpsd":
                self.source = "none"
        return False

    def _serial(self, stopped):
        try:
            import serial
        except ImportError:
            return
        mode = self.mode
        for candidate in self._ports():
            path = candidate["path"]
            if hardware.port_mark(path) == "node" or not hardware.hold_port(path, "gps"):
                continue
            try:
                if self._try(serial, candidate, mode, stopped):
                    return
            finally:
                hardware.let_go_port(path, "gps")
            if stopped.is_set() or self.mode != mode:
                return

    def _try(self, serial, candidate, mode, stopped):
        """Read one port at each speed in turn. True once a receiver that answered there has gone quiet."""
        path = candidate["path"]
        usb = bool(_USB_PORT.search(path))
        if not usb and self.power and self.rails is not None and self.rails.on():
            stopped.wait(WAKE_SECONDS)
        for baud in UART_BAUDS:
            if stopped.is_set() or self.mode != mode:
                return False
            try:
                with serial.Serial(path, baud, timeout=0.5, exclusive=True) as port:
                    valid_until = time.monotonic() + 3
                    seen = False
                    while not stopped.is_set() and self.mode == mode:
                        report = nmea_fix(port.read_until(b"\n", size=129))
                        if report is not None:
                            if not seen:
                                hardware.mark_port(path, "gps")
                                if usb:
                                    self.unpower()
                            seen = True
                            self.source = "%s (%s)" % (candidate.get("label", "GPS"), path)
                            self.port = path
                            self.update(report)
                        elif not seen and time.monotonic() > valid_until:
                            break  # wrong baud or not a GPS: try the next
                        elif seen and time.monotonic() - self._updated > 15:
                            hardware.mark_port(path, None)
                            break  # receiver unplugged or silent: probe again
                    if seen:
                        self.port, self.source = None, "none"
                        return True
            except (OSError, ValueError):
                return False  # port busy or gone: next candidate
        if hardware.port_mark(path) is None:
            hardware.mark_port(path, "checked")
        return False
