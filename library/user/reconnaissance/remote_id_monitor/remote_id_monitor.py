#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Passive ASTM/OpenDroneID monitor for the WiFi Pineapple Pager.

The decoder is a Python port of the ESP32 Marauder Remote ID implementation.
It accepts Wi-Fi Beacon vendor IEs, Wi-Fi NAN service descriptors, and ASTM
Bluetooth Service Data UUID 0xFFFA. Runtime dependencies are Python's standard
library plus the Pager's stock tcpdump and Bluetooth utilities.
"""

import argparse
import csv
import json
import math
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

MESSAGE_SIZE = 25
BLE_SERVICE_UUID = 0xFFFA
ASD_STAN_OUI = b"\xfa\x0b\xbc"
LEGACY_REMOTE_ID_OUI = b"\x90\x3a\xe6"
OPEN_DRONE_ID_VENDOR_TYPE = 0x0D
OPEN_DRONE_ID_BLE_APP_CODE = 0x0D
LOST_AFTER_SECONDS = 15
CSV_INTERVAL_SECONDS = 5
TRANSPORT_WIFI_BEACON = "wifi-beacon"
TRANSPORT_WIFI_NAN = "wifi-nan"
TRANSPORT_BLE = "ble"
IW_COMMAND = "/usr/sbin/iw" if os.path.exists("/usr/sbin/iw") else "iw"
UA_TYPES = {
    0: "None", 1: "Aeroplane", 2: "Helicopter", 3: "Gyroplane",
    4: "Hybrid Lift", 5: "Ornithopter", 6: "Glider", 7: "Kite",
    8: "Free Balloon", 9: "Captive Balloon", 10: "Airship",
    11: "Parachute", 12: "Rocket", 13: "Tethered", 14: "Ground",
    15: "Other",
}
ID_TYPES = {0: "None", 1: "Serial", 2: "CAA", 3: "UTM", 4: "Session"}
STATUS_TYPES = {
    0: "Undeclared", 1: "Ground", 2: "Airborne", 3: "Emergency",
    4: "Remote ID failure",
}


class DecodeError(ValueError):
    pass


def _i32le(data):
    return struct.unpack_from("<i", data)[0]


def _u16le(data):
    return struct.unpack_from("<H", data)[0]


def _u32le(data):
    return struct.unpack_from("<I", data)[0]


def _text(data, limit):
    raw = data[:limit].split(b"\0", 1)[0]
    return raw.decode("utf-8", "replace").strip()


def coordinates_valid(latitude_e7, longitude_e7):
    return (-900000000 <= latitude_e7 <= 900000000 and
            -1800000000 <= longitude_e7 <= 1800000000 and
            (latitude_e7 != 0 or longitude_e7 != 0))


def decode_message(message, record=None):
    if len(message) < MESSAGE_SIZE:
        raise DecodeError("truncated Remote ID message")
    record = {} if record is None else record
    msg_type = message[0] >> 4
    if msg_type == 0:
        record.update({
            "id_type": message[1] >> 4,
            "ua_type": message[1] & 0x0F,
            "uas_id": _text(message[2:22], 20),
        })
        return True, record
    if msg_type == 1:
        status_flags = message[1]
        high_speed = bool(status_flags & 0x01)
        west_direction = bool(status_flags & 0x02)
        direction = message[2] + (180 if west_direction else 0)
        horizontal_speed = message[3] * 0.75 + 63.75 if high_speed else message[3] * 0.25
        vertical_speed = struct.unpack("b", bytes([message[4]]))[0] * 0.5
        latitude_e7 = _i32le(message[5:9])
        longitude_e7 = _i32le(message[9:13])
        pressure_altitude = _u16le(message[13:15]) * 0.5 - 1000.0
        geo_altitude = _u16le(message[15:17]) * 0.5 - 1000.0
        height = _u16le(message[17:19]) * 0.5 - 1000.0
        timestamp_ds = _u16le(message[21:23])
        record.update({
            "operational_status": status_flags >> 4,
            "height_above_ground": bool(status_flags & 0x04),
            "direction_deg": direction,
            "direction_valid": direction <= 360,
            "horizontal_speed_mps": horizontal_speed,
            "horizontal_speed_valid": horizontal_speed <= 254.25,
            "vertical_speed_mps": vertical_speed,
            "vertical_speed_valid": -62.0 <= vertical_speed <= 62.0,
            "latitude_e7": latitude_e7,
            "longitude_e7": longitude_e7,
            "has_location": coordinates_valid(latitude_e7, longitude_e7),
            "pressure_altitude_m": pressure_altitude,
            "pressure_altitude_valid": pressure_altitude > -1000.0,
            "geo_altitude_m": geo_altitude,
            "geo_altitude_valid": geo_altitude > -1000.0,
            "height_m": height,
            "height_valid": height > -1000.0,
            "horizontal_accuracy": message[19] & 0x0F,
            "vertical_accuracy": message[19] >> 4,
            "speed_accuracy": message[20] & 0x0F,
            "location_timestamp_ds": timestamp_ds,
            "location_timestamp_valid": timestamp_ds != 0xFFFF,
        })
        return True, record
    if msg_type == 2:
        page = message[1] & 0x0F
        record.update({
            "has_authentication": True,
            "authentication_type": message[1] >> 4,
            "authentication_page": page,
        })
        if page == 0:
            if message[2] > 15:
                raise DecodeError("invalid authentication last page")
            record.update({
                "authentication_last_page": message[2],
                "authentication_length": message[3],
                "authentication_timestamp": _u32le(message[4:8]),
            })
        return True, record
    if msg_type == 3:
        record["description"] = _text(message[2:25], 23)
        return True, record
    if msg_type == 4:
        operator_latitude_e7 = _i32le(message[2:6])
        operator_longitude_e7 = _i32le(message[6:10])
        area_ceiling = _u16le(message[13:15]) * 0.5 - 1000.0
        area_floor = _u16le(message[15:17]) * 0.5 - 1000.0
        operator_altitude = _u16le(message[18:20]) * 0.5 - 1000.0
        record.update({
            "operator_location_type": message[1] & 0x03,
            "classification_type": (message[1] >> 2) & 0x07,
            "operator_latitude_e7": operator_latitude_e7,
            "operator_longitude_e7": operator_longitude_e7,
            "has_operator_location": coordinates_valid(operator_latitude_e7, operator_longitude_e7),
            "area_count": _u16le(message[10:12]),
            "area_radius_m": message[12] * 10,
            "area_ceiling_m": area_ceiling,
            "area_ceiling_valid": area_ceiling > -1000.0,
            "area_floor_m": area_floor,
            "area_floor_valid": area_floor > -1000.0,
            "category_eu": message[17] >> 4,
            "class_eu": message[17] & 0x0F,
            "operator_altitude_geo_m": operator_altitude,
            "operator_altitude_valid": operator_altitude > -1000.0,
            "system_timestamp": _u32le(message[20:24]),
        })
        return True, record
    if msg_type == 5:
        record["operator_id"] = _text(message[2:22], 20)
        return True, record
    return False, record


def decode_payload(payload, record=None):
    if not payload:
        raise DecodeError("empty Remote ID payload")
    record = {} if record is None else record
    if payload[0] >> 4 != 15:
        return decode_message(payload, record)
    if len(payload) < 3 or payload[1] != MESSAGE_SIZE or payload[2] == 0:
        raise DecodeError("invalid Remote ID message pack")
    required = 3 + payload[2] * MESSAGE_SIZE
    if required > len(payload):
        raise DecodeError("truncated Remote ID message pack")
    decoded = False
    for index in range(payload[2]):
        start = 3 + index * MESSAGE_SIZE
        accepted, record = decode_message(payload[start:start + MESSAGE_SIZE], record)
        decoded = decoded or accepted
    return decoded, record


def decode_wifi_beacon(frame):
    if len(frame) < 36:
        raise DecodeError("truncated beacon")
    if frame[0] & 0xFC != 0x80:
        return False, {}
    offset = 36
    while offset + 2 <= len(frame):
        element_id = frame[offset]
        element_length = frame[offset + 1]
        offset += 2
        end = offset + element_length
        if end > len(frame):
            raise DecodeError("truncated beacon information element")
        element = frame[offset:end]
        if (element_id == 221 and element_length >= 8 and
                element[:3] in (ASD_STAN_OUI, LEGACY_REMOTE_ID_OUI) and
                element[3] == OPEN_DRONE_ID_VENDOR_TYPE):
            return decode_payload(element[5:])
        offset = end
    return False, {}


def decode_wifi_nan(frame):
    nan_destination = b"\x51\x6f\x9a\x01\x00\x00"
    wifi_alliance_oui = b"\x50\x6f\x9a"
    remote_id_service = b"\x88\x69\x19\x9d\x92\x09"
    if len(frame) < 30:
        raise DecodeError("truncated NAN frame")
    if frame[0] & 0xFC != 0xD0:
        return False, {}
    if frame[4:10] != nan_destination:
        return False, {}
    if (frame[24] != 0x04 or frame[25] != 0x09 or
            frame[26:29] != wifi_alliance_oui or frame[29] != 0x13):
        return False, {}
    offset = 30
    while offset < len(frame):
        if len(frame) - offset < 3:
            raise DecodeError("truncated NAN attribute")
        attribute = frame[offset]
        attribute_length = _u16le(frame[offset + 1:offset + 3])
        offset += 3
        end = offset + attribute_length
        if end > len(frame):
            raise DecodeError("NAN attribute exceeds frame")
        if attribute != 0x03:
            offset = end
            continue
        if attribute_length < 9:
            raise DecodeError("short NAN service descriptor")
        control = frame[offset + 8]
        if (frame[offset:offset + 6] != remote_id_service or
                not control & 0x10 or control & 0x03 == 0x03 or control & 0x80):
            offset = end
            continue
        service_info = offset + 9
        if control & 0x40:
            if end - service_info < 2:
                raise DecodeError("truncated NAN binding bitmap")
            service_info += 2
        for flag in (0x04, 0x08):
            if not control & flag:
                continue
            if service_info == end:
                raise DecodeError("missing NAN filter length")
            filter_length = frame[service_info]
            service_info += 1
            if filter_length > end - service_info:
                raise DecodeError("NAN filter exceeds descriptor")
            service_info += filter_length
        if service_info == end:
            raise DecodeError("missing NAN service information")
        service_length = frame[service_info]
        service_info += 1
        if service_length < 1 or service_length > end - service_info:
            raise DecodeError("invalid NAN service information length")
        result = decode_payload(frame[service_info + 1:service_info + service_length])
        if result[0]:
            return result
        offset = end
    return False, {}


def decode_ble_service_data(service_data):
    if len(service_data) < 2:
        raise DecodeError("truncated BLE service data")
    if _u16le(service_data[:2]) != BLE_SERVICE_UUID:
        return False, {}
    if len(service_data) < 4 + MESSAGE_SIZE:
        raise DecodeError("truncated OpenDroneID BLE service data")
    if service_data[2] != OPEN_DRONE_ID_BLE_APP_CODE:
        return False, {}
    return decode_payload(service_data[4:])


def parse_advertising_data(data):
    records = []
    offset = 0
    while offset < len(data):
        length = data[offset]
        offset += 1
        if length == 0:
            break
        end = offset + length
        if end > len(data):
            raise DecodeError("truncated BLE AD structure")
        ad_type = data[offset]
        value = data[offset + 1:end]
        if ad_type == 0x16:
            records.append(value)
        offset = end
    return records


def _btmon_hex_bytes(line):
    values = []
    for token in line.strip().split():
        if len(token) != 2 or not all(char in "0123456789abcdefABCDEF" for char in token):
            break
        values.append(int(token, 16))
    return bytes(values)


def iter_btmon_reports(stream):
    """Yield complete LE advertising reports from btmon's decoded stream."""
    in_advertising_event = False
    mac = None
    rssi = None
    expected_length = None
    data = bytearray()
    complete = True

    def finished_report():
        if (mac and complete and expected_length is not None and
                len(data) >= expected_length and expected_length > 0):
            return mac.lower(), rssi, bytes(data[:expected_length])
        return None

    for line in stream:
        if ("LE Advertising Report" in line or
                "LE Extended Advertising Report" in line):
            report = finished_report()
            if report:
                yield report
            in_advertising_event = True
            mac = None
            rssi = None
            expected_length = None
            data = bytearray()
            complete = True
            continue
        if not in_advertising_event:
            continue
        if re.search(r"\bEntry \d+", line):
            report = finished_report()
            if report:
                yield report
            mac = None
            rssi = None
            expected_length = None
            data = bytearray()
            complete = True
            continue
        if "Data status:" in line:
            complete = "Complete" in line
            continue
        address = re.search(r"\bAddress: ([0-9A-Fa-f:]{17})\b", line)
        if address:
            mac = address.group(1)
            continue
        signal_value = re.search(r"\bRSSI: (-?\d+) dBm", line)
        if signal_value:
            rssi = int(signal_value.group(1))
            continue
        length_match = re.search(r"\bData length: (?:0x([0-9A-Fa-f]+)|(\d+))", line)
        if length_match:
            expected_length = int(length_match.group(1), 16) if length_match.group(1) else int(length_match.group(2))
            data = bytearray()
            continue
        if expected_length is not None and len(data) < expected_length:
            chunk = _btmon_hex_bytes(line)
            if chunk:
                data.extend(chunk)
                if len(data) >= expected_length:
                    report = finished_report()
                    if report:
                        yield report
                    expected_length = None
                    data = bytearray()
    report = finished_report()
    if report:
        yield report


