"""LoRa mesh nodes heard with the Cap LoRa-1262 during a wardrive, for WDGWars and Wardrift. WiGLE takes none.

One thread owns the radio. It listens on Meshtastic LongFast and on MeshCore's public settings for the country in
turn, DWELL seconds each, as one radio hears one setting at a time. Each node is kept once, with the sighting where it
was heard strongest and the one where it was heard weakest, each at the Cardputer's own position and time. A sighting
through fewer hops always wins over one relayed further, as only a direct one says where the node itself is. The
position a node gives of itself is kept beside them.

Nodes heard through the internet (MQTT) and packets without a signal reading are left out. Quartermaster never
transmits, so it has no node of its own to leave out.

While LoRaWAN networks alert in Drive Alerts, LoRaWAN uplinks take a turn as well. What is heard there names an
operator for Drive Alerts and never becomes a mesh node.

The nodes are saved every JOURNAL_SECONDS in a hidden journal, and at the stop as a mesh.json.gz beside the WiGLE
log, with a summary CSV.
"""

import base64
import csv
from datetime import datetime, timezone
import gzip
import io
import json
import math
from pathlib import Path
import re
import threading
import time
import uuid

from . import __version__, adsb, faults, lora, lorawan, meshpackets, wigle

JOURNAL_SECONDS = 30.0
RETRY_SECONDS = 30.0
RETIME_SECONDS = 2.0
MAX_NODES = 20000
WDGWARS_BATCH = 1000
WARDRIFT_BATCH = 100
WARDRIFT_MAX_BYTES = 2_000_000
FILE_GLOB = "quartermaster_*.mesh.json.gz"
JOURNAL_GLOB = ".quartermaster_*.mesh.json.part"
NETWORKS = ("meshtastic", "meshcore")
SUMMARY_COLUMNS = ("Network", "NodeID", "Name", "ShortName", "Role", "FirstSeen", "LastSeen", "Heard",
                   "StrongestRSSI", "StrongestSNR", "Hops", "ClosestRSSI", "ClosestLatitude", "ClosestLongitude",
                   "ClosestAccuracy", "ClosestTime", "FurthestRSSI", "FurthestLatitude", "FurthestLongitude",
                   "FurthestAccuracy", "FurthestTime", "OwnLatitude", "OwnLongitude", "OwnTime")
REPEATERS = ("ROUTER", "ROUTER_LATE", "ROUTER_CLIENT", "REPEATER")
SENSORS = ("SENSOR", "LOST_AND_FOUND")
WARDRIFT_TYPES = ("COMPANION", "REPEATER", "ROOM_SERVER", "SENSOR")
_NAME = re.compile(r"quartermaster_\d{8}-\d{6}(-\d+)?\.mesh\.json\.gz")
_ID = {"meshtastic": re.compile(r"[0-9a-f]{8}"), "meshcore": re.compile(r"[0-9a-f]{16}")}
_KEY = re.compile(r"[0-9a-f]{64}")

STARTING, LISTENING, NO_BAND, FAILED = "starting", "listening", "no_band", "failed"
WORDS = dict(lora.WORDS, **{STARTING: "Starting", LISTENING: "Listening", NO_BAND: "No LoRa band for this country",
                            FAILED: "It stopped. Trying again soon."})


def is_mesh(path):
    return str(path).endswith(".mesh.json.gz")


def file_for(log):
    log = Path(log)
    return log.with_name(log.name.replace(".wigle.csv", ".mesh.json.gz"))


def summary_path(path):
    path = Path(path)
    return path.with_name(path.name.replace(".mesh.json.gz", ".mesh.csv"))


def journal_path(path):
    path = Path(path)
    return path.with_name("." + path.name.replace(".json.gz", ".json.part"))


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) \
        else None


def _text(value, limit):
    return "".join(c for c in value if c.isprintable()).strip()[:limit] if isinstance(value, str) else ""


def _utc(epoch):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(epoch)) if epoch else ""


def _iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _hops(point):
    """How direct a sighting is: its hops, with an unknown count after every known one."""
    return 8 if point[2] is None else point[2]


def _stronger(point, other):
    return other is None or (_hops(point), -point[0]) < (_hops(other), -other[0])


