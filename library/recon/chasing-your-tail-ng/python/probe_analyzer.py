#!/usr/bin/env python3
"""
probe_analyzer.py - Pineapple Pager Edition
Post-Processing: Analysiert gesammelte Probe-Daten mit optionaler WiGLE-API.
OpenWrt-Anpassungen:
  - urllib statt requests (stdlib, kein pip nötig)
  - Kein pandas (kein pip-compile auf MIPS)
  - Credentials aus config.json (kein cryptography-Paket)
  - Fallback auf urllib wenn requests nicht verfügbar
"""

import sqlite3
import json
import os
import sys
import logging
import argparse
import base64
import glob
from datetime import datetime, timedelta
from collections import defaultdict

# Requests oder urllib als Fallback
try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    import urllib.request
    import urllib.error
    HAS_REQUESTS = False
    logging.getLogger('CYT-Probe').warning(
        "'requests' nicht verfügbar - nutze urllib (stdlib)"
    )

log = logging.getLogger('CYT-Probe')

# ============================================================
# WIGLE API - kompatibel mit requests UND urllib
# ============================================================
class WiGLEClient:
    """Leichtgewichtiger WiGLE-API-Client ohne externe Abhängigkeiten."""

    BASE_URL = 'https://api.wigle.net/api/v2'

    def __init__(self, api_name, api_token):
        # Basic Auth aus API-Name und Token
        credentials = f'{api_name}:{api_token}'
        self.auth_header = 'Basic ' + base64.b64encode(
            credentials.encode()
        ).decode()
        self.enabled = bool(api_name and api_token)

    def search_ssid(self, ssid, lat_min=-90, lat_max=90,
                    lon_min=-180, lon_max=180, max_results=5):
        """Sucht SSID in WiGLE-Datenbank, gibt Standortliste zurück."""
        if not self.enabled:
            return []

        url = f'{self.BASE_URL}/network/search'
        params = {
            'ssid': ssid,
            'latrange1': lat_min,
            'latrange2': lat_max,
            'longrange1': lon_min,
            'longrange2': lon_max,
            'resultsPerPage': max_results
        }

        try:
            if HAS_REQUESTS:
                resp = requests.get(
                    url,
                    params=params,
                    headers={'Authorization': self.auth_header},
                    timeout=10
                )
                resp.raise_for_status()
                data = resp.json()
            else:
                # urllib Fallback
                param_str = '&'.join(f'{k}={v}' for k, v in params.items())
                full_url = f'{url}?{param_str}'
                req = urllib.request.Request(
                    full_url,
                    headers={'Authorization': self.auth_header}
                )
                with urllib.request.urlopen(req, timeout=10) as resp:
                    data = json.loads(resp.read().decode())

            results = data.get('results', [])
            locations = []
            for r in results:
                if r.get('trilat') and r.get('trilong'):
                    locations.append({
                        'ssid': r.get('ssid', ssid),
                        'bssid': r.get('netid', ''),
                        'lat': r['trilat'],
                        'lon': r['trilong'],
                        'lastupdt': r.get('lastupdt', ''),
                        'encryption': r.get('encryption', 'unknown')
                    })
            log.info(f"WiGLE: '{ssid}' → {len(locations)} Standorte")
            return locations

        except Exception as e:
            log.warning(f"WiGLE-Abfrage fehlgeschlagen für '{ssid}': {e}")
            return []

