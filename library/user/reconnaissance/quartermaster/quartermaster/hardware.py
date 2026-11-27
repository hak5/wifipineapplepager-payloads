"""Find what is plugged in: Wi-Fi adapters (built-in and USB) and GPS receivers.

Everything here reads sysfs and `iw`, so it works for any adapter Linux has a
driver for. The chip table adds a friendly name, and says why a known adapter
that never started cannot work here; unknown adapters still work and show their
USB product string.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import threading

SYS_NET = Path("/sys/class/net")
SYS_TTY = Path("/sys/class/tty")
BY_ID = Path("/dev/serial/by-id")
USB_TTY = re.compile(r"tty(ACM|USB)\d+")

# The ESP32-C5's own USB port, and the USB-serial bridges of ESP32-C5 boards. A bridge can be a GPS as well.
NODE_NATIVE = "303a:1001"
NODE_BRIDGES = ("10c4:ea60", "1a86:55d4", "1a86:7523", "1a86:55d3")

# Driver name -> chipset family, for the adapter line in the UI.
DRIVER_CHIPSETS = {
    "mt7921u": "MediaTek MT7921AU", "mt7921e": "MediaTek MT7921", "mt7925u": "MediaTek MT7925",
    "mt7925e": "MediaTek MT7925", "mt76x2u": "MediaTek MT7612U", "mt76x0u": "MediaTek MT7610U",
    "mt7601u": "MediaTek MT7601U", "rt2800usb": "Ralink RT2800", "ath9k_htc": "Atheros AR9271",
    "rtl8xxxu": "Realtek RTL8xxxU", "rtl88xxau": "Realtek RTL8812AU", "8812au": "Realtek RTL8812AU",
    "rtl8812au": "Realtek RTL8812AU", "88XXau": "Realtek RTL8812AU", "rtl8814au": "Realtek RTL8814AU",
    "8814au": "Realtek RTL8814AU", "rtw_8812au": "Realtek RTL8812AU", "rtw_8821au": "Realtek RTL8821AU",
    "rtw_8814au": "Realtek RTL8814AU", "rtw_8822bu": "Realtek RTL8822BU", "rtw_8821cu": "Realtek RTL8821CU",
    "rtl8852au": "Realtek RTL8852AU", "rtl8852bu": "Realtek RTL8852BU", "rtw89_8852au": "Realtek RTL8852AU",
    "rtw89_8852bu": "Realtek RTL8852BU", "rtl8832au": "Realtek RTL8832AU", "brcmfmac": "Broadcom (built-in)",
    "carl9170": "Atheros AR9170", "rtl8187": "Realtek RTL8187", "rtl8192cu": "Realtek RTL8192CU",
    "rtw_8822cu": "Realtek RTL8822CU", "rtw_8723du": "Realtek RTL8723DU", "rtw89_8851bu": "Realtek RTL8851BU",
    "rtw89_8852cu": "Realtek RTL8852CU", "rtw89_8922au": "Realtek RTL8922AU",
}

# USB Wi-Fi chips: name, first Linux with a USB driver for it, start of its firmware file name, firmware package.
CHIPS = {
    "mt7601u": ("MT7601U", (4, 2), "mt7601u", "firmware-misc-nonfree"),
    "mt7610u": ("MT7610U", (4, 19), "mediatek/mt7610u", "firmware-misc-nonfree"),
    "mt7612u": ("MT7612U", (4, 19), "mediatek/mt7662u", "firmware-misc-nonfree"),
    "mt7921au": ("MT7921AU", (5, 18), "mediatek/WIFI_RAM_CODE_MT7961", "firmware-mediatek"),
    "mt7925u": ("MT7925U", (6, 7), "mediatek/mt7925/WIFI_RAM_CODE_MT7925", "firmware-mediatek"),
    "rtl8812au": ("RTL8812AU", (6, 13), "rtw88/rtw8812a_fw", "firmware-realtek"),
    "rtl8821au": ("RTL8821AU", (6, 13), "rtw88/rtw8821a_fw", "firmware-realtek"),
    "rtl8814au": ("RTL8814AU", (6, 15), "rtw88/rtw8814a_fw", "firmware-realtek"),
    "rtl8822bu": ("RTL8822BU", (6, 2), "rtw88/rtw8822b_fw", "firmware-realtek"),
    "rtl8822cu": ("RTL8822CU", (6, 2), "rtw88/rtw8822c_fw", "firmware-realtek"),
    "rtl8821cu": ("RTL8821CU", (6, 2), "rtw88/rtw8821c_fw", "firmware-realtek"),
    "rtl8723du": ("RTL8723DU", (6, 2), "rtw88/rtw8723d_fw", "firmware-realtek"),
    "rtl8851bu": ("RTL8851BU", (6, 17), "rtw89/rtw8851b_fw", "firmware-realtek"),
    "rtl8852bu": ("RTL8852BU", (6, 17), "rtw89/rtw8852b_fw", "firmware-realtek"),
    "rtl8852au": ("RTL8852AU", (6, 19), "rtw89/rtw8852a_fw", "firmware-realtek"),
    "rtl8852cu": ("RTL8852CU", (6, 19), "rtw89/rtw8852c_fw", "firmware-realtek"),
    "rtl8922au": ("RTL8922AU", (7, 2), "rtw89/rtw8922a_fw", "firmware-realtek"),
    "rtl8192eu": ("RTL8192EU", (4, 4), "rtlwifi/rtl8192eu", "firmware-realtek"),
    "rtl8188eu": ("RTL8188EU", (6, 0), "rtlwifi/rtl8188eu", "firmware-realtek"),
    "rtl8188fu": ("RTL8188FU", (6, 0), "rtlwifi/rtl8188fu", "firmware-realtek"),
    "rtl8192cu": ("RTL8192CU", (4, 4), "rtlwifi/rtl8192cu", "firmware-realtek"),
    "rtl8192fu": ("RTL8192FU", (6, 6), "rtlwifi/rtl8192fu", "firmware-realtek"),
    "rtl8723bu": ("RTL8723BU", (4, 4), "rtlwifi/rtl8723bu", "firmware-realtek"),
    "rtl8187": ("RTL8187", (4, 4), "", ""),
    "ar9271": ("AR9271", (4, 4), "ath9k_htc/htc_9271", "firmware-atheros"),
    "ar7010": ("AR7010", (4, 4), "ath9k_htc/htc_7010", "firmware-atheros"),
    "ar9170": ("AR9170", (4, 4), "", ""),
    "rt2800": ("RT2800", (4, 4), "rt2870", "firmware-misc-nonfree"),
}

CHIP_IDS = {
    "mt7601u": "148f:7601 148f:760a 148f:760b 148f:760c 148f:760d 0e8d:760a 0e8d:760b 2001:3d04 2717:4106 7392:7710",
    "mt7610u": "148f:7610 0e8d:7610 148f:761a 0e8d:7630 0e8d:7650 13b1:003e 2357:0105 7392:a711 0b05:17d1 0b05:17db",
    "mt7612u": "0e8d:7612 0e8d:7632 0e8d:7662 0b05:1833 0b05:17eb 0b05:180b 045e:02e6 0846:9053 2c4e:0103 057c:8503",
    "mt7921au": "0e8d:7961 3574:6211 0846:9060 0846:9065 35bc:0107",
    "mt7925u": "0e8d:7925 0846:9072",
    "rtl8812au": "0bda:8812 0bda:881a 0bda:881b 0bda:881c 2357:0101 2357:0103 2357:010d 2357:010e 2357:010f "
                 "2357:0122 7392:a822 0846:9051 2604:0012 0b05:17d2",
    "rtl8821au": "0bda:0811 0bda:0820 0bda:0821 0bda:0823 0bda:8822 0bda:a811 0bda:0120 2357:011e 2357:011f "
                 "2357:0120 0846:9052 7392:a811 7392:a812 7392:a813 7392:b611",
    "rtl8814au": "0bda:8813 2357:0106 0846:9054 0b05:1817 0b05:1852 0b05:1853 7392:a833 7392:a834 056e:400b "
                 "056e:400d",
    "rtl8822bu": "0bda:b812 0bda:b82c 0bda:b81a 0bda:2102 2357:012d 2357:0138 2357:0115 0846:9055 13b1:0043 "
                 "7392:b822 0b05:184c 0b05:1841 2001:331e 2001:331c 20f4:808a",
    "rtl8822cu": "0bda:c82c 0bda:c812 0bda:c82e",
    "rtl8821cu": "0bda:c811 0bda:c820 0bda:c821 0bda:b820 0bda:c80c 0bda:8811 0bda:2006 0bda:8731 0bda:c82a "
                 "0bda:c82b 2001:331d 7392:c811 7392:d811",
    "rtl8723du": "0bda:d723 7392:d611",
    "rtl8851bu": "0bda:b831 0bda:b851 2001:332a 3625:010b 7392:e611 2c4e:0128",
    "rtl8852bu": "0bda:b832 0bda:b83a 0bda:b852 0bda:b85a 0b05:1a62 2001:3327 7392:6822 35bc:0100 35bc:0108 "
                 "0db0:6931 3574:6121",
    "rtl8852au": "0bda:8832 0bda:885a 0bda:885c 0b05:1997 2001:3321 2357:013f 2357:0140 2357:0141 0411:0312 "
                 "056e:4020",
    "rtl8852cu": "0bda:c832 0bda:c85a 0bda:c85d 37ad:0103 0db0:991d 28de:2432",
    "rtl8922au": "0bda:8912 0b05:1bcf 0b05:1bd2 0b05:1d84 0411:03ef 2001:332b 7392:3822 7392:4822 7392:5822",
    "rtl8192eu": "0bda:818b 0bda:818c 2357:0107 2357:0108 2357:0109 2001:3319",
    "rtl8188eu": "0bda:8179 0bda:0179 2357:010c 2357:0111",
    "rtl8188fu": "0bda:f179",
    "rtl8192cu": "0bda:8178 0bda:8176 7392:7811",
    "rtl8192fu": "0bda:f192 0bda:318b 0b05:18f1 7392:b722 2357:0135",
    "rtl8723bu": "0bda:b720",
    "rtl8187": "0bda:8187",
    "ar9271": "0cf3:9271 0cf3:1006 0846:9030",
    "ar7010": "0cf3:7010 0846:9018",
    "ar9170": "0cf3:9170",
    "rt2800": "148f:2770 148f:2870 148f:3070 148f:3071 148f:3072 148f:3572 148f:5370 148f:5372 148f:5572",
}
USB_CHIPS = {usb_id: chip for chip, ids in CHIP_IDS.items() for usb_id in ids.split()}

# Models whose id reached Linux later than their chip did.
ID_FIRST = {"37ad:0103": (7, 0)}

# Adapters that first show up as a driver disc and need usb-modeswitch to become Wi-Fi adapters.
DRIVER_DISC = ("0bda:1a2b", "0bda:a192", "0e8d:2870", "148f:2878")

# USB vendor:product -> retail name, for adapters wardrivers actually carry.
USB_ADAPTERS = {
    "0e8d:7961": "MT7921AU tri-band (ALFA AWUS036AXML / AXM)",
    "0e8d:7925": "MT7925 tri-band Wi-Fi 7",
    "3574:6211": "COMFAST CF-952AX (MT7921AU tri-band)",
    "0846:9060": "Netgear A8000 (MT7921AU tri-band)",
    "0846:9065": "Netgear A7500 (MT7921AU tri-band)",
    "35bc:0107": "TP-Link TXE50UH (MT7921AU tri-band)",
    "0e8d:7612": "ALFA AWUS036ACM (MT7612U dual-band)",
    "0e8d:7610": "MT7610U dual-band (ALFA AWUS036ACHM)",
    "0cf3:9271": "AR9271 2.4 GHz (ALFA AWUS036NHA)",
    "148f:3070": "RT3070 2.4 GHz (ALFA AWUS036NH)",
    "148f:5370": "RT5370 2.4 GHz",
    "148f:5572": "RT5572 dual-band (Panda PAU09)",
    "148f:7601": "MT7601U 2.4 GHz",
    "0bda:8812": "RTL8812AU dual-band (ALFA AWUS036ACH)",
    "0bda:8813": "RTL8814AU dual-band (ALFA AWUS1900)",
    "0bda:0811": "RTL8811AU dual-band (ALFA AWUS036ACS)",
    "0bda:0120": "RTL8811AU dual-band",
    "0bda:b812": "RTL8812BU dual-band",
    "0bda:c811": "RTL8811CU dual-band",
    "0bda:8832": "RTL8832AU Wi-Fi 6",
    "0bda:885a": "RTL8852AU Wi-Fi 6",
    "0bda:8187": "RTL8187 2.4 GHz (ALFA AWUS036H)",
}

# USB vendor:product of GPS receivers and the USB-serial bridges they ship on.
USB_GPS = {
    "1546": "u-blox GPS", "2c7c": "Quectel GPS", "067b:2303": "Prolific USB GPS", "067b:23a3": "Prolific USB GPS",
    "1a86:7523": "CH340 USB GPS", "1a86:55d4": "CH9102 USB GPS", "1a86:55d3": "CH343 USB GPS",
    "10c4:ea60": "CP210x USB GPS", "0403:6001": "FTDI USB GPS", "0403:6015": "FTDI USB GPS",
    "1ffb:0092": "LC29H USB GPS",
}

# USB vendor:product of RTL2832U sticks, the usual radio for aircraft.
RTL_SDR = ("0bda:2838", "0bda:2832")


def _read(path):
    try:
        return Path(path).read_text(errors="replace").strip()
    except OSError:
        return ""


def _target(node):
    """The real path of a device node, following a link such as /dev/serial0. None when it is missing."""
    try:
        return node.resolve(strict=True)
    except (OSError, RuntimeError):
        return None


def _usb_parent(device):
    """Walk up from an interface's device node to the USB device that owns it."""
    try:
        node = Path(device).resolve()
    except OSError:
        return None
    while node != node.parent:
        if (node / "idVendor").is_file() and (node / "idProduct").is_file():
            return node
        node = node.parent
    return None


