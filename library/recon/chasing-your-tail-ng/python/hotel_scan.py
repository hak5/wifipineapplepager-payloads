#!/usr/bin/env python3
"""
hotel_scan.py - Modus 4: Hotel-Scan für Chasing Your Tail NG v4.4
Erkennt versteckte Kameras und Überwachungsgeräte via:
  - WiFi Beacon Frame Analyse (Kamera-SSIDs, Kamera-OUIs)
  - BLE Advertisement Scan (IoT-UUIDs, Kamera-Appearance)
Nur Python stdlib. Kein scapy/pyshark.
"""
import os, sys, json, logging, argparse, re
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pcap_engine import read_pcap_beacons
from oui_lookup import load_oui_db, lookup
from bt_fingerprint import (
    fingerprint_device, risk_emoji, RISK_HIGH, RISK_MEDIUM, CAMERA_OUI_PREFIXES
)

log = logging.getLogger('CYT-Hotel')

# ============================================================
# KAMERA-SSID DATENBANK
# ============================================================

# Muster (lowercase) die auf Kamera/Überwachungsgeräte hinweisen
CAMERA_SSID_PATTERNS = [
    # Hersteller-spezifisch
    'hikvision', 'hik-', 'hik_',
    'dahua', 'dh-',
    'reolink',
    'wyze',
    'arlo',
    'ring-', 'ring_',
    'foscam',
    'eufy',
    'ezviz',
    'amcrest',
    'annke',
    'uniview',
    'axis',
    # Generisch
    'ipcam', 'ipcamera', 'ip_cam', 'ip-cam',
    'ipcam_', 'cam_', '-cam-',
    'cctv', 'nvr_', 'nvr-',
    'doorbell', 'door-bell', 'door_bell',
    # ESP32/IoT DIY Kameras
    'esp32', 'esp8266', 'esp_', 'esp-',
    'espcam', 'esp32cam',
    # Generische IoT-Präfixe (häufig bei Billig-Kameras)
    'xmeye', 'vstarcam', 'sricam', 'appcam', 'tplinkbaby',
]

# Bekannte versteckte SSID-Indikator-Hersteller (BSSID OUI → Kamera)
CAMERA_WIFI_OUIS = {
    '9c:b8:b5': 'Hikvision',
    'ac:cc:8e': 'Hikvision',
    'c8:02:10': 'Hikvision',
    'f0:9e:4a': 'Hikvision',
    'b4:a3:82': 'Hikvision',
    'd0:75:a7': 'Hikvision',
    '54:c4:15': 'Hikvision',
    'a0:e4:cb': 'Dahua',
    '70:6a:eb': 'Dahua',
    '7c:c2:c6': 'Reolink',
    'ec:71:db': 'Wyze',
    'a8:5b:4f': 'Wyze',
    '2c:aa:8e': 'Arlo',
    'e0:9a:d9': 'Arlo',
    '30:8c:fb': 'Eufy',
    '64:a2:f9': 'Ring',
    'b0:09:da': 'Ring',
    'c4:de:e2': 'Nest/Google',
    '18:b4:30': 'Nest/Google',
    # Espressif (häufig in DIY/Billig-IP-Kameras)
    '68:02:b8': 'Espressif (IoT)',
    '10:52:1c': 'Espressif (IoT)',
    'a4:cf:12': 'Espressif (IoT)',
    '24:0a:c4': 'Espressif (IoT)',
    'cc:50:e3': 'Espressif (IoT)',
    '84:f3:eb': 'Espressif (IoT)',
    'ec:fa:bc': 'Espressif (IoT)',
    '30:ae:a4': 'Espressif (IoT)',
    '24:6f:28': 'Espressif (IoT)',
    'c4:4f:33': 'Espressif (IoT)',
    '7c:df:a1': 'Espressif (IoT)',
    'b4:e6:2d': 'Espressif (IoT)',
    '08:3a:f2': 'Espressif (IoT)',
    'e8:68:e7': 'Espressif (IoT)',
    # Realtek IoT
    '00:00:6c': 'Realtek (IoT)',
    '00:e0:4c': 'Realtek (IoT)',
    # D-Link Kameras
    'd4:2b:4f': 'D-Link Camera',
    '1c:7e:e5': 'D-Link Camera',
    # TP-Link Kameras
    '90:72:40': 'TP-Link Camera',
    '50:c7:bf': 'TP-Link Camera',
    '54:af:97': 'TP-Link Camera',
    # Foscam
    'b0:be:76': 'Foscam',
    '00:26:61': 'Foscam',
    # Amcrest
    'b4:f1:e8': 'Amcrest',
}

