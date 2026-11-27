"""Drive Alerts: warns about surveillance devices a wardrive already hears, without slowing the wardrive.

Each sighting gets a quick look-up on the scan thread. The few that may matter are handed to one low-priority
thread, which grades them with Recon's classifier, decides whether they are worth an alert, writes them to a log of
their own and plays the tone. The WiGLE logs are never touched.

The alert rules follow Dragon Detector's alert policy and SquachWatch's alert controls. The kinds of device are
SquachWatch's detection types, in its order.
"""

from collections import OrderedDict, deque
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import shutil
import threading
import time
import zlib

from . import faults, recon, tones, wigle
from .config import is_mac
from .recon_vendors import VENDOR_PREFIXES

EXTRA_LABELS = {"deauth": "Deauth flood", "eviltwin": "Evil twin AP", "lorawan": "LoRaWAN network",
                "mine": "My alert"}
EXTRA_SHORT = {"deauth": "DEAUTH", "eviltwin": "EVIL TWIN", "lorawan": "LORAWAN", "mine": "MY ALERT"}
LABELS = dict(recon.CATEGORY_LABELS, **EXTRA_LABELS)
SHORT = dict(recon.CATEGORY_SHORT, **EXTRA_SHORT)
PRIORITY = dict(recon.PRIORITY, eviltwin=50, deauth=50, lorawan=10, mine=100)
NAMES = {"flock": "Flock cameras", "axon": "Axon body cams", "glasses": "Meta glasses", "skimmer": "Card skimmers",
         "raven": "Raven sensors", "airtag": "AirTags", "drone": "Drones", "alpr": "ALPR cameras",
         "camera": "Cameras", "samsung_tag": "Samsung tags", "google_tag": "Google tags", "tile": "Tile trackers",
         "ring": "Ring cameras", "deauth": "Deauth floods", "eviltwin": "Evil twin APs",
         "ibeacon": "Proximity beacons", "hacker": "Hacker hardware", "lorawan": "LoRaWAN networks",
         "mine": "My alerts", "listener": "Smart speakers"}
FLOOD_NAMES = {"flock": "Flock cameras", "axon": "Axon body cams", "glasses": "Meta glasses",
               "skimmer": "card skimmers", "raven": "Raven sensors", "airtag": "AirTags", "drone": "drones",
               "alpr": "ALPR cameras", "camera": "cameras", "samsung_tag": "Samsung tags", "google_tag": "Google tags",
               "tile": "Tile trackers", "ring": "Ring cameras", "deauth": "deauth floods", "eviltwin": "evil twin APs",
               "ibeacon": "proximity beacons", "hacker": "hacker devices", "lorawan": "LoRaWAN networks",
               "mine": "watched devices", "listener": "smart speakers"}
FIRST = ("flock", "axon", "glasses", "mine")
SQUACHWATCH_ORDER = ("flock", "axon", "glasses", "skimmer", "raven", "airtag", "drone", "alpr", "camera",
                     "samsung_tag", "google_tag", "tile", "ring", "deauth", "eviltwin", "ibeacon", "hacker", "lorawan",
                     "mine", "listener")
TYPES = FIRST + tuple(k for k in SQUACHWATCH_ORDER if k not in FIRST)
RENAMED = {"tracker": ("samsung_tag", "google_tag", "tile")}
FOLDED = {"fleet": "axon", "burst": "hacker", "fox": "hacker"}
DEFAULT_TYPES = ["flock", "axon", "glasses", "mine"]
DEFAULT_TONES = dict({key: "blip" for key in TYPES}, axon="siren", flock="chirp", glasses="ping")
FIRST_HIT = {"flock", "alpr", "axon", "ring", "camera", "glasses", "drone", "hacker", "lorawan", "mine"}
FIXED = frozenset({"flock", "alpr", "ring", "camera", "raven", "lorawan"})
TONE_GAP = {"flock": 60.0, "axon": 300.0, "glasses": 120.0, "mine": 30.0}
TONE_PRIORITY = {"axon": 99, "mine": 98}
QUIET = {"eviltwin": 1800.0, "burst": 600.0, "deauth": 600.0}
INCIDENTS = {"eviltwin": "eviltwin", "deauth": "deauth", "burst": "hacker"}
BANNER_SECONDS, AXON_BANNER_SECONDS = 6.0, 10.0
BANNER_MIN, BANNER_EXTEND, BANNER_MAX, BANNER_WAITING = 3.0, 3.0, 12.0, 3
RUN_SECONDS, RUN_SPACING, PASS_SECONDS = 30.0, 0.4, 600.0
TONE_SPACING, TONES_PER_HOUR, URGENT_PER_HOUR = 8.0, 30, 6
CARD_REST = {"axon": 300.0}
START_SILENCE, QUIET_SECONDS = 60.0, 600.0
BACKOFF_TONES, BACKOFF_WINDOW, BACKOFF_MAX = 5, 600.0, 240.0
FLOOD_COUNT, FLOOD_WINDOW, FLOOD_QUIET, FIRST_FLOOD = 15, 60.0, 300.0, 30
HANDOFF_SECONDS, TWIN_SECONDS, DRAGON_FOLD_SECONDS, DRAGON_PASS = 20.0, 60.0, 30.0, 120.0
HEARD_BY = {"wifi": "Wi-Fi", "ble": "BLE", "dragon": "Dragon Detector", "lora": "LoRa", "monitor": "Wi-Fi monitor"}
BURST_WINDOW, BURST_TRACKERS, BURST_PAIRING = 5.0, 12, 24
LOG_INTERVAL = 30.0
QUEUE_LIMIT = 256
MAX_DEVICES = 4096
MAX_WATCH, WATCH_LENGTH = 8, 32
APPLE = ("airtag", "ibeacon", "listener")
TAGS = ("airtag", "samsung_tag", "google_tag", "tile")
MIN_FREE_BYTES = 32 * 1024 * 1024
CLASH_KEEP = 120.0


