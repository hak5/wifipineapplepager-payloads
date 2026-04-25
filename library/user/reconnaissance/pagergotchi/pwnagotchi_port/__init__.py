"""
Pagergotchi - Pwnagotchi port for WiFi Pineapple Pager
Based on jayofelony/pwnagotchi with minimal changes for OpenWRT/hcxdumptool
"""

import time
import os

__version__ = '1.0.0'
__author__ = 'brAinphreAk'

_name = 'pagergotchi'
_started_at = time.time()


def name():
    """Get the device name"""
    return _name


def set_name(n):
    """Set the device name"""
    global _name
    _name = n


def uptime():
    """Get uptime in seconds"""
    return time.time() - _started_at


def cpu_load():
    """Get CPU load (simplified for OpenWRT)"""
    try:
        with open('/proc/loadavg', 'r') as f:
            return float(f.read().split()[0])
    except:
        return 0.0


def mem_usage():
    """Get memory usage percentage"""
    try:
        with open('/proc/meminfo', 'r') as f:
            lines = f.readlines()
            total = int(lines[0].split()[1])
            free = int(lines[1].split()[1])
            return ((total - free) / total) * 100
    except:
        return 0.0


def temperature():
    """Get CPU temperature (if available)"""
    try:
        # Try common temperature file locations
        for path in ['/sys/class/thermal/thermal_zone0/temp',
                     '/sys/class/hwmon/hwmon0/temp1_input']:
            if os.path.exists(path):
                with open(path, 'r') as f:
                    return int(f.read().strip()) / 1000.0
    except:
        pass
    return 0.0


def restart(mode='AUTO'):
    """Restart pwnagotchi (just exit, payload.sh will handle restart)"""
    import sys
    print(f"[*] Restart requested (mode={mode})")
    sys.exit(0)


def reboot():
    """Reboot the device"""
    import subprocess
    print("[*] Reboot requested")
    subprocess.run(['reboot'], check=False)


def shutdown():
    """Shutdown the device"""
    import subprocess
    print("[*] Shutdown requested")
    subprocess.run(['poweroff'], check=False)


def battery():
    """
    Get battery percentage.

    Tries multiple methods:
    1. Standard Linux power_supply sysfs interface
    2. ubus call (common on OpenWRT/Pineapple)
    3. Falls back to None if unavailable

    Returns: int (0-100) or None if unavailable
    """
    import subprocess
    import glob
    import json

    # Method 1: Standard Linux sysfs interface
    try:
        for bat_path in glob.glob('/sys/class/power_supply/*/capacity'):
            with open(bat_path, 'r') as f:
                return int(f.read().strip())
    except:
        pass

    # Method 2: Try ubus (OpenWRT/Pineapple)
    try:
        result = subprocess.run(
            ['ubus', 'call', 'battery', 'info'],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            if 'percent' in data:
                return int(data['percent'])
            if 'capacity' in data:
                return int(data['capacity'])
    except:
        pass

    # Method 3: Try reading from /tmp (some devices write battery here)
    try:
        for path in ['/tmp/battery', '/tmp/battery_percent', '/var/battery']:
            if os.path.exists(path):
                with open(path, 'r') as f:
                    return int(f.read().strip())
    except:
        pass

    # Method 4: Try pineapple-specific paths
    try:
        for path in ['/sys/devices/platform/battery/capacity',
                     '/sys/devices/platform/axp20x-battery-power-supply/capacity']:
            if os.path.exists(path):
                with open(path, 'r') as f:
                    return int(f.read().strip())
    except:
        pass

    return None


def battery_charging():
    """
    Check if battery is charging.

    Returns: True if charging, False if not, None if unknown
    """
    import glob

    try:
        for status_path in glob.glob('/sys/class/power_supply/*/status'):
            with open(status_path, 'r') as f:
                status = f.read().strip().lower()
                return status in ('charging', 'full')
    except:
        pass

    return None
