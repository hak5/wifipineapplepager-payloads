#!/usr/bin/env python3
"""
pcap_engine.py - Pineapple Pager Edition
Ersetzt Kismet-DB durch direktes PCAP-Lesen.
Nur Python stdlib - kein scapy, kein pyshark.
"""

import struct
import os
import json
import logging
from collections import defaultdict
from datetime import datetime

log = logging.getLogger('CYT-PCAP')

def read_pcap_probes(filepath):
    """
    Liest Probe-Requests direkt aus PCAP-Datei.
    Gibt {mac: {count, first_seen, last_seen, ssids}} zurück.
    """
    devices = defaultdict(lambda: {
        'count': 0,
        'first_seen': None,
        'last_seen': None,
        'ssids': set()
    })

    if not os.path.exists(filepath):
        log.error(f"PCAP nicht gefunden: {filepath}")
        return {}

    try:
        with open(filepath, 'rb') as f:
            # Global Header
            magic = f.read(4)
            if magic == b'\xd4\xc3\xb2\xa1':
                endian = '<'
            elif magic == b'\xa1\xb2\xc3\xd4':
                endian = '>'
            else:
                log.error("Ungültiges PCAP-Format")
                return {}

            f.read(20)  # Rest Global Header

            while True:
                hdr = f.read(16)
                if len(hdr) < 16:
                    break

                ts_sec, ts_usec, incl_len, orig_len = struct.unpack(
                    endian + 'IIII', hdr
                )
                data = f.read(incl_len)
                if len(data) < incl_len:
                    break

                # Radiotap Header überspringen
                if len(data) < 4:
                    continue
                rt_len = struct.unpack('<H', data[2:4])[0]
                dot11 = data[rt_len:]

                # Frame Control prüfen
                fc = dot11[0]
                # 0x40 = Probe Request, 0x50 = Probe Response
                if len(dot11) < 16:
                    continue

                if fc == 0x40:
                    # Probe Request - Source MAC
                    mac = ':'.join(f'{b:02x}' for b in dot11[10:16])
                elif fc == 0x50:
                    # Probe Response - Destination MAC (wer wird angesprochen)
                    mac = ':'.join(f'{b:02x}' for b in dot11[4:10])
                else:
                    continue

                # SSID aus Tagged Parameters
                # Probe Request:  Fixed Params = 4 Bytes  → tag_start = 24+4 = 28
                # Probe Response: Fixed Params = 12 Bytes → tag_start = 24+12 = 36
                ssid = ''
                tag_start = 36 if fc == 0x50 else 28
                if len(dot11) > tag_start + 2:
                    try:
                        # Alle Tags durchsuchen bis SSID (Tag 0) gefunden
                        pos = tag_start
                        while pos + 2 <= len(dot11):
                            tag_id  = dot11[pos]
                            tag_len = dot11[pos + 1]
                            if tag_id == 0 and tag_len > 0:
                                ssid_bytes = dot11[pos+2:pos+2+tag_len]
                                ssid = ssid_bytes.decode('utf-8', errors='ignore').strip()
                                break
                            pos += 2 + tag_len
                    except (IndexError, UnicodeDecodeError):
                        pass

                # Gerät speichern
                devices[mac]['count'] += 1
                if devices[mac]['first_seen'] is None:
                    devices[mac]['first_seen'] = ts_sec
                devices[mac]['last_seen'] = ts_sec
                # Binärmüll-SSIDs filtern
                if ssid and ssid.isprintable() and len(ssid) > 1:
                    devices[mac]['ssids'].add(ssid)

    except Exception as e:
        log.error(f"PCAP-Lesefehler: {e}")

    # Sets zu Listen
    result = {}
    for mac, data in devices.items():
        result[mac] = {
            'count': data['count'],
            'first_seen': data['first_seen'],
            'last_seen': data['last_seen'],
            'ssids': list(data['ssids']),
            'appearances': data['count']
        }

    log.info(f"PCAP gelesen: {len(result)} Geräte gefunden")
    return result


def _parse_radiotap_rssi(data):
    """
    Extrahiert RSSI (dBm Antenna Signal) aus Radiotap Header.
    Present-Flag Bit 5 = dBm Antenna Signal (1 Byte, signed).
    """
    if len(data) < 8:
        return None
    try:
        rt_len  = struct.unpack('<H', data[2:4])[0]
        present = struct.unpack('<I', data[4:8])[0]

        # Position nach present words (bit 31 = weiteres present word)
        pos = 8
        cur = present
        while cur & (1 << 31):
            if pos + 4 > len(data):
                return None
            cur  = struct.unpack('<I', data[pos:pos+4])[0]
            pos += 4

        # Felder laut original present-Wort
        # Bit 0: TSFT (8 Byte, align 8)
        if present & (1 << 0):
            pos = (pos + 7) & ~7
            pos += 8
        # Bit 1: FLAGS (1 Byte)
        if present & (1 << 1):
            pos += 1
        # Bit 2: RATE (1 Byte)
        if present & (1 << 2):
            pos += 1
        # Bit 3: CHANNEL (4 Byte, align 2)
        if present & (1 << 3):
            pos = (pos + 1) & ~1
            pos += 4
        # Bit 4: FHSS (2 Byte, align 2)
        if present & (1 << 4):
            pos = (pos + 1) & ~1
            pos += 2
        # Bit 5: dBm Antenna Signal (1 Byte, signed)
        if present & (1 << 5) and pos < len(data):
            return struct.unpack('b', data[pos:pos+1])[0]
    except Exception:
        pass
    return None


