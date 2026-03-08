#!/usr/bin/env python3
"""
surveillance_analyzer.py - Pineapple Pager Edition
GPS-Korrelation und KML-Visualisierung verdächtiger Geräte.
OpenWrt-Anpassungen:
  - kein tkinter
  - kein numpy/scipy (kein pip-compile auf MIPS)
  - GPS aus Kismet-DB (Bluetooth GPS via Kismet)
  - Einfaches KML ohne externe Bibliotheken (reines XML)
"""

import sqlite3
import json
import os
import sys
import logging
import argparse
import math
from datetime import datetime, timedelta
from collections import defaultdict
from xml.etree.ElementTree import Element, SubElement, tostring
from xml.dom import minidom

log = logging.getLogger('CYT-Surveillance')

# ============================================================
# GPS AUS KISMET DB EXTRAHIEREN
# ============================================================
def extract_gps_from_kismet(db_path):
    """
    Extrahiert GPS-Koordinaten aus der Kismet-Datenbank.
    Kismet speichert GPS-Punkte in der 'snapshots' oder 'packets' Tabelle.
    """
    gps_points = []

    if not os.path.exists(db_path):
        log.error(f"Kismet-DB nicht gefunden: {db_path}")
        return gps_points

    try:
        conn = sqlite3.connect(db_path, timeout=10)
        cursor = conn.cursor()

        # Tabellen prüfen (je nach Kismet-Version unterschiedlich)
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = {row[0] for row in cursor.fetchall()}
        log.info(f"Kismet-DB Tabellen: {tables}")

        # GPS aus 'snapshots'-Tabelle (neuere Kismet-Versionen)
        if 'snapshots' in tables:
            cursor.execute("""
                SELECT ts_sec, lat, lon, alt, speed
                FROM snapshots
                WHERE lat != 0 AND lon != 0
                ORDER BY ts_sec
            """)
            for row in cursor.fetchall():
                gps_points.append({
                    'timestamp': row[0],
                    'lat': row[1],
                    'lon': row[2],
                    'alt': row[3] or 0,
                    'speed': row[4] or 0
                })

        # GPS aus 'packets'-Tabelle als Fallback
        elif 'packets' in tables:
            cursor.execute("""
                SELECT ts_sec, lat, lon, alt
                FROM packets
                WHERE lat IS NOT NULL AND lat != 0
                  AND lon IS NOT NULL AND lon != 0
                ORDER BY ts_sec
            """)
            for row in cursor.fetchall():
                gps_points.append({
                    'timestamp': row[0],
                    'lat': row[1],
                    'lon': row[2],
                    'alt': row[3] or 0,
                    'speed': 0
                })

        conn.close()
        log.info(f"GPS-Punkte extrahiert: {len(gps_points)}")

    except sqlite3.Error as e:
        log.error(f"GPS-Extraktion fehlgeschlagen: {e}")

    return gps_points

# ============================================================
# LOCATION CLUSTERING (ohne numpy - reines Python)
# ============================================================
def haversine_distance(lat1, lon1, lat2, lon2):
    """Berechnet Distanz in Metern zwischen zwei GPS-Punkten."""
    R = 6371000  # Erdradius in Metern
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi/2)**2 + math.cos(phi1)*math.cos(phi2)*math.sin(dlambda/2)**2
    return 2 * R * math.asin(math.sqrt(a))

def cluster_locations(gps_points, threshold_meters=100):
    """
    Einfaches Radius-Clustering ohne numpy.
    Gruppert GPS-Punkte die < threshold_meters auseinander liegen.
    """
    if not gps_points:
        return []

    clusters = []
    used = [False] * len(gps_points)

    for i, p in enumerate(gps_points):
        if used[i]:
            continue
        cluster = [p]
        used[i] = True
        for j, q in enumerate(gps_points):
            if used[j]:
                continue
            dist = haversine_distance(p['lat'], p['lon'], q['lat'], q['lon'])
            if dist <= threshold_meters:
                cluster.append(q)
                used[j] = True
        # Cluster-Zentrum berechnen
        center_lat = sum(pt['lat'] for pt in cluster) / len(cluster)
        center_lon = sum(pt['lon'] for pt in cluster) / len(cluster)
        clusters.append({
            'lat': center_lat,
            'lon': center_lon,
            'point_count': len(cluster),
            'start_time': min(pt['timestamp'] for pt in cluster),
            'end_time': max(pt['timestamp'] for pt in cluster),
            'points': cluster
        })

    log.info(f"GPS-Cluster: {len(gps_points)} Punkte → {len(clusters)} Cluster")
    return clusters

