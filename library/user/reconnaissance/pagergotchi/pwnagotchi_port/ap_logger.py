"""
AP Logger for Pagergotchi
Logs discovered access points in normal or WiGLE CSV format
"""

import csv
import json
import os
import time
import logging
from datetime import datetime

# Payload directory paths (relative to this file's location)
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PAYLOAD_DIR = os.path.abspath(os.path.join(_THIS_DIR, '..'))
DATA_DIR = os.path.join(PAYLOAD_DIR, 'data')
SETTINGS_FILE = os.path.join(DATA_DIR, 'settings.json')

# Loot directories (standard Pager location for captured data)
LOOT_DIR = '/root/loot'
WIGLE_DIR = os.path.join(LOOT_DIR, 'wigle')
AP_LOG_DIR = os.path.join(LOOT_DIR, 'ap_logs')


class APLogger:
    """
    Logger for discovered access points

    Supports two formats:
    - Normal: Simple JSON log with AP details
    - WiGLE: WiGLE.net compatible CSV format with GPS coordinates
    """

    # WiGLE CSV header
    WIGLE_HEADER = [
        'MAC', 'SSID', 'AuthMode', 'FirstSeen', 'Channel', 'RSSI',
        'CurrentLatitude', 'CurrentLongitude', 'AltitudeMeters',
        'AccuracyMeters', 'Type'
    ]

    def __init__(self, config, gps=None):
        self._config = config
        self._gps = gps
        self._enabled = False
        self._wigle_enabled = False
        self._seen_aps = {}  # Track seen APs to avoid duplicates

        # Output paths - use standard loot directories
        self._wigle_dir = WIGLE_DIR
        self._log_dir = AP_LOG_DIR
        self._wigle_file = None
        self._normal_file = None

        # Load settings from persistent file
        self._load_settings()

    def _load_settings(self):
        """Load settings from persistent settings file"""
        try:
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings = json.load(f)
                    self._wigle_enabled = settings.get('wigle_enabled', False)
                    self._enabled = settings.get('log_aps_enabled', False)
        except Exception:
            pass

    def reload_settings(self):
        """Reload settings (call this when settings change)"""
        self._load_settings()

    def start(self):
        """Start logging (creates output files)"""
        if not self._enabled:
            return

        # Create dated filenames
        date_str = datetime.now().strftime('%Y%m%d_%H%M%S')

        if self._wigle_enabled:
            # Use /root/loot/wigle for WiGLE files
            if not os.path.exists(self._wigle_dir):
                try:
                    os.makedirs(self._wigle_dir)
                except Exception as e:
                    logging.error(f"[APLogger] Failed to create wigle dir: {e}")
                    return
            self._wigle_file = os.path.join(self._wigle_dir, f'wigle_{date_str}.csv')
            self._init_wigle_file()
            logging.info(f"[APLogger] WiGLE logging to {self._wigle_file}")
        else:
            # Use /root/loot/ap_logs for normal AP logs
            if not os.path.exists(self._log_dir):
                try:
                    os.makedirs(self._log_dir)
                except Exception as e:
                    logging.error(f"[APLogger] Failed to create log dir: {e}")
                    return
            self._normal_file = os.path.join(self._log_dir, f'aps_{date_str}.json')
            logging.info(f"[APLogger] Normal logging to {self._normal_file}")

    def _init_wigle_file(self):
        """Initialize WiGLE CSV file with header"""
        if not self._wigle_file:
            return

        try:
            with open(self._wigle_file, 'w', newline='') as f:
                # WiGLE format version header
                f.write('WigleWifi-1.4,appRelease=Pagergotchi,model=PineapplePager,release=1.0.0,device=Pager,display=Pagergotchi,board=Pineapple,brand=Hak5\n')
                writer = csv.writer(f)
                writer.writerow(self.WIGLE_HEADER)
        except Exception as e:
            logging.error(f"[APLogger] Failed to init WiGLE file: {e}")

    def log_aps(self, aps):
        """Log access points"""
        if not self._enabled:
            return

        # Reload settings in case they changed
        self._load_settings()
        if not self._enabled:
            return

        if self._wigle_enabled:
            self._log_wigle(aps)
        else:
            self._log_normal(aps)

    def _log_wigle(self, aps):
        """Log APs in WiGLE CSV format"""
        if not self._wigle_file:
            return

        # Get GPS coordinates
        coords = None
        if self._gps:
            coords = self._gps.coordinates

        if not coords:
            # WiGLE needs GPS - skip logging if no fix
            return

        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        new_aps = []

        for ap in aps:
            mac = ap.get('mac', '')
            if not mac:
                continue

            # Skip if we've already logged this AP at this location
            loc_key = f"{mac}_{coords['Latitude']:.4f}_{coords['Longitude']:.4f}"
            if loc_key in self._seen_aps:
                continue

            self._seen_aps[loc_key] = True

            # Map encryption to WiGLE auth mode
            enc = ap.get('encryption', 'OPEN')
            auth_mode = self._map_encryption(enc)

            row = [
                mac,  # MAC
                ap.get('hostname', ap.get('ssid', '')),  # SSID
                auth_mode,  # AuthMode
                now,  # FirstSeen
                ap.get('channel', 0),  # Channel
                ap.get('rssi', -100),  # RSSI
                coords['Latitude'],  # CurrentLatitude
                coords['Longitude'],  # CurrentLongitude
                coords.get('Altitude', 0),  # AltitudeMeters
                10,  # AccuracyMeters (estimated)
                'WIFI'  # Type
            ]
            new_aps.append(row)

        if new_aps:
            try:
                with open(self._wigle_file, 'a', newline='') as f:
                    writer = csv.writer(f)
                    writer.writerows(new_aps)
                logging.debug(f"[APLogger] Logged {len(new_aps)} APs to WiGLE")
            except Exception as e:
                logging.error(f"[APLogger] Failed to write WiGLE: {e}")

    def _map_encryption(self, encryption):
        """Map pwnagotchi encryption string to WiGLE auth mode"""
        enc = encryption.upper()
        if 'WPA3' in enc:
            return '[WPA3-SAE-CCMP][ESS]'
        elif 'WPA2' in enc:
            return '[WPA2-PSK-CCMP][ESS]'
        elif 'WPA' in enc:
            return '[WPA-PSK-TKIP][ESS]'
        elif 'WEP' in enc:
            return '[WEP][ESS]'
        elif enc == 'OPEN' or enc == '':
            return '[ESS]'
        else:
            return f'[{enc}][ESS]'

    def _log_normal(self, aps):
        """Log APs in simple JSON format"""
        if not self._normal_file:
            return

        now = datetime.now().isoformat()
        new_entries = []

        for ap in aps:
            mac = ap.get('mac', '')
            if not mac:
                continue

            # Skip duplicates
            if mac in self._seen_aps:
                continue

            self._seen_aps[mac] = True

            entry = {
                'timestamp': now,
                'mac': mac,
                'ssid': ap.get('hostname', ap.get('ssid', '')),
                'channel': ap.get('channel', 0),
                'encryption': ap.get('encryption', 'OPEN'),
                'rssi': ap.get('rssi', -100),
                'clients': len(ap.get('clients', []))
            }

            # Add GPS if available
            if self._gps:
                coords = self._gps.coordinates
                if coords:
                    entry['latitude'] = coords['Latitude']
                    entry['longitude'] = coords['Longitude']
                    entry['altitude'] = coords.get('Altitude', 0)

            new_entries.append(entry)

        if new_entries:
            try:
                # Append to JSON file (one JSON object per line for easy parsing)
                with open(self._normal_file, 'a') as f:
                    for entry in new_entries:
                        f.write(json.dumps(entry) + '\n')
                logging.debug(f"[APLogger] Logged {len(new_entries)} APs")
            except Exception as e:
                logging.error(f"[APLogger] Failed to write log: {e}")

    def stop(self):
        """Stop logging"""
        if self._wigle_file:
            logging.info(f"[APLogger] Finished WiGLE log: {self._wigle_file}")
        if self._normal_file:
            logging.info(f"[APLogger] Finished normal log: {self._normal_file}")

    @property
    def enabled(self):
        return self._enabled

    @property
    def wigle_enabled(self):
        return self._wigle_enabled