# ============================================================
# WIFI BEACON ANALYSE
# ============================================================

def _merge_beacons(merged, new_beacons):
    """Fügt Beacons aus einem weiteren PCAP in das bestehende Dict zusammen."""
    for bssid, data in new_beacons.items():
        if bssid not in merged:
            merged[bssid] = dict(data)
        else:
            m = merged[bssid]
            if data['ssid'] and not m['ssid']:
                m['ssid'] = data['ssid']
            if data['channel'] is not None and m['channel'] is None:
                m['channel'] = data['channel']
            if data['rssi'] is not None:
                if m['rssi'] is None or data['rssi'] > m['rssi']:
                    m['rssi'] = data['rssi']
            m['beacon_count'] += data['beacon_count']
            if data['hidden']:
                m['hidden'] = True
    return merged


def _rssi_to_distance(rssi):
    """Grobe Schätzung: Entfernung in Metern aus RSSI."""
    if rssi is None:
        return '?'
    if rssi >= -50:
        return '<1m (sehr nah!)'
    elif rssi >= -65:
        return '~1-3m'
    elif rssi >= -75:
        return '~3-10m'
    elif rssi >= -85:
        return '~10-30m'
    else:
        return '>30m'


def analyze_beacons(beacons, oui_db=None):
    """
    Analysiert Beacon-Frame-Daten auf Kamera-Verdacht.
    Returns: list of suspect dicts, sorted by risk descending.
    """
    suspects = []

    for bssid, data in beacons.items():
        ssid    = data.get('ssid', '')
        hidden  = data.get('hidden', False)
        channel = data.get('channel')
        rssi    = data.get('rssi')
        count   = data.get('beacon_count', 0)

        risk    = 'none'
        reasons = []

        # 1. SSID-Muster prüfen
        ssid_lower = ssid.lower() if ssid else ''
        for pattern in CAMERA_SSID_PATTERNS:
            if pattern in ssid_lower:
                risk = RISK_HIGH
                reasons.append(f'📷 Kamera-SSID: "{ssid}" (Muster: {pattern})')
                break

        # 2. OUI-Lookup
        oui = bssid[:8]
        cam_vendor = CAMERA_WIFI_OUIS.get(oui)
        if cam_vendor:
            if risk != RISK_HIGH:
                risk = RISK_MEDIUM
            reasons.append(f'⚠ Kamera-Hersteller OUI: {cam_vendor}')

        # 3. IEEE OUI-Lookup (Espressif / Realtek = IoT-Hinweis)
        ieee_vendor = lookup(bssid, oui_db) if oui_db else 'Unbekannt'
        if ieee_vendor and any(v in ieee_vendor for v in ['Espressif', 'Realtek', 'MediaTek']):
            if risk != RISK_HIGH:
                risk = RISK_MEDIUM
            if not cam_vendor:
                reasons.append(f'⚠ IoT-Chip: {ieee_vendor}')

        # 4. Versteckte SSID = zusätzlicher Verdachtspunkt
        if hidden and count > 5:
            if risk == 'none':
                risk = 'low'
            reasons.append('⚠ Versteckte SSID (leerer Beacon)')

        if risk == 'none':
            continue

        suspects.append({
            'bssid':       bssid,
            'ssid':        ssid if ssid else '<versteckt>',
            'hidden':      hidden,
            'channel':     channel,
            'rssi':        rssi,
            'beacon_count': count,
            'risk':        risk,
            'reasons':     reasons,
            'vendor':      cam_vendor or ieee_vendor or 'Unbekannt',
            'distance_est': _rssi_to_distance(rssi),
        })

    suspects.sort(key=lambda x: [RISK_HIGH, RISK_MEDIUM, 'low', 'none'].index(x['risk']))
    return suspects