def parse_iw_phy(text):
    """Bands and modes from `iw phy <phy> info`."""
    bands, modes, section = set(), set(), None
    for line in text.splitlines():
        stripped = line.strip()
        if re.match(r"Band \d+:", stripped):
            section = "band"
            continue
        if stripped.startswith("Supported interface modes:"):
            section = "modes"
            continue
        if section == "modes":
            if stripped.startswith("* "):
                modes.add(stripped[2:].strip())
                continue
            section = None
        if section == "band":
            match = re.match(r"\* (\d+)(?:\.\d+)? MHz \[\d+\](.*)", stripped)
            if match and "disabled" not in match.group(2):
                freq = int(match.group(1))
                if freq < 3000:
                    bands.add("2.4")
                elif freq < 5925:
                    bands.add("5")
                elif freq <= 7125:
                    bands.add("6")
    order = [b for b in ("2.4", "5", "6") if b in bands]
    return {"bands": order, "monitor": "monitor" in modes}


def band_label(bands):
    return {1: "single-band", 2: "dual-band", 3: "tri-band"}.get(len(bands), "no bands")


def wifi_adapters(sys_net=SYS_NET, runner=subprocess.run):
    """Every Wi-Fi interface with what the scanner and the UI need to know about it."""
    adapters = []
    try:
        names = sorted(p.name for p in Path(sys_net).iterdir()
                       if (p / "phy80211").exists() or (p / "wireless").exists())
    except OSError:
        names = []
    for name in names:
        base = Path(sys_net) / name
        phy = _read(base / "phy80211" / "name")
        try:
            driver = (base / "device" / "driver").resolve().name
        except OSError:
            driver = ""
        usb = _usb_parent(base / "device")
        usb_id = product = ""
        if usb is not None:
            usb_id = "%s:%s" % (_read(usb / "idVendor").lower(), _read(usb / "idProduct").lower())
            product = " ".join(x for x in (_read(usb / "manufacturer"), _read(usb / "product")) if x)
        info = {"bands": [], "monitor": False}
        if phy and shutil.which("iw"):
            try:
                result = runner(["iw", "phy", phy, "info"], capture_output=True, text=True, errors="replace", timeout=5,
                                check=False)
                if result.returncode == 0:
                    info = parse_iw_phy(result.stdout)
            except (OSError, subprocess.SubprocessError):
                pass
        label = USB_ADAPTERS.get(usb_id) or DRIVER_CHIPSETS.get(driver) or product or driver or "Wi-Fi adapter"
        adapters.append({
            "interface": name, "phy": phy, "driver": driver, "external": usb is not None, "usb_id": usb_id,
            "product": product, "chipset": DRIVER_CHIPSETS.get(driver, ""), "label": label,
            "bands": info["bands"], "band_label": band_label(info["bands"]), "monitor": info["monitor"],
            "mac": _read(base / "address").upper(), "type": _read(base / "type"),
            "autosuspend": _read(usb / "power" / "control") if usb is not None else "",
        })
    # External adapters first: they are why the user plugged them in.
    adapters.sort(key=lambda a: (not a["external"], -len(a["bands"]), a["interface"]))
    return adapters


