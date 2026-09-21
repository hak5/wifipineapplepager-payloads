"""
suspects_db.py - Persistente Verdächtige-Datenbank
Speichert verdächtige Geräte über mehrere Scans hinweg.
"""
import json
import os
import logging
from datetime import datetime

log = logging.getLogger(__name__)

DEFAULT_PATH = '/root/loot/chasing_your_tail/suspects_db.json'

class SuspectsDB:
    def __init__(self, path=DEFAULT_PATH):
        self.path = path
        self.db = self._load()

    def _load(self):
        if os.path.exists(self.path):
            try:
                with open(self.path) as f:
                    data = json.load(f)
                log.info(f'SuspectsDB: {len(data)} bekannte Verdächtige geladen')
                return data
            except Exception as e:
                log.warning(f'SuspectsDB Ladefehler: {e}')
        return {}

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, 'w') as f:
            json.dump(self.db, f, indent=2)

    def is_known(self, mac):
        return mac in self.db

    def get(self, mac):
        return self.db.get(mac)

    def update(self, mac, vendor, mac_type, score, ssids=None, lat=None, lon=None):
        ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        if mac not in self.db:
            self.db[mac] = {
                'mac': mac,
                'vendor': vendor,
                'type': mac_type,
                'first_seen': ts,
                'last_seen': ts,
                'seen_count': 1,
                'max_score': score,
                'ssids': list(ssids or []),
                'locations': []
            }
            log.info(f'SuspectsDB: NEU {mac} ({vendor})')
        else:
            entry = self.db[mac]
            entry['last_seen'] = ts
            entry['seen_count'] += 1
            entry['max_score'] = max(entry['max_score'], score)
            for s in (ssids or []):
                if s not in entry['ssids']:
                    entry['ssids'].append(s)
            log.info(f'SuspectsDB: UPDATE {mac} - gesehen {entry["seen_count"]}x')

        if lat and lon:
            self.db[mac]['locations'].append({
                'ts': ts, 'lat': lat, 'lon': lon
            })

        self.save()
        return self.db[mac]

    def was_seen_before(self, mac):
        entry = self.db.get(mac)
        if not entry:
            return False
        return entry['seen_count'] > 1

    def summary(self):
        return {'total': len(self.db), 'entries': self.db}
