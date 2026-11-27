"""Bluetooth LE on the Pager, straight from the controller: Hak5's package feed has no D-Bus for Python.

A raw HCI socket turns on a passive-friendly LE scan and reads the advertising reports, giving the same
records BlueZ gives the CardputerZero. It never connects to or pairs with a device. If BlueZ is already
scanning, the reports are read all the same.
"""

import select
import socket
import struct

from quartermaster.wifi import ScanUnavailable

SOL_HCI, HCI_FILTER = 0, 2
HCI_COMMAND_PKT, HCI_EVENT_PKT = 0x01, 0x04
EVT_CMD_COMPLETE, EVT_CMD_STATUS, EVT_LE_META = 0x0E, 0x0F, 0x3E
LE_ADVERTISING_REPORT, LE_EXTENDED_REPORT = 0x02, 0x0D
SET_SCAN_PARAMETERS, SET_SCAN_ENABLE = 0x200B, 0x200C
BASE_UUID = "-0000-1000-8000-00805f9b34fb"
KEEP = 512


def uuid16(value):
    return "%08x%s" % (value, BASE_UUID)


def uuid128(raw):
    h = raw[::-1].hex()
    return "%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:])


def parse_ad(data):
    found = {"name": "", "uuids": [], "manufacturer": {}, "service_data": {}, "tx_power": None, "appearance": None}
    i = 0
    while i < len(data):
        size = data[i]
        if size == 0 or i + 1 + size > len(data):
            break
        kind, body = data[i + 1], bytes(data[i + 2:i + 1 + size])
        i += 1 + size
        if kind in (0x08, 0x09):
            name = body.decode("utf-8", "replace").strip("\x00")
            if kind == 0x09 or not found["name"]:
                found["name"] = name
        elif kind in (0x02, 0x03):
            found["uuids"] += [uuid16(v) for (v,) in struct.iter_unpack("<H", body[:len(body) // 2 * 2])]
        elif kind in (0x04, 0x05):
            found["uuids"] += [uuid16(v) for (v,) in struct.iter_unpack("<I", body[:len(body) // 4 * 4])]
        elif kind in (0x06, 0x07):
            found["uuids"] += [uuid128(body[j:j + 16]) for j in range(0, len(body) - 15, 16)]
        elif kind == 0x0A and body:
            found["tx_power"] = struct.unpack("b", body[:1])[0]
        elif kind == 0x16 and len(body) >= 2:
            found["service_data"][uuid16(struct.unpack("<H", body[:2])[0])] = body[2:]
        elif kind == 0x20 and len(body) >= 4:
            found["service_data"][uuid16(struct.unpack("<I", body[:4])[0])] = body[4:]
        elif kind == 0x21 and len(body) >= 16:
            found["service_data"][uuid128(body[:16])] = body[16:]
        elif kind == 0x19 and len(body) >= 2:
            found["appearance"] = struct.unpack("<H", body[:2])[0]
        elif kind == 0xFF and len(body) >= 2:
            found["manufacturer"][struct.unpack("<H", body[:2])[0]] = body[2:]
    return found


def address_text(raw):
    return ":".join("%02X" % b for b in raw[::-1])


def reports(packet):
    """(address, address type, rssi, advertising data) for each report in one HCI event packet."""
    if len(packet) < 4 or packet[0] != HCI_EVENT_PKT or packet[1] != EVT_LE_META:
        return []
    sub, body = packet[3], packet[4:]
    out = []
    if sub == LE_ADVERTISING_REPORT and body:
        i = 1
        for _ in range(body[0]):
            if i + 9 > len(body):
                break
            address_type, address = body[i + 1], bytes(body[i + 2:i + 8])
            size = body[i + 8]
            data = bytes(body[i + 9:i + 9 + size])
            if i + 9 + size >= len(body):
                break
            rssi = struct.unpack("b", body[i + 9 + size:i + 10 + size])[0]
            out.append((address, address_type, rssi, data))
            i += 10 + size
    elif sub == LE_EXTENDED_REPORT and body:
        i = 1
        for _ in range(body[0]):
            if i + 24 > len(body):
                break
            address_type, address = body[i + 2], bytes(body[i + 3:i + 9])
            rssi = struct.unpack("b", body[i + 13:i + 14])[0]
            size = body[i + 23]
            data = bytes(body[i + 24:i + 24 + size])
            out.append((address, address_type & 1, rssi, data))
            i += 24 + size
    return out


def command(opcode, params=b""):
    return struct.pack("<BHB", HCI_COMMAND_PKT, opcode, len(params)) + params


class HciBleScanner:
    name = "BLE"

    def __init__(self, device=0, opener=None):
        self.device = device
        self.opener = opener
        self.sock = None
        self.started = False
        self.seen = {}

    def open(self):
        try:
            if self.opener:
                sock = self.opener()
            else:
                sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
                sock.bind((self.device,))
                types = 1 << HCI_EVENT_PKT
                events = (1 << EVT_CMD_COMPLETE) | (1 << EVT_CMD_STATUS)
                mask = struct.pack("<IIIH", types, events, 1 << (EVT_LE_META - 32), 0)
                sock.setsockopt(SOL_HCI, HCI_FILTER, mask)
        except (OSError, AttributeError) as exc:
            raise ScanUnavailable("No Bluetooth radio (hci%d): %s" % (self.device, exc)) from exc
        sock.setblocking(False)
        try:
            sock.send(command(SET_SCAN_ENABLE, b"\x00\x00"))
            sock.send(command(SET_SCAN_PARAMETERS, struct.pack("<BHHBB", 1, 0x0030, 0x0030, 0, 0)))
            sock.send(command(SET_SCAN_ENABLE, b"\x01\x00"))
        except OSError as exc:
            sock.close()
            raise ScanUnavailable("Bluetooth refused the scan: %s" % exc) from exc
        self.sock, self.started = sock, True
        return self

    def read(self):
        while True:
            ready, _, _ = select.select([self.sock], [], [], 0)
            if not ready:
                return
            try:
                packet = self.sock.recv(300)
            except BlockingIOError:
                return
            except OSError as exc:
                self.close()
                raise ScanUnavailable("Bluetooth stopped: %s" % exc) from exc
            for address, address_type, rssi, data in reports(packet):
                if rssi == 127:
                    continue
                key = address_text(address)
                record = self.seen.get(key)
                ad = parse_ad(data)
                if record is None:
                    record = self.seen[key] = {"address": key, "address_type": address_type & 1, "name": "",
                                               "uuids": [], "manufacturer": {}, "service_data": {},
                                               "tx_power": None, "appearance": None, "classic": False}
                record["rssi"] = rssi
                record["name"] = ad["name"] or record["name"]
                record["uuids"] = sorted(set(record["uuids"]) | set(ad["uuids"]))
                record["manufacturer"].update(ad["manufacturer"])
                record["service_data"].update(ad["service_data"])
                for field in ("tx_power", "appearance"):
                    if ad[field] is not None:
                        record[field] = ad[field]

    def scan(self):
        if not self.started:
            self.open()
        self.read()
        seen, self.seen = list(self.seen.values()), {}
        return seen[-KEEP:]

    def close(self):
        if self.sock is not None:
            try:
                self.sock.send(command(SET_SCAN_ENABLE, b"\x00\x00"))
            except OSError:
                pass
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock, self.started = None, False
