#!/usr/bin/env python3
"""
wigle_lookup.py - WiGLE API Integration für Chasing Your Tail NG
Sucht MAC, BT-Adresse und SSIDs in der WiGLE Datenbank.
v4.5: Nearby-Search – bekannte Geräte in GPS-Radius abfragen.
"""
import urllib.request, urllib.parse, json, logging, base64, time, os

log = logging.getLogger('CYT-WiGLE')

WIGLE_BASE    = 'https://api.wigle.net/api/v2'
CACHE_FILE    = '/root/loot/chasing_your_tail/wigle_cache.json'
RATE_LIMIT    = 1.5  # Sekunden zwischen Anfragen

class WiGLEClient:
    def __init__(self, api_name, api_token):
        credentials = base64.b64encode(
            f'{api_name}:{api_token}'.encode()
        ).decode()
        self.headers = {
            'Authorization': f'Basic {credentials}',
            'Accept': 'application/json'
        }
        self._last_request = 0
        self._cache = self._load_cache()

    def _load_cache(self):
        if os.path.exists(CACHE_FILE):
            try:
                with open(CACHE_FILE) as f:
                    return json.load(f)
            except Exception:
                pass
        return {}

    def _save_cache(self):
        os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
        with open(CACHE_FILE, 'w') as f:
            json.dump(self._cache, f)

    def _rate_limit(self):
        elapsed = time.time() - self._last_request
        if elapsed < RATE_LIMIT:
            time.sleep(RATE_LIMIT - elapsed)
        self._last_request = time.time()

    def _get(self, endpoint, params):
        cache_key = f'{endpoint}?{urllib.parse.urlencode(params)}'
        if cache_key in self._cache:
            log.debug(f'Cache hit: {cache_key}')
            return self._cache[cache_key]

        self._rate_limit()
        url = f'{WIGLE_BASE}{endpoint}?{urllib.parse.urlencode(params)}'
        try:
            req = urllib.request.Request(url, headers=self.headers)
            resp = urllib.request.urlopen(req, timeout=10)
            data = json.loads(resp.read().decode())
            self._cache[cache_key] = data
            self._save_cache()
            return data
        except Exception as e:
            log.warning(f'WiGLE Fehler: {e}')
            return None

    def search_wifi_mac(self, mac):
        """Sucht WiFi-Gerät anhand MAC-Adresse."""
        data = self._get('/network/search', {
            'netid': mac.upper().replace(':', '%3A'),
            'resultsPerPage': 1
        })
        return self._parse_network(data, 'wifi')

    def search_bt_mac(self, mac):
        """Sucht Bluetooth-Gerät anhand MAC-Adresse."""
        data = self._get('/bluetooth/search', {
            'netid': mac.upper().replace(':', '%3A'),
            'resultsPerPage': 1
        })
        return self._parse_network(data, 'bt')

    def search_ssid(self, ssid):
        """Sucht SSID in WiGLE."""
        data = self._get('/network/search', {
            'ssid': ssid,
            'resultsPerPage': 3
        })
        return self._parse_network(data, 'ssid')

    def search_nearby(self, lat, lon, radius_m=200):
        """
        Sucht alle WiGLE-bekannten WiFi-Netze in einem Radius um GPS-Position.
        radius_m: Suchradius in Metern (empfohlen: 100-500m).
        Gibt Liste von {ssid, netid, lat, lon, last_seen} zurück.
        """
        import math
        # Grad-Offset für Radius: 1° Lat ≈ 111km, 1° Lon ≈ 111km * cos(lat)
        lat_delta = radius_m / 111_000.0
        lon_delta = radius_m / (111_000.0 * max(math.cos(math.radians(lat)), 0.01))

        data = self._get('/network/search', {
            'latrange1':     lat - lat_delta,
            'latrange2':     lat + lat_delta,
            'longrange1':    lon - lon_delta,
            'longrange2':    lon + lon_delta,
            'resultsPerPage': 100,
            'onlymine':      'false',
        })
        if not data or not data.get('success'):
            return []

        results = []
        for r in data.get('results', []):
            results.append({
                'ssid':      r.get('ssid', ''),
                'netid':     r.get('netid', '').upper().replace('-', ':'),
                'lat':       r.get('trilat', 0),
                'lon':       r.get('trilong', 0),
                'last_seen': r.get('lasttime', '')[:10],
                'type':      'wifi',
            })
        log.info(f'WiGLE Nearby ({radius_m}m): {len(results)} Netze in Datenbank')
        return results

    def _parse_network(self, data, ntype):
        if not data or not data.get('success'):
            return None
        results = data.get('results', [])
        if not results:
            return {'found': False, 'type': ntype}

        r = results[0]
        return {
            'found':       True,
            'type':        ntype,
            'ssid':        r.get('ssid', ''),
            'netid':       r.get('netid', ''),
            'lat':         r.get('trilat', 0),
            'lon':         r.get('trilong', 0),
            'country':     r.get('country', ''),
            'region':      r.get('region', ''),
            'city':        r.get('city', ''),
            'first_seen':  r.get('firsttime', ''),
            'last_seen':   r.get('lasttime', ''),
            'total_found': data.get('totalResults', 0),
        }

def format_location(result):
    """Formatiert WiGLE-Ergebnis als lesbaren String."""
    if not result or not result.get('found'):
        return 'Nicht in WiGLE'
    parts = []
    if result.get('city'):
        parts.append(result['city'])
    if result.get('region'):
        parts.append(result['region'])
    if result.get('country'):
        parts.append(result['country'])
    loc = ', '.join(parts) if parts else f'{result["lat"]:.4f}, {result["lon"]:.4f}'
    return f'{loc} (zuletzt: {result.get("last_seen","?")[:10]})'

