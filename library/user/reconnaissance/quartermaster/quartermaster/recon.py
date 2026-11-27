"""Recon: classifies the Wi-Fi and Bluetooth devices a scan hears as kinds of surveillance equipment.

Remote ID decoding follows the ASTM F3411 wire layout.

A result describes broadcast evidence. It does not establish that a device is
recording, that it is hostile, or who owns it. Randomized and locally
administered addresses never supply vendor evidence.
"""

from bisect import bisect_left
import re
import struct

from .recon_vendors import VENDOR_PREFIXES

NONE, LOW, MEDIUM, STRONG = 0, 1, 2, 3
CONFIDENCE_NAMES = {NONE: "Unclassified", LOW: "Weak indicator", MEDIUM: "Medium evidence", STRONG: "Strong signature"}
CONFIDENCE_KEYS = {NONE: "none", LOW: "low", MEDIUM: "medium", STRONG: "high"}
CONFIDENCE_BY_KEY = {"low": LOW, "medium": MEDIUM, "high": STRONG}
MAX_BLE_BYTES = 512
MAX_WIFI_BYTES = 1024

# Category keys used in settings and logs, in SquachWatch's order.
CATEGORY_LABELS = {
    "flock": "Flock camera",
    "axon": "Axon body camera",
    "glasses": "Meta glasses",
    "skimmer": "Card skimmer",
    "raven": "Raven sensor",
    "airtag": "AirTag",
    "drone": "Drone",
    "alpr": "ALPR",
    "camera": "Camera",
    "samsung_tag": "Samsung tag",
    "google_tag": "Google tag",
    "tile": "Tile",
    "ring": "Ring camera",
    "ibeacon": "Proximity beacon",
    "hacker": "Hacker hardware",
    "listener": "Smart speaker",
}
CATEGORY_SHORT = {
    "flock": "FLOCK", "axon": "AXON", "glasses": "GLASSES", "skimmer": "SKIMMER", "raven": "RAVEN",
    "airtag": "AIRTAG", "drone": "DRONE", "alpr": "ALPR", "camera": "CAMERA", "samsung_tag": "SMARTTAG",
    "google_tag": "FIND HUB", "tile": "TILE", "ring": "RING", "ibeacon": "IBEACON", "hacker": "HACKER",
    "listener": "SPEAKER",
}
CATEGORIES = tuple(CATEGORY_LABELS)
OFF_BY_DEFAULT = ("ibeacon", "listener")
# Higher sorts first on the Recon list.
PRIORITY = {"flock": 100, "alpr": 100, "axon": 95, "ring": 90, "camera": 90, "glasses": 90, "drone": 85,
            "hacker": 50, "raven": 50, "skimmer": 50, "airtag": 10, "samsung_tag": 10, "google_tag": 10, "tile": 10,
            "ibeacon": 10, "listener": 10}

_FAMILY_PRIORITY = {"Flock": 100, "Alpr": 100, "Axon": 95, "Ring": 90, "Camera": 90, "Meta": 90, "Drone": 85,
                    "Flipper": 75, "Fleet": 50, "Listener": 10, "Fox": 10, "Wifi": 20, "Ble": 20}
_TRACKER_FAMILIES = {"Tracker", "SmartTag", "GoogleTag", "Tile", "IBeacon"}


def _family_priority(family):
    if family in _FAMILY_PRIORITY:
        return _FAMILY_PRIORITY[family]
    return 10 if family in _TRACKER_FAMILIES else 50


def _contains(haystack, needle):
    return needle.lower() in haystack.lower()


def safe_text(raw):
    return "".join(chr(b) if 32 <= b < 127 else "?" for b in raw)


def _equal_name(a, b):
    return len(a) == len(b) and a.lower() == b.lower()


def _named_prefix(name, prefix):
    if len(name) < len(prefix) or name[:len(prefix)].lower() != prefix.lower():
        return False
    return len(name) == len(prefix) or name[len(prefix)] in " -_"


def _prefix(mac):
    return mac[0] << 16 | mac[1] << 8 | mac[2]


_FLOCK_OUIS = frozenset((
    0x70c94e, 0x3c9180, 0xd8f3bc, 0x803049, 0xb83532, 0x145afc, 0x744ca1, 0x083a88, 0x9c2f9d, 0xc03532,
    0x940853, 0xe4aaea, 0xf46add, 0xe00af6, 0x24b2b9, 0x00f48d, 0xd03957, 0xe8d0fc, 0xe04f43, 0xb81ea4,
    0x700894, 0x588e81, 0xec1bbd, 0x5800e3, 0x9035ea, 0x5c93a2, 0x646e69, 0x14b5cd, 0xb41e52, 0x00037f))
_VENDOR_KEYS = [row[0] for row in VENDOR_PREFIXES]
_CONF = {"Low": LOW, "Medium": MEDIUM, "Strong": STRONG}


def flock_prefix(mac):
    return not mac[0] & 3 and _prefix(mac) in _FLOCK_OUIS


def address_hint(mac, public, current):
    """Vendor evidence from a globally administered public address only."""
    if not mac or not public or mac[0] & 3 or current[1] >= MEDIUM:
        return current
    prefix = _prefix(mac)
    if current[1] == NONE:
        if prefix == 0x826bf2:
            return ("Flock", LOW, "Local address research pattern; no vendor or camera identity")
        if prefix in (0x02c0ca, 0x021337):
            return ("Pineapple", LOW, "Local pentest address pattern; easily changed or spoofed")
    if mac[0] & 2:
        return current
    index = bisect_left(_VENDOR_KEYS, prefix)
    if index < len(VENDOR_PREFIXES) and VENDOR_PREFIXES[index][0] == prefix:
        _, family, confidence, evidence = VENDOR_PREFIXES[index]
        if _CONF[confidence] > current[1]:
            return (family, _CONF[confidence], evidence)
    if current[1] != NONE:
        return current
    if flock_prefix(mac):
        return ("Flock", LOW, "Flock research OUI; shared chip vendor possible")
    return current


_SSID_CAMERA_PREFIXES = ("viofo_", "viofo-", "blackvue", "70mai_", "thinkware", "nextbase ", "rove_r", "redtiger_",
                         "auxcamera_", "dgk-", "accq-", "bccq-", "xccq-", "hcam-", "cloudcam_", "meye_", "gw_ipc",
                         "ipc_ap_")
