"""
Bettercap API shim for Pagergotchi
Wraps hcxdumptool to provide a bettercap-compatible interface

This allows the original pwnagotchi code to work without modification
by translating bettercap commands to hcxdumptool operations.
"""

import os
import re
import time
import json
import logging
import asyncio
import subprocess
import threading
from datetime import datetime
from queue import Queue, Empty


class WiFiBackend:
    """
    WiFi scanning and capture using hcxdumptool
    Provides data in bettercap session format
    """

    def __init__(self, interface='wlan1mon', handshakes_dir='/root/loot/handshakes/pagergotchi'):
        self.interface = interface
        self.handshakes_dir = handshakes_dir
        self.channels = list(range(1, 12))
        self.hop_interval = 5

        # State
        self.current_channel = 0  # 0 = all channels
        self.running = False
        self.hcxdumptool_proc = None
        self.capture_file = None

        # Discovered networks
        self.access_points = {}
        self.handshakes = {}

        # Event queue for websocket simulation
        self.event_queue = Queue()

        # Stats update thread
        self._stats_thread = None
        self._lock = threading.Lock()

    def start(self):
        """Start WiFi scanning and capture"""
        if self.running:
            return True

        os.makedirs(self.handshakes_dir, exist_ok=True)

        # Generate capture filename
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        self.capture_file = os.path.join(self.handshakes_dir, f'capture_{timestamp}.pcapng')

        # Start hcxdumptool (v6.3.4 syntax)
        cmd = [
            'hcxdumptool',
            '-i', self.interface,
            '-w', self.capture_file,
            '-F',           # Use all available channels
            '--rds=1',      # Real-time display sorted
        ]

        logging.info(f"Starting hcxdumptool: {' '.join(cmd)}")

        try:
            self.hcxdumptool_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )
            self.running = True
            logging.info(f"hcxdumptool started with PID: {self.hcxdumptool_proc.pid}")

            # Start stats update thread
            self._stats_thread = threading.Thread(target=self._stats_loop, daemon=True)
            self._stats_thread.start()

            return True
        except Exception as e:
            logging.error(f"Error starting hcxdumptool: {e}")
            return False

    def stop(self):
        """Stop WiFi scanning"""
        self.running = False

        if self.hcxdumptool_proc:
            self.hcxdumptool_proc.terminate()
            try:
                self.hcxdumptool_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.hcxdumptool_proc.kill()
            self.hcxdumptool_proc = None

        # Convert captures to hashcat format
        if self.capture_file and os.path.exists(self.capture_file):
            self._convert_captures()

    def set_channel(self, channel):
        """Set specific channel (0 = all channels)"""
        self.current_channel = channel
        if channel > 0:
            try:
                subprocess.run(
                    ['iw', 'dev', self.interface, 'set', 'channel', str(channel)],
                    capture_output=True, timeout=5
                )
                return True
            except Exception as e:
                logging.error(f"Error setting channel: {e}")
                return False
        return True

    def clear_channel(self):
        """Clear channel restriction (scan all)"""
        self.current_channel = 0
        return True

    def _stats_loop(self):
        """Periodically update stats from capture file"""
        while self.running:
            time.sleep(5)
            if not self.running:
                break
            self._update_stats()

    def _update_stats(self):
        """Get AP and handshake counts from capture file using hcxpcapngtool"""
        if not self.capture_file or not os.path.exists(self.capture_file):
            return

        try:
            result = subprocess.run(
                ['hcxpcapngtool', '-o', '/tmp/current.22000', self.capture_file],
                capture_output=True, text=True, timeout=10
            )

            output = result.stderr + result.stdout

            with self._lock:
                # Parse ESSID count
                essid_match = re.search(r'ESSID \(total unique\)\.+:\s*(\d+)', output)
                if essid_match:
                    new_ap_count = int(essid_match.group(1))
                    # Create placeholder AP entries
                    while len(self.access_points) < new_ap_count:
                        fake_mac = f"00:00:00:00:{len(self.access_points):02x}:00"
                        self.access_points[fake_mac] = {
                            'mac': fake_mac,
                            'hostname': f'AP_{len(self.access_points)}',
                            'vendor': '',
                            'channel': self.current_channel or 1,
                            'rssi': -70,
                            'encryption': 'WPA2',
                            'clients': []
                        }

                # Parse EAPOL pairs (actual handshakes)
                eapol_match = re.search(r'EAPOL pairs written.*:\s*(\d+)', output)
                if eapol_match:
                    new_shake_count = int(eapol_match.group(1))
                    old_count = len(self.handshakes)

                    # Add placeholder entries and queue events for new handshakes
                    while len(self.handshakes) < new_shake_count:
                        shake_id = len(self.handshakes)
                        fake_sta = f"00:00:00:00:00:{shake_id:02x}"
                        fake_ap = f"00:00:00:00:{shake_id:02x}:00"

                        self.handshakes[f"{fake_sta} -> {fake_ap}"] = {
                            'file': self.capture_file,
                            'station': fake_sta,
                            'ap': fake_ap
                        }

                        # Queue handshake event
                        self.event_queue.put({
                            'tag': 'wifi.client.handshake',
                            'data': {
                                'file': self.capture_file,
                                'station': fake_sta,
                                'ap': fake_ap
                            }
                        })

                # Also check for PMKID
                pmkid_match = re.search(r'PMKID.*written.*:\s*(\d+)', output)
                if pmkid_match:
                    pmkid_count = int(pmkid_match.group(1))
                    # PMKIDs also count as handshakes for our purposes

        except Exception as e:
            logging.debug(f"Stats update error: {e}")

    def _convert_captures(self):
        """Convert pcapng to hashcat 22000 format"""
        if not self.capture_file:
            return

        output_file = self.capture_file.replace('.pcapng', '.22000')
        try:
            subprocess.run(
                ['hcxpcapngtool', '-o', output_file, self.capture_file],
                capture_output=True, timeout=60
            )
            if os.path.exists(output_file) and os.path.getsize(output_file) > 0:
                logging.info(f"Converted captures to: {output_file}")
        except Exception as e:
            logging.error(f"Conversion error: {e}")

    def get_session_data(self):
        """Return data in bettercap session format"""
        with self._lock:
            return {
                'wifi': {
                    'aps': list(self.access_points.values())
                },
                'interfaces': [
                    {'name': self.interface}
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


class Client:
    """
    Bettercap-compatible Client that uses hcxdumptool backend

    This provides the same interface as the original pwnagotchi.bettercap.Client
    so the rest of the code can work unchanged.
    """

    def __init__(self, hostname='localhost', scheme='http', port=8081,
                 username='user', password='pass'):
        # These params are ignored - we don't connect to bettercap
        self.hostname = hostname
        self.scheme = scheme
        self.port = port
        self.username = username
        self.password = password
        self.url = f"{scheme}://{hostname}:{port}/api"
        self.websocket = f"ws://{username}:{password}@{hostname}:{port}/api"

        # Our hcxdumptool backend
        self._backend = None
        self._interface = 'wlan1mon'
        self._handshakes_dir = '/root/loot/handshakes/pagergotchi'

    def _ensure_backend(self):
        """Lazily initialize backend"""
        if self._backend is None:
            self._backend = WiFiBackend(
                interface=self._interface,
                handshakes_dir=self._handshakes_dir
            )
        return self._backend

    def session(self, sess="session"):
        """Return session data in bettercap format"""
        backend = self._ensure_backend()
        return backend.get_session_data()

    def run(self, command, verbose_errors=True):
        """
        Execute a bettercap command by translating to hcxdumptool operations

        Supported commands:
        - wifi.recon on/off
        - wifi.recon.channel X or wifi.recon.channel clear
        - wifi.clear
        - wifi.assoc MAC (logged but no-op)
        - wifi.deauth MAC (logged but no-op)
        - set wifi.* (configuration, mostly ignored)
        - events.* (ignored)
        """
        backend = self._ensure_backend()
        command = command.strip()

        logging.debug(f"[bettercap shim] run: {command}")

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
                    backend.clear_channel()
                else:
                    # Could be single channel or comma-separated list
                    try:
                        channels = [int(c.strip()) for c in channel_arg.split(',')]
                        backend.set_channel(channels[0])  # Use first channel
                    except:
                        pass
            return {'success': True}

        elif command == 'wifi.clear':
            with backend._lock:
                backend.access_points.clear()
            return {'success': True}

        elif command.startswith('wifi.assoc'):
            # Association attack - log but don't actually do it
            mac = command.replace('wifi.assoc', '').strip()
            logging.info(f"[shim] Association requested for {mac} (not implemented)")
            return {'success': True}

        elif command.startswith('wifi.deauth'):
            # Deauth attack - log but don't actually do it
            mac = command.replace('wifi.deauth', '').strip()
            logging.info(f"[shim] Deauth requested for {mac} (not implemented)")
            return {'success': True}

        elif command.startswith('set wifi.'):
            # Configuration commands - parse and apply what we can
            if 'interface' in command:
                match = re.search(r'set wifi\.interface\s+(\S+)', command)
                if match:
                    self._interface = match.group(1)
                    if self._backend:
                        self._backend.interface = self._interface
            elif 'handshakes.file' in command or 'handshakes' in command:
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
            logging.debug(f"[bettercap shim] Unhandled command: {command}")
            return {'success': True}

    async def start_websocket(self, consumer):
        """
        Simulate bettercap websocket by polling event queue

        The consumer is an async function that receives JSON event messages
        """
        backend = self._ensure_backend()

        logging.info("[bettercap shim] Starting event polling...")

        while True:
            try:
                # Check for events
                event = backend.get_next_event(timeout=1.0)
                if event:
                    # Send event to consumer as JSON string (like real bettercap)
                    await consumer(json.dumps(event))

                # Small delay to prevent tight loop
                await asyncio.sleep(0.1)

            except Exception as e:
                logging.debug(f"[bettercap shim] Event loop error: {e}")
                await asyncio.sleep(1.0)
