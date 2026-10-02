#!/usr/bin/env python3
"""
watchlist_add.py - CLI-Wrapper für WatchList.add()
Wird von payload.sh aufgerufen um Geräte zur Watch-List hinzuzufügen.
v4.5: GPS-Koordinaten nur in config.json auf dem Pager - NIEMALS ins Repo!
"""
import os
import sys
import json
import argparse
import logging

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from watch_list import WatchList

DEFAULT_CONFIG = '/root/payloads/user/reconnaissance/chasing_your_tail/config.json'


def _load_watch_config(config_path):
    """Lädt watch_list-Sektion aus config.json (nur auf dem Pager vorhanden)."""
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg.get('watch_list', {})
    except Exception:
        return {}


def main():
    parser = argparse.ArgumentParser(description='Gerät zur Watch-List hinzufügen')
    parser.add_argument('--mac',
                        required=False,
                        help='MAC-Adresse des Geräts')
    parser.add_argument('--label',
                        default='',
                        help='Bezeichnung / Hersteller')
    parser.add_argument('--type',
                        default='dynamic',
                        choices=['dynamic', 'static'],
                        help='dynamic=Tracking-Erkennung, static=Nur an bekanntem Ort')
    parser.add_argument('--notes',
                        default='',
                        help='Optionale Notizen')
    parser.add_argument('--lat',
                        type=float,
                        default=None,
                        help='GPS Latitude (aktueller Standort vom Gerät)')
    parser.add_argument('--lon',
                        type=float,
                        default=None,
                        help='GPS Longitude (aktueller Standort vom Gerät)')
    parser.add_argument('--zone',
                        default=None,
                        help='Zonenname (überschreibt config)')
    parser.add_argument('--zone-idx',
                        type=int,
                        default=None,
                        dest='zone_idx',
                        help='Zone aus config wählen (1-basiert; 0=ohne Zone)')
    parser.add_argument('--radius',
                        type=int,
                        default=None,
                        help='Zonen-Radius in Metern (Standard aus config)')
    parser.add_argument('--config',
                        default=DEFAULT_CONFIG,
                        help='Pfad zur config.json')
    parser.add_argument('--path',
                        default='/root/loot/chasing_your_tail/watch_list.json',
                        help='Pfad zur watch_list.json')
    parser.add_argument('--list-zones',
                        action='store_true',
                        dest='list_zones',
                        help='Bekannte Zonen aus config ausgeben, dann beenden')
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING)

    # config.json laden (GPS-Koordinaten nur auf dem Pager - NICHT im Repo!)
    wl_cfg         = _load_watch_config(args.config)
    known_zones    = wl_cfg.get('known_zones', [])
    default_radius = wl_cfg.get('default_zone_radius_m', 100)

    # --list-zones: Zonenliste für payload.sh ausgeben
    if args.list_zones:
        for z in known_zones:
            print(f'ZONE:{z["name"]}')
        print('ZONE:Aktueller GPS-Standort')
        sys.exit(0)

    if not args.mac:
        parser.error('--mac ist erforderlich')

    try:
        wl = WatchList(path=args.path)

        # Bereits in der Liste?
        if wl.is_watched(args.mac):
            existing = wl.get(args.mac)
            label    = existing.get('label', args.mac)
            wtype    = existing.get('type', '?')
            print(f'WATCHLIST:ALREADY_EXISTS:{label} ({wtype})')
            sys.exit(0)

        # Zonenkonfiguration auflösen
        zone_name   = args.zone or 'Aktueller GPS-Standort'
        zone_lat    = args.lat
        zone_lon    = args.lon
        zone_radius = args.radius or default_radius

        if args.type == 'static' and args.zone_idx is not None:
            if args.zone_idx == 0:
                # Ohne Zone - nur beobachten
                zone_name = 'Beobachtet'
                zone_lat  = None
                zone_lon  = None
            elif 1 <= args.zone_idx <= len(known_zones):
                # Konfigurierte Zone aus config.json verwenden
                # GPS-Koordinaten kommen aus config.json auf dem Pager (NICHT aus dem Repo!)
                z = known_zones[args.zone_idx - 1]
                zone_name   = z['name']
                zone_radius = z.get('radius_m', zone_radius)
                cfg_lat = z.get('lat', 0.0)
                cfg_lon = z.get('lon', 0.0)
                if cfg_lat != 0.0 or cfg_lon != 0.0:
                    # Echte Koordinaten aus config.json (nur auf Pager-Instanz)
                    zone_lat = cfg_lat
                    zone_lon = cfg_lon
                # Andernfalls: aktuellen GPS-Fix aus --lat/--lon nutzen
            # else: letzter Index (GPS-Option) → Defaults bleiben

        wl.add(
            mac       = args.mac,
            label     = args.label or args.mac,
            watch_type= args.type,
            notes     = args.notes,
            lat       = zone_lat,
            lon       = zone_lon,
            zone_name = zone_name,
            radius_m  = zone_radius,
        )
        print(f'WATCHLIST:OK:{args.type}:{zone_name}')

    except Exception as e:
        print(f'WATCHLIST:ERROR:{e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
