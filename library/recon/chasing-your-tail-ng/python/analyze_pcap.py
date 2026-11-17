#!/usr/bin/env python3
"""
analyze_pcap.py - Hauptanalyse auf Basis von PCAP-Dateien.
Nutzt pcap_engine.py für das Lesen, erstellt Reports.
"""
import os, sys, json, logging, argparse
from datetime import datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pcap_engine import read_pcap_probes, analyze_persistence
from oui_lookup import load_oui_db, lookup
from wigle_lookup import WiGLEClient, lookup_device, format_wigle_section, format_nearby_section
from suspects_db import SuspectsDB
from watch_list import WatchList

def is_locally_administered(mac):
    """Prüft ob MAC lokal administriert (gespooft/randomisiert) ist."""
    try:
        first_byte = int(mac.split(':')[0], 16)
        return bool(first_byte & 0x02)
    except Exception:
        return False

def mac_type(mac):
    """Gibt MAC-Typ zurück: 'lokal (gespooft?)' oder 'global'"""
    return '⚠ lokal/gespooft' if is_locally_administered(mac) else 'global'

log = logging.getLogger('CYT-Analyze')

def load_ignore_lists(config):
    """Lädt MAC und SSID Ignore-Listen aus config."""
    ignore_macs  = set()
    ignore_ssids = set()

    # Aus config.json Pfade lesen
    mac_file  = config.get('paths', {}).get('ignore_lists', {}).get(
        'mac',  '/root/loot/chasing_your_tail/ignore_lists/mac_list.json')
    ssid_file = config.get('paths', {}).get('ignore_lists', {}).get(
        'ssid', '/root/loot/chasing_your_tail/ignore_lists/ssid_list.json')

    if os.path.exists(mac_file):
        with open(mac_file) as f:
            data = json.load(f)
        ignore_macs = set(m.lower() for m in data.get('ignore_macs', []))
        log.info(f'Ignore-MACs geladen: {len(ignore_macs)}')

    if os.path.exists(ssid_file):
        with open(ssid_file) as f:
            data = json.load(f)
        ignore_ssids = set(s.lower() for s in data.get('ignore_ssids', []))
        log.info(f'Ignore-SSIDs geladen: {len(ignore_ssids)}')

    return ignore_macs, ignore_ssids

def filter_scans(scans, ignore_macs, ignore_ssids):
    """Entfernt ignorierte MACs und SSIDs aus allen Scans."""
    filtered = []
    total_removed = 0

    for scan in scans:
        clean = {}
        for mac, data in scan.items():
            # MAC prüfen
            if mac.lower() in ignore_macs:
                total_removed += 1
                continue

            # SSIDs filtern
            clean_ssids = {
                s for s in data.get('ssids', set())
                if s.lower() not in ignore_ssids
            }

            clean[mac] = {**data, 'ssids': clean_ssids}

        filtered.append(clean)

    if total_removed:
        log.info(f'{total_removed} Einträge durch Ignore-Liste gefiltert')

    return filtered

def _ensure_bt_fingerprinting(bt_devices, oui_db=None):
    """
    Wendet bt_fingerprint auf BT-Geräte an, falls noch nicht erfolgt.
    Gibt ein neues dict zurück (Original unverändert).
    """
    try:
        from bt_fingerprint import fingerprint_device
        from oui_lookup import lookup
    except ImportError:
        return bt_devices

    result = {}
    for mac, dev in bt_devices.items():
        d = dict(dev)
        if 'risk' not in d:
            vendor = lookup(mac, oui_db) if oui_db else ''
            fp = fingerprint_device(
                mac,
                name=d.get('name', ''),
                uuids=d.get('uuids', []),
                appearance_code=d.get('appearance'),
                oui_vendor=vendor,
            )
            d.update({
                'vendor':      vendor,
                'risk':        fp['risk'],
                'has_mic':     fp['has_mic'],
                'has_camera':  fp['has_camera'],
                'device_type': fp['device_type'],
                'fp_flags':    fp['flags'],
            })
        result[mac] = d
    return result