def parse_hci_event(packet):
    """Return (mac, rssi, service-data) tuples from LE advertising events."""
    results = []
    if len(packet) < 4 or packet[0] != 0x04 or packet[1] != 0x3E:
        return results
    payload_length = packet[2]
    payload = packet[3:3 + payload_length]
    if len(payload) < 2:
        return results
    subevent = payload[0]
    count = payload[1]
    offset = 2
    if subevent == 0x02:
        for _ in range(count):
            if offset + 10 > len(payload):
                break
            offset += 2
            address = payload[offset:offset + 6]
            offset += 6
            data_length = payload[offset]
            offset += 1
            if offset + data_length + 1 > len(payload):
                break
            ad = payload[offset:offset + data_length]
            offset += data_length
            rssi = struct.unpack("b", bytes([payload[offset]]))[0]
            offset += 1
            mac = ":".join(f"{byte:02x}" for byte in address[::-1])
            for service_data in parse_advertising_data(ad):
                results.append((mac, rssi, service_data))
    elif subevent == 0x0D:
        for _ in range(count):
            if offset + 24 > len(payload):
                break
            offset += 2
            offset += 1
            address = payload[offset:offset + 6]
            offset += 6
            offset += 3
            offset += 1
            rssi = struct.unpack("b", bytes([payload[offset]]))[0]
            offset += 1
            offset += 2
            offset += 1
            offset += 6
            data_length = payload[offset]
            offset += 1
            if offset + data_length > len(payload):
                break
            ad = payload[offset:offset + data_length]
            offset += data_length
            mac = ":".join(f"{byte:02x}" for byte in address[::-1])
            for service_data in parse_advertising_data(ad):
                results.append((mac, rssi, service_data))
    return results