_SSID_LISTENER_PREFIXES = ("googlehome",)
_P2P_CAMERA = re.compile(r"[A-Z]{3,4}-[0-9]{6}-[A-Z]{5}")
_V380 = re.compile(r"MV[0-9]{6,}")


def _ssid_shape(name):
    low = name.lower()
    if low.startswith(_SSID_CAMERA_PREFIXES):
        return ("Camera", LOW, "dashcam or camera setup hotspot name; spoofable")
    if _P2P_CAMERA.fullmatch(name) or _V380.fullmatch(name) or "_vantrue_" in low:
        return ("Camera", LOW, "P2P camera hotspot name pattern; spoofable")
    if low.startswith(_SSID_LISTENER_PREFIXES):
        return ("Listener", LOW, "Google speaker setup hotspot; spoofable")
    return None


def named(name, base):
    if _equal_name(name, "flock noir") or _named_prefix(name, "dragon detector"):
        return (base, NONE, "detector dashboard, not a camera")
    if base == "Ble":
        serial = len(name) == 10 and name.isdigit() and name.isascii()
        fs = 7 <= len(name) <= 15 and name.startswith("FS-") and all(c in "0123456789abcdefABCDEF" for c in name[3:])
        if fs or serial or _equal_name(name, "FS Ext Battery") or any(
                _contains(name, word) for word in ("flock", "penguin", "pigvision")):
            return ("Flock", LOW, "Flock/battery name match; arbitrary names are unverified")
        if _contains(name, "axon") or _contains(name, "bodyworn"):
            return ("Axon", LOW, "Axon name match; arbitrary names are unverified")
        if _contains(name, "flipper"):
            return ("Flipper", LOW, "Flipper name match; arbitrary names are unverified")
    if _named_prefix(name, "biscuit"):
        return ("Biscuit", LOW, "Biscuit name; Pro/Ultra model unverified")
    if _named_prefix(name, "flipper"):
        return ("Flipper", LOW, "Flipper name only; spoofable")
    if _contains(name, "smarttag"):
        return ("SmartTag", LOW, "SmartTag advertised name only")
    if _contains(name, "airtag"):
        return ("Tracker", LOW, "AirTag advertised name only")
    if _contains(name, "pwnagotchi"):
        return ("Pwnagotchi", LOW, "advertised name; spoofable")
    if _contains(name, "pineapple") or _contains(name, "hak5"):
        return ("Pineapple", LOW, "advertised name; model unverified")
    if _contains(name, "nyanbox"):
        return ("Nyanbox", LOW, "advertised name only")
    if _contains(name, "halehound"):
        return ("Halehound", LOW, "advertised name only")
    if (_contains(name, "ray-ban") or _contains(name, "rayban") or _contains(name, "oakley meta")
            or _named_prefix(name, "spectacles")):
        return ("Meta", LOW, "advertised glasses name")
    if any(_named_prefix(name, p) for p in ("axon", "AB2", "AB3", "AB4")):
        return ("Axon", LOW, "camera-like advertised name")
    if _named_prefix(name, "flock"):
        return ("Flock", LOW, "advertised Flock name")
    if _named_prefix(name, "ring"):
        return ("Ring", LOW, "Ring-like name; spoofable")
    if _named_prefix(name, "raven"):
        return ("Raven", LOW, "Raven name; service not observed")
    if base == "Wifi":
        shape = _ssid_shape(name)
        if shape:
            return shape
    if _named_prefix(name, "penguin") or _named_prefix(name, "pigvision"):
        return ("Flock", LOW, "Flock research name; accessory/camera unverified")
    if len(name) >= 5 and name[:5].lower() == "pwned":
        return ("Pineapple", LOW, "pwned SSID/name prefix; hardware unverified")
    if _named_prefix(name, "deauther"):
        return ("Pineapple", LOW, "deauther-style name; hardware unverified")
    if any(_named_prefix(name, p) for p in ("HC-03", "HC-05", "HC-06", "HC-08", "RN42", "BT04-A")):
        return ("Skimmer", LOW, "generic serial module; skimming not established")
    return (base, NONE, "no specific signature")


def _odid_message(msg, state):
    """Decode one 25-byte message into state; False when OpenDroneID rejects it."""
    kind = msg[0] >> 4
    if kind == 0:
        id_type, ua_type = msg[1] >> 4, msg[1] & 15
        # Two Basic ID slots: fill a free slot or overwrite the same ID type.
        for slot in state["basic"]:
            if slot[0] in (0, id_type):
                slot[:] = [id_type, ua_type, msg[2:22], True]
                return True
        return False
    if kind == 1:
        state["location"] = msg
    elif kind == 2:
        if not msg[1] & 15:  # page zero carries the length fields
            if msg[2] >= 16 or 17 + msg[2] * 23 < msg[3]:
                return False
    elif kind == 4:
        state["system"] = msg
    elif kind > 5:
        return False
    return True


def _odid_fields(state):
    out = {"decoded": True}
    for id_type, ua_type, raw, valid in state["basic"]:
        if not valid or not id_type:
            continue
        if id_type in (3, 4):  # UTM-assigned UUID, specific session ID: binary
            text = raw.hex().upper()
        else:
            text = "".join(chr(c) if 32 <= c < 127 else "?" for c in raw.split(b"\x00", 1)[0])
        out.update(has_id=True, id=text, id_type=id_type, aircraft_type=ua_type)
        break
    msg = state.get("location")
    if msg is not None:
        flags, speed_raw = msg[1], msg[3]
        speed = speed_raw * 0.75 + 255 * 0.25 if flags & 1 else speed_raw * 0.25
        lat, lon = struct.unpack_from("<ii", msg, 5)
        lat, lon = lat / 1e7, lon / 1e7
        altitude = struct.unpack_from("<H", msg, 15)[0] * 0.5 - 1000
        if abs(lat) <= 90 and abs(lon) <= 180 and (lat or lon):
            out.update(has_location=True, latitude=lat, longitude=lon,
                       has_altitude=altitude != -1000, has_speed=speed >= 0 and speed != 255)
            if out["has_altitude"]:
                out["altitude_m"] = altitude
            if out["has_speed"]:
                out["speed_mps"] = speed
    msg = state.get("system")
    if msg is not None:
        out["operator_location_type"] = msg[1] & 3
        lat, lon = struct.unpack_from("<ii", msg, 2)
        lat, lon = lat / 1e7, lon / 1e7
        if abs(lat) <= 90 and abs(lon) <= 180 and (lat or lon):
            out.update(has_operator=True, operator_latitude=lat, operator_longitude=lon)
    return out