def same_vendor(one, other):
    """Two addresses from one maker's block, with the locally administered bit set aside: mesh nodes and the
    other band of one box, which SquachWatch never pairs as twins."""
    try:
        a = (int(one[0:2], 16) & ~2, one[3:8].upper())
        b = (int(other[0:2], 16) & ~2, other[3:8].upper())
    except (TypeError, ValueError):
        return False
    return a == b


def _uuid_text(raw):
    text = raw[::-1].hex()
    return "%s-%s-%s-%s-%s" % (text[:8], text[8:12], text[12:16], text[16:20], text[20:])


_OUI_HINT = {prefix: "fleet" if family == "Fleet" else recon._FAMILY_CATEGORY.get(family, "hacker")
             for prefix, family, _, _ in VENDOR_PREFIXES}
for _prefix in recon._FLOCK_OUIS:
    _OUI_HINT.setdefault(_prefix, "flock")
for _prefix in (0x0025df, 0x001d96, 0x0023bd, 0x2824ff, 0xe40540):
    _OUI_HINT[_prefix] = "axon"
_LOCAL_HINT = {0x826bf2: "flock", 0x02c0ca: "hacker", 0x021337: "hacker"}
_CID_HINT = {0x034d: "axon", 0x09c8: "flock", 0x0d53: "glasses", 0x01ab: "glasses", 0x060c: "glasses",
             0x03c2: "glasses", 0x08c3: "google_tag", 0x004c: "apple", 0x05a7: "listener", 0x0e29: "hacker"}
_UUID16_HINT = {0xfd44: "airtag", 0xfc81: "axon", 0xfe6b: "axon", 0xfe6c: "axon", 0xfd5a: "samsung_tag",
                0xfd5f: "glasses", 0xfeb7: "glasses", 0xfeb8: "glasses", 0xfe45: "glasses", 0xfeed: "tile",
                0xfeec: "tile", 0xfd84: "tile", 0xfcb2: "google_tag", 0xfe33: "google_tag", 0xfe65: "google_tag",
                0x1101: "skimmer", 0xfeaa: "google_tag", 0xfffa: "drone", 0xfe07: "listener"}
_UUID16_HINT.update((uuid, "hacker") for uuid in range(0x3080, 0x3084))
_UUID16_HINT.update((uuid, "raven") for uuid in range(0x3100, 0x3501, 0x100))
_UUID128_HINT = {_uuid_text(recon._FOX): "hacker", _uuid_text(recon._BISCUIT): "hacker",
                 _uuid_text(recon._FLOCK_SERVICE): "flock", _uuid_text(recon._DULT): "google_tag"}
_MARKERS = (b"BWCDEVICE", b"ECIVEDCWB")
_MARKER_HEX = tuple(marker.hex() for marker in _MARKERS)
_NAME_HINT = re.compile(
    r"flock|penguin|pigvision|axon|bodyworn|flipper|smarttag|airtag|pwnagotchi|pineapple|hak5|nyanbox|halehound"
    r"|ray-ban|rayban|oakley meta|_vantrue_|fs ext battery"
    r"|^(?:biscuit|spectacles|ab[234]|ring|raven|pwned|deauther|hc-0[3568]|rn42|bt04-a|fs-|googlehome|viofo"
    r"|blackvue|70mai_|thinkware|nextbase |rove_r|redtiger_|auxcamera_|dgk-|accq-|bccq-|xccq-|hcam-|cloudcam_"
    r"|meye_|gw_ipc|ipc_ap_)|^[0-9]{10}$")


def _name_hint(name):
    if not name:
        return None
    if _NAME_HINT.search(name.lower()) or recon._P2P_CAMERA.fullmatch(name) or recon._V380.fullmatch(name):
        return "?"
    return None


def wifi_hint(bssid, ssid):
    """The kind of device a network may be, "?" when only its name says so, or None when it cannot be one."""
    try:
        prefix = int(bssid[0:2] + bssid[3:5] + bssid[6:8], 16)
    except (TypeError, ValueError):
        return None
    if not prefix >> 16 & 3 and prefix in _OUI_HINT:
        return _OUI_HINT[prefix]
    if prefix in _LOCAL_HINT:
        return _LOCAL_HINT[prefix]
    return _name_hint(ssid)


def _uuid_hint(text):
    text = str(text).lower()
    if len(text) == 4:
        text = "0000%s-0000-1000-8000-00805f9b34fb" % text
    if text in _UUID128_HINT:
        return _UUID128_HINT[text]
    try:
        short = int(text[4:8], 16)
    except ValueError:
        return None
    if short in _UUID16_HINT:
        return _UUID16_HINT[short]
    plain = text.replace("-", "")
    if any(marker in plain for marker in _MARKER_HEX):
        return "axon"
    return None


def ble_hint(item):
    """The kind of device a Bluetooth sighting may be, or None when Recon's classifier cannot flag it."""
    if item.get("raw_ad"):
        return "?"
    for company, value in (item.get("manufacturer") or {}).items():
        if company in _CID_HINT:
            return _CID_HINT[company]
        if any(marker in bytes(value) for marker in _MARKERS):
            return "axon"
    for text in item.get("uuids") or ():
        found = _uuid_hint(text)
        if found:
            return found
    for text, value in (item.get("service_data") or {}).items():
        found = _uuid_hint(text)
        if found:
            return found
        if any(marker in bytes(value) for marker in _MARKERS):
            return "axon"
    found = _name_hint(item.get("name") or "")
    if found:
        return found
    if item.get("address_type", 1) in (0, 2):
        return wifi_hint(item.get("address", ""), "")
    return None


class WatchList:
    """My alerts: addresses that match exactly, and names that match from their start or by * and ? patterns."""

    def __init__(self, entries=()):
        entries = [str(e).strip()[:WATCH_LENGTH] for e in entries if str(e).strip()][:MAX_WATCH]
        self.macs = {e.upper().replace("-", ":"): e for e in entries if is_mac(e)}
        self.names = [(e, e.lower()) for e in entries if not is_mac(e)]

    def __bool__(self):
        return bool(self.macs or self.names)

    def match(self, address, name):
        entry = self.macs.get(str(address or "").upper())
        if entry:
            return entry
        low = (name or "").lower()
        if not low:
            return None
        for entry, pattern in self.names:
            if "*" in pattern or "?" in pattern:
                if fnmatchcase(low, pattern.replace("[", "[[]")):
                    return entry
            elif low.startswith(pattern):
                return entry
        return None


