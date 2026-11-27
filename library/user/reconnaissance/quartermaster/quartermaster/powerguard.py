"""Power guard: keeps the USB radios within what the Cardputer's USB port can give, and recovers when it runs short.

Every USB radio here tells Linux it takes 100 mA, so the kernel never budgets them. The table below holds what they
really draw, as estimates. Signs of a brownout come from sysfs, the kernel log when the app may read it and the
battery gauge, read on the wardrive's upkeep thread only. Nothing changes while there is no sign of trouble.
"""

from collections import deque
import errno
import os
from pathlib import Path
import re
import time

from . import hardware

SYS_USB = Path("/sys/bus/usb/devices")
SYS_NET = Path("/sys/class/net")
HWMON = Path("/sys/class/hwmon")
SUPPLIES = Path("/sys/class/power_supply")
KMSG = Path("/dev/kmsg")

# Typical and peak draw in mA. Estimates from measurements and data sheets, not from the devices.
ESTIMATES = {
    "mt7921au": (600, 900), "mt7925u": (650, 950), "mt7612u": (450, 650), "mt7610u": (350, 500),
    "mt7601u": (200, 300), "rtl8812au": (500, 700), "rtl8821au": (350, 500), "rtl8814au": (650, 900),
    "rtl8822bu": (500, 700), "rtl8822cu": (500, 700), "rtl8821cu": (350, 500), "rtl8723du": (250, 350),
    "rtl8851bu": (450, 650), "rtl8852bu": (550, 800), "rtl8852au": (550, 800), "rtl8852cu": (600, 850),
    "rtl8922au": (700, 1000), "rtl8192eu": (250, 400), "rtl8188eu": (200, 300), "rtl8188fu": (200, 300),
    "rtl8192cu": (250, 400), "rtl8192fu": (250, 400), "rtl8723bu": (200, 300), "rtl8187": (300, 500),
    "ar9271": (250, 400), "ar7010": (300, 450), "ar9170": (300, 450), "rt2800": (250, 450),
    "wifi": (500, 700), "sdr": (300, 300), "node": (150, 350), "gps": (50, 50), "hub": (50, 100),
}
DRIVER_CHIPS = {
    "mt7921u": "mt7921au", "mt7925u": "mt7925u", "mt76x2u": "mt7612u", "mt76x0u": "mt7610u", "mt7601u": "mt7601u",
    "rtw_8812au": "rtl8812au", "rtl88xxau": "rtl8812au", "8812au": "rtl8812au", "rtl8812au": "rtl8812au",
    "88XXau": "rtl8812au", "rtw_8821au": "rtl8821au", "rtw_8814au": "rtl8814au", "rtl8814au": "rtl8814au",
    "8814au": "rtl8814au", "rtw_8822bu": "rtl8822bu", "rtw88_8822bu": "rtl8822bu", "rtw_8822cu": "rtl8822cu",
    "rtw_8821cu": "rtl8821cu", "rtw88_8821cu": "rtl8821cu", "rtw_8723du": "rtl8723du", "rtw89_8851bu": "rtl8851bu",
    "rtw89_8852bu": "rtl8852bu", "rtl8852bu": "rtl8852bu", "rtw89_8852au": "rtl8852au", "rtl8852au": "rtl8852au",
    "rtw89_8852cu": "rtl8852cu", "rtw89_8922au": "rtl8922au", "ath9k_htc": "ar9271", "carl9170": "ar9170",
    "rtl8187": "rtl8187", "rtl8192cu": "rtl8192cu", "rt2800usb": "rt2800",
}
# What the Cardputer's USB port, and an unpowered hub on it, can pass on. Estimates.
PORT_MA = 1000
HUB_MA = 900
# Hubs that say they have their own power but do not.
BUS_HUBS = ("214b:7260",)
HUNGRY = ("wifi", "sdr", "node")
STAGGER = 1.5
SETTLE = 20.0
WINDOW = 60.0
REJOIN = 30.0
RETRY = 180.0
PROBATION = 120.0
SPACE = 8.0
DIP_UV = 300000
KMSG_RECORDS = 200
USB_LIMIT_LOG = re.compile(r"dwc2.*no free (?:host )?channels?\b", re.I)
EPROTO_LOG = re.compile(r"(?:error|err|status|ret|failed)[ =:,]*-71\b|-EPROTO\b|\bEPROTO\b")
GUARD_LOG = re.compile(hardware.POWER_LOG.pattern + r"|Cannot enable\. Maybe the USB cable is bad|"
                       r"hub_ext_port_status failed|Under-?voltage detected|over-current change|" +
                       "(?i:" + USB_LIMIT_LOG.pattern + ")|" + EPROTO_LOG.pattern)