def decode_remote_id(data):
    """One 25-byte ODID message or a message pack; returns a dict or None."""
    if not data:
        return None
    state = {"basic": [[0, 0, b"", False], [0, 0, b"", False]]}
    if data[0] >> 4 == 0xF:
        count = data[2] if len(data) >= 3 else 0
        if len(data) < 3 or data[1] != 25 or not 1 <= count <= 9 or len(data) != 3 + count * 25:
            return None
        messages = [data[3 + i * 25:3 + (i + 1) * 25] for i in range(count)]
        kinds = [m[0] >> 4 for m in messages]
        if any(k > 5 for k in kinds) or kinds.count(0) > 2 or kinds.count(2) > 16 or \
                any(kinds.count(k) > 1 for k in (1, 3, 4, 5)):
            return None
        valid = [_odid_message(m, state) for m in messages]
        if not any(valid):
            return None
        return _odid_fields(state)
    if len(data) != 25 or data[0] >> 4 > 5 or not _odid_message(data, state):
        return None
    return _odid_fields(state)


def _merge_drone(stored, fresh):
    """Fields from several Remote ID messages accumulate."""
    if fresh is None:
        return stored
    merged = dict(stored or {})
    merged.update(fresh)
    return merged


def _decode_drone_nan(frame):
    header, service = bytes((4, 9, 0x50, 0x6f, 0x9a, 0x13)), bytes((0x88, 0x69, 0x19, 0x9d, 0x92, 9))
    n = len(frame)
    if n < 30 or frame[24:30] != header:
        return None
    result, at = None, 30
    while at < n:
        if n - at < 3:
            return None
        kind, length = frame[at], frame[at + 1] | frame[at + 2] << 8
        at += 3
        if length > n - at:
            return None
        d = frame[at:at + length]
        if kind == 3 and length >= 11 and d[:6] == service and d[8] == 0x10:
            info = d[9]
            if info != length - 10 or info < 4:
                return None
            result = decode_remote_id(d[11:11 + info - 1])
            if result is None:
                return None
        at += length
    return result


def _valid_security_ie(d, rsn):
    n = len(d)
    if n < 8 or d[0] != 1 or d[1] != 0:
        return False
    at = 6
    for _ in range(2):
        if n - at < 2:
            return False
        count = d[at] | d[at + 1] << 8
        at += 2
        if not count or count > (n - at) // 4:
            return False
        at += count * 4
    if at == n:
        return True
    if n - at < 2:
        return False
    at += 2
    if at == n:
        return True
    if not rsn or n - at < 2:
        return False
    pmkids = d[at] | d[at + 1] << 8
    at += 2
    if pmkids > (n - at) // 16:
        return False
    at += pmkids * 16
    return at == n or n - at == 4


def _peer_name(data):
    if b'"pwnd_tot"' not in data:
        return None
    i = data.find(b'"name"')
    while i >= 0:
        p = i + 6
        while p < len(data) and data[p] in b" \t":
            p += 1
        if p < len(data) and data[p] == ord(":"):
            p += 1
            while p < len(data) and data[p] in b" \t":
                p += 1
            if p < len(data) and data[p] == ord('"'):
                p += 1
                start = p
                while p < len(data) and data[p] != ord('"'):
                    if data[p] < 32 or data[p] > 126 or data[p] == ord("\\"):
                        return None
                    p += 1
                if p == len(data) or p == start:
                    return None
                return safe_text(data[start:p])[:32]
        i = data.find(b'"name"', i + 1)
    return None


def parse_wifi(p):
    """Parse a raw 802.11 management or data frame without FCS."""
    n = len(p)
    f = {"valid": False}
    if n < 24 or p[0] & 3:
        return f
    kind, sub = (p[0] >> 2) & 3, p[0] >> 4
    if kind not in (0, 2):
        return f
    f.update(valid=True, source=p[10:16], name="", security=0, drone=None,
             match=("Wifi", NONE, "802.11 frame"))
    beacon, probe = kind == 0 and sub in (8, 5), kind == 0 and sub == 4
    protected = bool(p[1] & 0x40)
    if kind == 0 and sub in (12, 10) and n < 26:
        return {"valid": False}
    if beacon or probe:
        off = 36 if beacon else 24
        if n < off:
            return {"valid": False}
        if beacon and p[34] & 0x10:
            f["security"] = 1
        while off + 2 <= n:
            ie, length = p[off], p[off + 1]
            off += 2
            if length > n - off:
                return {"valid": False}
            body = p[off:off + length]
            if ie == 0:
                if length > 32:
                    return {"valid": False}
                f["name"] = safe_text(body)
            if ie == 48:
                if not _valid_security_ie(body, True):
                    return {"valid": False}
                f["security"] |= 4
            if ie == 221 and length >= 4 and body[:4] == b"\x00\x50\xf2\x01":
                if not _valid_security_ie(body[4:], False):
                    return {"valid": False}
                f["security"] |= 2
            if beacon and ie == 221 and length >= 8 and body[:4] == b"\xfa\x0b\xbc\x0d":
                f["drone"] = _merge_drone(f["drone"], decode_remote_id(body[5:]))
            off += length
        if off != n:
            return {"valid": False}
        f["match"] = named(f["name"], "Wifi") if beacon else \
            ("Wifi", NONE, "probe request does not identify the advertised AP")
        if probe and flock_prefix(p[10:16]) and _probe_signature_primary(p[24:]) and wildcard_probe(p[24:]) == 1:
            f["match"] = ("Flock", MEDIUM, "Flock research OUI + wildcard probe IE fingerprint; spoofable")
        peer = _peer_name(p[36:]) if beacon else None
        if peer:
            f["match"] = ("Pwnagotchi", STRONG if p[10:16] == b"\xde\xad\xbe\xef\xde\xad" else MEDIUM,
                          "Pwnagotchi peer name + counter fields; spoofable")
            f["name"] = peer
        elif f["match"][1] == NONE and p[10:13] == b"\x00\x13\x37":
            f["match"] = ("Pineapple", LOW, "Marauder OUI heuristic; Pager model unverified")
    if kind == 0 and sub == 13 and not protected:
        f["drone"] = _decode_drone_nan(p) or f["drone"]
    if f["drone"]:
        f["match"] = ("Drone", STRONG, "decoded Remote ID broadcast; position and identity self-reported")
    f["match"] = address_hint(p[10:16], True, f["match"])
    return f


