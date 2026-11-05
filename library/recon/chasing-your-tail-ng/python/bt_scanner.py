#!/usr/bin/env python3
"""
bt_scanner.py - Bluetooth Scanner für Chasing Your Tail NG
Scannt BT Classic + BLE Geräte und korreliert mit WiFi-Probes.
v4.4: BLE Advertisement Data (UUIDs, Appearance) via btmon + Fingerprinting.
v4.5: SDP-Abfrage für BT Classic Geräte (sdptool browse).
"""
import subprocess, threading, time, logging, os, json, re
from datetime import datetime

log = logging.getLogger('CYT-BT')

# ============================================================
# BLE ADVERTISEMENT DATA (btmon-basiert)
# ============================================================

def _scan_btmon(duration=20):
    """
    Lauscht auf BLE Advertisement Data via btmon.
    Extrahiert Service UUIDs, Appearance Code, Name und RSSI.
    Gibt {mac_lower: {name, uuids, appearance, rssi}} zurück.
    """
    adv_data = {}
    current  = None  # aktuelle MAC

    try:
        proc = subprocess.Popen(
            ['btmon', '-t'],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True
        )
    except FileNotFoundError:
        log.warning('btmon nicht gefunden – UUID-Scan übersprungen')
        return adv_data

    start = time.time()
    try:
        while time.time() - start < duration:
            line = proc.stdout.readline()
            if not line:
                break
            line = line.rstrip()

            # Neue Advertising-Report Adresse
            m = re.match(r'\s+Address:\s+([0-9A-Fa-f:]{17})', line)
            if m:
                current = m.group(1).lower()
                if current not in adv_data:
                    adv_data[current] = {
                        'name': '', 'uuids': [], 'appearance': None, 'rssi': None
                    }
                continue

            if current is None:
                continue

            # Gerätename
            m = re.match(r'\s+Name \((?:complete|short)\):\s+(.+)', line)
            if m:
                adv_data[current]['name'] = m.group(1).strip()
                continue

            # 16-bit Service UUIDs (btmon zeigt: Unknown (0xXXXX) oder Name (0xXXXX))
            m = re.search(r'\(0x([0-9a-fA-F]{4})\)', line)
            if m and ('UUID' in line or 'Service' in line or 'Unknown' in line):
                uuid = m.group(1).lower()
                if uuid not in adv_data[current]['uuids']:
                    adv_data[current]['uuids'].append(uuid)
                continue

            # Appearance
            m = re.match(r'\s+Appearance:\s+0x([0-9a-fA-F]+)', line)
            if m:
                adv_data[current]['appearance'] = int(m.group(1), 16)
                continue

            # RSSI
            m = re.match(r'\s+RSSI:\s+(-?\d+)\s+dBm', line)
            if m:
                adv_data[current]['rssi'] = int(m.group(1))

    except Exception as e:
        log.error(f'btmon Fehler: {e}')
    finally:
        proc.terminate()
        proc.wait()

    log.info(f'btmon: Advertisement Data für {len(adv_data)} BLE-Geräte gesammelt')
    return adv_data

# ============================================================
# SDP QUERY (BT Classic)
# ============================================================

def _sdp_query(mac, timeout=10):
    """
    Fragt Service UUIDs eines BT Classic Geräts via sdptool browse ab.
    Gibt Liste von UUID-Hex-Strings zurück (z.B. ['111e', '110b', '1108']).
    Gibt [] zurück wenn Gerät nicht erreichbar oder sdptool fehlt.
    """
    uuids = []
    try:
        result = subprocess.run(
            ['sdptool', 'browse', mac.upper()],
            capture_output=True, text=True, timeout=timeout
        )
        # Parst Zeilen wie: "Audio Sink" (0x110b)
        # oder: Unknown (0x111e)
        for line in result.stdout.splitlines():
            m = re.search(r'\(0x([0-9a-fA-F]{4})\)', line)
            if m:
                uuid = m.group(1).lower()
                if uuid not in uuids:
                    uuids.append(uuid)
        if uuids:
            log.info(f'SDP {mac}: {len(uuids)} UUIDs gefunden: {uuids}')
        else:
            log.debug(f'SDP {mac}: keine UUIDs (Gerät evtl. außer Reichweite)')
    except subprocess.TimeoutExpired:
        log.debug(f'SDP {mac}: Timeout nach {timeout}s')
    except FileNotFoundError:
        log.warning('sdptool nicht gefunden – SDP-Abfrage übersprungen')
    except Exception as e:
        log.debug(f'SDP {mac}: Fehler: {e}')
    return uuids


