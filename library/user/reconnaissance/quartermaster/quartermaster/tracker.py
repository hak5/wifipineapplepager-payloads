"""One record per device, with the strongest and weakest place it was heard.

The strongest sighting is the closest pass and the weakest is the farthest edge
of the device's range. The tracker also decides which sightings earn a WiGLE
row, and remembers which extremes still have to be written to the log.
"""

import math
import threading

WIFI, BLE, BT = "WIFI", "BLE", "BT"
FLOOR_RSSI = -92
EDGE_ACCURACY = 25.0
_UNKNOWN = float("inf")


def distance_m(a, b):
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(min(1.0, h)))


def _accuracy(value):
    if value in ("", None):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


class Ends:
    """The strongest sighting of a device, and the weakest one that may stand for the far edge of its range.

    A weak sighting counts only from FLOOR_RSSI up and with a position good to EDGE_ACCURACY metres. One whose
    accuracy is unknown counts only while the strongest sighting's accuracy is unknown as well. Between equal
    signals the smaller accuracy wins, then the earlier sighting. Points are (rssi, ., ., time, ., accuracy).
    """

    __slots__ = ("best", "edge", "blind")

    def __init__(self):
        self.best = self.edge = self.blind = None

    @staticmethod
    def _rank(point, sign):
        accuracy = _accuracy(point[5])
        return sign * point[0], _UNKNOWN if accuracy is None else accuracy, point[3]

    def _before(self, point, other, sign):
        """Whether point ranks before other. Most sightings differ in signal, which settles it at once."""
        if other is None or point[0] != other[0]:
            return other is None or sign * point[0] < sign * other[0]
        return self._rank(point, sign) < self._rank(other, sign)

    def add(self, point):
        """Take a sighting in. Returns 1 when it is the new strongest, 2 when it is the new usable weakest, 3 for
        both, 4 when it only waits as the weakest of unknown accuracy, and 0 when it changes nothing."""
        changed = 0
        if self._before(point, self.best, -1):
            self.best, changed = point, 1
        if point[0] < FLOOR_RSSI:
            return changed
        accuracy = _accuracy(point[5])
        if accuracy is None:
            if self._before(point, self.blind, 1):
                self.blind = point
                changed |= 2 if _accuracy(self.best[5]) is None else 4
        elif accuracy <= EDGE_ACCURACY and self._before(point, self.edge, 1):
            self.edge = point
            changed |= 2
        return changed

    def usable(self, point):
        """Whether a point may stand for the far edge."""
        return point is self.edge or point is self.blind and _accuracy(self.best[5]) is None

    def chosen(self):
        """The strongest sighting, then the weakest if it is another one and may be used."""
        if self.best is None:
            return []
        blind = self.blind if _accuracy(self.best[5]) is None else None
        weak = [point for point in (self.edge, blind) if point is not None]
        edge = min(weak, key=lambda point: self._rank(point, 1)) if weak else self.best
        return [self.best] if edge is self.best else [self.best, edge]


class Device:
    __slots__ = ("kind", "mac", "name", "security", "capabilities", "channel", "frequency", "band", "first_seen",
                 "last_seen", "sightings", "rssi", "best", "worst", "logged_best", "logged_worst", "logged_at",
                 "logged_pos", "rows", "extra", "ignored", "order", "ends", "part", "sent", "fresh")

    def __init__(self, kind, mac, now, order=0):
        self.kind, self.mac, self.order = kind, mac, order
        self.name = self.security = self.capabilities = self.band = ""
        self.channel = self.frequency = None
        self.first_seen = self.last_seen = now
        self.sightings = 0
        self.rssi = None
        self.best = self.worst = None      # (rssi, lat, lon, epoch, altitude, accuracy)
        self.logged_best = self.logged_worst = None
        self.logged_at = None
        self.logged_pos = None
        self.rows = 0
        self.extra = None
        self.ignored = False
        self.ends = self.part = None       # with extremes: Ends of every sighting, and of those in the open log
        self.sent = ()                     # the points of ends that are logged
        self.fresh = False                 # ends has changed since its chosen points were last all handed out