FLOCK_IE_SIGNATURE = "2,12,127,221:506f9a16030103,45,191,221:0050f208000000"
_LITEON = "221:506f9a16030103"
_MONITOR_FLOCK = _FLOCK_OUIS | {0x826bf2}


def monitor_flock(mac):
    """A Flock prefix as flock-you matches it on the air: locally administered 82:6b:f2 counts too."""
    return len(mac) >= 3 and _prefix(mac) in _MONITOR_FLOCK


def wildcard_probe(ies):
    """1: an empty SSID element (a Flock-style probe), 0: a named one, -1: none. Retries without a trailing FCS."""
    for body in (ies, ies[:-4] if len(ies) > 4 else None):
        if body is None:
            break
        at = 0
        while at + 2 <= len(body):
            ie, size = body[at], body[at + 1]
            if size + 2 > len(body) - at:
                break
            if ie == 0:
                return 1 if size == 0 else 0
            at += size + 2
    return -1


def _liteon_at(ies, pos):
    return pos + 9 <= len(ies) and ies[pos] == 221 and ies[pos + 1] == 7 and ies[pos + 2:pos + 5] == b"\x50\x6f\x9a"


def _phantom(ies, ie, size, at):
    if at + 2 + size <= len(ies):
        return False
    if size > 200:
        return True
    return ie == 64 and size == 128 and any(_liteon_at(ies, j) for j in range(at + 2, min(at + 34, len(ies) - 1)))


def _resync(ies, start):
    for j in range(start, min(start + 64, len(ies) - 1)):
        if ies[j + 1] <= 200 and j + 2 + ies[j + 1] <= len(ies):
            return j
    return -1


def ie_signature(ies):
    """flock-you's probe fingerprint of the elements after the header: (signature, every byte used) or None.

    The SSID element is left out, vendor elements are 221: and up to 8 payload bytes in hex, others their number.
    A length that runs past the frame is skipped when it looks like a driver's phantom tag, and parsing picks up
    again at the next element that fits."""
    parts, at, skips, n = [], 0, 0, len(ies)
    while at + 2 <= n:
        ie, size = ies[at], ies[at + 1]
        if at + 2 + size > n:
            if skips < 16 and _phantom(ies, ie, size, at):
                skips += 1
                at += 2
                continue
            j = _resync(ies, at)
            if j > at:
                at = j
                continue
            return None
        at += 2
        if ie == 0:
            if size == 0:
                while at + 2 <= n and ies[at] == 0 and ies[at + 1] == 0:
                    at += 2
            else:
                at += size
            continue
        parts.append("221:" + bytes(ies[at:at + min(size, 8)]).hex() if ie == 221 and size >= 4 else str(ie))
        at += size
    return (",".join(parts), at == n) if parts else None


def _probe_signature(body):
    first = ie_signature(body)
    second = ie_signature(body[2:]) if len(body) >= 2 and body[0] == 0 and body[1] == 0 else None
    if first and second:
        if first[1] != second[1]:
            pick = first if first[1] else second
        else:
            pick = second if len(second[0]) > len(first[0]) else first
    else:
        pick = first or second
    if not pick:
        return ""
    sig = pick[0]
    if _LITEON in sig and not sig.startswith("2,12,127,"):
        sig = "2,12,127," + sig[sig.index(_LITEON):]
    return sig


def _probe_signature_primary(body):
    return _probe_signature(body) == FLOCK_IE_SIGNATURE or \
        len(body) > 4 and _probe_signature(body[:-4]) == FLOCK_IE_SIGNATURE


def flock_frame(frame, address=None, hopping=False):
    """flock-you's tiers on a monitor frame, or None when the frame says nothing about a Flock prefix.

    Returns (address of the Flock device, (family, confidence, evidence)). A wildcard probe from a Flock prefix with
    the fingerprint is medium evidence; without it, weak, unless the same sender hops between channels as Flock
    cameras do. Any other frame from a Flock prefix is a weak hint, and a frame sent to one is second-hand."""
    if len(frame) < 24 or frame[0] & 3 or (frame[0] >> 2) & 3 not in (0, 2):
        return None
    mgmt = (frame[0] >> 2) & 3 == 0
    addr1, addr2, addr3 = bytes(frame[4:10]), bytes(frame[10:16]), bytes(frame[16:22])
    target = parse_mac(address) if isinstance(address, str) else address
    if target not in (None, addr2) and monitor_flock(target) and (
            target == addr1 and not addr1[0] & 1 or mgmt and target == addr3):
        return target, ("Flock", LOW, "Second-hand: a frame addressed to a Flock-prefix device; shared vendor "
                                      "possible")
    if not monitor_flock(addr2):
        return None
    if mgmt and frame[0] == 0x40 and wildcard_probe(frame[24:]) == 1:
        if _probe_signature_primary(frame[24:]):
            return addr2, ("Flock", MEDIUM, "Flock prefix + wildcard probe IE fingerprint (flock-you); spoofable")
        if hopping:
            return addr2, ("Flock", MEDIUM, "Hopping wildcard prober from a Flock prefix: probes on several "
                                            "channels within seconds, as Flock cameras do; spoofable")
        return addr2, ("Flock", LOW, "Wildcard probe from a Flock prefix; IE fingerprint not matched")
    return None


