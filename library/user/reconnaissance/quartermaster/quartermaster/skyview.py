"""The aircraft viewer: every aircraft the RTL-SDR stick hears now, the way each one flew, and captures of it.

One stick has one reader. While a wardrive listens for aircraft, the viewer is handed the same frames the wardrive's
receiver reads and starts nothing. Without a wardrive it starts rtl_adsb itself and stops it when the viewer closes.
Where a readsb or dump1090 holds the stick, its aircraft.json is read instead, and there are no raw frames then.

Only what an aircraft sent is shown. A field not heard stays None. Aircraft do not send where they come from or
where they go, so the route is the track heard: the positions decoded while the aircraft was in range.

A capture is two files in quartermaster/aircraft: a CSV with one line per position, and the raw Mode S frames as
AVR lines with a 12 MHz timestamp ("@" + 12 hex digits + the frame + ";"), which dump1090 and readsb read on their
raw input port. The timestamp counts from the UTC second in the file's name. Both are written under hidden names
while the capture runs, put on disk every few seconds, and given their names at the end. A capture a crash or a
power cut ended is finished the next time the viewer opens.

The CardputerZero has no battery clock, so UTC is what the GPS said last, also when its fix is long lost. Only
before the GPS has told the time is the system clock used, and a capture begun on it is moved to the GPS's time once
the GPS tells it.
"""

import calendar
from collections import deque
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time

from . import adsb, faults, hardware, modes, wigle
from .engine import gps_epoch

STEP_SECONDS = 0.5
FEED_SECONDS = 2.0
RETRY_SECONDS = 10.0
FRESH_SECONDS = 60.0
RAW_KEEP = 20000
INBOX = 2000
TRACK_POINTS = 240
POINT_SECONDS = 1.0
SILENCE_SECONDS = 120.0
SAME_SECONDS = 0.3
MAX_SEEN = 400
MIN_FREE_BYTES = 32 * 1024 * 1024
CAPTURE_BYTES = 128 * 1024 * 1024
TICKS = 12_000_000
FOLDER = "aircraft"
TRACK_END, FRAMES_END = ".track.csv", ".frames.avr"
TRACK_COLUMNS = ("Time", "ICAO", "Callsign", "Latitude", "Longitude", "AltitudeFt", "SpeedKt", "Heading",
                 "VerticalRateFpm", "Squawk")
SAID = ("flight", "squawk", "alt_baro", "alt_geom", "gs", "track", "mag_heading", "ias", "tas", "baro_rate",
        "geom_rate")
NO_DRIVE, STARTING = "no_drive", "starting"
WORDS = dict(adsb.WORDS)
WORDS.update({adsb.RUNNING: "Listening", adsb.READY: "Starting", STARTING: "Starting",
              adsb.FAILED: "The radio stopped. Trying again soon.",
              NO_DRIVE: "This wardrive does not listen for aircraft"})
SHARED = "Listening with the wardrive"
FULL = "Capture ended: storage is almost full"
LARGE = "Capture ended: it reached 128 MB"
BROKEN = "Capture ended: the files could not be written"
NO_TIME = "The time is not known yet. Wait for a GPS fix."

_HEX = re.compile(r"[0-9a-f]{6}")
_FEED_TEXT = {"flight": re.compile(r"[A-Z0-9 ]{1,8}"), "squawk": re.compile(r"[0-7]{4}"),
              "category": re.compile(r"[A-D][1-7]")}
_NAME = re.compile(r"quartermaster_(\d{8}-\d{6})(-\d+)?\.(track\.csv|frames\.avr)")


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) \
        else None