ALARM_LOG = re.compile(r"Under-?voltage|over-current")
LOG_PORT = re.compile(r"\b(\d+-\d+(?:\.\d+)*)(?:-port(\d+))?\b")
START_LOG = re.compile(r"descriptor read|Cannot enable|not accepting address")
LISTEN_SHARE = 0.6
RESET_WAIT = (10.0, 30.0, 90.0)
RESET_TRIES = 3
WORDS = {
    "over": "Too many adapters for USB power. Use a powered hub.",
    "eased": "USB power ran short: extra adapters eased",
    "parked": "%s paused: not enough USB power",
    "limit": "The USB port is at its limit: extra adapters eased",
    "needs_power": "%s needs power",
}


def _read(path):
    try:
        return Path(path).read_text(errors="replace").strip()
    except (OSError, TypeError):
        return ""


def _parent(port):
    """The hub port a USB device hangs off: 1-1.2 for 1-1.2.4, None under a root hub."""
    return port.rsplit(".", 1)[0] if "." in port else None


def chip_of(usb_id="", driver=""):
    return hardware.USB_CHIPS.get(usb_id) or DRIVER_CHIPS.get(driver, "")


def estimate(kind, chip=""):
    """(typical mA, peak mA) of one device: an estimate."""
    return ESTIMATES.get(chip) or ESTIMATES.get(kind, (0, 0))


def adapter_estimate(adapter):
    if not adapter.get("external"):
        return (0, 0)
    return estimate("wifi", chip_of(adapter.get("usb_id", ""), adapter.get("driver", "")))


def _ttys(node):
    found = [path.name for path in node.glob("*:*/ttyUSB*")]
    found += [path.name for path in node.glob("*:*/tty/tty*")]
    return found


def _kind(node, usb_id, product):
    if usb_id in hardware.RTL_SDR:
        return "sdr", ""
    chip = hardware.USB_CHIPS.get(usb_id, "")
    if chip or usb_id in hardware.USB_ADAPTERS or hardware.WIFI_PRODUCT.search(product) or \
            any(node.glob("*:*/ieee80211/*")):
        return "wifi", chip
    if usb_id == hardware.NODE_NATIVE:
        return "node", ""
    if usb_id in hardware.NODE_BRIDGES or usb_id in hardware.USB_GPS or usb_id.split(":")[0] in hardware.USB_GPS:
        for name in _ttys(node):
            path = "/dev/" + name
            if "node" in (hardware.port_holder(path), hardware.port_mark(path)):
                return "node", ""
        if usb_id in hardware.USB_GPS or usb_id.split(":")[0] in hardware.USB_GPS:
            return "gps", ""
    return "", ""