def lookup_device(mac, ssids, bt_mac=None, client=None):
    """
    Vollständiger WiGLE-Lookup für ein Gerät.
    Returns: dict mit allen Ergebnissen
    """
    if not client:
        return {}

    results = {}

    # 1. WiFi MAC suchen
    log.info(f'WiGLE: Suche WiFi-MAC {mac}')
    results['wifi_mac'] = client.search_wifi_mac(mac)

    # 2. BT MAC suchen (falls vorhanden)
    if bt_mac:
        log.info(f'WiGLE: Suche BT-MAC {bt_mac}')
        results['bt_mac'] = client.search_bt_mac(bt_mac)

    # 3. Probe-SSIDs suchen
    results['ssids'] = {}
    for ssid in ssids[:5]:  # Max 5 SSIDs
        if ssid and len(ssid) > 2:
            log.info(f'WiGLE: Suche SSID "{ssid}"')
            results['ssids'][ssid] = client.search_ssid(ssid)

    return results

def nearby_cross_reference(nearby_list, suspicious_macs):
    """
    Gleicht WiGLE-Nearby-Ergebnisse mit verdächtigen Geräten ab.
    suspicious_macs: set/list von MACs aus dem aktuellen Scan.
    Gibt zurück: (matched, unmatched_known)
      matched        – verdächtige Geräte die WiGLE in diesem Bereich kennt
      unmatched_known – WiGLE-Geräte die wir NICHT gesehen haben (interessant!)
    """
    sus_set = set(m.upper().replace('-', ':') for m in suspicious_macs)
    nearby_set = {r['netid']: r for r in nearby_list if r['netid']}

    matched = {mac: nearby_set[mac.upper().replace('-', ':')]
               for mac in suspicious_macs
               if mac.upper().replace('-', ':') in nearby_set}

    unmatched_known = [r for nid, r in nearby_set.items()
                       if nid not in sus_set and r.get('ssid')]
    return matched, unmatched_known


def format_nearby_section(nearby_list, suspicious_macs, lat, lon, radius_m=200):
    """Formatiert WiGLE Nearby-Ergebnisse für den Report."""
    if not nearby_list:
        return ''

    matched, unmatched = nearby_cross_reference(nearby_list, suspicious_macs)
    lines = [f'\n## 📡 WiGLE Nearby-Abgleich ({radius_m}m Radius)\n']
    lines.append(f'**GPS:** {lat:.5f}, {lon:.5f}  ')
    lines.append(f'**WiGLE kennt:** {len(nearby_list)} Netze im Bereich\n')

    if matched:
        lines.append(f'### ⚠️ Verdächtige Geräte auch in WiGLE bekannt ({len(matched)})\n')
        lines.append('| MAC | SSID | Zuletzt gesehen |')
        lines.append('|-----|------|-----------------|')
        for mac, r in matched.items():
            lines.append(f'| `{mac}` | {r.get("ssid","?")} | {r.get("last_seen","?")} |')
        lines.append('')

    if unmatched[:10]:  # Max 10 zeigen
        lines.append(f'### 📋 WiGLE-bekannte Netze (nicht im aktuellen Scan)\n')
        lines.append('| SSID | MAC | Zuletzt gesehen |')
        lines.append('|------|-----|-----------------|')
        for r in unmatched[:10]:
            lines.append(f'| {r.get("ssid","?")} | `{r.get("netid","?")}` | {r.get("last_seen","?")} |')
        lines.append('')

    return '\n'.join(lines)


def format_wigle_section(wigle_results):
    """Formatiert WiGLE-Ergebnisse für den Report."""
    if not wigle_results:
        return ''

    lines = ['\n**WiGLE:**\n']

    # WiFi MAC
    wifi = wigle_results.get('wifi_mac')
    if wifi:
        lines.append(f'- WiFi MAC: {format_location(wifi)}')

    # BT MAC
    bt = wigle_results.get('bt_mac')
    if bt:
        lines.append(f'- BT MAC: {format_location(bt)}')

    # SSIDs
    ssids = wigle_results.get('ssids', {})
    if ssids:
        lines.append('- Probe-SSIDs:')
        for ssid, result in ssids.items():
            loc = format_location(result)
            lines.append(f'  - `{ssid}`: {loc}')

    return '\n'.join(lines)

# ============================================================
# MAIN (Test)
# ============================================================
if __name__ == '__main__':
    import argparse, sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default='config.json')
    parser.add_argument('--mac',  help='WiFi MAC testen')
    parser.add_argument('--ssid', help='SSID testen')
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format='[%(asctime)s] %(levelname)s %(message)s')

    with open(args.config) as f:
        config = json.load(f)

    wigle_cfg = config.get('wigle', {})
    if not wigle_cfg.get('enabled') or not wigle_cfg.get('api_token'):
        print("WiGLE nicht konfiguriert!")
        sys.exit(1)

    client = WiGLEClient(wigle_cfg['api_name'], wigle_cfg['api_token'])

    if args.mac:
        result = client.search_wifi_mac(args.mac)
        print(f'WiFi MAC {args.mac}: {format_location(result)}')

    if args.ssid:
        result = client.search_ssid(args.ssid)
        print(f'SSID "{args.ssid}": {format_location(result)}')
