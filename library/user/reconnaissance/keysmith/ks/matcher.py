"""Which default-key algorithm applies to this beacon?

This is the decision table from RouterKeygen's ``WirelessMatcher`` (GPLv3),
ported to Python.  It is the part that makes KEYSMITH useful: an SSID alone
tells you which vendor scheme to run, and which MAC bytes the vendor mangled.

``candidates(ssid, bssid)`` returns a list of :class:`Candidate` objects in the
same order RouterKeygen tries them.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

from . import keygens

# MAC prefixes, normalised to upper-case colon form.
_ARCADYAN = (
    "00:12:BF", "00:1A:2A", "00:1D:19", "00:23:08", "00:26:4D", "50:7E:5D",
    "1C:C6:3C", "74:31:70", "7C:4F:B5", "7E:4F:B5", "84:9C:A6", "88:03:55",
    "88:25:2C",
)
_ARNET = (
    "00:08:27", "00:13:C8", "00:17:C2", "00:19:3E", "00:1C:A2", "00:1D:8B",
    "00:22:33", "00:23:8E", "00:25:53", "00:8C:54", "30:39:F2", "38:22:9D",
    "64:87:D7", "74:88:8B", "84:26:15", "A4:52:6F", "A4:5D:A1", "D0:D4:12",
    "D4:D1:84", "DC:0B:1A", "F0:84:2F",
)
_HUAWEI = (
    "00:18:82", "00:19:15", "00:1E:10", "00:22:A1", "00:25:68", "00:25:9E",
    "00:34:FE", "00:46:4B", "00:66:4B", "00:E0:FC", "00:F8:1C", "04:02:1F",
    "04:BD:70", "04:C0:6F", "04:F9:38", "08:19:A6", "08:63:61", "08:7A:4C",
    "08:E8:4F", "0C:37:DC", "0C:96:BF", "0C:D6:BD", "10:1B:54", "10:47:80",
    "10:51:72", "10:C6:1F", "14:B9:68", "18:C5:8A", "1C:1D:67", "1C:8E:5C",
    "20:08:ED", "20:0B:C7", "20:2B:C1", "20:F3:A3", "24:09:95", "24:1F:A0",
    "24:69:A5", "24:7F:3C", "24:9E:AB", "24:DB:AC", "28:31:52", "28:3C:E4",
    "28:5F:DB", "28:6E:D4", "2C:CF:58", "30:87:30", "30:D1:7E", "30:F3:35",
    "34:00:A3", "34:6B:D3", "34:CD:BE", "38:F8:89", "3C:47:11", "3C:DF:BD",
    "3C:F8:08", "40:4D:8E", "40:CB:A8", "44:55:B1", "48:46:FB", "48:62:76",
    "4C:1F:CC", "4C:54:99", "4C:8B:EF", "4C:B1:6C", "50:9F:27", "50:A7:2B",
    "54:39:DF", "54:89:98", "54:A5:1B", "58:1F:28", "58:2A:F7", "58:7F:66",
    "5C:4C:A9", "5C:7D:5E", "5C:B3:95", "5C:B4:3E", "5C:F9:6A", "60:DE:44",
    "60:E7:01", "64:16:F0", "64:3E:8C", "64:A6:51", "68:89:C1", "68:8F:84",
    "68:A0:F6", "68:A8:28", "70:54:F5", "70:72:3C", "70:7B:E8", "70:A8:E3",
    "74:88:2A", "74:A0:63", "78:1D:BA", "78:6A:89", "78:D7:52", "78:F5:FD",
    "7C:60:97", "7C:A2:3E", "80:38:BC", "80:71:7A", "80:B6:86", "80:D0:9B",
    "80:FB:06", "84:5B:12", "84:A8:E4", "84:DB:AC", "88:53:D4", "88:86:03",
    "88:A2:D7", "88:CE:FA", "88:E3:AB", "8C:34:FD", "90:17:AC", "90:4E:2B",
    "90:67:1C", "94:04:9C", "94:77:2B", "9C:28:EF", "9C:37:F4", "9C:C1:72",
    "A4:99:47", "A4:DC:BE", "AC:4E:91", "AC:85:3D", "AC:E2:15", "AC:E8:7B",
    "B0:5B:67", "B4:15:13", "B4:30:52", "B8:BC:1B", "BC:25:E0", "BC:76:70",
    "BC:9C:31", "C0:70:09", "C4:05:28", "C4:07:2F", "C8:51:95", "C8:D1:5E",
    "CC:53:B5", "CC:96:A0", "CC:A2:23", "CC:CC:81", "D0:2D:B3", "D0:3E:5C",
    "D0:7A:B5", "D4:40:F0", "D4:6A:A8", "D4:6E:5C", "D4:94:E8", "D4:B1:10",
    "D4:F9:A1", "D8:49:0B", "DC:D2:FC", "E0:19:1D", "E0:24:7F", "E0:36:76",
    "E0:97:96", "E4:35:C8", "E4:68:A3", "E4:C2:D1", "E8:08:8B", "E8:BD:D1",
    "E8:CD:2D", "EC:23:3D", "EC:38:8F", "EC:CB:30", "F4:55:9C", "F4:8E:92",
    "F4:9F:F3", "F4:C7:14", "F4:DC:F9", "F4:E3:FB", "F8:01:13", "F8:3D:FF",
    "F8:4A:BF", "F8:98:B9", "F8:BF:09", "F8:E8:11", "FC:48:EF", "FC:E3:3C",
)
_HG824X = (
    "00:18:82", "00:1E:10", "00:22:A1", "00:25:68", "00:25:9E", "00:34:FE",
    "00:46:4B", "00:66:4B", "00:E0:FC", "00:F8:1C", "08:19:A6", "08:63:61",
    "08:7A:4C", "08:E8:4F", "10:1B:54", "10:47:80", "10:51:72", "10:C6:1F",
    "20:08:ED", "20:0B:C7", "20:2B:C1", "20:F3:A3", "28:31:52", "28:3C:E4",
    "28:5F:DB", "28:6E:D4", "48:46:FB", "48:62:76", "70:54:F5", "70:72:3C",
    "70:7B:E8", "70:A8:E3", "80:38:BC", "80:71:7A", "80:B6:86", "80:D0:9B",
    "80:FB:06", "AC:4E:91", "AC:85:3D", "AC:E2:15", "AC:E8:7B", "CC:53:B5",
    "CC:96:A0", "CC:A2:23", "CC:CC:81", "D4:40:F0", "D4:6A:A8", "D4:6E:5C",
    "D4:94:E8", "D4:B1:10", "D4:F9:A1", "E0:19:1D", "E0:24:7F", "E0:36:76",
    "E0:97:96", "F8:01:13", "F8:3D:FF", "F8:4A:BF", "F8:98:B9", "F8:BF:09",
    "F8:E8:11",
)
_BELKIN = ("08:86:3B", "14:91:82", "94:10:3E", "94:44:52", "B4:75:0E",
           "C0:56:27", "EC:1A:59")
_SKY = ("C4:3D:C7", "E0:46:9A", "E0:91:F5", "00:09:5B", "00:0F:B5", "00:14:6C",
        "00:18:4D", "00:26:F2", "C0:3F:0E", "30:46:9A", "00:1B:2F", "A0:21:B7",
        "00:1E:2A", "00:1F:33", "00:22:3F", "00:24:B2")
_VERIZON = ("00:1F:90", "A8:39:44", "00:18:01", "00:20:E0", "00:0F:B3",
            "00:1E:A7", "00:15:05", "00:24:7B", "00:26:62", "00:26:B8")
_WLAN2 = ("00:01:38", "00:16:38", "00:01:13", "00:01:1B", "00:19:5B")
_PIRELLI_VENDORS = (
    "000827", "0013C8", "0017C2", "00193E", "001CA2", "001D8B", "002233",
    "00238E", "002553", "00A02F", "080018", "3039F2", "38229D", "6487D7",
)
_ZYXEL = ("00:1F:A4", "F4:3E:61", "40:4A:03")
_COMTREND = ("00:1B:20", "64:68:0C", "00:1D:20", "00:23:F8", "38:72:C0",
             "30:39:F2", "8C:0C:A3", "5C:33:8E", "C8:6C:87", "D0:AE:EC",
             "00:19:15", "00:1A:2B", "F4:3E:61", "F8:8E:85")
_HOTBOX = ("7C:B7:33", "A0:64:8F", "B4:EE:B4", "E0:CE:C3")
_TP_LINK_BSSID = ("10:FE:ED", "30:B5:C2", "64:66:B3", "64:70:02", "90:F6:52",
                  "A0:F3:C1", "C0:4A:00", "F8:1A:67")

_THOMSON_RE = re.compile(
    r"^(Thomson|Blink|SpeedTouch|O2Wireless|O2wireless|Orange-|ORANGE-|INFINITUM|"
    r"BigPond|Otenet|Bbox-|DMAX|privat|TN_private_|CYTA|Vodafone-|Optimus|"
    r"OptimusFibra|MEO-|Forthnet-)[0-9a-fA-F]{6}$")


@dataclass
class Candidate:
    name: str
    mac: str
    kwargs: dict = field(default_factory=dict)
    note: str = ""


def _colons(hexmac: str) -> str:
    h = keygens._norm(hexmac)
    return ":".join(h[i:i + 2] for i in range(0, 12, 2))


def _rs(ssid: str, pattern: str) -> bool:
    return re.search(pattern, ssid) is not None


def candidates(ssid: str, bssid: str) -> list[Candidate]:
    h = keygens._norm(bssid)[:12]
    mc = _colons(h) if len(h) == 12 else ""
    out: list[Candidate] = []

    def add(name, mac=None, **kwargs):
        out.append(Candidate(name, mac if mac is not None else h, kwargs))

    # ── Alice Italy (table driven; the matcher may pass a 6-char prefix) ──
    if _rs(ssid, r"^[aA]lice-[0-9]{8}$"):
        entries = keygens._alice_table().get(ssid[6:9])
        if entries:
            vendor = entries[0][3]
            mac_used = h if h[:6] == vendor else vendor
            add("AliceItaly", mac_used)

    if mc.startswith(("00:1E:40", "00:25:5E")):
        add("AliceGermany")
    if ssid == "Andared":
        add("Andared")
    if mc.startswith(_ARCADYAN):
        add("Arcadyan")
    if mc.startswith(_ARNET):
        add("ArnetPirelli")
    if _rs(ssid, r"^(AXTEL|AXTEL-XTREMO|AXTEL XTREMO)-[0-9A-F]{4}$"):
        add("Axtel")
    if _rs(ssid, r"^Cabovisao-[0-9A-F]{4}$") and (not bssid or mc.startswith("C0:AC:54")):
        add("CabovisaoSagem")
    if ssid.upper().startswith("CONN-X"):
        add("Conn")
    if _rs(ssid, r"^Discus--?[0-9a-fA-F]{6}$"):
        add("Discus")
    if _rs(ssid, r"^DLink-[0-9a-fA-F]{6}$") or _rs(ssid, r"^dlink-[0-9](\d)+$"):
        add("Dlink")
    if _rs(ssid, r"^[eE]ircom[0-7]{4} ?[0-7]{4}$"):
        mac_used = h
        if not bssid:
            filtered = ssid.replace(" ", "")
            try:
                end = "%06X" % (int(filtered[-8:], 8) ^ 0x000FCC)
            except ValueError:
                end = ""
            if end:
                mac_used = "000FCC" + end
        add("Eircom", mac_used)
    if _rs(ssid, r"^INFINITUM[0-9a-z]{4}$") or mc.startswith(_HUAWEI):
        add("Huawei")
    if mc.startswith(_HG824X):
        add("HG824x")
    if _rs(ssid, r"^InfostradaWiFi-[0-9a-f]{6}$"):
        add("Infostrada")
    if ssid.startswith("InterCable"):
        add("InterCable")
    if _rs(ssid, r"^[Pp]1[0-9]{6}0{4}[0-9]$"):
        add("Ono")
    if _rs(ssid, r"^(OTE|ote)[0-9a-fA-F]{4}") and mc.startswith("00:13:33"):
        add("OteBAUD")
    if ssid.upper().startswith("OTE") and mc.startswith(
            ("E8:39:DF:F5", "E8:39:DF:F6", "E8:39:DF:FD")):
        table = keygens._cache.get("ote")
        if table is None:
            table = []
            try:
                with open(os.path.join(keygens.DATA_DIR, "ote_huawei.txt"),
                          "r", encoding="utf-8", errors="replace") as fh:
                    table = [line.strip() for line in fh if line.strip()]
            except OSError:
                table = []
            keygens._cache["ote"] = table
        target = int(h[8:12], 16)
        if table and target > 65535 - len(table):
            add("OteHuawei", magic=table[65535 - target])
    if _rs(ssid, r"^PBS-[0-9A-F]{6}$"):
        add("PBS")
    if _rs(ssid, r"^(B|b)elkin(\.|_)[0-9a-fA-F]{3,6}$") and mc.startswith(_BELKIN):
        add("Belkin")
    if _rs(ssid, r"^FASTWEB-1-(000827|0013C8|0017C2|00193E|001CA2|001D8B|"
                 r"002233|00238E|002553|00A02F|080018|3039F2|38229D|6487D7)"
                 r"[0-9A-F]{6}$"):
        mac_used = h
        if not bssid:
            mac_used = ssid[-12:]
        add("Pirelli", mac_used)
    if _rs(ssid, r"^Sitecom[0-9a-fA-F]{6}$") or mc.startswith(("00:0C:F6", "64:D1:A3")):
        macs = [h]
        if not bssid or h == "":
            macs = ["000CF6" + ssid[-6:], "64D1A3" + ssid[-6:]]
        for m in macs:
            add("Sitecom", m)
            add("SitecomWLR400x", m)
            add("SitecomWLR2100", m)
    if _rs(ssid, r"^SKY[0-9]{5}$") and mc.startswith(_SKY):
        add("SkyV1")
    if _rs(ssid, r"^WLAN-[0-9A-F]{6}$"):
        if ssid[5:9] == mc[9:14].replace(":", ""):
            if mc.startswith(("00:12:BF", "00:1A:2A", "00:1D:19")):
                add("Speedport500", minus="-")
            if mc.startswith(("00:1D:19", "00:23:08")):
                add("Speedport500", minus="")
    if _rs(ssid, r"^TECOM-AH4(021|222)-[0-9A-Z]{6}$"):
        add("Tecom")
    if ssid.lower().startswith("teletu"):
        filtered = h
        if len(filtered) != 12 and _rs(ssid, r"^TeleTu_[0-9a-fA-F]{12}$"):
            filtered = ssid[7:]
        if len(filtered) == 12:
            entries = keygens._tele2_table().get(filtered[:6], [])
            value = int(filtered[6:], 16)
            for start, end, serial, base, divider in entries:
                if start <= value <= end and divider:
                    out.append(Candidate("Teletu", filtered,
                                         {"serial": serial, "base": base,
                                          "divider": divider}))
    if _THOMSON_RE.search(ssid):
        add("Thomson")

    # ── generic BssidKeygen rules (ssid family ⇒ window/offset/case) ──────
    def bss(rule_name, length=12, offset=0, upper=True, lower=False,
            cut_left=False):
        add("Bssid", length=length, offset=offset, upper=upper,
            lower=lower, cut_left=cut_left, note=rule_name)

    if (mc.startswith("F8:D1:11") or ssid.startswith("Reliance ") or ssid in ("YOTA", "YOTAZ")
            or _rs(ssid, r"^YotaCPE[0-9A-F]{5}$")
            or _rs(ssid, r"^Aztech110_[0-9A-F]{4}$")
            or _rs(ssid, r"^HEXABYTE_[0-9A-F]{6}$")
            or _rs(ssid, r"^BOLT! SUPER 4G-[0-9A-F]{4}$")
            or _rs(ssid, r"^MBLAZE-AC3633-[0-9A-F]{4}$")
            or _rs(ssid, r"^MBLAZE-AC3633R2-[0-9A-F]{4}$")
            or _rs(ssid, r"^VodafoneNet-[0-9A-F]{4}$")
            or (_rs(ssid, r"^TP-LINK_[0-9A-F]{6}$") and mc.startswith(_TP_LINK_BSSID))):
        bss("len8", 8, 0, True, False)
    if (ssid == "netis" or _rs(ssid, r"^MGTS_GPON_[0-9A-F]{4}$")
            or _rs(ssid, r"^MGTS(-|_)(\d)+$") or _rs(ssid, r"^mgts[0-9]{3}$")
            or _rs(ssid, r"^HAME_([0-9A-Z]{2}|[0-9A-Z]{4})_[0-9a-f]{4}$")
            or _rs(ssid, r"^MBR[0-9]{2,4}-[0-9a-f]{3}$")
            or _rs(ssid, r"^MIFI_[0-9A-Z]{2}_[0-9a-f]{4}$")
            or _rs(ssid, r"^wi-fi[0-9]{4}$")
            or _rs(ssid, r"^true_home2G_[0-9a-f]{3}$")):
        bss("len8-lc", 8, 0, False, True)
    if ssid == "Broadband Express" or _rs(ssid, r"^AER[0-9]{2,4}-[0-9a-f]{3}$"):
        bss("len8-1", 8, -1, True, False)
    if (ssid.startswith("H2OBOLTSpot") or _rs(ssid, r"^CLEARSpot[0-9A-F]{5}$")
            or _rs(ssid, r"^telew_[0-9a-f]{3}$")):
        bss("len8-1-lc", 8, -1, False, True)
    if ssid.startswith("PTCL"):
        bss("len8-1-both", 8, -1, True, True)
    if _rs(ssid, r"^MAXNET-[0-9A-F]{4}$"):
        bss("len8-2-uc", 8, -2, True, False)
    if _rs(ssid, r"^MAXNET-[0-9a-f]{4}$"):
        bss("len8-2-lc", 8, -2, False, True)
    if _rs(ssid, r"^NET_2G[0-9A-F]{6}$") or _rs(ssid, r"^NET_2G_[0-9]{3}$"):
        bss("len8-6", 8, -6, True, False)
        bss("len8-5", 8, -5, True, False)
        bss("len12-6", 12, -6, True, False)
        bss("len12-5", 12, -5, True, False)
    if _rs(ssid, r"^OPTIC[0-9a-fA-F]{4}$"):
        bss("len8-16", 8, -16, True, False)
    if _rs(ssid, r"^TeleRed-[0-9A-F]{4}$") or _rs(ssid, r"^Ubee[0-9A-F]{4}$"):
        bss("len10-4", 10, -4, True, False)
    if (_rs(ssid, r"^PTV[0-9]{4}$") or _rs(ssid, r"^VIVO-[0-9A-F]{4}$")
            or (_rs(ssid, r"^WIFI-[0-9A-F]{4}$") and mc[-5:].replace(":", "") == ssid[-4:])):
        bss("len10", 10, 0, True, False)
    if ssid.startswith("CTM-"):
        bss("len10-lc", 10, 0, False, True)
    if ssid == "AXTEL EXTREMO" or _rs(ssid, r"^VIVO-[0-9A-F]{4}$"):
        bss("len10-1", 10, 1, True, False)
    if _rs(ssid, r"^Comtrend[0-9A-F]{4}$"):
        bss("len10-1m", 10, -1, True, False)
    if ssid == "D-Link" or _rs(ssid, r"^VIVOFIBRA-[0-9A-F]{4}$"):
        bss("len10-2m", 10, -2, False, True)
    if ssid == "D-Link" or _rs(ssid, r"^NetZero-[0-9A-F]{6}$"):
        bss("len10-1m2", 10, -1, False, True)
    if _rs(ssid, r"^ORANGE-[0-9A-F]{4}$"):
        bss("len12-6m", 12, -6, False, True)
    if _rs(ssid, r"^Distributel_[0-9]{5}$"):
        bss("len12-3m", 12, -3, False, True)
        bss("len12-2m", 12, -2, False, True)
    if _rs(ssid, r"^FLOW[0-9]{4}$"):
        bss("len12-2", 12, -2, True, False)
    if _rs(ssid, r"^Access[0-9]{3}$"):
        bss("len12+2", 12, 2, True, False)
    if _rs(ssid, r"^Lukman_Wi_Fi_[0-9]{7}$"):
        bss("len12+1", 12, 1, True, False)
    if _rs(ssid, r"^Upvel_?[0-9a-f]{4}$"):
        bss("len12+1m", 12, 1, False, True)
        bss("len12+2m", 12, 2, False, True)
        bss("len12+3m", 12, 3, False, True)
    if (ssid.startswith(("Nemont", "TURBONET", "300NWLAN", "DJAWEB_"))
            or _rs(ssid, r"^Djaweb[0-9]{8}$")
            or _rs(ssid, r"^MAXCOM[0-9a-zA-Z]{4}$")
            or _rs(ssid, r"^(PTV-|ptv|ptv-)[0-9a-zA-Z]{6}$")):
        bss("len12", 12, 0, True, False)
    if ssid == "MTNL":
        bss("len12+0", 12, 0, True, False)
        bss("len12+1", 12, 1, True, False)
        bss("len12+2", 12, 2, True, False)
    if _rs(ssid, r"^Claro-[0-9A-F]{4}$"):
        bss("len12-both", 12, 0, True, True)
    if _rs(ssid, r"^CIK[0-9]{4}$"):
        bss("len12-1m", 12, -1, False, True)
    if _rs(ssid, r"^Slingshot Home WIFI [0-9]{3}$"):
        bss("len12-1mb", 12, -1, True, True)
    if ssid.startswith("ElectronicBox"):
        bss("len12-2m2", 12, -2, False, True)
    if _rs(ssid, r"^AKADO-[0-9A-F]{4}$"):
        bss("len12-6m2", 12, -6, False, True)
    if _rs(ssid, r"^HOTBOX-[0-9A-F]{4}$") and mc.startswith(_HOTBOX):
        bss("len12-6m3", 12, -6, False, True)
    if _rs(ssid, r"^movistar_[0-9a-f]{6}$"):
        bss("len12-9m", 12, -9, False, True)
    if (_rs(ssid, r"^OTE[0-9a-fA-F]{6}$") or _rs(ssid, r"^conn-x[0-9a-f]{6}$")
            or _rs(ssid, r"^Claro[0-9A-F]{4}$")
            or _rs(ssid, r"^Wind WiFi [0-9a-zA-Z]{6}$")
            or _rs(ssid, r"^Megared[0-9a-f]{4}$")
            or _rs(ssid, r"^CIK1000M_2.4G_[0-9]{4}$")
            or _rs(ssid, r"^CIK1000M_AC2.4G_[0-9]{4}$")
            or _rs(ssid, r"^2KOM_[0-9a-f]{6}$")):
        bss("len12-m", 12, 0, False, True)
    if _rs(ssid, r"^OnLime_[0-9A-F]{4}$"):
        mac_used = h[:10] + ssid[7:9] + ssid[9:]
        bss("len12-onlime", 12, 0, False, True)
        out[-1].mac = mac_used
    if _rs(ssid, r"^ZTE-[0-9a-f]{6}$"):
        bss("zte0", 8, 0, False, True, True)
        bss("zte1", 8, 1, False, True, True)
    if _rs(ssid, r"^LIME[0-9]{4}$"):
        bss("lime0", 10, 0, True, False, True)
        bss("lime1", 12, -2, True, False)
    if (_rs(ssid, r"^Singtel[0-9]{4}-[0-9A-F]{4}$")
            or _rs(ssid, r"^SINGTEL-[0-9A-F]{4}$")
            or _rs(ssid, r"^BoxByTELMA-[0-9A-F]{4}$")):
        add("BaseX", length=10, offset=-1, base=10, nibbles=6,
            upper=False, lower=True)
    if len(ssid) == 5 and mc.startswith(_VERIZON):
        add("Verizon")
    if _rs(ssid, r"^wifimedia(_|-)R-[0-9a-zA-Z]{4}$") and len(h) == 12:
        add("WifimediaR")
    if _rs(ssid, r"^WLAN_[0-9a-zA-Z]{2}$") and mc.startswith(_WLAN2):
        add("Wlan2")
    if _rs(ssid, r"^(WLAN|WiFi|YaCom)[0-9a-zA-Z]{6}$"):
        add("Wlan6")
    if _rs(ssid, r"^(WLAN|JAZZTEL)_[0-9a-fA-F]{4}$") or _rs(ssid, r"^OTE[0-9A-F]{6}$"):
        if mc.startswith(_ZYXEL):
            add("Zyxel")
        if mc.startswith(_COMTREND):
            add("Comtrend")
    if mc.startswith("64:7C:34"):
        pass  # Upc07Ubee is not ported (profanity substitution table)
    elif _rs(ssid, r"^UPC[0-9]{7}$"):
        add("Upc07")
    if _rs(ssid, r"^TPW4G_[0-9A-F]{6}$"):
        add("Tpw4g")
    if ssid.startswith(("PLDTMyDSL", "PLDTHOMEDSL")):
        add("Pldt", variant=0)
    if ssid.startswith(("PLDTFIBR", "PLDTHOMEFIBR")):
        add("Pldt", variant=1)
    if _rs(ssid, r"^Eijsink[0-9]{5}(K5|k5|)$"):
        add("Eijsink")
    if ssid.startswith(("GONTWIFI", "GONT_WIFI")):
        add("Gontwifi")
    return out


def candidate_keys(cand: Candidate, ssid: str, progress=None,
                   cancelled=None) -> list[str]:
    """Expand one candidate into passphrases."""
    kwargs = dict(cand.kwargs)
    # ``note`` is a human label for the Bssid rules, not an algorithm argument.
    kwargs.pop("note", None)
    if cand.name == "Teletu":
        serial = kwargs.pop("serial")
        base = kwargs.pop("base")
        divider = kwargs.pop("divider")
        if len(cand.mac) < 12:
            return []
        serial_int = (int(cand.mac[6:], 16) - base) // divider
        return [serial + "Y" + str(serial_int).rjust(7, "0")]
    if cand.name in ("Thomson", "Upc07"):
        kwargs["progress"] = progress
        kwargs["cancelled"] = cancelled
    return keygens.derive(cand.name, ssid, cand.mac, **kwargs)