_ports_lock = threading.Lock()
_held, _marks = {}, {}


def _real(path):
    return os.path.realpath(str(path))


def hold_port(path, owner):
    """Take a serial port for one owner, "gps" or "node". False while the other one has it."""
    real = _real(path)
    with _ports_lock:
        if _held.get(real, owner) != owner:
            return False
        _held[real] = owner
        return True


def let_go_port(path, owner):
    real = _real(path)
    with _ports_lock:
        if _held.get(real) == owner:
            del _held[real]


def port_holder(path):
    return _held.get(_real(path))


def mark_port(path, kind):
    """Note what answered on a port ("gps" or "node", or "checked": the GPS layer heard no GPS there), until it is
    unplugged. None forgets it."""
    real = _real(path)
    with _ports_lock:
        if kind:
            _marks[real] = kind
        else:
            _marks.pop(real, None)


def port_mark(path):
    return _marks.get(_real(path))


def forget_ports(paths):
    """Ports that are gone: whatever is plugged in there next has to show what it is."""
    with _ports_lock:
        for path in paths:
            _marks.pop(_real(path), None)


def usb_serial_names(sys_tty=SYS_TTY):
    try:
        return sorted(name for name in os.listdir(sys_tty) if USB_TTY.fullmatch(name))
    except OSError:
        return []


