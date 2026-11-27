"""Aircraft from an RTL-SDR stick, for WDGWars and Wardrift. WiGLE takes no aircraft.

The radio is read by a program of its own, never inside Quartermaster. A readsb or dump1090 the system already runs
is used when its aircraft.json in /run is fresh. Otherwise rtl_adsb, from the rtl-sdr package Quartermaster depends
on, is started for the wardrive and stopped with it: it prints each frame it hears as hex, and modes.py decodes them.
A readsb built with RTL-SDR support is started instead only when rtl_adsb is not installed.

Either way the aircraft reach the same store, as readsb's aircraft.json lists them, and one record is kept per
aircraft with the closest and the furthest position heard from it. At the stop that becomes a dump1090
aircraft.json.gz beside the WiGLE log, and a summary with both positions.
"""

import atexit
import csv
import gzip
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import threading
import time

from . import faults, hardware, modes, wigle

POLL_SECONDS = 5.0
JOURNAL_SECONDS = 30.0
STALE_SECONDS = 30.0
RETRY_SECONDS = 30.0
STOP_WAIT = 3.0
RETIME_SECONDS = 2.0
MAX_KM = 600.0
EARTH_KM = 6371.0088
WARDRIFT_BATCH = 5000
CREDIT_SECONDS = 72 * 3600
FILE_GLOB = "quartermaster_*.aircraft.json.gz"
JOURNAL_GLOB = ".quartermaster_*.aircraft.json.part"
SYSTEM_FEEDS = (Path("/run/readsb/aircraft.json"), Path("/run/adsb/aircraft.json"),
                Path("/run/dump1090-fa/aircraft.json"), Path("/run/dump1090-mutability/aircraft.json"))
READSB_PATHS = ("/usr/bin/readsb", "/usr/local/bin/readsb")
RTL_ADSB_PATHS = ("/usr/bin/rtl_adsb", "/usr/local/bin/rtl_adsb")
MAX_FRAMES = 2000
READ_PAUSE = 0.05
MAX_LINE = 80
SUMMARY_COLUMNS = ("ICAO", "Callsign", "Squawk", "Category", "FirstSeen", "LastSeen", "StrongestRSSI",
                   "WeakestRSSI", "ClosestKm", "ClosestLatitude", "ClosestLongitude", "ClosestAltitudeFt",
                   "ClosestSpeedKt", "ClosestTrack", "ClosestTime", "FurthestKm", "FurthestLatitude",
                   "FurthestLongitude", "FurthestAltitudeFt", "FurthestSpeedKt", "FurthestTrack", "FurthestTime")
HOLDERS = ("readsb", "dump1090", "rtl_")
DRIVER_WORDS = ("kernel driver is active",)
BUSY_WORDS = ("usb_claim_interface", "resource busy", "error -6")
GONE_WORDS = ("no supported devices", "no rtl-sdr", "device not found")
DENIED_WORDS = ("usb_open error -3", "access denied", "insufficient permissions")
NO_RTLSDR_WORDS = ("not recognized", "not enabled in this build")

OFF, NO_DONGLE, NO_TOOLS, BUSY, RUNNING, SYSTEM, FAILED, READY, DENIED, DRIVER = (
    "off", "no_dongle", "no_tools", "busy", "running", "system", "failed", "ready", "denied", "driver")
WORDS = {OFF: "Off in Settings", NO_DONGLE: "Not plugged in", NO_TOOLS: "rtl-sdr is missing. Reinstall Quartermaster",
         BUSY: "In use by another program", RUNNING: "Running", SYSTEM: "Uses the aircraft program that already runs",
         FAILED: "It stopped. Trying again soon.", READY: "Ready. It listens in the next wardrive.",
         DENIED: "No permission yet. Restart the Cardputer once.", DRIVER: "Restart the Cardputer once to use it"}

_HEX = re.compile(r"[0-9a-f]{6}")
_NAME = re.compile(r"quartermaster_\d{8}-\d{6}(-\d+)?\.aircraft\.json\.gz")
_help = {}
_no_rtlsdr = set()
_children = set()
_children_lock = threading.Lock()


def is_aircraft(path):
    return str(path).endswith(".aircraft.json.gz")


def file_for(log):
    """The aircraft file that goes with a WiGLE log."""
    log = Path(log)
    return log.with_name(log.name.replace(".wigle.csv", ".aircraft.json.gz"))


def summary_path(path):
    path = Path(path)
    return path.with_name(path.name.replace(".aircraft.json.gz", ".aircraft.csv"))


