"""Recon mode: watch for surveillance and tracking devices on every radio, without logging a wardrive.

Wi-Fi comes from every adapter at once and Bluetooth from BlueZ. Both only
scan: nothing is connected to. Each device is graded by the classifier in
`recon`, and flagged devices are kept in a live table and written to a JSON
Lines log.
"""

from collections import deque
import json
import os
from pathlib import Path
import shutil
import threading
import time

import zlib

from . import deepscan, faults, hardware, radios, recon, tones, wigle
from .ble import BleScanner
from .engine import DEFAULT_ROOT, MIN_FREE_BYTES, gps_epoch
from .tracker import distance_m
from .wifi import ScanUnavailable, WifiFleet

BLE_INTERVAL = 1.0
LOG_INTERVAL = 30.0
ALERT_AGAIN = 900.0
FOLLOW_MIN_SECONDS = 600
FOLLOW_MIN_METERS = 800
MAX_DEVICES = 3000
ACTIVE_SECONDS = 60


class AlertSound:
    """Recon's beep. Asking only queues it: the tone player's own thread renders and plays it."""

    def __init__(self, player=None):
        self.player = player if player is not None else tones.Player()

    def play(self, volume="medium"):
        return self.player.play("beep", volume, kind="recon")


class Recon:
    def __init__(self, cfg, gps, root=DEFAULT_ROOT, adapters=None, ble=None, fleet=WifiFleet, sound=None,
                 clock=time.time, nodes=None, deep=deepscan.DeepScan):
        self.cfg = dict(cfg)
        self.deep_class, self.deep = deep, None
        self.nodes = nodes
        self.gps = gps
        self.root = Path(root)
        self.adapters = adapters
        self.ble = ble
        self.fleet_class = fleet
        self.fleet = None
        self.sound = sound or AlertSound()
        self.clock = clock
        self.lock = threading.Lock()
        self.state = "idle"
        self.errors = {}
        self.devices = {}
        self.alerts = deque(maxlen=50)
        self.unseen_alerts = 0
        self.log_path = None
        self.started = 0.0
        self.counters = dict(observations=0, classified=0, alerts=0, log_errors=0, logged=0)
        self.totals = {"wifi": 0, "ble": 0}
        self._seen = set()
        self._cache = {}
        self._log = None
        self._synced = 0.0
        self._stop = threading.Event()
        self._threads = []
        self._hotplug = False

    def enabled(self, category):
        return category in self.cfg.get("recon_categories", recon.CATEGORIES)

    def display_min(self):
        return recon.CONFIDENCE_BY_KEY.get(self.cfg.get("recon_display_min", "low"), recon.LOW)

    def alert_min(self):
        return recon.CONFIDENCE_BY_KEY.get(self.cfg.get("recon_alert_min", "medium"), recon.MEDIUM)

    def start(self):
        if self.state == "running":
            return
        radios.claim("recon")
        try:
            directory = self.root / "recon"
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._hotplug = self.adapters is None
            if self.adapters is None:
                self.adapters = hardware.wifi_adapters()
            self.errors.clear()
            self.devices.clear()
            self.alerts.clear()
            self._cache.clear()
            self._seen = set()
            self.totals = {"wifi": 0, "ble": 0}
            self.unseen_alerts = 0
            self.counters = dict(observations=0, classified=0, alerts=0, log_errors=0, logged=0)
            stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(gps_epoch(self.gps.snapshot(), self.clock())))
            self.log_path = directory / ("recon_%s.jsonl" % stamp)
            self._log = None
            self._stop.clear()
            self.started = time.monotonic()
            self.state = "running"
            self.fleet = self.fleet_class(self._deep_scan(self._usable()), self._wifi_sink, 0.0)
            self.fleet.start()
            if self.nodes is not None:
                self.nodes.attach(self, self._wifi_sink, self._node_ble)
            self._threads = [threading.Thread(target=self._housekeeping, daemon=True, name="recon-housekeeping")]
            if self.ble is None:
                self.ble = BleScanner()
            self._threads.append(threading.Thread(target=self._ble_loop, daemon=True, name="recon-ble"))
            for thread in self._threads:
                thread.start()
        except Exception:
            self.state = "idle"
            radios.release("recon")
            raise

    def _deep_scan(self, usable):
        """Deep scan in Recon: the monitor adds what it hears; the other adapters scan as before."""
        self.deep = None
        if self.deep_class is None or not deepscan.wanted(self.cfg):
            return usable
        try:
            deep = self.deep = self.deep_class(self.cfg)
            if not deep.open():
                return usable
            deep.plan_roles(usable, self._node_bands())
            deep.start(self._wifi_sink, self._deep_frame)
            managed = deep.managed(usable)
            deep.tune(managed)
            return deep.scanners(managed)
        except Exception:
            faults.note("Starting Deep scan in Recon")
            return usable

    def _node_bands(self):
        return self.nodes.wifi_bands() if self.nodes is not None else ()

    def _deep_frame(self, event):
        frame = bytes(event.get("frame") or b"")
        result = recon.classify_wifi(event.get("address"), frame=frame, hopping=bool(event.get("hopping")))
        item = {"bssid": str(result.get("address") or event.get("address") or "").upper(), "ssid": "",
                "rssi": event.get("rssi"), "channel": event.get("channel"), "frequency": event.get("frequency"),
                "frame": frame, "hopping": bool(event.get("hopping"))}
        self._observe("wifi", item)

    def _usable(self):
        return [a for a in self.adapters if a.get("bands") or not a.get("phy")]

    def _housekeeping(self):
        while not self._stop.wait(4.0):
            try:
                self._follow_adapters()
            except Exception:
                faults.note("Recon upkeep")

    def _follow_adapters(self):
        if self._hotplug and hasattr(self.fleet, "refresh"):
            try:
                self.adapters = hardware.wifi_adapters()
                usable = self._usable()
                if self.deep is not None:
                    usable = self.deep.follow(usable, self.adapters, self._node_bands())
                self.fleet.refresh(usable)
            except OSError:
                pass
        errors = [("%s: %s" % (s["label"], s["error"]) if s.get("method") == "node" else s["error"])
                  for s in self.radio_status() if s.get("error")]
        if errors:
            self.errors["wifi"] = errors[0]
        else:
            self.errors.pop("wifi", None)

    def stop(self):
        if self.state != "running":
            return
        self.state = "stopping"
        self._stop.set()
        if self.nodes is not None:
            self.nodes.detach(self)
        if self.fleet is not None:
            self.fleet.stop()
        if self.deep is not None:
            try:
                self.deep.stop()
            except Exception:
                faults.note("Stopping Deep scan in Recon")
        for thread in self._threads:
            thread.join(timeout=5)
        if self.ble is not None:
            self.ble.close()
        with self.lock:
            if self._log is not None:
                try:
                    self._log.close()
                except OSError:
                    pass
                self._log = None
        self.state = "idle"
        radios.release("recon")

    def elapsed(self):
        return time.monotonic() - self.started if self.state == "running" else 0

    def radio_status(self):
        """The radios Recon listens with: the Wi-Fi adapters, then the nodes."""
        found = self.fleet.status() if self.fleet else []
        if self.deep is not None and self.fleet:
            found += self.deep.radio_status()
        return found + (self.nodes.adapters() if self.nodes is not None and self.fleet else [])

    def _wifi_sink(self, networks, adapter):
        for net in networks:
            self._observe("wifi", net)

    def _node_ble(self, seen):
        for item in seen:
            self._observe("ble", item, partial=True)

    def _observe(self, transport, item, partial=False):
        """One device that cannot be read must not hide the others heard with it."""
        try:
            self.observe(transport, item, partial=partial)
        except Exception:
            faults.note("Recon, a %s device" % transport)

    def _ble_loop(self):
        last_rssi = {}
        while not self._stop.is_set():
            try:
                seen = self.ble.scan()
                self.errors.pop("ble", None)
                for item in seen:
                    if item["address"] and last_rssi.get(item["address"]) != item["rssi"]:
                        last_rssi[item["address"]] = item["rssi"]
                        self._observe("ble", item)
            except ScanUnavailable as exc:
                self.errors["ble"] = str(exc)
                self._stop.wait(5)
                continue
            except Exception:
                faults.note("Recon Bluetooth scan")
                self.errors["ble"] = "Bluetooth scan failed. Trying again."
                self._stop.wait(5)
                continue
            if len(last_rssi) > 20000:
                last_rssi.clear()
            self._stop.wait(BLE_INTERVAL)

    def classify(self, transport, item):
        if transport == "wifi":
            frame = item.get("frame")
            if frame:
                key = ("frame", item["bssid"], zlib.crc32(bytes(frame[:64])), bool(item.get("hopping")))
                if key not in self._cache:
                    if len(self._cache) > 8000:
                        self._cache.clear()
                    self._cache[key] = recon.classify_wifi(item["bssid"], frame=bytes(frame),
                                                           hopping=bool(item.get("hopping")))
                return self._cache[key]
            key = ("wifi", item["bssid"], item.get("ssid", ""))
            if key not in self._cache:
                self._cache[key] = recon.classify_wifi(item["bssid"], item.get("ssid", ""))
            return self._cache[key]
        ad = item.get("raw_ad") or recon.advertisement_from_properties(
            item.get("name"), item.get("uuids", ()), item.get("manufacturer"), item.get("service_data"))
        key = ("ble", item["address"], item.get("address_type", 1), ad)
        if key not in self._cache:
            if len(self._cache) > 8000:
                self._cache.clear()
            self._cache[key] = recon.classify_ble(item["address"], item.get("address_type", 1), ad)
        return self._cache[key]

    def observe(self, transport, item, now=None, partial=False):
        """partial: the item carries less than a full advertisement (a node's line), so what was found from a
        fuller one is kept."""
        now = self.clock() if now is None else now
        address = item["bssid"] if transport == "wifi" else item["address"]
        result = self.classify(transport, item)
        known = self.devices.get((transport, address)) if partial else None
        if known is not None and known.get("result", result)["confidence"] > result["confidence"]:
            result = known["result"]
        category = result.get("category")
        shown = bool(category) and self.enabled(category) and result["confidence"] >= self.display_min()
        gps = self.gps.snapshot()
        rssi = item.get("rssi")
        key = (transport, address)
        record = alert = None
        followed = False
        with self.lock:
            self.counters["observations"] += 1
            if key not in self._seen and len(self._seen) < 200000:
                self._seen.add(key)
                self.totals[transport] += 1
            device = self.devices.get(key)
            if device is None:
                if len(self.devices) >= MAX_DEVICES:
                    self._make_room()
                device = self.devices[key] = {
                    "transport": transport, "address": address, "first_seen": now, "count": 0, "best_rssi": rssi,
                    "rssi_history": deque(maxlen=60), "places": [], "alerted_at": None, "logged_at": 0.0,
                    "follow": False, "category": None, "confidence": 0}
            device["count"] += 1
            away = now - device.get("last_seen", now)
            device["last_seen"] = now
            device["rssi"] = rssi
            device["rssi_history"].append((now, rssi))
            device["name"] = item.get("ssid") if transport == "wifi" else (
                item.get("name") or result.get("name", "") or (device.get("name", "") if partial else ""))
            device["result"] = result
            for field in ("channel", "frequency", "security", "band", "address_type"):
                if item.get(field) not in (None, ""):
                    device[field] = item[field]
            changed = (device["category"], device["confidence"]) != (category if shown else None,
                                                                     result["confidence"] if shown else 0)
            device["category"] = category if shown else None
            device["confidence"] = result["confidence"] if shown else 0
            for field in ("label", "evidence", "vendor", "remote_id", "beacon"):
                if result.get(field):
                    device[field] = result[field]
            if isinstance(rssi, (int, float)) and (device["best_rssi"] is None or rssi >= device["best_rssi"]):
                device["best_rssi"] = rssi
                if gps.get("valid"):
                    device["best_fix"] = (gps["latitude"], gps["longitude"])
            if gps.get("valid"):
                places = device["places"]
                if not places or now - places[-1][0] >= 60:
                    places.append((now, gps["latitude"], gps["longitude"]))
                    del places[:-30]
                if shown and not device["follow"] and self._following(places):
                    device["follow"] = followed = True
                    changed = True
            if shown and changed:
                self.counters["classified"] += 1
            follow = device["follow"] and not result.get("hint_only")
            if shown and (result["confidence"] >= self.alert_min() or follow) and \
                    (device["alerted_at"] is None or away >= ALERT_AGAIN or followed):
                device["alerted_at"] = now
                alert = {"time": now, "transport": transport, "address": address, "category": category,
                         "label": recon.CATEGORY_LABELS[category], "confidence": result["confidence"],
                         "evidence": result.get("evidence", ""), "rssi": rssi, "name": device.get("name", ""),
                         "follow": follow}
                self.alerts.appendleft(alert)
                self.unseen_alerts += 1
                self.counters["alerts"] += 1
            if shown and (changed or alert or now - device["logged_at"] >= LOG_INTERVAL):
                device["logged_at"] = now
                record = {"time": now, "transport": transport, "address": address, "rssi_dbm": rssi,
                          "name": device.get("name", ""), "category": category, "label": result.get("label"),
                          "confidence": recon.CONFIDENCE_KEYS[result["confidence"]],
                          "evidence": result.get("evidence", ""), "vendor": result.get("vendor", ""),
                          "alert": bool(alert), "following": device["follow"]}
                if gps.get("valid"):
                    record["receiver"] = {"latitude": gps["latitude"], "longitude": gps["longitude"]}
                for field in ("channel", "frequency", "security", "address_type"):
                    if field in device:
                        record[field] = device[field]
                for field in ("remote_id", "beacon"):
                    if result.get(field):
                        record[field] = result[field]
                self._write(record)
        if alert and self.cfg.get("recon_sound", True):
            self.sound.play(self.cfg.get("drive_alert_volume", "medium"))
        return device

    @staticmethod
    def _following(places):
        """Heard at places far apart over a long time: it may be travelling with you."""
        if len(places) < 3 or places[-1][0] - places[0][0] < FOLLOW_MIN_SECONDS:
            return False
        first = (places[0][1], places[0][2])
        return max(distance_m(first, (p[1], p[2])) for p in places) >= FOLLOW_MIN_METERS

    def _write(self, record):
        try:
            if self._log is None:
                if shutil.disk_usage(self.log_path.parent).free < MIN_FREE_BYTES:
                    self.errors["storage"] = "Storage is almost full: Recon log paused"
                    return
                fd = os.open(str(self.log_path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                self._log = os.fdopen(fd, "a", encoding="utf-8")
            self._log.write(json.dumps(record, ensure_ascii=True, allow_nan=False, default=_plain) + "\n")
            self._log.flush()
            if time.monotonic() - self._synced >= wigle.SYNC_SECONDS:
                wigle.fsync(self._log.fileno())
                self._synced = time.monotonic()
            self.counters["logged"] += 1
        except (OSError, ValueError):
            self.counters["log_errors"] += 1
            self.errors["storage"] = "Recon log write failed"

    def _make_room(self):
        """Drop the tenth of the table least worth keeping: not flagged first, then longest unheard."""
        keys = sorted(self.devices, key=lambda k: (bool(self.devices[k]["category"]), self.devices[k]["last_seen"]))
        for key in keys[:max(1, MAX_DEVICES // 10)]:
            del self.devices[key]

    def device_list(self, show_all=False, sort="threat"):
        with self.lock:
            items = [dict(d, rssi_history=list(d["rssi_history"])) for d in self.devices.values()
                     if show_all or d.get("category")]
        now = self.clock()
        if sort == "signal":
            items.sort(key=lambda d: d.get("rssi") if d.get("rssi") is not None else -999, reverse=True)
        elif sort == "recent":
            items.sort(key=lambda d: d["last_seen"], reverse=True)
        else:
            items.sort(key=lambda d: (now - d["last_seen"] < ACTIVE_SECONDS, d.get("follow", False),
                                      d.get("confidence", 0), recon.PRIORITY.get(d.get("category"), 0),
                                      d.get("rssi") or -999), reverse=True)
        return items

    def device(self, transport, address):
        with self.lock:
            found = self.devices.get((transport, address))
            return dict(found, rssi_history=list(found["rssi_history"])) if found else None

    def summary(self):
        with self.lock:
            devices = list(self.devices.values())
        now = self.clock()
        active = [d for d in devices if now - d["last_seen"] < ACTIVE_SECONDS]
        flagged = [d for d in devices if d.get("category")]
        return {"wifi": sum(1 for d in active if d["transport"] == "wifi"),
                "ble": sum(1 for d in active if d["transport"] == "ble"),
                "flagged": sum(1 for d in active if d.get("category")), "flagged_total": len(flagged),
                "strong": sum(1 for d in active if d.get("category") and d.get("confidence", 0) >= recon.STRONG),
                "following": sum(1 for d in devices if d.get("follow")),
                "wifi_total": self.totals["wifi"], "ble_total": self.totals["ble"],
                "radios": len(self.radio_status())}


def _plain(value):
    if isinstance(value, (bytes, bytearray)):
        return value.hex()
    if isinstance(value, (set, tuple, deque)):
        return list(value)
    raise TypeError("not serialisable")