RADIOTAP_FIELDS = {
    0: (8, 8), 1: (1, 1), 2: (1, 1), 3: (2, 4), 4: (2, 2),
    5: (1, 1), 6: (1, 1), 7: (2, 2), 8: (2, 2), 9: (2, 2),
    10: (1, 1), 11: (1, 1), 12: (1, 1), 13: (1, 1), 14: (2, 2),
    15: (2, 2), 16: (1, 1), 17: (1, 1),
}


def _align(offset, alignment):
    return (offset + alignment - 1) & ~(alignment - 1)


def channel_from_frequency(frequency):
    if frequency == 2484:
        return 14
    if 2412 <= frequency <= 2472:
        return (frequency - 2407) // 5
    if 5000 <= frequency <= 5895:
        return (frequency - 5000) // 5
    if 5955 <= frequency <= 7115:
        return (frequency - 5950) // 5
    return 0


def parse_radiotap(packet):
    if len(packet) < 8 or packet[0] != 0:
        raise DecodeError("invalid radiotap header")
    header_length = _u16le(packet[2:4])
    if header_length < 8 or header_length > len(packet):
        raise DecodeError("invalid radiotap length")
    present_words = []
    offset = 4
    while True:
        if offset + 4 > header_length:
            raise DecodeError("truncated radiotap present bitmap")
        word = _u32le(packet[offset:offset + 4])
        present_words.append(word)
        offset += 4
        if not word & 0x80000000:
            break
    field_offset = offset
    rssi = None
    channel = 0
    for bit in range(18):
        word_index = bit // 32
        if word_index >= len(present_words) or not present_words[word_index] & (1 << (bit % 32)):
            continue
        alignment, size = RADIOTAP_FIELDS[bit]
        field_offset = _align(field_offset, alignment)
        if field_offset + size > header_length:
            raise DecodeError("truncated radiotap field")
        value = packet[field_offset:field_offset + size]
        if bit == 3:
            channel = channel_from_frequency(_u16le(value[:2]))
        elif bit == 5:
            rssi = struct.unpack("b", value)[0]
        field_offset += size
    return packet[header_length:], rssi, channel


