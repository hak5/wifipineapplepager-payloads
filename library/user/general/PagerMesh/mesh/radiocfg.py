# PagerMesh - settings of the connected Meshtastic radio (Python standard library only)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The radio sends every settings section during want_config. PagerMesh keeps each
# section exactly as it arrived (raw protobuf) and, for a change, replaces only the
# fields that were edited (meshproto.patch). Everything else on the radio, including
# fields this version does not know, stays as it was.
#
# Secrets (Wi-Fi password, MQTT password, channel keys) are write-only here: the
# console shows "set" / "not set" and never the value.

import meshproto as mp

CFG, MOD = "cfg", "mod"
# Config sections (config.proto Config oneof) and ModuleConfig sections (module_config.proto)
DEVICE, POSITION, POWER, NETWORK, DISPLAY, LORA, BLUETOOTH = 1, 2, 3, 4, 5, 6, 7
MQTT, TELEMETRY = 1, 6
SECTION_NAMES = {(CFG, DEVICE): "Device", (CFG, POSITION): "Position", (CFG, POWER): "Power",
                 (CFG, NETWORK): "Network", (CFG, DISPLAY): "Display", (CFG, LORA): "LoRa",
                 (CFG, BLUETOOTH): "Bluetooth", (MOD, MQTT): "MQTT", (MOD, TELEMETRY): "Telemetry"}

UNITS = {0: "METRIC", 1: "IMPERIAL"}

# key, label, (kind, section), field, type, options
#   type: bool | uint | int | str | enum | secret
#   options: choices (enum), max (str length / number), risky (asks first), min
SETTINGS = [
    ("lora.region", "Region", (CFG, LORA), 7, "enum", {"choices": mp.REGIONS, "risky": True}),
    ("lora.modem_preset", "Modem preset", (CFG, LORA), 2, "enum", {"choices": mp.PRESETS, "risky": True}),
    ("lora.hop_limit", "Hop limit", (CFG, LORA), 8, "uint", {"min": 1, "max": 7}),
    ("lora.tx_power", "TX power (dBm, 0 = default)", (CFG, LORA), 10, "int", {"min": 0, "max": 30}),
    ("lora.tx_enabled", "Transmit enabled", (CFG, LORA), 9, "bool", {"risky": True}),
    ("device.role", "Role", (CFG, DEVICE), 1, "enum", {"choices": mp.ROLES, "pick": mp.ROLE_CHOICES}),
    ("device.node_info_broadcast_secs", "Node info broadcast (s)", (CFG, DEVICE), 7, "uint", {"min": 0, "max": 604800}),
    ("position.position_broadcast_secs", "Radio position broadcast (s)", (CFG, POSITION), 1, "uint", {"min": 0, "max": 604800}),
    ("position.position_broadcast_smart_enabled", "Smart position", (CFG, POSITION), 2, "bool", {}),
    ("position.gps_update_interval", "Radio GPS update (s)", (CFG, POSITION), 5, "uint", {"min": 0, "max": 604800}),
    ("telemetry.device_update_interval", "Device telemetry (s)", (MOD, TELEMETRY), 1, "uint", {"min": 0, "max": 604800}),
    ("telemetry.environment_update_interval", "Environment telemetry (s)", (MOD, TELEMETRY), 2, "uint", {"min": 0, "max": 604800}),
    ("network.wifi_enabled", "Wi-Fi on", (CFG, NETWORK), 1, "bool", {"risky": True}),
    ("network.wifi_ssid", "Wi-Fi network (SSID)", (CFG, NETWORK), 3, "str", {"max": 32, "risky": True}),
    ("network.wifi_psk", "Wi-Fi password", (CFG, NETWORK), 4, "secret", {"max": 63, "risky": True}),
    ("network.ntp_server", "NTP server", (CFG, NETWORK), 5, "str", {"max": 32}),
    ("bluetooth.enabled", "Bluetooth on", (CFG, BLUETOOTH), 1, "bool", {}),
    ("mqtt.enabled", "MQTT on", (MOD, MQTT), 1, "bool", {}),
    ("mqtt.address", "MQTT server", (MOD, MQTT), 2, "str", {"max": 63}),
    ("mqtt.username", "MQTT user", (MOD, MQTT), 3, "str", {"max": 63}),
    ("mqtt.password", "MQTT password", (MOD, MQTT), 4, "secret", {"max": 63}),
    ("mqtt.root", "MQTT root topic", (MOD, MQTT), 8, "str", {"max": 31}),
    ("mqtt.encryption_enabled", "MQTT encryption", (MOD, MQTT), 5, "bool", {}),
    ("mqtt.json_enabled", "MQTT JSON", (MOD, MQTT), 6, "bool", {}),
    ("mqtt.tls_enabled", "MQTT TLS", (MOD, MQTT), 7, "bool", {}),
    ("mqtt.proxy_to_client_enabled", "MQTT through the app", (MOD, MQTT), 9, "bool", {}),
    ("mqtt.map_reporting_enabled", "MQTT map report", (MOD, MQTT), 10, "bool", {}),
    ("display.screen_on_secs", "Screen on (s)", (CFG, DISPLAY), 1, "uint", {"min": 0, "max": 86400}),
    ("display.units", "Units", (CFG, DISPLAY), 6, "enum", {"choices": UNITS}),
    ("display.flip_screen", "Flip screen", (CFG, DISPLAY), 5, "bool", {}),
    ("power.is_power_saving", "Power saving", (CFG, POWER), 1, "bool", {}),
    ("power.on_battery_shutdown_after_secs", "Shut down on battery after (s)", (CFG, POWER), 2, "uint", {"min": 0, "max": 604800}),
]
BY_KEY = {s[0]: s for s in SETTINGS}