_BASE_UUID = bytes((0xfb, 0x34, 0x9b, 0x5f, 0x80, 0x00, 0x00, 0x80, 0x00, 0x10, 0x00, 0x00))
_FOX = bytes((0x90, 0x4b, 0x5a, 0xc6, 0x44, 0x5f, 0x26, 0x8e, 0x2b, 0x45, 0x14, 0x71, 1, 0, 4, 0xdd))
_BISCUIT = bytes((0x4b, 0x91, 0x31, 0xc3, 0xc9, 0xc5, 0xcc, 0x8f, 0x9e, 0x45, 0xb5, 0x1f, 0x01, 0xc2, 0xaf, 0x4f))
_FLOCK_SERVICE = bytes((0x6f, 0x2e, 0x17, 0xdf, 0x14, 0x18, 0xe5, 0x9f, 0xa8, 0x46, 0x32, 0x95, 0x38, 0xbb, 0xcc, 0xe8))
_DULT = bytes((0x85, 0x2a, 0x9f, 0x57, 0xc5, 0x2a, 0xed, 0x88, 0x26, 0xc2, 0xf4, 0x12, 0x01, 0x00, 0x19, 0x15))


def _assigned_uuid16(d, width):
    if width == 16:
        if d[:12] != _BASE_UUID or d[14] or d[15]:
            return None
        d = d[12:]
    elif width == 4:
        if d[2] or d[3]:
            return None
    elif width != 2:
        return None
    return d[0] | d[1] << 8


def _width(t):
    return 2 if t in (2, 3, 0x16) else 4 if t in (4, 5, 0x20) else 16 if t in (6, 7, 0x21) else 0


def _segments(p, adv_length):
    """Yield (type, data) for each AD structure; None on malformed framing."""
    out, o, n = [], 0, len(p)
    while o < n:
        end = adv_length if adv_length and o < adv_length else n
        length = p[o]
        o += 1
        if not length:
            o = end
            continue
        if length > end - o:
            return None
        out.append((p[o], p[o + 1:o + length]))
        o += length
    return out


