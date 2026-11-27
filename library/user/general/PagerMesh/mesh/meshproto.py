# PagerMesh - Meshtastic TCP API protocol helpers (Python standard library only)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stream framing (TCP API, same as the phone app uses): 0x94 0xC3, 2-byte
# big-endian length, then a protobuf ToRadio (to meshtasticd) or FromRadio
# (from meshtasticd). Field numbers follow meshtastic/protobufs (mesh.proto,
# portnums.proto, telemetry.proto, config.proto, channel.proto).

import os
import random
import select
import socket
import struct
import subprocess

MAGIC = b"\x94\xc3"
MAX_FRAME = 512
BROADCAST = 0xFFFFFFFF
MAX_TEXT_BYTES = 200            # Meshtastic data payload is ~233 bytes; leave room

# portnums.proto
PORT_TEXT = 1
PORT_POSITION = 3
PORT_NODEINFO = 4
PORT_ROUTING = 5
PORT_TELEMETRY = 67
PORT_ADMIN = 6
PORT_WAYPOINT = 8
PORT_TRACEROUTE = 70
PORT_NAMES = {0: "UNKNOWN", 1: "TEXT", 2: "REMOTE_HW", 3: "POSITION", 4: "NODEINFO", 5: "ROUTING", 6: "ADMIN",
              7: "TEXT_COMPRESSED", 8: "WAYPOINT", 10: "DETECTION", 32: "REPLY", 33: "IP_TUNNEL",
              34: "PAXCOUNTER", 64: "SERIAL", 65: "STORE_FORWARD", 66: "RANGE_TEST", 67: "TELEMETRY",
              68: "ZPS", 70: "TRACEROUTE", 71: "NEIGHBORINFO", 72: "ATAK_PLUGIN", 73: "MAP_REPORT"}

# config.proto LoRaConfig.RegionCode (names only for the status screen)
REGIONS = {0: "UNSET", 1: "US", 2: "EU_433", 3: "EU_868", 4: "CN", 5: "JP", 6: "ANZ", 7: "KR",
           8: "TW", 9: "RU", 10: "IN", 11: "NZ_865", 12: "TH", 13: "LORA_24", 14: "UA_433",
           15: "UA_868", 16: "MY_433", 17: "MY_919", 18: "SG_923", 19: "PH_433", 20: "PH_868",
           21: "PH_915", 22: "ANZ_433", 23: "KZ_433", 24: "KZ_863", 25: "NP_865", 26: "BR_902",
           27: "ITU1_2M", 28: "ITU2_2M", 29: "EU_866", 30: "EU_874", 31: "EU_917", 32: "EU_N_868",
           33: "ITU3_2M", 34: "ITU1_70CM"}

# config.proto LoRaConfig.ModemPreset
PRESETS = {0: "LONG_FAST", 1: "LONG_SLOW", 2: "VERY_LONG_SLOW", 3: "MEDIUM_SLOW", 4: "MEDIUM_FAST",
           5: "SHORT_SLOW", 6: "SHORT_FAST", 7: "LONG_MODERATE", 8: "SHORT_TURBO", 9: "LONG_TURBO",
           10: "LITE_FAST", 11: "LITE_SLOW", 12: "NARROW_FAST", 13: "NARROW_SLOW", 14: "TINY_FAST",
           15: "TINY_SLOW", 16: "MEDIUM_TURBO"}
# presets a normal US/EU radio offers (the phone app list); the scan uses these
COMMON_PRESETS = [0, 7, 1, 3, 4, 5, 6, 8]

# config.proto DeviceConfig.Role (deprecated 3 and 4 left out of pickers)
ROLES = {0: "CLIENT", 1: "CLIENT_MUTE", 2: "ROUTER", 3: "ROUTER_CLIENT", 4: "REPEATER", 5: "TRACKER",
         6: "SENSOR", 7: "TAK", 8: "CLIENT_HIDDEN", 9: "LOST_AND_FOUND", 10: "TAK_TRACKER",
         11: "ROUTER_LATE", 12: "CLIENT_BASE"}
ROLE_CHOICES = [0, 1, 12, 2, 11, 5, 6, 7, 10, 8, 9]