# ============================================================
# BLUETOOTH SCANNER
# ============================================================

def scan_bt_classic(duration=10):
    """Scannt BT Classic Geräte via hcitool scan."""
    devices = {}
    try:
        result = subprocess.run(
            ['hcitool', 'scan', '--flush'],
            capture_output=True, text=True, timeout=duration+5
        )
        for line in result.stdout.strip().split('\n'):
            line = line.strip()
            if not line or line == 'Scanning ...':
                continue
            parts = line.split('\t')
            if len(parts) >= 2:
                mac  = parts[0].strip().lower()
                name = parts[1].strip() if len(parts) > 1 else ''
                if len(mac) == 17:
                    devices[mac] = {
                        'name': name,
                        'type': 'classic',
                        'rssi': None,
                        'first_seen': datetime.now().isoformat(),
                    }
                    log.info(f'BT Classic: {mac} ({name})')
    except subprocess.TimeoutExpired:
        pass
    except Exception as e:
        log.error(f'BT Classic Fehler: {e}')
    return devices

def scan_ble(duration=15):
    """Scannt BLE Geräte via hcitool lescan."""
    devices = {}
    try:
        proc = subprocess.Popen(
            ['hcitool', 'lescan', '--duplicates'],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True
        )
        start = time.time()
        while time.time() - start < duration:
            line = proc.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line or line == 'LE Scan ...':
                continue
            parts = line.split(' ', 1)
            if len(parts) >= 1:
                mac  = parts[0].strip().lower()
                name = parts[1].strip() if len(parts) > 1 else ''
                if len(mac) == 17 and mac not in devices:
                    devices[mac] = {
                        'name': name,
                        'type': 'ble',
                        'rssi': None,
                        'first_seen': datetime.now().isoformat(),
                    }
                    log.info(f'BLE: {mac} ({name})')
        proc.terminate()
        proc.wait()
    except Exception as e:
        log.error(f'BLE Fehler: {e}')
    return devices

def scan_bluetooth(duration=15, with_fingerprint=True, oui_db=None):
    """
    Scannt BT Classic und BLE parallel.
    v4.4: Optional btmon für UUID/Appearance Fingerprinting.
    """
    log.info('Starte Bluetooth-Scan...')

    results = {'classic': {}, 'ble': {}, 'adv': {}}

    def run_classic():
        results['classic'] = scan_bt_classic(duration)

    def run_ble():
        results['ble'] = scan_ble(duration)

    def run_btmon():
        results['adv'] = _scan_btmon(duration)

    threads = [
        threading.Thread(target=run_classic, daemon=True),
        threading.Thread(target=run_ble,     daemon=True),
    ]
    if with_fingerprint:
        threads.append(threading.Thread(target=run_btmon, daemon=True))

    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=duration + 10)

    # Zusammenführen
    all_devices = {}
    all_devices.update(results['classic'])
    for mac, data in results['ble'].items():
        if mac not in all_devices:
            all_devices[mac] = data
        else:
            all_devices[mac]['type'] = 'classic+ble'

    # Advertisement-Daten einmergen (Name, UUIDs, Appearance, RSSI)
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

    # SDP-Abfrage für BT Classic Geräte ohne UUIDs (v4.5)
    if with_fingerprint:
        classic_macs = [
            mac for mac, dev in all_devices.items()
            if dev.get('type') in ('classic', 'classic+ble')
            and not dev.get('uuids')
        ]
        if classic_macs:
            log.info(f'SDP-Abfrage für {len(classic_macs)} Classic-Geräte...')
            for mac in classic_macs:
                sdp_uuids = _sdp_query(mac)
                if sdp_uuids:
                    all_devices[mac]['uuids'] = sdp_uuids
                    all_devices[mac]['sdp_queried'] = True

    # OUI-Lookup + Fingerprinting
    if with_fingerprint:
        _apply_fingerprinting(all_devices, oui_db)

    log.info(f'BT-Scan: {len(all_devices)} Geräte gefunden '
             f'({len(results["classic"])} Classic, {len(results["ble"])} BLE)')
    return all_devices