class Seen:
    """One aircraft in view. Times are monotonic seconds. points holds (time, lat, lon, altitude, ground speed,
    heading, vertical rate, squawk), thinned out as the track grows, and heard counts every position there was.
    newest is the last position heard, and cuts holds where in points the aircraft was heard again after a silence
    of SILENCE_SECONDS."""

    __slots__ = ("hex", "flight", "category", "squawk", "alt_baro", "alt_geom", "gs", "track", "mag_heading", "ias",
                 "tas", "baro_rate", "geom_rate", "lat", "lon", "pos_time", "messages", "first", "last", "rssi",
                 "points", "gap", "newest", "cuts", "heard", "plane", "base")

    def __init__(self, code, now):
        self.hex, self.first, self.last = code, now, now
        self.flight = self.category = self.squawk = self.alt_baro = self.alt_geom = self.gs = self.track = None
        self.mag_heading = self.ias = self.tas = self.baro_rate = self.geom_rate = None
        self.lat = self.lon = self.pos_time = self.rssi = self.plane = self.newest = None
        self.messages = self.base = self.heard = 0
        self.points, self.gap, self.cuts = [], POINT_SECONDS, set()

    @property
    def name(self):
        return (self.flight or "").strip() or self.hex.upper()

    @property
    def altitude(self):
        return self.alt_baro if self.alt_baro is not None else self.alt_geom

    @property
    def heading(self):
        return self.track if self.track is not None else self.mag_heading

    @property
    def rate(self):
        return self.baro_rate if self.baro_rate is not None else self.geom_rate

    def afresh(self):
        """Forget what the aircraft said before a long silence, so that only what it says from now on is shown.
        Its category, its last position and the way it flew stay."""
        for key in SAID:
            setattr(self, key, None)
        self.rssi = None

    def place(self, point):
        """Keep a position for the track drawn on screen: at most TRACK_POINTS, further apart as it grows. The
        first one stays. Where the aircraft is heard again after a silence is marked, with the last position
        before it, and the mark stays when the track is thinned out."""
        points, before = self.points, self.newest
        self.newest = point
        self.heard += 1
        if before is not None and point[0] - before[0] > SILENCE_SECONDS:
            if points[-1] is not before and before[0] - points[-1][0] >= POINT_SECONDS:
                points.append(before)
            self.cuts.add(len(points))
        elif points and point[0] - points[-1][0] < self.gap:
            return
        points.append(point)
        if len(points) > TRACK_POINTS:
            first = 1 - len(points) % 2
            self.points = points[:first] + points[first::2]
            self.cuts = {(cut + 1 + first) // 2 for cut in self.cuts}
            self.gap *= 2

    def route(self):
        """The positions kept, oldest first. The newest one heard is the last, unless it came less than
        POINT_SECONDS after the last one kept: positions that close together are shown as one."""
        points, newest = self.points, self.newest
        if not points or points[-1] is newest or newest[0] - points[-1][0] < POINT_SECONDS:
            return list(points)
        return points + [newest]

    def parts(self):
        """The same positions as the parts of the flight that were heard: a silence of SILENCE_SECONDS ends one."""
        points, parts, start = self.route(), [], 0
        for cut in sorted(self.cuts) + [len(points)]:
            if cut > start:
                parts.append(points[start:cut])
                start = cut
        return parts


class _Decoder(modes.Decoder):
    """The decoder, which also tells of every position it places."""

    def __init__(self):
        super().__init__()
        self.moved = []

    def _position(self, plane, odd, lat_cpr, lon_cpr, now):
        super()._position(plane, odd, lat_cpr, lon_cpr, now)
        if plane.placed and plane.pos_time == now:
            self.moved.append((plane, (now, plane.lat, plane.lon,
                                       plane.alt_baro if plane.alt_baro is not None else plane.alt_geom, plane.gs,
                                       plane.track if plane.track is not None else plane.mag_heading,
                                       plane.baro_rate if plane.baro_rate is not None else plane.geom_rate,
                                       plane.squawk)))


class _Nothing:
    """What rtl_adsb's lines pass through on the viewer's own pipe: they are decoded on the viewer's thread."""

    dropped = 0

    @staticmethod
    def line(raw, now):
        return False


def frame_of(raw):
    """(hex digits in upper case, bytes) of a line rtl_adsb printed, or None for anything else."""
    if raw[:1] != b"*":
        return None
    end = raw.find(b";")
    if end != 15 and end != 29:
        return None
    try:
        text = raw[1:end].decode("ascii")
        data = bytes.fromhex(text)
    except ValueError:
        return None
    return (text.upper(), data) if len(data) * 2 == end - 1 else None


def avr_line(text, ticks):
    """One frame as an AVR line with its 48 bit, 12 MHz timestamp."""
    return "@%012X%s;\n" % (max(0, ticks) & 0xFFFFFFFFFFFF, text)


def iso(epoch):
    whole = int(math.floor(epoch))
    return "%s.%03dZ" % (time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(whole)), int((epoch - whole) * 1000))


