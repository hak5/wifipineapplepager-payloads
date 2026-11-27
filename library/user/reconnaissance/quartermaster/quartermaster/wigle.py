"""WigleWifi-1.6 CSV writer.

A pre-header line names the app and device, then the fixed column header, then
one observation per row. Rows are only written with a fresh GPS fix and a sane
UTC time, because WiGLE discards rows without them. The pre-header is what marks
a log as made by Quartermaster: WiGLE, WDGWars and Wardrift all read it.
"""

import csv
import errno
import io
import os
from pathlib import Path
import time

from . import APP_NAME, __version__
from .config import is_mac
from .names import one_line
from .tracker import Ends

COLUMNS = ("MAC", "SSID", "AuthMode", "FirstSeen", "Channel", "Frequency", "RSSI", "CurrentLatitude",
           "CurrentLongitude", "AltitudeMeters", "AccuracyMeters", "RCOIs", "MfgrId", "Type")
FIX_MAX_AGE = 5.0
MIN_EPOCH = 1704067200  # 2024-01-01: an unset clock must never reach a log
LOG_GLOB = "quartermaster_*.wigle.csv"
JOURNAL_GLOB = ".quartermaster_*.wigle.csv.part"
SYNC_SECONDS = 5.0
DEVICE_TREE_MODEL = Path("/proc/device-tree/model")
DISPLAY_SIZES = {"cardputer": "320x170", "st7735-128": "128x128", "st7789-240": "240x240"}


def pre_header(os_version="", *, display_profile="cardputer"):
    display = DISPLAY_SIZES[display_profile]
    model, board = "CardputerZero", "M5Stack CardputerZero"
    if display_profile != "cardputer":
        try:
            board = one_line(DEVICE_TREE_MODEL.read_text(errors="replace")).strip() or "Raspberry Pi"
        except OSError:
            board = "Raspberry Pi"
        model = board
    return ["WigleWifi-1.6", "appRelease=%s %s" % (APP_NAME, __version__), "model=%s" % model,
            "release=%s" % (os_version or "unknown"), "device=%s" % APP_NAME, "display=%s" % display,
            "board=%s" % board, "brand=Valleytech Solutions", "star=Sol", "body=3", "subBody=0"]


def _text(value):
    return one_line(value or "")


def accuracy_m(fix):
    """Estimated horizontal error in metres, or "" when the receiver gives no hint."""
    if isinstance(fix.get("accuracy"), (int, float)):
        return fix["accuracy"]
    errors = [fix[k] for k in ("epx", "epy") if isinstance(fix.get(k), (int, float))]
    if errors:
        return round(max(errors), 1)
    hdop = fix.get("hdop")
    if isinstance(hdop, (int, float)) and hdop > 0:
        return round(max(2.5, hdop * 5.0), 1)
    return ""


def usable(fix, epoch, max_hdop=None):
    """True when a fix and clock are good enough to stamp a log row."""
    if not fix or not fix.get("valid") or (fix.get("age_seconds") or 0) > FIX_MAX_AGE or epoch < MIN_EPOCH:
        return False
    lat, lon = fix.get("latitude"), fix.get("longitude")
    if lat is None or lon is None or (abs(lat) < 1e-6 and abs(lon) < 1e-6):
        return False
    hdop = fix.get("hdop")
    return not (max_hdop and isinstance(hdop, (int, float)) and hdop > max_hdop)


def point_fix(point):
    """A fix rebuilt from a tracker point (rssi, lat, lon, epoch, altitude, accuracy)."""
    fix = {"valid": True, "latitude": point[1], "longitude": point[2], "age_seconds": 0.0}
    if point[4] is not None:
        fix["altMSL"] = point[4]
    if point[5] not in (None, ""):
        fix["accuracy"] = point[5]
    return fix


def log_filename(epoch, serial=0):
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(epoch))
    return "quartermaster_%s%s.wigle.csv" % (stamp, "-%d" % serial if serial else "")


def new_log_path(directory, epoch, taken=()):
    serial = 0
    while True:
        path = Path(directory) / log_filename(epoch, serial)
        if not path.exists() and path.name not in taken and not journal_path(path).exists():
            return path
        serial += 1


def journal_path(path):
    """The hidden file a log's candidate rows wait in until the log is compacted."""
    path = Path(path)
    return path.with_name("." + path.name + ".part")