# channel.proto Channel.Role
CHAN_ROLES = {0: "DISABLED", 1: "PRIMARY", 2: "SECONDARY"}

# mesh.proto HardwareModel (names for the node details)
HW_MODELS = dict(enumerate((
    "UNSET TLORA_V2 TLORA_V1 TLORA_V2_1_1P6 TBEAM HELTEC_V2_0 TBEAM_V0P7 T_ECHO TLORA_V1_1P3 RAK4631 "
    "HELTEC_V2_1 HELTEC_V1 LILYGO_TBEAM_S3_CORE RAK11200 NANO_G1 TLORA_V2_1_1P8 TLORA_T3_S3 NANO_G1_EXPLORER "
    "NANO_G2_ULTRA LORA_TYPE WIPHONE WIO_WM1110 RAK2560 HELTEC_HRU_3601 HELTEC_WIRELESS_BRIDGE STATION_G1 "
    "RAK11310 MAKERFABS_TRACKER MAKERFABS_RESERVED CANARYONE RP2040_LORA STATION_G2 LORA_RELAY_V1 T_ECHO_PLUS "
    "PPR GENIEBLOCKS NRF52_UNKNOWN PORTDUINO ANDROID_SIM DIY_V1 NRF52840_PCA10059 DR_DEV M5STACK HELTEC_V3 "
    "HELTEC_WSL_V3 BETAFPV_2400_TX BETAFPV_900_NANO_TX RPI_PICO HELTEC_WIRELESS_TRACKER HELTEC_WIRELESS_PAPER "
    "T_DECK T_WATCH_S3 PICOMPUTER_S3 HELTEC_HT62 EBYTE_ESP32_S3 ESP32_S3_PICO CHATTER_2 "
    "HELTEC_WIRELESS_PAPER_V1_0 HELTEC_WIRELESS_TRACKER_V1_0 UNPHONE TD_LORAC CDEBYTE_EORA_S3 TWC_MESH_V4 "
    "NRF52_PROMICRO_DIY RADIOMASTER_900_BANDIT_NANO HELTEC_CAPSULE_SENSOR_V3 HELTEC_VISION_MASTER_T190 "
    "HELTEC_VISION_MASTER_E213 HELTEC_VISION_MASTER_E290 HELTEC_MESH_NODE_T114 SENSECAP_INDICATOR "
    "TRACKER_T1000_E RAK3172 WIO_E5 RADIOMASTER_900_BANDIT ME25LS01_4Y10TD RP2040_FEATHER_RFM95 "
    "M5STACK_COREBASIC M5STACK_CORE2 RPI_PICO2 M5STACK_CORES3 SEEED_XIAO_S3 MS24SF1 TLORA_C6 WISMESH_TAP "
    "ROUTASTIC MESH_TAB MESHLINK XIAO_NRF52_KIT THINKNODE_M1 THINKNODE_M2 T_ETH_ELITE HELTEC_SENSOR_HUB "
    "MUZI_BASE HELTEC_MESH_POCKET SEEED_SOLAR_NODE NOMADSTAR_METEOR_PRO CROWPANEL LINK_32 SEEED_WIO_TRACKER_L1 "
    "SEEED_WIO_TRACKER_L1_EINK MUZI_R1_NEO T_DECK_PRO T_LORA_PAGER M5STACK_RESERVED WISMESH_TAG RAK3312 "
    "THINKNODE_M5 HELTEC_MESH_SOLAR T_ECHO_LITE HELTEC_V4 M5STACK_C6L M5STACK_CARDPUTER_ADV "
    "HELTEC_WIRELESS_TRACKER_V2 T_WATCH_ULTRA THINKNODE_M3 WISMESH_TAP_V2 RAK3401 RAK6421 THINKNODE_M4 "
    "THINKNODE_M6 MESHSTICK_1262 TBEAM_1_WATT T5_S3_EPAPER_PRO TBEAM_BPF MINI_EPAPER_S3 TDISPLAY_S3_PRO "
    "HELTEC_MESH_NODE_T096 MESH_TRACKER_X1 THINKNODE_M7 THINKNODE_M8 THINKNODE_M9 HELTEC_V4_R8 "
    "HELTEC_MESH_NODE_T1 STATION_G3").split()))
HW_MODELS[255] = "PRIVATE_HW"