def journal_path(path):
    path = Path(path)
    return path.with_name("." + path.name.replace(".json.gz", ".json.part"))


def _find(name, paths, which):
    found = which(name)
    if found:
        return found
    return next((path for path in paths if os.access(path, os.X_OK)), "")


def find_readsb(which=shutil.which):
    return _find("readsb", READSB_PATHS, which)


def find_rtl_adsb(which=shutil.which):
    return _find("rtl_adsb", RTL_ADSB_PATHS, which)


def find_decoder(which=shutil.which, runner=subprocess.run):
    """The program a wardrive would start for the stick: rtl_adsb, else a readsb that can open it, else ""."""
    found = find_rtl_adsb(which)
    if found:
        return found
    readsb = find_readsb(which)
    return readsb if readsb and reads_rtlsdr(readsb, runner) else ""


def distance_km(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * EARTH_KM * math.asin(min(1.0, math.sqrt(a)))


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) \
        else None


def _text(value, limit):
    return value.strip()[:limit] if isinstance(value, str) else ""


class Plane:
    """One aircraft: when it was heard, what it said, its signal and its closest and furthest position.

    A position is (km from the receiver or None, lat, lon, altitude, ground speed, track, epoch)."""

    __slots__ = ("hex", "flight", "squawk", "category", "first", "last", "strongest", "weakest", "alt", "near",
                 "far")

    def __init__(self, code, when):
        self.hex, self.flight, self.squawk, self.category = code, "", "", ""
        self.first = self.last = when
        self.strongest = self.weakest = self.alt = self.near = self.far = None

    def heard(self, when, report):
        self.first, self.last = min(self.first, when), max(self.last, when)
        flight, squawk, category = report.get("flight"), report.get("squawk"), report.get("category")
        if flight:
            self.flight = _text(flight, 8) or self.flight
        if squawk:
            self.squawk = _text(squawk, 4) or self.squawk
        if category:
            self.category = _text(category, 2) or self.category
        rssi = _number(report.get("rssi"))
        if rssi is not None:
            self.strongest = rssi if self.strongest is None else max(self.strongest, rssi)
            self.weakest = rssi if self.weakest is None else min(self.weakest, rssi)
        alt = report.get("alt_baro")
        if _number(alt) is not None or alt == "ground":
            self.alt = alt

    def place(self, point):
        km, near, far = point[0], self.near, self.far
        if near is None or km is not None and (near[0] is None or km < near[0]):
            self.near = point
        if far is None or km is not None and (far[0] is None or km > far[0]):
            self.far = point

    def dump(self):
        return [self.hex, self.flight, self.squawk, self.category, self.first, self.last, self.strongest,
                self.weakest, self.alt, self.near and list(self.near), self.far and list(self.far)]

    @classmethod
    def restore(cls, row):
        code, flight, squawk, category, first, last, strongest, weakest, alt, near, far = row
        if not isinstance(code, str) or not _HEX.fullmatch(code) or _number(first) is None or _number(last) is None:
            raise ValueError(code)
        plane = cls(code, first)
        plane.last, plane.flight, plane.squawk = last, _text(flight, 8), _text(squawk, 4)
        plane.category, plane.strongest, plane.weakest = _text(category, 2), _number(strongest), _number(weakest)
        plane.alt = alt if _number(alt) is not None or alt == "ground" else None
        plane.near, plane.far = _point(near), _point(far)
        return plane

    def entry(self, now):
        """This aircraft at its closest position, in dump1090 shape, with seen and seen_pos counted back from now."""
        out = {"hex": self.hex}
        if self.flight:
            out["flight"] = self.flight
        near = self.near
        if near is not None:
            out.update(lat=round(near[1], 6), lon=round(near[2], 6))
            for key, value in zip(("alt_baro", "gs", "track"), near[3:6]):
                if value is not None:
                    out[key] = value
        elif self.alt is not None:
            out["alt_baro"] = self.alt
        if self.squawk:
            out["squawk"] = self.squawk
        if self.category:
            out["category"] = self.category
        if self.strongest is not None:
            out["rssi"] = round(self.strongest, 1)
        out["seen"] = round(max(0.0, now - self.last), 1)
        if near is not None:
            out["seen_pos"] = round(max(0.0, now - near[6]), 1)
        return out

    def summary_row(self):
        return [self.hex, self.flight, self.squawk, self.category, _utc(self.first), _utc(self.last),
                _rssi(self.strongest), _rssi(self.weakest), *_summary_point(self.near), *_summary_point(self.far)]