class Tracker:
    def __init__(self, relog_seconds=30.0, relog_meters=25.0, rssi_step=4, accuracy=None, extremes=False):
        self.extremes = extremes
        self.kept = 0                      # rows the open part of the log keeps, with extremes
        self._parted = []                  # devices with a part
        self._fresh = {}                   # devices whose ends changed since take_extremes last looked
        self.relog_seconds = relog_seconds
        self.relog_meters = relog_meters
        self.rssi_step = rssi_step
        self.accuracy = accuracy or (lambda fix: None)
        self.devices = {}                  # kept in order of last sighting, oldest first
        self.made = 0
        self.lock = threading.Lock()
        self.counts = {WIFI: 0, BLE: 0, BT: 0}
        self.bands = {"2.4": 0, "5": 0, "6": 0}
        self.security = {}
        self.sightings = 0

    def observe(self, kind, mac, rssi, now, fix=None, **fields):
        """Record one sighting and return (device, is_new, reason).

        reason says why the sighting earns a log row: "new", "stronger", "weaker" or "moved".
        It is None when the sighting adds nothing, or when there is no usable fix. With extremes, there is no
        "moved", and "weaker" means weaker than any logged sighting that may stand for the far edge."""
        key = (kind, mac)
        with self.lock:
            device = self.devices.pop(key, None)
            new = device is None
            if new:
                device = Device(kind, mac, now, self.made)
                self.made += 1
                self.counts[kind] = self.counts.get(kind, 0) + 1
                band = fields.get("band")
                if kind == WIFI and band in self.bands:
                    self.bands[band] += 1
                if kind == WIFI:
                    label = fields.get("security") or "OPEN"
                    self.security[label] = self.security.get(label, 0) + 1
            self.devices[key] = device
            device.last_seen = now
            device.sightings += 1
            self.sightings += 1
            device.rssi = rssi
            for name in ("security", "capabilities", "channel", "frequency", "band", "extra"):
                value = fields.get(name)
                if value not in (None, ""):
                    setattr(device, name, value)
            if fields.get("name"):
                device.name = fields["name"]
            if fields.get("ignored"):
                device.ignored = True
            if device.ignored or not fix or not fix.get("valid") or rssi is None:
                return device, new, None
            point = (rssi, fix["latitude"], fix["longitude"], now, fix.get("altMSL", fix.get("altHAE")),
                     self.accuracy(fix))
            reason = None
            if device.best is None:
                device.best = device.worst = point
                reason = "new"
                if self.extremes:
                    device.ends = Ends()
                    self._edge(device, point)
            else:
                if rssi > device.best[0]:
                    device.best = point
                elif rssi < device.worst[0]:
                    device.worst = point
                if self.extremes:
                    reason = self._edge(device, point)
                elif rssi - device.logged_best >= self.rssi_step:
                    reason = "stronger"
                elif device.logged_worst - rssi >= self.rssi_step:
                    reason = "weaker"
                elif (now - device.logged_at >= self.relog_seconds
                      and distance_m(device.logged_pos, point[1:3]) >= self.relog_meters):
                    reason = "moved"
            if reason:
                device.logged_at, device.logged_pos = now, point[1:3]
                self._logged(device, point)
            return device, new, reason

    def _edge(self, device, point):
        """With extremes: take a sighting into the device's ends, and say whether it moves one by rssi_step."""
        changed = device.ends.add(point)
        if not changed:
            return None
        device.fresh = True
        self._fresh[(device.kind, device.mac)] = device
        if changed & 1 and (device.logged_best is None or point[0] - device.logged_best >= self.rssi_step):
            return "stronger"
        if changed & 2 and (device.logged_worst is None or device.logged_worst - point[0] >= self.rssi_step):
            return "weaker"
        return None

    def _logged(self, device, point):
        device.logged_best = point[0] if device.logged_best is None else max(device.logged_best, point[0])
        if self.extremes:
            self._sent(device, point)
            if not device.ends.usable(point):
                return
        else:
            device.rows += 1
        device.logged_worst = point[0] if device.logged_worst is None else min(device.logged_worst, point[0])

    def _sent(self, device, point):
        part = device.part
        if part is None:
            part = device.part = Ends()
            self._parted.append(device)
        before = len(part.chosen())
        part.add(point)
        self.kept += len(part.chosen()) - before
        ends = device.ends
        device.sent = tuple(p for p in device.sent + (point,) if p is ends.best or p is ends.edge or p is ends.blind)

    def _done(self, device):
        if self.extremes:
            return not device.fresh or all(point in device.sent for point in device.ends.chosen())
        return device.best[0] <= device.logged_best and device.worst[0] >= device.logged_worst

    def find(self, kind, mac):
        """The device a log row names, whose address may be written in another case."""
        return self.devices.get((kind, mac.upper())) or self.devices.get((kind, mac))

    def log_rows(self, device):
        """Rows the device has in the log, or will have once the open part is finished."""
        part = device.part
        return device.rows + (len(part.chosen()) if part is not None else 0)

    def reset_part(self):
        """The open part of the log has ended. Returns the rows it was to keep."""
        with self.lock:
            for device in self._parted:
                device.part = None
            kept, self._parted, self.kept = self.kept, [], 0
            return kept

    def add_rows(self, counts):
        """A part of the log is finished, and holds counts[(type, mac)] rows of each device."""
        with self.lock:
            for (kind, mac), rows in counts.items():
                device = self.find(kind, mac)
                if device is not None:
                    device.rows += rows

    def new_part(self, counts):
        """The open part of the log is finished, and holds counts[(type, mac)] rows of each device."""
        self.reset_part()
        self.add_rows(counts)

    def take_extremes(self, idle_before=None):
        """Strongest and weakest sightings that no log row carries yet.

        Each is returned once, as (device, point), and counts as logged from then on.
        With idle_before, only devices not heard since that time are considered."""
        out = []
        with self.lock:
            for device in list(self._fresh.values()) if self.extremes else self.devices.values():
                if device.ignored and self.extremes:
                    del self._fresh[(device.kind, device.mac)]
                if device.best is None or device.ignored:
                    continue
                if idle_before is not None and device.last_seen > idle_before:
                    continue
                if self.extremes:
                    for point in device.ends.chosen():
                        if point not in device.sent:
                            out.append((device, point))
                            self._logged(device, point)
                    device.fresh = False
                    del self._fresh[(device.kind, device.mac)]
                    continue
                if device.best[0] > device.logged_best:
                    out.append((device, device.best))
                    self._logged(device, device.best)
                if device.worst[0] < device.logged_worst:
                    out.append((device, device.worst))
                    self._logged(device, device.worst)
        out.sort(key=lambda item: item[1][3])
        return out

    def recent(self, limit=50, kinds=None):
        """The devices heard last, newest first, and those heard in the same moment in the order they were found.

        After hours of driving there are far too many devices to walk them all for every frame."""
        found = []
        with self.lock:
            for device in reversed(self.devices.values()):
                if len(found) >= limit and device.last_seen != found[-1].last_seen:
                    break
                if kinds is None or device.kind in kinds:
                    found.append(device)
        found.sort(key=lambda d: (-d.last_seen, d.order))
        return found[:limit]

    def found(self):
        """Every device, in the order it was first heard."""
        with self.lock:
            return sorted(self.devices.values(), key=lambda d: d.order)

    def forget(self, limit, idle_before):
        """On a very long drive, free memory: past `limit` devices, drop the ones unheard for longest.

        Only devices unheard since idle_before with nothing left to log go. They are returned, and one
        heard again later simply counts as new.
        """
        gone = []
        with self.lock:
            spare = len(self.devices) - limit
            if spare <= 0:
                return gone
            for key, device in self.devices.items():
                if len(gone) >= spare + limit // 5 or device.last_seen > idle_before:
                    break
                if device.best is None or device.ignored or self._done(device):
                    gone.append(key)
            gone = [self.devices.pop(key) for key in gone]
            for key in [key for key in self._fresh if key not in self.devices]:
                del self._fresh[key]
        return gone

    def summary(self):
        with self.lock:
            return {"wifi": self.counts.get(WIFI, 0), "ble": self.counts.get(BLE, 0) + self.counts.get(BT, 0),
                    "total": len(self.devices), "bands": dict(self.bands), "security": dict(self.security),
                    "sightings": self.sightings}