class PcapReader:
    def __init__(self, stream):
        self.stream = stream
        header = self._read_exact(24)
        magic = header[:4]
        if magic == b"\xd4\xc3\xb2\xa1" or magic == b"\x4d\x3c\xb2\xa1":
            self.endian = "<"
        elif magic == b"\xa1\xb2\xc3\xd4" or magic == b"\xa1\xb2\x3c\x4d":
            self.endian = ">"
        else:
            raise DecodeError("unsupported pcap header")
        self.linktype = struct.unpack(self.endian + "I", header[20:24])[0]
        if self.linktype != 127:
            raise DecodeError(f"expected radiotap linktype 127, got {self.linktype}")

    def _read_exact(self, length):
        chunks = []
        remaining = length
        while remaining:
            chunk = self.stream.read(remaining)
            if not chunk:
                raise EOFError
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def __iter__(self):
        while True:
            try:
                header = self._read_exact(16)
            except EOFError:
                return
            _, _, included, _ = struct.unpack(self.endian + "IIII", header)
            if included > 65535:
                raise DecodeError("unreasonable pcap packet length")
            try:
                yield self._read_exact(included)
            except EOFError as error:
                raise DecodeError("truncated pcap packet") from error


def distance_m(lat1, lon1, lat2, lon2):
    lat1r, lat2r = math.radians(lat1), math.radians(lat2)
    dlat = lat2r - lat1r
    dlon = math.radians(lon2 - lon1)
    value = math.sin(dlat / 2) ** 2 + math.cos(lat1r) * math.cos(lat2r) * math.sin(dlon / 2) ** 2
    return 2 * 6371000.0 * math.atan2(math.sqrt(value), math.sqrt(max(0.0, 1.0 - value)))


def bearing_deg(lat1, lon1, lat2, lon2):
    lat1r, lat2r = math.radians(lat1), math.radians(lat2)
    dlon = math.radians(lon2 - lon1)
    y = math.sin(dlon) * math.cos(lat2r)
    x = math.cos(lat1r) * math.sin(lat2r) - math.sin(lat1r) * math.cos(lat2r) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def atomic_json(path, value):
    path = str(path)
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w") as handle:
        handle.write(json.dumps(value, sort_keys=True, separators=(",", ":")))
    os.replace(temporary, path)