class SsidConflicts:
    """One network name that is open on one access point and protected on another nearby: a possible evil twin.

    Several access points with one name are normal, and so are WPA2 and WPA3 side by side."""

    LIMIT = 256

    def __init__(self):
        self.aps = OrderedDict()
        self.names = {}

    def _forget(self, bssid, ap):
        group = self.names.get(ap["ssid"])
        if group is not None:
            group.discard(bssid)
            if not group:
                del self.names[ap["ssid"]]

    def observe(self, networks, now):
        found = []
        for net in networks:
            ssid, bssid = net.get("ssid") or "", str(net.get("bssid") or "").upper()
            if not ssid or len(bssid) != 17 or int(bssid[:2], 16) & 3:
                continue
            open_ = net.get("security") == "OPEN"
            ap = self.aps.get(bssid)
            if ap is None or ap["ssid"] != ssid or ap["open"] != open_ or now - ap["last"] > 30:
                if ap is not None:
                    self._forget(bssid, ap)
                ap = {"ssid": ssid, "open": open_, "first": now, "last": now, "hits": 0}
            ap["last"] = now
            ap["hits"] += 1
            self.aps[bssid] = ap
            self.aps.move_to_end(bssid)
            group = self.names.setdefault(ssid, set())
            group.add(bssid)
            while len(self.aps) > self.LIMIT:
                self._forget(*self.aps.popitem(last=False))
            if ap["hits"] < 3 or now - ap["first"] < RUN_SPACING or len(group) < 2:
                continue
            for other in group:
                peer = self.aps[other]
                if other != bssid and peer["open"] != open_ and peer["hits"] >= 3 and not same_vendor(other, bssid) and \
                        peer["last"] - peer["first"] >= RUN_SPACING and now - peer["last"] < 15:
                    found.append((ssid, bssid if open_ else other, other if open_ else bssid))
                    break
        return found