def parse_ble(p, adv_length=0):
    f = {"valid": False}
    if not p or adv_length > len(p):
        return f
    segments = _segments(p, adv_length)
    if segments is None:
        return f
    s = dict.fromkeys(("xuntong", "lux", "meta", "findmy", "flipper", "meta_service", "dult", "axon_company",
                       "axon_service", "smarttag", "biscuit", "flock_service", "snap", "snap_service", "vuzix",
                       "chipolo", "axon_bwc", "raven", "tile", "google", "ibeacon", "serial", "fox",
                       "google_service", "drone_service", "apple_pairing", "ibeacon_extra", "sonos",
                       "flipper_company", "findmy_near", "airtag_unpaired", "siri"), False)
    raven_services, appearance, name, drone, company = 0, 0, "", None, None
    beacon = owner = None

    def service(uuid):
        nonlocal raven_services
        s["findmy"] |= uuid == 0xfd44
        s["flipper"] |= 0x3080 <= uuid <= 0x3083
        s["axon_service"] |= uuid in (0xfc81, 0xfe6b, 0xfe6c)
        s["smarttag"] |= uuid == 0xfd5a
        s["meta_service"] |= uuid in (0xfd5f, 0xfeb7, 0xfeb8)
        s["snap_service"] |= uuid == 0xfe45
        s["tile"] |= uuid in (0xfeed, 0xfeec, 0xfd84)
        s["dult"] |= uuid == 0xfcb2
        s["chipolo"] |= uuid in (0xfe33, 0xfe65)
        s["serial"] |= uuid == 0x1101
        s["google_service"] |= uuid == 0xfeaa
        s["drone_service"] |= uuid == 0xfffa
        s["sonos"] |= uuid == 0xfe07
        if 0x3100 <= uuid <= 0x3500 and not uuid & 0xff:
            s["raven"] = True
            raven_services |= 1 << ((uuid >> 8) - 0x31)

    for t, d in segments:
        z = len(d)
        if (t in (2, 3) and z % 2) or (t in (4, 5) and z % 4) or (t in (6, 7) and z % 16) or \
                (t == 0x16 and z < 2) or (t == 0x20 and z < 4) or (t == 0x21 and z < 16):
            return f
        if t == 0x19 and z == 2:
            appearance = d[0] | d[1] << 8
        if t in (8, 9) and z:
            name = safe_text(d[:63])
        if t == 0xff and z >= 2:
            cid = d[0] | d[1] << 8
            company = cid
            s["axon_company"] |= cid == 0x034d
            s["xuntong"] |= cid == 0x09c8
            s["lux"] |= cid == 0x0d53
            s["meta"] |= cid == 0x01ab
            s["vuzix"] |= cid == 0x060c
            s["chipolo"] |= cid == 0x08c3
            s["snap"] |= cid == 0x03c2
            s["sonos"] |= cid == 0x05a7
            s["flipper_company"] |= cid == 0x0e29
            is_ibeacon = cid == 0x004c and z >= 25 and d[2] == 2 and d[3] == 0x15
            s["ibeacon"] |= is_ibeacon
            s["ibeacon_extra"] |= is_ibeacon and z > 25
            s["apple_pairing"] |= cid == 0x004c and z == 29
            if cid == 0x004c and z >= 4:
                s["findmy"] |= d[2] == 0x12 and d[3] == 0x19 and z >= 29
                if d[2] == 0x12 and d[3] == 0x19 and z >= 5:
                    owner = "away from owner"
                if d[2] == 0x12 and d[3] == 0x02:
                    s["findmy_near"] = True
                    owner = "with owner"
                if z >= 7 and d[2] == 0x07 and d[3] == 0x19 and d[5] == 0x00 and d[6] == 0x55:
                    s["airtag_unpaired"] = True
                    owner = "not set up"
                at = 2
                while at + 1 < z:
                    kind, size = d[at], d[at + 1]
                    if at + 2 + size > z:
                        break
                    if kind == 0x08 and size == 7:
                        s["siri"] |= d[at + 6:at + 8] in (b"\x00\x07", b"\x07\x00")
                        break
                    at += 2 + size
            if cid == 0x004c and z == 25 and d[2] == 2 and d[3] == 0x15 and beacon is None:
                beacon = {"uuid": d[4:20].hex(), "major": d[20] << 8 | d[21], "minor": d[22] << 8 | d[23],
                          "measured_power": struct.unpack("b", d[24:25])[0]}
        width = _width(t)
        service_data = t in (0x16, 0x20, 0x21)
        if width:
            for j in range(0, z - width + 1, width):
                uuid = _assigned_uuid16(d[j:j + width], width)
                if uuid is not None:
                    service(uuid)
                if service_data:
                    break
        if service_data and z > width:
            data_uuid = _assigned_uuid16(d[:width], width)
            body = d[width:]
            if data_uuid == 0xfeaa and body[0] in (0x40, 0x41) and len(body) in (21, 22, 33, 34):
                s["google"] = True
            if data_uuid == 0xfffa and len(body) >= 27 and body[0] == 0x0d:
                drone = _merge_drone(drone, decode_remote_id(body[2:]))
        if t in (6, 7, 0x21) and z >= 16:
            s["fox"] |= t == 0x21 and z == 21 and d[:16] == _FOX and d[16] == 1
            for j in range(0, z - 15, 16):
                chunk = d[j:j + 16]
                s["biscuit"] |= chunk == _BISCUIT
                s["flock_service"] |= chunk == _FLOCK_SERVICE
                s["dult"] |= chunk == _DULT
                if t == 0x21:
                    break
        if t in (0x21, 0xff, 6, 7):
            s["axon_bwc"] |= b"BWCDEVICE" in d or b"ECIVEDCWB" in d
    match = named(name, "Ble")
    penguin = name.startswith("Penguin-") and len(name) == 18 and name[8:].isdigit()
    numeric = len(name) == 10 and name.isdigit()
    if s["fox"]:
        match = ("Fox", STRONG, "Dragon fox training beacon; unauthenticated, not a threat")
    elif drone:
        match = ("Drone", STRONG, "decoded Remote ID broadcast; position and identity self-reported")
    elif s["axon_bwc"]:
        match = ("Axon", MEDIUM, "BWCDEVICE body-camera payload marker; spoofable, recording unknown")
    elif s["axon_company"] or s["axon_service"]:
        match = ("Axon", STRONG if s["axon_company"] and s["axon_service"] else MEDIUM,
                 "Axon/TASER company or member service ID; model/recording unknown")
    elif s["flock_service"]:
        match = ("Flock", STRONG, "Flock accessory 128-bit service; camera presence unverified")
    elif s["xuntong"] and (penguin or numeric or _equal_name(name, "FS Ext Battery")):
        match = ("Flock", MEDIUM, "Xuntong company + Flock battery name")
    elif (s["lux"] or s["meta"]) and s["meta_service"]:
        match = ("Meta", MEDIUM, "Meta/Luxottica + Meta service composite; recording unknown")
    elif s["snap"] and s["snap_service"]:
        match = ("Meta", MEDIUM, "Snap company + FE45 service; model/recording unknown")
    elif s["raven"]:
        match = ("Raven", STRONG if raven_services == 0x1f else MEDIUM,
                 "exact Raven research service; spoofable, field validation pending")
    elif s["biscuit"] and _named_prefix(name, "biscuit"):
        match = ("Biscuit", MEDIUM, "Biscuit name + service; Pro/Ultra model unverified")
    elif s["smarttag"]:
        match = ("SmartTag", MEDIUM, "Samsung FD5A service; owner and model unknown")
    elif s["google"]:
        match = ("GoogleTag", STRONG, "Find Hub 40/41 frame and valid EID length; owner unknown")
    elif s["chipolo"]:
        match = ("GoogleTag", LOW, "Chipolo identifier; network/model/owner unverified")
    elif s["tile"]:
        match = ("Tile", MEDIUM, "Tile-assigned service; owner unknown")
    elif s["findmy"]:
        match = ("Tracker", MEDIUM, "Find My protocol; may be AirTag or another accessory")
    elif s["findmy_near"]:
        match = ("Tracker", MEDIUM, "Find My near-owner frame; AirTag or Find My accessory with its owner")
    elif s["dult"]:
        match = ("Tracker", MEDIUM, "DULT tracker service; owner unknown")
    elif s["flipper"]:
        match = ("Flipper", MEDIUM if appearance == 0x8600 or s["flipper_company"] else LOW,
                 "Flipper Zero service; activity unverified")
    elif s["flipper_company"]:
        match = ("Flipper", MEDIUM, "Flipper Devices company ID; activity unverified")
    elif s["ibeacon"]:
        match = ("IBeacon", LOW if s["ibeacon_extra"] else STRONG, "iBeacon format; common benign proximity beacon")
    elif s["siri"]:
        match = ("Listener", MEDIUM, "Apple Hey Siri advert (HomePod class); spoofable")
    elif s["sonos"]:
        match = ("Listener", MEDIUM, "Sonos company or service ID; speaker with microphones")
    elif s["airtag_unpaired"]:
        match = ("Tracker", MEDIUM, "Apple pairing advert with AirTag model 0x0055; unpaired or reset AirTag")
    elif s["serial"] and match[1] == NONE:
        match = ("Skimmer", LOW, "serial service; common benign module, not proof of a skimmer")
    elif s["lux"] and match[1] == NONE:
        match = ("Meta", LOW, "Luxottica company only; product unverified")
    elif (s["snap"] or s["snap_service"] or s["meta"] or s["vuzix"]) and match[1] == NONE:
        match = ("Meta", LOW, "Glasses-vendor identifier; model/recording unverified")
    elif match[1] == NONE:
        if s["meta_service"]:
            match = ("Meta", LOW, "Meta service only; glasses/recording not established")
        elif s["xuntong"]:
            match = ("Flock", LOW, "Xuntong module company; camera or battery unverified")
        elif s["google_service"]:
            match = ("GoogleTag", LOW, "FEAA shared with Eddystone beacons; Find Hub tracker unverified")
        elif s["drone_service"]:
            match = ("Drone", LOW, "FFFA service; no valid aircraft Remote ID decoded")
        elif s["apple_pairing"]:
            match = ("Tracker", LOW, "Apple pairing-size advert; may be AirTag, AirPods or other accessory")
    return {"valid": True, "name": name, "company": company, "match": match, "drone": drone, "beacon": beacon,
            "owner": owner}


_AXON_COMPANY, _AXON_SERVICE, _AXON_OUI, _AXON_COMPAT, _AXON_NAME, _AXON_RESEARCH, _AXON_BWC, _BODYCAM = \
    1, 2, 4, 8, 16, 32, 64, 128


