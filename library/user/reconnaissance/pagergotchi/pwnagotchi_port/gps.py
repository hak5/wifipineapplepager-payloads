"""
GPS support for Pagergotchi
Optional module - works when USB GPS is attached, gracefully disabled when not

Supports:
- gpsd (if running)
- Direct serial GPS devices (USB GPS dongles)
"""

import os
import json
import logging
import threading
import time


class GPS:
    """
    GPS handler for Pagergotchi

    Tries multiple methods to get GPS coordinates:
    1. gpsd (via socket) - Pager runs gpsd automatically when GPS attached
    2. Direct serial reading from UCI-configured or common GPS devices
    """

    def __init__(self, device=None):
        self._device = device
        self._baud_rate = 9600
        self._coordinates = None
        self._running = False
        self._thread = None
        self._lock = threading.Lock()

        # Try to read device/baud from Pager's UCI config
        self._read_uci_config()

        # Common USB GPS device paths
        self._device_paths = [
            '/dev/ttyUSB0',
            '/dev/ttyUSB1',
            '/dev/ttyACM0',
            '/dev/ttyACM1',
            '/dev/gps0',
        ]

        # Add UCI-discovered device first
        if self._device and self._device not in self._device_paths:
            self._device_paths.insert(0, self._device)

        # Add user-specified device first
        if device and device not in self._device_paths:
            self._device_paths.insert(0, device)

    def _read_uci_config(self):
        """Read GPS config from Pager's UCI system"""
        import subprocess

        # Get device path from UCI
        try:
            result = subprocess.run(
                ['uci', '-q', 'get', 'gpsd.core.device'],
                capture_output=True, text=True, timeout=2
            )
            if result.returncode == 0 and result.stdout.strip():
                uci_device = result.stdout.strip()
                # Resolve symlink if needed
                if os.path.islink(uci_device):
                    uci_device = os.path.realpath(uci_device)
                if os.path.exists(uci_device):
                    self._device = uci_device
                    logging.info(f"[GPS] Found UCI device: {uci_device}")
        except Exception as e:
            logging.debug(f"[GPS] UCI device lookup failed: {e}")

        # Get baud rate from UCI
        try:
            result = subprocess.run(
                ['uci', '-q', 'get', 'gpsd.core.speed'],
                capture_output=True, text=True, timeout=2
            )
            if result.returncode == 0 and result.stdout.strip():
                self._baud_rate = int(result.stdout.strip())
                logging.info(f"[GPS] Found UCI baud rate: {self._baud_rate}")
        except Exception as e:
            logging.debug(f"[GPS] UCI baud lookup failed: {e}")

    def start(self):
        """Start GPS monitoring in background thread"""
        if self._running:
            return True

        # On Pager, gpsd is managed by the system - try to ensure it's running
        self._ensure_gpsd_running()

        # Try gpsd first (preferred on Pager since it's already configured)
        if self._try_gpsd():
            logging.info("[GPS] Connected via gpsd")
            self._running = True
            self._thread = threading.Thread(target=self._gpsd_loop, daemon=True)
            self._thread.start()
            return True

        # Try direct serial as fallback
        device = self._find_gps_device()
        if device:
            logging.info(f"[GPS] Found device at {device}")
            self._device = device
            self._running = True
            self._thread = threading.Thread(target=self._serial_loop, daemon=True)
            self._thread.start()
            return True

        logging.info("[GPS] No GPS device found - GPS disabled")
        return False

    def _ensure_gpsd_running(self):
        """Ensure gpsd is running and connected to device (Pager-specific)"""
        import subprocess

        try:
            # Check if gpsd is running and has devices
            import socket
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(2)
            sock.connect(('127.0.0.1', 2947))
            sock.send(b'?DEVICES;\n')
            response = sock.recv(1024).decode('utf-8', errors='ignore')
            sock.close()

            # If no devices, restart gpsd
            if '"devices":[]' in response or 'devices":[]' in response:
                logging.info("[GPS] gpsd has no devices, restarting...")
                subprocess.run(['/etc/init.d/gpsd', 'restart'],
                             capture_output=True, timeout=5)
                time.sleep(2)  # Give gpsd time to connect
        except Exception as e:
            # gpsd not running, try to start it
            logging.debug(f"[GPS] gpsd check failed: {e}, trying to start...")
            try:
                subprocess.run(['/etc/init.d/gpsd', 'start'],
                             capture_output=True, timeout=5)
                time.sleep(2)
            except Exception:
                pass

    def stop(self):
        """Stop GPS monitoring"""
        self._running = False
        if self._thread:
            self._thread.join(timeout=2)

    def _try_gpsd(self):
        """Check if gpsd is available"""
        try:
            import socket
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            sock.connect(('127.0.0.1', 2947))
            sock.close()
            return True
        except:
            return False

    def _find_gps_device(self):
        """Find a GPS serial device"""
        for path in self._device_paths:
            if os.path.exists(path):
                # Quick check if it's a GPS by reading a line
                try:
                    with open(path, 'r') as f:
                        # Set non-blocking with timeout
                        import select
                        ready, _, _ = select.select([f], [], [], 2)
                        if ready:
                            line = f.readline()
                            if line.startswith('$GP') or line.startswith('$GN'):
                                return path
                except:
                    pass
        return None

    def _gpsd_loop(self):
        """Background thread to read from gpsd"""
        import socket

        while self._running:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(5)
                sock.connect(('127.0.0.1', 2947))
                sock.send(b'?WATCH={"enable":true,"json":true}\n')

                buffer = ''
                while self._running:
                    data = sock.recv(4096).decode('utf-8', errors='ignore')
                    if not data:
                        break

                    buffer += data
                    while '\n' in buffer:
                        line, buffer = buffer.split('\n', 1)
                        self._parse_gpsd_json(line)

                sock.close()
            except Exception as e:
                logging.debug(f"[GPS] gpsd error: {e}")

            time.sleep(5)  # Retry delay

    def _parse_gpsd_json(self, line):
        """Parse gpsd JSON output"""
        try:
            data = json.loads(line)
            if data.get('class') == 'TPV':
                lat = data.get('lat')
                lon = data.get('lon')
                alt = data.get('alt', 0)

                if lat is not None and lon is not None:
                    with self._lock:
                        self._coordinates = {
                            'Latitude': lat,
                            'Longitude': lon,
                            'Altitude': alt,
                            'Updated': time.time()
                        }
        except:
            pass

    def _serial_loop(self):
        """Background thread to read from serial GPS"""
        while self._running:
            try:
                with open(self._device, 'r') as f:
                    while self._running:
                        line = f.readline().strip()
                        if line:
                            self._parse_nmea(line)
            except Exception as e:
                logging.debug(f"[GPS] Serial error: {e}")

            time.sleep(5)  # Retry delay

    def _parse_nmea(self, line):
        """Parse NMEA sentences from GPS"""
        try:
            # GGA - Global Positioning System Fix Data
            if line.startswith('$GPGGA') or line.startswith('$GNGGA'):
                parts = line.split(',')
                if len(parts) >= 10 and parts[2] and parts[4]:
                    lat = self._nmea_to_decimal(parts[2], parts[3])
                    lon = self._nmea_to_decimal(parts[4], parts[5])
                    alt = float(parts[9]) if parts[9] else 0

                    with self._lock:
                        self._coordinates = {
                            'Latitude': lat,
                            'Longitude': lon,
                            'Altitude': alt,
                            'Updated': time.time()
                        }

            # RMC - Recommended Minimum Navigation Information
            elif line.startswith('$GPRMC') or line.startswith('$GNRMC'):
                parts = line.split(',')
                if len(parts) >= 7 and parts[3] and parts[5] and parts[2] == 'A':
                    lat = self._nmea_to_decimal(parts[3], parts[4])
                    lon = self._nmea_to_decimal(parts[5], parts[6])

                    with self._lock:
                        if self._coordinates:
                            self._coordinates['Latitude'] = lat
                            self._coordinates['Longitude'] = lon
                            self._coordinates['Updated'] = time.time()
                        else:
                            self._coordinates = {
                                'Latitude': lat,
                                'Longitude': lon,
                                'Altitude': 0,
                                'Updated': time.time()
                            }
        except Exception as e:
            logging.debug(f"[GPS] NMEA parse error: {e}")

    def _nmea_to_decimal(self, coord, direction):
        """Convert NMEA coordinate to decimal degrees"""
        # NMEA format: DDDMM.MMMMM
        if not coord:
            return None

        # Find decimal point to determine degrees digits
        dot_pos = coord.index('.')
        degrees = int(coord[:dot_pos-2])
        minutes = float(coord[dot_pos-2:])

        decimal = degrees + (minutes / 60)

        if direction in ['S', 'W']:
            decimal = -decimal

        return decimal

    @property
    def coordinates(self):
        """Get current coordinates (or None if unavailable)"""
        with self._lock:
            if self._coordinates:
                # Check if coordinates are stale (> 60 seconds old)
                if time.time() - self._coordinates.get('Updated', 0) > 60:
                    return None
                return self._coordinates.copy()
            return None

    @property
    def available(self):
        """Check if GPS is available and has a fix"""
        return self.coordinates is not None

    def save_coordinates(self, handshake_file):
        """
        Save GPS coordinates alongside a handshake file

        Creates a .gps.json file with the same name as the handshake
        """
        coords = self.coordinates
        if not coords:
            logging.debug("[GPS] No coordinates to save")
            return False

        # Don't save if coordinates are 0,0 (invalid)
        if coords['Latitude'] == 0 and coords['Longitude'] == 0:
            logging.debug("[GPS] Invalid coordinates (0,0), not saving")
            return False

        # Create GPS filename
        base = handshake_file.rsplit('.', 1)[0]
        gps_file = base + '.gps.json'

        try:
            with open(gps_file, 'w') as f:
                json.dump(coords, f, indent=2)
            logging.info(f"[GPS] Saved coordinates to {gps_file}")
            return True
        except Exception as e:
            logging.error(f"[GPS] Failed to save coordinates: {e}")
            return False