def _read(raw, fn, typ):
    wt, v = mp.field_value(raw, fn)
    if typ == "bool":
        return bool(v) if wt == 0 else False
    if typ in ("uint", "enum"):
        return v if wt == 0 else 0
    if typ == "int":
        return mp.sint(v) if wt == 0 else 0
    if typ == "str":
        return mp.text(v) if wt == 2 else ""
    if typ == "secret":
        return bool(wt == 2 and len(v))          # set or not; never the value
    return None


def current(sections):
    """{key: value} for the console. sections: {(kind, section): raw bytes}."""
    out = {}
    for key, _label, sec, fn, typ, _o in SETTINGS:
        if sec in sections:
            out[key] = _read(sections[sec], fn, typ)
    return out


def describe():
    """The settings list for the web console / Pager (no values)."""
    out = []
    for key, label, sec, _fn, typ, o in SETTINGS:
        d = {"key": key, "label": label, "type": typ, "group": SECTION_NAMES[sec],
             "risky": bool(o.get("risky"))}
        if typ == "enum":
            pick = o.get("pick") or sorted(o["choices"])
            d["choices"] = [[k, o["choices"][k]] for k in pick if k in o["choices"]]
        for k in ("min", "max"):
            if k in o:
                d[k] = o[k]
        out.append(d)
    return out


def _value(key, v):
    """Checked value for one setting, or raises ValueError with a readable reason."""
    _k, label, _sec, _fn, typ, o = BY_KEY[key]
    if typ == "bool":
        if isinstance(v, str):
            v = v.strip().lower() in ("1", "true", "yes", "on")
        return bool(v)
    if typ in ("uint", "int", "enum"):
        try:
            v = int(str(v).strip())
        except ValueError:
            raise ValueError("%s: enter a number" % label)
        if typ == "enum" and v not in o["choices"]:
            raise ValueError("%s: not a valid choice" % label)
        if "min" in o and v < o["min"] or "max" in o and v > o["max"]:
            raise ValueError("%s: %d to %d" % (label, o.get("min", 0), o.get("max", 0)))
        return v
    v = str(v)
    if any(ch < " " for ch in v):
        raise ValueError("%s: no control characters" % label)
    if len(v.encode("utf-8")) > o.get("max", 63):
        raise ValueError("%s: at most %d characters" % (label, o.get("max", 63)))
    return v