def save_report(scored, suspicious, output_dir, ignore_macs, bt_devices=None, oui_db=None, wigle_client=None, suspects_db=None, watch_list=None, cur_lat=None, cur_lon=None):
    os.makedirs(output_dir, exist_ok=True)
    ts   = datetime.now().strftime('%Y%m%d_%H%M%S')
    path = os.path.join(output_dir, f'cyt_report_{ts}.md')

    with open(path, 'w') as f:
        f.write('# Chasing Your Tail NG - Report\n\n')
        f.write(f'**Datum:** {datetime.now().strftime("%d.%m.%Y %H:%M:%S")}  \n')
        f.write(f'**Geräte gesamt:** {len(scored)}  \n')
        f.write(f'**Verdächtig:** {len(suspicious)}  \n')
        if ignore_macs:
            f.write(f'**Ignoriert:** {len(ignore_macs)} MACs  \n')
        f.write('\n')

        # Watch-List Alarme sammeln
        tracking_alarms = []
        static_alarms   = []
        watched_ok      = []
        if watch_list:
            for mac, d in scored.items():
                if watch_list.is_watched(mac):
                    result = watch_list.check(mac, cur_lat, cur_lon)
                    entry  = {'mac': mac, 'watch': result, 'data': d}
                    if result['status'] == 'dynamic_alarm':
                        tracking_alarms.append(entry)
                    elif result['status'] == 'static_alarm':
                        static_alarms.append(entry)
                    else:
                        watched_ok.append(entry)

        # 🔴 TRACKING ERKANNT
        if tracking_alarms:
            f.write('## 🔴 TRACKING ERKANNT - Dynamische Geräte\n\n')
            for e in tracking_alarms:
                mac    = e['mac']
                vendor = lookup(mac, oui_db) if oui_db else '?'
                label  = watch_list.get(mac).get('label', mac)
                f.write(f'### {label} (`{mac}`)\n')
                f.write(f'- **Hersteller:** {vendor}\n')
                f.write(f'- **Warnung:** {e["watch"]["message"]}\n\n')

        # ⚠ AUSSERHALB BEKANNTER ZONE
        if static_alarms:
            f.write('## ⚠️ AUSSERHALB BEKANNTER ZONE\n\n')
            for e in static_alarms:
                mac    = e['mac']
                vendor = lookup(mac, oui_db) if oui_db else '?'
                label  = watch_list.get(mac).get('label', mac)
                f.write(f'### {label} (`{mac}`)\n')
                f.write(f'- **Hersteller:** {vendor}\n')
                f.write(f'- **Warnung:** {e["watch"]["message"]}\n\n')

        # Verdächtige die nicht in Watch-List sind
        new_suspicious = {m: d for m, d in suspicious.items()
                         if not (watch_list and watch_list.is_watched(m))}

        if new_suspicious:
            f.write('## ⚠️ WARNING - Verdächtige Geräte\n\n')
            f.write('| MAC | Hersteller | Typ | Score | Appearances | Status |\n')
            f.write('|-----|------------|-----|-------|-------------|--------|\n')
            for mac, d in sorted(new_suspicious.items(),
                                 key=lambda x: x[1]['persistence_score'],
                                 reverse=True):
                vendor = lookup(mac, oui_db) if oui_db else '?'
                mtype  = mac_type(mac)
                # suspects_db ZUERST aktualisieren, dann Status lesen
                if suspects_db:
                    suspects_db.update(mac, vendor, mtype,
                                      d['persistence_score'],
                                      d.get('ssids', []),
                                      cur_lat, cur_lon)
                    entry = suspects_db.get(mac)
                    if entry['seen_count'] > 1:
                        known_flag = f'⚠ BEKANNT ({entry["seen_count"]}x)'
                    else:
                        known_flag = '🆕 NEU'
                else:
                    known_flag = '🆕 NEU'
                f.write(f'| `{mac}` | {vendor} | {mtype} | {d["persistence_score"]:.2f} | '
                        f'{d["appearances"]} | {known_flag} |\n')
                # WiGLE Lookup
                if wigle_client:
                    ssids = [s for s in d.get('ssids', []) if s and len(s) > 2]
                    wigle = lookup_device(mac, ssids, client=wigle_client)
                    wigle_text = format_wigle_section(wigle)
                    if wigle_text.strip():
                        f.write(wigle_text + '\n')
                    else:
                        f.write('\n**WiGLE:** Keine Treffer (Wildcard Probes)\n')
        elif not tracking_alarms and not static_alarms:
            f.write('## ✅ Keine verdächtigen Geräte erkannt\n\n')

        # 👁 Beobachtete Geräte (unauffällig)
        if watched_ok:
            f.write('\n## 👁 Beobachtete Geräte (unauffällig)\n\n')
            f.write('| MAC | Label | Status |\n')
            f.write('|-----|-------|--------|\n')
            for e in watched_ok:
                mac   = e['mac']
                label = watch_list.get(mac).get('label', mac)
                f.write(f'| `{mac}` | {label} | {e["watch"]["message"]} |\n')

        f.write('\n## Alle Geräte\n\n')
        f.write('| MAC | Hersteller | Typ | Score | Appearances | Fenster |\n')
        f.write('|-----|------------|-----|-------|-------------|--------|\n')
        for mac, d in sorted(scored.items(),
                             key=lambda x: x[1]['persistence_score'],
                             reverse=True):
            flag = '🔴' if d['suspicious'] else '🟢'
            vendor = lookup(mac, oui_db) if oui_db else '?'
            mtype  = mac_type(mac)
            f.write(f'| {flag} `{mac}` | {vendor} | {mtype} | {d["persistence_score"]:.2f} | '
                    f'{d["appearances"]} | '
                    f'{d["present_in_windows"]}/{d["total_windows"]} |\n')

        if ignore_macs:
            f.write('\n## Ignorierte Geräte\n\n')
            for mac in sorted(ignore_macs):
                f.write(f'- `{mac}`\n')

        if bt_devices:
            # Fingerprinting anwenden falls nicht schon im bt_scanner erfolgt
            bt_fingerprinted = _ensure_bt_fingerprinting(bt_devices, oui_db)

            # Eigene Geräte aus Ignore-Liste herausfiltern
            if ignore_macs:
                bt_fingerprinted = {
                    mac: d for mac, d in bt_fingerprinted.items()
                    if mac.lower() not in ignore_macs
                }

            # Kritische BT-Geräte (high/medium) separat hervorheben
            bt_critical = {
                mac: d for mac, d in bt_fingerprinted.items()
                if d.get('risk') in ('high', 'medium')
            }
            if bt_critical:
                f.write('\n## 🔴 Bluetooth Verdächtige (Fingerprint)\n\n')
                for mac, d in sorted(bt_critical.items(),
                                     key=lambda x: x[1].get('risk', ''),
                                     reverse=True):
                    emoji = {'high': '🔴', 'medium': '🟡'}.get(d.get('risk'), '⚪')
                    f.write(f'### {emoji} `{mac}` — {d.get("name","?")}\n')
                    f.write(f'- **Typ:** {d.get("device_type", "Unbekannt")}\n')
                    f.write(f'- **Hersteller:** {d.get("vendor", "Unbekannt")}\n')
                    f.write(f'- **Risiko:** {d.get("risk", "?")}\n')
                    if d.get('has_mic'):
                        f.write('- **🎤 Mikrofon:** ja\n')
                    if d.get('has_camera'):
                        f.write('- **📷 Kamera:** ja\n')
                    for flag in d.get('fp_flags', []):
                        f.write(f'- {flag}\n')
                    # WiFi-Korrelation
                    for wmac in suspicious:
                        if mac[:8].lower() == wmac[:8].lower():
                            f.write(f'- **⚠️ OUI-Korrelation WiFi:** `{wmac}`\n')
                            break
                        if mac.lower() == wmac.lower():
                            f.write(f'- **🔴 Exakt WiFi:** `{wmac}`\n')
                            break
                    if d.get('uuids'):
                        f.write(f'- **UUIDs:** {", ".join(d["uuids"])}\n')
                    f.write('\n')

            f.write('\n## Bluetooth Geräte\n\n')
            f.write('| MAC | Name | Typ | Risiko | Mic | Cam | WiFi-Korr. |\n')
            f.write('|-----|------|-----|--------|-----|-----|------------|\n')
            for mac, d in bt_fingerprinted.items():
                corr = '-'
                for wmac in suspicious:
                    if mac[:8].lower() == wmac[:8].lower():
                        corr = f'⚠️ `{wmac}`'
                        break
                    if mac.lower() == wmac.lower():
                        corr = f'🔴 `{wmac}`'
                        break
                risk_em = {'none': '🟢', 'low': '🔵', 'medium': '🟡',
                           'high': '🔴'}.get(d.get('risk', 'none'), '⚪')
                mic = '🎤' if d.get('has_mic') else '-'
                cam = '📷' if d.get('has_camera') else '-'
                f.write(f'| `{mac}` | {d.get("name","?")} | '
                        f'{d.get("device_type", d.get("type","?"))} | '
                        f'{risk_em} {d.get("risk","?")} | {mic} | {cam} | {corr} |\n')

    # WiGLE Nearby-Abgleich (nur wenn GPS + WiGLE verfügbar)
    if wigle_client and cur_lat and cur_lon and cur_lat != 0 and cur_lon != 0:
        try:
            nearby = wigle_client.search_nearby(cur_lat, cur_lon, radius_m=200)
            if nearby:
                nearby_section = format_nearby_section(
                    nearby, list(suspicious.keys()), cur_lat, cur_lon, radius_m=200
                )
                with open(path, 'a') as f:
                    f.write(nearby_section)
        except Exception as e:
            log.warning(f'WiGLE Nearby fehlgeschlagen: {e}')

    log.info(f'Report: {path}')
    print(f'REPORT_PATH:{path}')
    return path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pcaps', required=True)
    parser.add_argument('--config', default='config.json')
    parser.add_argument('--output-dir',
                        default='/root/loot/chasing_your_tail/surveillance_reports')
    parser.add_argument('--threshold', type=float, default=None)
    parser.add_argument('--min-appearances', type=int, default=None)
    parser.add_argument('--log-file')
    parser.add_argument('--bt-scans', default=None,
                        help='Kommagetrennte BT-Scan JSON-Dateien')
    args = parser.parse_args()

    handlers = [logging.StreamHandler()]
    if args.log_file:
        os.makedirs(os.path.dirname(args.log_file), exist_ok=True)
        handlers.append(logging.FileHandler(args.log_file))
    logging.basicConfig(level=logging.INFO,
                        format='[%(asctime)s] %(levelname)s %(message)s',
                        handlers=handlers)

    config = {}
    if os.path.exists(args.config):
        with open(args.config) as f:
            config = json.load(f)

    threshold = args.threshold or \
        config.get('surveillance', {}).get('persistence_threshold', 0.6)
    min_app = args.min_appearances or \
        config.get('surveillance', {}).get('min_appearances', 2)

    # OUI-Datenbank laden
    oui_db = load_oui_db()

    # WiGLE Client initialisieren
    wigle_client = None
    wigle_cfg = config.get('wigle', {})
    if wigle_cfg.get('enabled') and wigle_cfg.get('api_token'):
        wigle_client = WiGLEClient(wigle_cfg['api_name'], wigle_cfg['api_token'])
        log.info('WiGLE aktiviert')
    else:
        log.info('WiGLE deaktiviert')

    # BT-Scans laden
    bt_devices_all = {}
    if args.bt_scans:
        for bt_file in [f.strip() for f in args.bt_scans.split(',') if f.strip()]:
            if os.path.exists(bt_file):
                with open(bt_file) as f:
                    bt_data = json.load(f)
                bt_devices_all.update(bt_data.get('bt_devices', {}))
        log.info(f'BT-Geräte geladen: {len(bt_devices_all)}')

    # Ignore-Listen laden
    ignore_macs, ignore_ssids = load_ignore_lists(config)

    # PCAP-Dateien lesen
    pcap_files = [p.strip() for p in args.pcaps.split(',') if p.strip()]
    log.info(f'{len(pcap_files)} PCAP-Datei(en) werden analysiert')

    scans = [read_pcap_probes(p) for p in pcap_files]
    if not any(scans):
        log.warning('Keine Daten gefunden.')
        sys.exit(0)

    # Ignorierte Geräte herausfiltern
    scans = filter_scans(scans, ignore_macs, ignore_ssids)

    scored, suspicious = analyze_persistence(
        *scans, threshold=threshold, min_appearances=min_app
    )

    log.info(f'Geräte gesamt: {len(scored)} | Verdächtig: {len(suspicious)}')
    # SuspectsDB laden
    suspects_db_path = config.get('paths', {}).get(
        'suspects_db', '/root/loot/chasing_your_tail/suspects_db.json')
    suspects = SuspectsDB(suspects_db_path)

    # WatchList laden
    watch_list_path = config.get('paths', {}).get(
        'watch_list', '/root/loot/chasing_your_tail/watch_list.json')
    wl = WatchList(watch_list_path)

    # GPS-Koordinaten aus letztem GPS-Track lesen (falls vorhanden)
    cur_lat, cur_lon = None, None
    gps_track = config.get('paths', {}).get(
        'gps_track', '/root/loot/chasing_your_tail/gps_track.csv')
    if os.path.exists(gps_track):
        try:
            with open(gps_track) as f:
                lines = [l.strip() for l in f if l.strip()]
            if lines:
                last = lines[-1].split(',')
                cur_lat, cur_lon = float(last[1]), float(last[2])
                log.info(f'GPS: {cur_lat}, {cur_lon}')
        except Exception as e:
            log.warning(f'GPS-Track Lesefehler: {e}')

    save_report(scored, suspicious, args.output_dir, ignore_macs,
                bt_devices_all, oui_db, wigle_client,
                suspects, wl, cur_lat, cur_lon)
    sys.exit(2 if suspicious else 0)

if __name__ == '__main__':
    main()