# ============================================================
# GERÄT-ZU-LOCATION KORRELATION
# ============================================================
def correlate_devices_to_locations(suspicious_devices, gps_clusters, db_path):
    """
    Verknüpft verdächtige Geräte mit GPS-Clustern anhand von Zeitstempeln.
    """
    if not gps_clusters or not suspicious_devices:
        return suspicious_devices

    # Geräte-Timestamps aus DB laden
    try:
        conn = sqlite3.connect(db_path, timeout=10)
        cursor = conn.cursor()

        for mac, data in suspicious_devices.items():
            mac_clean = mac.replace(':', '').upper()
            # Zeitstempel des Geräts
            first_ts = data.get('first_seen', 0) or 0
            last_ts = data.get('last_seen', 0) or 0

            # Passende Cluster finden (zeitliche Überschneidung)
            matched_clusters = []
            for cluster in gps_clusters:
                c_start = cluster['start_time']
                c_end = cluster['end_time']
                # Zeitliche Überschneidung prüfen
                if first_ts <= c_end and last_ts >= c_start:
                    matched_clusters.append({
                        'lat': cluster['lat'],
                        'lon': cluster['lon'],
                        'point_count': cluster['point_count']
                    })

            if matched_clusters:
                data['gps_locations'] = matched_clusters
                data['location_count'] = len(matched_clusters)
                log.info(f"Gerät {mac} an {len(matched_clusters)} Standort(en) gesehen")

        conn.close()

    except sqlite3.Error as e:
        log.warning(f"Geräte-Location-Korrelation fehlgeschlagen: {e}")

    return suspicious_devices

# ============================================================
# KML GENERIERUNG (reines XML, keine externe Lib)
# ============================================================
def generate_kml(suspicious_devices, gps_clusters, output_path):
    """
    Erstellt professionelle KML-Datei für Google Earth.
    Farbkodierung nach Persistence-Score.
    """
    kml = Element('kml', xmlns='http://www.opengis.net/kml/2.2')
    doc = SubElement(kml, 'Document')
    SubElement(doc, 'name').text = f'CYT-Surveillance-{datetime.now().strftime("%Y%m%d_%H%M%S")}'
    SubElement(doc, 'description').text = 'Chasing Your Tail NG - Surveillance Analysis'

    # Styles definieren
    for style_id, color, scale in [
        ('red_marker', 'ff0000ff', '1.2'),    # Hoch verdächtig (AABBGGRR)
        ('amber_marker', 'ff00aaff', '1.0'),   # Mittel
        ('green_marker', 'ff00ff00', '0.8'),   # Niedrig
        ('gps_line', 'ff00ffff', '1.0'),       # GPS-Pfad
    ]:
        style = SubElement(doc, 'Style', id=style_id)
        if 'line' in style_id:
            line = SubElement(style, 'LineStyle')
            SubElement(line, 'color').text = color
            SubElement(line, 'width').text = '3'
        else:
            icon_style = SubElement(style, 'IconStyle')
            SubElement(icon_style, 'color').text = color
            SubElement(icon_style, 'scale').text = scale
            icon = SubElement(icon_style, 'Icon')
            SubElement(icon, 'href').text = \
                'http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png'

    # GPS-Pfad Folder
    if gps_clusters and len(gps_clusters) > 1:
        gps_folder = SubElement(doc, 'Folder')
        SubElement(gps_folder, 'name').text = '📍 GPS-Pfad'

        pm = SubElement(gps_folder, 'Placemark')
        SubElement(pm, 'name').text = 'Bewegungspfad'
        SubElement(pm, 'styleUrl').text = '#gps_line'
        ls = SubElement(pm, 'LineString')
        SubElement(ls, 'altitudeMode').text = 'clampToGround'
        coords = ' '.join(
            f"{c['lon']},{c['lat']},0" for c in gps_clusters
        )
        SubElement(ls, 'coordinates').text = coords

    # Verdächtige Geräte Folder
    if suspicious_devices:
        sus_folder = SubElement(doc, 'Folder')
        SubElement(sus_folder, 'name').text = '⚠️ Verdächtige Geräte'

        for mac, data in sorted(suspicious_devices.items(),
                                key=lambda x: x[1]['persistence_score'],
                                reverse=True):
            score = data['persistence_score']

            # Style nach Score
            if score >= 0.8:
                style_url = '#red_marker'
                level = 'HOCH'
            elif score >= 0.6:
                style_url = '#amber_marker'
                level = 'MITTEL'
            else:
                style_url = '#green_marker'
                level = 'NIEDRIG'

            # Pro GPS-Standort ein Marker
            locations = data.get('gps_locations', [])
            if not locations and gps_clusters:
                # Ersten Cluster als Fallback
                locations = [{'lat': gps_clusters[0]['lat'],
                              'lon': gps_clusters[0]['lon']}]

            for i, loc in enumerate(locations):
                pm = SubElement(sus_folder, 'Placemark')
                SubElement(pm, 'name').text = f'{mac} [{level}]'
                SubElement(pm, 'styleUrl').text = style_url

                desc_lines = [
                    f'MAC: {mac}',
                    f'Persistence-Score: {score:.2f}',
                    f'Verdächtigkeitslevel: {level}',
                    f'Appearances: {data["appearances"]}',
                    f'SSIDs: {", ".join(data.get("ssids", [])[:5]) or "keine"}',
                    f'Standort {i+1} von {len(locations)}'
                ]
                SubElement(pm, 'description').text = '\n'.join(desc_lines)

                point = SubElement(pm, 'Point')
                SubElement(point, 'coordinates').text = f'{loc["lon"]},{loc["lat"]},0'

    # KML schreiben
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    rough_string = tostring(kml, encoding='unicode')
    reparsed = minidom.parseString(rough_string)
    pretty = reparsed.toprettyxml(indent='  ', encoding='UTF-8')

    with open(output_path, 'wb') as f:
        f.write(pretty)

    log.info(f"KML gespeichert: {output_path}")
    return output_path