# ============================================================
# BLE SCAN (Hotel-Modus: länger, kamera-fokussiert)
# ============================================================

def scan_ble_hotel(duration=60, oui_db=None):
    """
    BLE Advertisement Scan für Hotel-Modus.
    Läuft länger (60s) und fokussiert auf Kamera/IoT-Fingerprinting.
    Returns: (all_devices, camera_suspects)
    """
    import subprocess, threading, time

    log.info(f'Hotel BLE-Scan ({duration}s)...')

    # bt_scanner Funktionen nutzen
    from bt_scanner import _scan_btmon, scan_ble, _apply_fingerprinting

    results = {'ble': {}, 'adv': {}}

    def run_ble():
        results['ble'] = scan_ble(duration)

    def run_btmon():
        results['adv'] = _scan_btmon(duration)

    t_ble   = threading.Thread(target=run_ble,   daemon=True)
    t_btmon = threading.Thread(target=run_btmon, daemon=True)
    t_ble.start()
    t_btmon.start()
    t_ble.join(timeout=duration + 5)
    t_btmon.join(timeout=duration + 5)

    all_devices = {}
    all_devices.update(results['ble'])
    for mac, adv in results['adv'].items():
        if mac not in all_devices:
            all_devices[mac] = {'type': 'ble', 'first_seen': datetime.now().isoformat()}
        dev = all_devices[mac]
        if adv['name'] and not dev.get('name'):
            dev['name'] = adv['name']
        dev['uuids']      = adv['uuids']
        dev['appearance'] = adv['appearance']
        if adv['rssi'] is not None:
            dev['rssi'] = adv['rssi']

    _apply_fingerprinting(all_devices, oui_db)

    # Kamera/High-Risk Geräte herausfiltern
    camera_suspects = {
        mac: dev for mac, dev in all_devices.items()
        if dev.get('risk') in (RISK_HIGH, RISK_MEDIUM)
        and (dev.get('has_camera') or dev.get('has_mic') or
             any('Kamera' in f or 'IoT' in f or 'Espressif' in f
                 for f in dev.get('fp_flags', [])))
    }

    log.info(f'BLE Hotel-Scan: {len(all_devices)} Geräte, '
             f'{len(camera_suspects)} Verdächtige')
    return all_devices, camera_suspects


# ============================================================
# REPORT
# ============================================================

