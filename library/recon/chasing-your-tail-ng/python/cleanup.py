#!/usr/bin/env python3
"""
cleanup.py - Loot-Verzeichnis Bereinigung für Chasing Your Tail NG
Löscht alte Reports, PCAPs und BT-Scans basierend auf config.json.
v4.5: Automatischer Aufruf beim Payload-Start.
"""
import os, sys, json, logging, argparse
from datetime import datetime, timedelta

log = logging.getLogger('CYT-Cleanup')

# Standardwerte falls config keine cleanup-Sektion hat
DEFAULTS = {
    'enabled':           True,
    'keep_reports_days': 30,
    'keep_pcaps_days':   7,
    'keep_bt_scans_days': 14,
    'keep_logs_days':    14,
}

def _age_days(filepath):
    """Gibt Alter einer Datei in Tagen zurück."""
    try:
        mtime = os.path.getmtime(filepath)
        return (datetime.now().timestamp() - mtime) / 86400
    except Exception:
        return 0

def _delete_old_files(directory, pattern_fn, max_days, label, dry_run=False):
    """
    Löscht Dateien in directory die älter als max_days sind.
    pattern_fn(filename) → True wenn Datei berücksichtigt werden soll.
    Gibt (gelöscht, gesamt, freigegeben_bytes) zurück.
    """
    deleted = 0
    total   = 0
    freed   = 0

    if not os.path.isdir(directory):
        return 0, 0, 0

    for fname in os.listdir(directory):
        fpath = os.path.join(directory, fname)
        if not os.path.isfile(fpath):
            continue
        if not pattern_fn(fname):
            continue
        total += 1
        age = _age_days(fpath)
        if age > max_days:
            size = os.path.getsize(fpath)
            if not dry_run:
                try:
                    os.remove(fpath)
                    deleted += 1
                    freed   += size
                    log.debug(f'Gelöscht ({age:.0f}d): {fname}')
                except Exception as e:
                    log.warning(f'Konnte nicht löschen {fname}: {e}')
            else:
                deleted += 1
                freed   += size
                log.debug(f'[dry-run] Würde löschen ({age:.0f}d): {fname}')

    if deleted:
        log.info(f'{label}: {deleted}/{total} Dateien gelöscht '
                 f'({freed // 1024}KB freigegeben)')
    else:
        log.info(f'{label}: {total} Dateien, alle aktuell (max {max_days}d)')

    return deleted, total, freed


def run_cleanup(config_path, dry_run=False):
    """
    Führt Cleanup durch. Gibt (total_deleted, total_freed_bytes) zurück.
    """
    # Config laden
    cfg_cleanup = DEFAULTS.copy()
    base_dir    = '/root/loot/chasing_your_tail'

    try:
        with open(config_path) as f:
            config = json.load(f)
        base_dir = config.get('paths', {}).get('base_dir', base_dir)
        cfg_cleanup.update(config.get('cleanup', {}))
    except Exception as e:
        log.warning(f'Config nicht geladen ({e}), nutze Standardwerte')

    if not cfg_cleanup.get('enabled', True):
        log.info('Cleanup deaktiviert (config: cleanup.enabled = false)')
        return 0, 0

    log.info(f'Cleanup startet (dry_run={dry_run})...')
    total_del  = 0
    total_free = 0

    # 1. Surveillance Reports
    d, _, f = _delete_old_files(
        os.path.join(base_dir, 'surveillance_reports'),
        lambda n: n.endswith('.md'),
        cfg_cleanup['keep_reports_days'],
        'Reports',
        dry_run
    )
    total_del += d; total_free += f

    # 2. PCAP-Dateien
    d, _, f = _delete_old_files(
        os.path.join(base_dir, 'pcap'),
        lambda n: n.endswith('.pcap') or n.endswith('.pcapng'),
        cfg_cleanup['keep_pcaps_days'],
        'PCAPs',
        dry_run
    )
    total_del += d; total_free += f

    # 3. BT-Scan JSONs
    d, _, f = _delete_old_files(
        base_dir,
        lambda n: n.startswith('bt_scan_') and n.endswith('.json'),
        cfg_cleanup['keep_bt_scans_days'],
        'BT-Scans',
        dry_run
    )
    total_del += d; total_free += f

    # 4. Log-Dateien
    d, _, f = _delete_old_files(
        os.path.join(base_dir, 'logs'),
        lambda n: n.endswith('.log'),
        cfg_cleanup['keep_logs_days'],
        'Logs',
        dry_run
    )
    total_del += d; total_free += f

    if total_del:
        log.info(f'Cleanup fertig: {total_del} Dateien, '
                 f'{total_free // 1024}KB freigegeben')
        print(f'CLEANUP:{total_del} Dateien gelöscht, '
              f'{total_free // 1024}KB freigegeben')
    else:
        log.info('Cleanup: nichts zu tun')
        print('CLEANUP:Alles aktuell')

    return total_del, total_free


# ============================================================
# MAIN
# ============================================================
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Loot-Cleanup für CYT NG')
    parser.add_argument('--config',   default='/root/payloads/user/reconnaissance/'
                                               'chasing_your_tail/config.json')
    parser.add_argument('--dry-run',  action='store_true',
                        help='Nur anzeigen, nicht löschen')
    parser.add_argument('--verbose',  action='store_true')
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='[%(asctime)s] %(levelname)s %(message)s'
    )

    deleted, freed = run_cleanup(args.config, dry_run=args.dry_run)
    if args.dry_run:
        print(f'[dry-run] Würde {deleted} Dateien löschen ({freed // 1024}KB)')