def _apply_fingerprinting(devices, oui_db=None):
    """Wendet bt_fingerprint auf alle Geräte an (in-place)."""
    try:
        import sys, os
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from bt_fingerprint import fingerprint_device
        from oui_lookup import lookup
    except ImportError as e:
        log.warning(f'Fingerprinting nicht verfügbar: {e}')
        return

    for mac, dev in devices.items():
        vendor = lookup(mac, oui_db) if oui_db else ''
        fp = fingerprint_device(
            mac,
            name=dev.get('name', ''),
            uuids=dev.get('uuids', []),
            appearance_code=dev.get('appearance'),
            oui_vendor=vendor,
        )
        dev['vendor']      = vendor
        dev['risk']        = fp['risk']
        dev['has_mic']     = fp['has_mic']
        dev['has_camera']  = fp['has_camera']
        dev['device_type'] = fp['device_type']
        dev['fp_flags']    = fp['flags']
        if fp['risk'] in ('medium', 'high'):
            log.info(f'BT Fingerprint [{fp["risk"]}] {mac} '
                     f'({dev.get("name","?")}): {", ".join(fp["flags"][:2])}')

# ============================================================
# KORRELATION WiFi <-> Bluetooth
# ============================================================

def correlate_wifi_bt(wifi_devices, bt_devices):
    """
    Korreliert WiFi-Probes mit Bluetooth-Geräten.

    Strategie:
    - Direkte MAC-Übereinstimmung (selten, da WiFi oft randomisiert)
    - OUI-Übereinstimmung (erste 3 Bytes) – gleicher Hersteller
    - Zeitliche Nähe (beide im gleichen Scan-Fenster gesehen)

    Returns:
        correlated: {mac: {wifi_data, bt_data, correlation_type}}
    """
    correlated   = {}
    wifi_oui_map = {mac[:8]: mac for mac in wifi_devices}
    bt_oui_map   = {mac[:8]: mac for mac in bt_devices}

    for bt_mac, bt_data in bt_devices.items():
        # 1. Direkte MAC-Übereinstimmung
        if bt_mac in wifi_devices:
            correlated[bt_mac] = {
                'bt':               bt_data,
                'wifi':             wifi_devices[bt_mac],
                'correlation_type': 'exact_mac',
                'confidence':       1.0,
            }
            log.info(f'Exakte Korrelation: {bt_mac} ({bt_data.get("name","")})')
            continue

        # 2. OUI-Übereinstimmung (gleicher Hersteller)
        bt_oui = bt_mac[:8]
        if bt_oui in wifi_oui_map:
            wifi_mac = wifi_oui_map[bt_oui]
            correlated[bt_mac] = {
                'bt':               bt_data,
                'wifi':             wifi_devices[wifi_mac],
                'wifi_mac':         wifi_mac,
                'correlation_type': 'oui_match',
                'confidence':       0.6,
            }
            log.info(f'OUI-Korrelation: BT {bt_mac} ↔ WiFi {wifi_mac}')

    return correlated

# ============================================================
# GPS
# ============================================================