def _cell(value, form="%s"):
    return "" if value is None else form % value


def track_row(epoch, code, flight, point):
    """A line of the track file from a point (time, lat, lon, altitude, speed, heading, rate, squawk)."""
    _, lat, lon, alt, gs, heading, rate, squawk = point
    return ",".join((iso(epoch), code.upper(), (flight or "").strip(), "%.6f" % lat, "%.6f" % lon, _cell(alt),
                     _cell(gs, "%.1f"), _cell(heading, "%.1f"), _cell(rate), squawk or "")) + "\n"


def moved_row(line, seconds):
    """A line of the track file with its time moved by whole seconds. A line without a time, as the first, stays."""
    try:
        whole = calendar.timegm(tuple(int(line[start:end]) for start, end in ((0, 4), (5, 7), (8, 10), (11, 13),
                                                                              (14, 16), (17, 19))))
    except ValueError:
        return line
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(whole + seconds)) + line[19:]


def folder(root):
    return Path(root) / FOLDER


def _part(path):
    return path.with_name("." + path.name + ".part")


class Capture:
    """The two files of one capture, written under hidden names until finish(). offset is what is added to a
    monotonic time for UTC, and timed says that the GPS told it."""

    def __init__(self, directory, epoch, offset, sync_every=wigle.SYNC_SECONDS, timed=True):
        self.folder, self.offset, self.sync_every, self.timed = Path(directory), offset, sync_every, timed
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._name(int(math.floor(epoch)))
        self.points = self.raw = self.size = 0
        self._synced, self._waiting = time.monotonic(), False
        self._track = self._open(_part(self.track))
        try:
            self._frames = self._open(_part(self.frames))
            self._write(self._track, ",".join(TRACK_COLUMNS) + "\n")
            self.sync(force=True)
            adsb.settle(self.folder)
        except BaseException:
            self.abandon()
            raise

    def _name(self, base):
        """Name the files after the UTC second the capture counts from, with a number when that name is taken."""
        stamp, serial = time.strftime("%Y%m%d-%H%M%S", time.gmtime(base)), 0
        while True:
            stem = "quartermaster_%s%s" % (stamp, "-%d" % serial if serial else "")
            track, frames = self.folder / (stem + TRACK_END), self.folder / (stem + FRAMES_END)
            if not any(path.exists() for path in (track, frames, _part(track), _part(frames))):
                break
            serial += 1
        self.base, self.stem, self.track, self.frames = base, stem, track, frames

    @staticmethod
    def _open(path, mode=os.O_APPEND):
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | mode, 0o600)
        return os.fdopen(fd, "a", encoding="ascii", newline="")

    def _write(self, out, text):
        out.write(text)
        self.size += len(text)
        self._waiting = True

    def point(self, code, flight, point):
        self._write(self._track, track_row(point[0] + self.offset, code, flight, point))
        self.points += 1

    def frame(self, now, text):
        self._write(self._frames, avr_line(text, int(round((now + self.offset - self.base) * TICKS))))
        self.raw += 1

    def sync(self, force=False):
        """Put what waits in memory on disk, every few seconds at most."""
        now = time.monotonic()
        if self._waiting and (force or now - self._synced >= self.sync_every):
            for out in (self._track, self._frames):
                out.flush()
                wigle.fsync(out.fileno())
            self._synced, self._waiting = now, False

    def retime(self, seconds):
        """Move every time by a whole number of seconds and name the capture after its new start: the clock it
        began on was wrong. The frames count from the second in the name, so only the track is written again, under
        a name of its own until it is on disk. False when it could not be written, and the capture goes on as it
        was."""
        self.sync(force=True)
        self._close()
        track, frames = _part(self.track), _part(self.frames)
        copy = track.with_name(track.name + ".tmp")
        try:
            with open(track, encoding="ascii", newline="") as lines, self._open(copy, os.O_TRUNC) as out:
                for line in lines:
                    out.write(moved_row(line, seconds))
                out.flush()
                wigle.fsync(out.fileno())
        except OSError:
            try:
                copy.unlink(missing_ok=True)
            except OSError:
                pass
            self._track, self._frames = self._open(track), self._open(frames)
            return False
        self._name(self.base + seconds)
        self.offset += seconds
        os.replace(copy, _part(self.track))
        track.unlink(missing_ok=True)
        os.replace(frames, _part(self.frames))
        self._track, self._frames = self._open(_part(self.track)), self._open(_part(self.frames))
        adsb.settle(self.folder)
        return True

    def _close(self):
        for out in (getattr(self, "_track", None), getattr(self, "_frames", None)):
            try:
                if out is not None:
                    out.close()
            except OSError:
                pass

    def finish(self):
        """Give the files their names once they are on disk. Returns them; a file with nothing in it is removed."""
        try:
            self.sync(force=True)
        finally:
            self._close()
        saved = []
        for path, count in ((self.track, self.points), (self.frames, self.raw)):
            if count:
                os.replace(_part(path), path)
                saved.append(path)
            else:
                _part(path).unlink(missing_ok=True)
        adsb.settle(self.folder)
        return saved

    def abandon(self):
        self._close()
        for path in (self.track, self.frames):
            try:
                _part(path).unlink(missing_ok=True)
            except OSError:
                pass