def _encode(fn, typ, v):
    if typ in ("bool", "uint", "enum", "int"):
        return mp.f_varint(fn, int(v))
    return mp.f_bytes(fn, v)


def build(sections, changes):
    """changes {key: value} -> ([(kind, section, new raw)], [labels changed], risky?)
    Raises ValueError for a bad value or a section the radio did not send."""
    per = {}
    labels, risky = [], False
    for key, v in changes.items():
        if key not in BY_KEY:
            raise ValueError("unknown setting %s" % key)
        _k, label, sec, fn, typ, o = BY_KEY[key]
        if sec not in sections:
            raise ValueError("%s: the radio did not send its %s settings" % (label, SECTION_NAMES[sec]))
        if typ == "secret" and v in (None, ""):
            continue                                # empty secret field = keep the current one
        val = _value(key, v)
        if typ != "secret" and _read(sections[sec], fn, typ) == val:
            continue                                # unchanged
        per.setdefault(sec, {})[fn] = _encode(fn, typ, val)
        if key == "lora.modem_preset":
            per[sec][1] = mp.f_varint(1, 1)         # use_preset = true, or the preset is ignored
        labels.append(label)
        risky = risky or bool(o.get("risky"))
    out = [(sec[0], sec[1], mp.patch(sections[sec], fl)) for sec, fl in per.items()]
    return out, labels, risky


# ---- channels -------------------------------------------------------------

def channel_raw(index, settings_raw, role):
    return mp.f_varint(1, index) + mp.f_bytes(2, settings_raw) + mp.f_varint(3, role)


def build_channel(cur, index, name=None, psk=None, role=None, uplink=None, downlink=None, precision=None, rand=None):
    """New Channel bytes. cur = decoded channel (meshproto.dec_channel) or None for a new one.
    psk: None = keep, "random" = new AES-256 key, "default" = the public default key, "none" = no encryption."""
    if not 0 <= index <= 7:
        raise ValueError("channel index 0 to 7")
    settings = (cur or {}).get("settings_raw", b"")
    role = (cur or {}).get("role", 2) if role is None else int(role)
    if index == 0 and role != 1:
        raise ValueError("channel 0 is always the primary channel")
    if index != 0 and role == 1:
        raise ValueError("only channel 0 can be primary")
    ch = {}
    if name is not None:
        name = str(name).strip()
        if len(name.encode("utf-8")) > 11:
            raise ValueError("channel name: at most 11 characters")
        if any(c < " " for c in name):
            raise ValueError("channel name: no control characters")
        if role == 2 and not name:
            raise ValueError("a secondary channel needs a name")
        ch[3] = mp.f_bytes(3, name)
    if psk == "random":
        ch[2] = mp.f_bytes(2, rand(32))
    elif psk == "default":
        ch[2] = mp.f_bytes(2, b"\x01")
    elif psk == "none":
        ch[2] = mp.f_bytes(2, b"")
    elif psk not in (None, "", "keep"):
        raise ValueError("unknown key choice")
    if uplink is not None:
        ch[5] = mp.f_varint(5, 1 if uplink else 0)
    if downlink is not None:
        ch[6] = mp.f_varint(6, 1 if downlink else 0)
    if precision is not None:
        p = int(precision)
        if not 0 <= p <= 32:
            raise ValueError("position precision 0 to 32")
        _wt, mod = mp.field_value(settings, 7)
        ch[7] = mp.f_bytes(7, mp.patch(mod or b"", {1: mp.f_varint(1, p)}))
    if not settings and 2 not in ch:
        ch[2] = mp.f_bytes(2, rand(32))             # a new channel gets its own key
    return channel_raw(index, mp.patch(settings, ch), role)