def get_gps_position():
    """Liest GPS-Position via GPS_GET Pager-API."""
    try:
        result = subprocess.run(
            ['GPS_GET'], capture_output=True, text=True, timeout=5
        )
        parts = result.stdout.strip().split()
        if len(parts) >= 2:
            lat = float(parts[0])
            lon = float(parts[1])
            alt = float(parts[2]) if len(parts) > 2 else 0.0
            spd = float(parts[3]) if len(parts) > 3 else 0.0
            if lat != 0.0 or lon != 0.0:
                return {
                    'lat': lat, 'lon': lon,
                    'alt': alt, 'speed': spd,
                    'time': datetime.now().isoformat(),
                    'fix': True
                }
    except Exception as e:
        log.debug(f'GPS Fehler: {e}')
    return {'lat': 0, 'lon': 0, 'alt': 0, 'speed': 0,
            'time': datetime.now().isoformat(), 'fix': False}

def save_gps_track(gps_data, loot_dir):
    """Speichert GPS-Track als CSV."""
    track_file = os.path.join(loot_dir, 'gps_track.csv')
    write_header = not os.path.exists(track_file)

    with open(track_file, 'a') as f:
        if write_header:
            f.write('timestamp,latitude,longitude,altitude,speed,fix\n')
        f.write(f'{gps_data["time"]},'
                f'{gps_data["lat"]},'
                f'{gps_data["lon"]},'
                f'{gps_data["alt"]},'
                f'{gps_data["speed"]},'
                f'{gps_data["fix"]}\n')

def save_bt_scan(bt_devices, correlated, gps_data, output_path):
    """Speichert BT-Scan-Ergebnisse als JSON."""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    path = output_path

    with open(path, 'w') as f:
        json.dump({
            'timestamp':   datetime.now().isoformat(),
            'gps':         gps_data,
            'bt_devices':  bt_devices,
            'correlated':  correlated,
        }, f, indent=2, default=str)

    log.info(f'BT-Scan gespeichert: {path}')
    return path

# ============================================================
# MAIN (Test)
# ============================================================
if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--duration', type=int, default=15)
    parser.add_argument('--output',   default=None)
    parser.add_argument('--loot-dir', default='/root/loot/chasing_your_tail')
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(levelname)s %(message)s'
    )

    # GPS
    gps = get_gps_position()
    if gps['fix']:
        log.info(f'GPS: {gps["lat"]}, {gps["lon"]}')
        save_gps_track(gps, args.loot_dir)
    else:
        log.info('Kein GPS-Fix')

    # OUI-DB laden (optional, für BT OUI-Lookup)
    oui_db = None
    try:
        import sys as _sys, os as _os
        _sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
        from oui_lookup import load_oui_db
        oui_db = load_oui_db()
    except Exception:
        pass

    # BT scannen
    bt_devices = scan_bluetooth(duration=args.duration, oui_db=oui_db)

    # Korrelation
    correlated = correlate_wifi_bt({}, bt_devices)

    # Speichern
    if args.output:
        out = args.output  # direkt als Dateipfad verwenden
    else:
        os.makedirs(args.loot_dir, exist_ok=True)
        out = os.path.join(args.loot_dir,
            f'bt_scan_{datetime.now().strftime("%Y%m%d_%H%M%S")}.json')
    save_bt_scan(bt_devices, correlated, gps, out)

    print(f'\nGefunden: {len(bt_devices)} BT-Geräte')
    for mac, data in bt_devices.items():
        risk  = data.get('risk', '-')
        emoji = {'none': '🟢', 'low': '🔵', 'medium': '🟡', 'high': '🔴'}.get(risk, '⚪')
        mic   = '🎤' if data.get('has_mic') else ''
        cam   = '📷' if data.get('has_camera') else ''
        print(f'  {emoji} {mac} | {data.get("type","?"):10} | '
              f'{data.get("name","?"):20} | {data.get("device_type",""):20} '
              f'| {risk:6} {mic}{cam}')
