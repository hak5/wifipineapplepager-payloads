"""Quartermaster Nodes: ESP32-C5 boards on USB that scan Wi-Fi and Bluetooth LE for Quartermaster.

The serial line is described in firmware/PROTOCOL.md. A NodeManager finds the nodes plugged in, keeps one NodeLink
open per node, and shares the Wi-Fi channels between the nodes in use while a wardrive or Recon runs. What a node
hears reaches the wardrive in the same shape as a sweep of an adapter, a batch at a time.

One node on USB may be the hub of up to 8 wireless nodes. It scans nothing: it passes their lines on in @R lines,
which an AirLink per wireless node reads as a NodeLink reads its port, and their commands go out through it as #TO.
"""

from collections import deque
import os
from pathlib import Path
import secrets
import threading
import time

from . import dragon_link, faults, hardware, planner
from .config import MAX_NODES, MAX_WIRELESS, NODE_NAME_MAX, cluster_key, node_entries
from .wifi import band_of, security_label

BAUD = 921600
READ_SECONDS = 0.2
PROBE_SECONDS = 1.5
HELLO_SECONDS = 10.0
SILENT_SECONDS = 35.0
SCAN_SECONDS = 3.0
BATCH_SECONDS = 0.5
BATCH_LINES = 64
NUDGE_SECONDS = 3.0
AIR_NUDGE_SECONDS = 8.0
RETRIES = (0.0, 5.0, 30.0)
NODE_RETRY_SECONDS = 10.0
BRIDGE_SECONDS = 15.0
PROTOCOL = "1"
SEQUENCED = ("W", "B", "S", "A", "L", "C", "N", "J")
REMOTE = ("HELLO", "PLAN", "IDENT", "LED", "REBOOT")
PLAN_FIELDS = ("args", "version", "country", "bitmap", "time", "ble")
HUB_CHANNEL = "6"
HUB_QUIET_SECONDS = 16.0
AIR_SILENT_SECONDS = 30.0
AIR_LATE_MS = 15000
JOIN_SECONDS = 30.0
PAIR_SECONDS = 60
FORGET_SECONDS = 60.0

NO_SERIAL = "Nodes need python3-serial. Reinstall Quartermaster."
UNPLUGGED = "Unplugged"
SILENT = "Stopped answering. Plug it in again."
NOT_PLUGGED = "Not plugged in"
UPDATING = "Being updated"
NEWER = "Update Quartermaster to use this node"
OLDER = "Needs a firmware update"
REFUSED = "Did not take its channels"
NO_BLE = "No Bluetooth: the node is short of memory"
FULL = "Quartermaster takes up to %d nodes" % MAX_NODES
NOT_A_NODE = "That is not a node"
FULL_WIRELESS = "The hub takes up to %d wireless nodes" % MAX_WIRELESS
NO_HUB = "Waiting for the hub. Plug it in."
NO_HUB_SET = "No hub. Make a plugged-in node the hub."
AWAY = "Not heard for 30 s. Out of range or off?"
NOT_ON_HUB = "Not on this hub. Add it again."
NO_ESPNOW = "Needs a firmware update to be a hub"
HUB_FAILED = "Could not start as a hub. Plug it in again."
ADMIT_ERRORS = {"node": "It stopped asking. Hold BOOT on it for 2 seconds again.", "full": FULL_WIRELESS,
                "radio": "The hub's radio failed. Try again.", "role": "The hub is restarting. Try again."}

AUTH = {0: "OPEN", 1: "WEP", 2: "WPA_PSK", 3: "WPA2_PSK", 4: "WPA_WPA2_PSK", 5: "WPA2_ENTERPRISE", 6: "WPA3_PSK",
        7: "WPA2_WPA3_PSK", 8: "WAPI_PSK", 9: "OWE", 10: "WPA3_ENT_192", 11: "WPA3_EXT_PSK",
        12: "WPA3_EXT_PSK_MIXED_MODE", 13: "DPP", 14: "WPA3_ENTERPRISE", 15: "WPA2_WPA3_ENTERPRISE",
        16: "WPA_ENTERPRISE", 17: "UNKNOWN"}
# What the scan of an adapter makes of the same network. A WAPI network shows only its privacy bit there.
_AUTH_PARTS = {
    "OPEN": (), "WEP": ("[WEP]",), "WPA_PSK": ("[WPA-PSK-%s]",), "WPA2_PSK": ("[WPA2-PSK-%s]",),
    "WPA_WPA2_PSK": ("[WPA-PSK-%s]", "[WPA2-PSK-%s]"), "WPA2_ENTERPRISE": ("[WPA2-EAP-%s]",),
    "WPA3_PSK": ("[RSN-SAE-%s]",), "WPA2_WPA3_PSK": ("[WPA2-PSK-%s]", "[RSN-SAE-%s]"), "WAPI_PSK": ("[WEP]",),
    "OWE": ("[RSN-OWE-%s]",), "WPA3_ENT_192": ("[WPA2-EAP-%s]",), "WPA3_EXT_PSK": ("[RSN-SAE-%s]",),
    "WPA3_EXT_PSK_MIXED_MODE": ("[RSN-SAE-%s]",), "DPP": ("[RSN-DPP-%s]",), "WPA3_ENTERPRISE": ("[WPA2-EAP-%s]",),
    "WPA2_WPA3_ENTERPRISE": ("[WPA2-EAP-%s]",), "WPA_ENTERPRISE": ("[WPA-EAP-%s]",), "UNKNOWN": (),
}
CIPHERS = {3: "TKIP", 4: "CCMP", 5: "CCMP+TKIP", 8: "GCMP", 9: "GCMP-256"}
_security = {}


def xor(data):
    """The XOR of every byte, folded in halves: far quicker in Python than a byte at a time."""
    size, value = len(data), int.from_bytes(data, "little")
    while size > 1:
        size = (size + 1) // 2
        value = (value & ((1 << 8 * size) - 1)) ^ (value >> 8 * size)
    return value


def command(name, *args):
    body = ",".join((name,) + args).encode("ascii")
    return b"#%s*%02X\n" % (body, xor(body))


def parse(line):
    """The fields of a node line, None for a line that is not one (boot text, logs), False for a damaged one."""
    if not line.startswith(b"@"):
        return None
    if line.endswith(b"\r"):
        line = line[:-1]
    if len(line) < 6 or line[-3:-2] != b"*":
        return False
    body = line[1:-3]
    try:
        if xor(body) != int(line[-2:], 16):
            return False
        return body.decode("ascii").split(",")
    except (ValueError, UnicodeDecodeError):
        return False


