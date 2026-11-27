"""Settings: defaults, the on-disk file, and the list the Settings screen shows."""

import json
import os
from pathlib import Path
import re

PATH = Path(os.environ.get("QUARTERMASTER_CONFIG", str(Path.home() / ".config" / "quartermaster" / "config.json")))
ON_OFF = [(True, "On"), (False, "Off")]
# The countries a Quartermaster Node knows. The country sets the Wi-Fi channels the nodes may use.
COUNTRIES = [("US", "United States"), ("CA", "Canada"), ("GB", "United Kingdom"), ("DE", "Germany"),
             ("FR", "France"), ("AU", "Australia"), ("JP", "Japan"), ("AT", "Austria"), ("BE", "Belgium"),
             ("BR", "Brazil"), ("BG", "Bulgaria"), ("CN", "China"), ("HR", "Croatia"), ("CY", "Cyprus"),
             ("CZ", "Czechia"), ("DK", "Denmark"), ("EE", "Estonia"), ("FI", "Finland"), ("GR", "Greece"),
             ("HK", "Hong Kong"), ("HU", "Hungary"), ("IS", "Iceland"), ("IN", "India"), ("IE", "Ireland"),
             ("IT", "Italy"), ("LV", "Latvia"), ("LI", "Liechtenstein"), ("LT", "Lithuania"), ("LU", "Luxembourg"),
             ("MT", "Malta"), ("MX", "Mexico"), ("NL", "Netherlands"), ("NZ", "New Zealand"), ("NO", "Norway"),
             ("PL", "Poland"), ("PT", "Portugal"), ("RO", "Romania"), ("SK", "Slovakia"), ("SI", "Slovenia"),
             ("KR", "South Korea"), ("ES", "Spain"), ("SE", "Sweden"), ("CH", "Switzerland"), ("TW", "Taiwan"),
             ("01", "Anywhere else")]