class Node:
    """One mesh node. A sighting is (rssi, snr, hops, lat, lon, accuracy, epoch); lat, lon and accuracy are None
    when the Cardputer had no usable fix."""

    __slots__ = ("network", "id", "public_key", "name", "short_name", "role", "first", "last", "heard", "best",
                 "near", "far", "own")

    def __init__(self, network, node_id, when):
        self.network, self.id = network, node_id
        self.public_key = self.name = self.short_name = self.role = ""
        self.first = self.last = when
        self.heard = 0
        self.best = self.near = self.far = self.own = None

    def hear(self, packet, point):
        when = point[6]
        self.first, self.last = min(self.first, when), max(self.last, when)
        self.heard += 1
        for key, limit in (("public_key", 64), ("name", 40), ("short_name", 8), ("role", 16)):
            value = _text(packet.get(key), limit)
            if value:
                setattr(self, key, value)
        if packet.get("position"):
            self.own = (packet["position"][0], packet["position"][1], when)
        if _stronger(point, self.best):
            self.best = point
        if point[3] is None:
            return
        if _stronger(point, self.near):
            self.near = point
        far = self.far
        if far is None or _hops(point) < _hops(far) or _hops(point) == _hops(far) and point[0] < far[0]:
            self.far = point

    def shift(self, delta):
        self.first, self.last = self.first + delta, self.last + delta
        for name in ("best", "near", "far"):
            point = getattr(self, name)
            if point is not None:
                setattr(self, name, point[:6] + (point[6] + delta,))
        if self.own is not None:
            self.own = self.own[:2] + (self.own[2] + delta,)

    def dump(self):
        return [self.network, self.id, self.public_key, self.name, self.short_name, self.role, self.first, self.last,
                self.heard, self.best and list(self.best), self.near and list(self.near),
                self.far and list(self.far), self.own and list(self.own)]

    @classmethod
    def restore(cls, row):
        network, node_id, key, name, short, role, first, last, heard, best, near, far, own = row
        if network not in NETWORKS or not isinstance(node_id, str) or not _ID[network].fullmatch(node_id) or \
                _number(first) is None or _number(last) is None:
            raise ValueError(node_id)
        node = cls(network, node_id, first)
        node.last, node.heard = last, int(heard) if isinstance(heard, int) else 0
        node.public_key = key if isinstance(key, str) and _KEY.fullmatch(key) else ""
        node.name, node.short_name, node.role = _text(name, 40), _text(short, 8), _text(role, 16)
        node.best, node.near, node.far = _point(best), _point(near), _point(far)
        if own is not None:
            lat, lon, when = own
            if None in (_number(lat), _number(lon), _number(when)):
                raise ValueError(own)
            node.own = (lat, lon, when)
        return node

    def entry(self):
        out = {"network": self.network, "node_id": self.id, "name": self.name, "first_seen": self.first,
               "last_seen": self.last, "heard": self.heard}
        for key in ("public_key", "short_name", "role"):
            if getattr(self, key):
                out[key] = getattr(self, key)
        if self.best is not None:
            out.update(rssi=round(self.best[0], 1), snr=round(self.best[1], 2))
            if self.best[2] is not None:
                out["hops"] = self.best[2]
        for key, point in (("closest", self.near), ("furthest", self.far)):
            if point is not None:
                out[key] = {"lat": round(point[3], 7), "lon": round(point[4], 7), "accuracy": point[5],
                            "rssi": round(point[0], 1), "snr": round(point[1], 2), "hops": point[2],
                            "time": point[6]}
        if self.own is not None:
            out["reported"] = {"lat": self.own[0], "lon": self.own[1], "time": self.own[2]}
        return out

    def summary_row(self):
        def place(point):
            if point is None:
                return [""] * 5
            return ["%.1f" % point[0], "%.7f" % point[3], "%.7f" % point[4], "" if point[5] is None else point[5],
                    _utc(point[6])]
        best = self.best
        return [self.network, self.id, self.name, self.short_name, self.role, _utc(self.first), _utc(self.last),
                self.heard, "" if best is None else "%.1f" % best[0], "" if best is None else "%.2f" % best[1],
                "" if best is None or best[2] is None else best[2], *place(self.near), *place(self.far),
                *(["%.7f" % self.own[0], "%.7f" % self.own[1], _utc(self.own[2])] if self.own else ["", "", ""])]