# ============================================================
# PROBE-DATEN AUS KISMET-LOGS LADEN
# ============================================================
def load_probe_data_from_kismet(db_path, days_back=14):
    """
    Lädt Probe-Request-Daten aus einer Kismet-Datenbank.
    Gibt {mac: {ssids, timestamps}} zurück.
    """
    if not os.path.exists(db_path):
        log.error(f"DB nicht gefunden: {db_path}")
        return {}

    cutoff = int((datetime.now() - timedelta(days=days_back)).timestamp())
    probe_data = defaultdict(lambda: {'ssids': set(), 'timestamps': []})

    try:
        conn = sqlite3.connect(db_path, timeout=10)
        cursor = conn.cursor()

        # Sichere Abfrage - kein SQL-Injection möglich
        cursor.execute("""
            SELECT devmac, device, first_time, last_time
            FROM devices
            WHERE last_time >= ?
              AND (phyname = '802.11' OR phyname LIKE '%WiFi%')
        """, (cutoff,))

        count = 0
        for row in cursor.fetchall():
            mac = str(row[0]).upper().strip()
            try:
                dev_json = json.loads(row[1])
                dot11 = dev_json.get('dot11.device', {})
                probe_map = dot11.get('dot11.device.probed_ssid_map', {})
                for ssid_entry in probe_map.values():
                    ssid = ssid_entry.get('dot11.probedssid.ssid', '').strip()
                    if ssid:
                        probe_data[mac]['ssids'].add(ssid)
                        count += 1
            except (json.JSONDecodeError, TypeError):
                pass
            probe_data[mac]['timestamps'].append(row[3])

        conn.close()
        log.info(f"Probe-Daten: {len(probe_data)} Geräte, {count} SSID-Probes")

    except sqlite3.Error as e:
        log.error(f"DB-Fehler: {e}")

    return probe_data

def load_probe_data_from_logs(log_dir, days_back=14):
    """
    Lädt Probe-Daten aus CYT-Log-Dateien (JSON-Format).
    Fallback wenn keine Kismet-DB vorhanden.
    """
    probe_data = defaultdict(lambda: {'ssids': set(), 'timestamps': []})
    cutoff = datetime.now() - timedelta(days=days_back)

    log_files = sorted(glob.glob(os.path.join(log_dir, '*.json')))
    loaded = 0

    for log_file in log_files:
        try:
            mtime = datetime.fromtimestamp(os.path.getmtime(log_file))
            if mtime < cutoff:
                continue
            with open(log_file) as f:
                data = json.load(f)
            devices = data.get('scored_devices', data.get('suspicious_devices', {}))
            for mac, dev_data in devices.items():
                probe_data[mac]['ssids'].update(dev_data.get('ssids', []))
            loaded += 1
        except Exception as e:
            log.warning(f"Log-Datei übersprungen ({log_file}): {e}")

    log.info(f"Probe-Daten aus {loaded} Log-Dateien geladen")
    return probe_data

# ============================================================
# ANALYSE & REPORT
# ============================================================
def analyze_probes(probe_data, wigle_client=None, config=None):
    """
    Analysiert Probe-Daten:
    - Häufigste Netzwerke
    - WiGLE-Geolocation für interessante SSIDs
    - Verdächtige Kombinationen
    """
    config = config or {}
    search_bounds = config.get('search', {
        'lat_min': -90, 'lat_max': 90,
        'lon_min': -180, 'lon_max': 180
    })

    # SSID-Häufigkeit über alle Geräte
    ssid_counter = defaultdict(set)  # ssid → {macs die danach suchen}
    for mac, data in probe_data.items():
        for ssid in data['ssids']:
            ssid_counter[ssid].add(mac)

    # Top-SSIDs (nach Anzahl suchender Geräte)
    top_ssids = sorted(ssid_counter.items(), key=lambda x: len(x[1]), reverse=True)[:20]

    log.info(f"Top-5 gesuchte SSIDs:")
    for ssid, macs in top_ssids[:5]:
        log.info(f"  '{ssid}': {len(macs)} Geräte suchen danach")

    # WiGLE-Abfragen für Top-SSIDs
    wigle_results = {}
    if wigle_client and wigle_client.enabled:
        log.info("Starte WiGLE-Abfragen (verbraucht API-Credits)...")
        for ssid, macs in top_ssids[:10]:  # Max 10 Abfragen
            locations = wigle_client.search_ssid(
                ssid,
                lat_min=search_bounds.get('lat_min', -90),
                lat_max=search_bounds.get('lat_max', 90),
                lon_min=search_bounds.get('lon_min', -180),
                lon_max=search_bounds.get('lon_max', 180)
            )
            if locations:
                wigle_results[ssid] = {
                    'locations': locations,
                    'searching_devices': list(macs)[:10]
                }

    return {
        'total_devices': len(probe_data),
        'total_unique_ssids': len(ssid_counter),
        'top_ssids': [(s, len(m)) for s, m in top_ssids],
        'wigle_results': wigle_results
    }