def _axon_match(signals):
    if signals & (_AXON_COMPANY | _AXON_SERVICE) == _AXON_COMPANY | _AXON_SERVICE:
        return ("Axon", STRONG, "Axon/TASER CID 034D + assigned service; model/recording unknown")
    for bit, confidence, evidence in (
            (_BODYCAM, MEDIUM, "WatchGuard / Digital Ally vendor; body-camera model/recording unknown"),
            (_AXON_BWC, MEDIUM, "BWCDEVICE body-camera payload marker; recording unknown"),
            (_AXON_COMPANY, MEDIUM, "Axon/TASER manufacturer CID 034D; model/recording unknown"),
            (_AXON_SERVICE, MEDIUM, "Axon/TASER service FC81/FE6B/FE6C; model/recording unknown"),
            (_AXON_OUI, MEDIUM, "Axon public/source OUI 00:25:DF; model/recording unknown"),
            (_AXON_COMPAT, LOW, "AXEOFF UUID/address match; custom UUID or random address"),
            (_AXON_NAME, LOW, "Axon / AB2 / AB3 / AB4 advertised name match"),
            (_AXON_RESEARCH, LOW, "SquachWatch Axon address match; shared radio vendor")):
        if signals & bit:
            return ("Axon", confidence, evidence)
    return ("Ble", NONE, "no Axon signature")


def _axon_prefix(mac):
    return mac is not None and mac[:3] == b"\x00\x25\xdf"


def _bodycam_prefix(mac):
    return mac is not None and mac[:3] in (b"\x00\x1d\x96", b"\x00\x23\xbd")


def _axon_research_prefix(mac):
    return mac is not None and mac[:3] in (b"\x28\x24\xff", b"\xe4\x05\x40")


def _axon_name(raw):
    name = safe_text(raw[:63])
    return _contains(name, "axon") or _contains(name, "bodyworn") or \
        any(_named_prefix(name, p) for p in ("AB2", "AB3", "AB4"))


def _inspect_axon_ble(p, adv_length, mac, address_type):
    signals = 0
    public = address_type in (0, 2)
    if _axon_prefix(mac):
        signals |= _AXON_OUI if public else _AXON_COMPAT
    if public and _axon_research_prefix(mac):
        signals |= _AXON_RESEARCH
    if public and _bodycam_prefix(mac):
        signals |= _BODYCAM
    if not p or adv_length > len(p):
        return signals
    o, n = 0, len(p)
    while o < n:
        end = adv_length if adv_length and o < adv_length else n
        length = p[o]
        o += 1
        if not length or length > end - o:
            o = end
            continue
        t, d = p[o], p[o + 1:o + length]
        if t == 0xff and len(d) >= 2 and d[0] == 0x4d and d[1] == 3:
            signals |= _AXON_COMPANY
        if t in (0xff, 0x21, 6, 7) and (b"BWCDEVICE" in d or b"ECIVEDCWB" in d):
            signals |= _AXON_BWC
        if t in (8, 9) and _axon_name(d):
            signals |= _AXON_NAME
        width = _width(t)
        service_data = t in (0x16, 0x20, 0x21)
        if width and len(d) >= width and (service_data or len(d) % width == 0):
            for at in range(0, len(d) - width + 1, width):
                uuid = _assigned_uuid16(d[at:at + width], width)
                if uuid in (0xfc81, 0xfe6b, 0xfe6c):
                    signals |= _AXON_SERVICE
                elif uuid is None and width >= 4:
                    short = d[at + (12 if width == 16 else 0):]
                    if (short[0] | short[1] << 8) in (0xfc81, 0xfe6b, 0xfe6c):
                        signals |= _AXON_COMPAT
                if service_data:
                    break
        o += length
    return signals


def _with_axon(current, signals):
    nxt = _axon_match(signals)
    if nxt[1] == NONE or current[1] > nxt[1]:
        return current
    if current[1] == nxt[1] and _family_priority(current[0]) > _family_priority(nxt[0]):
        return current
    return nxt


_FAMILY_CATEGORY = {"Flock": "flock", "Alpr": "alpr", "Axon": "axon", "IBeacon": "ibeacon", "Ring": "ring",
                    "Camera": "camera", "Drone": "drone", "SmartTag": "samsung_tag", "GoogleTag": "google_tag",
                    "Tile": "tile", "Meta": "glasses", "Raven": "raven", "Skimmer": "skimmer",
                    "Pineapple": "hacker", "Pwnagotchi": "hacker", "Nyanbox": "hacker", "Halehound": "hacker",
                    "Flipper": "hacker", "Biscuit": "hacker", "Fleet": "axon", "Listener": "listener", "Fox": "hacker"}


def _result(match, drone=None, beacon=None):
    family, confidence, evidence = match
    category = _FAMILY_CATEGORY.get(family)
    if family == "Tracker":
        category = "airtag" if any(w in evidence for w in ("Find My", "Apple", "AirTag")) else "google_tag"
    if category is None or confidence == NONE:
        return {"category": None, "confidence": NONE, "payload_valid": True}
    if family == "Fox":
        confidence = LOW
    if category in ("airtag", "ibeacon"):
        vendor = "Apple format"
    elif family == "Fleet":
        vendor = evidence[:evidence.find(" OUI")] + " fleet router"
    elif family == "Fox":
        vendor = "Dragon fox test beacon"
    elif "Xuntong" in evidence:
        vendor = "Xuntong"
    elif category == "flock" and confidence >= MEDIUM:
        vendor = "Flock accessory"
    elif category == "axon" and "Axon" in evidence:
        vendor = "Axon / TASER candidate"
    elif drone:
        vendor = "Remote ID broadcast"
    elif category == "ring" and "Ring" in evidence:
        vendor = "Ring"
    elif "Samsung" in evidence:
        vendor = "Samsung"
    elif "Tile" in evidence:
        vendor = "Tile"
    elif "Find Hub" in evidence:
        vendor = "Find Hub format"
    elif category == "listener":
        vendor = "Sonos" if "Sonos" in evidence else "Apple" if "Siri" in evidence else \
            "Google" if "Google" in evidence else ""
    elif "OUI" in evidence or "product unverified" in evidence:
        cut = [i for i in (evidence.find(" OUI"), evidence.find(";")) if i >= 0]
        vendor = evidence[:min(cut)] if cut else evidence
    else:
        vendor = ""
    out = {"category": category, "label": CATEGORY_LABELS[category], "confidence": confidence,
           "confidence_name": CONFIDENCE_NAMES[confidence], "evidence": evidence, "vendor": vendor[:31],
           "payload_valid": True}
    if family in ("Fleet", "Fox"):
        out["hint_only"] = True
    if drone:
        out["remote_id"] = drone
    if beacon:
        out["beacon"] = beacon
    return out