def _point(value):
    if value is None:
        return None
    rssi, snr, hops, lat, lon, accuracy, when = value
    if None in (_number(rssi), _number(snr), _number(when)) or hops is not None and not isinstance(hops, int):
        raise ValueError(value)
    if lat is not None and (_number(lat) is None or _number(lon) is None):
        raise ValueError(value)
    return (rssi, snr, hops, lat, lon if lat is not None else None, _number(accuracy), when)


class Mesh:
    """Every node of one wardrive, by network and id."""

    def __init__(self):
        self.nodes = {}
        self.changed = False

    def __len__(self):
        return len(self.nodes)

    def hear(self, packet, rssi, snr, when, place=None):
        """Take one decoded packet. place is (lat, lon, accuracy) of the Cardputer, or None without a usable fix.
        Returns the node, or None when the packet is not one to keep."""
        if not packet or packet.get("via_mqtt") or _number(snr) is None or _number(rssi) is None:
            return None
        network, node_id = packet.get("network"), packet.get("node")
        if network not in NETWORKS or not isinstance(node_id, str) or not _ID[network].fullmatch(node_id):
            return None
        key = (network, node_id)
        node = self.nodes.get(key)
        if node is None:
            if len(self.nodes) >= MAX_NODES:
                return None
            node = self.nodes[key] = Node(network, node_id, when)
        lat, lon, accuracy = place if place is not None else (None, None, None)
        hops = packet.get("hops")
        node.hear(packet, (float(rssi), float(snr), hops if isinstance(hops, int) else None, lat, lon,
                           _number(accuracy), when))
        self.changed = True
        return node

    def shift(self, delta):
        for node in self.nodes.values():
            node.shift(delta)
        self.changed = self.changed or bool(self.nodes)

    def dump(self, name, now):
        return {"name": name, "now": now, "nodes": [node.dump() for node in self.nodes.values()]}

    @classmethod
    def restore(cls, data):
        mesh = cls()
        for row in data.get("nodes") or ():
            try:
                node = Node.restore(row)
            except (TypeError, ValueError):
                continue
            mesh.nodes[(node.network, node.id)] = node
        return mesh

    def document(self, now, listened=()):
        return {"app": "Quartermaster %s" % __version__, "format": "quartermaster-mesh-1", "now": now,
                "listened": list(listened),
                "nodes": [node.entry() for node in self.nodes.values()]}


def _json(document):
    """Compact JSON, one node at a time, so the screen thread is never held up for the whole list."""
    nodes = document.pop("nodes")
    head = json.dumps(document, separators=(",", ":"))
    return (head[:-1] + ',"nodes":[' + ",".join(json.dumps(node, separators=(",", ":")) for node in nodes) +
            "]}").encode("utf-8")


def write(path, mesh, now, listened=()):
    """The mesh file and its summary. Nothing is written for a wardrive that heard no node."""
    if not len(mesh):
        return False
    path = Path(path)
    text = _json(mesh.document(now, listened))

    def packed(out):
        with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=int(now)) as zipped:
            zipped.write(text)

    def table(out):
        lines = io.StringIO()
        rows = csv.writer(lines, lineterminator="\n")
        rows.writerow(SUMMARY_COLUMNS)
        rows.writerows(node.summary_row() for node in mesh.nodes.values())
        out.write(lines.getvalue().encode("utf-8"))
    adsb._replace(summary_path(path), table)
    adsb._replace(path, packed)
    adsb.settle(path.parent)
    return True


def save_journal(journal, mesh, name, now):
    data = _json(mesh.dump(name, now))
    adsb._replace(Path(journal), lambda out: out.write(data))
    mesh.changed = False


def recover(logs):
    """Finish the mesh files of a wardrive that a crash or a power cut ended. Returns the files written."""
    logs, done = Path(logs), []
    for journal in sorted(logs.glob(JOURNAL_GLOB)):
        try:
            data = json.loads(journal.read_text(encoding="utf-8"))
            name = data.get("name")
            if not isinstance(name, str) or not _NAME.fullmatch(name):
                name = journal.name[1:].replace(".json.part", ".json.gz")
            target = logs / name
            if not target.exists() and _number(data.get("now")) is not None:
                if write(target, Mesh.restore(data), data["now"]):
                    done.append(target)
        except OSError:
            faults.note("Finishing an earlier mesh log")
            continue
        except (ValueError, AttributeError):
            pass
        try:
            journal.unlink(missing_ok=True)
        except OSError:
            pass
    for leftover in logs.glob(".quartermaster_*.mesh.*.tmp"):
        try:
            leftover.unlink(missing_ok=True)
        except OSError:
            pass
    return done