def usb_id_of(name, sys_tty=SYS_TTY):
    usb = _usb_parent(Path(sys_tty) / name / "device")
    if usb is None:
        return ""
    return "%s:%s" % (_read(usb / "idVendor").lower(), _read(usb / "idProduct").lower())


def by_id_links(by_id=BY_ID):
    """{device path: its stable name in /dev/serial/by-id}."""
    try:
        names = sorted(os.listdir(by_id))
    except OSError:
        return {}
    return {_real(os.path.join(str(by_id), name)): os.path.join(str(by_id), name) for name in names}


def gps_candidates(sys_tty=SYS_TTY, dev=Path("/dev"), extra=(), *, cardputer=True):
    """Serial ports that may carry NMEA, most likely first: USB receivers, then the cap and Grove UART.

    A Quartermaster Node is never one: neither the ESP32-C5's own port nor a bridge a node answered on."""
    found = []
    for name in usb_serial_names(sys_tty):
        usb = _usb_parent(Path(sys_tty) / name / "device")
        usb_id = product = ""
        if usb is not None:
            usb_id = "%s:%s" % (_read(usb / "idVendor").lower(), _read(usb / "idProduct").lower())
            product = " ".join(x for x in (_read(usb / "manufacturer"), _read(usb / "product")) if x)
        path = str(Path(dev) / name)
        if usb_id == NODE_NATIVE or "node" in (port_holder(path), port_mark(path)):
            continue
        known = USB_GPS.get(usb_id) or USB_GPS.get(usb_id.split(":")[0])
        looks_gps = bool(known) or bool(re.search(r"gps|gnss|u-blox|quectel|lc29|nmea", product, re.I))
        found.append({"path": path, "kind": "usb", "usb_id": usb_id,
                      "label": known or product or "USB serial", "likely": looks_gps})
    found.sort(key=lambda item: not item["likely"])
    # The Cardputer's first UART carries its Cap / Grove GPS. On a DIY Pi it may be the console.
    if cardputer:
        bluetooth = _target(Path(dev) / "serial1")
        for name in ("serial0", "ttyS0"):
            port = _target(Path(dev) / name)
            if port is not None and port != bluetooth:
                found.append({"path": str(port), "kind": "uart", "usb_id": "",
                              "label": "Cap / Grove UART", "likely": True})
                break
    for path in extra:
        if path and all(c["path"] != path for c in found):
            found.insert(0, {"path": path, "kind": "custom", "usb_id": "", "label": "Custom port", "likely": True})
    return found