def security(auth, pairwise, wps):
    """(capabilities, short label) of a network as WiGLE and the live screen show it."""
    key = (auth, pairwise, wps)
    found = _security.get(key)
    if found is None:
        cipher = CIPHERS.get(pairwise, "CCMP")
        parts = [part % cipher if "%" in part else part for part in _AUTH_PARTS.get(AUTH.get(auth, "UNKNOWN"), ())]
        caps = "".join(dict.fromkeys(parts + (["[WPS]"] if wps else []) + ["[ESS]"]))
        found = _security[key] = (caps, security_label({"capabilities": caps}))
    return found


def wifi_record(fields):
    """An @W line as a network of an adapter's sweep."""
    if len(fields) != 12:
        return None
    try:
        age, rssi, channel, frequency = int(fields[2]), int(fields[4]), int(fields[5]), int(fields[6])
        auth, pairwise, flags = int(fields[7]), int(fields[8]), int(fields[10], 16)
        raw = bytes.fromhex(fields[11])
    except ValueError:
        return None
    bssid = fields[3].upper()
    if len(bssid) != 17:
        return None
    ssid = raw.decode("utf-8", "replace")[:32] if raw.strip(b"\x00") else ""
    caps, label = security(auth, pairwise, bool(flags & 2))
    return {"bssid": bssid, "ssid": ssid, "rssi": rssi, "channel": channel, "frequency": frequency,
            "band": band_of(frequency), "security": label, "capabilities": caps, "hidden": not ssid,
            "wps": bool(flags & 2), "age_ms": age}


def ble_record(fields):
    """A @B line as a device of a Bluetooth scan."""
    if len(fields) != 9:
        return None
    try:
        age, kind, rssi, flags = int(fields[2]), int(fields[4]), int(fields[5]), int(fields[6], 16)
        maker = int(fields[7], 16) if fields[7] else None
        name = bytes.fromhex(fields[8]).decode("utf-8", "replace")
    except ValueError:
        return None
    address = fields[3].upper()
    if len(address) != 17:
        return None
    return {"address": address, "address_type": 0 if kind == 0 else 1, "rssi": rssi, "name": name, "uuids": [],
            "manufacturer": {} if maker is None else {maker: b""}, "service_data": {}, "tx_power": None,
            "appearance": None, "classic": False, "connectable": bool(flags & 1), "age_ms": age}


def hello_record(fields):
    if len(fields) != 12 or len(fields[2]) != 12:
        return None
    try:
        int(fields[2], 16)
        return {"protocol": fields[1], "id": fields[2].lower(), "firmware": fields[3], "chip": fields[4],
                "flash_mb": int(fields[5]), "psram_mb": int(fields[6]), "board": fields[7],
                "capabilities": tuple(cap for cap in fields[8].split("+") if cap), "country": fields[9],
                "plan": int(fields[10]), "state": fields[11]}
    except ValueError:
        return None


def status_record(fields):
    if len(fields) != 11:
        return None
    try:
        values = [int(value) for value in fields[2:10]]
    except ValueError:
        return None
    names = ("uptime_ms", "sweeps", "sweep_ms", "networks", "devices", "dropped", "plan", "heap")
    record = dict(zip(names, values))
    record["state"] = fields[10]
    return record


def open_port(path, factory):
    """Open a node's port without resetting the board: DTR stays up until RTS is down, so RTS is never up alone."""
    port = factory()
    port.port, port.baudrate, port.timeout, port.write_timeout = path, BAUD, READ_SECONDS, 0.5
    port.exclusive = True
    port.dtr = True
    port.rts = False
    port.open()
    port.dtr = False
    return port


class NodeLink:
    """One node on one serial port. pump() reads what has come, sends what is waiting and keeps the node awake."""

    LATE_MS = None
    AIR = False

    def __init__(self, path, port, listener=None, clock=time.monotonic):
        self.path, self.port, self.listener, self.clock = path, port, listener, clock
        self.real = os.path.realpath(path)
        self.hello = self.status = None
        self.ready = False
        self.seq = None
        self.lost = self.bad = self.late = 0
        self.notes = deque(maxlen=4)
        self.text = deque(maxlen=8)
        self.acks = {}
        self.error = ""
        self.closed = False
        self.heard = self.said = clock()
        self._ending = None
        self._buffer = b""
        self._outbox = deque()
        self._wifi, self._ble, self._batch_at = [], [], None
        self._thread = None
        self.riders = ()

    @property
    def node_id(self):
        return self.hello["id"] if self.hello else None

    def send(self, name, *args):
        """Queue a command. The reading thread writes it, so a slow port never holds up the caller."""
        if not self.closed:
            self._outbox.append(command(name, *args))

    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True, name="node-" + os.path.basename(self.path))
        self._thread.start()

    def _run(self):
        try:
            while self.pump():
                pass
        except Exception:
            faults.note("Node link")
            self._close(SILENT)

    def wait_hello(self, seconds):
        deadline = self.clock() + seconds
        while self.hello is None and self.pump() and self.clock() < deadline:
            pass
        return self.hello is not None

    def stop(self, error=""):
        """Send what is waiting and close the port. With a reading thread, waits up to a second for it to let go."""
        self._ending = error
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=1.0)
        if not self.closed:
            try:
                self._drain()
            except (OSError, ValueError, TypeError):
                pass
            self._close(error)

    def _drain(self):
        while self._outbox:
            self.port.write(self._outbox[0])
            self._outbox.popleft()
            self.said = self.clock()

    def pump(self):
        if self.closed:
            return False
        try:
            self._drain()
            if self._ending is not None:
                self._close(self._ending)
                return False
            data = self.port.read(max(1, self.port.in_waiting))
        except (OSError, ValueError, TypeError):
            self._close(UNPLUGGED)
            return False
        now = self.clock()
        if data:
            self._take(data, now)
        if self._batch_at is not None and now - self._batch_at >= BATCH_SECONDS:
            self._flush()
        for rider in self.riders:
            if rider._batch_at is not None and now - rider._batch_at >= BATCH_SECONDS:
                rider._flush()
        if now - self.heard >= SILENT_SECONDS:
            self._close(SILENT)
            return False
        if now - self.said >= HELLO_SECONDS and not self._outbox:
            self.send("HELLO")
        return True

    def _take(self, data, now):
        buffer = self._buffer + data
        if b"\n" not in data:
            self._buffer = buffer if len(buffer) <= 4096 else b""
            return
        lines = buffer.split(b"\n")
        self._buffer = lines.pop()
        for line in lines:
            try:
                self._line(line, now)
            except Exception:
                faults.note("A node line")

    def _line(self, line, now):
        fields = parse(line)
        if fields is None:
            if self.hello is None:
                self.text.append(line[:dragon_link.MAX_LINE])
            return
        self.heard = now
        if fields is False:
            if not (line.startswith(b"@R,") and self.listener is not None and self.listener.garbled(self, line[3:15])):
                self.bad += 1
            return
        if fields[0] == "R":
            if self.ready and self.listener is not None and len(fields) > 3 and fields[2][:1] == "@":
                self.listener.relayed(self, fields, now)
            return
        self._fields(fields, now)

    def _fields(self, fields, now):
        kind = fields[0]
        if kind == "H":
            hello = hello_record(fields)
            if hello is None:
                self.bad += 1
            else:
                self.hello = hello
                if self.listener is not None:
                    self.listener.heard(self, hello["plan"], hello["state"])
            return
        if kind not in SEQUENCED:
            return
        if len(fields) < 2 or not fields[1].isdigit():
            self.bad += 1
            return
        seq = int(fields[1])
        if self.seq is not None:
            gap = (seq - self.seq - 1) & 0xFFFFFFFF
            if gap < 0x80000000:
                self.lost += gap
            elif self.listener is not None:
                self.listener.restarted(self)
        if kind == "A" and len(fields) == 5:
            self.acks[fields[2]] = (fields[3] == "ok", fields[4], now)
            self.ready = True
            if self.listener is not None:
                self.listener.answered(self, fields[2], fields[3] == "ok", fields[4])
        if not self.ready:
            return
        self.seq = seq
        if kind == "W" or kind == "B":
            record = wifi_record(fields) if kind == "W" else ble_record(fields)
            if record is None:
                self.bad += 1
                return
            if self.LATE_MS is not None and record["age_ms"] > self.LATE_MS:
                self.late += 1
                return
            record["heard"], record["air"] = now - record["age_ms"] / 1000.0, self.AIR
            (self._wifi if kind == "W" else self._ble).append(record)
            if self._batch_at is None:
                self._batch_at = now
            if len(self._wifi) + len(self._ble) >= BATCH_LINES:
                self._flush()
        elif kind == "S":
            status = status_record(fields)
            if status is None:
                self.bad += 1
                return
            self.status = status
            if self.listener is not None:
                self.listener.heard(self, status["plan"], status["state"])
        elif kind == "L" and len(fields) >= 3:
            self.notes.append((now, ",".join(fields[2:])))
        elif kind in ("C", "N", "J") and self.listener is not None:
            self.listener.hub_line(self, kind, fields, now)

    def _flush(self):
        """Hand the waiting lines on. Each says how long ago it was heard, in seconds, as "lag"."""
        wifi, ble = self._wifi, self._ble
        self._wifi, self._ble, self._batch_at = [], [], None
        now = self.clock()
        for record in wifi + ble:
            record["lag"] = max(0.0, now - record.pop("heard"))
        if self.listener is not None and (wifi or ble):
            self.listener.sightings(self, wifi, ble)

    def _close(self, error):
        if self.closed:
            return
        self.closed = True
        self.error = error
        self._outbox.clear()
        try:
            self.port.close()
        except (OSError, ValueError, TypeError):
            pass
        if self.listener is not None:
            self.listener.closed(self)