def load(path):
    with gzip.open(path, "rb") as source:
        data = json.loads(source.read(64 * 1024 * 1024).decode("utf-8"))
    if not isinstance(data, dict) or _number(data.get("now")) is None or not isinstance(data.get("nodes"), list):
        raise ValueError("not a mesh file")
    return data


def node_type(node):
    """The role in the words WDGWars and Wardrift use: COMPANION, REPEATER, ROOM_SERVER or SENSOR."""
    role = str(node.get("role") or "").upper()
    if node.get("network") == "meshcore":
        return role if role in WARDRIFT_TYPES else "REPEATER"
    return "REPEATER" if role in REPEATERS else "SENSOR" if role in SENSORS else "COMPANION"


def _valid(node):
    network, node_id = node.get("network"), node.get("node_id")
    if network not in NETWORKS or not isinstance(node_id, str) or not _ID[network].fullmatch(node_id):
        return False
    if network == "meshcore":
        key = node.get("public_key")
        return isinstance(key, str) and bool(_KEY.fullmatch(key)) and key.startswith(node_id)
    return True


def _own(node):
    reported = node.get("reported")
    if not isinstance(reported, dict):
        return None
    lat, lon = _number(reported.get("lat")), _number(reported.get("lon"))
    if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180) or \
            abs(lat) < 1e-6 and abs(lon) < 1e-6:
        return None
    return round(lat, 6), round(lon, 6)


def wdgwars_records(data):
    """WDGWars' meshcore_nodes: each node at the position it gave of itself. A node that gave none is left out,
    as WDGWars puts a node on its map where the node is."""
    out = []
    for node in data.get("nodes") or ():
        if not isinstance(node, dict) or not _valid(node):
            continue
        place, first = _own(node), _number(node.get("first_seen"))
        if place is None or first is None or first < wigle.MIN_EPOCH:
            continue
        record = {"node_id": node["node_id"], "node_type": node_type(node),
                  "name": _text(node.get("name"), 64) or node["node_id"], "lat": place[0], "lon": place[1],
                  "rssi": _number(node.get("rssi")), "first_seen": _utc(first), "type": "MESHCORE",
                  "network": node["network"]}
        if node["network"] == "meshcore":
            record["public_key"] = node["public_key"]
        if isinstance(node.get("hops"), int):
            record["path_hops"] = node["hops"]
        out.append(record)
    return out


def _utf16(value, units):
    return value.encode("utf-16-le", errors="replace")[:units * 2].decode("utf-16-le", errors="ignore")


def wardrift_nodes(data, now):
    """Wardrift's mesh nodes: every node heard, with the position it gave of itself when it gave one."""
    out = []
    for node in data.get("nodes") or ():
        if not isinstance(node, dict) or not _valid(node):
            continue
        last = _number(node.get("last_seen"))
        if last is None or last < wigle.MIN_EPOCH:
            continue
        wire = {"network": node["network"], "node_id": node["node_id"]}
        if node["network"] == "meshcore":
            wire["public_key"] = node["public_key"]
        wire["node_type"] = node_type(node)
        wire["name"] = _utf16(_text(node.get("name"), 80), 80) or node["node_id"]
        place = _own(node)
        if place is not None:
            wire.update(lat=place[0], lon=place[1])
        snr = _number(node.get("snr"))
        if snr is not None and -100 <= snr <= 100:
            wire["snr"] = snr
        if isinstance(node.get("hops"), int) and 0 <= node["hops"] <= 255:
            wire["hops"] = node["hops"]
        wire["last_heard"] = _iso(min(last, now))
        out.append(wire)
    return out