WIFI_PRODUCT = re.compile(r"802\.11|wlan|wi-?fi|wireless (lan|adapter|network)", re.I)
DISC_PRODUCT = re.compile(r"802\.11|wlan|wi-?fi|wireless|driver|\bdisk\b", re.I)

# Why a Wi-Fi adapter on USB has no network interface.
SETUP, NO_DRIVER, TOO_NEW, FIRMWARE, POWER, STALLED = "setup", "no driver", "too new", "firmware", "power", "stalled"

# Kernel log lines that mean the adapter or the port did not get enough power.
POWER_LOG = re.compile(r"failed:-(110|71|108)\b|failed with -110|fail, status: -71|write port txch \d+ failed|"
                       r"descriptor read/\d+, error -(71|110)|not accepting address|over-current|Undervoltage")
NOT_DRIVERS = ("btusb", "usb_storage", "uas")


def _driver_disc(node, usb_id, product):
    if usb_id in DRIVER_DISC:
        return True
    if usb_id.split(":")[0] not in ("0bda", "0e8d", "148f") or not DISC_PRODUCT.search(product):
        return False
    return any(_read(path) == "08" for path in node.glob("*:*/bInterfaceClass"))


def stalled_usb_adapters(sys_usb=Path("/sys/bus/usb/devices")):
    """USB Wi-Fi adapters that are plugged in but have no network interface.

    That is what a driver that failed to start looks like: the adapter is on the bus,
    powered and recognised, yet Linux never created wlanN for it. An adapter still showing
    its driver disc is one too."""
    stalled = []
    try:
        nodes = sorted(Path(sys_usb).iterdir())
    except OSError:
        return stalled
    for node in nodes:
        if not (node / "idVendor").is_file():
            continue
        usb_id = "%s:%s" % (_read(node / "idVendor").lower(), _read(node / "idProduct").lower())
        product = " ".join(x for x in (_read(node / "manufacturer"), _read(node / "product")) if x)
        disc = _driver_disc(node, usb_id, product)
        chip = USB_CHIPS.get(usb_id, "")
        if not (disc or chip or usb_id in USB_ADAPTERS or WIFI_PRODUCT.search(product)):
            continue
        if any(node.glob("*/net/*")) or any(node.glob("*/ieee80211/*")):
            continue
        label = USB_ADAPTERS.get(usb_id) or (CHIPS[chip][0] + " adapter" if chip else "") or product or \
            "USB Wi-Fi adapter"
        stalled.append({"usb_id": usb_id, "label": "Wi-Fi adapter" if disc else label, "port": node.name,
                        "chip": chip, "disc": disc, "plugged": _read(node / "devnum"),
                        "bound": sorted({path.resolve().name for path in node.glob("*:*/driver")
                                         if path.resolve().name.replace("-", "_") not in NOT_DRIVERS})})
    return stalled