def usb_load(sys_usb=None, hubs_powered=False):
    """What the USB radios, GPS and nodes draw, as estimates, on the Cardputer's port and on each unpowered hub.

    {"devices": [...], "hubs": {port: {...}}, "ma", "peak", "budget", "over"}. A device behind a hub with its own
    power is listed but not counted. With hubs_powered, as set in Settings, every hub counts as having its own power,
    for hubs that say they do not."""
    sys_usb = Path(SYS_USB if sys_usb is None else sys_usb)
    try:
        nodes = sorted(p for p in sys_usb.iterdir() if ":" not in p.name and not p.name.startswith("usb"))
    except OSError:
        nodes = []
    found, hubs = {}, {}
    for node in nodes:
        if not (node / "idVendor").is_file():
            continue
        usb_id = "%s:%s" % (_read(node / "idVendor").lower(), _read(node / "idProduct").lower())
        product = " ".join(x for x in (_read(node / "manufacturer"), _read(node / "product")) if x)
        if _read(node / "bDeviceClass") == "09":
            try:
                attributes = int(_read(node / "bmAttributes") or "0", 16)
            except ValueError:
                attributes = 0
            parent = _parent(node.name)
            if usb_id in BUS_HUBS or parent is not None:
                hubs[node.name] = {"port": node.name, "usb_id": usb_id, "label": product or "USB hub",
                                   "powered": hubs_powered or bool(attributes & 0x40) and usb_id not in BUS_HUBS,
                                   "ma": 0, "peak": 0, "children": [], "nodes": 0}
            continue
        kind, chip = _kind(node, usb_id, product)
        if kind:
            ma, peak = estimate(kind, chip)
            label = hardware.USB_ADAPTERS.get(usb_id) or product or kind
            found[node.name] = {"port": node.name, "usb_id": usb_id, "kind": kind, "chip": chip, "label": label,
                                "ma": ma, "peak": peak, "hub": None, "powered": False}

    def upstream(port):
        chain, parent = [], _parent(port)
        while parent is not None:
            if parent in hubs:
                chain.append(hubs[parent])
            parent = _parent(parent)
        return chain

    total = peak = 0
    for port, hub in hubs.items():
        hub["powered"] = hub["powered"] or any(h["powered"] for h in upstream(port))
        if not hub["powered"]:
            total += ESTIMATES["hub"][0]
            peak += ESTIMATES["hub"][1]
    for port, device in found.items():
        chain = upstream(port)
        device["hub"] = chain[0]["port"] if chain else None
        device["powered"] = any(h["powered"] for h in chain)
        if device["powered"]:
            continue
        total += device["ma"]
        peak += device["peak"]
        for hub in chain:
            hub["ma"] += device["ma"]
            hub["peak"] += device["peak"]
            hub["children"].append(port)
            hub["nodes"] += device["kind"] == "node"
    for hub in hubs.values():
        hub["over"] = not hub["powered"] and hub["ma"] > HUB_MA
    return {"devices": list(found.values()), "hubs": hubs, "ma": total, "peak": peak, "budget": PORT_MA,
            "over": total > PORT_MA}


def _ma(value):
    return "{:,}".format(int(value))


def load_cards(load):
    """What the Hardware screen says about USB power: [(title, detail, problem)]. Empty with nothing counted."""
    if not load or not load.get("devices"):
        return []
    cards = []
    if load["over"]:
        cards.append(("Too many adapters for USB power", "About %s of %s mA, estimated. Use a powered USB hub." % (
            _ma(load["ma"]), _ma(load["budget"])), True))
    else:
        cards.append(("USB power: about %s of %s mA" % (_ma(load["ma"]), _ma(load["budget"])),
                      "Estimate. Peaks to %s mA; radios start one by one." % _ma(load["peak"])
                      if load["peak"] > load["budget"] else "Estimate. Within what the Cardputer's port gives.",
                      False))
    for hub in load["hubs"].values():
        if not hub["over"]:
            continue
        cards.append(("Unpowered hub: about %s of %s mA" % (_ma(hub["ma"]), _ma(HUB_MA)),
                      "Use a powered USB hub for the adapters.", True))
        if hub["nodes"]:
            cards.append(("Node on the crowded hub", "Run the C5 node on its own battery. It works wirelessly.",
                          True))
    return cards


class Kmsg:
    """New kernel log lines, read without blocking. Nothing when the app may not read the kernel log."""

    def __init__(self, path):
        self.fd = None
        try:
            self.fd = os.open(str(path), os.O_RDONLY | os.O_NONBLOCK)
            os.lseek(self.fd, 0, os.SEEK_END)
        except OSError:
            self.close()

    def lines(self):
        out = []
        while self.fd is not None and len(out) < KMSG_RECORDS:
            try:
                record = os.read(self.fd, 8192)
            except BlockingIOError:
                break
            except OSError as exc:
                if exc.errno == errno.EPIPE:
                    continue
                self.close()
                break
            if not record:
                break
            text = record.decode("utf-8", "replace")
            out.append(text.split(";", 1)[1].split("\n", 1)[0] if ";" in text else text.strip())
        return out

    def close(self):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
        self.fd = None