def recover(directory, live=()):
    """Finish the captures a crash or a power cut ended: a last line left half written is cut off, and what holds
    data gets its name. A track that was being written again goes. Returns the files named."""
    directory, done = Path(directory), []
    try:
        parts = sorted(directory.glob(".quartermaster_*.part"))
        copies = list(directory.glob(".quartermaster_*.part.tmp"))
    except OSError:
        return done
    for part in parts:
        target = part.with_name(part.name[1:-len(".part")])
        if target in live or not _NAME.fullmatch(target.name):
            continue
        try:
            least = len(",".join(TRACK_COLUMNS)) + 2 if target.name.endswith(TRACK_END) else 1
            if wigle.trim(part) and part.stat().st_size >= least and not target.exists():
                os.replace(part, target)
                done.append(target)
            else:
                part.unlink(missing_ok=True)
        except OSError:
            faults.note("Finishing an earlier aircraft capture")
    for leftover in copies:
        try:
            leftover.unlink(missing_ok=True)
        except OSError:
            pass
    if done:
        adsb.settle(directory)
    return done


def captures(directory):
    """The captures saved, newest first: {"stem", "epoch", "files", "size", "track", "frames"}."""
    found = {}
    try:
        paths = [path for path in Path(directory).iterdir() if _NAME.fullmatch(path.name)]
    except OSError:
        return []
    for path in paths:
        try:
            size = path.stat().st_size
        except OSError:
            continue
        stem = path.name[:-len(TRACK_END if path.name.endswith(TRACK_END) else FRAMES_END)]
        entry = found.setdefault(stem, {"stem": stem, "files": [], "size": 0, "track": False, "frames": False})
        entry["files"].append(path)
        entry["size"] += size
        entry["track" if path.name.endswith(TRACK_END) else "frames"] = True
    for entry in found.values():
        try:
            entry["epoch"] = calendar.timegm(time.strptime(entry["stem"][14:29], "%Y%m%d-%H%M%S"))
        except (ValueError, OverflowError):
            entry["epoch"] = None
    return [found[stem] for stem in sorted(found, reverse=True)]


def delete(entry):
    """Remove the files of one capture. False when one of them stays."""
    gone = True
    for path in entry["files"]:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            gone = False
    return gone


def kilometres(here, lat, lon):
    return modes.distance_km(here[0], here[1], lat, lon)


def bearing(here, lat, lon):
    lat1, lon1, lat2, lon2 = map(math.radians, (here[0], here[1], lat, lon))
    y = math.sin(lon2 - lon1) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