def _version(text):
    match = re.match(r"(\d+)\.(\d+)", text or "")
    return (int(match.group(1)), int(match.group(2))) if match else None


_aliases = {}


def usb_driver(usb_id, modules=Path("/lib/modules"), release=None):
    """The Wi-Fi driver this system has for a USB id, "" when it has none, None when that cannot be told."""
    release = release or os.uname().release
    key = (str(modules), release)
    if key not in _aliases:
        table, found = {}, False
        for name in ("modules.alias", "modules.builtin.alias"):
            try:
                text = (Path(modules) / release / name).read_text(errors="replace")
            except OSError:
                continue
            found = True
            for match in re.finditer(r"^alias usb:v([0-9A-F]{4})p([0-9A-F]{4})d\S* (\S+)$", text, re.M):
                if match.group(3).replace("-", "_") not in NOT_DRIVERS:
                    table.setdefault("%s:%s" % (match.group(1).lower(), match.group(2).lower()), match.group(3))
        _aliases[key] = table if found else None
    table = _aliases[key]
    return None if table is None else table.get(usb_id, "")


def has_firmware(prefix, firmware=Path("/lib/firmware")):
    folder, _, start = ("/" + prefix).rpartition("/")
    try:
        return any(name.startswith(start) for name in os.listdir(str(firmware) + folder))
    except OSError:
        return False