# ============================================================
# SURVEILLANCE REPORT
# ============================================================
def generate_surveillance_report(suspicious_devices, gps_clusters, output_dir):
    """Erstellt detaillierten Markdown-Surveillance-Report."""
    os.makedirs(output_dir, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    report_path = os.path.join(output_dir, f'surveillance_report_{ts}.md')

    with open(report_path, 'w') as f:
        f.write('# 🔍 Chasing Your Tail NG - Surveillance Report\n\n')
        f.write(f'**Erstellt:** {datetime.now().strftime("%d.%m.%Y %H:%M:%S")}  \n')
        f.write(f'**GPS-Cluster:** {len(gps_clusters)}  \n')
        f.write(f'**Verdächtige Geräte:** {len(suspicious_devices)}  \n\n')

        if suspicious_devices:
            f.write('---\n\n')
            f.write('## ⚠️ WARNING - Surveillance Detection Alert\n\n')
            f.write('Folgende Geräte haben verdächtige Persistenz-Muster gezeigt:\n\n')

            for mac, data in sorted(suspicious_devices.items(),
                                    key=lambda x: x[1]['persistence_score'],
                                    reverse=True):
                score = data['persistence_score']
                level = 'HOCH 🔴' if score >= 0.8 else 'MITTEL 🟡' if score >= 0.6 else 'NIEDRIG 🟢'

                f.write(f'### `{mac}`\n\n')
                f.write(f'| Eigenschaft | Wert |\n|------------|------|\n')
                f.write(f'| Persistence-Score | {score:.3f} |\n')
                f.write(f'| Verdächtigkeitslevel | {level} |\n')
                f.write(f'| Anzahl Appearances | {data["appearances"]} |\n')
                f.write(f'| Zeitfenster | {data["present_in_windows"]}/{data["total_windows"]} |\n')
                ssids = ', '.join(data.get('ssids', [])[:5]) or 'keine'
                f.write(f'| Gesuchte SSIDs | {ssids} |\n')

                if data.get('gps_locations'):
                    f.write(f'| GPS-Standorte | {len(data["gps_locations"])} |\n')

                f.write('\n')
        else:
            f.write('## ✅ Keine Auffälligkeiten\n\n')
            f.write('Keine Geräte mit verdächtiger Persistenz erkannt.\n\n')

        if gps_clusters:
            f.write('---\n\n')
            f.write('## 📍 GPS-Standorte\n\n')
            for i, cluster in enumerate(gps_clusters, 1):
                start = datetime.fromtimestamp(cluster['start_time']).strftime('%H:%M:%S')
                end = datetime.fromtimestamp(cluster['end_time']).strftime('%H:%M:%S')
                f.write(f'**Standort {i}:** {cluster["lat"]:.6f}, {cluster["lon"]:.6f} '
                        f'({cluster["point_count"]} GPS-Punkte, {start}–{end})\n\n')

    log.info(f"Surveillance-Report: {report_path}")
    return report_path

# ============================================================
# MAIN
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description='CYT-NG Surveillance Analyzer - Pineapple Pager Edition'
    )
    parser.add_argument('--kismet-db', required=True, help='Kismet .kismet SQLite-DB')
    parser.add_argument('--config', default='config.json')
    parser.add_argument('--output-dir',
                        default='/root/loot/chasing_your_tail/surveillance_reports')
    parser.add_argument('--kml-dir',
                        default='/root/loot/chasing_your_tail/kml_files')
    parser.add_argument('--log-file', help='Log-Datei')
    parser.add_argument('--demo', action='store_true',
                        help='Demo-Modus mit simulierten GPS-Koordinaten')
    parser.add_argument('--stalking-only', action='store_true',
                        help='Nur Hochrisiko-Geräte ausgeben')
    parser.add_argument('--min-persistence', type=float, default=0.6,
                        help='Minimaler Persistence-Score (0.0-1.0)')
    parser.add_argument('--output-json', help='Ergebnis-JSON Pfad')
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

    log.info("Surveillance Analyzer gestartet")

    # Config laden
    config = {}
    if os.path.exists(args.config):
        with open(args.config) as f:
            config = json.load(f)

    # Min-Persistence aus Args überschreiben
    if 'surveillance' not in config:
        config['surveillance'] = {}
    config['surveillance']['persistence_threshold'] = args.min_persistence

    # Ignore-Listen
    ignore_macs, ignore_ssids = set(), set()

    # Haupt-Analyse importieren
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from chasing_your_tail import analyze_time_windows

    log.info(f"Analysiere: {args.kismet_db}")
    scored, suspicious = analyze_time_windows(
        args.kismet_db, config, ignore_macs, ignore_ssids
    )

    if args.stalking_only:
        suspicious = {m: d for m, d in suspicious.items()
                      if d['persistence_score'] >= 0.8}

    # GPS extrahieren
    if args.demo:
        # Demo: Simulierte GPS-Koordinaten (Berlin Mitte als Beispiel)
        log.info("Demo-Modus: Simulierte GPS-Daten")
        gps_points = [
            {'timestamp': 1700000000 + i*60, 'lat': 52.520 + i*0.001,
             'lon': 13.405 + i*0.001, 'alt': 35, 'speed': 5}
            for i in range(10)
        ]
    else:
        gps_points = extract_gps_from_kismet(args.kismet_db)

    # Location Clustering
    gps_clusters = cluster_locations(gps_points, threshold_meters=100)

    # Geräte mit Standorten korrelieren
    if suspicious and gps_clusters:
        suspicious = correlate_devices_to_locations(
            suspicious, gps_clusters, args.kismet_db
        )

    # Reports erstellen
    report_path = generate_surveillance_report(suspicious, gps_clusters, args.output_dir)

    # KML erstellen (auch ohne GPS sinnvoll wenn nur Geräte-Liste)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    kml_path = os.path.join(args.kml_dir, f'surveillance_{ts}.kml')
    if suspicious or gps_clusters:
        generate_kml(suspicious, gps_clusters, kml_path)

    # Optional: JSON-Export
    if args.output_json:
        with open(args.output_json, 'w') as f:
            json.dump({
                'timestamp': datetime.now().isoformat(),
                'suspicious': suspicious,
                'gps_clusters': len(gps_clusters),
                'total_scored': len(scored)
            }, f, indent=2, default=str)

    log.info(f"Report: {report_path}")
    log.info(f"KML: {kml_path}")

    sys.exit(2 if suspicious else 0)

if __name__ == '__main__':
    main()