def hw_name(v):
    return HW_MODELS.get(v, "HW_%s" % v) if v is not None else ""

# --------------------------------------------------------------------------
# tiny protobuf reader / writer (only what PagerMesh needs)
# --------------------------------------------------------------------------

def _varint(buf, i):
    shift = val = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated varint")
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def fields(buf):
    """Yield (field_number, wire_type, value) for each field of a message."""
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(buf, i)
        elif wt == 1:
            v = buf[i:i + 8]
            i += 8
        elif wt == 2:
            n, i = _varint(buf, i)
            v = buf[i:i + n]
            i += n
        elif wt == 5:
            v = buf[i:i + 4]
            i += 4
        else:
            raise ValueError("unsupported wire type %d" % wt)
        if i > len(buf):
            raise ValueError("truncated field")
        yield fn, wt, v


def raw_fields(buf):
    """Yield (field_number, wire_type, value, raw_bytes) - raw_bytes includes the tag, so a
    message can be rebuilt with unknown fields kept exactly as the radio sent them."""
    i = 0
    while i < len(buf):
        start = i
        key, i = _varint(buf, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(buf, i)
        elif wt == 1:
            v, i = buf[i:i + 8], i + 8
        elif wt == 2:
            n, i = _varint(buf, i)
            v, i = buf[i:i + n], i + n
        elif wt == 5:
            v, i = buf[i:i + 4], i + 4
        else:
            raise ValueError("unsupported wire type %d" % wt)
        if i > len(buf):
            raise ValueError("truncated field")
        yield fn, wt, v, bytes(buf[start:i])


def patch(buf, changes):
    """Copy of a protobuf message with some fields replaced.
    changes: {field_number: encoded field bytes, or b"" to drop it}. Other fields stay as they were."""
    out, done = bytearray(), set()
    for fn, _wt, _v, raw in raw_fields(buf or b""):
        if fn in changes:
            if fn not in done:
                out += changes[fn]
                done.add(fn)
        else:
            out += raw
    for fn in sorted(changes):
        if fn not in done:
            out += changes[fn]
    return bytes(out)


def field_value(buf, fn):
    """(wire_type, value) of the first field fn, or (None, None)."""
    for f, wt, v in fields(buf or b""):
        if f == fn:
            return wt, v
    return None, None


def ev(v):
    """Encode a varint (negative int32/int64 use 10-byte two's complement)."""
    if v < 0:
        v += 1 << 64
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def f_varint(fn, v):
    return ev(fn << 3) + ev(v)


def f_bytes(fn, b):
    if isinstance(b, str):
        b = b.encode("utf-8")
    return ev((fn << 3) | 2) + ev(len(b)) + b


def f_fixed32(fn, v):
    return ev((fn << 3) | 5) + struct.pack("<I", v & 0xFFFFFFFF)


def f_sfixed32(fn, v):
    return ev((fn << 3) | 5) + struct.pack("<i", v)


def f_float(fn, v):
    return ev((fn << 3) | 5) + struct.pack("<f", float(v))


def u32(b):
    return struct.unpack("<I", b)[0]


def s32(b):
    return struct.unpack("<i", b)[0]


def f32(b):
    return struct.unpack("<f", b)[0]


def text(b):
    return b.decode("utf-8", "replace")


def sint(v):
    """int32 sent as a plain varint (negative values arrive as 64-bit)."""
    return v - (1 << 64) if v >= (1 << 63) else v


def node_id(num):
    return "!%08x" % (num or 0)

# --------------------------------------------------------------------------
# decoders
# --------------------------------------------------------------------------

def dec_user(buf):
    u = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 2:
            u["id"] = text(v)
        elif fn == 2 and wt == 2:
            u["long_name"] = text(v)
        elif fn == 3 and wt == 2:
            u["short_name"] = text(v)
        elif fn == 5 and wt == 0:
            u["hw_model"] = v
        elif fn == 7 and wt == 0:
            u["role"] = v
    return u


def dec_position(buf):
    p = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 5:
            p["lat"] = s32(v) / 1e7
        elif fn == 2 and wt == 5:
            p["lon"] = s32(v) / 1e7
        elif fn == 3 and wt == 0:
            p["alt"] = sint(v)
        elif fn == 4 and wt == 5:
            p["time"] = u32(v)
    if p.get("lat") == 0 and p.get("lon") == 0:
        p.pop("lat", None)
        p.pop("lon", None)
    return p


def dec_metrics(buf):
    m = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            m["battery"] = v                 # 101 = on external power
        elif fn == 2 and wt == 5:
            m["voltage"] = round(f32(v), 2)
        elif fn == 3 and wt == 5:
            m["ch_util"] = round(f32(v), 1)
        elif fn == 4 and wt == 5:
            m["air_tx"] = round(f32(v), 1)
    return m


def dec_telemetry(buf):
    for fn, wt, v in fields(buf):
        if fn == 2 and wt == 2:              # Telemetry.device_metrics
            return dec_metrics(v)
    return {}


def dec_nodeinfo(buf):
    n = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            n["num"] = v
        elif fn == 2 and wt == 2:
            n["user"] = dec_user(v)
            n["user_raw"] = bytes(v)
        elif fn == 3 and wt == 2:
            n["position"] = dec_position(v)
        elif fn == 4 and wt == 5:
            n["snr"] = round(f32(v), 2)
        elif fn == 5 and wt == 5:
            n["last_heard"] = u32(v)
        elif fn == 8 and wt == 0:
            n["via_mqtt"] = bool(v)
        elif fn == 10 and wt == 0:
            n["favorite"] = bool(v)
        elif fn == 6 and wt == 2:
            n["metrics"] = dec_metrics(v)
        elif fn == 9 and wt == 0:
            n["hops_away"] = v
    return n


def dec_data(buf):
    d = {"portnum": 0, "payload": b""}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            d["portnum"] = v
        elif fn == 2 and wt == 2:
            d["payload"] = bytes(v)
        elif fn == 3 and wt == 0:
            d["want_response"] = bool(v)
        elif fn == 6 and wt == 5:
            d["request_id"] = u32(v)
        elif fn == 7 and wt == 5:
            d["reply_id"] = u32(v)
        elif fn == 8 and wt == 5:
            d["emoji"] = u32(v)
    return d


def dec_packet(buf):
    p = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 5:
            p["from"] = u32(v)
        elif fn == 2 and wt == 5:
            p["to"] = u32(v)
        elif fn == 3 and wt == 0:
            p["channel"] = v
        elif fn == 4 and wt == 2:
            p["decoded"] = dec_data(v)
        elif fn == 5 and wt == 2:
            p["encrypted"] = len(v)          # a channel key we don't have
        elif fn == 6 and wt == 5:
            p["id"] = u32(v)
        elif fn == 7 and wt == 5:
            p["rx_time"] = u32(v)
        elif fn == 8 and wt == 5:
            p["rx_snr"] = round(f32(v), 2)
        elif fn == 9 and wt == 0:
            p["hop_limit"] = v
        elif fn == 12 and wt == 0:
            p["rx_rssi"] = sint(v)
        elif fn == 14 and wt == 0:
            p["via_mqtt"] = bool(v)
        elif fn == 15 and wt == 0:
            p["hop_start"] = v
        elif fn == 17 and wt == 0:
            p["pki"] = bool(v)
    return p


def dec_routing_error(buf):
    """Routing.error_reason (0 = NONE = delivered), or None when not an ack."""
    for fn, wt, v in fields(buf):
        if fn == 3 and wt == 0:
            return v
    return 0


def dec_channel(buf):
    """Channel without its key: psk_kind says what kind of key it has."""
    c = {"index": 0, "name": "", "role": 0, "psk_kind": "none", "uplink": False, "downlink": False,
         "precision": 0, "raw": bytes(buf)}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            c["index"] = v
        elif fn == 2 and wt == 2:            # ChannelSettings (the key is never kept)
            c["settings_raw"] = bytes(v)
            for f2, w2, v2 in fields(v):
                if f2 == 3 and w2 == 2:
                    c["name"] = text(v2)
                elif f2 == 2 and w2 == 2:
                    c["psk_kind"] = psk_kind(v2)
                elif f2 == 5 and w2 == 0:
                    c["uplink"] = bool(v2)
                elif f2 == 6 and w2 == 0:
                    c["downlink"] = bool(v2)
                elif f2 == 7 and w2 == 2:
                    for f3, w3, v3 in fields(v2):
                        if f3 == 1 and w3 == 0:
                            c["precision"] = v3
        elif fn == 3 and wt == 0:
            c["role"] = v                    # 0 disabled, 1 primary, 2 secondary
    return c


def psk_kind(k):
    if not k:
        return "none"
    if len(k) == 1:
        return "default" if k[0] == 1 else "simple"
    return "AES-%d" % (len(k) * 8)


def dec_config(buf):
    """Only LoRa region and hop limit are kept."""
    out = {}
    for fn, wt, v in fields(buf):
        if fn == 6 and wt == 2:              # Config.lora
            for f2, w2, v2 in fields(v):
                if f2 == 7 and w2 == 0:
                    out["region"] = v2
                elif f2 == 8 and w2 == 0:
                    out["hop_limit"] = v2
                elif f2 == 9 and w2 == 0:
                    out["tx_enabled"] = bool(v2)
    return out


def dec_metadata(buf):
    m = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 2:
            m["firmware"] = text(v)
        elif fn == 4 and wt == 0:
            m["has_wifi"] = bool(v)
        elif fn == 5 and wt == 0:
            m["has_bt"] = bool(v)
        elif fn == 9 and wt == 0:
            m["hw_model"] = v
    return m


def dec_route(buf):
    """RouteDiscovery: node numbers out and back, SNR (dB) per hop."""
    r = {"route": [], "snr_towards": [], "route_back": [], "snr_back": []}
    for fn, wt, v in fields(buf):
        key = {1: "route", 2: "snr_towards", 3: "route_back", 4: "snr_back"}.get(fn)
        if not key:
            continue
        if fn in (1, 3):
            if wt == 5:
                r[key].append(u32(v))
            elif wt == 2:
                r[key] += [u32(v[i:i + 4]) for i in range(0, len(v) - 3, 4)]
        else:
            vals = []
            if wt == 0:
                vals = [v]
            elif wt == 2:
                i = 0
                while i < len(v):
                    x, i = _varint(v, i)
                    vals.append(x)
            r[key] += [sint(x) / 4.0 for x in vals]
    return r


def dec_waypoint(buf):
    w = {"id": 0, "name": "", "description": "", "expire": 0, "icon": 0, "locked_to": 0}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            w["id"] = v
        elif fn == 2 and wt == 5:
            w["lat"] = s32(v) / 1e7
        elif fn == 3 and wt == 5:
            w["lon"] = s32(v) / 1e7
        elif fn == 4 and wt == 0:
            w["expire"] = v
        elif fn == 5 and wt == 0:
            w["locked_to"] = v
        elif fn == 6 and wt == 2:
            w["name"] = text(v)
        elif fn == 7 and wt == 2:
            w["description"] = text(v)
        elif fn == 8 and wt == 5:
            w["icon"] = u32(v)
    return w


def dec_fromradio(buf):
    """Returns (kind, value) for the parts PagerMesh uses, else (None, None)."""
    for fn, wt, v in fields(buf):
        if fn == 2 and wt == 2:
            p = dec_packet(v)
            p["_raw"] = bytes(v)
            return "packet", p
        if fn == 3 and wt == 2:
            for f2, w2, v2 in fields(v):
                if f2 == 1 and w2 == 0:
                    return "my_info", v2
            return None, None
        if fn == 4 and wt == 2:
            return "node_info", dec_nodeinfo(v)
        if fn == 5 and wt == 2:
            c = dec_config(v)
            for f2, w2, v2 in fields(v):     # Config has one section set: keep it as the radio sent it
                if w2 == 2:
                    c["_section"], c["_raw"] = f2, bytes(v2)
            return "config", c
        if fn == 9 and wt == 2:              # ModuleConfig: one module section
            for f2, w2, v2 in fields(v):
                if w2 == 2:
                    return "module_config", (f2, bytes(v2))
            return None, None
        if fn == 13 and wt == 2:
            return "metadata", dec_metadata(v)
        if fn == 7 and wt == 0:
            return "config_complete", v
        if fn == 8 and wt == 0:
            return "rebooted", v
        if fn == 10 and wt == 2:
            return "channel", dec_channel(v)
    return None, None

# --------------------------------------------------------------------------
# encoders (ToRadio)
# --------------------------------------------------------------------------

def new_packet_id():
    return random.randint(1, 0xFFFFFFFF)


def want_config(nonce):
    return f_varint(3, nonce)


def heartbeat():
    return f_bytes(7, b"")


def disconnect():
    return f_varint(4, 1)


def _packet(to, channel, portnum, payload, pid, hop_limit, want_ack, want_response=False):
    data = f_varint(1, portnum) + f_bytes(2, payload)
    if want_response:
        data += f_varint(3, 1)
    mp = f_fixed32(2, to) + f_bytes(4, data) + f_fixed32(6, pid)
    if channel:
        mp = f_varint(3, channel) + mp
    if hop_limit:
        mp += f_varint(9, hop_limit)
    if want_ack:
        mp += f_varint(10, 1)
    return f_bytes(1, mp)                    # ToRadio.packet


def clip_text(msg):
    b = msg.encode("utf-8")[:MAX_TEXT_BYTES]
    return b.decode("utf-8", "ignore")


def text_packet(msg, to=BROADCAST, channel=0, hop_limit=0, pid=None):
    """Chat message. Direct messages ask for an ack, like the phone app."""
    return _packet(to, channel, PORT_TEXT, clip_text(msg).encode("utf-8"), pid or new_packet_id(),
                   hop_limit, to != BROADCAST)


def position_packet(lat, lon, alt=None, t=None, channel=0, hop_limit=0, pid=None, source=3):
    """Our position as a POSITION_APP broadcast. source: LOC_EXTERNAL (3) = Pager GPS,
    LOC_MANUAL (1) = set on the map."""
    pos = f_sfixed32(1, int(round(lat * 1e7))) + f_sfixed32(2, int(round(lon * 1e7)))
    if alt is not None:
        pos += f_varint(3, int(round(alt)))
    if t:
        pos += f_fixed32(4, int(t))
    pos += f_varint(5, source)
    return _packet(BROADCAST, channel, PORT_POSITION, pos, pid or new_packet_id(), hop_limit, False)

# --------------------------------------------------------------------------
# admin (settings of the connected radio), traceroute, position request, waypoints
# A local app (TCP / USB / BLE) sends AdminMessage to its own node with from = 0:
# the firmware trusts it and needs no session passkey.
# --------------------------------------------------------------------------

def admin_packet(my_num, admin, pid=None):
    return _packet(my_num, 0, PORT_ADMIN, admin, pid or new_packet_id(), 0, False, True)


def adm_set_owner(long_name, short_name):
    u = b""
    if long_name:
        u += f_bytes(2, long_name)
    if short_name:
        u += f_bytes(3, short_name)
    return f_bytes(32, u)


def adm_set_config(section, raw):
    return f_bytes(34, f_bytes(section, raw))


def adm_set_module(section, raw):
    return f_bytes(35, f_bytes(section, raw))


def adm_set_channel(raw):
    return f_bytes(33, raw)


def adm_begin():
    return f_varint(64, 1)


def adm_commit():
    return f_varint(65, 1)


def adm_reboot(secs=2):
    return f_varint(97, secs)


def adm_favorite(num, on=True):
    return f_varint(39 if on else 40, num)


def traceroute_packet(to, hop_limit=0, pid=None):
    return _packet(to, 0, PORT_TRACEROUTE, b"", pid or new_packet_id(), hop_limit, False, True)


def position_request(to, lat=None, lon=None, hop_limit=0, pid=None):
    """Ask a node for its position (want_response). Sends ours along when we have one, like the app."""
    pos = b""
    if lat is not None:
        pos = f_sfixed32(1, int(round(lat * 1e7))) + f_sfixed32(2, int(round(lon * 1e7))) + f_varint(5, 1)
    return _packet(to, 0, PORT_POSITION, pos, pid or new_packet_id(), hop_limit, False, True)


def waypoint_packet(w, channel=0, hop_limit=0, pid=None):
    b = f_varint(1, w["id"]) + f_sfixed32(2, int(round(w["lat"] * 1e7))) + f_sfixed32(3, int(round(w["lon"] * 1e7)))
    if w.get("expire"):
        b += f_varint(4, int(w["expire"]))
    if w.get("name"):
        b += f_bytes(6, w["name"][:29])
    if w.get("description"):
        b += f_bytes(7, w["description"][:99])
    if w.get("icon"):
        b += f_fixed32(8, int(w["icon"]))
    return _packet(BROADCAST, channel, PORT_WAYPOINT, b, pid or new_packet_id(), hop_limit, False)


def channel_url(settings_raws, lora_raw):
    """meshtastic.org share link (the QR code the phone app shows): ChannelSet, base64url."""
    import base64
    cs = b"".join(f_bytes(1, r) for r in settings_raws)
    if lora_raw:
        cs += f_bytes(2, lora_raw)
    return "https://meshtastic.org/e/#" + base64.urlsafe_b64encode(cs).decode().rstrip("=")

# --------------------------------------------------------------------------
# connection
# --------------------------------------------------------------------------

class Stream:
    def __init__(self, host, port, timeout=15):
        # host as bytes: a str host makes Python look up the "idna" codec, which
        # python3-light on the Pager does not include (LookupError: unknown encoding: idna)
        if isinstance(host, str):
            host = host.encode("ascii", "ignore")
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.buf = b""

    def settimeout(self, t):
        self.sock.settimeout(t)

    def send(self, payload):
        self.sock.sendall(MAGIC + struct.pack(">H", len(payload)) + payload)

    def _take(self):
        """Next complete frame from the buffer, or None. Skips debug text."""
        while True:
            j = self.buf.find(MAGIC)
            if j < 0:
                self.buf = self.buf[-1:]
                return None
            self.buf = self.buf[j:]
            if len(self.buf) < 4:
                return None
            n = struct.unpack(">H", self.buf[2:4])[0]
            if n > MAX_FRAME:                # not a real header: resync
                self.buf = self.buf[1:]
                continue
            if len(self.buf) < 4 + n:
                return None
            payload, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
            return payload

    def read(self):
        """One FromRadio payload. Raises socket.timeout when idle,
        ConnectionError when the server closed the connection."""
        while True:
            f = self._take()
            if f is not None:
                return f
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("meshtasticd closed the connection")
            self.buf += chunk

    def close(self, polite=True):
        if polite:
            try:
                self.send(disconnect())
            except OSError:
                pass
        try:
            self.sock.close()
        except OSError:
            pass


class SerialStream(Stream):
    """Meshtastic serial API on a USB radio (/dev/ttyUSB0, /dev/ttyACM0...):
    the same framing as TCP, at 115200 baud. The port is set up with stty
    (busybox) so no termios module is needed."""

    def __init__(self, dev, timeout=15):
        r = subprocess.run(["stty", "-F", dev, "115200", "raw", "-echo", "-echoe", "-echok", "-hupcl"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
        if r.returncode != 0:
            raise OSError("cannot set up %s: %s" % (dev, r.stderr.decode("utf-8", "replace").strip()[:80]))
        self.fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
        self.timeout = timeout
        self.buf = b""
        os.write(self.fd, bytes([0xC3]) * 32)      # wake the radio's serial API, like the phone app
        import time
        time.sleep(0.1)

    def settimeout(self, t):
        self.timeout = t

    def send(self, payload):
        data = MAGIC + struct.pack(">H", len(payload)) + payload
        while data:
            n = os.write(self.fd, data)
            data = data[n:]

    def read(self):
        while True:
            f = self._take()
            if f is not None:
                return f
            r, _, _ = select.select([self.fd], [], [], self.timeout)
            if not r:
                raise socket.timeout("serial idle")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise ConnectionError("USB radio closed the connection")
            self.buf += chunk

    def close(self, polite=True):
        if polite:
            try:
                self.send(disconnect())
            except OSError:
                pass
        try:
            os.close(self.fd)
        except OSError:
            pass


def serial_ports():
    """USB serial devices that could be a Meshtastic radio."""
    import glob
    return sorted(glob.glob("/dev/ttyUSB*") + glob.glob("/dev/ttyACM*"))


def open_stream(conn, host="127.0.0.1", port=4403, dev="", timeout=15):
    if conn == "usb":
        if not dev:
            raise OSError("no USB radio selected")
        return SerialStream(dev, timeout)
    return Stream(host, port, timeout)