def _since_plugged(lines, port, plugged):
    """The log lines since the adapter on this port was plugged in, so an older adapter's trouble is not counted."""
    marks = [re.compile(r"usb %s: new .*device number %s\b" % (re.escape(port), re.escape(plugged)))] if plugged else []
    marks.append(re.compile(r"usb %s: USB disconnect" % re.escape(port)))
    for mark in marks:
        for index in range(len(lines) - 1, -1, -1):
            if mark.search(lines[index]):
                return lines[index + 1:]
    return lines


def power_trouble(port, runner=subprocess.run, hwmon=Path("/sys/class/hwmon"), plugged=""):
    """True when the Pi says its supply is too low or the kernel log shows this port failing for want of power
    since the adapter was plugged in. None when neither can be read, so nothing is guessed."""
    try:
        sensors = list(Path(hwmon).iterdir())
    except OSError:
        sensors = []
    for sensor in sensors:
        if _read(sensor / "in0_lcrit_alarm") == "1":
            return True
    own = re.compile(r"(?<![\w.-])%s[:\s]" % re.escape(port))
    for command in (["dmesg"], ["journalctl", "-k", "-b", "-q", "--no-pager", "-o", "cat", "-n", "500"]):
        try:
            result = runner(command, capture_output=True, text=True, errors="replace", timeout=5, check=False)
        except (OSError, subprocess.SubprocessError):
            continue
        if result.returncode != 0 or not result.stdout.strip():
            continue
        lines = _since_plugged(result.stdout.splitlines(), port, plugged)
        return any(POWER_LOG.search(line) and (own.search(line) or "over-current" in line or "Undervoltage" in line)
                   for line in lines)
    return None


def package_installed(package, dpkg_info=Path("/var/lib/dpkg/info")):
    return any((Path(dpkg_info) / (package + suffix)).is_file() for suffix in (".list", ":arm64.list"))