def mac_from_frame(frame):
    if len(frame) < 16:
        return "00:00:00:00:00:00"
    return ":".join(f"{byte:02x}" for byte in frame[10:16])


def _basic_id_priority(id_type):
    if id_type == 1:
        return 3
    if id_type == 2:
        return 2
    return 1


def merge_decoded_record(record, updates):
    """Merge only present/valid fields and preserve the best ASTM Basic ID."""
    updates = dict(updates)
    candidate_id = updates.pop("uas_id", None)
    candidate_type = updates.pop("id_type", None)
    candidate_ua_type = updates.pop("ua_type", None)
    if candidate_id:
        current_id = record.get("uas_id")
        current_type = record.get("id_type", 0)
        if (not current_id or candidate_type == current_type or
                _basic_id_priority(candidate_type or 0) > _basic_id_priority(current_type)):
            record["uas_id"] = candidate_id
            if candidate_type is not None:
                record["id_type"] = candidate_type
            if candidate_ua_type is not None:
                record["ua_type"] = candidate_ua_type

    for text_key in ("operator_id", "description"):
        if not updates.get(text_key):
            updates.pop(text_key, None)

    if not updates.get("has_location") and record.get("has_location"):
        for key in ("has_location", "latitude_e7", "longitude_e7"):
            updates.pop(key, None)
    if not updates.get("has_operator_location") and record.get("has_operator_location"):
        for key in ("has_operator_location", "operator_latitude_e7", "operator_longitude_e7"):
            updates.pop(key, None)
    if updates.get("has_authentication") is False:
        updates.pop("has_authentication", None)

    record.update(updates)
    return record