def save_hotel_report(wifi_suspects, ble_all, ble_suspects, output_dir):
    """Generiert Hotel-Scan Report als Markdown."""
    os.makedirs(output_dir, exist_ok=True)
    ts   = datetime.now().strftime('%Y%m%d_%H%M%S')
    path = os.path.join(output_dir, f'hotel_scan_{ts}.md')

    total_suspects = len(wifi_suspects) + len(ble_suspects)

    with open(path, 'w') as f:
        f.write('# 🏨 Hotel-Scan Report - Chasing Your Tail NG v4.4\n\n')
        f.write(f'**Datum:** {datetime.now().strftime("%d.%m.%Y %H:%M:%S")}  \n')
        f.write(f'**WiFi Kamera-Verdächtige:** {len(wifi_suspects)}  \n')
        f.write(f'**BLE Kamera/IoT-Verdächtige:** {len(ble_suspects)}  \n')
        f.write(f'**BLE Geräte gesamt:** {len(ble_all)}  \n')
        f.write('\n')

        # === KRITISCHE FUNDE ===
        high_wifi = [s for s in wifi_suspects if s['risk'] == RISK_HIGH]
        high_ble  = {m: d for m, d in ble_suspects.items() if d.get('risk') == RISK_HIGH}

        if high_wifi or high_ble:
            f.write('## 🔴 KRITISCH - Mögliche versteckte Kameras!\n\n')
            if high_wifi:
                f.write('### WiFi Kameras\n\n')
                for s in high_wifi:
                    f.write(f'**{s["ssid"]}** (`{s["bssid"]}`)\n')
                    f.write(f'- Hersteller: {s["vendor"]}\n')
                    f.write(f'- Kanal: {s["channel"] or "?"} | '
                            f'RSSI: {s["rssi"] or "?"} dBm | '
                            f'Entfernung: ~{s["distance_est"]}\n')
                    f.write(f'- Beacons: {s["beacon_count"]}\n')
                    for r in s['reasons']:
                        f.write(f'- {r}\n')
                    f.write('\n')

            if high_ble:
                f.write('### BLE Kameras/IoT\n\n')
                for mac, dev in high_ble.items():
                    f.write(f'**{dev.get("name") or "?"}** (`{mac}`)\n')
                    f.write(f'- Typ: {dev.get("device_type", "Unbekannt")}\n')
                    f.write(f'- Hersteller: {dev.get("vendor", "Unbekannt")}\n')
                    f.write(f'- RSSI: {dev.get("rssi") or "?"} dBm | '
                            f'Entfernung: ~{_rssi_to_distance(dev.get("rssi"))}\n')
                    if dev.get('uuids'):
                        f.write(f'- UUIDs: {", ".join(dev["uuids"])}\n')
                    for flag in dev.get('fp_flags', []):
                        f.write(f'- {flag}\n')
                    f.write('\n')
        else:
            f.write('## ✅ Keine eindeutigen Kameras erkannt\n\n')

        # === MITTLERES RISIKO ===
        med_wifi = [s for s in wifi_suspects if s['risk'] == RISK_MEDIUM]
        med_ble  = {m: d for m, d in ble_suspects.items() if d.get('risk') == RISK_MEDIUM}

        if med_wifi or med_ble:
            f.write('## 🟡 Verdächtig - Nähere Prüfung empfohlen\n\n')

            if med_wifi:
                f.write('### WiFi (mittel)\n\n')
                f.write('| BSSID | SSID | Hersteller | RSSI | Entfernung | Kanal |\n')
                f.write('|-------|------|------------|------|------------|-------|\n')
                for s in med_wifi:
                    f.write(f'| `{s["bssid"]}` | {s["ssid"]} | {s["vendor"]} | '
                            f'{s["rssi"] or "?"} dBm | {s["distance_est"]} | '
                            f'{s["channel"] or "?"} |\n')
                f.write('\n')

            if med_ble:
                f.write('### BLE (mittel)\n\n')
                f.write('| MAC | Name | Typ | RSSI | Entfernung | Flags |\n')
                f.write('|-----|------|-----|------|------------|-------|\n')
                for mac, dev in med_ble.items():
                    flags_short = '; '.join(dev.get('fp_flags', [])[:2])
                    f.write(f'| `{mac}` | {dev.get("name","?")} | '
                            f'{dev.get("device_type","?")} | '
                            f'{dev.get("rssi") or "?"} dBm | '
                            f'{_rssi_to_distance(dev.get("rssi"))} | '
                            f'{flags_short} |\n')
                f.write('\n')

        # === ALLE BLE GERÄTE (Zusammenfassung) ===
        f.write('## Alle BLE Geräte\n\n')
        f.write('| MAC | Name | Typ | Risiko | RSSI |\n')
        f.write('|-----|------|-----|--------|------|\n')
        for mac, dev in sorted(
            ble_all.items(),
            key=lambda x: [RISK_HIGH, RISK_MEDIUM, 'low', 'none'].index(
                x[1].get('risk', 'none')
            )
        ):
            emoji = risk_emoji(dev.get('risk', 'none'))
            f.write(f'| {emoji} `{mac}` | {dev.get("name","?")} | '
                    f'{dev.get("device_type","?")} | {dev.get("risk","?")} | '
                    f'{dev.get("rssi") or "?"} dBm |\n')
        f.write('\n')

        # === ALLE WIFI BEACONS ===
        if wifi_suspects:
            f.write('## Alle WiFi Kamera-Verdächtige\n\n')
            f.write('| Risiko | BSSID | SSID | Hersteller | RSSI | Beacons |\n')
            f.write('|--------|-------|------|------------|------|--------|\n')
            for s in wifi_suspects:
                emoji = '🔴' if s['risk'] == RISK_HIGH else '🟡'
                f.write(f'| {emoji} | `{s["bssid"]}` | {s["ssid"]} | '
                        f'{s["vendor"]} | {s["rssi"] or "?"} dBm | '
                        f'{s["beacon_count"]} |\n')

    log.info(f'Hotel-Scan Report: {path}')
    print(f'REPORT_PATH:{path}')
    return path, total_suspects