def save_probe_report(analysis, output_dir):
    """Speichert Probe-Analyse-Report."""
    os.makedirs(output_dir, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')

    # Markdown
    report_path = os.path.join(output_dir, f'probe_report_{ts}.md')
    with open(report_path, 'w') as f:
        f.write('# 📡 Probe-Analyse Report\n\n')
        f.write(f'**Datum:** {datetime.now().strftime("%d.%m.%Y %H:%M:%S")}  \n')
        f.write(f'**Geräte:** {analysis["total_devices"]}  \n')
        f.write(f'**Eindeutige SSIDs:** {analysis["total_unique_ssids"]}  \n\n')

        f.write('## Top gesuchte Netzwerke\n\n')
        f.write('| Rang | SSID | Anzahl Geräte |\n|------|------|---------------|\n')
        for i, (ssid, count) in enumerate(analysis['top_ssids'][:15], 1):
            f.write(f'| {i} | `{ssid}` | {count} |\n')

        if analysis.get('wigle_results'):
            f.write('\n## 🌍 WiGLE Geolocation-Ergebnisse\n\n')
            for ssid, data in analysis['wigle_results'].items():
                f.write(f'### `{ssid}`\n')
                f.write(f'Gefunden von {len(data["searching_devices"])} Gerät(en).  \n')
                for loc in data['locations'][:3]:
                    f.write(f'- 📍 {loc["lat"]:.4f}, {loc["lon"]:.4f} '
                            f'(Verschl.: {loc["encryption"]})\n')
                f.write('\n')

    log.info(f"Probe-Report: {report_path}")
    return report_path

# ============================================================
# MAIN
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description='CYT-NG Probe Analyzer - Pineapple Pager Edition'
    )
    parser.add_argument('--kismet-db', help='Kismet .kismet SQLite-DB')
    parser.add_argument('--days', type=int, default=14, help='Analysezeitraum in Tagen')
    parser.add_argument('--all-logs', action='store_true', help='Alle Logs analysieren')
    parser.add_argument('--wigle', action='store_true', help='WiGLE API nutzen')
    parser.add_argument('--config', default='config.json')
    parser.add_argument('--output-dir',
                        default='/root/loot/chasing_your_tail/reports')
    parser.add_argument('--log-file')
    args = parser.parse_args()

    # Logging
    handlers = [logging.StreamHandler()]
    if args.log_file:
        os.makedirs(os.path.dirname(args.log_file), exist_ok=True)
        handlers.append(logging.FileHandler(args.log_file))
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(levelname)s %(message)s',
        handlers=handlers
    )

    log.info(f"Probe Analyzer gestartet (Zeitraum: {args.days} Tage)")

    # Config
    config = {}
    if os.path.exists(args.config):
        with open(args.config) as f:
            config = json.load(f)

    # Probe-Daten laden
    days = 36500 if args.all_logs else args.days

    if args.kismet_db and os.path.exists(args.kismet_db):
        probe_data = load_probe_data_from_kismet(args.kismet_db, days)
    else:
        # Aus vorhandenen JSON-Logs laden
        log_dir = config.get('paths', {}).get('log_dir',
                                               '/root/loot/chasing_your_tail/logs')
        probe_data = load_probe_data_from_logs(log_dir, days)

    if not probe_data:
        log.warning("Keine Probe-Daten gefunden.")
        sys.exit(0)

    # WiGLE-Client
    wigle_client = None
    if args.wigle:
        wigle_cfg = config.get('wigle', {})
        api_name = wigle_cfg.get('api_name', '')
        api_token = wigle_cfg.get('api_token', '')
        if not api_name or not api_token:
            log.warning("WiGLE aktiviert, aber keine Credentials in config.json!")
            log.warning("Trage api_name und api_token in config.json ein.")
        else:
            wigle_client = WiGLEClient(api_name, api_token)
            log.info("WiGLE-Client initialisiert")

    # Analysieren
    analysis = analyze_probes(probe_data, wigle_client, config)

    # Report speichern
    save_probe_report(analysis, args.output_dir)

    log.info("Probe-Analyse abgeschlossen.")

if __name__ == '__main__':
    main()