# (section, [(key, label, choices, help)]). choices is None for a setting that opens its own screen.
SECTIONS = [
    ("SCANNING", [
        ("wifi_adapters", "Wi-Fi adapters", [("all", "All"), ("external", "USB only"), ("internal", "Built-in only")],
         "Which radios scan. All uses every adapter at once."),
        ("wifi_bands", "Wi-Fi bands kept", [("all", "All"), ("2.4", "2.4 GHz"), ("5", "5 GHz"), ("6", "6 GHz"),
                                            ("5+6", "5 + 6 GHz")], "Networks on other bands are left out."),
        ("wifi_pause", "Pause between sweeps", [(0.0, "None"), (1.0, "1 s"), (3.0, "3 s"), (10.0, "10 s")],
         "None is fastest. A pause saves battery."),
        ("power_guard", "Power guard", ON_OFF,
         "Starts USB radios one by one and eases extra adapters when USB power runs short, so the GPS keeps going."),
        ("hub_power", "USB hub power", [(False, "Auto"), (True, "Hub has power")],
         "Pick Hub has power if your USB hub has its own power supply plugged in, even if it says it does not."),
        ("min_rssi", "Weakest signal kept", [(-100, "Everything"), (-90, "-90 dBm"), (-85, "-85 dBm"),
                                             (-80, "-80 dBm"), (-70, "-70 dBm")],
         "Ignore sightings weaker than this."),
        ("ble", "Bluetooth scan", ON_OFF, "Log Bluetooth LE and classic devices."),
        ("ble_random", "Random BLE addresses", [(True, "Log"), (False, "Skip")],
         "Phones rotate random addresses. Skip keeps logs smaller."),
        ("ble_interval", "Bluetooth check", [(0.5, "0.5 s"), (1.0, "1 s"), (2.0, "2 s"), (5.0, "5 s")],
         "How often Bluetooth results are read."),
        ("adsb", "Aircraft (ADS-B)", [("auto", "Auto"), (True, "On"), (False, "Off")],
         "Logs aircraft with an RTL-SDR stick. Auto listens when one is plugged in. Sent to WDGWars and Wardrift "
         "only."),
        ("lora", "LoRa mesh", [("auto", "Auto"), (True, "On"), (False, "Off")],
         "Logs Meshtastic and MeshCore nodes with a Cap LoRa-1262, for WDGWars and Wardrift. Auto listens when one is "
         "plugged in."),
        ("country", "Country", COUNTRIES, "Where you are. Nodes use the Wi-Fi channels and LoRa the band allowed "
         "here."),
    ]),
    ("DEEP SCAN", [
        ("deep_scan", "Deep scan", [(False, "Off"), (True, "On")],
         "Listens with a spare USB adapter: Flock probes, deauth floods, evil twins, and every network it hears. "
         "6 GHz stays covered."),
        ("deep_scan_plan", "Listen pattern", [("balanced", "Balanced"), ("flock", "Flock first")],
         "Balanced also covers busy 5 GHz channels. Flock first stays on 1, 6 and 11."),
        ("deep_scan_all", "All adapters listen", [("auto", "Auto"), (False, "Off")],
         "With 2 or more USB adapters that can listen, every spare one listens on its own channels. One adapter "
         "per band keeps normal scans."),
        ("deep_scan_adapter", "Monitor adapter", [("auto", "Auto")],
         "Auto picks a spare adapter and never the only 6 GHz one."),
        ("direct_scan", "Direct scans", [(False, "Off"), (True, "On")],
         "USB adapters scan through Quartermaster's radio helper instead of NetworkManager: fresher results."),
        ("radio_tuning", "Radio tuning", [(False, "Off"), (True, "During a wardrive")],
         "Power save off and full legal transmit power on USB adapters, put back after. The country is never "
         "changed."),
    ]),
    ("NODES", [
        ("nodes", "Nodes", None, "ESP32-C5 boards that scan Wi-Fi beside your adapters, on USB or wireless. Add, "
         "name or update them here."),
        ("flash_node", "Flash a node", None, "Put the node firmware on an ESP32-C5 board, or update a node."),
    ]),
    ("LOGGING", [
        ("log_rows", "Rows per device", [("extremes", "Closest + furthest"), ("track", "Full track")],
         "Closest + furthest keeps two rows per device in a log. Full track adds rows as you move."),
        ("rssi_step", "Log when signal changes", [(2, "2 dB"), (4, "4 dB"), (6, "6 dB"), (10, "10 dB")],
         "Full track only. A stronger or weaker sighting by this much adds a row."),
        ("relog_meters", "Log again after moving", [(10, "10 m"), (25, "25 m"), (50, "50 m"), (100, "100 m")],
         "Full track only. Extra rows as you move help WiGLE place the device."),
        ("relog_seconds", "Shortest time between rows", [(5, "5 s"), (10, "10 s"), (30, "30 s"), (60, "60 s")],
         "Full track only. Per device. Lower means bigger logs."),
        ("log_hidden", "Hidden networks", [(True, "Log"), (False, "Skip")], "Networks that do not send a name."),
        ("ignore", "Ignored networks", None, "Names or addresses that are never written to a log."),
    ]),
    ("GPS", [
        ("gps_source", "GPS source", [("auto", "Auto"), ("gpsd", "gpsd"), ("/dev/ttyUSB0", "USB (ttyUSB0)"),
                                      ("/dev/ttyACM0", "USB (ttyACM0)"), ("/dev/ttyS0", "Cap / Grove"),
                                      ("off", "Off")], "Auto finds a USB, Cap LoRa or Grove GPS by itself."),
        ("gps_max_hdop", "GPS accuracy needed", [(0, "Any fix"), (10, "Fair"), (5, "Good"), (2, "Best")],
         "Rows wait until the fix is at least this good."),
        ("gps_power", "Cap and Grove power", [(True, "When needed"), (False, "Leave off")],
         "Switches on 5 V for a GPS on the Cap or the Grove port."),
    ]),
    ("UPLOADS", [
        ("auto_upload", "Send logs", [(True, "Automatic"), (False, "Only when asked")],
         "Automatic sends finished logs whenever the Cardputer is online."),
    ]),
    ("DRIVE ALERTS", [
        ("drive_alerts", "Alerts while wardriving", ON_OFF,
         "Warns you about the devices you pick while you wardrive, from what the scan already hears."),
        ("drive_alert_types", "Alert me about", None, "Which kinds of device alert, and the tone of each."),
        ("drive_alert_tones", "Alert tones", ON_OFF, "Off shows alerts on screen without a sound."),
        ("drive_alert_volume", "Tone volume", [("high", "Loud"), ("medium", "Medium"), ("low", "Quiet")],
         "How loud alert tones play, in wardrive alerts and in Recon."),
        ("alert_place", "Alert position", [("bottom", "Bottom"), ("top", "Top")],
         "Where alert banners show, in wardrive alerts and in Recon. Del hides one, Q is quiet for 10 min."),
        ("drive_alert_min", "Alert from", [("medium", "Medium evidence"), ("high", "Strong only"),
                                           ("low", "Weak hints")],
         "Evidence needed before a wardrive alert. Weaker finds are still saved."),
        ("drive_alert_again", "Alert again (moving devices)", [(900, "After 15 min"), (3600, "After 1 h"),
                                                               (0, "Once per drive")],
         "When a body camera or other moving device may alert again after it has gone. Fixed cameras alert once "
         "per drive."),
        ("drive_alert_floor", "Only when signal is above", [(-100, "Any"), (-85, "-85 dBm"), (-75, "-75 dBm")],
         "Weaker finds are saved but do not alert."),
        ("drive_watch", "My alerts", None, "Wi-Fi names or addresses that always alert, such as veh* for patrol "
         "cars."),
        ("drive_alert_skip", "No alerts for", None, "Devices you silenced from an alert, such as your own glasses. "
         "They are still logged."),
    ]),
    ("RECON", [
        ("recon_display_min", "Show devices from", [("low", "Weak hints"), ("medium", "Medium evidence"),
                                                    ("high", "Strong only")], "Weakest evidence listed in Recon."),
        ("recon_alert_min", "Alert from", [("medium", "Medium evidence"), ("high", "Strong only"),
                                           ("low", "Weak hints")], "Evidence needed before Recon alerts you."),
        ("recon_sound", "Alert sound", ON_OFF, "Beep when Recon raises an alert."),
        ("recon_categories", "Watch list", None, "Kinds of devices Recon looks for."),
    ]),
    ("SCREEN", [
        ("live_list", "Live list shows", [("all", "Wi-Fi + BLE"), ("wifi", "Wi-Fi"), ("ble", "Bluetooth")],
         "What scrolls on the wardrive screen."),
        ("auto_start", "Start wardrive on launch", [(False, "No"), (True, "Yes")],
         "Skip the menu and start scanning."),
        ("splash", "Boot animation", ON_OFF, "Show the ship at launch."),
    ]),
    ("ABOUT", [
        ("check_updates", "Check for updates", None, "Asks the AppStore and GitHub for a newer version. Nothing "
         "is downloaded."),
    ]),
]
SETTINGS = [item for _, items in SECTIONS for item in items]
DEFAULTS = {key: choices[0][0] for key, _, choices, _ in SETTINGS if choices}
DEFAULTS.update(min_rssi=-100, rssi_step=4, relog_meters=25, relog_seconds=30, ble_interval=1.0,
                drive_alert_volume="medium")