def log_of(journal):
    journal = Path(journal)
    return journal.with_name(journal.name[1:-len(".part")])


def _fields(line):
    if not line.endswith("\n"):
        return None
    if '"' in line:
        try:
            row = next(csv.reader((line,)))
        except (csv.Error, StopIteration):
            return None
    else:
        row = line[:-1].split(",")
    if len(row) != len(COLUMNS) or row[13] not in ("WIFI", "BLE", "BT") or not is_mac(row[0]):
        return None
    try:
        int(row[6])
        float(row[10] or 0)
    except ValueError:
        return None
    return row


def _named(line, ssid, auth):
    row = _fields(line)
    if (row[1], row[2]) == (ssid, auth):
        return line
    row[1], row[2] = ssid, auth
    out = io.StringIO()
    csv.writer(out, lineterminator="\n", quoting=csv.QUOTE_MINIMAL).writerow(row)
    return out.getvalue()


def compact(journal, path, names=None):
    """Write the strongest and the weakest row of each device in a journal to a log, in the order they were seen.

    One pass over the journal keeps where each row that may still be chosen starts, and a second reads only those.
    Both rows of a device carry the last name and capabilities known for it: names(type, mac, ssid, auth) gives the
    ones to write, or None to leave the device out. The log appears under its name only once it is whole and on
    disk. A journal without rows writes nothing. Returns the number of rows written for each (type, mac).
    """
    found, header, offset, same = {}, [], 0, {}
    with open(journal, "rb") as source:
        for seq, raw in enumerate(source):
            at, offset = offset, offset + len(raw)
            line = raw.decode("utf-8", "replace")
            if seq < 2:
                header.append(line)
                continue
            row = _fields(line)
            if row is None:
                continue
            entry = found.get((row[13], row[0]))
            if entry is None:
                entry = found[(row[13], row[0])] = [Ends(), "", ""]
            entry[0].add((int(row[6]), seq, at, same.setdefault(row[3], row[3]), None,
                          same.setdefault(row[10], row[10])))
            entry[1], entry[2] = row[1] or entry[1], row[2] or entry[2]
    if len(header) < 2 or not header[0].startswith("WigleWifi-1.6,") or header[1] != ",".join(COLUMNS) + "\n":
        return {}
    kept, counts = [], {}
    for (kind, mac), (ends, ssid, auth) in found.items():
        if names:
            known = names(kind, mac, ssid, auth)
            if known is None:
                continue
            ssid, auth = known
        chosen = ends.chosen()
        counts[(kind, mac)] = len(chosen)
        kept.extend((point[3], point[1], point[2], ssid, auth) for point in chosen)
    if not kept:
        return {}
    kept.sort()
    tmp = path.with_name("." + path.name + ".tmp")
    try:
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as out, open(journal, "rb") as source:
            out.write("".join(header).encode("utf-8"))
            for _, _, at, ssid, auth in kept:
                source.seek(at)
                out.write(_named(source.readline().decode("utf-8", "replace"), ssid, auth).encode("utf-8"))
            out.flush()
            fsync(out.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    return counts


def data_rows(path, limit=None):
    """Observation rows in a log, not counting the two header lines."""
    count = 0
    try:
        with open(path, "rb") as source:
            for index, _ in enumerate(source):
                if index >= 2:
                    count += 1
                    if limit and count >= limit:
                        break
    except OSError:
        return None
    return count


def prune_empty(directory):
    """Delete logs that hold headers but no observations. Unreadable files are left alone."""
    removed = []
    for path in sorted(Path(directory).glob(LOG_GLOB)):
        if data_rows(path, limit=1) == 0:
            try:
                path.unlink()
                removed.append(path)
            except OSError:
                pass
    return removed


def fsync(fd):
    """Wait until what a file was given is on disk. A file system that cannot do that at all has still taken it."""
    try:
        os.fsync(fd)
    except OSError as exc:
        if exc.errno not in (errno.EINVAL, errno.ENOTSUP):
            raise


def trim(path, window=65536):
    """Cut off a last line that has no end and put the rest on disk. False when that cannot be done."""
    try:
        with open(path, "rb+") as kept:
            start = max(0, kept.seek(0, os.SEEK_END) - window)
            kept.seek(start)
            tail = kept.read()
            whole = tail.rfind(b"\n") + 1
            if start and not whole:
                return False
            kept.truncate(start + whole)
            fsync(kept.fileno())
    except OSError:
        return False
    return True


def cut(path, size):
    """Cut a file back to the size a sync has put on disk. Storage that refuses this as well keeps what it has, and
    False says so."""
    try:
        with open(path, "rb+") as kept:
            if kept.seek(0, os.SEEK_END) > size:
                kept.truncate(size)
                fsync(kept.fileno())
    except FileNotFoundError:
        pass
    except OSError:
        return False
    return True


class WigleWriter:
    def __init__(self, path, os_version="", sync_every=SYNC_SECONDS, *, display_profile="cardputer"):
        self.path = Path(path)
        self.size = self.path.stat().st_size if self.path.exists() else 0
        header = pre_header(os_version, display_profile=display_profile) if not self.size else None
        fd = os.open(str(self.path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.file = os.fdopen(fd, "a", encoding="utf-8", newline="")
        self.rows = 0
        self.sync_every = sync_every
        self._synced, self._waiting = time.monotonic(), False
        self._emitted, self._safe, self._dropped = 0, (self.size, 0), False
        if header is not None:
            try:
                self._emit(header)
                self._emit(COLUMNS)
                self.sync(force=True)
            except OSError:
                self._let_go()
                self.path.unlink()
                raise

    def _emit(self, row):
        line = io.StringIO()
        csv.writer(line, lineterminator="\n", quoting=csv.QUOTE_MINIMAL).writerow(row)
        text = line.getvalue()
        self._waiting = True
        self.file.write(text)
        self.size += len(text.encode("utf-8"))

    @staticmethod
    def row(kind, device, rssi, fix, epoch):
        """Build one row, or None when it would not be a valid WiGLE observation."""
        if not usable(fix, epoch) or not isinstance(rssi, (int, float)):
            return None
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(epoch))
        altitude = fix.get("altMSL", fix.get("altHAE", ""))
        if isinstance(altitude, float):
            altitude = round(altitude, 1)
        position = ["%.7f" % fix["latitude"], "%.7f" % fix["longitude"], altitude, accuracy_m(fix)]
        rssi = max(-127, min(0, int(round(rssi))))
        if kind == "WIFI":
            return [device["mac"].lower(), _text(device.get("name")), device.get("capabilities") or "[ESS]", stamp,
                    device.get("channel") or 0, device.get("frequency") or "", rssi, *position, "", "", "WIFI"]
        mfgr = device.get("mfgr")
        return [device["mac"].lower(), _text(device.get("name")), device.get("capabilities") or "Misc [LE]", stamp,
                0, "", rssi, *position, "", "" if mfgr is None else mfgr, kind]

    def write(self, kind, device, rssi, fix, epoch):
        row = self.row(kind, device, rssi, fix, epoch)
        if row is None:
            return False
        self.write_row(row)
        return True

    def write_row(self, row):
        self._emit(row)
        self._emitted += 1
        self.sync()
        self.rows += 1

    def sync(self, force=False):
        """Put the rows that wait in memory on disk, every few seconds at most. An error means they are not there."""
        now = time.monotonic()
        if self._waiting and (force or now - self._synced >= self.sync_every):
            self.file.flush()
            try:
                fsync(self.file.fileno())
            except OSError:
                self._dropped = True
                raise
            self._synced, self._waiting, self._safe = now, False, (self.size, self._emitted)

    def close(self):
        """Close the file whatever happens. An error means that the last rows are not on disk."""
        try:
            self.sync(force=True)
        finally:
            self.file.close()

    def _let_go(self):
        try:
            self.file.close()
        except OSError:
            pass

    def abandon(self, exc):
        """Give up a file that refused a write. Returns how many of the rows counted are not in it.

        Full storage refuses at once what it cannot take: what the file holds then stays, less a row that is only
        half there. After any other error the kernel may have lost what it took since the last sync, and reading
        the file back would not show that, so the file is cut back to that sync.
        """
        self._let_go()
        full = exc.errno in (errno.ENOSPC, errno.EDQUOT) and not self._dropped
        kept = data_rows(self.path) if full and trim(self.path) else None
        if kept is None:
            size, kept = self._safe
            cut(self.path, size)
        return self.rows - kept
