#!/usr/bin/env python3
"""
chasing_your_tail.py - Pineapple Pager Edition
Kern-Engine: Liest Kismet SQLite-DB und erkennt wiederkehrende Probes.
OpenWrt-Anpassungen:
  - Kein tkinter / keine GUI
  - Kein cryptography-Paket (Fallback auf Klartext-Config)
  - sqlite3 aus stdlib (kein externes Paket nötig)
  - Logging statt print für Pager-Kompatibilität
"""

import sqlite3
import json
import os
import sys
import logging
import time
import argparse
from datetime import datetime, timedelta
from collections import defaultdict

# ============================================================
# LOGGING SETUP
# ============================================================
def setup_logging(log_file=None):
    handlers = [logging.StreamHandler(sys.stdout)]
    if log_file:
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        handlers.append(logging.FileHandler(log_file))
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] [%(levelname)s] %(message)s',
        datefmt='%H:%M:%S',
        handlers=handlers
    )
    return logging.getLogger('CYT')

log = logging.getLogger('CYT')

# ============================================================
# CONFIG LADEN
# ============================================================
def load_config(config_path):
    """Lädt config.json - ohne cryptography-Abhängigkeit."""
    default_config = {
        "paths": {
            "base_dir": "/root/loot/chasing_your_tail",
            "log_dir": "/root/loot/chasing_your_tail/logs",
            "kismet_logs": "/root/loot/chasing_your_tail/kismet_data/*.kismet",
            "ignore_lists": {
                "mac": "/root/loot/chasing_your_tail/ignore_lists/mac_list.json",
                "ssid": "/root/loot/chasing_your_tail/ignore_lists/ssid_list.json"
            }
        },
        "timing": {
            "check_interval": 60,
            "list_update_interval": 5,
            "time_windows": {"recent": 5, "medium": 10, "old": 15, "oldest": 20}
        },
        "surveillance": {
            "persistence_threshold": 0.6,
            "min_appearances": 3
        }
    }

    if config_path and os.path.exists(config_path):
        try:
            with open(config_path, 'r') as f:
                loaded = json.load(f)
            # Tief mergen
            def deep_merge(base, override):
                for k, v in override.items():
                    if k in base and isinstance(base[k], dict) and isinstance(v, dict):
                        deep_merge(base[k], v)
                    else:
                        base[k] = v
                return base
            return deep_merge(default_config, loaded)
        except Exception as e:
            log.warning(f"Config-Ladefehler ({e}), nutze Defaults.")
    return default_config

# ============================================================
# IGNORE-LISTEN LADEN
# ============================================================
def load_ignore_lists(config):
    """Lädt MAC- und SSID-Ignorier-Listen aus JSON."""
    ignore_macs = set()
    ignore_ssids = set()

    mac_path = config['paths']['ignore_lists'].get('mac', '')
    ssid_path = config['paths']['ignore_lists'].get('ssid', '')

    for path, target_set, key in [
        (mac_path, ignore_macs, 'ignore_macs'),
        (ssid_path, ignore_ssids, 'ignore_ssids')
    ]:
        if path and os.path.exists(path):
            try:
                with open(path, 'r') as f:
                    data = json.load(f)
                items = data.get(key, [])
                target_set.update(str(i).upper() for i in items)
                log.info(f"Ignore-Liste geladen: {len(items)} Einträge aus {path}")
            except Exception as e:
                log.warning(f"Ignore-Liste nicht ladbar ({path}): {e}")

    return ignore_macs, ignore_ssids