def _point(value):
    if value is None:
        return None
    km, lat, lon, alt, gs, track, when = value
    if _number(lat) is None or _number(lon) is None or _number(when) is None:
        raise ValueError(value)
    return (_number(km), lat, lon, alt if _number(alt) is not None or alt == "ground" else None, _number(gs),
            _number(track), when)


def _utc(epoch):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(epoch)) if epoch else ""


def _rssi(value):
    return "" if value is None else "%.1f" % value


def _summary_point(point):
    if point is None:
        return [""] * 7
    km, lat, lon, alt, gs, track, when = point
    return ["" if km is None else "%.2f" % km, "%.6f" % lat, "%.6f" % lon, "" if alt is None else alt,
            "" if gs is None else gs, "" if track is None else track, _utc(when)]


class Sky:
    """Every aircraft of one wardrive, by ICAO address."""

    def __init__(self):
        self.planes = {}
        self.changed = False

    def __len__(self):
        return len(self.planes)

    def update(self, data, epoch, here=None):
        """Take one aircraft.json. epoch is the UTC time it was written, here the receiver's (lat, lon) or None."""
        reports = data.get("aircraft") if isinstance(data, dict) else None
        if not isinstance(reports, list):
            return 0
        planes, taken = self.planes, 0
        for report in reports:
            if not isinstance(report, dict):
                continue
            code = report.get("hex")
            if not isinstance(code, str) or len(code) != 6:
                continue
            code = code.lower()
            if not _HEX.fullmatch(code):
                continue
            if "alt_baro" not in report and "altitude" in report or "gs" not in report and "speed" in report:
                report = dict(report, alt_baro=report.get("alt_baro", report.get("altitude")),
                              gs=report.get("gs", report.get("speed")))
            seen = _number(report.get("seen"))
            plane = planes.get(code)
            when = epoch - max(0.0, seen or 0.0)
            if plane is None:
                plane = planes[code] = Plane(code, when)
            plane.heard(when, report)
            taken += 1
            lat, lon = _number(report.get("lat")), _number(report.get("lon"))
            if lat is None or lon is None or abs(lat) > 90 or abs(lon) > 180 or (abs(lat) < 1e-6 and abs(lon) < 1e-6):
                continue
            km = None
            if here is not None:
                km = distance_km(here[0], here[1], lat, lon)
                if km > MAX_KM:
                    continue
            alt = report.get("alt_baro")
            seen_pos = _number(report.get("seen_pos"))
            plane.place((km, lat, lon, alt if _number(alt) is not None or alt == "ground" else None,
                         _number(report.get("gs")), _number(report.get("track")),
                         epoch - max(0.0, seen_pos if seen_pos is not None else seen or 0.0)))
        if taken:
            self.changed = True
        return taken

    def shift(self, delta):
        """Move every time by delta seconds: the times were the system clock's, and the GPS has told the real one."""
        for plane in self.planes.values():
            plane.first, plane.last = plane.first + delta, plane.last + delta
            plane.near = plane.near and plane.near[:6] + (plane.near[6] + delta,)
            plane.far = plane.far and plane.far[:6] + (plane.far[6] + delta,)
        self.changed = self.changed or bool(self.planes)

    def dump(self, name, now):
        return {"name": name, "now": now, "aircraft": [plane.dump() for plane in self.planes.values()]}

    @classmethod
    def restore(cls, data):
        sky = cls()
        for row in data.get("aircraft") or ():
            try:
                plane = Plane.restore(row)
            except (TypeError, ValueError):
                continue
            sky.planes[plane.hex] = plane
        return sky

    def document(self, now):
        return {"now": now, "messages": 0,
                "aircraft": [self.planes[code].entry(now) for code in sorted(self.planes)]}