def read_pcap_beacons(filepath):
    """
    Liest Beacon Frames (FC=0x80) direkt aus PCAP-Datei.
    Gibt {bssid: {ssid, channel, rssi, beacon_count, hidden}} zurück.
    Für Hotel-Scan Modus 4.
    """
    beacons = defaultdict(lambda: {
        'ssid': '', 'channel': None, 'rssi': None,
        'beacon_count': 0, 'hidden': False
    })

    if not os.path.exists(filepath):
        log.error(f"PCAP nicht gefunden: {filepath}")
        return {}

    try:
        with open(filepath, 'rb') as f:
            magic = f.read(4)
            if magic == b'\xd4\xc3\xb2\xa1':
                endian = '<'
            elif magic == b'\xa1\xb2\xc3\xd4':
                endian = '>'
            else:
                log.error("Ungültiges PCAP-Format (Beacons)")
                return {}
            f.read(20)  # Rest Global Header

            while True:
                hdr = f.read(16)
                if len(hdr) < 16:
                    break
                ts_sec, ts_usec, incl_len, orig_len = struct.unpack(
                    endian + 'IIII', hdr
                )
                data = f.read(incl_len)
                if len(data) < incl_len:
                    break

                if len(data) < 4:
                    continue
                rt_len = struct.unpack('<H', data[2:4])[0]
                if rt_len >= len(data):
                    continue
                dot11 = data[rt_len:]

                if len(dot11) < 24:
                    continue

                # Frame Control: Beacon = 0x80
                fc = dot11[0]
                if fc != 0x80:
                    continue

                # BSSID = bytes 16:22
                bssid = ':'.join(f'{b:02x}' for b in dot11[16:22])

                # SSID + Channel aus Tagged Parameters
                # Beacon fixed params = 12 Bytes → Tags ab Offset 24+12=36
                ssid    = ''
                channel = None
                tag_start = 36
                if len(dot11) > tag_start + 2:
                    try:
                        pos = tag_start
                        while pos + 2 <= len(dot11):
                            tag_id  = dot11[pos]
                            tag_len = dot11[pos + 1]
                            if tag_id == 0:   # SSID
                                if tag_len == 0:
                                    pass  # hidden SSID
                                else:
                                    ssid_bytes = dot11[pos+2:pos+2+tag_len]
                                    ssid = ssid_bytes.decode('utf-8', errors='ignore').strip()
                            elif tag_id == 3 and tag_len == 1:  # DS Parameter Set
                                channel = dot11[pos + 2]
                            pos += 2 + tag_len
                    except (IndexError, UnicodeDecodeError):
                        pass

                # RSSI aus Radiotap
                rssi = _parse_radiotap_rssi(data[:rt_len])

                b = beacons[bssid]
                b['beacon_count'] += 1
                if ssid:
                    b['ssid'] = ssid
                elif b['beacon_count'] == 1:
                    b['hidden'] = True
                if channel is not None:
                    b['channel'] = channel
                if rssi is not None:
                    # Gleitender Durchschnitt
                    if b['rssi'] is None:
                        b['rssi'] = rssi
                    else:
                        b['rssi'] = (b['rssi'] + rssi) // 2

    except Exception as e:
        log.error(f"PCAP-Beacon-Lesefehler: {e}")

    result = dict(beacons)
    log.info(f"Beacon-Scan: {len(result)} BSSIDs gefunden")
    return result


def analyze_persistence(*scans, threshold=0.6, min_appearances=2):
    """
    Vergleicht mehrere Scans und berechnet Persistence-Score.
    Score = Anteil der Scans in dem das Gerät sichtbar war.
    """
    scans = [s for s in scans if s]
    all_macs = set()
    for scan in scans:
        all_macs.update(scan.keys())

    scored = {}
    for mac in all_macs:
        present = sum(1 for scan in scans if mac in scan)
        score = present / len(scans)
        total_appearances = sum(
            scan.get(mac, {}).get('count', 0) for scan in scans
        )
        all_ssids = set()
        for scan in scans:
            if mac in scan:
                all_ssids.update(scan[mac].get('ssids', []))

        if total_appearances >= min_appearances:
            scored[mac] = {
                'persistence_score': round(score, 3),
                'appearances': total_appearances,
                'present_in_windows': present,
                'total_windows': len(scans),
                'ssids': list(all_ssids),
                'suspicious': score >= threshold
            }

    suspicious = {m: d for m, d in scored.items() if d['suspicious']}
    return scored, suspicious