class RemoteIdMonitor:
    def __init__(self, state_path, event_path, csv_path, gpx_path):
        self.state_path = str(state_path)
        self.event_path = str(event_path)
        self.csv_path = str(csv_path)
        self.gpx_path = str(gpx_path)
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.records = {}
        self.frames = 0
        self.ble_frames = 0
        self.decoded = 0
        self.malformed = 0
        self.event_seq = 0
        self.started = time.time()
        self.gps = None
        self.capture_errors = []
        self.processes = []
        self.process_lock = threading.Lock()
        self.wifi_alive = False
        self.ble_alive = False
        self.last_gpx_write = 0
        self.wifi_channel = None
        self.original_wifi_channel = None

    def stop(self):
        self.stop_event.set()
        with self.process_lock:
            processes = list(self.processes)
        for process in processes:
            try:
                process.terminate()
            except OSError:
                pass

    def _register_process(self, process):
        with self.process_lock:
            self.processes.append(process)

    def _reap_process(self, process):
        try:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=2)
        except Exception:
            try:
                process.kill()
                process.wait(timeout=2)
            except Exception:
                pass
        with self.process_lock:
            if process in self.processes:
                self.processes.remove(process)

    def _reap_all_processes(self):
        with self.process_lock:
            processes = list(self.processes)
        for process in processes:
            self._reap_process(process)

    def _capture_error(self, message):
        with self.lock:
            if message not in self.capture_errors:
                self.capture_errors.append(message)

    def _record_key(self, mac, updates):
        uas_id = updates.get("uas_id")
        if uas_id:
            for key, record in self.records.items():
                if record.get("uas_id") == uas_id:
                    return key
        return mac

    def observe(self, mac, transport, rssi, channel, updates):
        now = time.time()
        with self.lock:
            key = self._record_key(mac, updates)
            is_new = key not in self.records
            record = self.records.setdefault(key, {
                "mac": mac, "first_seen": now, "last_seen": now,
                "packet_count": 0, "transports": [], "history": [],
            })
            record["last_seen"] = now
            record["packet_count"] += 1
            record["mac"] = mac
            if transport not in record["transports"]:
                record["transports"].append(transport)
            if rssi is not None:
                record["rssi"] = rssi
            if channel:
                record["channel"] = channel
            had_location = bool(record.get("has_location"))
            old_location = (record.get("latitude_e7"), record.get("longitude_e7"))
            merge_decoded_record(record, updates)
            if record.get("has_location"):
                location = (record.get("latitude_e7"), record.get("longitude_e7"))
                if not had_location or location != old_location:
                    record["history"].append({"time": now, "latitude": location[0] / 1e7, "longitude": location[1] / 1e7})
                    record["history"] = record["history"][-200:]
            self.decoded += 1
            if is_new:
                self.event_seq += 1
                self._write_event("new", record)
            elif record.get("uas_id") and not record.get("identity_logged"):
                record["identity_logged"] = True
                self.event_seq += 1
                self._write_event("identified", record)
            if is_new or now - record.get("_last_csv", 0) >= CSV_INTERVAL_SECONDS:
                record["_last_csv"] = now
                self._append_csv(record, transport)

    def _write_event(self, kind, record):
        event = {"event": kind, "time": time.time(), "record": self.public_record(record)}
        os.makedirs(os.path.dirname(self.event_path) or ".", exist_ok=True)
        with open(self.event_path, "a") as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")

    def _append_csv(self, record, transport):
        os.makedirs(os.path.dirname(self.csv_path) or ".", exist_ok=True)
        exists = os.path.exists(self.csv_path)
        with open(self.csv_path, "a", newline="") as handle:
            writer = csv.writer(handle)
            if not exists:
                writer.writerow(["time", "uas_id", "mac", "transport", "rssi", "channel", "latitude", "longitude", "geo_altitude_m", "operator_id"])
            writer.writerow([
                int(time.time()), record.get("uas_id", ""), record.get("mac", ""), transport,
                record.get("rssi", ""), record.get("channel", ""),
                record.get("latitude_e7", 0) / 1e7 if record.get("has_location") else "",
                record.get("longitude_e7", 0) / 1e7 if record.get("has_location") else "",
                record.get("geo_altitude_m", "") if record.get("geo_altitude_valid") else "",
                record.get("operator_id", ""),
            ])

    def public_record(self, record):
        result = {key: value for key, value in record.items() if not key.startswith("_")}
        if self.gps and record.get("has_location"):
            drone_lat = record["latitude_e7"] / 1e7
            drone_lon = record["longitude_e7"] / 1e7
            result["distance_m"] = distance_m(self.gps[0], self.gps[1], drone_lat, drone_lon)
            result["bearing_deg"] = bearing_deg(self.gps[0], self.gps[1], drone_lat, drone_lon)
        return result

    def snapshot(self, status="scanning"):
        with self.lock:
            now = time.time()
            records = [self.public_record(record) for record in self.records.values()]
            for record in records:
                record["is_lost"] = now - record.get("last_seen", 0) >= LOST_AFTER_SECONDS
            records.sort(key=lambda item: item.get("last_seen", 0), reverse=True)
            active_count = sum(1 for record in records if not record["is_lost"])
            if status == "scanning" and self.capture_errors:
                status = "degraded"
            return {
                "status": status,
                "active_count": active_count,
                "started": self.started,
                "updated": time.time(),
                "frames": self.frames,
                "ble_frames": self.ble_frames,
                "decoded": self.decoded,
                "malformed": self.malformed,
                "event_seq": self.event_seq,
                "gps": self.gps,
                "capture_errors": list(self.capture_errors),
                "wifi_alive": self.wifi_alive,
                "ble_alive": self.ble_alive,
                "wifi_channel": self.wifi_channel,
                "original_wifi_channel": self.original_wifi_channel,
                "records": records,
            }

    def write_state(self, status="scanning"):
        atomic_json(self.state_path, self.snapshot(status))

    def wifi_loop(self, interface):
        command = ["tcpdump", "-l", "-U", "-s", "2048", "-i", interface, "-w", "-", "type mgt"]
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as error:
            self._capture_error(f"Wi-Fi: {error}")
            return
        self._register_process(process)
        self.wifi_alive = True
        try:
            for packet in PcapReader(process.stdout):
                if self.stop_event.is_set():
                    break
                self.frames += 1
                try:
                    frame, rssi, channel = parse_radiotap(packet)
                    mac = mac_from_frame(frame)
                    frame_kind = frame[0] & 0xFC if frame else -1
                    if frame_kind == 0x80:
                        decoded, updates = decode_wifi_beacon(frame)
                        transport = TRANSPORT_WIFI_BEACON
                    elif frame_kind == 0xD0:
                        decoded, updates = decode_wifi_nan(frame)
                        transport = TRANSPORT_WIFI_NAN
                    else:
                        continue
                    if decoded:
                        self.observe(mac, transport, rssi, channel, updates)
                except DecodeError:
                    self.malformed += 1
            if not self.stop_event.is_set():
                self._capture_error("Wi-Fi capture ended unexpectedly")
        except (DecodeError, EOFError, OSError) as error:
            if not self.stop_event.is_set():
                self._capture_error(f"Wi-Fi: {error}")
        finally:
            self.wifi_alive = False
            self._reap_process(process)

    def ble_loop(self):
        blue5_running = subprocess.call(
            ["pgrep", "blue5"], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ) == 0
        if not blue5_running:
            self._capture_error("BLE: stock blue5 scanner is not running")
            return
        try:
            process = subprocess.Popen(
                ["btmon", "-i", "0", "-P", "-c", "never"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, bufsize=1,
            )
        except OSError as error:
            self._capture_error(f"BLE: {error}")
            return
        self._register_process(process)
        self.ble_alive = True
        try:
            for mac, rssi, advertising_data in iter_btmon_reports(process.stdout):
                if self.stop_event.is_set():
                    break
                self.ble_frames += 1
                try:
                    for service_data in parse_advertising_data(advertising_data):
                        decoded, updates = decode_ble_service_data(service_data)
                        if decoded:
                            self.observe(mac, TRANSPORT_BLE, rssi, 0, updates)
                except DecodeError:
                    self.malformed += 1
            if not self.stop_event.is_set():
                self._capture_error("BLE capture ended unexpectedly")
        except (OSError, ValueError) as error:
            if not self.stop_event.is_set():
                self._capture_error(f"BLE: {error}")
        finally:
            self.ble_alive = False
            self._reap_process(process)

    def gps_loop(self):
        try:
            process = subprocess.Popen(["gpspipe", "-w"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError:
            return
        self._register_process(process)
        try:
            for line in process.stdout:
                if self.stop_event.is_set():
                    break
                try:
                    report = json.loads(line)
                    if report.get("class") == "TPV" and report.get("mode", 0) >= 2:
                        self.gps = (float(report["lat"]), float(report["lon"]))
                except (ValueError, KeyError, TypeError):
                    continue
        finally:
            self._reap_process(process)

    def write_gpx(self):
        points = []
        with self.lock:
            for record in self.records.values():
                for point in record.get("history", []):
                    points.append((point["time"], point["latitude"], point["longitude"], record.get("uas_id") or record.get("mac")))
        points.sort()
        os.makedirs(os.path.dirname(self.gpx_path) or ".", exist_ok=True)
        temporary = self.gpx_path + ".tmp"
        with open(temporary, "w") as handle:
            handle.write('<?xml version="1.0" encoding="UTF-8"?>\n')
            handle.write('<gpx version="1.1" creator="Remote ID Radar" xmlns="http://www.topografix.com/GPX/1/1">\n')
            for stamp, latitude, longitude, name in points:
                safe_name = str(name).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                handle.write(f'  <wpt lat="{latitude:.7f}" lon="{longitude:.7f}"><time>{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp))}</time><name>{safe_name}</name></wpt>\n')
            handle.write('</gpx>\n')
        os.replace(temporary, self.gpx_path)
        self.last_gpx_write = time.time()


def parse_interface_channel(text):
    match = re.search(r"^\s*channel\s+(\d+)\b", text, re.MULTILINE)
    return int(match.group(1)) if match else None


def interface_channel(interface):
    try:
        output = subprocess.check_output(
            [IW_COMMAND, "dev", interface, "info"],
            stderr=subprocess.DEVNULL, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return parse_interface_channel(output)


def set_interface_channel(interface, channel):
    try:
        return subprocess.call(
            [IW_COMMAND, "dev", interface, "set", "channel", str(channel)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ) == 0
    except OSError:
        return False


def run_monitor(args):
    monitor = RemoteIdMonitor(args.state, args.events, args.csv, args.gpx)
    monitor.original_wifi_channel = interface_channel(args.interface)
    if args.wifi_channel:
        if set_interface_channel(args.interface, args.wifi_channel):
            monitor.wifi_channel = args.wifi_channel
        else:
            monitor._capture_error(f"Wi-Fi: could not tune {args.interface} to channel {args.wifi_channel}")
    def stop_handler(_signum, _frame):
        monitor.stop()
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    threads = [
        threading.Thread(target=monitor.wifi_loop, args=(args.interface,), daemon=True),
        threading.Thread(target=monitor.ble_loop, daemon=True),
        threading.Thread(target=monitor.gps_loop, daemon=True),
    ]
    for thread in threads:
        thread.start()
    monitor.write_state()
    try:
        while not monitor.stop_event.wait(1.0):
            monitor.write_state()
            if time.time() - monitor.last_gpx_write >= 30:
                monitor.write_gpx()
    finally:
        monitor.stop()
        for thread in threads:
            thread.join(timeout=3)
        monitor._reap_all_processes()
        if (monitor.original_wifi_channel and monitor.wifi_channel and
                monitor.original_wifi_channel != monitor.wifi_channel):
            if not set_interface_channel(args.interface, monitor.original_wifi_channel):
                monitor._capture_error(
                    f"Wi-Fi: could not restore channel {monitor.original_wifi_channel}")
        monitor.write_gpx()
        monitor.write_state("stopped")
    return 0


def load_state(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {"status": "not-started", "records": [], "frames": 0, "decoded": 0, "event_seq": 0}


def direction_name(degrees):
    names = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")
    return names[int((degrees + 22.5) // 45) % 8]


def looks_like_mac(value):
    return bool(re.fullmatch(r"[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}", str(value)))


def censor_name(value):
    value = str(value)
    return value[:3] + "X" * max(0, len(value) - 3)


def censor_mac(value):
    result = []
    hex_digits = 0
    for character in str(value):
        if character in "0123456789abcdefABCDEF":
            result.append(character if hex_digits < 4 else "X")
            hex_digits += 1
        else:
            result.append(character)
    return "".join(result)


def censor_identifier(value):
    return censor_mac(value) if looks_like_mac(value) else censor_name(value)


def load_censor_setting(path):
    try:
        with open(path) as handle:
            return bool(json.load(handle).get("censor", False))
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def save_censor_setting(path, enabled):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    atomic_json(path, {"censor": bool(enabled)})


def short_identity(record, censor=False):
    identity = record.get("uas_id") or record.get("description") or record.get("mac", "unknown")
    return censor_identifier(identity) if censor else identity


def render_state(path, censor=False):
    state = load_state(path)
    elapsed = max(0, int(time.time() - state.get("started", time.time())))
    records = state.get("records", [])
    active_count = state.get("active_count", sum(1 for record in records if not record.get("is_lost")))
    lines = [f"REMOTE ID RADAR  {elapsed // 60:02d}:{elapsed % 60:02d}",
             f"ACTIVE {active_count}  SEEN {len(records)}  W {state.get('frames', 0)} B {state.get('ble_frames', 0)}"
             + (f" Ch {state['wifi_channel']}" if state.get("wifi_channel") else "")]
    if state.get("capture_errors"):
        lines.append("WARN " + state["capture_errors"][-1][:54])
    if not records:
        lines.append("Scanning Wi-Fi + Bluetooth...")
    visible_records = [record for record in records if not record.get("is_lost")]
    if not visible_records:
        visible_records = records
    for record in visible_records[:3]:
        transport = "+".join("W" if value.startswith("wifi") else "B" for value in record.get("transports", []))
        identity = short_identity(record, censor)[:24]
        rssi = f"{record.get('rssi')}dBm" if "rssi" in record else "RSSI ?"
        line = f"[{transport or '?'}] {identity}  {rssi}"
        if "distance_m" in record:
            distance = record["distance_m"]
            distance_text = f"{distance:.0f}m" if distance < 1000 else f"{distance / 1000:.1f}km"
            line += f"  {distance_text} {direction_name(record['bearing_deg'])}"
        lines.append(line)
    lines.append("A: stop")
    return "\n".join(lines)


def list_state(path, censor=False):
    records = load_state(path).get("records", [])
    if not records:
        return ["No Remote ID devices"]
    return [f"{index + 1}. {short_identity(record, censor)[:23]}{' [lost]' if record.get('is_lost') else ''}" for index, record in enumerate(records[:20])]


def detail_state(path, index, censor=False):
    records = load_state(path).get("records", [])
    if index < 0 or index >= len(records):
        return "No device selected"
    record = records[index]
    identity = short_identity(record, censor)
    mac = censor_mac(record.get("mac", "?")) if censor else record.get("mac", "?")
    lines = [identity, f"MAC: {mac}",
             "Transport: " + ", ".join(record.get("transports", [])),
             f"RSSI: {record.get('rssi', '?')} dBm  Ch: {record.get('channel', '?')}",
             f"Type: {UA_TYPES.get(record.get('ua_type'), 'Unknown')}",
             f"Status: {STATUS_TYPES.get(record.get('operational_status'), 'Unknown')}"]
    if record.get("has_location"):
        lines.append(f"Drone: {record['latitude_e7'] / 1e7:.7f}, {record['longitude_e7'] / 1e7:.7f}")
        if record.get("geo_altitude_valid"):
            lines.append(f"Altitude: {record['geo_altitude_m']:.1f} m")
        if "distance_m" in record:
            lines.append(f"Range: {record['distance_m']:.0f} m @ {record['bearing_deg']:.0f} deg")
    if record.get("operator_id"):
        operator_id = censor_identifier(record["operator_id"]) if censor else record["operator_id"]
        lines.append("Operator: " + operator_id)
    if record.get("has_operator_location"):
        lines.append(f"Operator pos: {record['operator_latitude_e7'] / 1e7:.7f}, {record['operator_longitude_e7'] / 1e7:.7f}")
    if record.get("description"):
        description = censor_name(record["description"]) if censor else record["description"]
        lines.append("Note: " + description)
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--interface", default="wlan1mon")
    parser.add_argument("--wifi-channel", type=int, choices=range(1, 14), default=6)
    parser.add_argument("--state", default="/tmp/remote-id-radar.json")
    parser.add_argument("--events", default="/tmp/remote-id-radar.jsonl")
    parser.add_argument("--csv", default="/tmp/remote-id-radar.csv")
    parser.add_argument("--gpx", default="/tmp/remote-id-radar.gpx")
    parser.add_argument("--render-state")
    parser.add_argument("--list-state")
    parser.add_argument("--detail-state")
    parser.add_argument("--index", type=int, default=0)
    parser.add_argument("--settings", default="/tmp/remote-id-radar-settings.json")
    parser.add_argument("--censor", action="store_true")
    parser.add_argument("--get-censor", action="store_true")
    parser.add_argument("--set-censor", choices=("on", "off"))
    args = parser.parse_args(argv)
    if args.run:
        return run_monitor(args)
    if args.render_state:
        print(render_state(args.render_state, args.censor))
        return 0
    if args.list_state:
        print("\n".join(list_state(args.list_state, args.censor)))
        return 0
    if args.detail_state:
        print(detail_state(args.detail_state, args.index, args.censor))
        return 0
    if args.get_censor:
        print("1" if load_censor_setting(args.settings) else "0")
        return 0
    if args.set_censor:
        save_censor_setting(args.settings, args.set_censor == "on")
        return 0
    parser.error("choose a run, state-rendering, or settings action")


if __name__ == "__main__":
    raise SystemExit(main())