class DriveWatch:
    def __init__(self, cfg, gps, root, player=None, clock=time.time, monotonic=time.monotonic, threads=True):
        self.gps, self.root, self.clock, self.monotonic = gps, Path(root), clock, monotonic
        self.player = player if player is not None else tones.Player()
        self.threads = threads
        self.urgent, self.rest = deque(), deque()
        self.dropped = 0
        self.alerts = deque(maxlen=100)
        self.devices = OrderedDict()
        self.counts = {}
        self.log_path = None
        self.log_start = None
        self.errors = 0
        self.no_speaker = self.speaker_said = False
        self._cache = {}
        self._incidents = {}
        self._tones, self._tone_at = deque(), {}
        self._kind_tones, self._kind_alert_at, self._backoff, self._streak = {}, {}, {}, {}
        self._banner, self._waiting = None, []
        self._card_at = {}
        self.started = self.quiet_until = None
        self._floods, self._muted = {}, {}
        self._bursts, self._pairing = deque(), deque()
        self._conflicts = SsidConflicts()
        self._clashes = OrderedDict()
        self._paused = {}
        self._log = None
        self._synced = 0.0
        self._lock = threading.Lock()
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._busy = False
        self._thread = None
        self.configure(cfg)

    def configure(self, cfg):
        from .engine import ignoring
        types = set(cfg.get("drive_alert_types", DEFAULT_TYPES))
        if not cfg.get("drive_alerts", True):
            types = set()
        watch = WatchList(cfg.get("drive_watch", ()))
        skip = [str(e).strip() for e in cfg.get("drive_alert_skip", ()) if str(e).strip()]
        hot = set(types) | {"?"} | ({"mine"} if watch else set())
        if hot & set(APPLE):
            hot.add("apple")
        sounds = dict(DEFAULT_TONES)
        sounds.update((k, v) for k, v in (cfg.get("drive_alert_sounds") or {}).items() if v in tones.ORDER)
        self.settings = {
            "types": frozenset(types), "hot": frozenset(hot), "burst": "hacker" in types, "watch": watch,
            "tones": cfg.get("drive_alert_tones", True), "volume": cfg.get("drive_alert_volume", "medium"),
            "min": recon.CONFIDENCE_BY_KEY.get(cfg.get("drive_alert_min", "medium"), recon.MEDIUM),
            "again": cfg.get("drive_alert_again", 900), "floor": cfg.get("drive_alert_floor", -100),
            "sounds": sounds, "mute": frozenset(cfg.get("drive_alert_mute", ())),
            "skip": (frozenset(e.upper().replace("-", ":") for e in skip if is_mac(e)),
                     frozenset(e.lower() for e in skip if not is_mac(e))),
            "ignore": ignoring(cfg.get("ignore", ()))}

    def start(self, epoch):
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(epoch))
        self.log_path = self.root / "recon" / ("drive_%s.jsonl" % stamp)
        self.started = self.monotonic()
        self._stop.clear()
        if self.threads and self._thread is None:
            self._thread = threading.Thread(target=self._run, daemon=True, name="drive-alerts")
            self._thread.start()

    def stop(self):
        self._stop.set()
        self._ready.set()
        thread, self._thread = self._thread, None
        if thread is not None:
            thread.join(timeout=5)
            if thread.is_alive():
                self._thread = thread
        if self._thread is None:
            self.drain()
        with self._lock:
            if self._log is not None:
                try:
                    self._log.close()
                except OSError:
                    pass
                self._log = None

    def _run(self):
        try:
            os.setpriority(os.PRIO_PROCESS, threading.get_native_id(), 10)
        except (AttributeError, OSError):
            pass
        while not self._stop.is_set():
            self._ready.wait()
            self._ready.clear()
            self.drain()

    def drain(self):
        """Grade everything waiting. The worker thread calls this; a test may call it instead."""
        while True:
            try:
                item = self.urgent.popleft() if self.urgent else self.rest.popleft()
            except IndexError:
                return
            self._busy = True
            try:
                self._process(item)
            except Exception:
                faults.note("Drive alerts")
            finally:
                self._busy = False

    def idle(self, timeout=2.0):
        deadline = time.monotonic() + timeout
        while (self.urgent or self.rest or self._busy) and time.monotonic() < deadline:
            time.sleep(0.005)
        return not (self.urgent or self.rest or self._busy)

    def _put(self, item, hint):
        line = self.urgent if hint in self.settings["hot"] else self.rest
        if len(line) >= QUEUE_LIMIT:
            self.dropped += 1
            return
        line.append(item)
        self._ready.set()

    def offer_wifi(self, networks):
        """From a scan thread: one sweep. Never raises and never waits."""
        try:
            watch = self.settings["watch"]
            for net in networks:
                hint = wifi_hint(net.get("bssid", ""), net.get("ssid") or "")
                if hint is None and watch and watch.match(net.get("bssid"), net.get("ssid")):
                    hint = "mine"
                if hint is not None:
                    self._put(("wifi", net), hint)
            self._put(("sweep", list(networks)), "sweep")
        except Exception:
            faults.note("Drive alerts, Wi-Fi")

    def offer_ble(self, item):
        """From a scan thread: one Bluetooth sighting. Never raises and never waits."""
        try:
            hint = ble_hint(item)
            watch = self.settings["watch"]
            if hint == "apple" and "apple" not in self.settings["hot"] and not self.settings["burst"]:
                hint = None
            if hint is None and watch and watch.match(item.get("address"), item.get("name")):
                hint = "mine"
            if hint is not None:
                self._put(("ble", item), hint)
        except Exception:
            faults.note("Drive alerts, Bluetooth")

    def offer_external(self, alert):
        """An alert another detector raised, such as a Dragon Detector on USB."""
        try:
            self._put(("external", alert), alert.get("category"))
        except Exception:
            faults.note("Drive alerts, Dragon Detector")

    def offer_frames(self, events):
        """From Deep scan: frames that may come from a Flock camera. Never raises and never waits."""
        try:
            for event in events:
                self._put(("frame", event), "flock")
        except Exception:
            faults.note("Drive alerts, Deep scan")

    def offer_incident(self, incident, sender, evidence, rssi=None):
        """From Deep scan: a pattern seen in raw frames, such as a disconnect flood."""
        try:
            self._put(("incident", {"incident": incident, "sender": sender, "evidence": evidence, "rssi": rssi}),
                      INCIDENTS.get(incident))
        except Exception:
            faults.note("Drive alerts, Deep scan")

    def offer_clash(self, clash):
        """From Deep scan: one access point beaconing on two channels at once, or open and protected. Only kept as
        evidence for an evil twin alert; it never alerts by itself."""
        try:
            self._put(("clash", clash), "clash")
        except Exception:
            faults.note("Drive alerts, Deep scan")

    def offer_lorawan(self, hit):
        """From the LoRa thread: a LoRaWAN operator heard, {"net_id", "operator", "address", "rssi", "exact"}."""
        try:
            self._put(("lorawan", hit), "lorawan")
        except Exception:
            faults.note("Drive alerts, LoRaWAN")

    def listening(self, radio, on):
        """While a radio does not listen, time away from its devices does not count."""
        now = self.monotonic()
        with self._lock:
            since = self._paused.get(radio)
            if not on and since is None:
                self._paused[radio] = now
            elif on and since is not None:
                del self._paused[radio]
                for (transport, _, _), device in self.devices.items():
                    if transport == radio and device["last"] <= since:
                        device["last"] += now - since

    def _age(self, transport, last, now):
        return max(0.0, self._paused.get(transport, now) - last)

    def _process(self, item):
        kind, payload = item
        if kind == "sweep":
            for ssid, open_bssid, other in self._conflicts.observe(payload, self.monotonic()):
                self._conflict(ssid, open_bssid, other, payload)
            return
        if kind == "external":
            return self._external(payload)
        if kind == "lorawan":
            return self._lorawan(payload)
        if kind == "frame":
            return self._frame(payload)
        if kind == "incident":
            sender = str(payload.get("sender") or "").upper()
            return self._incident(payload["incident"], sender, payload.get("evidence", ""), "Disconnect flood",
                                  payload.get("rssi"), "wifi", address=sender)
        if kind == "clash":
            self._clashes[str(payload.get("bssid", "")).upper()] = (self.monotonic(), payload.get("evidence", ""))
            while len(self._clashes) > 64:
                self._clashes.popitem(last=False)
            return
        if len(self._cache) > 8000:
            self._cache.clear()
        if kind == "wifi":
            address, name = str(payload["bssid"]).upper(), payload.get("ssid") or ""
            key = ("wifi", address, name)
            result = self._cache.get(key)
            if result is None:
                result = self._cache[key] = recon.classify_wifi(address, name)
            return self._consider("wifi", 0, address, name, payload.get("rssi"), result, payload)
        address, address_type = str(payload.get("address", "")).upper(), payload.get("address_type", 1)
        ad = payload.get("raw_ad") or recon.advertisement_from_properties(
            payload.get("name"), payload.get("uuids", ()), payload.get("manufacturer"), payload.get("service_data"))
        key = ("ble", address, address_type, ad)
        result = self._cache.get(key)
        if result is None:
            result = self._cache[key] = recon.classify_ble(address, address_type, ad)
        self._burst(address, result, payload)
        self._consider("ble", address_type, address, payload.get("name") or result.get("name", ""),
                       payload.get("rssi"), result, payload)

    def _frame(self, event):
        frame = event.get("frame") or b""
        hopping = bool(event.get("hopping"))
        key = ("frame", event.get("address"), zlib.crc32(bytes(frame[:64])), hopping)
        result = self._cache.get(key)
        if result is None:
            result = self._cache[key] = recon.classify_wifi(event.get("address"), frame=bytes(frame), hopping=hopping)
        address = str(result.get("address") or event.get("address") or "").upper()
        item = {"channel": event.get("channel"), "frequency": event.get("frequency")}
        self._consider("wifi", 0, address, "", event.get("rssi"), result, item, source="monitor")

    def _burst(self, address, result, item):
        now = self.monotonic()
        apple = (item.get("manufacturer") or {}).get(0x004C)
        if result.get("category") in TAGS:
            self._bursts.append((now, address))
        if apple is not None and len(apple) == 27:
            self._pairing.append((now, bytes(apple)))
        for line in (self._bursts, self._pairing):
            while line and now - line[0][0] > BURST_WINDOW:
                line.popleft()
            while len(line) > 512:
                line.popleft()
        trackers = len({a for _, a in self._bursts})
        pairing = len({p for _, p in self._pairing})
        if trackers >= BURST_TRACKERS or pairing >= BURST_PAIRING:
            count, kind = (trackers, "addresses") if trackers >= BURST_TRACKERS else (pairing, "pairing adverts")
            self._incident("burst", kind, "BLE advert burst: %d %s in %d s; fake adverts, often from a hacking tool" % (
                count, kind, BURST_WINDOW), "BLE advert burst, %d nearby" % count, item.get("rssi"), "ble")

    def _conflict(self, ssid, open_bssid, other, networks):
        differ = open_bssid[:8] != other[:8]
        evidence = "Same name open on %s and protected on %s%s" % (
            open_bssid, other, "; different makers" if differ else "")
        now = self.monotonic()
        for bssid in (open_bssid, other):
            clash = self._clashes.get(bssid)
            if clash is not None and now - clash[0] <= CLASH_KEEP:
                evidence += "; " + clash[1]
        rssi = next((n.get("rssi") for n in networks if str(n.get("bssid", "")).upper() == open_bssid), None)
        tag = zlib.crc32(ssid.encode("utf-8", "replace")) ^ zlib.crc32(open_bssid.encode())
        self._incident("eviltwin", tag, evidence, ssid, rssi, "wifi", address=open_bssid)

    def _external(self, alert):
        category = alert.get("category")
        if category not in LABELS:
            return
        incident = alert.get("incident") or (category if category in QUIET else None)
        if incident in QUIET:
            return self._incident(incident, ("dragon", alert.get("name") or alert.get("evidence")),
                                  alert.get("evidence", ""), alert.get("name", ""), alert.get("rssi"), "dragon")
        result = {"category": category, "confidence": alert.get("confidence", recon.MEDIUM),
                  "evidence": alert.get("evidence", ""), "label": LABELS[category], "vendor": ""}
        name, evidence = alert.get("name") or "", alert.get("evidence") or ""
        key = ("dragon", 0, "%s|%s" % (category, name.lower() or evidence))
        self._consider("dragon", 0, "%s / %s" % (name, evidence), name, alert.get("rssi"), result, alert,
                       source="dragon", key=key, unnamed=not name)

    def _lorawan(self, hit):
        """One alert per operator, as SquachWatch does: a street of meters is one network, not hundreds of devices."""
        evidence = "LoRaWAN address prefix of NetID %06X%s" % (
            hit["net_id"], "" if hit.get("exact") else "; the likeliest of several operators")
        result = {"category": "lorawan", "confidence": recon.STRONG if hit.get("exact") else recon.MEDIUM,
                  "evidence": evidence, "label": LABELS["lorawan"], "vendor": hit["operator"][:31]}
        self._consider("lora", 0, hit["address"], hit["operator"], hit.get("rssi"), result, hit)

    def _incident(self, incident, tag, evidence, name, rssi, transport, address=""):
        """A pattern rather than one device: a deauth flood, an evil twin, or a burst of fake adverts."""
        now = self.monotonic()
        category = INCIDENTS[incident]
        key = (incident, tag)
        last = self._incidents.get(key)
        again = self.settings["again"]
        quiet = max(QUIET[incident], again) if again else float("inf")
        self._incidents[key] = now
        if len(self._incidents) > 64:
            oldest = min(self._incidents, key=self._incidents.get)
            del self._incidents[oldest]
        if last is not None and self._age(transport if transport != "dragon" else "wifi", last, now) < quiet:
            return
        alert = category in self.settings["types"] and not self._skipped(address, "", None)
        record = {"time": self.clock(), "transport": transport, "address": address, "rssi_dbm": rssi, "name": name,
                  "category": category, "label": LABELS[category], "confidence": "medium", "evidence": evidence,
                  "vendor": "", "alert": alert, "source": "dragon" if transport == "dragon" else "scan",
                  "count": 1, "incident": incident}
        self._place(record)
        self._write(record)
        if alert:
            self._raise(category, record, rssi)

    def _place(self, record):
        fix = self.gps.snapshot()
        if fix.get("valid"):
            record["receiver"] = {"latitude": fix["latitude"], "longitude": fix["longitude"]}

    def _consider(self, transport, address_type, address, name, rssi, result, item, source="scan", key=None,
                  unnamed=False, replay=False):
        s = self.settings
        now = self.monotonic()
        mine = s["watch"].match(address if transport != "dragon" else None, name) if s["watch"] else None
        category, confidence = result.get("category"), result.get("confidence", recon.NONE)
        if mine:
            result = dict(result, category="mine", confidence=recon.STRONG,
                          evidence="My alerts: %s" % mine + ("; %s" % result["evidence"]
                                                             if result.get("evidence") else ""))
            category, confidence = "mine", recon.STRONG
        if not category or confidence < recon.LOW:
            return
        key = key or (transport, address_type, address)
        back, handed_to = False, None
        with self._lock:
            device = self.devices.get(key)
            fresh = device is None
            if fresh:
                while len(self.devices) >= MAX_DEVICES:
                    self.devices.popitem(last=False)
                device = self.devices[key] = {"first": now, "last": now, "run": now, "hits": 0, "notified": False,
                                              "category": category, "confidence": confidence, "result": result,
                                              "logged_at": None, "best_rssi": rssi, "repeats": 0, "alert": None,
                                              "sig": _signature(item, name) if transport == "ble" else None}
                self._join_twin(key, device, now)
                if device.get("handed") is not None:
                    device["replay"] = (transport, address_type, address, name, rssi, result, item, source, key)
            else:
                self.devices.move_to_end(key)
                handed = device.get("handed")
                if handed is not None and handed["last"] > device["first"]:
                    device.update(notified=False, alert=None, skip=False, handed=None, replay=None)
                handed_to = device.pop("handed_to", None) if not replay else None
                away = self._age(transport, device["last"], now)
                back = away >= PASS_SECONDS
                if unnamed and away >= DRAGON_PASS:
                    device.update(notified=False, hits=0, repeats=0, alert=None, skip=False)
                    back = True
                elif s["again"] and away >= s["again"] and device["category"] not in FIXED:
                    device.update(notified=False, hits=0, repeats=0, alert=None)
                if now - device["last"] > RUN_SECONDS:
                    device["hits"] = 0
            if confidence > device["confidence"] or category == "mine" or category == device["category"]:
                changed = (category, confidence) != (device["category"], device["confidence"])
                device.update(category=category, confidence=confidence, result=result)
            else:
                changed = False
                result, category, confidence = device["result"], device["category"], device["confidence"]
            if not replay:
                if device["hits"] == 0:
                    device["run"] = now
                device["hits"] += 1
                device["last"] = now
            improved = isinstance(rssi, (int, float)) and (device["best_rssi"] is None or rssi > device["best_rssi"])
            if improved:
                device["best_rssi"] = rssi
        ignored = address in s["ignore"][0] or bool(name) and name in s["ignore"][1]
        skipped = self._skipped(address, name, device)
        alert = self._gate(category, confidence, rssi, device, now, ignored, source, skipped)
        if fresh or changed or alert or back or improved and (device["logged_at"] is None or
                                                      now - device["logged_at"] >= LOG_INTERVAL):
            device["logged_at"] = now
            record = {"time": self.clock(), "transport": transport, "address": address, "rssi_dbm": rssi,
                      "name": name, "category": category, "label": LABELS[category],
                      "confidence": recon.CONFIDENCE_KEYS[confidence], "evidence": result.get("evidence", ""),
                      "vendor": result.get("vendor", ""), "alert": bool(alert), "source": source,
                      "count": device["hits"]}
            if transport == "ble":
                record["address_type"] = address_type
            for field in ("channel", "frequency", "security"):
                if item.get(field) not in (None, ""):
                    record[field] = item[field]
            for field in ("owner", "remote_id"):
                if result.get(field):
                    record[field] = result[field]
            if ignored:
                record["ignored"] = True
            if skipped:
                record["skipped"] = True
            self._place(record)
            self._write(record)
            if alert:
                device["alert"] = self._raise(category, record, rssi)
        for twin in handed_to or ():
            if twin.get("handed") is device and twin.get("replay"):
                again = twin.pop("replay")
                self._consider(*again[:7], source=again[7], key=again[8], replay=True)

    def _gate(self, category, confidence, rssi, device, now, ignored, source="scan", skipped=False):
        s = self.settings
        if skipped:
            return False
        if category != "mine":
            if category not in s["types"] or ignored or confidence < s["min"]:
                return False
            if isinstance(rssi, (int, float)) and rssi < s["floor"]:
                return False
            if category not in FIRST_HIT and source != "dragon" and \
                    (device["hits"] < 2 or now - device["run"] < RUN_SPACING):
                return False
            if category not in FIRST:
                if self._muted.get(category, -FLOOD_QUIET) > now - FLOOD_QUIET:
                    return False
                if not device["notified"] and self._flooded(category, now):
                    return False
            elif not device["notified"]:
                self._first_flood(category, now)
        elif "mine" not in s["types"]:
            return False
        if device["notified"]:
            device["repeats"] += 1
            shown = device.get("alert")
            if shown is not None:
                with self._lock:
                    shown["count"] = shown.get("count", 1) + 1
                    if isinstance(rssi, (int, float)) and (shown.get("rssi") is None or rssi > shown["rssi"]):
                        shown["rssi"] = rssi
            return False
        device["notified"] = True
        return True

    def _join_twin(self, key, device, now):
        """A new device that is one already alerted about: the same camera on Wi-Fi and Bluetooth, a Bluetooth
        address that changed, or a Dragon Detector line about what the scan just heard. It joins that alert."""
        transport, address_type, address = key
        category = device["category"]
        shown, other = None, None
        for alert in self.alerts:
            if now - alert.get("seen", now) > DRAGON_FOLD_SECONDS:
                break
            if alert["category"] == category and not alert.get("flood") and alert.get("transport") in HEARD_BY and \
                    (transport == "dragon") != (alert.get("source") == "dragon"):
                shown = alert
                break
        if shown is None and transport != "dragon":
            for other_key, candidate in reversed(self.devices.items()):
                if candidate is device:
                    continue
                if now - candidate["last"] > TWIN_SECONDS:
                    break
                if candidate.get("alert") is None or candidate["category"] != category:
                    continue
                kind, kind_type, kind_address = other_key
                if transport == "ble" and address_type == 1 and kind == "ble" and kind_type == 1 and \
                        now - candidate["last"] <= HANDOFF_SECONDS and _same_device(device["sig"], candidate["sig"]):
                    shown, other = candidate["alert"], candidate
                    device["handed"] = candidate
                    candidate.setdefault("handed_to", []).append(device)
                    break
                if {transport, kind} == {"wifi", "ble"} and abs(now - candidate["first"]) <= TWIN_SECONDS and \
                        _near(address, kind_address):
                    shown, other = candidate["alert"], candidate
                    break
        if shown is None:
            return
        device.update(notified=True, alert=shown, skip=bool(other and other.get("skip")))
        via = shown.setdefault("via", [HEARD_BY.get(shown.get("transport"), "")])
        if HEARD_BY[transport] not in via:
            via.append(HEARD_BY[transport])

    def _skipped(self, address, name, device):
        addresses, names = self.settings["skip"]
        return bool(device and device.get("skip")) or str(address or "").upper() in addresses or \
            bool(name) and name.lower() in names

    def silence(self, shown):
        """No more alerts on this drive for the devices of an alert. Whether this drive knew any of them."""
        known = False
        with self._lock:
            for device in self.devices.values():
                if device.get("alert") is shown:
                    device["skip"] = known = True
        return known

    def hide(self):
        """Take the banner off the screen now, and the ones waiting behind it. Whether one was showing."""
        with self._lock:
            shown = self._current(self.monotonic()) is not None
            self._banner, self._waiting = None, []
        return shown

    def quiet(self):
        """No tones and no banners for QUIET_SECONDS, or back to normal when that is on already. Whether it is on
        now. Alerts are still listed and logged."""
        with self._lock:
            now = self.monotonic()
            if self.quiet_until is not None and now < self.quiet_until:
                self.quiet_until = None
                return False
            self.quiet_until = now + QUIET_SECONDS
            self._banner, self._waiting = None, []
        hush = getattr(self.player, "hush", None)
        if hush is not None:
            hush()
        return True

    def quiet_left(self):
        """Seconds of quiet left, or 0."""
        until = self.quiet_until
        return max(0.0, until - self.monotonic()) if until is not None else 0.0

    def _flooded(self, category, now):
        times = self._floods.setdefault(category, deque())
        times.append(now)
        while times and now - times[0] > FLOOD_WINDOW:
            times.popleft()
        if len(times) <= FLOOD_COUNT:
            return False
        self._muted[category] = now
        times.clear()
        record = {"time": self.clock(), "category": category, "label": LABELS[category], "flood": True,
                  "name": "Flood: %d new %s" % (FLOOD_COUNT + 1, FLOOD_NAMES[category]), "address": "",
                  "confidence": recon.LOW, "rssi": None, "count": 1, "evidence": "Over %d new devices in %d s; "
                  "this kind is muted for %d min" % (FLOOD_COUNT, FLOOD_WINDOW, FLOOD_QUIET // 60)}
        self._show(record, tone=False)
        return True

    def _first_flood(self, category, now):
        times = self._floods.setdefault(category, deque())
        times.append(now)
        while times and now - times[0] > FLOOD_WINDOW:
            times.popleft()
        if len(times) < FIRST_FLOOD:
            return
        record = {"time": self.clock(), "category": category, "label": LABELS[category], "flood": True,
                  "name": "%d %s in 1 min" % (len(times), FLOOD_NAMES[category]), "address": "",
                  "confidence": recon.LOW, "rssi": None, "count": 1,
                  "evidence": "Each one is still listed and logged"}
        times.clear()
        self._show(record, tone=False)

    def _raise(self, category, record, rssi):
        shown = {"time": self.clock(), "seen": self.monotonic(), "category": category,
                 "label": LABELS[category], "name": record.get("name", ""), "address": record.get("address", ""),
                 "transport": record.get("transport", ""), "address_type": record.get("address_type"),
                 "rssi": rssi, "count": 1,
                 "confidence": recon.CONFIDENCE_BY_KEY.get(record.get("confidence"), recon.MEDIUM),
                 "evidence": record.get("evidence", ""), "vendor": record.get("vendor", ""),
                 "owner": record.get("owner"), "source": record.get("source", "scan"),
                 "receiver": record.get("receiver"), "incident": record.get("incident")}
        self._show(shown, tone=True)
        return shown

    def _show(self, shown, tone):
        now = self.monotonic()
        shown.setdefault("seen", now)
        with self._lock:
            self.alerts.appendleft(shown)
            self.counts[shown["category"]] = self.counts.get(shown["category"], 0) + (0 if shown.get("flood") else 1)
            hushed = self.quiet_until is not None and now < self.quiet_until
            if not hushed:
                self._present(shown, now)
        if tone and not hushed:
            shown["tone"] = self._sound(shown["category"], now)

    def _view(self, shown, now):
        hold = AXON_BANNER_SECONDS if shown["category"] == "axon" else BANNER_SECONDS
        return {"alert": shown, "category": shown["category"], "fold": 1, "rssi": shown.get("rssi"),
                "since": now, "hold": hold}

    def _present(self, shown, now):
        """One banner at a time. More of the same kind add to it; others wait their turn, and a few waiting
        together become one summary."""
        current = self._current(now)
        if current is not None and current["category"] == shown["category"]:
            return self._fold(current, shown, now)
        category = shown["category"]
        if now - self._card_at.get(category, -1e9) < CARD_REST.get(category, 0.0) and not any(
                waiting["category"] == category for waiting in self._waiting):
            return
        self._card_at[category] = now
        if current is None or _rank(shown["category"]) > _rank(current["category"]):
            self._banner = self._view(shown, now)
            self._banner["until"] = now + self._banner["hold"]
            return
        for waiting in self._waiting:
            if waiting["category"] == shown["category"]:
                return self._fold(waiting, shown, now)
        self._waiting.append(self._view(shown, now))
        del self._waiting[:-BANNER_WAITING]

    @staticmethod
    def _fold(view, shown, now):
        view["fold"] += 1
        rssi = shown.get("rssi")
        if isinstance(rssi, (int, float)) and (view["rssi"] is None or rssi > view["rssi"]):
            view["rssi"] = rssi
        if "until" in view:
            view["until"] = min(view["since"] + max(BANNER_MAX, view["hold"]), view["until"] + BANNER_EXTEND)

    def _current(self, now):
        banner = self._banner
        if banner is not None and (now >= banner["until"] or self._waiting and now - banner["since"] >= BANNER_MIN
                                   and max(_rank(v["category"]) for v in self._waiting) >= _rank(banner["category"])):
            banner = self._banner = None
        if banner is None and self._waiting:
            waiting, self._waiting = self._waiting, []
            if len(waiting) == 1:
                banner = dict(waiting[0], since=now)
            else:
                waiting.sort(key=lambda v: _rank(v["category"]), reverse=True)
                banner = {"summary": True, "category": waiting[0]["category"], "alert": waiting[0]["alert"],
                          "fold": sum(v["fold"] for v in waiting), "rssi": None, "since": now,
                          "hold": BANNER_SECONDS, "kinds": [v["category"] for v in waiting]}
            banner["until"] = now + banner["hold"]
            self._banner = banner
        return banner

    def _sound(self, category, now):
        s = self.settings
        tone = s["sounds"].get(category, DEFAULT_TONES.get(category, "blip"))
        if not s["tones"] or category in s["mute"] or tone == "silent" or tone not in tones.TONES:
            return False
        if self.started is not None and now - self.started < START_SILENCE:
            return False
        if now - self._kind_alert_at.get(category, -1e9) >= BACKOFF_WINDOW:
            self._backoff[category] = 0
            self._streak.pop(category, None)
        self._kind_alert_at[category] = now
        base = TONE_GAP.get(category, 300.0)
        gap = min(base * 2 ** self._backoff.get(category, 0), max(base, BACKOFF_MAX))
        if now - self._tone_at.get(category, -1e9) < gap:
            return False
        while self._tones and now - self._tones[0][0] > 3600:
            self._tones.popleft()
        played = self._kind_tones.setdefault(category, deque())
        urgent = category in TONE_PRIORITY
        if urgent:
            if sum(1 for at in played if now - at < 3600) >= URGENT_PER_HOUR:
                return False
        else:
            if self._tones and now - self._tones[-1][0] < TONE_SPACING:
                return False
            if sum(1 for _, counted in self._tones if counted) >= TONES_PER_HOUR:
                return False
        priority = TONE_PRIORITY.get(category, min(PRIORITY.get(category, 50), 90))
        if not self.player.play(tone, s["volume"], kind=category, priority=priority):
            self.no_speaker = self.no_speaker or not self.player.available()
            return False
        self._tone_at[category] = now
        self._tones.append((now, not urgent))
        played.append(now)
        while played and now - played[0] > 3600:
            played.popleft()
        streak = self._streak.setdefault(category, deque())
        streak.append(now)
        while streak and now - streak[0] > BACKOFF_WINDOW:
            streak.popleft()
        if len(streak) >= BACKOFF_TONES:
            self._backoff[category] = min(self._backoff.get(category, 0) + 1, 2)
            streak.clear()
        return True

    def _write(self, record):
        with self._lock:
            try:
                if self._log is None:
                    if self.log_path is None:
                        return
                    self.log_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    if shutil.disk_usage(self.log_path.parent).free < MIN_FREE_BYTES:
                        return
                    fd = os.open(str(self.log_path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                    self._log = os.fdopen(fd, "a", encoding="utf-8")
                    self.log_start = os.fstat(fd).st_size
                self._log.write(json.dumps(record, ensure_ascii=True, allow_nan=False, default=_plain) + "\n")
                self._log.flush()
                if time.monotonic() - self._synced >= wigle.SYNC_SECONDS:
                    wigle.fsync(self._log.fileno())
                    self._synced = time.monotonic()
            except (OSError, ValueError):
                self.errors += 1

    def banner(self):
        """The banner to show now, or None: {"alert", "category", "fold", "rssi", "since"}, with "summary" and
        "kinds" when it stands for several kinds at once."""
        with self._lock:
            banner = self._current(self.monotonic())
            return dict(banner, age=self.monotonic() - banner["since"]) if banner is not None else None

    def alert_list(self):
        with self._lock:
            return list(self.alerts)

    def summary(self):
        """{category: alerts} of this drive, most first."""
        with self._lock:
            counts = {k: v for k, v in self.counts.items() if v}
        return dict(sorted(counts.items(), key=lambda kv: (-kv[1], -PRIORITY.get(kv[0], 0))))

    def status(self):
        with self._lock:
            alerts = sum(self.counts.values())
            urgent = any(c in ("flock", "axon", "alpr", "mine") for c, n in self.counts.items() if n)
        return {"alerts": alerts, "urgent": urgent, "dropped": self.dropped, "errors": self.errors,
                "log": str(self.log_path) if self.log_path else "",
                "speaker": not (self.no_speaker or self.player.failed)}


def _rank(category):
    return category in TONE_PRIORITY, PRIORITY.get(category, 0)


def _signature(item, name):
    return (frozenset((item.get("manufacturer") or {}).keys()),
            frozenset(str(u).lower() for u in item.get("uuids") or ()), (name or "").lower())


def _same_device(mine, theirs):
    if not mine or not theirs:
        return False
    if mine[2] or theirs[2]:
        return mine[2] == theirs[2]
    return bool(mine[0] or mine[1]) and mine[:2] == theirs[:2]


def _near(one, other):
    """Two addresses of one device: the first five octets alike and the last within four."""
    try:
        return one[:14].upper() == other[:14].upper() and abs(int(one[15:17], 16) - int(other[15:17], 16)) <= 4
    except (TypeError, ValueError):
        return False


def silence_entry(shown):
    """What keeps an alert's device silent in later drives: its address, or its name when the address changes.
    "" when it has neither."""
    transport = shown.get("transport")
    lasting = transport == "dragon" or transport == "ble" and shown.get("address_type") in (1, 3)
    return ((shown.get("name") if lasting else shown.get("address")) or "")[:64]


def summary_text(counts, limit=3):
    words = []
    for category, count in list(counts.items())[:limit]:
        words.append("%d %s" % (count, SHORT.get(category, category).lower()))
    return ", ".join(words)


def _plain(value):
    if isinstance(value, (bytes, bytearray)):
        return value.hex()
    if isinstance(value, (set, tuple, deque, frozenset)):
        return list(value)
    raise TypeError("not serialisable")
