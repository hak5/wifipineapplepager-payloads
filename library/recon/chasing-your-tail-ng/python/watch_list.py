"""
watch_list.py - Beobachtungsliste mit statischer/dynamischer Erkennung
STATIC:  Gerät nur an bekanntem Ort erwartet (Nachbar, Hotel, Arbeit)
DYNAMIC: Gerät folgt mir = Tracking!
"""
import json
import os
import math
import logging
from datetime import datetime

log = logging.getLogger(__name__)

DEFAULT_PATH = '/root/loot/chasing_your_tail/watch_list.json'

def haversine(lat1, lon1, lat2, lon2):
    """Abstand in Metern zwischen zwei GPS-Koordinaten"""
    R = 6371000
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi/2)**2 + math.cos(phi1)*math.cos(phi2)*math.sin(dlam/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

class WatchList:
    def __init__(self, path=DEFAULT_PATH):
        self.path = path
        self.devices = self._load()

    def _load(self):
        if os.path.exists(self.path):
            try:
                with open(self.path) as f:
                    data = json.load(f)
                devices = data.get('watched_devices', {})
                log.info(f'WatchList: {len(devices)} Geräte geladen')
                return devices
            except Exception as e:
                log.warning(f'WatchList Ladefehler: {e}')
        return {}

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, 'w') as f:
            json.dump({'watched_devices': self.devices}, f, indent=2)

    def is_watched(self, mac):
        return mac in self.devices

    def get(self, mac):
        return self.devices.get(mac)

    def add(self, mac, label, watch_type, notes='', lat=None, lon=None, zone_name=None, radius_m=100):
        """Gerät zur Watch-List hinzufügen"""
        ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        entry = {
            'mac': mac,
            'label': label,
            'type': watch_type,  # 'static' oder 'dynamic'
            'first_seen': ts,
            'notes': notes,
            'seen_locations': []
        }
        if watch_type == 'static' and lat and lon:
            entry['known_locations'] = [{
                'name': zone_name or 'Unbekannte Zone',
                'lat': lat,
                'lon': lon,
                'radius_m': radius_m
            }]
        else:
            entry['known_locations'] = []

        self.devices[mac] = entry
        self.save()
        log.info(f'WatchList: {mac} hinzugefügt als {watch_type} - {label}')
        return entry

    def check(self, mac, cur_lat=None, cur_lon=None):
        """
        Prüft Gerät gegen Watch-List.
        Gibt zurück: dict mit status, alert, message
        Status: 'static_ok', 'static_alarm', 'dynamic_ok', 'dynamic_alarm', 'not_watched'
        """
        if mac not in self.devices:
            return {'status': 'not_watched', 'alert': False, 'message': ''}

        entry = self.devices[mac]
        watch_type = entry.get('type', 'dynamic')
        label = entry.get('label', mac)

        # Standort speichern
        if cur_lat and cur_lon:
            ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            entry['seen_locations'].append({
                'ts': ts, 'lat': cur_lat, 'lon': cur_lon
            })
            self.save()

        if watch_type == 'static':
            return self._check_static(entry, label, cur_lat, cur_lon)
        else:
            return self._check_dynamic(entry, label, cur_lat, cur_lon)

    def _check_static(self, entry, label, cur_lat, cur_lon):
        """Statisches Gerät - nur an bekanntem Ort erwartet"""
        known = entry.get('known_locations', [])

        # Kein GPS verfügbar - kann nicht prüfen
        if not cur_lat or not cur_lon:
            return {
                'status': 'static_ok',
                'alert': False,
                'message': f'{label}: Bekanntes Gerät (kein GPS-Check)'
            }

        # Keine bekannten Zonen definiert
        if not known:
            return {
                'status': 'static_ok',
                'alert': False,
                'message': f'{label}: Beobachtet (keine Zone definiert)'
            }

        # In einer bekannten Zone?
        for zone in known:
            dist = haversine(cur_lat, cur_lon, zone['lat'], zone['lon'])
            if dist <= zone.get('radius_m', 100):
                return {
                    'status': 'static_ok',
                    'alert': False,
                    'message': f'{label}: In Zone "{zone["name"]}" ({dist:.0f}m)'
                }

        # Außerhalb aller bekannten Zonen!
        zone_names = ', '.join(z['name'] for z in known)
        return {
            'status': 'static_alarm',
            'alert': True,
            'message': f'{label}: AUSSERHALB bekannter Zone! (erwartet: {zone_names})'
        }

    def _check_dynamic(self, entry, label, cur_lat, cur_lon):
        """Dynamisches Gerät - Tracking-Erkennung"""
        locations = entry.get('seen_locations', [])

        # Weniger als 2 verschiedene Orte - noch unauffällig
        if len(locations) < 2:
            return {
                'status': 'dynamic_ok',
                'alert': False,
                'message': f'{label}: Beobachtet (1 Standort)'
            }

        # Verschiedene Orte prüfen - min. 500m Abstand = neuer Ort
        unique_locations = [locations[0]]
        for loc in locations[1:]:
            is_new = True
            for known_loc in unique_locations:
                dist = haversine(loc['lat'], loc['lon'],
                               known_loc['lat'], known_loc['lon'])
                if dist < 500:
                    is_new = False
                    break
            if is_new:
                unique_locations.append(loc)

        if len(unique_locations) >= 2:
            return {
                'status': 'dynamic_alarm',
                'alert': True,
                'message': f'{label}: TRACKING ERKANNT! An {len(unique_locations)} verschiedenen Orten gesehen!'
            }

        return {
            'status': 'dynamic_ok',
            'alert': False,
            'message': f'{label}: Beobachtet ({len(locations)} Sichtungen, 1 Ort)'
        }

    def get_all_alerts(self, cur_lat=None, cur_lon=None):
        """Alle Watch-List Einträge prüfen und Alarme zurückgeben"""
        results = {}
        for mac in self.devices:
            results[mac] = self.check(mac, cur_lat, cur_lon)
        return results
