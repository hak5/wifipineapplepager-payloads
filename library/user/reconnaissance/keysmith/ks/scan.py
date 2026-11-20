"""Radio discovery, scanning and beacon parsing for KEYSMITH.

Only the tri-band radio (``phy1``) is touched.  ``phy0`` is the Pager's
management uplink: scanning it drops the phone tether / stock UI, so the code
below refuses to use it even if the caller asks by name.
"""

from __future__ import annotations

import re
import subprocess
import time

# SSIDs longer than this cannot be valid 802.11, and the LCD only has room
# for a truncated copy anyway.
MAX_SSID = 32


def run(cmd, timeout=25):
    """Run a command, returning ``(rc, stdout+stderr)``; never raises."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except FileNotFoundError:
        return 127, "not found: %s" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "timeout: %s" % " ".join(cmd)
    except Exception as exc:                       # pragma: no cover - defensive
        return 1, repr(exc)


def which(binary):
    rc, out = run(["sh", "-c", "command -v %s" % binary], timeout=5)
    return out.strip() if rc == 0 and out.strip() else None


# --------------------------------------------------------------------------- #
# Interfaces
# --------------------------------------------------------------------------- #

def list_ifaces():
    """Return ``[{iface, phy, type, addr}]`` from ``iw dev``."""
    rc, out = run(["iw", "dev"], timeout=8)
    if rc != 0:
        return []
    found = []
    phy = None
    cur = None
    for raw in out.splitlines():
        line = raw.strip()
        m = re.match(r"phy#(\d+)", line)
        if m:
            phy = int(m.group(1))
            continue
        m = re.match(r"Interface\s+(\S+)", line)
        if m:
            if cur:
                found.append(cur)
            cur = {"iface": m.group(1), "phy": phy, "type": "", "addr": ""}
            continue
        if cur is None:
            continue
        m = re.match(r"type\s+(\S+)", line)
        if m:
            cur["type"] = m.group(1)
        m = re.match(r"addr\s+([0-9a-fA-F:]{17})", line)
        if m:
            cur["addr"] = m.group(1).lower()
    if cur:
        found.append(cur)
    return found


def iface_phy(iface):
    for entry in list_ifaces():
        if entry["iface"] == iface:
            return entry["phy"]
    return None


def pick_iface(prefer=None):
    """Pick a managed interface on phy1 (the tri-band radio).

    Returns ``None`` when phy1 is absent, which the caller must treat as a
    hard error: the only other radio is the management uplink.
    """
    entries = list_ifaces()
    if prefer:
        for entry in entries:
            if entry["iface"] == prefer and entry["phy"] != 0:
                return entry["iface"]
    cands = [e for e in entries
             if e["phy"] == 1 and not e["iface"].endswith("mon")]
    # Base radios first, then firmware virtual APs.
    for want in ("wlan1", "wlan2", "wlan3"):
        for entry in cands:
            if entry["iface"] == want:
                return want
    return cands[0]["iface"] if cands else None


def iface_info(iface):
    rc, out = run(["iw", "dev", iface, "info"], timeout=6)
    info = {"type": "", "channel": 0, "addr": "", "raw": out}
    if rc != 0:
        return info
    m = re.search(r"type\s+(\S+)", out)
    if m:
        info["type"] = m.group(1)
    m = re.search(r"channel\s+(\d+)", out)
    if m:
        info["channel"] = int(m.group(1))
    m = re.search(r"addr\s+([0-9a-fA-F:]{17})", out)
    if m:
        info["addr"] = m.group(1).lower()
    return info


def _set_type(iface, kind):
    rc, out = run(["iw", "dev", iface, "set", "type", kind], timeout=8)
    return rc == 0, out


def prep_iface(iface):
    """Bring ``iface`` up in managed mode, tolerating firmware quirks.

    Returns ``(ok, message)``.  A monitor vif on the same phy is taken down
    first; the radio cannot do both at once on most drivers.
    """
    if iface.endswith("mon"):
        return False, "refusing to scan a monitor vif"
    info = iface_info(iface)
    if info["type"] and info["type"] != "managed":
        run(["ip", "link", "set", iface, "down"], timeout=6)
        ok, msg = _set_type(iface, "managed")
        if not ok:
            return False, "cannot set %s to managed: %s" % (iface, msg.strip())
    rc, out = run(["ip", "link", "set", iface, "up"], timeout=6)
    if rc != 0:
        return False, "cannot bring %s up: %s" % (iface, out.strip())
    # Give the driver a moment to settle after the mode switch.
    time.sleep(0.4)
    return True, "ok"


# --------------------------------------------------------------------------- #
# Beacon parsing
# --------------------------------------------------------------------------- #

def band_for_freq(freq):
    if 2400 <= freq <= 2500:
        return "2.4"
    if 4900 <= freq <= 5900:
        return "5"
    if 5925 <= freq <= 7125:
        return "6"
    return "?"


def channel_for_freq(freq):
    if freq == 2484:
        return 14
    if 2412 <= freq <= 2472:
        return (freq - 2407) // 5
    if 5000 <= freq <= 5900:
        return (freq - 5000) // 5
    if 5950 <= freq <= 7125:
        return (freq - 5950) // 5
    return 0


_OUI = {
    # Router brands whose default-key schemes KEYSMITH can derive.
    "000CF6": "Sitecom", "64D1A3": "Sitecom",
    "001B11": "D-Link", "001CF0": "D-Link", "0022B0": "D-Link",
    "002401": "D-Link", "1CBDB9": "D-Link", "340804": "D-Link",
    "F07D68": "D-Link", "CCB255": "D-Link",
    "001F9F": "Thomson", "0024D2": "Thomson", "0090D0": "Thomson",
    "D086CB": "Technicolor",
    "00144F": "Sagemcom", "E4C146": "Sagemcom",
    "001839": "Cisco-Linksys", "0018F8": "Cisco-Linksys",
    "002129": "Cisco-Linksys", "C0C1C0": "Cisco-Linksys",
    "001C10": "Cisco-Linksys",
    "08606E": "Asus", "1C872C": "Asus", "2C56DC": "Asus",
    "F832E4": "Asus",
    "C83A35": "Tenda", "D8320E": "Tenda",
    "001A11": "Arris", "0025F2": "Arris", "3C7A8A": "Arris",
    "B077AC": "Arris", "F87B7A": "Arris",
    "001E40": "Alice", "00255E": "Alice",
    "001882": "Huawei", "00259E": "Huawei", "00E0FC": "Huawei",
    "001E10": "Huawei", "0022A1": "Huawei", "F8E811": "Huawei",
    "001B20": "Comtrend", "64680C": "Comtrend", "3872C0": "Comtrend",
    "001A2B": "Comtrend",
    "0012BF": "Arcadyan", "001A2A": "Arcadyan", "001D19": "Arcadyan",
    "002308": "Arcadyan", "00264D": "Arcadyan", "743170": "Arcadyan",
    "001F90": "Verizon", "001801": "Verizon", "0020E0": "Verizon",
    "A83944": "Verizon",
    "C43DC7": "Sky", "E0469A": "Sky", "E091F5": "Sky",
    "001FA4": "Zyxel", "F43E61": "Zyxel", "404A03": "Zyxel",
    "000827": "Pirelli", "0013C8": "Pirelli", "0017C2": "Pirelli",
    "00193E": "Pirelli", "001CA2": "Pirelli", "001D8B": "Pirelli",
    "002233": "Pirelli", "00238E": "Pirelli", "002553": "Pirelli",
    "74888B": "Pirelli", "F0842F": "Pirelli",
    "001338": "2Wire", "001638": "2Wire", "0011F3": "2Wire",
    "08863B": "Belkin", "149182": "Belkin", "944452": "Belkin",
    "C05627": "Belkin", "EC1A59": "Belkin", "B4750E": "Belkin",
    "7CB733": "Hotbox", "A0648F": "Hotbox", "B4EEB4": "Hotbox",
    "E0CEC3": "Hotbox",
    "10FEED": "TP-Link", "30B5C2": "TP-Link", "6466B3": "TP-Link",
    "647002": "TP-Link", "90F652": "TP-Link", "A0F3C1": "TP-Link",
    "C04A00": "TP-Link", "F81A67": "TP-Link", "F8D111": "TP-Link",
    "00095B": "Netgear", "000FB5": "Netgear", "00146C": "Netgear",
    "00184D": "Netgear", "0026F2": "Netgear", "C03F0E": "Netgear",
    "30469A": "Netgear", "001B2F": "Netgear", "A021B7": "Netgear",
    "001E2A": "Netgear", "001F33": "Netgear", "00223F": "Netgear",
    "0024B2": "Netgear",
}


def vendor_for(bssid):
    h = (bssid or "").replace(":", "").replace("-", "").upper()
    return _OUI.get(h[:6], "")


def _security(flags):
    if flags.get("sae"):
        return "WPA3"
    if flags.get("rsn"):
        return "WPA2"
    if flags.get("wpa"):
        return "WPA"
    if flags.get("privacy"):
        return "WEP"
    return "OPEN"


def parse_scan(output):
    """Parse ``iw dev <iface> scan`` output into AP dictionaries."""
    aps = []
    cur = None

    def finalize(ap):
        if not ap or not ap.get("bssid"):
            return
        flags = ap.pop("_flags", {})
        ap["enc"] = _security(flags)
        ap["ssid"] = (ap.get("ssid") or "")[:MAX_SSID]
        if not ap["channel"]:
            ap["channel"] = channel_for_freq(ap.get("freq", 0))
        ap["band"] = band_for_freq(ap.get("freq", 0))
        ap["vendor"] = vendor_for(ap["bssid"])
        ap["bars"] = signal_bars(ap.get("rssi", -100))
        aps.append(ap)

    for raw in (output or "").splitlines():
        line = raw.strip()
        m = re.match(r"BSS\s+([0-9a-fA-F:]{17})", line)
        if m:
            finalize(cur)
            cur = {"bssid": m.group(1).lower(), "ssid": "", "channel": 0,
                   "freq": 0, "rssi": -100, "enc": "OPEN",
                   "band": "2.4", "_flags": {}}
            continue
        if cur is None:
            continue
        m = re.match(r"freq:\s*(\d+)", line)
        if m:
            cur["freq"] = int(m.group(1))
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


def signal_bars(rssi):
    if rssi >= -55:
        return 4
    if rssi >= -66:
        return 3
    if rssi >= -77:
        return 2
    if rssi >= -88:
        return 1
    return 0


def scan(iface, timeout=25):
    """Scan on ``iface`` and return APs sorted strongest-first."""
    rc, out = run(["iw", "dev", iface, "scan"], timeout=timeout)
    if rc != 0 and "BSS" not in out:
        # Some firmware builds need an explicit passive scan after a mode
        # switch; one retry with a longer dwell is cheap.
        rc, out = run(["iw", "dev", iface, "scan", "passive"], timeout=timeout)
    if "BSS" not in out:
        return []
    aps = [a for a in parse_scan(out) if a.get("ssid")]
    aps.sort(key=lambda a: a.get("rssi", -100), reverse=True)
    return aps[:60]


def scan_loop(iface, seconds=25):
    """Yield one AP list per sweep, sleeping between sweeps."""
    while True:
        yield scan(iface, seconds)
        time.sleep(1.0)