LISTS = ("ignore", "recon_categories", "nodes", "drive_alert_types", "drive_alert_mute", "drive_watch",
         "drive_alert_skip")
MAX_IGNORED = 64
MAX_WATCH, WATCH_LENGTH = 8, 32
MAX_SKIP, SKIP_LENGTH = 32, 64
MAX_NODES = 8
MAX_WIRELESS = 8
NODE_NAME_MAX = 16
_MAC = re.compile(r"(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}")
_NODE_ID = re.compile(r"[0-9a-f]{12}")
_LED = re.compile(r"none|(gpio|ws2812),([0-9]|10|2[3-8])(,[01])?")
_KEY = re.compile(r"[0-9a-f]{32}")
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
_IFACE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}")
HELPER_SETTINGS = ("deep_scan", "direct_scan", "radio_tuning")


def is_mac(text):
    return bool(_MAC.fullmatch(str(text).strip()))


def default_lists():
    from .drive_watch import DEFAULT_TYPES
    from .recon import CATEGORIES, OFF_BY_DEFAULT
    return {"ignore": [], "recon_categories": [c for c in CATEGORIES if c not in OFF_BY_DEFAULT], "nodes": [],
            "drive_alert_types": list(DEFAULT_TYPES), "drive_alert_mute": [], "drive_watch": [], "drive_alert_skip": []}


def renamed(kinds, fold=True):
    """A saved list of kinds of device, with the kinds of earlier versions under their SquachWatch names. A kind that
    became part of another turns that one on, unless fold is False."""
    from .drive_watch import FOLDED, RENAMED
    out = set()
    for kind in kinds:
        if not isinstance(kind, str):
            continue
        if kind in FOLDED:
            if fold:
                out.add(FOLDED[kind])
        else:
            out.update(RENAMED.get(kind, (kind,)))
    return out


def default_sounds():
    from .drive_watch import DEFAULT_TONES
    return dict(DEFAULT_TONES)


def cluster_key(value):
    """The key of the hub and its wireless nodes, or None when it is not one."""
    value = value.strip().lower() if isinstance(value, str) else ""
    return value if _KEY.fullmatch(value) and value.strip("0") else None