def explain(item, modules=Path("/lib/modules"), firmware=Path("/lib/firmware"), release=None,
            runner=subprocess.run, hwmon=Path("/sys/class/hwmon"), dpkg_info=Path("/var/lib/dpkg/info")):
    """Why a stalled adapter has no interface: the item with "why" set, and "needs" or "package" when they help.
    "package" is only set when that package is not installed yet."""
    item = dict(item, needs="", package="")
    chip = CHIPS.get(item.get("chip", ""))
    if item.get("disc"):
        return dict(item, why=SETUP)
    release = release or os.uname().release
    driver = usb_driver(item["usb_id"], modules, release)
    running = _version(release)
    first = ID_FIRST.get(item["usb_id"]) or (chip[1] if chip is not None else None)
    too_old = first is not None and running is not None and running < first
    if not item.get("bound") and (driver == "" or driver is None and too_old):
        if too_old or chip is None:
            return dict(item, why=NO_DRIVER, needs="%d.%d" % first if too_old else "")
        return dict(item, why=TOO_NEW)
    if chip is not None and chip[2] and not has_firmware(chip[2], firmware):
        return dict(item, why=FIRMWARE, package="" if package_installed(chip[3], dpkg_info) else chip[3])
    if power_trouble(item["port"], runner, hwmon, item.get("plugged", "")):
        return dict(item, why=POWER)
    return dict(item, why=STALLED)


def stall_words(item):
    """What the Hardware screen says about an adapter with no interface."""
    why = item.get("why", STALLED)
    if why == SETUP:
        return "Wi-Fi adapter in setup mode", "It shows as a driver disc. Replug it."
    if why == NO_DRIVER and item.get("needs"):
        return item["label"], "No driver for it here. It needs Linux %s." % item["needs"]
    if why == NO_DRIVER:
        return item["label"], "This system has no driver for it."
    if why == TOO_NEW:
        return item["label"], "This model is too new for the driver here."
    if why == FIRMWARE and item.get("package"):
        return item["label"], "Firmware missing. Install %s." % item["package"]
    if why == FIRMWARE:
        return item["label"], "Firmware missing. This system needs newer firmware."
    if why == POWER:
        return item["label"], "Needs more power. Use a powered hub."
    return item["label"], "On USB but not starting. Replug it or use a powered hub."


def rtl_sdr_dongles(sys_usb=Path("/sys/bus/usb/devices")):
    """RTL2832U sticks on USB, the radio aircraft are heard with."""
    found = []
    try:
        nodes = sorted(Path(sys_usb).iterdir())
    except OSError:
        return found
    for node in nodes:
        if not (node / "idVendor").is_file():
            continue
        usb_id = "%s:%s" % (_read(node / "idVendor").lower(), _read(node / "idProduct").lower())
        if usb_id in RTL_SDR:
            product = " ".join(x for x in (_read(node / "manufacturer"), _read(node / "product")) if x)
            found.append({"usb_id": usb_id, "label": product or "RTL-SDR", "port": node.name})
    return found


def local_addresses(runner=subprocess.run):
    """IPv4 addresses other devices on the network can reach, Wi-Fi first."""
    found = []
    try:
        result = runner(["ip", "-4", "-o", "addr", "show", "scope", "global"], capture_output=True, text=True,
                        timeout=5, check=False)
        for line in result.stdout.splitlines() if result.returncode == 0 else ():
            match = re.match(r"\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/", line)
            if match and not match.group(1).startswith(("docker", "veth", "br-", "tun", "tailscale")):
                found.append((match.group(1), match.group(2)))
    except (OSError, subprocess.SubprocessError):
        pass
    if not found:
        import socket
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                probe.connect(("192.0.2.1", 9))
                found.append(("", probe.getsockname()[0]))
        except OSError:
            pass
    found.sort(key=lambda item: not item[0].startswith("wl"))
    return [address for _, address in found if not address.startswith("127.")]


def bluetooth_adapters(sys_bt=Path("/sys/class/bluetooth")):
    try:
        names = sorted(p.name for p in Path(sys_bt).iterdir() if re.fullmatch(r"hci\d+", p.name))
    except OSError:
        return []
    out = []
    for name in names:
        usb = _usb_parent(Path(sys_bt) / name / "device")
        out.append({"name": name, "external": usb is not None,
                    "label": (" ".join(x for x in (_read(usb / "manufacturer"), _read(usb / "product")) if x)
                              if usb is not None else "Built-in Bluetooth")})
    return out


def os_release():
    for line in _read("/etc/os-release").splitlines():
        if line.startswith("VERSION_ID="):
            return line.split("=", 1)[1].strip('"')
    return os.uname().release
