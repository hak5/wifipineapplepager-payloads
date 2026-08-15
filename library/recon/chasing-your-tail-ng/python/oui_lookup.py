#!/usr/bin/env python3
"""
oui_lookup.py - Offline OUI/MAC Hersteller-Lookup
Lädt IEEE OUI Liste und cached sie lokal.
Wird bei Internetverbindung automatisch aktualisiert.
"""
import os, re, logging, urllib.request, json
from datetime import datetime, timedelta

log = logging.getLogger('CYT-OUI')

OUI_URL       = 'https://standards-oui.ieee.org/oui/oui.txt'
OUI_CACHE     = '/root/loot/chasing_your_tail/oui_cache.json'
UPDATE_DAYS   = 7  # Wöchentlich updaten

def _parse_oui_txt(text):
    """Parst IEEE oui.txt Format."""
    db = {}
    for line in text.split('\n'):
        m = re.match(r'^([0-9A-F]{2}-[0-9A-F]{2}-[0-9A-F]{2})\s+\(hex\)\s+(.+)$', line.strip())
        if m:
            oui    = m.group(1).replace('-', ':').lower()
            vendor = m.group(2).strip()
            db[oui] = vendor
    return db

def _load_cache():
    """Lädt OUI-Cache von Disk."""
    if os.path.exists(OUI_CACHE):
        try:
            with open(OUI_CACHE) as f:
                data = json.load(f)
            return data.get('db', {}), data.get('updated', '')
        except Exception:
            pass
    return {}, ''

def _save_cache(db):
    """Speichert OUI-Cache auf Disk."""
    os.makedirs(os.path.dirname(OUI_CACHE), exist_ok=True)
    with open(OUI_CACHE, 'w') as f:
        json.dump({
            'updated': datetime.now().isoformat(),
            'count':   len(db),
            'db':      db
        }, f)
    log.info(f'OUI-Cache gespeichert: {len(db)} Einträge')

def _needs_update(updated_str):
    """Prüft ob Cache aktualisiert werden muss."""
    if not updated_str:
        return True
    try:
        updated = datetime.fromisoformat(updated_str)
        return datetime.now() - updated > timedelta(days=UPDATE_DAYS)
    except Exception:
        return True

def _download_oui(timeout=15):
    """Lädt OUI-Liste von IEEE herunter."""
    try:
        log.info('Lade OUI-Liste von IEEE...')
        request = urllib.request.Request(OUI_URL, headers={
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
        })
        req = urllib.request.urlopen(request, timeout=timeout)
        text = req.read().decode('utf-8', errors='ignore')
        db = _parse_oui_txt(text)
        if len(db) > 1000:
            log.info(f'OUI-Liste geladen: {len(db)} Einträge')
            return db
    except Exception as e:
        log.warning(f'OUI Download fehlgeschlagen: {e}')
    return None

def load_oui_db(force_update=False):
    """
    Lädt OUI-Datenbank - aus Cache oder frisch von IEEE.
    Bei Internetverbindung wird wöchentlich aktualisiert.
    """
    db, updated = _load_cache()

    if force_update or _needs_update(updated) or len(db) < 100:
        new_db = _download_oui()
        if new_db:
            db = new_db
            _save_cache(db)
        elif not db:
            log.warning('Kein OUI-Cache und kein Internet - Lookup nicht verfügbar')

    log.info(f'OUI-DB: {len(db)} Einträge (Stand: {updated[:10] if updated else "unbekannt"})')
    return db

def lookup(mac, db):
    """
    Sucht Hersteller für eine MAC-Adresse.
    Returns: Herstellername oder 'Unbekannt'
    """
    if not mac or not db:
        return 'Unbekannt'
    oui = mac.lower().replace('-', ':')[:8]
    return db.get(oui, 'Unbekannt')

def lookup_many(macs, db):
    """Lookup für mehrere MACs auf einmal."""
    return {mac: lookup(mac, db) for mac in macs}

# ============================================================
# MAIN (Test + Update)
# ============================================================
if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--update', action='store_true', help='Cache aktualisieren')
    parser.add_argument('--lookup', help='MAC-Adresse nachschlagen')
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format='[%(asctime)s] %(levelname)s %(message)s')

    db = load_oui_db(force_update=args.update)

    if args.lookup:
        vendor = lookup(args.lookup, db)
        print(f'{args.lookup} -> {vendor}')
    else:
        # Test mit bekannten MACs
        test_macs = [
            'e0:48:24:12:5e:33',  # Garmin
            'bc:ff:4d:38:a2:d2',  # Unbekannt
            'f8:b5:4d:5c:eb:bc',  # Unbekannt
            '00:13:37:ad:61:c6',  # Pager selbst
        ]
        print(f'\nOUI-Lookup Test ({len(db)} Einträge):')
        for mac in test_macs:
            print(f'  {mac} -> {lookup(mac, db)}')