class AirLink(NodeLink):
    """A wireless node, heard through the hub. Its lines come in the hub's @R lines; its commands go through the hub
    as #TO. It has no port and no thread of its own: the hub's link reads for it and sends its batches on."""

    LATE_MS = AIR_LATE_MS
    AIR = True

    def __init__(self, node_id, hub, listener=None, clock=time.monotonic):
        super().__init__(hub.path, None, listener, clock)
        self.id, self.hub = node_id, hub
        self.ready = True
        self.heard = self.asked = self.rssi = None
        self.link = "new"
        self.frames = self.resent = 0

    @property
    def node_id(self):
        return self.id

    def up(self, now):
        """Heard in the last 30 s."""
        return self.heard is not None and now - self.heard < AIR_SILENT_SECONDS

    def send(self, name, *args):
        if name in REMOTE and not self.hub.closed:
            self.hub.send("TO", self.id, name, *args)

    def pump(self):
        return False

    def start(self):
        pass

    def stop(self, error=""):
        pass

    def _fields(self, fields, now):
        if fields[0] == "H" and (len(fields) < 3 or fields[2].lower() != self.id):
            self.bad += 1
            return
        super()._fields(fields, now)


class NodeManager:
    """The nodes Quartermaster knows (in the settings) and the ones plugged in. The app owns one.

    A wardrive or Recon attaches to it while it runs: the nodes in use (in the settings and plugged in) then scan
    their share of the channels, and what they hear goes to the sinks given to attach()."""

    def __init__(self, cfg=None, serial_factory=None, sys_tty=hardware.SYS_TTY, dev=Path("/dev"),
                 by_id=hardware.BY_ID, clock=time.monotonic, threads=True, on_change=None, bridge_wait=BRIDGE_SECONDS):
        cfg = cfg or {}
        self.factory = serial_factory
        self.no_serial = False
        self.bridge_wait = bridge_wait
        self.gps_source = cfg.get("gps_source", "auto")
        self.sys_tty, self.dev, self.by_id = sys_tty, Path(dev), by_id
        self.clock = clock
        self.threads = threads
        self.on_change = on_change
        self.country = cfg.get("country", "US")
        self.configured = node_entries(cfg.get("nodes", []))
        self.error = ""
        self.lock = threading.RLock()
        self.links = {}
        self.twins = {}
        self.ports = {}
        self.tries = {}
        self.away = {}
        self.lent = {}
        self.last = {}
        self.plans = {}
        self.version = 0
        self.owner = None
        self.sinks = None
        self.ble = True
        self.bands = None
        self.given, self.started, self.refused, self.nudged, self.left = {}, set(), {}, {}, {}
        self.key = cluster_key(cfg.get("cluster_key"))
        self.on_key = None
        self.hub_link = None
        self.hub_ok = self.hub_run = False
        self.hub_error = self.pair_error = ""
        self.hub_said = self.hub_sent = None
        self.pair_until = 0.0
        self.air, self.joins, self.admitting, self.forgotten, self.tried = {}, {}, {}, {}, {}
        self.cycle, self.listed = None, []
        self.dragons, self.dragon_sink = {}, None
        self._key = None
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread = None

    def start(self):
        if self._thread is None:
            self._stop.clear()
            self._thread = threading.Thread(target=self._loop, daemon=True, name="nodes")
            self._thread.start()

    def stop(self):
        """Stop looking for nodes and close every port."""
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None
        with self.lock:
            links = list(self.links.values())
            dragons = list(self.dragons.values())
        for link in links:
            link.send("STOP")
            link.stop("")
        for dragon in dragons:
            dragon.stop()

    def _loop(self):
        while not self._stop.is_set():
            try:
                self.scan()
            except Exception:
                faults.note("Looking for nodes")
            self._wake.wait(SCAN_SECONDS)
            self._wake.clear()

    @property
    def available(self):
        return self._factory() is not None

    def _factory(self):
        if self.factory is None:
            if self.no_serial:
                return None
            try:
                import serial
            except ImportError:
                self.no_serial, self.error = True, NO_SERIAL
                return None
            self.factory = serial.Serial
        return self.factory

    def _present(self):
        """{device path: path to open} of every USB serial port, from two directory listings."""
        links = hardware.by_id_links(self.by_id)
        present = {}
        for name in hardware.usb_serial_names(self.sys_tty):
            real = os.path.realpath(str(self.dev / name))
            present[real] = (name, links.get(real, str(self.dev / name)))
        return present

    def scan(self):
        """One look at the USB serial ports: ask each new one that may be a node whether it is."""
        present = self._present()
        now = self.clock()
        gone = [real for real in self.ports if real not in present]
        for real in gone:
            dragon = self.dragons.get(real)
            if dragon is not None:
                dragon.stop()
        hardware.forget_ports(gone)
        for real in gone:
            self.ports.pop(real, None)
            self.tries.pop(real, None)
            self.twins.pop(real, None)
        for real, (name, path) in present.items():
            if real not in self.ports or self.ports[real]["path"] != path:
                self.ports[real] = {"path": path, "usb_id": hardware.usb_id_of(name, self.sys_tty), "seen": now}
        gps = os.path.realpath(self.gps_source) if self.gps_source.startswith("/") else None
        with self.lock:
            for real, port in self.ports.items():
                if port["path"] in self.lent and real not in self.away:
                    self.away[real] = self.lent[port["path"]]
                    hardware.hold_port(real, "node")
            busy = {link.real for link in self.links.values()} | set(self.away) | set(self.twins) | set(self.dragons)
        for real, port in sorted(self.ports.items(), key=lambda item: item[1]["usb_id"] != hardware.NODE_NATIVE):
            native = port["usb_id"] == hardware.NODE_NATIVE
            if self._stop.is_set():
                return
            if real in busy or not (native or port["usb_id"] in hardware.NODE_BRIDGES):
                continue
            if hardware.port_holder(real) is not None or not native and self._gps_port(real, port, gps):
                continue
            count, after = self.tries.get(real, (0, now))
            if now < after or count >= len(RETRIES) and hardware.port_mark(real) != "node":
                continue
            if self._factory() is None:
                return
            self.error = ""
            if not self._probe(real, port["path"]):
                retry = RETRIES[min(count + 1, len(RETRIES) - 1)]
                if hardware.port_mark(real) == "node":
                    retry = NODE_RETRY_SECONDS
                self.tries[real] = (count + 1, self.clock() + retry)

    def _gps_port(self, real, port, gps):
        """A bridge may be the GPS: it is left alone while the GPS layer has not had its look at it."""
        mark = hardware.port_mark(real)
        if mark == "gps" or real == gps:
            return True
        return mark not in ("node", "checked") and self.clock() - port["seen"] < self.bridge_wait

    def _probe(self, real, path):
        if not hardware.hold_port(real, "node"):
            return False
        try:
            port = open_port(path, self.factory)
        except (OSError, ValueError):
            hardware.let_go_port(real, "node")
            return False
        link = NodeLink(path, port, None, self.clock)
        link.send("HELLO")
        if not link.wait_hello(PROBE_SECONDS):
            if dragon_link.recognised(link.text):
                return self._dragon(real, path, link)
            link.stop("")
            hardware.let_go_port(real, "node")
            return False
        hardware.mark_port(real, "node")
        self.tries.pop(real, None)
        with self.lock:
            other = self.links.get(link.node_id)
            if other is not None and not other.closed:
                self.twins[real] = link.node_id
                link.stop("")
                hardware.let_go_port(real, "node")
                return True
            link.listener = self
            self.links[link.node_id] = link
            self.last.pop(link.node_id, None)
            self.given.pop(link.node_id, None)
            self.started.discard(link.node_id)
            entry = self._entry(link.node_id)
            if entry is not None and entry.get("led"):
                link.send("LED", *entry["led"].split(","))
            self._replan()
        if self.threads:
            link.start()
        return True

    def _dragon(self, real, path, link):
        """A Dragon Detector answered instead of a node: keep its port open and read its alerts."""
        def gone():
            with self.lock:
                self.dragons.pop(real, None)
            hardware.let_go_port(real, "node")
        dragon = dragon_link.DragonLink(path, link.port, self._dragon_alert, gone, link.text)
        hardware.mark_port(real, "dragon")
        self.tries.pop(real, None)
        with self.lock:
            self.dragons[real] = dragon
        if self.threads:
            dragon.start()
        return True

    def _dragon_alert(self, alert):
        sink = self.dragon_sink
        if sink is not None:
            sink(alert)

    def pump(self):
        """Read every port once. For tests and for a caller without threads."""
        with self.lock:
            links = list(self.links.values())
            dragons = list(self.dragons.values())
        for link in links:
            link.pump()
        for dragon in dragons:
            if not dragon.pump():
                dragon.stop()

    def _entry(self, node_id):
        return next((entry for entry in self.configured if entry["id"] == node_id), None)

    def _link(self, node_id):
        """The node's link on USB, else the one through the hub."""
        return self.links.get(node_id) or self.air.get(node_id)

    def _members(self):
        """The nodes in use: in the settings, plugged in or heard through the hub, and speaking this protocol. The
        hub is not one: it scans nothing."""
        usb = [node_id for node_id, link in self.links.items() if self._entry(node_id) is not None
               and not self._entry(node_id).get("hub") and link.hello and link.hello["protocol"] == PROTOCOL]
        return sorted(usb + self._air_members(self.clock()))

    def _air_members(self, now):
        if self.hub_link is None or not self.hub_ok:
            return []
        return [node_id for node_id, air in self.air.items() if node_id not in self.links and air.up(now)
                and air.hello and air.hello["protocol"] == PROTOCOL and (self._entry(node_id) or {}).get("wireless")]

    def _hub_id(self):
        return next((entry["id"] for entry in self.configured if entry.get("hub")), None)

    def _follow_hub(self):
        """Start with the hub when its link comes, and let go of its wireless nodes when it goes. Call with the
        lock."""
        node_id = self._hub_id()
        hub = self.links.get(node_id) if node_id is not None else None
        if hub is not None and not (hub.hello and hub.hello["protocol"] == PROTOCOL):
            hub = None
        if hub is self.hub_link:
            return
        self._drop_air(NO_HUB)
        self.hub_link = hub
        if hub is not None:
            self.started.discard(node_id)
            self.given.pop(node_id, None)
            self._begin_hub(hub)

    def _drop_air(self, error):
        for node_id, air in self.air.items():
            self.last[node_id] = self._last_of(air)
            if self.owner is not None and node_id in self.plans:
                self.left[node_id] = error
        if self.hub_link is not None:
            self.hub_link.riders = ()
        self.air, self.joins, self.admitting, self.forgotten = {}, {}, {}, {}
        self.cycle, self.listed = None, []
        self.hub_ok = self.hub_run = False
        self.hub_said = self.hub_sent = None
        self.pair_until = 0.0
        self.hub_error = self.pair_error = ""

    def _begin_hub(self, link):
        """Make the node a hub. Harmless when it already is one with this key. A hub in settings that lost the key
        gets a new one, so its wireless nodes have to be added again."""
        self.hub_error = ""
        if "espnow" not in link.hello["capabilities"]:
            self.hub_error = NO_ESPNOW
            return
        if self.key is None:
            self.key = secrets.token_hex(16)
            if self.on_key is not None:
                self.on_key(self.key)
        self.cycle, self.listed = None, []
        link.send("HUB", HUB_CHANNEL, self.key)
        self.hub_sent = self.clock()

    def _hub_up(self):
        """The node answered as a hub. #HUB stops what it ran, so it is started again for a running scan."""
        if not self.hub_ok:
            self.hub_ok, self.hub_run, self.hub_error = True, False, ""
            self._replan()
        if self.owner is not None:
            self._run_hub(True)

    def _run_hub(self, on):
        hub = self.hub_link
        if hub is None or not self.hub_ok or self.hub_run == on:
            return
        hub.send("START" if on else "STOP")
        self.hub_run = on
        self.nudged[hub.node_id] = self.clock()

    def _air_link(self, node_id):
        """The link of a wireless node through the hub, made when it is first heard of. Call with the lock."""
        air = self.air.get(node_id)
        if air is None:
            air = self.air[node_id] = AirLink(node_id, self.hub_link, self, self.clock)
            self.hub_link.riders = tuple(self.air.values())
            self.last.pop(node_id, None)
        return air

    def _replan(self):
        """Share the channels again if who is in use, their Bluetooth or the country changed. Call with the lock."""
        self._follow_hub()
        members = self._members()
        air = frozenset(node_id for node_id in members if node_id not in self.links)
        nodes = tuple((node_id, tuple(self._link(node_id).hello["capabilities"]),
                       self._entry(node_id)["ble"] and self.ble) for node_id in members)
        key = (self.country, nodes, self.bands, air)
        if key == self._key:
            return
        self._key = key
        if self.owner is not None:
            for node_id in set(self.plans) - set(members):
                if node_id in self.air and node_id not in self.links:
                    self.left[node_id] = AWAY
        plans = planner.make(self.country, nodes, self.plans, self.version + 1, bands=self.bands, slow=air)
        if any(plan.version == self.version + 1 for plan in plans.values()):
            self.version += 1
        self.plans = plans
        self._push()

    def _push(self, only=None):
        """Give each node in use its plan and start it. Call with the lock."""
        if self.owner is None:
            return
        now = self.clock()
        for node_id, plan in self.plans.items():
            link = self._link(node_id)
            if link is None or only not in (None, node_id):
                continue
            if self.given.get(node_id) != plan.version and self.refused.get(node_id) != plan.version:
                link.send("PLAN", *planner.arguments(plan))
                self.given[node_id] = plan.version
            if node_id not in self.started:
                if node_id in self.links:
                    link.send("START")
                self.started.add(node_id)
            self.nudged[node_id] = now
        self._run_hub(True)

    def heard(self, link, plan_version, state):
        """A node said which plan it scans with and whether it runs: bring it back in line when it is not."""
        with self.lock:
            node_id, now = link.node_id, self.clock()
            if link is self.hub_link:
                self._hub_heard(link, state, now)
                return
            wait = NUDGE_SECONDS if node_id in self.links else AIR_NUDGE_SECONDS
            if self._link(node_id) is not link or now - self.nudged.get(node_id, now - wait) < wait:
                return
            plan = self.plans.get(node_id) if self.owner is not None else None
            if plan is None:
                if state == "run" and node_id in self.links:
                    link.send("STOP")
                    self.nudged[node_id] = now
                return
            if plan_version != plan.version:
                self.given.pop(node_id, None)
            if state != "run" and node_id in self.links:
                self.started.discard(node_id)
            if node_id not in self.given or node_id not in self.started:
                self._push(node_id)

    def _hub_heard(self, hub, state, now):
        """A hub that is idle and has said no @C for a while restarted as a USB node: it is made a hub again. A hub
        runs while a wardrive or Recon does, so that its wireless nodes scan."""
        said = [moment for moment in (self.hub_said, self.hub_sent) if moment is not None]
        if said and state != "run" and now - max(said) >= HUB_QUIET_SECONDS:
            self.hub_ok = self.hub_run = False
            self._begin_hub(hub)
            return
        if not self.hub_ok or now - self.nudged.get(hub.node_id, now - NUDGE_SECONDS) < NUDGE_SECONDS:
            return
        if self.owner is not None and state != "run":
            self.hub_run = False
            self._run_hub(True)
        elif self.owner is None and state == "run":
            self.hub_run = True
            self._run_hub(False)

    def restarted(self, link):
        """The node counts its lines from 0 again. A hub has then lost its role and is made a hub again."""
        with self.lock:
            if link is self.hub_link:
                self.hub_ok = self.hub_run = False
                self.hub_said = None
                self._begin_hub(link)

    def hub_line(self, link, kind, fields, now):
        """@C, @N and @J of the hub."""
        entries = None
        with self.lock:
            if link is not self.hub_link:
                return
            if kind == "C" and len(fields) == 8 and fields[3].isdigit():
                if self.cycle is not None:
                    self.listed = (self.listed + [self.cycle])[-2:]
                self.cycle = set()
                self.hub_said = now
                self.pair_until = now + int(fields[3])
                self._hub_up()
            elif kind == "N" and len(fields) == 8:
                entries = self._air_heard(link, fields, now)
            elif kind == "J" and len(fields) == 6 and len(fields[2]) == 12 and fields[2].lower() not in self.links:
                node_id = fields[2].lower()
                rssi = int(fields[3]) if fields[3].lstrip("-").isdigit() else None
                self.joins[node_id] = {"id": node_id, "rssi": rssi, "firmware": fields[4], "board": fields[5],
                                       "at": now}
        self._save(entries)

    def _air_heard(self, hub, fields, now):
        """An @N line: how the hub hears one wireless node. A node the settings do not have is forgotten, and a node
        also on USB is left as it is. Returns the entries to save when it shows that a node was added."""
        node_id = fields[2].lower()
        if len(node_id) != 12 or node_id in self.links:
            return None
        if self.cycle is not None:
            self.cycle.add(node_id)
        entries = self._admitted(True, node_id)
        entry = self._entry(node_id)
        if entry is None or not entry.get("wireless"):
            if now - self.forgotten.get(node_id, now - FORGET_SECONDS) >= FORGET_SECONDS:
                hub.send("FORGET", node_id)
                self.forgotten[node_id] = now
            return entries
        air = self._air_link(node_id)
        air.link = fields[3]
        try:
            if fields[4]:
                heard = now - int(fields[4]) / 1000
                if air.heard is None or heard > air.heard:
                    air.heard = heard
            if fields[5]:
                air.rssi = int(fields[5])
            air.frames, air.resent = int(fields[6]), int(fields[7])
        except ValueError:
            hub.bad += 1
        if air.hello is None and air.up(now) and (air.asked is None or now - air.asked >= HELLO_SECONDS):
            air.asked = now
            air.send("HELLO")
        self._replan()
        return entries

    def relayed(self, hub, fields, now):
        """An @R line: one line of a wireless node, read as its own link reads it."""
        if hub is not self.hub_link:
            return
        node_id = fields[1]
        air = self.air.get(node_id)
        if air is None:
            with self.lock:
                if node_id in self.links or hub is not self.hub_link or \
                        not (self._entry(node_id) or {}).get("wireless"):
                    return
                air = self._air_link(node_id)
        elif node_id in self.links:
            return
        inner = fields[2:]
        inner[0] = inner[0][1:]
        fresh = air.hello is None or not air.up(now)
        air.heard = now
        air._fields(inner, now)
        if fresh:
            with self.lock:
                self._replan()

    def garbled(self, hub, raw_id):
        """An @R line with a wrong checksum is counted on its node, when the id in it is one."""
        air = self.air.get(raw_id.decode("ascii", "replace")) if hub is self.hub_link else None
        if air is None:
            return False
        air.bad += 1
        return True

    def answered(self, link, name, ok, detail):
        """A plan the node refused is not sent again; one garbled on the way is, at the next nudge."""
        if link is self.hub_link and name in ("HUB", "ADMIT", "PAIR"):
            entries = None
            with self.lock:
                if name == "HUB":
                    if ok:
                        self._hub_up()
                    else:
                        self.hub_error = NO_ESPNOW if detail == "unknown" else HUB_FAILED
                elif name == "ADMIT":
                    entries = self._admitted(ok, detail)
                elif ok and detail.isdigit():
                    self.pair_until = self.clock() + int(detail)
            self._save(entries)
            return
        if name == "PLAN" and not ok and detail in PLAN_FIELDS:
            with self.lock:
                plan = self.plans.get(link.node_id)
                if plan is not None:
                    self.refused[link.node_id] = plan.version

    def _admitted(self, ok, detail):
        """The hub took a new wireless node, or did not. A refusal does not say which node: the oldest one waiting
        stops showing as being added, but any node tried in the last minute is still added when the hub lists it.
        Returns the entries to save. Call with the lock."""
        if not ok:
            self.pair_error = ADMIT_ERRORS.get(detail, ADMIT_ERRORS["radio"])
            if self.admitting:
                del self.admitting[min(self.admitting, key=lambda node_id: self.admitting[node_id][1])]
            return None
        node_id = detail.lower()
        tried = self.tried.get(node_id)
        if node_id not in self.admitting and (tried is None or self.clock() - tried[1] >= FORGET_SECONDS):
            return None
        name, _ = self.admitting.pop(node_id, None) or tried
        self.tried.pop(node_id, None)
        if self.cycle is not None:
            self.cycle.add(node_id)
        self.joins.pop(node_id, None)
        self.forgotten.pop(node_id, None)
        entry = self._entry(node_id)
        if entry is None:
            if sum(1 for other in self.configured if other.get("wireless")) >= MAX_WIRELESS:
                self.pair_error = FULL_WIRELESS
                return None
            self.configured.append(node_entries([{"id": node_id, "name": name, "wireless": True}])[0])
        elif entry.get("hub"):
            return None
        else:
            entry["wireless"] = True
        return self._changed()

    def sightings(self, link, wifi, ble):
        with self.lock:
            sinks = self.sinks
            if sinks is None or link.node_id not in self.plans or self._link(link.node_id) is not link:
                return
            adapter = self._adapter(link.node_id) if wifi else None
        if wifi:
            sinks[0](wifi, adapter)
        if ble and sinks[1] is not None:
            sinks[1](ble)

    def closed(self, link):
        with self.lock:
            node_id = link.node_id
            if node_id is not None and self.links.get(node_id) is link:
                del self.links[node_id]
                self.last[node_id] = self._last_of(link)
                self.given.pop(node_id, None)
                self.started.discard(node_id)
                if self.owner is not None and node_id in self.plans:
                    self.left[node_id] = link.error
                for real in [real for real, other in self.twins.items() if other == node_id]:
                    del self.twins[real]
                    self.tries[real] = (0, self.clock())
                self._replan()
            if link.real not in self.away:
                hardware.let_go_port(link.real, "node")
                self.tries[link.real] = (0, self.clock() + 1.0)
        self._wake.set()

    @staticmethod
    def _last_of(link):
        return {"hello": link.hello, "status": link.status, "error": link.error, "heard": link.heard,
                "lost": link.lost, "bad": link.bad, "late": link.late, "rssi": getattr(link, "rssi", None)}

    def attach(self, owner, wifi_sink, ble_sink=None, ble=True, bands=None):
        """A wardrive or Recon starts: the nodes in use get their plans and start. Bluetooth only with ble, Wi-Fi
        only on the bands kept (None: all)."""
        with self.lock:
            self.owner, self.sinks, self.ble = owner, (wifi_sink, ble_sink), bool(ble)
            self.bands = None if bands is None else frozenset(bands)
            self.given, self.started, self.refused, self.nudged, self.left = {}, set(), {}, {}, {}
            self._key = None
            self._replan()

    def detach(self, owner):
        with self.lock:
            if self.owner is not owner:
                return
            for node_id in self.started:
                link = self.links.get(node_id)
                if link is not None:
                    link.send("STOP")
            self._run_hub(False)
            self.owner = self.sinks = self.bands = None
            self.ble = True
            self.started, self.given, self.left = set(), {}, {}
            self._key = None
            self._replan()

    def in_use(self):
        with self.lock:
            return self._members()

    def wifi_bands(self):
        """The Wi-Fi capabilities ("wifi24", "wifi5") the nodes in use have between them."""
        with self.lock:
            found = set()
            for node_id in self._members():
                link = self._link(node_id)
                if link is not None and link.hello:
                    found |= {cap for cap in link.hello["capabilities"] if cap in ("wifi24", "wifi5")}
            return tuple(sorted(found))

    def adapters(self):
        """Each node of the running wardrive or Recon as an adapter, for the screens that list them."""
        with self.lock:
            if self.owner is None:
                return []
            ids = sorted(set(self.plans) | set(self.left))
            return [self._adapter(node_id) for node_id in ids if self._entry(node_id) is not None]

    def _adapter(self, node_id):
        link = self._link(node_id)
        status = link.status if link is not None else None
        plan = self.plans.get(node_id)
        bands = sorted({band for band, _ in planner.share_of(plan)}, key=("2.4", "5").index) if plan else []
        label = "Node %s" % self._name(node_id)
        return {"interface": label, "label": label, "method": "node", "node": node_id,
                "sweeps": status["sweeps"] if status else 0,
                "sweep_seconds": status["sweep_ms"] / 1000 if status and status["sweeps"] else None,
                "error": self._error(node_id), "bands": bands}

    def _name(self, node_id):
        entry = self._entry(node_id)
        return entry["name"] if entry is not None and entry["name"] else node_id[-4:].upper()

    def _error(self, node_id):
        link, entry = self.links.get(node_id), self._entry(node_id)
        if link is None and node_id in self.lent.values():
            return UPDATING
        if link is None and entry is not None and entry.get("wireless"):
            if self.hub_link is None or not self.hub_ok:
                return NO_HUB if self._hub_id() is not None else NO_HUB_SET
            link = self.air.get(node_id)
            if link is None or not link.up(self.clock()):
                unlisted = len(self.listed) == 2 and node_id not in self.cycle and \
                    not any(node_id in cycle for cycle in self.listed)
                return NOT_ON_HUB if unlisted else AWAY
        if link is None:
            return self.left.get(node_id) or (self.last.get(node_id) or {}).get("error") or NOT_PLUGGED
        if link.hello and link.hello["protocol"] != PROTOCOL:
            protocol = link.hello["protocol"]
            return OLDER if protocol.isdigit() and int(protocol) < int(PROTOCOL) else NEWER
        if entry is not None and entry.get("hub"):
            return self.hub_error
        plan = self.plans.get(node_id)
        if plan is not None and self.refused.get(node_id) == plan.version:
            return REFUSED
        if entry is not None and entry["ble"] and self.ble and link.hello and "ble" not in link.hello["capabilities"]:
            return NO_BLE
        return ""

    def node(self, node_id):
        """Everything the screens show about one node, plugged in, heard through the hub, or neither."""
        with self.lock:
            now = self.clock()
            link, entry = self.links.get(node_id), self._entry(node_id)
            air = self.air.get(node_id) if link is None else None
            live = link or air
            last = self.last.get(node_id) or {}
            connected = link is not None or air is not None and self.hub_ok and air.up(now)
            hello = live.hello if live is not None and live.hello else last.get("hello")
            status = live.status if live is not None and live.status else last.get("status")
            heard = live.heard if live is not None and live.heard is not None else last.get("heard")
            plan = self.plans.get(node_id)
            share = planner.share_of(plan) if plan else []
            state = (status or hello)["state"] if connected and (status or hello) else ""
            info = dict.fromkeys(("board", "firmware", "chip", "flash_mb", "psram_mb"))
            info.update((key, hello[key]) for key in info if hello)
            hub = bool(entry and entry.get("hub"))
            info.update({
                "id": node_id, "name": self._name(node_id), "configured": entry is not None,
                "connected": connected, "port": link.path if link is not None else "", "state": state,
                "capabilities": list(hello["capabilities"]) if hello else [],
                "ble": bool(entry and entry["ble"]), "led": entry.get("led", "") if entry else "",
                "wireless": bool(entry and entry.get("wireless")), "hub": hub,
                "hub_ready": hub and link is not None and link is self.hub_link and self.hub_ok,
                "wireless_nodes": sum(1 for other in self.air.values() if other.up(now)) if hub else 0,
                "link_rssi": air.rssi if air is not None else last.get("rssi") if link is None else None,
                "in_use": self.owner is not None and connected and node_id in self.plans,
                "plan_version": plan.version if plan else 0, "plan_channels": [ch for _, ch in share],
                "plan_bands": sorted({band for band, _ in share}, key=("2.4", "5").index),
                "networks": status["networks"] if status else 0, "devices": status["devices"] if status else 0,
                "sweeps": status["sweeps"] if status else 0,
                "sweep_seconds": status["sweep_ms"] / 1000 if status and status["sweeps"] else None,
                "last_heard": now - heard if heard is not None else None,
                "dropped": status["dropped"] if status else 0,
                "lost": live.lost if live is not None else last.get("lost", 0),
                "bad": live.bad if live is not None else last.get("bad", 0),
                "late": live.late if live is not None else last.get("late", 0),
                "error": self._error(node_id), "note": live.notes[-1][1] if live is not None and live.notes else "",
                "updating": node_id in self.lent.values()})
            return info

    def known(self):
        """The nodes in the settings, in their order."""
        with self.lock:
            ids = [entry["id"] for entry in self.configured]
        return [self.node(node_id) for node_id in ids]

    def found(self):
        """Nodes plugged in that are not in the settings yet."""
        with self.lock:
            ids = sorted(node_id for node_id in self.links if self._entry(node_id) is None)
        return [self.node(node_id) for node_id in ids]

    def entries(self):
        """The nodes as the settings keep them."""
        with self.lock:
            return [dict(entry) for entry in self.configured]

    def names(self):
        """The names of the wireless nodes in the settings, by id. Cheap enough for every frame."""
        with self.lock:
            return {entry["id"]: self._name(entry["id"]) for entry in self.configured if entry.get("wireless")}

    def stranded(self, node_id):
        """How many wireless nodes would have to be added again if this node became the hub: the ones of another
        hub, which this one does not know. The node that was the hub last still knows them, even while it is not."""
        with self.lock:
            entry = self._entry(node_id) or {}
            if entry.get("hub") or entry.get("last_hub"):
                return 0
            return self.wireless()

    def wireless(self):
        """How many wireless nodes are in the settings."""
        with self.lock:
            return sum(1 for entry in self.configured if entry.get("wireless"))

    def _changed(self):
        """Call with the lock, then give what it returns to _save() without it."""
        self._key = None
        self._replan()
        return [dict(entry) for entry in self.configured]

    def _save(self, entries):
        if entries is not None and self.on_change is not None:
            self.on_change(entries)

    def configure(self, cfg):
        """Take the nodes and the country from the settings again."""
        with self.lock:
            self.configured = node_entries(cfg.get("nodes", []))
            self.country = cfg.get("country", self.country)
            self.gps_source = cfg.get("gps_source", self.gps_source)
            self.key = cluster_key(cfg.get("cluster_key")) or self.key
            self._key = None
            self._replan()

    def add(self, node_id, name=""):
        """Put a node in the settings. Raises ValueError with words for the screen when there is no room."""
        entry = node_entries([{"id": str(node_id), "name": name}])
        if not entry:
            raise ValueError(NOT_A_NODE)
        with self.lock:
            if self._entry(entry[0]["id"]) is not None:
                return
            if sum(1 for other in self.configured if not other.get("wireless")) >= MAX_NODES:
                raise ValueError(FULL)
            self.configured.append(entry[0])
            entries = self._changed()
        self._save(entries)

    def remove(self, node_id):
        """Take a node out of the settings. The hub forgets a wireless node now, or when it is next plugged in; a hub
        stops being one."""
        with self.lock:
            entry = self._entry(node_id) or {}
            link = self.links.get(node_id)
            if entry.get("wireless") and self.hub_link is not None and self.hub_ok:
                self.hub_link.send("FORGET", node_id)
                self.forgotten[node_id] = self.clock()
            if entry.get("hub") and link is not None:
                link.send("USB")
            air = self.air.pop(node_id, None)
            if air is not None:
                self.hub_link.riders = tuple(self.air.values())
            self.configured = [entry for entry in self.configured if entry["id"] != node_id]
            entries = self._changed()
        self._save(entries)

    def set_hub(self, node_id, on):
        """Make a node on USB the hub of the wireless nodes, or stop it being one. There is one hub: turning it on
        for one node turns it off for the others. The key the hub and its nodes share is made the first time and
        kept in the settings. Raises ValueError with words for the screen when the node cannot be a hub."""
        key = entries = None
        with self.lock:
            entry = self._entry(node_id)
            if entry is None or bool(entry.get("hub")) == bool(on):
                return
            link = self.links.get(node_id)
            if on:
                if link is not None and "espnow" not in link.hello["capabilities"]:
                    raise ValueError(NO_ESPNOW)
                if self.key is None:
                    self.key = key = secrets.token_hex(16)
                if self.hub_link is not None and self.hub_link is not link:
                    self.hub_link.send("USB")
                for other in self.configured:
                    other.pop("hub", None)
                    other.pop("last_hub", None)
                entry.pop("wireless", None)
                entry["hub"] = entry["last_hub"] = True
            else:
                del entry["hub"]
                if link is not None:
                    link.send("USB")
            entries = self._changed()
        if key is not None and self.on_key is not None:
            self.on_key(key)
        self._save(entries)

    def hub(self):
        """The hub in the settings, or None: whether it answers as one, how long pairing stays open, and how many
        wireless nodes it hears."""
        with self.lock:
            node_id = self._hub_id()
            if node_id is None:
                return None
            now = self.clock()
            ready = self.hub_link is not None and self.hub_ok
            return {"id": node_id, "name": self._name(node_id), "connected": node_id in self.links, "ready": ready,
                    "error": self._error(node_id), "pairing": max(0, int(self.pair_until - now + 0.999)) if ready
                    else 0, "nodes": sum(1 for air in self.air.values() if air.up(now)) if ready else 0,
                    "note": self.pair_error}

    def pair(self, seconds=PAIR_SECONDS):
        """Open the hub's pairing window for that long; 0 closes it. False when there is no hub that answers."""
        with self.lock:
            hub = self.hub_link
            if hub is None or not self.hub_ok:
                return False
            hub.send("PAIR", str(int(seconds)))
            self.pair_until = self.clock() + seconds
            self.pair_error = ""
            if not seconds:
                self.joins.clear()
            return True

    def joining(self):
        """The wireless nodes that asked the hub to join in the last 30 s, with "adding" while #ADMIT waits."""
        with self.lock:
            now = self.clock()
            return [dict(join, adding=node_id in self.admitting) for node_id, join in sorted(self.joins.items())
                    if now - join["at"] < JOIN_SECONDS and node_id not in self.links]

    def admit(self, node_id, name=""):
        """Add a wireless node that asked to join. It is put in the settings when the hub has taken it. False when
        there is no hub that answers; ValueError with words for the screen when there is no room."""
        with self.lock:
            hub = self.hub_link
            if hub is None or not self.hub_ok:
                return False
            entry = self._entry(node_id)
            if entry is None and sum(1 for other in self.configured if other.get("wireless")) >= MAX_WIRELESS:
                raise ValueError(FULL_WIRELESS)
            hub.send("ADMIT", node_id)
            self.admitting[node_id] = self.tried[node_id] = (" ".join(str(name).split())[:NODE_NAME_MAX],
                                                             self.clock())
            self.pair_error = ""
            return True

    def rename(self, node_id, name):
        self._set(node_id, "name", " ".join(str(name).split())[:NODE_NAME_MAX])

    def set_ble(self, node_id, on):
        self._set(node_id, "ble", bool(on))

    def set_led(self, node_id, led):
        """led: the #LED arguments, such as "gpio,27,1", "ws2812,27" or "none". The node keeps it."""
        if not node_entries([{"id": node_id, "led": led}])[0].get("led"):
            raise ValueError("That is not an LED this node can use")
        self._set(node_id, "led", led)
        with self.lock:
            link = self._link(node_id)
            if link is not None:
                link.send("LED", *led.split(","))

    def _set(self, node_id, key, value):
        entries = None
        with self.lock:
            entry = self._entry(node_id)
            if entry is not None and entry.get(key) != value:
                entry[key] = value
                entries = self._changed()
        self._save(entries)

    def set_country(self, country):
        with self.lock:
            if country != self.country:
                self.country = country
                self._replan()

    def identify(self, node_id, seconds=5):
        """Blink the node's LED. False when it is neither plugged in nor heard through the hub."""
        with self.lock:
            link = self.links.get(node_id)
            if link is None:
                air = self.air.get(node_id)
                if air is None or not self.hub_ok or not air.up(self.clock()):
                    return False
                link = air
            link.send("IDENT", str(int(seconds)))
            return True

    def release(self, node_id):
        """Let go of a node's port so that it can be flashed. Returns the path to flash, or None.

        Its channels go to the other nodes at once. Waits up to a second for the port to close: call it off the
        screen thread. Nothing opens its ports, nor the port it comes back on, until take_back()."""
        with self.lock:
            link = self.links.get(node_id)
            if link is None:
                return None
            self.lent[link.path] = node_id
            self.away[link.real] = node_id
            for real, other in self.twins.items():
                if other == node_id:
                    self.away[real] = node_id
                    hardware.hold_port(real, "node")
        link.stop(UPDATING)
        return link.path

    def take_back(self, path):
        """The flashing is over: look at the node's ports again at once, whatever is on them now and wherever the
        board came back."""
        real = os.path.realpath(path)
        with self.lock:
            node_id = self.lent.pop(path, None) or self.away.get(real)
            self.lent = {lent: owner for lent, owner in self.lent.items() if owner != node_id}
            for other in [other for other, owner in self.away.items() if owner == node_id or other == real]:
                del self.away[other]
                hardware.let_go_port(other, "node")
                self.tries.pop(other, None)
            self.tries.pop(real, None)
            for other, port in self.ports.items():
                if port["path"] == path:
                    self.tries.pop(other, None)
        self._wake.set()
