"""
Utility functions - copied from original pwnagotchi with minimal changes
Simplified for Pagergotchi (removed toml config loading, kept essential functions)
"""

import logging
import glob
import os
import subprocess
import json
from datetime import datetime
from enum import Enum


def parse_version(version):
    """Converts a version str to tuple for comparison"""
    return tuple(version.split('.'))


def merge_config(user, default):
    """Recursively merge user config into default config"""
    if isinstance(user, dict) and isinstance(default, dict):
        for k, v in default.items():
            if k not in user:
                user[k] = v
            else:
                user[k] = merge_config(user[k], v)
    return user


def secs_to_hhmmss(secs):
    """Convert seconds to HH:MM:SS format"""
    mins, secs = divmod(int(secs), 60)
    hours, mins = divmod(mins, 60)
    return '%02d:%02d:%02d' % (hours, mins, secs)


def total_unique_handshakes(path):
    """Count unique handshake files in path (prefer .22000, don't double-count)"""
    # .22000 files are hashcat format - count these first (pineapd creates both .pcap and .22000)
    hash_files = glob.glob(os.path.join(path, "*.22000"))
    if hash_files:
        return len(hash_files)
    # Fallback to pcap/pcapng if no .22000 files
    pcap_files = glob.glob(os.path.join(path, "*.pcap"))
    pcapng_files = glob.glob(os.path.join(path, "*.pcapng"))
    return len(pcap_files) + len(pcapng_files)


def iface_channels(ifname):
    """Get supported channels for interface"""
    channels = []
    try:
        # Try to get phy number
        result = subprocess.run(
            ['iw', ifname, 'info'],
            capture_output=True, text=True, timeout=5
        )
        phy_match = None
        for line in result.stdout.split('\n'):
            if 'wiphy' in line:
                phy_match = line.split()[-1]
                break

        if phy_match:
            result = subprocess.run(
                ['iw', f'phy{phy_match}', 'channels'],
                capture_output=True, text=True, timeout=5
            )
            for line in result.stdout.split('\n'):
                if 'MHz' in line and 'disabled' not in line.lower():
                    # Extract channel number from [X]
                    if '[' in line and ']' in line:
                        ch = line.split('[')[1].split(']')[0]
                        try:
                            channels.append(int(ch))
                        except:
                            pass
    except Exception as e:
        logging.debug(f"Error getting channels: {e}")

    # Fallback to 2.4GHz channels
    if not channels:
        channels = list(range(1, 12))

    return channels


class WifiInfo(Enum):
    """Fields you can extract from a pcap file"""
    BSSID = 0
    ESSID = 1
    ENCRYPTION = 2
    CHANNEL = 3
    FREQUENCY = 4
    RSSI = 5


class FieldNotFoundError(Exception):
    pass


def md5(fname):
    """Calculate MD5 hash of file"""
    import hashlib
    hash_md5 = hashlib.md5()
    with open(fname, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()


class StatusFile(object):
    """Status file handler for persistent data"""
    def __init__(self, path, data_format='raw'):
        self._path = path
        self._updated = None
        self._format = data_format
        self.data = None

        if os.path.exists(path):
            self._updated = datetime.fromtimestamp(os.path.getmtime(path))
            with open(path) as fp:
                if data_format == 'json':
                    self.data = json.load(fp)
                else:
                    self.data = fp.read()

    def data_field_or(self, name, default=""):
        if self.data is not None and name in self.data:
            return self.data[name]
        return default

    def newer_then_minutes(self, minutes):
        return self._updated is not None and ((datetime.now() - self._updated).seconds / 60) < minutes

    def newer_then_hours(self, hours):
        return self._updated is not None and ((datetime.now() - self._updated).seconds / (60 * 60)) < hours

    def newer_then_days(self, days):
        return self._updated is not None and (datetime.now() - self._updated).days < days

    def update(self, data=None):
        self._updated = datetime.now()
        self.data = data
        os.makedirs(os.path.dirname(self._path), exist_ok=True)
        with open(self._path, 'w') as fp:
            if data is None:
                fp.write(str(self._updated))
            elif self._format == 'json':
                json.dump(self.data, fp)
            else:
                fp.write(data)