# ============================================================
# KISMET DB ABFRAGEN
# ============================================================
def query_kismet_db(db_path, time_window_minutes=20, ignore_macs=None, ignore_ssids=None):
    """
    Liest Probe-Requests aus der Kismet SQLite-Datenbank.
    Kismet-Schema: Tabelle 'devices', JSON im 'device'-Feld.
    Gibt Dict {mac: {ssids, timestamps, appearances}} zurück.
    """
    if not os.path.exists(db_path):
        log.error(f"Kismet-DB nicht gefunden: {db_path}")
        return {}

    ignore_macs = ignore_macs or set()
    ignore_ssids = ignore_ssids or set()

    cutoff = datetime.now() - timedelta(minutes=time_window_minutes)
    cutoff_ts = int(cutoff.timestamp())

    devices = defaultdict(lambda: {
        'ssids': set(),
        'timestamps': [],
        'appearances': 0,
        'first_seen': None,
        'last_seen': None
    })

    try:
        conn = sqlite3.connect(db_path, timeout=10)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        # Kismet speichert Geräte mit letztem_gesehen-Timestamp
        # Sichere Abfrage mit Parametern (kein SQL-Injection)
        cursor.execute("""
            SELECT devmac, phyname, strongest_signal,
                   first_time, last_time, device
            FROM devices
            WHERE last_time >= ?
              AND (phyname = '802.11' OR phyname LIKE '%WiFi%')
        """, (cutoff_ts,))

        rows = cursor.fetchall()
        log.info(f"Kismet-DB: {len(rows)} 802.11-Geräte im Zeitfenster ({time_window_minutes} Min.)")

        for row in rows:
            mac = str(row['devmac']).upper().strip()

            # MAC ignorieren?
            if mac in ignore_macs:
                continue

            # JSON-Device-Blob parsen für Probe-SSIDs
            probe_ssids = set()
            try:
                dev_json = json.loads(row['device'])
                # Kismet speichert Probes unter dot11.device > dot11.device.probed_ssid_map
                dot11 = dev_json.get('dot11.device', {})
                probe_map = dot11.get('dot11.device.probed_ssid_map', {})
                for ssid_entry in probe_map.values():
                    ssid = ssid_entry.get('dot11.probedssid.ssid', '')
                    if ssid and ssid.upper() not in ignore_ssids:
                        probe_ssids.add(ssid)
            except (json.JSONDecodeError, AttributeError, TypeError):
                pass

            first_t = row['first_time']
            last_t = row['last_time']

            devices[mac]['ssids'].update(probe_ssids)
            devices[mac]['timestamps'].append(last_t)
            devices[mac]['appearances'] += 1
            if devices[mac]['first_seen'] is None or first_t < devices[mac]['first_seen']:
                devices[mac]['first_seen'] = first_t
            if devices[mac]['last_seen'] is None or last_t > devices[mac]['last_seen']:
                devices[mac]['last_seen'] = last_t

        conn.close()

    except sqlite3.Error as e:
        log.error(f"SQLite-Fehler: {e}")
        return {}

    # Sets zu Listen für JSON-Serialisierbarkeit
    result = {}
    for mac, data in devices.items():
        result[mac] = {
            'ssids': list(data['ssids']),
            'appearances': data['appearances'],
            'first_seen': data['first_seen'],
            'last_seen': data['last_seen'],
            'timestamps': data['timestamps']
        }

    return result

# ============================================================
# ZEIT-FENSTER ANALYSE
# ============================================================
def analyze_time_windows(db_path, config, ignore_macs=None, ignore_ssids=None):
    """
    Analysiert Gerätepersistenz über vier Zeitfenster.
    Gibt Geräte mit Persistence-Score zurück.
    """
    windows = config.get('timing', {}).get('time_windows', {
        'recent': 5, 'medium': 10, 'old': 15, 'oldest': 20
    })

    # Geräte für jedes Zeitfenster abrufen
    window_data = {}
    for window_name, minutes in windows.items():
        window_data[window_name] = query_kismet_db(
            db_path, minutes, ignore_macs, ignore_ssids
        )
        log.info(f"Zeitfenster '{window_name}' ({minutes} Min.): "
                 f"{len(window_data[window_name])} Geräte")

    # Alle bekannten MACs sammeln
    all_macs = set()
    for data in window_data.values():
        all_macs.update(data.keys())

    log.info(f"Gesamt eindeutige Geräte: {len(all_macs)}")

    # Persistence-Score berechnen
    # Score = Anteil der Zeitfenster in denen das Gerät sichtbar war
    scored_devices = {}
    threshold = config.get('surveillance', {}).get('persistence_threshold', 0.6)
    min_appearances = config.get('surveillance', {}).get('min_appearances', 3)

    for mac in all_macs:
        present_in = sum(1 for wd in window_data.values() if mac in wd)
        score = present_in / len(windows)

        # Gesamtappearances aus dem größten Fenster
        oldest_data = window_data.get('oldest', {})
        mac_data = oldest_data.get(mac, {})
        appearances = mac_data.get('appearances', present_in)
        ssids = mac_data.get('ssids', [])

        if appearances >= min_appearances:
            scored_devices[mac] = {
                'persistence_score': round(score, 3),
                'appearances': appearances,
                'present_in_windows': present_in,
                'total_windows': len(windows),
                'ssids': ssids,
                'first_seen': mac_data.get('first_seen'),
                'last_seen': mac_data.get('last_seen'),
                'suspicious': score >= threshold
            }

    suspicious = {m: d for m, d in scored_devices.items() if d['suspicious']}
    log.info(f"Verdächtige Geräte (Score >= {threshold}): {len(suspicious)}")

    return scored_devices, suspicious