class PowerGuard:
    """Watches for brownouts during a wardrive and eases the extra USB adapters while they happen.

    check() returns what the wardrive should do: ("untune", iface), ("space", iface, seconds), ("park", iface) and
    ("unpark", iface). The GPS, the built-in radio and nodes are never eased, and the last 6 GHz radio is never
    parked while another adapter can be. Weak signs only add up when they come from two separate looks. A pause or
    easing belongs to the adapter: when it is unplugged, or another adapter takes its name, it is forgotten, and
    forget() hands the names over once."""

    def __init__(self, cfg=None, sys_usb=None, sys_net=None, hwmon=None, supplies=None, kmsg=None,
                 clock=time.monotonic):
        self.cfg = cfg or {}
        self.sys_usb = Path(SYS_USB if sys_usb is None else sys_usb)
        self.sys_net = Path(SYS_NET if sys_net is None else sys_net)
        self.hwmon = Path(HWMON if hwmon is None else hwmon)
        self.supplies = Path(SUPPLIES if supplies is None else supplies)
        self.kmsg_path = KMSG if kmsg is None else kmsg
        self.clock = clock
        self.load = None
        self.level = 0
        self.parked, self.permanent, self.retried = [], set(), set()
        self.spaced, self.untuned = set(), set()
        self.troubles, self.eased, self.reason = 0, 0, ""
        self.usb_limit, self.limit_reason = 0, ""
        self.stuck = False
        self.revive = {}
        self._worked = set()
        self.listening = []
        self.moving = set()
        self.notice = None
        self.said = None
        self._shown = set()
        self._notices = 0
        self._weak = deque()
        self._last_step = None
        self._trouble_at = None
        self._retrying, self._retry_at = None, None
        self._ports, self._gone, self._marked, self._dropped = {}, {}, {}, {}
        self._labels = {}
        self._ifaces, self._iface_gone, self._iface_port = set(), {}, {}
        self._forgotten = []
        self._volts = None
        self._battery = None
        self._kmsg = None

    def _usb_load(self):
        load = usb_load(self.sys_usb, bool(self.cfg.get("hub_power")))
        for item in load["devices"] + list(load["hubs"].values()):
            self._labels[item["port"]] = item["label"]
        return load

    def start(self, adapters):
        """Read what is plugged in. Returns the start plan: {"stagger", "sky", "nodes"}, the seconds between the
        adapters' first sweeps and how long the aircraft radio and the nodes on USB wait to start."""
        self.load = self._usb_load()
        self._ports = self._snapshot()
        self._kmsg = Kmsg(self.kmsg_path)
        self._battery = self._find_battery()
        self._volts = self._voltage()
        self._watch_ifaces(adapters, self.clock())
        hungry = [d for d in self.load["devices"] if d["kind"] in HUNGRY and not d["powered"]]
        stagger = STAGGER if len(hungry) >= 2 else 0.0
        slots = sum(1 for a in adapters if a.get("external"))
        sky = nodes = 0.0
        if stagger and any(d["kind"] == "sdr" for d in hungry):
            sky, slots = slots * stagger, slots + 1
        if stagger and any(d["kind"] == "node" for d in hungry):
            nodes = slots * stagger
        if self.load["over"]:
            self._tell("over", WORDS["over"])
        return {"stagger": stagger, "sky": sky, "nodes": nodes}

    def stop(self):
        if self._kmsg is not None:
            self._kmsg.close()

    def _tell(self, kind, text):
        """Each kind of notice is shown once a drive."""
        if kind in self._shown:
            return
        self._shown.add(kind)
        self._notices += 1
        self.notice = {"id": self._notices, "kind": kind, "text": text}

    def _snapshot(self):
        try:
            nodes = [p for p in self.sys_usb.iterdir() if ":" not in p.name]
        except OSError:
            return {}
        found = {}
        for node in nodes:
            devnum = _read(node / "devnum")
            if devnum:
                found[node.name] = ("%s:%s" % (_read(node / "idVendor"), _read(node / "idProduct")), devnum)
        return found

    def _find_battery(self):
        try:
            supplies = sorted(self.supplies.iterdir(), key=lambda p: not p.name.startswith("bq27220"))
        except OSError:
            return None
        for supply in supplies:
            if _read(supply / "type") == "Battery" and _read(supply / "scope") != "Device" and \
                    _read(supply / "voltage_now"):
                return supply
        return None

    def _voltage(self):
        if self._battery is None:
            return None
        text = _read(self._battery / "voltage_now")
        if not re.fullmatch(r"[0-9]{4,8}", text) or _read(self._battery / "status") == "Charging":
            return None
        return int(text)

    def _port_of(self, iface):
        try:
            node = (self.sys_net / iface / "device").resolve()
        except OSError:
            return None
        return node.parent.name if ":" in node.name else None

    def forget(self):
        """The adapters whose pause or easing was dropped since the last call, as they left or changed."""
        names, self._forgotten = self._forgotten, []
        return names

    def _drop(self, name):
        groups = (self.permanent, self.retried, self.spaced, self.untuned)
        if name not in self.parked and self._retrying != name and not any(name in group for group in groups):
            return
        if name in self.parked:
            self.parked.remove(name)
        if self._retrying == name:
            self._retrying = None
        for group in groups:
            group.discard(name)
        self._forgotten.append(name)

    def _watch_ifaces(self, adapters, now):
        here = {a["interface"]: (self._port_of(a["interface"]), a.get("usb_id", "")) for a in adapters
                if a.get("external")}
        for adapter, vif in self.listening:
            here[adapter["interface"]] = (self._port_of(vif), adapter.get("usb_id", ""))
        for name in self.moving:
            if name not in here and name in self._ifaces and name in self._iface_port:
                here[name] = self._iface_port[name]
        names = set(here)
        signs = []
        for name in names - self._ifaces:
            gone = self._iface_gone.pop(name, None)
            before = self._iface_port.get(name)
            if before is not None and before != here[name]:
                self._drop(name)
                continue
            port = before[0] if before else None
            seen = port is not None and now - self._marked.get(port, -REJOIN - now) <= REJOIN
            if gone is not None and now - gone <= REJOIN and not seen:
                signs.append(("weak", "%s went away and came back" % name))
        for name in self._ifaces - names:
            self._iface_gone[name] = now
        for name, gone in list(self._iface_gone.items()):
            if now - gone > REJOIN:
                del self._iface_gone[name]
                self._iface_port.pop(name, None)
                self._drop(name)
        for name in names:
            self._iface_port[name] = here[name]
            if here[name][0]:
                self._worked.add(here[name][0])
        self._ifaces = names
        return signs

    def _usb_signs(self, now):
        current = self._snapshot()
        if not current and not self._ports:
            return []
        signs = []
        for port, (usb_id, devnum) in current.items():
            before = self._ports.get(port)
            gone = self._gone.pop(port, None)
            if before is not None and before[0] == usb_id and before[1] != devnum or \
                    gone is not None and gone[0] == usb_id and now - gone[1] <= REJOIN:
                self._marked[port] = now
                if now - self._dropped.get(port, -REJOIN - now) > REJOIN:
                    signs.append(("weak", "%s started again" % self._label(port)))
        lost = [port for port in self._ports if port not in current]
        for port in lost:
            self._gone[port] = (self._ports[port][0], now)
        hubs = (self.load or {}).get("hubs", {})
        counted = {d["port"] for d in (self.load or {}).get("devices", ())}
        for port in lost:
            children = [c for c in lost if c.startswith(port + ".")]
            if port in hubs and len([c for c in children if c in counted]) >= 2:
                for item in [port] + children:
                    self._dropped[item] = now
                signs.append(("weak", "The USB hub dropped off with its devices"))
        self._gone = {port: item for port, item in self._gone.items() if now - item[1] <= REJOIN}
        self._dropped = {port: at for port, at in self._dropped.items() if now - at <= REJOIN}
        if set(current) != set(self._ports):
            self.load = self._usb_load()
        self._ports = current
        return signs

    def _label(self, port):
        label = self._labels.get(port)
        return label[:22] if label else "A USB device"

    def _kernel_sign(self, line):
        """A kernel log line as a sign in plain words. Lines about a device that has just gone away are what drivers
        print when it is unplugged, so they are left out."""
        if ALARM_LOG.search(line):
            return ("strong", "USB over-current" if "over-current" in line else "The Pi reports under-voltage")
        if USB_LIMIT_LOG.search(line):
            if self._gone:
                return None
            self.usb_limit += 1
            self.limit_reason = "The USB port ran out of channels"
            self._tell("limit", WORDS["limit"])
            return ("weak", self.limit_reason)
        found = LOG_PORT.search(line)
        if found is None:
            return None if self._gone else ("weak", "USB errors in the kernel log")
        port = found.group(1) + ("." + found.group(2) if found.group(2) else "")
        chain = [port]
        while _parent(chain[-1]) is not None:
            chain.append(_parent(chain[-1]))
        if any(item in self._gone for item in chain):
            return None
        if EPROTO_LOG.search(line):
            self.usb_limit += 1
            self.limit_reason = "%s: USB errors (-71)" % self._label(port)
            self._tell("limit", WORDS["limit"])
            if not hardware.POWER_LOG.search(line):
                return ("weak", self.limit_reason)
        if "hub_ext_port_status" in line:
            return ("weak", "The USB hub lost a device")
        if START_LOG.search(line):
            return ("weak", "%s could not start" % self._label(port))
        return ("weak", "%s lost contact" % self._label(port))

    def _signs(self, adapters, now):
        signs = []
        try:
            sensors = list(self.hwmon.iterdir())
        except OSError:
            sensors = []
        if any(_read(sensor / "in0_lcrit_alarm") == "1" for sensor in sensors):
            signs.append(("strong", "The Pi reports under-voltage"))
        lines = self._kmsg.lines() if self._kmsg is not None else ()
        signs += self._usb_signs(now)
        for line in lines:
            sign = self._kernel_sign(line) if GUARD_LOG.search(line) else None
            if sign is not None:
                signs.append(sign)
                if sign[0] == "strong":
                    break
        signs += self._watch_ifaces(adapters, now)
        volts = self._voltage()
        if volts is not None and self._volts is not None and self._volts - volts >= DIP_UV:
            signs.append(("weak", "Battery voltage dipped under load"))
        self._volts = volts
        return signs

    def check(self, adapters, nodes=(), tuned=(), can_space=True, monitor=None):
        """One look, on the wardrive's upkeep thread. Returns the steps to take now, usually none."""
        now = self.clock()
        signs = self._signs(adapters, now)
        while self._weak and now - self._weak[0] > WINDOW:
            self._weak.popleft()
        strong = [words for strength, words in signs if strength == "strong"]
        weak = [words for strength, words in signs if strength == "weak"]
        if weak:
            self._weak.append(now)
        if signs:
            self.reason = (strong or weak)[0]
        present = {a["interface"] for a in adapters}
        if not strong and len(self._weak) < 2:
            return self._calm(now, present)
        self._weak.clear()
        self.troubles += 1
        self._trouble_at = now
        if self._retrying is not None and now - self._retry_at < PROBATION and self._retrying in present:
            name, self._retrying = self._retrying, None
            self.permanent.add(name)
            self.parked.append(name)
            self._last_step = now
            return [("park", name)]
        self._retrying = None
        if self._last_step is not None and now - self._last_step < SETTLE:
            return []
        return self._step(adapters, nodes, tuned, can_space, monitor, now)

    def _calm(self, now, present):
        if self._retrying is not None and now - self._retry_at >= PROBATION:
            self._retrying = None
        if self._retrying is not None or not self.parked:
            return []
        quiet_since = max(t for t in (self._trouble_at, self._last_step) if t is not None)
        if now - quiet_since < RETRY:
            return []
        waiting = [name for name in self.parked if name not in self.permanent and name not in self.retried and
                   name in present]
        if not waiting:
            return []
        name = waiting[-1]
        self.parked.remove(name)
        self.retried.add(name)
        self._retrying, self._retry_at = name, now
        return [("unpark", name)]

    @staticmethod
    def _keeper(active):
        """The adapter that keeps its tuning and pace: the one with 6 GHz and the most bands."""
        if not active:
            return None
        return sorted(active, key=lambda a: ("6" not in a.get("bands", ()), -len(a.get("bands", ())),
                                             active.index(a)))[0]

    def _active(self, adapters, monitor):
        return [a for a in adapters if a.get("external") and a["interface"] not in self.parked and
                a["interface"] != monitor]

    def _step(self, adapters, nodes, tuned, can_space, monitor, now):
        """The gentlest step left: undo tuning, then space the sweeps, then pause one adapter. An adapter plugged in
        later gets the gentle steps first too."""
        active = self._active(adapters, monitor)
        keeper = self._keeper(active)
        extras = [a for a in active if a is not keeper]
        actions, stage = [], 0
        for stage in (1, 2, 3):
            if stage == 1:
                actions = [("untune", a["interface"]) for a in extras if a["interface"] in tuned and
                           a["interface"] not in self.untuned]
                self.untuned.update(name for _, name in actions)
            elif stage == 2:
                actions = [("space", a["interface"], SPACE) for a in extras if can_space and
                           a["interface"] not in self.spaced]
                self.spaced.update(item[1] for item in actions)
            else:
                target = self._pick(adapters, nodes, monitor)
                if target is not None:
                    actions = [("park", target)]
                    self.parked.append(target)
                    if target in self.retried:
                        self.permanent.add(target)
            if actions:
                break
        if not actions:
            self.stuck = True
            return []
        self.level = max(self.level, stage)
        self.eased += 1
        self._last_step = now
        self._tell("eased", WORDS["eased"])
        if actions[0][0] == "park":
            self._tell("parked", WORDS["parked"] % actions[0][1])
        return actions

    def _pick(self, adapters, nodes, monitor):
        """The adapter whose bands the others cover best. Never the last 6 GHz radio while another can be parked."""
        active = self._active(adapters, monitor)
        if len(active) < 2:
            return None
        node_bands = {{"wifi24": "2.4", "wifi5": "5"}.get(n, n) for n in nodes}
        scanning = [a for a in adapters if a["interface"] not in self.parked and a["interface"] != monitor]
        six = [a for a in scanning if "6" in a.get("bands", ())]

        def unique(a):
            others = set(node_bands)
            for other in scanning:
                if other is not a:
                    others.update(other.get("bands", ()))
            return len(set(a.get("bands", ())) - others)

        candidates = [a for a in active if not (len(six) == 1 and six[0] is a)] or active
        best = sorted(candidates, key=lambda a: (unique(a), "6" in a.get("bands", ()), -adapter_estimate(a)[1],
                                                 -active.index(a)))[0]
        return best["interface"]

    def revive_stalled(self, reset, stalled=None):
        """Adapters that worked in this drive and are now on the bus without a network interface, as a brownout
        leaves them: reset on their USB port, at most RESET_TRIES times, further apart each time. After that they
        need power. reset(port) returns True when the reset was done, and None when no reset is possible here, which
        is then left alone. Returns the ports reset now."""
        now = self.clock()
        if stalled is None:
            stalled = hardware.stalled_usb_adapters(self.sys_usb)
        here = {}
        for item in stalled:
            if item.get("disc") or item.get("port") not in self._worked:
                continue
            here[item["port"]] = item
        for port, state in self.revive.items():
            if port in here and not state["stalled"]:
                state["next"] = max(state["next"], now + RESET_WAIT[0])
            state["stalled"] = port in here
        done = []
        for port, item in here.items():
            state = self.revive.setdefault(port, {"label": item.get("label") or "Wi-Fi adapter", "tries": 0,
                                                  "next": now + RESET_WAIT[0], "needs_power": False,
                                                  "possible": True, "stalled": True})
            if state["needs_power"] or not state["possible"] or now < state["next"]:
                continue
            if state["tries"] >= RESET_TRIES:
                state["needs_power"] = True
                self._tell("needs_power", WORDS["needs_power"] % state["label"][:22])
                continue
            result = reset(port)
            if result is None:
                state["possible"] = False
                continue
            state["tries"] += 1
            state["next"] = now + RESET_WAIT[min(state["tries"], len(RESET_WAIT) - 1)]
            if result:
                self._marked[port] = now
                done.append(port)
        return done

    def _device_of(self, iface):
        port = self._port_of(iface)
        if port is None:
            return None
        return next((d for d in (self.load or {}).get("devices", ()) if d["port"] == port), None)

    def adapters_line(self, scanning, listening):
        """"Adapters: N active, est. X.X A, hub: powered/unpowered" for the Hardware screen. scanning: the USB
        adapters that sweep now; listening: the monitor interfaces, which only listen and so draw less."""
        load = self.load or {}
        ma = load.get("ma", 0)
        for iface in listening:
            device = self._device_of(iface)
            if device is not None and not device["powered"]:
                ma -= int(device["ma"] * (1 - LISTEN_SHARE))
        hubs = load.get("hubs") or {}
        hub = "none" if not hubs else "powered" if all(h["powered"] for h in hubs.values()) else "unpowered"
        active = len([a for a in scanning if a.get("external") and a["interface"] not in self.parked])
        return "Adapters: %d active, est. %.1f A, hub: %s" % (active + len(listening), max(0, ma) / 1000.0, hub)

    def status(self):
        return {"level": self.level, "parked": list(self.parked), "permanent": sorted(self.permanent),
                "retrying": self._retrying, "troubles": self.troubles, "eased": self.eased, "reason": self.reason,
                "notice": dict(self.notice) if self.notice else None, "load": self.load,
                "usb_limit": self.usb_limit, "limit_reason": self.limit_reason,
                "revive": {port: dict(state) for port, state in self.revive.items() if state["stalled"]}}
