"""Who a LoRa mesh packet came from, and what it says about the node: Meshtastic and MeshCore.

Meshtastic: the 16-byte header names the sender in the clear, says how many hops the packet has made and whether it
came from the internet (MQTT). Only the public default key is tried, so NodeInfo (names, role) and Position are read
from the public default channels and from nothing else. MeshCore: only adverts name a node, and one counts only with a
valid Ed25519 signature.

Adapted from LORA Tunnel for the CardputerZero (Copyright 2026 Valleytech Solutions, MIT). Wire formats:
Meshtastic mesh.proto and MeshCore's packet_format.md and payloads.md. The cryptography package does the AES and
Ed25519. Without it, Meshtastic senders are still counted, with no names or positions, and MeshCore adverts are not.
"""

import math
import struct

DEFAULT_KEY = bytes.fromhex("d4f1bb3a20290759f0bcffabcf4e6901")
DEFAULT_CHANNELS = ("LongFast", "LongSlow", "LongTurbo", "LongMod", "LongModerate", "MediumFast", "MediumSlow",
                    "ShortFast", "ShortSlow", "ShortTurbo")
ROLES = {0: "CLIENT", 1: "CLIENT_MUTE", 2: "ROUTER", 3: "ROUTER_CLIENT", 4: "REPEATER", 5: "TRACKER", 6: "SENSOR",
         7: "TAK", 8: "CLIENT_HIDDEN", 9: "LOST_AND_FOUND", 10: "TAK_TRACKER", 11: "ROUTER_LATE", 12: "CLIENT_BASE"}
MESHCORE_ROLES = {1: "COMPANION", 2: "REPEATER", 3: "ROOM_SERVER", 4: "SENSOR"}
INT32_MAX = 0x7FFFFFFF


class Malformed(ValueError):
    pass


def _varint(data, pos):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise Malformed("varint")
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
    raise Malformed("varint")


def fields(data, limit=96):
    """One bounded protobuf message: {number: (wire type, value)}, the last of each kept."""
    out, pos = {}, 0
    while pos < len(data):
        if len(out) >= limit:
            raise Malformed("fields")
        tag, pos = _varint(data, pos)
        number, wire = tag >> 3, tag & 7
        if number < 1:
            raise Malformed("tag")
        if wire == 0:
            value, pos = _varint(data, pos)
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            if pos + size > len(data):
                raise Malformed("fixed")
            value, pos = data[pos:pos + size], pos + size
        elif wire == 2:
            size, pos = _varint(data, pos)
            if size > len(data) - pos:
                raise Malformed("length")
            value, pos = data[pos:pos + size], pos + size
        else:
            raise Malformed("wire")
        out[number] = (wire, value)
    return out


def _get(found, number, wire):
    item = found.get(number)
    if item is not None and item[0] != wire:
        raise Malformed("wire type")
    return item[1] if item is not None else None


def _text(raw, limit):
    """Text as sent, or Malformed for bytes no node would send, which is what the wrong key gives."""
    if raw is None:
        return ""
    if len(raw) > limit * 2:
        raise Malformed("text")
    try:
        value = raw.decode("utf-8").rstrip("\x00")
    except UnicodeDecodeError:
        raise Malformed("text") from None
    return "".join(c for c in value if c.isprintable()).strip()[:limit]


def _place(lat, lon):
    if lat is None or lon is None or not (math.isfinite(lat) and math.isfinite(lon)):
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180) or (abs(lat) < 1e-6 and abs(lon) < 1e-6):
        return None
    return round(lat, 7), round(lon, 7)


def _aes_ctr(key, nonce, data):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        decryptor = Cipher(algorithms.AES(key), modes.CTR(nonce)).decryptor()
        return decryptor.update(data) + decryptor.finalize()
    except Exception:
        pass
    try:
        from Crypto.Cipher import AES
        return AES.new(key, AES.MODE_CTR, nonce=b"", initial_value=int.from_bytes(nonce, "big")).decrypt(data)
    except Exception:
        return None


def _verify(key, message, signature):
    """True or False, or None when no Ed25519 provider is installed."""
    try:
        from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except Exception:
        try:
            from nacl.exceptions import BadSignatureError
            from nacl.signing import VerifyKey
        except ImportError:
            return None
        try:
            VerifyKey(key).verify(message, signature)
            return True
        except (ValueError, BadSignatureError):
            return False
    try:
        Ed25519PublicKey.from_public_bytes(key).verify(signature, message)
        return True
    except UnsupportedAlgorithm:
        return None
    except (ValueError, InvalidSignature):
        return False