def node_entries(items):
    """The nodes of a settings file that make sense: {"id", "name", "ble"} and an optional "led", each id once.

    A node on USB may be the hub ("hub": True), only one; a node heard through the hub has "wireless": True. The node
    that was the hub last, and keeps the list of the wireless nodes, has "last_hub": True."""
    nodes, seen, hub, last = [], set(), False, False
    for item in items if isinstance(items, list) else ():
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            continue
        node_id = item["id"].strip().lower()
        if not _NODE_ID.fullmatch(node_id) or node_id in seen:
            continue
        name = item.get("name")
        entry = {"id": node_id, "name": " ".join(name.split())[:NODE_NAME_MAX] if isinstance(name, str) else "",
                 "ble": item.get("ble") is True}
        if isinstance(item.get("led"), str) and _LED.fullmatch(item["led"]):
            entry["led"] = item["led"]
        wireless = item.get("wireless") is True
        if sum(1 for other in nodes if other.get("wireless", False) == wireless) >= \
                (MAX_WIRELESS if wireless else MAX_NODES):
            continue
        if wireless:
            entry["wireless"] = True
        else:
            if item.get("hub") is True and not hub:
                entry["hub"] = hub = True
            if item.get("last_hub") is True and not last:
                entry["last_hub"] = last = True
        nodes.append(entry)
        seen.add(node_id)
    if hub:
        for entry in nodes:
            entry.pop("last_hub", None)
            if entry.get("hub"):
                entry["last_hub"] = True
    return nodes


def load(path=PATH):
    cfg = dict(DEFAULTS, country_set=False, adsb_set=False, drive_alert_sounds=default_sounds())
    cfg.update(default_lists())
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return cfg
    if not isinstance(data, dict):
        return cfg
    for key, _, choices, _ in SETTINGS:
        if choices and key in data and any(data[key] == v and type(data[key]) is type(v) for v, _ in choices):
            cfg[key] = data[key]
    adapter = data.get("deep_scan_adapter")
    if isinstance(adapter, str) and _IFACE.fullmatch(adapter):
        cfg["deep_scan_adapter"] = adapter
    if "alert_place" not in data and cfg["drive_alert_volume"] == "high":
        cfg["drive_alert_volume"] = "medium"
    ignore = data.get("ignore")
    if isinstance(ignore, list):
        cfg["ignore"] = [str(item)[:64] for item in ignore if isinstance(item, str) and item.strip()][:MAX_IGNORED]
    from .drive_watch import TYPES
    from .recon import CATEGORIES
    from .tones import ORDER
    categories = data.get("recon_categories")
    if isinstance(categories, list):
        categories = renamed(categories)
        cfg["recon_categories"] = [c for c in CATEGORIES if c in categories]
    for key in ("drive_alert_types", "drive_alert_mute"):
        if isinstance(data.get(key), list):
            chosen = renamed(data[key], fold=key == "drive_alert_types")
            cfg[key] = [t for t in TYPES if t in chosen]
    watch = data.get("drive_watch")
    if isinstance(watch, list):
        cfg["drive_watch"] = list(dict.fromkeys(item.strip()[:WATCH_LENGTH] for item in watch
                                                if isinstance(item, str) and item.strip()))[:MAX_WATCH]
    skip = data.get("drive_alert_skip")
    if isinstance(skip, list):
        cfg["drive_alert_skip"] = list(dict.fromkeys(item.strip()[:SKIP_LENGTH] for item in skip
                                                     if isinstance(item, str) and item.strip()))[-MAX_SKIP:]
    sounds = data.get("drive_alert_sounds")
    if isinstance(sounds, dict):
        from .drive_watch import RENAMED
        for old, new in RENAMED.items():
            if sounds.get(old) in ORDER:
                for key in new:
                    sounds.setdefault(key, sounds[old])
        cfg["drive_alert_sounds"].update((k, v) for k, v in sounds.items() if k in TYPES and v in ORDER)
    cfg["country_set"] = data.get("country_set") is True and "country" in data
    cfg["adsb_set"] = data.get("adsb_set") is True
    if cfg["adsb"] is False and not cfg["adsb_set"]:
        cfg["adsb"] = "auto"
    cfg["nodes"] = node_entries(data.get("nodes"))
    if isinstance(data.get("wardrift_reporter"), str) and _UUID.fullmatch(data["wardrift_reporter"]):
        cfg["wardrift_reporter"] = data["wardrift_reporter"]
    sequence = data.get("wardrift_sequence")
    if isinstance(sequence, int) and not isinstance(sequence, bool) and 0 <= sequence < 2 ** 53:
        cfg["wardrift_sequence"] = sequence
    if cluster_key(data.get("cluster_key")):
        cfg["cluster_key"] = cluster_key(data["cluster_key"])
    return cfg


def save(cfg, path=PATH):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name("." + path.name)
    keys = list(DEFAULTS) + list(LISTS) + ["drive_alert_sounds", "cluster_key", "country_set", "adsb_set",
                                           "wardrift_reporter", "wardrift_sequence"]
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(json.dumps({k: cfg[k] for k in keys if k in cfg}, indent=1) + "\n")
    os.replace(tmp, path)


def shown(key, value):
    for name, _, choices, _ in SETTINGS:
        if name == key and choices:
            return next((text for v, text in choices if v == value), str(value))
    return str(value)