def wdgwars_body(records, key, nonce):
    """The signed envelope: base64 of the payload, a nonce, and HMAC-SHA256 of nonce + data under the API key."""
    import hashlib
    import hmac
    payload = {"networks": [], "aircraft": [], "meshcore_nodes": records}
    data = base64.b64encode(json.dumps(payload, separators=(",", ":")).encode("utf-8")).decode("ascii")
    sig = hmac.new(key.encode("utf-8"), (nonce + data).encode("ascii"), hashlib.sha256).hexdigest()
    return json.dumps({"data": data, "nonce": nonce, "sig": sig}, separators=(",", ":")).encode("ascii")


def wardrift_bodies(nodes, now, reporter, sequence):
    """Wardrift's requests: at most WARDRIFT_BATCH nodes and WARDRIFT_MAX_BYTES each. sequence() gives the next
    number, always higher than the one before. Yields (body bytes, batch id, nodes in it)."""
    start = 0
    while start < len(nodes):
        body = {"now": _iso(now), "nodes": [], "batch_id": str(uuid.uuid4()), "reporter_id": reporter,
                "sequence_no": 0}
        while start < len(nodes) and len(body["nodes"]) < WARDRIFT_BATCH:
            body["nodes"].append(nodes[start])
            if len(json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")) + 24 > \
                    WARDRIFT_MAX_BYTES and len(body["nodes"]) > 1:
                body["nodes"].pop()
                break
            start += 1
        body["sequence_no"] = sequence()
        yield (json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8"), body["batch_id"],
               len(body["nodes"]))


class Listener:
    """The mesh side of one wardrive. The radio is opened, read and closed by one thread of its own."""

    def __init__(self, logs, gps, radio, plan, clock=time.time, log=None, max_hdop=None, epoch=None,
                 dwell=lora.DWELL_SECONDS, retry=RETRY_SECONDS, gate=None):
        self.logs, self.gps, self.radio_factory, self.plan = Path(logs), gps, radio, list(plan)
        self.clock, self.log, self.max_hdop = clock, log or (lambda: None), max_hdop
        self.epoch = epoch or (lambda fix: self.clock())
        self.dwell, self.retry = dwell, retry
        self.gate = gate or (lambda: True)
        self.mesh = Mesh()
        self.lorawan_sink = None
        self.operators = lorawan.Operators()
        self._replan = None
        self.state = STARTING if self.plan else NO_BAND
        self.reason = ""
        self.packets = 0
        self.radio = None
        self.index = 0
        self._deadline = 0.0
        self.target = self.journal = self.started = None
        self._journaled = self._failed_at = None
        self._offset = None
        self._stop = threading.Event()
        self._thread = None
        self._lock = threading.Lock()

    @property
    def count(self):
        return len(self.mesh)

    @property
    def profile(self):
        return self.plan[self.index] if self.plan else None

    def status(self):
        detail = self.profile.short if self.state == LISTENING else WORDS.get(self.reason or self.state, "")
        return {"state": self.state, "nodes": len(self.mesh), "packets": self.packets, "detail": detail,
                "reason": self.reason}

    def prepare(self, epoch):
        serial = 0
        while True:
            target = self.logs / wigle.log_filename(epoch, serial).replace(".wigle.csv", ".mesh.json.gz")
            if not target.exists() and not journal_path(target).exists():
                break
            serial += 1
        self.target, self.journal, self.started = target, journal_path(target), epoch
        self._journaled = time.monotonic()

    def replan(self, plan):
        """A new list to listen on in turn, such as with LoRaWAN uplinks added. The radio thread takes it up."""
        self._replan = list(plan)

    def start(self, epoch):
        self.prepare(epoch)
        fix = self.gps.snapshot()
        if fix.get("utc"):
            self._offset = self.epoch(fix) - self.clock()
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True, name="lora")
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(5)

    def name(self):
        log = self.log()
        return file_for(log) if log is not None else self.target

    def finish(self):
        """Write the mesh file beside the WiGLE log, or under the wardrive's own time without one. Returns it, or None
        when no node was heard."""
        with self._lock:
            journal = self.journal
            if self.log() is None and self.started < wigle.MIN_EPOCH and len(self.mesh):
                self.prepare(min(node.first for node in self.mesh.nodes.values()))
            path = self.name()
            written = write(path, self.mesh, self._now(),
                            [profile.short for profile in self.plan if profile.protocol in NETWORKS])
            for hidden in {journal, self.journal}:
                try:
                    hidden.unlink(missing_ok=True)
                except OSError:
                    pass
            return path if written else None

    def checkpoint(self):
        """Put the nodes heard so far on disk now, so that a power cut loses none of them."""
        with self._lock:
            if self.journal is None or not len(self.mesh):
                return
            self._journaled = time.monotonic()
            save_journal(self.journal, self.mesh, self.name().name, self._now())
            adsb.settle(self.journal.parent)

    def discard(self):
        """Throw the nodes of this wardrive away: nothing is written and the journal goes. False when it could not
        be removed."""
        with self._lock:
            self.mesh, gone = Mesh(), True
            if self.journal is not None:
                for hidden in (self.journal, self.journal.with_name(self.journal.name + ".tmp")):
                    try:
                        hidden.unlink(missing_ok=True)
                    except OSError:
                        gone = False
            return gone

    def _time(self, fix):
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
            self.mesh.shift(delta)
            self.prepare(self.started + delta)
            if old is not None and old != self.journal and old.exists():
                try:
                    save_journal(self.journal, self.mesh, self.name().name, self._now())
                    old.unlink(missing_ok=True)
                except OSError:
                    faults.note("Saving the mesh journal")

    def _now(self):
        fix = self.gps.snapshot()
        now = self.epoch(fix) if fix.get("utc") or self._offset is None else self.clock() + self._offset
        return max([now] + [node.last for node in self.mesh.nodes.values()])

    def _run(self):
        try:
            while not self._stop.is_set():
                try:
                    self._step()
                except lora.RadioError as exc:
                    self._fail(str(exc))
                except Exception:
                    faults.note("LoRa mesh")
                    self._fail("")
        finally:
            self._close()

    def _step(self):
        if not self.plan:
            self._stop.wait(1.0)
            return
        if self.radio is None:
            if self._failed_at is not None and time.monotonic() - self._failed_at < self.retry:
                self._stop.wait(1.0)
                return
            radio = self.radio_factory()
            self.radio = radio
            radio.open(self.plan[0])
            self.index, self._deadline = 0, time.monotonic() + self.dwell
            self.state, self.reason = LISTENING, ""
        heard = self.radio.receive(0.25, self._stop.wait)
        if heard is not None:
            self._heard(*heard)
        replan, self._replan = self._replan, None
        if replan and replan != self.plan:
            current = self.plan[self.index]
            self.plan = replan
            self.index = replan.index(current) if current in replan else 0
            if current not in replan:
                self.radio.tune(self.plan[self.index])
                self._deadline = time.monotonic() + self.dwell
        if len(self.plan) > 1 and time.monotonic() >= self._deadline:
            self.index = (self.index + 1) % len(self.plan)
            self.radio.tune(self.plan[self.index])
            self._deadline = time.monotonic() + self.dwell
        self._save()

    def _heard(self, raw, rssi, snr, crc_ok):
        if not crc_ok:
            return
        if self.plan[self.index].protocol == "lorawan":
            hit = self.operators.note(raw, rssi, time.monotonic())
            sink = self.lorawan_sink
            if hit is not None and sink is not None:
                sink(hit)
            return
        if not self.gate():
            return
        self.packets += 1
        packet = meshpackets.decode(raw, self.plan[self.index].protocol)
        if packet is None:
            return
        fix = self.gps.snapshot()
        epoch = self._time(fix)
        place = None
        if wigle.usable(fix, epoch, self.max_hdop):
            accuracy = wigle.accuracy_m(fix)
            place = (fix["latitude"], fix["longitude"], accuracy if accuracy != "" else None)
        with self._lock:
            self.mesh.hear(packet, rssi, snr, epoch, place)

    def _save(self):
        if self.mesh.changed and time.monotonic() - self._journaled >= JOURNAL_SECONDS:
            self._journaled = time.monotonic()
            with self._lock:
                try:
                    save_journal(self.journal, self.mesh, self.name().name, self._now())
                except OSError:
                    faults.note("Saving the mesh journal")

    def _fail(self, reason):
        self._close()
        self.state, self.reason = FAILED, reason if reason in WORDS else ""
        self._failed_at = time.monotonic()

    def _close(self):
        radio, self.radio = self.radio, None
        if radio is not None:
            try:
                radio.close()
            except Exception:
                pass