class Viewer:
    """One viewing session. drive() gives the wardrive that runs now, or None."""

    def __init__(self, root, gps, drive=None, launcher=subprocess.Popen, which=shutil.which,
                 dongles=hardware.rtl_sdr_dongles, feeds=adsb.SYSTEM_FEEDS, out=None, cpus=os.cpu_count, kill=None,
                 tools=shutil.which, clock=time.time, mono=None, epoch=None, threads=True):
        self.folder, self.gps = folder(root), gps
        self.drive = drive or (lambda: None)
        self.launcher, self.which, self.dongles, self.feeds = launcher, which, dongles, feeds
        self.out, self.cpus, self.kill, self.tools, self.clock = out, cpus, kill, tools, clock
        self.mono = mono or (lambda: time.monotonic())
        self.epoch = epoch or (lambda fix: gps_epoch(fix, self.clock()))
        self.threads = threads
        self.decoder = _Decoder()
        self.seen = {}
        self.state, self.shared, self.feed, self.proc = STARTING, False, None, None
        self.frames = 0
        self.capture, self.note, self.saved = None, "", []
        self._raw = deque(maxlen=RAW_KEEP)
        self._inbox = deque(maxlen=INBOX)
        self._tapped = self._listener = self._said = self._failed_at = self._utc = None
        self._feed_at, self._feed_now = 0.0, None
        self._lock = threading.RLock()
        self._pipe = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self._recovered = False

    def start(self):
        self._stop.clear()
        if self.threads and self._thread is None:
            self._thread = threading.Thread(target=self._run, daemon=True, name="aircraft-viewer")
            self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            try:
                self.step()
            except Exception:
                faults.note("Aircraft viewer")
            self._stop.wait(STEP_SECONDS)

    def stop(self):
        """Close the session: the capture is finished, the wardrive's receiver let go, our own rtl_adsb ended.
        Returns the name of the capture saved, or ""."""
        self._stop.set()
        thread, self._thread = self._thread, None
        if thread is not None:
            thread.join(STEP_SECONDS + adsb.STOP_WAIT + 5)
        self._detach()
        self._end()
        try:
            self._drain()
        except Exception:
            faults.note("Aircraft viewer")
        return self.capture_finish()

    def step(self):
        if not self._recovered:
            self._recovered = True
            with self._lock:
                capture = self.capture
                recover(self.folder, (capture.track, capture.frames) if capture is not None else ())
        self._connect()
        self._drain()
        self._guard()

    def take(self, lines, now):
        """Frames as rtl_adsb printed them, heard at `now`. Called from the thread that reads the pipe."""
        self._inbox.append((now, lines))

    def here(self, fix=None):
        fix = self.gps.snapshot() if fix is None else fix
        lat, lon = fix.get("latitude"), fix.get("longitude")
        if not fix.get("valid") or lat is None or lon is None or (fix.get("age_seconds") or 0) > wigle.FIX_MAX_AGE \
                or (abs(lat) < 1e-6 and abs(lon) < 1e-6):
            return None
        return lat, lon

    def _detach(self):
        receiver, self._tapped = self._tapped, None
        if receiver is not None and receiver.tap == self.take:
            receiver.tap = None

    def _connect(self):
        drive = self.drive()
        if drive is not None:
            if self.proc is not None:
                self._end()
            receiver = getattr(drive, "aircraft", None)
            self.shared = True
            if receiver is None:
                self._detach()
                self.feed = None
                self.state = STARTING if getattr(drive, "_sky_waiting", False) else NO_DRIVE
                return
            if self._tapped is not receiver:
                self._detach()
                receiver.tap, self._tapped = self.take, receiver
            self.feed = receiver.feed if receiver.decoder is None else None
            self.state = receiver.state
            return
        self._detach()
        self.shared = False
        proc = self.proc
        if proc is not None:
            if proc.poll() is not None:
                said = adsb._tail(self._said) if self._said else ""
                self._end()
                self.state, self._failed_at = adsb.stopped_state(said, self.dongles()), self.mono()
            return
        found = adsb.system_feed(self.feeds, self.clock())
        if found is not None:
            self.feed, self.state = found, adsb.SYSTEM
            return
        self.feed = None
        if not self.dongles():
            self.state = adsb.NO_DONGLE
            return
        binary = adsb.find_rtl_adsb(self.which)
        if not binary:
            self.state = adsb.NO_TOOLS
            return
        if self._failed_at is not None and self.mono() - self._failed_at < RETRY_SECONDS:
            return
        try:
            self._listen(binary)
        except (OSError, subprocess.SubprocessError):
            faults.note("Starting the aircraft viewer")
            self.state, self._failed_at = adsb.FAILED, self.mono()

    def _listen(self, binary):
        out = adsb._own_dir(self.out or adsb.run_dir())
        said = out / "rtl_adsb-viewer.log"
        count = self.cpus() or 1
        prefix = adsb.calm(count - 1 if count >= 4 else None, self.tools)
        with open(said, "wb") as log:
            proc = self.launcher(adsb.rtl_command(binary, prefix), stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=log, cwd=str(out), close_fds=True,
                                 start_new_session=True)
        with adsb._children_lock:
            adsb._children.add(proc)
        listener = threading.Thread(target=self._hear, args=(proc.stdout,), daemon=True, name="rtl_adsb-viewer")
        self.proc, self._listener, self._said, self.state = proc, listener, said, adsb.RUNNING
        listener.start()

    def _hear(self, stream):
        try:
            adsb.listen(stream, _Nothing(), self._pipe, self.mono, tap=self.take)
        except (OSError, ValueError):
            pass
        except Exception:
            faults.note("Aircraft viewer")

    def _end(self):
        proc, self.proc = self.proc, None
        listener, self._listener = self._listener, None
        if proc is not None:
            adsb.end(proc, self.kill)
        if listener is not None:
            listener.join(adsb.STOP_WAIT)
            stream = getattr(proc, "stdout", None)
            if stream is not None and not listener.is_alive():
                try:
                    stream.close()
                except OSError:
                    pass

    def _drain(self):
        """Decode what was heard since the last look, and write it to the capture when one runs."""
        batches, inbox = [], self._inbox
        while inbox:
            batches.append(inbox.popleft())
        with self._lock:
            decoder = self.decoder
            fix = self.gps.snapshot()
            decoder.receiver = self.here(fix)
            self._offset(fix)
            try:
                since = batches[0][0] if batches else None
                if batches:
                    decoder.forget(since)
                for now, lines in batches:
                    for raw in lines:
                        found = frame_of(raw)
                        if found is None:
                            continue
                        self.frames += 1
                        if self.capture is not None:
                            self.capture.frame(now, found[0])
                        else:
                            self._raw.append((now, found[0]))
                        decoder.frame(found[1], now)
                if since is not None:
                    self._decoded(since)
                elif self.feed is not None:
                    self._read_feed()
                if self.capture is not None:
                    self.capture.sync()
            except OSError:
                self._broken(BROKEN)

    def _decoded(self, since):
        decoder = self.decoder
        for plane in decoder.planes.values():
            if plane.last >= since and plane.good >= 2:
                self._sync(plane)
        moved, decoder.moved = decoder.moved, []
        for plane, point in moved:
            seen = self._sync(plane)
            seen.lat, seen.lon, seen.pos_time = point[1], point[2], point[0]
            self._placed(seen, point)
        self._trim()

    def _sync(self, plane):
        """Take what the decoder knows of an aircraft into its row. One heard again after the decoder let it go
        starts afresh: what it said before the silence is not shown as what it says now. A ground speed comes with
        its track, which is unknown at 0 kt."""
        code = "%06x" % plane.address
        seen = self.seen.get(code)
        if seen is None:
            seen = self.seen[code] = Seen(code, plane.last)
        if seen.plane is not plane:
            if seen.plane is not None:
                seen.afresh()
            seen.plane, seen.base = plane, seen.messages
        for key in SAID:
            value = getattr(plane, key)
            if value is not None or key == "track" and plane.gs is not None:
                setattr(seen, key, value)
        if plane.category is not None and plane.category[1] != "0":
            seen.category = plane.category
        if plane.alt_geom is None and plane.geom_delta is not None and plane.alt_baro is not None:
            seen.alt_geom = plane.alt_baro + plane.geom_delta
        seen.messages, seen.last = seen.base + plane.messages, plane.last
        return seen

    def _placed(self, seen, point):
        seen.place(point)
        if self.capture is not None:
            self.capture.point(seen.hex, seen.flight, point)

    def _trim(self):
        if len(self.seen) > MAX_SEEN:
            for code in sorted(self.seen, key=lambda code: self.seen[code].last)[:len(self.seen) - MAX_SEEN]:
                del self.seen[code]

    def _read_feed(self):
        """Aircraft as a readsb or dump1090 lists them. It gives no raw frames. Its ages count back from when the
        file was written, which is a while before it is read. They are rounded to tenths of a second, so the same
        place at nearly the same time is the position already taken. An aircraft heard again after
        FORGET_SECONDS of silence starts afresh, as with the decoder. One listed at 0 kt without a track has no
        heading: the one it had while it moved is not shown as its heading now."""
        mono = self.mono()
        if mono - self._feed_at < FEED_SECONDS:
            return
        self._feed_at = mono
        clock = self.clock()
        data = adsb.read_feed(self.feed, clock)
        if data is None or data["now"] == self._feed_now or not isinstance(data.get("aircraft"), list):
            return
        self._feed_now = data["now"]
        written = mono - max(0.0, clock - data["now"])
        for report in data["aircraft"]:
            code = report.get("hex") if isinstance(report, dict) else None
            if not isinstance(code, str) or not _HEX.fullmatch(code.lower()):
                continue
            last = written - max(0.0, _number(report.get("seen")) or 0.0)
            seen = self.seen.get(code.lower())
            if seen is None:
                seen = self.seen[code.lower()] = Seen(code.lower(), last)
            elif last - seen.last > modes.FORGET_SECONDS:
                seen.afresh()
                seen.messages = 0
            seen.last = max(seen.last, last)
            for key, good in _FEED_TEXT.items():
                value = report.get(key)
                if isinstance(value, str) and good.fullmatch(value.strip()):
                    setattr(seen, key, value.strip())
            for key, name in (("alt_baro", "alt_baro"), ("altitude", "alt_baro"), ("alt_geom", "alt_geom"),
                              ("gs", "gs"), ("speed", "gs"), ("track", "track"), ("mag_heading", "mag_heading"),
                              ("ias", "ias"), ("tas", "tas"), ("baro_rate", "baro_rate"),
                              ("geom_rate", "geom_rate"), ("rssi", "rssi"), ("messages", "messages")):
                value = _number(report.get(key))
                if value is not None:
                    setattr(seen, name, value)
            if seen.gs == 0 and _number(report.get("track")) is None:
                seen.track = None
            lat, lon = _number(report.get("lat")), _number(report.get("lon"))
            if lat is None or lon is None or abs(lat) > 90 or abs(lon) > 180 or (abs(lat) < 1e-6 and abs(lon) < 1e-6):
                continue
            age = _number(report.get("seen_pos"))
            when = written - max(0.0, age if age is not None else _number(report.get("seen")) or 0.0)
            same = SAME_SECONDS if (lat, lon) == (seen.lat, seen.lon) else 0.0
            if seen.pos_time is not None and when <= seen.pos_time + same:
                continue
            seen.lat, seen.lon, seen.pos_time = lat, lon, when
            self._placed(seen, (when, lat, lon, seen.altitude, seen.gs, seen.heading, seen.rate, seen.squawk))
        self._trim()

    def _guard(self):
        """A capture ends by itself before it fills the storage. One begun on the system clock is moved to the
        GPS's time when the GPS first tells it, unless the two agree."""
        with self._lock:
            capture = self.capture
            if capture is None:
                return
            try:
                if capture.size >= CAPTURE_BYTES:
                    self.capture_finish(LARGE)
                elif shutil.disk_usage(self.folder).free < MIN_FREE_BYTES // 2:
                    self.capture_finish(FULL)
                elif not capture.timed and self._utc is not None:
                    capture.timed = True
                    seconds = int(round(self._utc - capture.offset))
                    if abs(seconds) >= adsb.RETIME_SECONDS:
                        capture.retime(seconds)
            except OSError:
                self._broken(BROKEN)

    def _broken(self, note):
        capture, self.capture = self.capture, None
        if capture is not None:
            capture._close()
            self.note = note

    def _offset(self, fix=None):
        """What to add to a monotonic time for UTC, and whether the GPS told it. What the GPS said last is kept,
        also after its fix is lost, and so is what it said before the viewer opened. Until it has told the time,
        the system clock is all there is."""
        fix = self.gps.snapshot() if fix is None else fix
        if fix.get("utc"):
            self._utc = self.epoch(fix) + (fix.get("age_seconds") or 0.0) - self.mono()
        elif self._utc is None:
            told = getattr(self.gps, "told", None)
            told = told() if told is not None else None
            epoch = gps_epoch({"utc": told[0]}, None) if told else None
            if epoch is not None:
                self._utc = epoch - told[1]
        if self._utc is not None:
            return self._utc, True
        return self.epoch(fix) - self.mono(), False

    def capture_start(self):
        """Start a capture with everything still in memory: the track of every aircraft and the last RAW_KEEP
        frames. From here on every position and every frame goes to disk. Returns "" or why it could not start."""
        with self._lock:
            if self.capture is not None:
                return ""
            try:
                self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                if shutil.disk_usage(self.folder).free < MIN_FREE_BYTES:
                    return "Storage is almost full (under 32 MB free)"
                (offset, timed), now = self._offset(), self.mono()
                if now + offset < wigle.MIN_EPOCH:
                    return NO_TIME
                points = sorted(((point, seen) for seen in self.seen.values() for point in seen.route()),
                                key=lambda item: item[0][0])
                first = min([now] + [point[0] for point, _ in points[:1]] +
                            ([self._raw[0][0]] if self._raw else []))
                capture = Capture(self.folder, first + offset, offset, timed=timed)
                try:
                    for point, seen in points:
                        capture.point(seen.hex, seen.flight, point)
                    for when, text in self._raw:
                        capture.frame(when, text)
                    capture.sync(force=True)
                except BaseException:
                    capture.abandon()
                    raise
            except OSError as exc:
                return "The capture could not start: %s" % (exc.strerror or exc)
            self._raw.clear()
            self.capture, self.note = capture, ""
            return ""

    def capture_finish(self, note=""):
        """End the capture and name its files. Returns the name they share, or "" when nothing was saved."""
        with self._lock:
            capture, self.capture = self.capture, None
            if capture is None:
                return ""
            try:
                saved = capture.finish()
            except OSError:
                self.note = BROKEN
                return ""
            self.saved, self.note = saved, note
            return capture.stem if saved else ""

    def status(self):
        capture = self.capture
        words = SHARED if self.shared and self.state == adsb.RUNNING else WORDS.get(self.state, "")
        return {"state": self.state, "detail": words, "shared": self.shared, "aircraft": len(self.seen),
                "frames": self.frames, "raw": self.feed is None, "listening": self.state in (adsb.RUNNING, adsb.SYSTEM),
                "capture": None if capture is None else {"name": capture.stem, "points": capture.points,
                                                          "frames": capture.raw, "size": capture.size}}

    def find(self, code):
        return self.seen.get(code)

    def track(self, code):
        """A copy of the positions kept for one aircraft, oldest first. See Seen.route()."""
        with self._lock:
            seen = self.seen.get(code)
            return seen.route() if seen is not None else []

    def parts(self, code):
        """The same positions as the parts of the flight that were heard, for a line with no silence drawn over."""
        with self._lock:
            seen = self.seen.get(code)
            return seen.parts() if seen is not None else []

    def planes(self, order="near", here=None):
        """What is in view as (aircraft, km or None, bearing or None): the nearest first, then those without a
        known distance by when they were last heard. With order "latest", by when they were last heard only.
        A distance is given only from a position heard in the last FRESH_SECONDS."""
        now, rows = self.mono(), []
        with self._lock:
            for seen in self.seen.values():
                km = angle = None
                if here is not None and seen.pos_time is not None and now - seen.pos_time <= FRESH_SECONDS:
                    km, angle = kilometres(here, seen.lat, seen.lon), bearing(here, seen.lat, seen.lon)
                rows.append((seen, km, angle))
        if order == "latest":
            rows.sort(key=lambda row: (-row[0].last, row[0].hex))
        else:
            rows.sort(key=lambda row: (row[1] is None, row[1] if row[1] is not None else -row[0].last, row[0].hex))
        return rows