def parse_mac(text):
    try:
        parts = text.split(":")
        if len(parts) != 6 or any(len(p) != 2 for p in parts):
            return None
        return bytes(int(p, 16) for p in parts)
    except (AttributeError, ValueError):
        return None


def classify_wifi(address, ssid="", frame=None, hopping=False):
    """Classify an AP from its BSSID and SSID, or a full 802.11 frame without FCS.

    With a frame from a monitor adapter, the result's "address" is the Flock device the frame points to, which for
    a frame sent to a Flock prefix is not the sender."""
    if frame is not None:
        if len(frame) > MAX_WIFI_BYTES:
            return {"category": None, "confidence": NONE, "payload_valid": False}
        tier = flock_frame(frame, address, hopping)
        if tier is not None:
            result = _result(tier[1])
            result["address"] = ":".join("%02X" % b for b in tier[0])
            return result
        parsed = parse_wifi(frame)
        signals = 0
        if len(frame) >= 24 and not frame[0] & 3 and (frame[0] >> 2) & 3 in (0, 2):
            src = frame[10:16]
            signals = _AXON_OUI if _axon_prefix(src) else _BODYCAM if _bodycam_prefix(src) else \
                _AXON_RESEARCH if _axon_research_prefix(src) else 0
            if frame[0] in (0x80, 0x50):
                at = 36
                while at + 2 <= len(frame):
                    ie, length = frame[at], frame[at + 1]
                    at += 2
                    if length > len(frame) - at:
                        break
                    if ie == 0 and length <= 32 and _axon_name(frame[at:at + length]):
                        signals |= _AXON_NAME
                    at += length
        if not parsed["valid"]:
            return {"category": None, "confidence": NONE, "payload_valid": False}
        return _result(_with_axon(parsed["match"], signals), parsed.get("drone"))
    mac = parse_mac(address) if isinstance(address, str) else address
    if mac is None:
        return {"category": None, "confidence": NONE, "payload_valid": False}
    name = safe_text((ssid or "").encode("utf-8", "replace")[:32])
    match = address_hint(mac, True, named(name, "Wifi"))
    if not mac[0] & 3:
        signals = _AXON_OUI if _axon_prefix(mac) else _BODYCAM if _bodycam_prefix(mac) else \
            _AXON_RESEARCH if _axon_research_prefix(mac) else 0
        match = _with_axon(match, signals)
    return _result(match)


def classify_ble(address, address_type, ad, adv_length=0):
    """address_type: 0 public, 1 random, 2 public identity, 3 random identity."""
    if not ad or len(ad) > MAX_BLE_BYTES or adv_length > len(ad):
        return {"category": None, "confidence": NONE, "payload_valid": False}
    mac = parse_mac(address) if isinstance(address, str) else address
    if mac is None:
        address_type = 255
    parsed = parse_ble(ad, adv_length)
    if not parsed["valid"]:
        # Malformed AD framing never yields a classification.
        return {"category": None, "confidence": NONE, "payload_valid": False}
    public_mac = mac if mac is not None and address_type in (0, 2) and not mac[0] & 3 else bytes(6)
    signals = _inspect_axon_ble(ad, adv_length, public_mac, 0)
    public = mac is not None and address_type in (0, 2) and not mac[0] & 3
    match = _with_axon(parsed["match"], signals)
    if public:
        match = address_hint(mac, True, match)
    result = _result(match, parsed.get("drone"), parsed.get("beacon"))
    if parsed.get("name"):
        result["name"] = parsed["name"]
    if parsed.get("owner") and result.get("category") == "airtag":
        result["owner"] = parsed["owner"]
    return result


def advertisement_from_properties(name=None, uuids=(), manufacturer=None, service_data=None):
    """Rebuild a bounded AD stream from BlueZ Device1 properties.

    BlueZ exposes parsed advertisement fields rather than raw bytes. Rebuilding
    them in AD form lets one classifier serve both. Flags and TX power are not
    needed by any rule and are omitted.
    """
    out = bytearray()

    def add(kind, data):
        if len(data) <= 254 and len(out) + len(data) + 2 <= MAX_BLE_BYTES:
            out.extend((len(data) + 1, kind))
            out.extend(data)

    if name:
        add(0x09, name.encode("utf-8", "replace")[:29])
    short, wide = bytearray(), bytearray()
    for text in uuids or ():
        raw = _uuid_bytes(text)
        if raw is None:
            continue
        if raw[:12] == _BASE_UUID and not raw[14] and not raw[15]:
            short.extend(raw[12:14])
        else:
            wide.extend(raw)
    if short:
        add(0x03, bytes(short))
    for start in range(0, len(wide), 16 * 15):
        add(0x07, bytes(wide[start:start + 16 * 15]))
    for text, value in (service_data or {}).items():
        raw = _uuid_bytes(text)
        if raw is None:
            continue
        if raw[:12] == _BASE_UUID and not raw[14] and not raw[15]:
            add(0x16, raw[12:14] + bytes(value))
        else:
            add(0x21, raw + bytes(value))
    for company, value in sorted((manufacturer or {}).items()):
        add(0xff, struct.pack("<H", int(company) & 0xffff) + bytes(value))
    return bytes(out)


def _uuid_bytes(text):
    """128-bit UUID string to little-endian AD bytes."""
    try:
        hexits = str(text).replace("-", "")
        if len(hexits) == 4:
            hexits = "0000%s00001000800000805f9b34fb" % hexits
        if len(hexits) != 32:
            return None
        return bytes.fromhex(hexits)[::-1]
    except ValueError:
        return None


def distance_from_rssi(rssi, measured_power=-59, exponent=2.2):
    """Rough free-space range estimate in metres, for a 'getting closer' cue only."""
    if rssi is None:
        return None
    return round(10 ** ((measured_power - rssi) / (10 * exponent)), 1)