def channel_hash(name, key=DEFAULT_KEY):
    value = 0
    for byte in name.encode("utf-8") + key:
        value ^= byte
    return value


_HASHES = {channel_hash(name) for name in DEFAULT_CHANNELS}


def meshtastic(raw):
    """{"network", "node", "hops", "via_mqtt"} and, on a default channel, "name", "short_name", "role", "position"."""
    if len(raw) <= 16:
        raise Malformed("short")
    destination, source, packet_id, flags, channel, _, _ = struct.unpack("<IIIBBBB", raw[:16])
    if source in (0, 0xFFFFFFFF):
        raise Malformed("source")
    hop_limit, hop_start = flags & 7, flags >> 5
    out = {"network": "meshtastic", "node": "%08x" % source, "via_mqtt": bool(flags & 0x10),
           "hops": hop_start - hop_limit if hop_start and hop_start >= hop_limit else None}
    if channel not in _HASHES:
        return out
    plain = _aes_ctr(DEFAULT_KEY, struct.pack("<QII", packet_id, source, 0), raw[16:])
    if plain is None:
        return out
    try:
        data = fields(plain)
        port, body = _get(data, 1, 0), _get(data, 2, 2) or b""
        if port is None or not 1 <= port <= 511:
            raise Malformed("port")
        if port == 4:
            out.update(_nodeinfo(body, source))
        elif port == 3:
            out.update(_position(body))
    except (Malformed, struct.error):
        pass
    return out


def _nodeinfo(body, source):
    user = fields(body)
    if _get(user, 1, 2) not in (None, b"!%08x" % source):
        raise Malformed("user id")
    out = {"name": _text(_get(user, 2, 2), 40), "short_name": _text(_get(user, 3, 2), 8),
           "role": ROLES.get(_get(user, 7, 0) or 0, "CLIENT")}
    return {key: value for key, value in out.items() if value}


def _position(body):
    position = fields(body)
    lat, lon = _get(position, 1, 5), _get(position, 2, 5)
    if lat is None or lon is None:
        return {}
    lat, lon = struct.unpack("<i", lat)[0], struct.unpack("<i", lon)[0]
    if INT32_MAX in (abs(lat), abs(lon)):
        return {}
    place = _place(lat / 1e7, lon / 1e7)
    return {"position": place} if place else {}


def meshcore(raw):
    """A signed advert as {"network", "node", "public_key", "hops", "role", "name", "position"}. None for any other
    packet: those name a node only by a byte or two of its key."""
    if len(raw) < 3 or raw[0] >> 6:
        raise Malformed("header")
    route, kind = raw[0] & 3, (raw[0] >> 2) & 15
    if kind != 4:
        return None
    index = 5 if route in (0, 3) else 1
    if index >= len(raw):
        raise Malformed("transport")
    count, size = raw[index] & 63, 1 + (raw[index] >> 6)
    if size > 3 or count * size > 64 or index + 1 + count * size >= len(raw):
        raise Malformed("path")
    payload = raw[index + 1 + count * size:]
    if not 100 <= len(payload) <= 132:
        raise Malformed("advert")
    key, stamp, signature, app = payload[:32], payload[32:36], payload[36:100], payload[100:]
    if _verify(key, key + stamp + app, signature) is not True:
        return None
    out = {"network": "meshcore", "node": key[:8].hex(), "public_key": key.hex(), "via_mqtt": False,
           "hops": count if route in (0, 1) else 0 if count == 0 else None}
    if not app:
        return out
    flags, cursor = app[0], 1
    out["role"] = MESHCORE_ROLES.get(flags & 15, "")
    if flags & 0x10:
        if cursor + 8 > len(app):
            raise Malformed("location")
        lat, lon = struct.unpack("<ii", app[cursor:cursor + 8])
        cursor += 8
        place = _place(lat / 1e6, lon / 1e6)
        if place:
            out["position"] = place
    cursor += (2 if flags & 0x20 else 0) + (2 if flags & 0x40 else 0)
    if cursor > len(app):
        raise Malformed("features")
    if flags & 0x80:
        try:
            out["name"] = _text(app[cursor:], 32)
        except Malformed:
            pass
    return {key: value for key, value in out.items() if value not in ("", None) or key == "hops"}


def decode(raw, protocol):
    """The node a packet tells of, or None. Malformed packets are None, never an error."""
    if not isinstance(raw, bytes) or not 1 <= len(raw) <= 255:
        return None
    try:
        return meshtastic(raw) if protocol == "meshtastic" else meshcore(raw)
    except (Malformed, struct.error, IndexError, ValueError):
        return None
