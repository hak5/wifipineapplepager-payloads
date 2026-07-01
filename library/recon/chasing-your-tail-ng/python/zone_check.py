#!/usr/bin/env python3
"""
zone_check.py - Standort-Zone erkennen (GPS oder IP-Geolokalisierung)

Ausgabe (stdout, eine Zeile):
  ZONE_GPS:<name>:<dist_m>            - Zone per GPS erkannt (innerhalb Radius)
  ZONE_IP:<name>:<dist_m>:<city>      - Zone per IP erkannt (innerhalb Radius)
  ZONE_IP_NEAR:<name>:<dist_m>:<city> - IP nah an Zone, aber außerhalb Radius
  ZONE_NONE                           - Kein bekannter Standort / kein Netz
  ZONE_ERROR:<msg>                    - Konfigurationsfehler
"""
import json
import sys
import math
import argparse
import logging
import urllib.request

logging.basicConfig(level=logging.WARNING)
log = logging.getLogger(__name__)

DEFAULT_CONFIG = '/root/payloads/user/reconnaissance/chasing_your_tail/config.json'


def haversine(lat1, lon1, lat2, lon2):
    R = 6371000
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def load_zones(config_path):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        wl = cfg.get('watch_list', {})
        default_radius = wl.get('default_zone_radius_m', 100)
        zones = wl.get('known_zones', [])
        for z in zones:
            if 'radius_m' not in z:
                z['radius_m'] = default_radius
        # Nur Zonen mit echten GPS-Koordinaten
        return [z for z in zones if not (z.get('lat', 0) == 0 and z.get('lon', 0) == 0)]
    except Exception as e:
        print(f'ZONE_ERROR:{e}')
        sys.exit(0)


def find_nearest(zones, lat, lon):
    """
    Gibt (in_radius, nearest) zurück:
      in_radius = (name, dist_m) wenn innerhalb Zone-Radius, sonst None
      nearest   = (name, dist_m) nächste Zone unabhängig von Radius, oder None
    """
    in_radius = None
    nearest = None
    for z in zones:
        dist = haversine(lat, lon, z['lat'], z['lon'])
        if dist <= z.get('radius_m', 100):
            if in_radius is None or dist < in_radius[1]:
                in_radius = (z['name'], int(dist))
        if nearest is None or dist < nearest[1]:
            nearest = (z['name'], int(dist))
    return in_radius, nearest


def ip_geolocate():
    """Gibt (lat, lon, city) via ip-api.com zurück oder None bei Fehler."""
    try:
        req = urllib.request.Request(
            'http://ip-api.com/json/?fields=status,lat,lon,city',
            headers={'User-Agent': 'ChasingYourTail/4.5'}
        )
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.loads(r.read().decode())
        if data.get('status') == 'success':
            return float(data['lat']), float(data['lon']), data.get('city', '')
    except Exception as e:
        log.debug(f'IP-Geo Fehler: {e}')
    return None


def main():
    p = argparse.ArgumentParser(description='Standort-Zone erkennen')
    p.add_argument('--config', default=DEFAULT_CONFIG)
    p.add_argument('--lat', type=float, default=None, help='GPS Latitude')
    p.add_argument('--lon', type=float, default=None, help='GPS Longitude')
    args = p.parse_args()

    zones = load_zones(args.config)
    if not zones:
        # Keine echten GPS-Koordinaten in config.json → Zonen nicht nutzbar
        print('ZONE_NONE')
        return

    # 1. GPS-basierte Prüfung
    if args.lat is not None and args.lon is not None:
        in_radius, _ = find_nearest(zones, args.lat, args.lon)
        if in_radius:
            print(f'ZONE_GPS:{in_radius[0]}:{in_radius[1]}')
        else:
            print('ZONE_NONE')
        return

    # 2. IP-basierte Prüfung (kein GPS-Fix)
    geo = ip_geolocate()
    if geo:
        ip_lat, ip_lon, city = geo
        in_radius, nearest = find_nearest(zones, ip_lat, ip_lon)
        if in_radius:
            print(f'ZONE_IP:{in_radius[0]}:{in_radius[1]}:{city}')
            return
        # Nächste Zone innerhalb 5 km → als Hinweis ausgeben
        if nearest and nearest[1] < 5000:
            print(f'ZONE_IP_NEAR:{nearest[0]}:{nearest[1]}:{city}')
            return

    print('ZONE_NONE')


if __name__ == '__main__':
    main()