# ============================================================
# ERGEBNISSE SPEICHERN
# ============================================================
def save_results(scored_devices, suspicious, output_dir):
    """Speichert Ergebnisse als JSON und Markdown-Report."""
    os.makedirs(output_dir, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')

    # JSON-Export
    json_path = os.path.join(output_dir, f'cyt_results_{ts}.json')
    with open(json_path, 'w') as f:
        json.dump({
            'timestamp': datetime.now().isoformat(),
            'total_devices': len(scored_devices),
            'suspicious_count': len(suspicious),
            'scored_devices': scored_devices,
            'suspicious_devices': suspicious
        }, f, indent=2, default=str)
    log.info(f"JSON gespeichert: {json_path}")

    # Markdown-Report
    md_path = os.path.join(output_dir, f'cyt_report_{ts}.md')
    with open(md_path, 'w') as f:
        f.write(f"# Chasing Your Tail NG - Report\n\n")
        f.write(f"**Datum:** {datetime.now().strftime('%d.%m.%Y %H:%M:%S')}  \n")
        f.write(f"**Geräte gesamt:** {len(scored_devices)}  \n")
        f.write(f"**Verdächtig:** {len(suspicious)}  \n\n")

        if suspicious:
            f.write("## ⚠️ WARNING - Verdächtige Geräte\n\n")
            f.write("| MAC | Score | Appearances | SSIDs |\n")
            f.write("|-----|-------|-------------|-------|\n")
            for mac, data in sorted(suspicious.items(),
                                    key=lambda x: x[1]['persistence_score'],
                                    reverse=True):
                ssid_str = ', '.join(data['ssids'][:3]) or '(keine)'
                f.write(f"| `{mac}` | {data['persistence_score']:.2f} | "
                        f"{data['appearances']} | {ssid_str} |\n")
            f.write("\n")
        else:
            f.write("## ✅ Keine verdächtigen Geräte erkannt\n\n")

        f.write("## Alle Geräte nach Persistence-Score\n\n")
        f.write("| MAC | Score | Appearances | Fenster | SSIDs |\n")
        f.write("|-----|-------|-------------|---------|-------|\n")
        for mac, data in sorted(scored_devices.items(),
                                key=lambda x: x[1]['persistence_score'],
                                reverse=True):
            ssid_str = ', '.join(data['ssids'][:2]) or '-'
            flag = '🔴' if data['suspicious'] else '🟢'
            f.write(f"| {flag} `{mac}` | {data['persistence_score']:.2f} | "
                    f"{data['appearances']} | {data['present_in_windows']}/{data['total_windows']} "
                    f"| {ssid_str} |\n")

    log.info(f"Report gespeichert: {md_path}")
    return json_path, md_path

# ============================================================
# MAIN
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description='Chasing Your Tail NG - Pineapple Pager Edition'
    )
    parser.add_argument('--kismet-db', help='Pfad zur Kismet .kismet SQLite-DB')
    parser.add_argument('--config', default='config.json', help='Pfad zu config.json')
    parser.add_argument('--output-dir', default='/root/loot/chasing_your_tail/surveillance_reports',
                        help='Ausgabeverzeichnis für Reports')
    parser.add_argument('--log-file', help='Log-Datei Pfad')
    parser.add_argument('--days', type=int, default=1,
                        help='Analysezeitraum in Tagen (für Probe-Analyse)')
    args = parser.parse_args()

    # Logging initialisieren
    setup_logging(args.log_file)
    log.info("Chasing Your Tail NG - Pineapple Pager Edition gestartet")
    log.info("SECURE MODE: Parameterized SQL queries active")

    # Config laden
    config = load_config(args.config)

    # Ignore-Listen laden
    ignore_macs, ignore_ssids = load_ignore_lists(config)

    # Kismet-DB bestimmen
    db_path = args.kismet_db
    if not db_path:
        import glob
        pattern = config['paths'].get('kismet_logs', '')
        dbs = sorted(glob.glob(pattern))
        if dbs:
            db_path = dbs[-1]  # Neueste DB
            log.info(f"Neueste Kismet-DB: {db_path}")
        else:
            log.error("Keine Kismet-DB angegeben und keine gefunden!")
            sys.exit(1)

    # Analyse
    scored, suspicious = analyze_time_windows(db_path, config, ignore_macs, ignore_ssids)

    if not scored:
        log.warning("Keine Geräte analysiert - DB möglicherweise leer oder zu frisch.")
        sys.exit(0)

    # Ergebnisse speichern
    json_path, md_path = save_results(scored, suspicious, args.output_dir)

    # Exit-Code für payload.sh auswertbar
    if suspicious:
        log.warning(f"ALERT: {len(suspicious)} verdächtige Geräte erkannt!")
        sys.exit(2)  # Exit 2 = Warnung/Alert
    else:
        log.info("Keine verdächtigen Geräte. Alles normal.")
        sys.exit(0)

if __name__ == '__main__':
    main()