def _replace(path, write):
    """Write a file under a hidden name, put it on disk and only then give it its name."""
    tmp = path.with_name(("" if path.name.startswith(".") else ".") + path.name + ".tmp")
    try:
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as out:
            write(out)
            out.flush()
            wigle.fsync(out.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def settle(folder):
    try:
        fd = os.open(str(folder), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write(path, sky, now):
    """The aircraft file and its summary. Nothing is written for a wardrive that heard no aircraft."""
    if not len(sky):
        return False
    path = Path(path)
    text = json.dumps(sky.document(now), separators=(",", ":")).encode("utf-8")

    def packed(out):
        with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=int(now)) as zipped:
            zipped.write(text)

    def table(out):
        lines = io.StringIO()
        rows = csv.writer(lines, lineterminator="\n")
        rows.writerow(SUMMARY_COLUMNS)
        rows.writerows(sky.planes[code].summary_row() for code in sorted(sky.planes))
        out.write(lines.getvalue().encode("utf-8"))
    _replace(summary_path(path), table)
    _replace(path, packed)
    settle(path.parent)
    return True


def save_journal(journal, sky, name, now):
    data = json.dumps(sky.dump(name, now), separators=(",", ":")).encode("utf-8")
    _replace(Path(journal), lambda out: out.write(data))
    sky.changed = False


def recover(logs):
    """Finish the aircraft files of a wardrive that a crash or a power cut ended. Returns the files written."""
    logs, done = Path(logs), []
    for journal in sorted(logs.glob(JOURNAL_GLOB)):
        try:
            data = json.loads(journal.read_text(encoding="utf-8"))
            name = data.get("name")
            if not isinstance(name, str) or not _NAME.fullmatch(name):
                name = journal.name[1:].replace(".json.part", ".json.gz")
            target = logs / name
            if not target.exists() and _number(data.get("now")) is not None:
                if write(target, Sky.restore(data), data["now"]):
                    done.append(target)
        except OSError:
            faults.note("Finishing an earlier aircraft log")
            continue
        except (ValueError, AttributeError):
            pass
        try:
            journal.unlink(missing_ok=True)
        except OSError:
            pass
    for leftover in logs.glob(".quartermaster_*.aircraft.*.tmp"):
        try:
            leftover.unlink(missing_ok=True)
        except OSError:
            pass
    return done


def load(path):
    with gzip.open(path, "rb") as source:
        data = json.loads(source.read(64 * 1024 * 1024).decode("utf-8"))
    if not isinstance(data, dict) or _number(data.get("now")) is None or not isinstance(data.get("aircraft"), list):
        raise ValueError("not an aircraft file")
    return data


def rebased(data, now):
    """The aircraft of a file with seen and seen_pos counted back from now instead of from the file's own time."""
    shift = now - data["now"]
    out = []
    for item in data["aircraft"]:
        if not isinstance(item, dict):
            continue
        item = dict(item)
        for key in ("seen", "seen_pos"):
            if _number(item.get(key)) is not None:
                item[key] = round(item[key] + shift, 1)
        out.append(item)
    return out


def batches(data, now, size=None):
    """Wardrift's bodies for a file: gzipped {"now", "aircraft"} with at most WARDRIFT_BATCH aircraft each."""
    planes, size = rebased(data, now), size or WARDRIFT_BATCH
    for start in range(0, len(planes), size):
        text = json.dumps({"now": now, "aircraft": planes[start:start + size]}, separators=(",", ":"))
        yield gzip.compress(text.encode("utf-8"), mtime=int(now))


def part_name(name, part):
    """The name each part of a file is sent under: the file's own for the first, numbered after that."""
    return name if part == 1 else name.replace(".aircraft.json.gz", "-part%d.aircraft.json.gz" % part)


def read_feed(path, now):
    """A readsb or dump1090 aircraft.json written in the last STALE_SECONDS, or None."""
    try:
        with open(path, "rb") as source:
            data = json.loads(source.read(16 * 1024 * 1024).decode("utf-8", "replace"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or _number(data.get("now")) is None or now - data["now"] > STALE_SECONDS:
        return None
    return data


def system_feed(feeds=SYSTEM_FEEDS, now=None):
    """The aircraft.json of a readsb or dump1090 the system already runs, when it is fresh."""
    now = time.time() if now is None else now
    return next((Path(path) for path in feeds if read_feed(path, now) is not None), None)


def in_use(feeds=SYSTEM_FEEDS, proc=Path("/proc"), now=None, me=None):
    """Between wardrives: SYSTEM when a readsb or dump1090 the system runs writes fresh output, BUSY when another
    program that takes the stick runs, else "". What Quartermaster started itself does not count."""
    if system_feed(feeds, now) is not None:
        return SYSTEM
    me = os.getpid() if me is None else me
    try:
        entries = [entry for entry in os.scandir(proc) if entry.name.isdigit()]
    except OSError:
        return ""
    for entry in entries:
        try:
            with open(os.path.join(entry.path, "stat"), "rb") as stat:
                text = stat.read(512).decode("utf-8", "replace")
            name, rest = text[text.index("(") + 1:text.rindex(")")], text[text.rindex(")") + 1:].split()
            if name.startswith(HOLDERS) and int(rest[1]) != me:
                return BUSY
        except (OSError, ValueError, IndexError):
            continue
    return ""


def _usage(binary, runner):
    """readsb's --help, asked once per binary."""
    if binary not in _help:
        try:
            result = runner([binary, "--help"], capture_output=True, text=True, errors="replace", timeout=10,
                            check=False)
            _help[binary] = (result.stdout or "") + (result.stderr or "")
        except (OSError, subprocess.SubprocessError):
            _help[binary] = ""
    return _help[binary]


def reads_rtlsdr(binary, runner=subprocess.run):
    """Whether a readsb was built with RTL-SDR support: its --help then lists the RTL-SDR options, and a start
    that said otherwise is remembered."""
    if binary in _no_rtlsdr:
        return False
    text = _usage(binary, runner).lower()
    return "rtl-sdr options" in text or "--device-type rtlsdr" in text


def options(binary, runner=subprocess.run):
    """Flags that lighten readsb's load, only those its --help lists."""
    _usage(binary, runner)
    extra = []
    entry = re.search(r"--preamble-threshold\S*(.*?)(?=\n\s*-|\Z)", _help[binary], re.S)
    match = entry and re.search(r"pi zero[^:]*:\s*(\d+)", entry.group(1), re.I)
    if match:
        extra += ["--preamble-threshold", match.group(1)]
    return extra


def rtl_command(binary, prefix=()):
    return list(prefix) + [binary, "-d", "0", "-S"]


def command(binary, out, here=None, extra=(), prefix=()):
    argv = list(prefix) + [binary, "--device-type", "rtlsdr", "--gain", "auto", "--quiet", "--write-json", str(out),
                           "--write-json-every", "5", "--max-range", "300"]
    if here is not None:
        argv += ["--lat", "%.4f" % here[0], "--lon", "%.4f" % here[1]]
    return argv + list(extra)


def run_dir():
    base = os.environ.get("XDG_RUNTIME_DIR")
    if base and os.path.isdir(base):
        return Path(base) / "quartermaster-adsb"
    return Path("/tmp") / ("quartermaster-adsb-%d" % os.getuid())


def _own_dir(path):
    """A folder for the decoder's output that only this user can write, never a link someone else left."""
    path = Path(path)
    try:
        path.mkdir(mode=0o700, exist_ok=True)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if not os.path.isdir(path) or os.path.islink(path) or info.st_uid != os.getuid():
        raise OSError("The folder %s cannot be used" % path)
    os.chmod(path, 0o700)
    return path


def calm(cpu, which=shutil.which):
    """The programs the decoder is started through, each of them only when it is there: setpriv ends it when the
    thread that started it ends, even when Quartermaster is killed; nice lowers its priority; taskset keeps it on one
    CPU. No Python runs between the fork and the decoder, so the threads Quartermaster runs cannot hang the start."""
    prefix = []
    for tool, args in (("setpriv", ["--pdeathsig", "TERM"]), ("nice", ["-n", "10"]),
                       ("taskset", ["-c", str(cpu)] if cpu is not None else None)):
        found = which(tool) if args is not None else None
        if found:
            prefix += [found] + args
    return prefix


def end(proc, kill=None, wait=STOP_WAIT):
    """Stop the decoder and everything it started: SIGTERM, then SIGKILL after `wait` seconds."""
    kill = kill or os.killpg
    with _children_lock:
        _children.discard(proc)
    if proc.poll() is not None:
        return
    for sig, seconds in ((signal.SIGTERM, wait), (signal.SIGKILL, 1.0)):
        try:
            kill(proc.pid, sig)
        except ProcessLookupError:
            return
        except OSError:
            (proc.terminate if sig == signal.SIGTERM else proc.kill)()
        try:
            proc.wait(seconds)
            return
        except subprocess.TimeoutExpired:
            continue


def end_all():
    """What Quartermaster started is never left running when it closes, however it closes."""
    with _children_lock:
        left = list(_children)
    for proc in left:
        try:
            end(proc, wait=1.0)
        except Exception:
            pass


atexit.register(end_all)


def listen(stream, decoder, lock, mono=None, limit=MAX_FRAMES, pause=READ_PAUSE, read=os.read, tap=None):
    """Give each line rtl_adsb prints to the decoder until it ends. rtl_adsb writes each frame in many small pieces,
    so the pipe is read in large chunks, `pause` seconds apart, instead of waking for each piece. Past `limit` lines in
    one second the rest of that second are dropped unread by the decoder, so a flood of noise never queues up.
    tap(lines, now) is handed the same lines after the decoder had them."""
    mono = mono or time.monotonic
    fd, left, second, count = stream.fileno(), b"", None, 0
    while True:
        chunk = read(fd, 65536)
        if not chunk:
            return
        lines = (left + chunk).split(b"\n")
        left = lines.pop()
        if len(left) > MAX_LINE:
            left = b""
            decoder.dropped += 1
        now = mono()
        if second is None or now - second >= 1.0:
            second, count = now, 0
        take = lines[:max(0, limit - count)]
        count += len(lines)
        decoder.dropped += len(lines) - len(take)
        with lock:
            for raw in take:
                decoder.line(raw, now)
        if tap is not None and take:
            tap(take, now)
        time.sleep(pause)


def stopped_state(said, plugged):
    """Why a decoder that ended by itself did, from what it said last."""
    return DRIVER if any(w in said for w in DRIVER_WORDS) else \
        BUSY if any(w in said for w in BUSY_WORDS) else \
        DENIED if any(w in said for w in DENIED_WORDS) else \
        NO_DONGLE if any(w in said for w in GONE_WORDS) or not plugged else FAILED


def _tail(path, size=4096):
    try:
        with open(path, "rb") as log:
            log.seek(max(0, log.seek(0, os.SEEK_END) - size))
            return log.read().decode("utf-8", "replace").lower()
    except OSError:
        return ""


class Receiver:
    """The aircraft side of one wardrive. Everything slow happens on its own thread."""

    def __init__(self, logs, gps, clock=time.time, log=None, launcher=subprocess.Popen, which=shutil.which,
                 dongles=hardware.rtl_sdr_dongles, feeds=SYSTEM_FEEDS, out=None, cpus=os.cpu_count,
                 runner=subprocess.run, kill=None, poll=POLL_SECONDS, max_hdop=None, epoch=None, tools=shutil.which,
                 mono=None, gate=None):
        self.logs, self.gps, self.clock, self.log = Path(logs), gps, clock, log or (lambda: None)
        self.gate = gate or (lambda: True)
        self.epoch = epoch or (lambda fix: self.clock())
        self.launcher, self.which, self.dongles, self.feeds = launcher, which, dongles, feeds
        self.out, self.cpus, self.runner, self.kill, self.poll = out, cpus, runner, kill, poll
        self.max_hdop, self.tools = max_hdop, tools
        self.mono = mono or (lambda: time.monotonic())
        self.sky = Sky()
        self.state, self.proc, self.feed = RUNNING, None, None
        self.decoder = self._listener = self._said = self._binary = None
        self._decoding = threading.Lock()
        self.tap = None
        self.target = self.journal = self.started = None
        self._journaled = self._failed_at = None
        self._last, self._blind = None, False
        self._offset = self._shut = None
        self._stop = threading.Event()
        self._thread = None
        self._lock = threading.Lock()

    @property
    def count(self):
        return len(self.sky)

    def status(self):
        return {"state": self.state, "aircraft": len(self.sky), "detail": WORDS.get(self.state, "")}

    def prepare(self, epoch):
        """Name the file after the wardrive's start, for a wardrive that ends without a WiGLE log."""
        serial = 0
        while True:
            name = wigle.log_filename(epoch, serial).replace(".wigle.csv", ".aircraft.json.gz")
            target = self.logs / name
            if not target.exists() and not journal_path(target).exists():
                break
            serial += 1
        self.target, self.journal, self.started = target, journal_path(target), epoch
        self._journaled = time.monotonic()

    def start(self, epoch):
        self.prepare(epoch)
        fix = self.gps.snapshot()
        if fix.get("utc"):
            self._offset = self.epoch(fix) - self.clock()
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True, name="aircraft")
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(self.poll + STOP_WAIT + 5)
        self._end()

    def name(self):
        log = self.log()
        return file_for(log) if log is not None else self.target

    def finish(self):
        """Write the aircraft file beside the WiGLE log, or under the wardrive's own time without one. Returns it, or
        None when no aircraft was heard. The journal goes once the file is on disk."""
        with self._lock:
            journal = self.journal
            if self.log() is None and self.started < wigle.MIN_EPOCH and len(self.sky):
                self.prepare(min(plane.first for plane in self.sky.planes.values()))
            path = self.name()
            written = write(path, self.sky, self._now())
            for hidden in {journal, self.journal}:
                try:
                    hidden.unlink(missing_ok=True)
                except OSError:
                    pass
            return path if written else None

    def checkpoint(self):
        """Put the aircraft heard so far on disk now, so that a power cut loses none of them."""
        with self._lock:
            if self.journal is None or not len(self.sky):
                return
            self._journaled = time.monotonic()
            save_journal(self.journal, self.sky, self.name().name, self._now())
            settle(self.journal.parent)

    def discard(self):
        """Throw the aircraft of this wardrive away: nothing is written and the journal goes. False when it could
        not be removed."""
        with self._lock:
            self.sky, gone = Sky(), True
            if self.journal is not None:
                for hidden in (self.journal, self.journal.with_name(self.journal.name + ".tmp")):
                    try:
                        hidden.unlink(missing_ok=True)
                    except OSError:
                        gone = False
            return gone

    def _time(self, fix):
        """UTC: the GPS's when it has it, else the system clock moved by what the GPS last said of it.

        The CardputerZero has no battery clock, so the system clock may be days off. Aircraft heard before the GPS
        first gives the time are moved to it then, and their file is named again."""
        if not fix.get("utc"):
            return self.epoch(fix) if self._offset is None else self.clock() + self._offset
        epoch = self.epoch(fix)
        first, self._offset = self._offset is None, epoch - self.clock()
        if first:
            self._retime(self._offset)
        return epoch

    def _retime(self, delta):
        with self._lock:
            if self.started is None or abs(delta) < RETIME_SECONDS:
                return
            old = self.journal
            self.sky.shift(delta)
            self.prepare(self.started + delta)
            if old is not None and old != self.journal and old.exists():
                try:
                    save_journal(self.journal, self.sky, self.name().name, self._now())
                    old.unlink(missing_ok=True)
                except OSError:
                    faults.note("Saving the aircraft journal")

    def _now(self):
        """The time a file is stamped with: never before the last aircraft heard, should the clock fall back."""
        fix = self.gps.snapshot()
        now = self.epoch(fix) if fix.get("utc") or self._offset is None else self.clock() + self._offset
        return max([now] + [plane.last for plane in self.sky.planes.values()])

    def _here(self, fix, epoch):
        if wigle.usable(fix, epoch, self.max_hdop):
            return fix["latitude"], fix["longitude"]
        return None

    def _run(self):
        while not self._stop.is_set():
            try:
                self._tick()
            except Exception:
                faults.note("Aircraft")
            self._stop.wait(self.poll)
        try:
            self._read()
        except Exception:
            faults.note("Aircraft")
        self._end()

    def _tick(self):
        self._watch()
        if self.feed is None and self.proc is None:
            self._connect()
        self._read()
        if self.sky.changed and time.monotonic() - self._journaled >= JOURNAL_SECONDS:
            self._journaled = time.monotonic()
            with self._lock:
                try:
                    save_journal(self.journal, self.sky, self.name().name, self._now())
                except OSError:
                    faults.note("Saving the aircraft journal")

    def _watch(self):
        """Notice that the decoder ended, that the system's copy went quiet, or that the GPS has a fix for a readsb
        started without one: it is started again with the position, so that its own range check works."""
        proc = self.proc
        if proc is not None and proc.poll() is not None:
            said = _tail(self._said) if self._said else ""
            readsb = self.decoder is None
            if not readsb:
                if self._listener is not None:
                    self._listener.join(STOP_WAIT)
                try:
                    self._heard()
                except Exception:
                    faults.note("Aircraft")
            self._end()
            if readsb and any(w in said for w in NO_RTLSDR_WORDS):
                _no_rtlsdr.add(self._binary)
                self.state = NO_TOOLS
            else:
                self.state = stopped_state(said, self.dongles())
            self._failed_at = time.monotonic()
        elif proc is not None and self._blind:
            fix = self.gps.snapshot()
            if self._here(fix, self._time(fix)) is not None:
                self._end()
        elif proc is None and self.feed is not None and read_feed(self.feed, self.clock()) is None:
            self.feed = None

    def _connect(self):
        found = system_feed(self.feeds, self.clock())
        if found is not None:
            self.feed, self.state = found, SYSTEM
            return
        if not self.dongles():
            self.state = NO_DONGLE
            return
        rtl_adsb = find_rtl_adsb(self.which)
        readsb = "" if rtl_adsb else find_readsb(self.which)
        if not rtl_adsb and not (readsb and reads_rtlsdr(readsb, self.runner)):
            self.state = NO_TOOLS
            return
        if self._failed_at is not None and time.monotonic() - self._failed_at < RETRY_SECONDS:
            return
        try:
            if rtl_adsb:
                self._listen(rtl_adsb)
            else:
                self._launch(readsb)
        except (OSError, subprocess.SubprocessError):
            faults.note("Starting the aircraft decoder")
            self.state, self._failed_at = FAILED, time.monotonic()

    def _prefix(self):
        count = self.cpus() or 1
        return calm(count - 1 if count >= 4 else None, self.tools)

    def _listen(self, binary):
        out = _own_dir(self.out or run_dir())
        said = out / "rtl_adsb.log"
        with open(said, "wb") as log:
            proc = self.launcher(rtl_command(binary, self._prefix()), stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=log, cwd=str(out), close_fds=True,
                                 start_new_session=True)
        with _children_lock:
            _children.add(proc)
        decoder = modes.Decoder()
        fix = self.gps.snapshot()
        decoder.receiver = self._here(fix, self._time(fix))
        listener = threading.Thread(target=self._hear, args=(proc.stdout, decoder), daemon=True, name="rtl_adsb")
        self.proc, self.decoder, self._listener, self._said, self._binary = proc, decoder, listener, said, binary
        self.feed, self.state, self._blind = None, RUNNING, False
        listener.start()

    def _hear(self, stream, decoder):
        try:
            listen(stream, decoder, self._decoding, self.mono, tap=self._tapped)
        except (OSError, ValueError):
            pass
        except Exception:
            faults.note("Aircraft")

    def _tapped(self, lines, now):
        """The aircraft viewer reads the frames the wardrive hears, so that one stick serves both."""
        tap = self.tap
        if tap is not None:
            try:
                tap(lines, now)
            except Exception:
                self.tap = None
                faults.note("Aircraft viewer")

    def _launch(self, binary):
        out = _own_dir(self.out or run_dir())
        feed = out / "aircraft.json"
        try:
            feed.unlink(missing_ok=True)
        except OSError:
            pass
        fix = self.gps.snapshot()
        here = self._here(fix, self._time(fix))
        argv = command(binary, out, here, options(binary, self.runner), self._prefix())
        said = out / "readsb.log"
        with open(said, "wb") as log:
            proc = self.launcher(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, cwd=str(out),
                                 close_fds=True, start_new_session=True)
        with _children_lock:
            _children.add(proc)
        self.proc, self.feed, self.state, self._blind = proc, feed, RUNNING, here is None
        self.decoder, self._said, self._binary = None, said, binary

    def _end(self):
        proc, self.proc = self.proc, None
        listener, self._listener = self._listener, None
        if listener is not None:
            self.decoder = None
        if proc is not None:
            end(proc, self.kill)
            if self.state in (RUNNING, SYSTEM):
                self.feed = None
        if listener is not None:
            listener.join(STOP_WAIT)
            stream = getattr(proc, "stdout", None)
            if stream is not None and not listener.is_alive():
                try:
                    stream.close()
                except OSError:
                    pass

    def _read(self):
        if self.decoder is not None:
            self._heard()
            return
        if self.feed is None:
            return
        now = self.clock()
        data = read_feed(self.feed, now)
        if data is None or data["now"] == self._last:
            return
        self._last = data["now"]
        fix = self.gps.snapshot()
        epoch = self._time(fix)
        if not self.gate():
            self._shut = now
            return
        if epoch < wigle.MIN_EPOCH:
            return
        if self._shut is not None and isinstance(data.get("aircraft"), list):
            data = dict(data, aircraft=[report for report in data["aircraft"] if not isinstance(report, dict) or
                                        data["now"] - (_number(report.get("seen")) or 0.0) >= self._shut])
        with self._lock:
            self.sky.update(data, epoch - max(0.0, now - data["now"]), self._here(fix, epoch))

    def _heard(self):
        """What rtl_adsb was heard saying since the last look, through the decoder, into the store."""
        decoder = self.decoder
        fix = self.gps.snapshot()
        epoch = self._time(fix)
        here = self._here(fix, epoch)
        now = self.mono()
        counting = self.gate()
        with self._decoding:
            if not counting:
                decoder.planes.clear()
                return
            decoder.receiver = here
            decoder.forget(now)
            planes = decoder.aircraft(now)
        if epoch < wigle.MIN_EPOCH or not planes:
            return
        with self._lock:
            self.sky.update({"now": epoch, "aircraft": planes}, epoch, here)