# ============================================================
# MAIN
# ============================================================

def main():
    parser = argparse.ArgumentParser(description='Hotel-Scan: Kamera-Erkennung')
    parser.add_argument('--pcap',       required=True,
                        help='PCAP-Datei(en) mit Beacon Frames (kommagetrennt: 2.4GHz,5G)')
    parser.add_argument('--bt-scan',    default=None,
                        help='BT-Scan JSON (aus bt_scanner.py) oder "live"')
    parser.add_argument('--bt-duration', type=int, default=60,
                        help='BLE Scan-Dauer in Sekunden (bei --bt-scan live)')
    parser.add_argument('--output-dir',
                        default='/root/loot/chasing_your_tail/surveillance_reports')
    parser.add_argument('--log-file',   default=None)
    args = parser.parse_args()

    handlers = [logging.StreamHandler()]
    if args.log_file:
        os.makedirs(os.path.dirname(args.log_file), exist_ok=True)
        handlers.append(logging.FileHandler(args.log_file))
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(levelname)s %(message)s',
        handlers=handlers
    )

    # OUI-DB laden
    oui_db = load_oui_db()

    # Ignore-Liste laden
    ignore_macs = set()
    mac_list_path = '/root/loot/chasing_your_tail/ignore_lists/mac_list.json'
    try:
        with open(mac_list_path) as f:
            ignore_macs = set(m.lower() for m in json.load(f).get('ignore_macs', []))
        if ignore_macs:
            log.info(f'Ignore-MACs geladen: {len(ignore_macs)}')
    except Exception:
        pass

    # WiFi Beacon-Analyse (alle PCAP-Dateien zusammenführen)
    pcap_files = [p.strip() for p in args.pcap.split(',')
                  if p.strip() and os.path.exists(p.strip())]
    beacons = {}
    for pcap_path in pcap_files:
        log.info(f'Lese Beacon Frames: {pcap_path}')
        _merge_beacons(beacons, read_pcap_beacons(pcap_path))
    log.info(f'WiFi: {len(beacons)} BSSIDs aus {len(pcap_files)} PCAP(s)')
    wifi_suspects = [s for s in analyze_beacons(beacons, oui_db)
                     if s['bssid'].lower() not in ignore_macs]
    log.info(f'WiFi Verdächtige: {len(wifi_suspects)}')

    # BLE Scan
    ble_all      = {}
    ble_suspects = {}

    if args.bt_scan == 'live':
        ble_all, ble_suspects = scan_ble_hotel(
            duration=args.bt_duration, oui_db=oui_db
        )
    elif args.bt_scan and os.path.exists(args.bt_scan):
        with open(args.bt_scan) as f:
            bt_data = json.load(f)
        ble_all = bt_data.get('bt_devices', {})
        # Fingerprinting anwenden falls noch nicht erfolgt
        from bt_scanner import _apply_fingerprinting
        _apply_fingerprinting(ble_all, oui_db)
        ble_suspects = {
            mac: dev for mac, dev in ble_all.items()
            if dev.get('risk') in (RISK_HIGH, RISK_MEDIUM)
        }

    # Eigene Geräte aus Ignore-Liste entfernen
    if ignore_macs:
        ble_all      = {m: d for m, d in ble_all.items()
                        if m.lower() not in ignore_macs}
        ble_suspects = {m: d for m, d in ble_suspects.items()
                        if m.lower() not in ignore_macs}

    # Report generieren
    report_path, total = save_hotel_report(
        wifi_suspects, ble_all, ble_suspects, args.output_dir
    )

    log.info(f'Hotel-Scan abgeschlossen: {total} Verdächtige gefunden')
    sys.exit(2 if total > 0 else 0)


if __name__ == '__main__':
    main()
