"""
Startup and pause menus for Pagergotchi
Uses libpagerctl.so for fast native rendering
"""

import json
import os
import sys
import subprocess
import time

# Payload directory paths (relative to this file's location)
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PAYLOAD_DIR = os.path.abspath(os.path.join(_THIS_DIR, '..', '..'))
DATA_DIR = os.path.join(PAYLOAD_DIR, 'data')
SETTINGS_FILE = os.path.join(DATA_DIR, 'settings.json')
RECOVERY_FILE = os.path.join(DATA_DIR, 'recovery.json')

# Font paths
FONTS_DIR = os.path.join(PAYLOAD_DIR, 'fonts')
FONT_LOVEDAYS = os.path.join(FONTS_DIR, 'LoveDays.ttf')
FONT_DEJAVU = os.path.join(FONTS_DIR, 'DejaVuSansMono.ttf')

# TTF font sizes (to replace bitmap FONT_SMALL/MEDIUM/LARGE)
TTF_SMALL = 14.0
TTF_MEDIUM = 18.0
TTF_LARGE = 24.0

# Add lib directory to path for pagerctl import
_lib_dir = os.path.join(os.path.dirname(__file__), '..', '..', 'lib')
if os.path.abspath(_lib_dir) not in sys.path:
    sys.path.insert(0, os.path.abspath(_lib_dir))

from pagerctl import Pager

# =============================================================================
# THEME SYSTEM
# =============================================================================
# Theme names (for cycling)
THEME_NAMES = ['Default', 'Cyberpunk', 'Matrix', 'Synthwave']

# View themes (for main pagergotchi display)
VIEW_THEMES = {
    'Default': {
        'bg': Pager.BLACK,
        'text': Pager.WHITE,
        'face': Pager.WHITE,
        'label': Pager.WHITE,
        'line': Pager.WHITE,
        'status': Pager.WHITE,
    },
    'Cyberpunk': {
        'bg': Pager.rgb(10, 15, 35),
        'text': Pager.rgb(0, 230, 255),      # Cyan
        'face': Pager.rgb(0, 255, 255),      # Bright cyan
        'label': Pager.rgb(140, 150, 170),   # Cool gray
        'line': Pager.rgb(60, 80, 120),      # Dim blue
        'status': Pager.rgb(0, 230, 255),    # Cyan
    },
    'Matrix': {
        'bg': Pager.rgb(0, 10, 0),
        'text': Pager.rgb(0, 255, 0),        # Bright green
        'face': Pager.rgb(50, 255, 50),      # Phosphor green
        'label': Pager.rgb(0, 180, 0),       # Medium green
        'line': Pager.rgb(0, 80, 0),         # Dark green
        'status': Pager.rgb(0, 255, 0),      # Bright green
    },
    'Synthwave': {
        'bg': Pager.rgb(15, 5, 25),
        'text': Pager.rgb(255, 100, 200),    # Hot pink
        'face': Pager.rgb(0, 255, 255),      # Cyan
        'label': Pager.rgb(180, 100, 255),   # Purple
        'line': Pager.rgb(100, 50, 150),     # Dark purple
        'status': Pager.rgb(255, 150, 220),  # Light pink
    },
}

# Menu themes (for startup/pause menus)
MENU_THEMES = {
    'Default': {
        'bg': Pager.BLACK,
        'title': Pager.rgb(100, 200, 255),   # Light blue for title
        'selected': Pager.GREEN,
        'unselected': Pager.WHITE,
        'on': Pager.GREEN,
        'off': Pager.RED,
        'dim': Pager.GRAY,
        'accent': Pager.YELLOW,
        'warning': Pager.rgb(255, 100, 0),
        'submenu': Pager.YELLOW,
    },
    'Cyberpunk': {
        'bg': Pager.rgb(10, 15, 35),
        'title': Pager.rgb(0, 255, 255),
        'selected': Pager.rgb(0, 230, 255),
        'unselected': Pager.rgb(140, 150, 170),
        'on': Pager.rgb(0, 255, 100),
        'off': Pager.rgb(255, 0, 150),
        'dim': Pager.rgb(60, 80, 100),
        'accent': Pager.rgb(255, 50, 200),
        'warning': Pager.rgb(255, 100, 0),
        'submenu': Pager.rgb(180, 100, 255),
    },
    'Matrix': {
        'bg': Pager.rgb(0, 10, 0),
        'title': Pager.rgb(50, 255, 50),
        'selected': Pager.rgb(0, 255, 0),
        'unselected': Pager.rgb(0, 150, 0),
        'on': Pager.rgb(0, 255, 0),
        'off': Pager.rgb(100, 0, 0),
        'dim': Pager.rgb(0, 80, 0),
        'accent': Pager.rgb(100, 255, 100),
        'warning': Pager.rgb(255, 100, 0),
        'submenu': Pager.rgb(0, 200, 0),
    },
    'Synthwave': {
        'bg': Pager.rgb(15, 5, 25),
        'title': Pager.rgb(255, 100, 200),
        'selected': Pager.rgb(0, 255, 255),
        'unselected': Pager.rgb(180, 100, 255),
        'on': Pager.rgb(0, 255, 200),
        'off': Pager.rgb(255, 50, 100),
        'dim': Pager.rgb(100, 50, 120),
        'accent': Pager.rgb(255, 200, 100),
        'warning': Pager.rgb(255, 100, 50),
        'submenu': Pager.rgb(255, 150, 220),
    },
}

def get_current_theme_name():
    """Get current theme name from settings"""
    settings = load_settings()
    return settings.get('theme', 'Default')

def get_view_theme():
    """Get view theme colors for current theme"""
    name = get_current_theme_name()
    return VIEW_THEMES.get(name, VIEW_THEMES['Default'])

def get_menu_theme():
    """Get menu theme colors for current theme"""
    name = get_current_theme_name()
    return MENU_THEMES.get(name, MENU_THEMES['Default'])



class StartupMenu:
    """
    Startup menu with whitelist/blacklist management
    Uses libpagerctl.so for fast rendering
    """

    def __init__(self, config, display=None):
        self.config = config
        self.config_path = config.get('config_path', os.path.join(PAYLOAD_DIR, 'config.conf'))

        # Use provided display or create new one
        if display:
            self.gfx = display
            self._owns_display = False
        else:
            self.gfx = Pager()
            self.gfx.init()
            self.gfx.set_rotation(270)
            self._owns_display = True

        # Load all settings from persistent file
        self.settings = load_settings()
        self.wigle_enabled = self.settings.get('wigle_enabled', False)
        self.log_aps_enabled = self.settings.get('log_aps_enabled', False)
        self.deauth_enabled = self.settings.get('deauth_enabled', True)
        self.privacy_mode = self.settings.get('privacy_mode', False)

        # Load whitelist and blacklist (new format with BSSID)
        # Format: [{"ssid": "name", "bssid": "XX:XX:XX:XX:XX:XX"}, ...]
        self.whitelist = self.settings.get('whitelist', [])
        self.blacklist = self.settings.get('blacklist', [])

        # Migrate old whitelist format if needed
        self._migrate_old_whitelist()

    def _migrate_old_whitelist(self):
        """Migrate old whitelist format (list of strings) to new format (list of dicts)"""
        # Check if whitelist needs migration
        if self.whitelist and isinstance(self.whitelist[0], str):
            self.whitelist = [{'ssid': ssid, 'bssid': ''} for ssid in self.whitelist]
            self._save_lists()

        # Also try to import from old config file format
        try:
            with open(self.config_path, 'r') as f:
                for line in f:
                    if line.strip().startswith('ssids'):
                        parts = line.split('=', 1)
                        if len(parts) > 1:
                            ssids = parts[1].strip()
                            for ssid in ssids.split(','):
                                ssid = ssid.strip()
                                if ssid and not self._is_in_list(self.whitelist, ssid):
                                    self.whitelist.append({'ssid': ssid, 'bssid': ''})
                            self._save_lists()
                        break
        except:
            pass

    def _is_in_list(self, lst, ssid_or_bssid):
        """Check if SSID or BSSID is in a list"""
        for entry in lst:
            if entry.get('ssid', '').lower() == ssid_or_bssid.lower():
                return True
            if entry.get('bssid', '').lower() == ssid_or_bssid.lower():
                return True
        return False

    def _save_lists(self):
        """Save whitelist and blacklist to settings file"""
        self.settings['whitelist'] = self.whitelist
        self.settings['blacklist'] = self.blacklist
        self.settings['deauth_enabled'] = self.deauth_enabled
        save_settings(self.settings)

        # Also save to config file for compatibility
        try:
            ssids = [e.get('ssid', '') for e in self.whitelist if e.get('ssid')]
            with open(self.config_path, 'r') as f:
                lines = f.readlines()
            with open(self.config_path, 'w') as f:
                found_ssids = False
                for line in lines:
                    if line.strip().startswith('ssids'):
                        f.write(f"ssids = {', '.join(ssids)}\n")
                        found_ssids = True
                    else:
                        f.write(line)
                if not found_ssids and ssids:
                    f.write(f"\n[whitelist]\nssids = {', '.join(ssids)}\n")
        except:
            pass

    def scan_networks(self):
        """Scan for nearby WiFi networks using PineAP, returns list of {ssid, bssid} dicts"""
        networks = []
        seen_bssids = set()

        # Try PineAP first (best option on Pineapple)
        try:
            result = subprocess.run(
                ['_pineap', 'RECON', 'APS', 'limit=50', 'format=json'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0 and result.stdout.strip():
                try:
                    data = json.loads(result.stdout)
                    aps_list = data if isinstance(data, list) else data.get('aps', data.get('data', []))
                    for ap in aps_list:
                        bssid = ap.get('mac', ap.get('bssid', ''))
                        ssid = ''

                        # Try top-level ssid first
                        ssid = ap.get('ssid', ap.get('essid', ap.get('name', '')))

                        # If no ssid at top level, check inside beacon dict
                        if not ssid and 'beacon' in ap:
                            beacon = ap['beacon']
                            if isinstance(beacon, dict):
                                for beacon_key, beacon_data in beacon.items():
                                    if isinstance(beacon_data, dict):
                                        ssid = beacon_data.get('ssid', '')
                                        if ssid:
                                            break

                        # Also check response dict
                        if not ssid and 'response' in ap:
                            response = ap['response']
                            if isinstance(response, dict):
                                for resp_key, resp_data in response.items():
                                    if isinstance(resp_data, dict):
                                        ssid = resp_data.get('ssid', '')
                                        if ssid:
                                            break

                        if bssid and bssid not in seen_bssids:
                            seen_bssids.add(bssid)
                            networks.append({'ssid': ssid or '<hidden>', 'bssid': bssid})
                except json.JSONDecodeError:
                    pass
        except Exception:
            pass

        # Fallback to iwinfo
        if not networks:
            try:
                result = subprocess.run(
                    ['iwinfo', 'wlan0', 'scan'],
                    capture_output=True, text=True, timeout=15
                )
                if result.returncode == 0:
                    current_bssid = None
                    for line in result.stdout.split('\n'):
                        if 'Address:' in line:
                            parts = line.split('Address:')
                            if len(parts) > 1:
                                current_bssid = parts[1].strip()
                        elif 'ESSID:' in line:
                            ssid = line.split('ESSID:')[1].strip().strip('"')
                            if current_bssid and current_bssid not in seen_bssids:
                                seen_bssids.add(current_bssid)
                                networks.append({'ssid': ssid or '<hidden>', 'bssid': current_bssid})
            except:
                pass

        return networks[:20]

    def _wait_button(self, timeout=None):
        """Wait for a button press using thread-safe event queue"""
        start = time.time()
        while True:
            if timeout and (time.time() - start) > timeout:
                return None

            # poll_input() reads hardware and populates the event queue
            self.gfx.poll_input()

            # Consume events from the thread-safe queue
            event = self.gfx.get_input_event()
            if event:
                button, event_type, timestamp = event
                # Only react to press events
                if event_type == Pager.EVENT_PRESS:
                    if button == Pager.BTN_UP:
                        return 'UP'
                    if button == Pager.BTN_DOWN:
                        return 'DOWN'
                    if button == Pager.BTN_LEFT:
                        return 'LEFT'
                    if button == Pager.BTN_RIGHT:
                        return 'RIGHT'
                    if button == Pager.BTN_A:  # GREEN button = Select
                        return 'SELECT'
                    if button == Pager.BTN_B:  # RED button = Exit/Back
                        return 'BACK'
            else:
                time.sleep(0.016)

    def _save_toggle_settings(self):
        """Save toggle settings to persistent file"""
        self.settings['wigle_enabled'] = self.wigle_enabled
        self.settings['log_aps_enabled'] = self.log_aps_enabled
        self.settings['deauth_enabled'] = self.deauth_enabled
        self.settings['privacy_mode'] = self.privacy_mode
        save_settings(self.settings)

        # Update in-memory config
        if 'wigle' not in self.config:
            self.config['wigle'] = {}
        if 'log_aps' not in self.config:
            self.config['log_aps'] = {}
        self.config['wigle']['enabled'] = self.wigle_enabled
        self.config['log_aps']['enabled'] = self.log_aps_enabled
        if 'personality' not in self.config:
            self.config['personality'] = {}
        self.config['personality']['deauth'] = self.deauth_enabled

    def _draw_main_menu(self, selected, options):
        """Draw the main menu"""
        theme = get_menu_theme()
        self.gfx.clear(theme['bg'])

        # Title using TTF font - larger and centered
        self.gfx.draw_ttf_centered(0, "PagerGotchi", theme['title'], FONT_LOVEDAYS, 62.0)

        # Menu options - centered vertically
        y = 68
        for i, opt in enumerate(options):
            is_toggle = opt.startswith('Privacy:') or opt.startswith('WiGLE:') or opt.startswith('Log APs:')

            if is_toggle:
                # Handle toggle options - use fixed label position so it doesn't shift
                if opt.startswith('Privacy:'):
                    label = "Privacy:"
                    value = "ON" if self.privacy_mode else "OFF"
                    value_color = theme['on'] if self.privacy_mode else theme['off']
                elif opt.startswith('WiGLE:'):
                    label = "WiGLE:"
                    value = "Yes" if self.wigle_enabled else "No"
                    value_color = theme['on'] if self.wigle_enabled else theme['off']
                else:
                    label = "Log APs:"
                    value = "Yes" if self.log_aps_enabled else "No"
                    value_color = theme['on'] if self.log_aps_enabled else theme['off']

                label_color = theme['selected'] if i == selected else theme['unselected']
                # Use widest possible value ("OFF") to calculate fixed position
                max_value = "OFF"
                label_width = self.gfx.ttf_width(label, FONT_DEJAVU, TTF_MEDIUM)
                max_value_width = self.gfx.ttf_width(max_value, FONT_DEJAVU, TTF_MEDIUM)
                total_width = label_width + 8 + max_value_width  # 8px gap between label and value
                start_x = (480 - total_width) // 2
                self.gfx.draw_ttf(start_x, y + 6, label, label_color, FONT_DEJAVU, TTF_MEDIUM)
                self.gfx.draw_ttf(start_x + label_width + 8, y + 6, value, value_color, FONT_DEJAVU, TTF_MEDIUM)
            else:
                color = theme['selected'] if i == selected else theme['unselected']
                self.gfx.draw_ttf_centered(y + 6, opt, color, FONT_DEJAVU, TTF_MEDIUM)
            y += 25

        self.gfx.flip()

    def show_main_menu(self):
        """
        Show main startup menu
        Returns True to continue to pagergotchi, False to exit
        """
        selected = 0
        options = [
            'Start Pagergotchi',
            'Deauth Scope',
            'Privacy:',
            'WiGLE:',
            'Log APs:',
            'Clear History'
        ]

        self._draw_main_menu(selected, options)

        while True:
            btn = self._wait_button()

            if btn == 'UP':
                selected = (selected - 1) % len(options)
                self._draw_main_menu(selected, options)
            elif btn == 'DOWN':
                selected = (selected + 1) % len(options)
                self._draw_main_menu(selected, options)
            elif btn in ['LEFT', 'RIGHT']:
                # Handle toggles
                if selected == 2:  # Privacy toggle
                    self.privacy_mode = not self.privacy_mode
                    self._save_toggle_settings()
                    self._draw_main_menu(selected, options)
                elif selected == 3:  # WiGLE toggle
                    self.wigle_enabled = not self.wigle_enabled
                    if self.wigle_enabled:
                        self.log_aps_enabled = True
                    self._save_toggle_settings()
                    self._draw_main_menu(selected, options)
                elif selected == 4:  # Log APs toggle
                    self.log_aps_enabled = not self.log_aps_enabled
                    if not self.log_aps_enabled:
                        self.wigle_enabled = False
                    self._save_toggle_settings()
                    self._draw_main_menu(selected, options)
            elif btn == 'SELECT':
                if selected == 0:  # Start
                    return True
                elif selected == 1:  # Deauth Scope
                    self.show_deauth_scope_menu()
                    self._draw_main_menu(selected, options)
                elif selected == 2:  # Privacy toggle
                    self.privacy_mode = not self.privacy_mode
                    self._save_toggle_settings()
                    self._draw_main_menu(selected, options)
                elif selected == 3:  # WiGLE toggle
                    self.wigle_enabled = not self.wigle_enabled
                    if self.wigle_enabled:
                        self.log_aps_enabled = True
                    self._save_toggle_settings()
                    self._draw_main_menu(selected, options)
                elif selected == 4:  # Log APs toggle
                    self.log_aps_enabled = not self.log_aps_enabled
                    if not self.log_aps_enabled:
                        self.wigle_enabled = False
                    self._save_toggle_settings()
                    self._draw_main_menu(selected, options)
                elif selected == 5:  # Clear History
                    self.clear_history_confirm()
                    self._draw_main_menu(selected, options)
            elif btn == 'BACK':
                # Show exit confirmation dialog
                if self._show_exit_confirm():
                    return False
                self._draw_main_menu(selected, options)

    def _show_exit_confirm(self):
        """Show exit confirmation dialog. Returns True if user confirms exit."""
        selected = 1  # Default to No

        while True:
            theme = get_menu_theme()
            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(60, "Exit Pagergotchi?", theme['warning'], FONT_DEJAVU, TTF_LARGE)

            center = self.gfx.width // 2
            yes_color = theme['selected'] if selected == 0 else theme['unselected']
            no_color = theme['selected'] if selected == 1 else theme['unselected']
            self.gfx.draw_ttf(center - 85, 115, "YES", yes_color, FONT_DEJAVU, TTF_MEDIUM)
            self.gfx.draw_ttf(center + 45, 115, "NO", no_color, FONT_DEJAVU, TTF_MEDIUM)

            self.gfx.flip()

            btn = self._wait_button()
            if btn in ['LEFT', 'RIGHT', 'UP', 'DOWN']:
                selected = 1 - selected
            elif btn == 'SELECT':
                return selected == 0  # True if YES selected
            elif btn == 'BACK':
                return False  # Cancel exit

    def show_deauth_scope_menu(self):
        """Show Deauth Scope submenu with Deauth toggle and Whitelist/Blacklist options"""
        selected = 0

        while True:
            theme = get_menu_theme()
            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(12, "DEAUTH SCOPE", theme['submenu'], FONT_DEJAVU, TTF_LARGE)

            y = 55

            # Option 0: Deauth toggle - fixed position so it doesn't shift
            label = "Deauth:"
            value = "ON" if self.deauth_enabled else "OFF"
            value_color = theme['on'] if self.deauth_enabled else theme['off']
            label_color = theme['selected'] if selected == 0 else theme['unselected']
            # Use widest value ("OFF") to calculate fixed position
            label_width = self.gfx.ttf_width(label, FONT_DEJAVU, TTF_MEDIUM)
            max_value_width = self.gfx.ttf_width("OFF", FONT_DEJAVU, TTF_MEDIUM)
            total_width = label_width + 8 + max_value_width
            start_x = (self.gfx.width - total_width) // 2
            self.gfx.draw_ttf(start_x, y + 4, label, label_color, FONT_DEJAVU, TTF_MEDIUM)
            self.gfx.draw_ttf(start_x + label_width + 8, y + 4, value, value_color, FONT_DEJAVU, TTF_MEDIUM)
            y += 35

            # Options 1-3: White List, Black List, Back
            menu_options = [
                ('White List', 'Do Not Target'),
                ('Black List', 'Target Only These'),
                ('Back', '')
            ]
            for i, (label, desc) in enumerate(menu_options):
                opt_idx = i + 1  # Offset by 1 for Deauth toggle
                color = theme['selected'] if opt_idx == selected else theme['unselected']
                self.gfx.draw_ttf_centered(y + 2, label, color, FONT_DEJAVU, TTF_MEDIUM)
                if desc:
                    self.gfx.draw_ttf_centered(y + 22, f"({desc})", theme['dim'], FONT_DEJAVU, TTF_SMALL)
                y += 40

            # Show current counts at bottom (no instruction line)
            wl_count = len(self.whitelist)
            bl_count = len(self.blacklist)
            self.gfx.draw_ttf_centered(self.gfx.height - 20, f"Whitelist: {wl_count}  Blacklist: {bl_count}", theme['dim'], FONT_DEJAVU, TTF_SMALL)
            self.gfx.flip()

            btn = self._wait_button()
            num_options = 4  # Deauth, White List, Black List, Back
            if btn == 'UP':
                selected = (selected - 1) % num_options
            elif btn == 'DOWN':
                selected = (selected + 1) % num_options
            elif btn in ['LEFT', 'RIGHT']:
                if selected == 0:  # Deauth toggle
                    self.deauth_enabled = not self.deauth_enabled
                    self._save_toggle_settings()
            elif btn == 'SELECT':
                if selected == 0:  # Deauth toggle
                    self.deauth_enabled = not self.deauth_enabled
                    self._save_toggle_settings()
                elif selected == 1:  # White List
                    self.show_list_menu('whitelist')
                elif selected == 2:  # Black List
                    self.show_list_menu('blacklist')
                elif selected == 3:  # Back
                    return
            elif btn == 'BACK':
                return

    def show_list_menu(self, list_type):
        """Show submenu for managing a whitelist or blacklist"""
        title = "WHITE LIST" if list_type == 'whitelist' else "BLACK LIST"
        the_list = self.whitelist if list_type == 'whitelist' else self.blacklist

        selected = 0
        options = ['Scan & Add', 'Manual Add', 'View/Edit List', 'Back']

        while True:
            theme = get_menu_theme()
            # Refresh list reference in case it was modified
            the_list = self.whitelist if list_type == 'whitelist' else self.blacklist
            title_color = theme['title'] if list_type == 'whitelist' else theme['accent']

            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(12, title, title_color, FONT_DEJAVU, TTF_LARGE)
            self.gfx.draw_ttf_centered(40, f"{len(the_list)} entries", theme['dim'], FONT_DEJAVU, TTF_SMALL)

            y = 65
            for i, opt in enumerate(options):
                color = theme['selected'] if i == selected else theme['unselected']
                self.gfx.draw_ttf_centered(y + 4, opt, color, FONT_DEJAVU, TTF_MEDIUM)
                y += 32

            self.gfx.flip()

            btn = self._wait_button()
            if btn == 'UP':
                selected = (selected - 1) % len(options)
            elif btn == 'DOWN':
                selected = (selected + 1) % len(options)
            elif btn == 'SELECT':
                if selected == 0:  # Scan & Add
                    self.show_scan_add(list_type)
                elif selected == 1:  # Manual Add
                    self.show_manual_add(list_type)
                elif selected == 2:  # View List
                    self.show_view_list(list_type)
                elif selected == 3:  # Back
                    return
            elif btn == 'BACK':
                return

    def show_scan_add(self, list_type):
        """Scan for networks and add to whitelist or blacklist"""
        title = "ADD TO WHITELIST" if list_type == 'whitelist' else "ADD TO BLACKLIST"
        the_list = self.whitelist if list_type == 'whitelist' else self.blacklist

        theme = get_menu_theme()
        title_color = theme['title'] if list_type == 'whitelist' else theme['accent']

        self.gfx.clear(theme['bg'])
        self.gfx.draw_ttf_centered(100, "Scanning...", theme['submenu'], FONT_DEJAVU, TTF_LARGE)
        self.gfx.flip()

        networks = self.scan_networks()

        if not networks:
            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(80, "No networks found!", theme['warning'], FONT_DEJAVU, TTF_MEDIUM)
            self.gfx.draw_ttf_centered(110, "Try again later", theme['dim'], FONT_DEJAVU, TTF_SMALL)
            self.gfx.draw_ttf_centered(180, "Press any button...", theme['dim'], FONT_DEJAVU, TTF_SMALL)
            self.gfx.flip()
            self._wait_button()
            return

        selected = 0
        scroll_offset = 0
        max_visible = 4

        while True:
            theme = get_menu_theme()
            the_list = self.whitelist if list_type == 'whitelist' else self.blacklist
            title_color = theme['title'] if list_type == 'whitelist' else theme['accent']

            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(8, title, title_color, FONT_DEJAVU, TTF_MEDIUM)

            y = 38
            for i in range(scroll_offset, min(scroll_offset + max_visible, len(networks))):
                net = networks[i]
                ssid = net['ssid']
                bssid = net.get('bssid', '')
                is_in_list = self._is_in_list(the_list, ssid) or self._is_in_list(the_list, bssid)

                # Apply privacy obfuscation for display only
                display_ssid = obfuscate_ssid(ssid) if self.privacy_mode else ssid
                display_bssid = obfuscate_mac(bssid) if self.privacy_mode else bssid

                color = theme['selected'] if i == selected else theme['unselected']
                prefix = "[+] " if is_in_list else "    "
                display_color = theme['on'] if is_in_list else color

                # Show SSID on first line, BSSID in parenthesis on second
                self.gfx.draw_ttf(15, y, f"{prefix}{display_ssid[:22]}", display_color, FONT_DEJAVU, TTF_MEDIUM)
                if display_bssid:
                    self.gfx.draw_ttf(15, y + 20, f"    ({display_bssid})", theme['dim'], FONT_DEJAVU, TTF_SMALL)
                y += 42

            self.gfx.flip()

            btn = self._wait_button()
            if btn == 'UP':
                selected = max(0, selected - 1)
                if selected < scroll_offset:
                    scroll_offset = selected
            elif btn == 'DOWN':
                selected = min(len(networks) - 1, selected + 1)
                if selected >= scroll_offset + max_visible:
                    scroll_offset = selected - max_visible + 1
            elif btn == 'SELECT':
                net = networks[selected]
                if not self._is_in_list(the_list, net['ssid']) and not self._is_in_list(the_list, net.get('bssid', '')):
                    entry = {'ssid': net['ssid'], 'bssid': net.get('bssid', '')}
                    if list_type == 'whitelist':
                        self.whitelist.append(entry)
                    else:
                        self.blacklist.append(entry)
                    self._save_lists()

                    self.gfx.clear(theme['bg'])
                    self.gfx.draw_ttf_centered(100, "Added!", theme['on'], FONT_DEJAVU, TTF_LARGE)
                    self.gfx.flip()
                    time.sleep(0.5)
            elif btn == 'BACK':
                return

    def show_manual_add(self, list_type):
        """Manually add SSID or BSSID to list using character input"""
        title = "MANUAL ADD"
        subtitle = "to Whitelist" if list_type == 'whitelist' else "to Blacklist"

        # Character set for input
        chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:.-_<"
        # < is backspace, we'll handle it specially

        input_text = ""
        char_index = 0
        input_type = 0  # 0 = SSID, 1 = BSSID
        types = ['SSID', 'BSSID']

        while True:
            theme = get_menu_theme()
            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(8, title, theme['submenu'], FONT_DEJAVU, TTF_MEDIUM)
            self.gfx.draw_ttf_centered(30, subtitle, theme['dim'], FONT_DEJAVU, TTF_SMALL)

            # Input type selector
            type_text = f"Type: {types[input_type]}"
            self.gfx.draw_ttf_centered(52, type_text, theme['title'], FONT_DEJAVU, TTF_MEDIUM)

            # Current input
            display_text = input_text if input_text else "(empty)"
            self.gfx.draw_ttf_centered(82, display_text[:24], theme['unselected'], FONT_DEJAVU, TTF_MEDIUM)

            # Character selector
            self.gfx.draw_ttf_centered(115, "Select character:", theme['dim'], FONT_DEJAVU, TTF_SMALL)

            # Show 7 characters centered on current selection
            visible_chars = 7
            start = max(0, char_index - visible_chars // 2)
            end = min(len(chars), start + visible_chars)
            if end - start < visible_chars:
                start = max(0, end - visible_chars)

            x = 140
            for i in range(start, end):
                ch = chars[i]
                display_ch = "BS" if ch == '<' else ch
                if i == char_index:
                    self.gfx.fill_rect(x - 2, 132, 30 if ch == '<' else 22, 26, theme['dim'])
                    self.gfx.draw_ttf(x, 135, display_ch, theme['selected'], FONT_DEJAVU, TTF_MEDIUM)
                else:
                    self.gfx.draw_ttf(x, 135, display_ch, theme['unselected'], FONT_DEJAVU, TTF_MEDIUM)
                x += 30 if ch == '<' else 22

            self.gfx.flip()

            btn = self._wait_button()
            if btn == 'UP':
                input_type = (input_type - 1) % len(types)
            elif btn == 'DOWN':
                input_type = (input_type + 1) % len(types)
            elif btn == 'LEFT':
                char_index = (char_index - 1) % len(chars)
            elif btn == 'RIGHT':
                char_index = (char_index + 1) % len(chars)
            elif btn == 'SELECT':
                ch = chars[char_index]
                if ch == '<':  # Backspace
                    if input_text:
                        input_text = input_text[:-1]
                else:
                    if len(input_text) < 32:
                        input_text += ch
            elif btn == 'BACK':
                if input_text:
                    # Save the entry
                    entry = {'ssid': '', 'bssid': ''}
                    if input_type == 0:  # SSID
                        entry['ssid'] = input_text
                    else:  # BSSID
                        entry['bssid'] = input_text.upper()

                    the_list = self.whitelist if list_type == 'whitelist' else self.blacklist
                    if not self._is_in_list(the_list, entry.get('ssid', '')) and not self._is_in_list(the_list, entry.get('bssid', '')):
                        if list_type == 'whitelist':
                            self.whitelist.append(entry)
                        else:
                            self.blacklist.append(entry)
                        self._save_lists()

                        self.gfx.clear(theme['bg'])
                        self.gfx.draw_ttf_centered(100, "Added!", theme['on'], FONT_DEJAVU, TTF_LARGE)
                        self.gfx.flip()
                        time.sleep(0.5)
                return

    def show_view_list(self, list_type):
        """View and delete entries from whitelist or blacklist"""
        title = "WHITE LIST" if list_type == 'whitelist' else "BLACK LIST"

        selected = 0
        scroll_offset = 0
        max_visible = 4

        while True:
            theme = get_menu_theme()
            the_list = self.whitelist if list_type == 'whitelist' else self.blacklist
            title_color = theme['title'] if list_type == 'whitelist' else theme['accent']

            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(8, title, title_color, FONT_DEJAVU, TTF_MEDIUM)

            if not the_list:
                self.gfx.draw_ttf_centered(100, "List is empty", theme['dim'], FONT_DEJAVU, TTF_MEDIUM)
            else:
                y = 38
                for i in range(scroll_offset, min(scroll_offset + max_visible, len(the_list))):
                    entry = the_list[i]
                    ssid = entry.get('ssid', '')
                    bssid = entry.get('bssid', '')

                    # Apply privacy obfuscation for display only
                    display_ssid = obfuscate_ssid(ssid) if self.privacy_mode and ssid else ssid
                    display_bssid = obfuscate_mac(bssid) if self.privacy_mode and bssid else bssid

                    color = theme['selected'] if i == selected else theme['unselected']

                    # Show SSID or BSSID on first line
                    display_name = display_ssid if ssid else display_bssid
                    self.gfx.draw_ttf(15, y, display_name[:24], color, FONT_DEJAVU, TTF_MEDIUM)

                    # Show BSSID in parenthesis if we have both
                    if ssid and bssid:
                        self.gfx.draw_ttf(15, y + 20, f"({display_bssid})", theme['dim'], FONT_DEJAVU, TTF_SMALL)
                    elif bssid and not ssid:
                        self.gfx.draw_ttf(15, y + 20, "(BSSID only)", theme['dim'], FONT_DEJAVU, TTF_SMALL)

                    y += 42

            self.gfx.flip()

            btn = self._wait_button()
            if btn == 'UP' and the_list:
                selected = max(0, selected - 1)
                if selected < scroll_offset:
                    scroll_offset = selected
            elif btn == 'DOWN' and the_list:
                selected = min(len(the_list) - 1, selected + 1)
                if selected >= scroll_offset + max_visible:
                    scroll_offset = selected - max_visible + 1
            elif btn == 'SELECT' and the_list:
                # Delete entry
                if list_type == 'whitelist':
                    self.whitelist.pop(selected)
                else:
                    self.blacklist.pop(selected)
                self._save_lists()

                # Adjust selection
                the_list = self.whitelist if list_type == 'whitelist' else self.blacklist
                if selected >= len(the_list) and the_list:
                    selected = len(the_list) - 1
                if scroll_offset > 0 and scroll_offset >= len(the_list):
                    scroll_offset = max(0, len(the_list) - max_visible)
            elif btn == 'BACK':
                return

    def clear_whitelist_confirm(self):
        """Confirm clearing whitelist"""
        selected = 1  # Default to No

        while True:
            theme = get_menu_theme()
            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(50, "Clear Whitelist?", theme['warning'], FONT_DEJAVU, TTF_LARGE)
            self.gfx.draw_ttf_centered(85, "This cannot be undone!", theme['off'], FONT_DEJAVU, TTF_SMALL)

            center = self.gfx.width // 2
            yes_color = theme['selected'] if selected == 0 else theme['unselected']
            no_color = theme['selected'] if selected == 1 else theme['unselected']
            self.gfx.draw_ttf(center - 85, 125, "YES", yes_color, FONT_DEJAVU, TTF_MEDIUM)
            self.gfx.draw_ttf(center + 45, 125, "NO", no_color, FONT_DEJAVU, TTF_MEDIUM)

            self.gfx.flip()

            btn = self._wait_button()
            if btn in ['LEFT', 'RIGHT', 'UP', 'DOWN']:
                selected = 1 - selected
            elif btn == 'SELECT':
                if selected == 0:
                    self.save_whitelist([])
                    self.gfx.clear(theme['bg'])
                    self.gfx.draw_ttf_centered(100, "Cleared!", theme['on'], FONT_DEJAVU, TTF_LARGE)
                    self.gfx.flip()
                    time.sleep(0.5)
                return
            elif btn == 'BACK':
                return

    def clear_history_confirm(self):
        """Confirm clearing attack history (recovery file)"""
        selected = 1  # Default to No

        while True:
            theme = get_menu_theme()
            self.gfx.clear(theme['bg'])
            self.gfx.draw_ttf_centered(40, "Clear History?", theme['warning'], FONT_DEJAVU, TTF_LARGE)
            self.gfx.draw_ttf_centered(75, "Resets attack tracking", theme['dim'], FONT_DEJAVU, TTF_SMALL)
            self.gfx.draw_ttf_centered(95, "for all networks", theme['dim'], FONT_DEJAVU, TTF_SMALL)

            center = self.gfx.width // 2
            yes_color = theme['selected'] if selected == 0 else theme['unselected']
            no_color = theme['selected'] if selected == 1 else theme['unselected']
            self.gfx.draw_ttf(center - 85, 135, "YES", yes_color, FONT_DEJAVU, TTF_MEDIUM)
            self.gfx.draw_ttf(center + 45, 135, "NO", no_color, FONT_DEJAVU, TTF_MEDIUM)

            self.gfx.flip()

            btn = self._wait_button()
            if btn in ['LEFT', 'RIGHT', 'UP', 'DOWN']:
                selected = 1 - selected
            elif btn == 'SELECT':
                if selected == 0:
                    try:
                        if os.path.exists(RECOVERY_FILE):
                            os.remove(RECOVERY_FILE)
                    except Exception:
                        pass
                    self.gfx.clear(theme['bg'])
                    self.gfx.draw_ttf_centered(100, "History Cleared!", theme['on'], FONT_DEJAVU, TTF_LARGE)
                    self.gfx.flip()
                    time.sleep(0.5)
                return
            elif btn == 'BACK':
                return

    def cleanup(self):
        """Clean up resources"""
        if self._owns_display and hasattr(self, 'gfx'):
            self.gfx.cleanup()


# Privacy mode fixed GPS coordinates
PRIVACY_GPS_LAT = 38.871
PRIVACY_GPS_LON = -77.055


def load_settings():
    """Load settings from persistent file"""
    defaults = {
        'deauth_enabled': True,
        'privacy_mode': False,
        'whitelist': [],  # List of {ssid, bssid} dicts - do not target
        'blacklist': [],  # List of {ssid, bssid} dicts - target only these
        'wigle_enabled': False,
        'log_aps_enabled': False,
        'theme': 'Default',  # Theme name: Default, Cyberpunk, Matrix, Synthwave
    }
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                saved = json.load(f)
                defaults.update(saved)
    except Exception:
        pass
    return defaults


def save_settings(settings):
    """Save settings to persistent file"""
    try:
        if not os.path.exists(DATA_DIR):
            os.makedirs(DATA_DIR)
        with open(SETTINGS_FILE, 'w') as f:
            json.dump(settings, f)
    except Exception:
        pass


def obfuscate_mac(mac):
    """AB:CD:EF:12:34:56 -> AB:CD:EF:XX:XX:XX"""
    parts = mac.split(':')
    if len(parts) == 6:
        return ':'.join(parts[:3] + ['XX', 'XX', 'XX'])
    return mac


def obfuscate_ssid(ssid):
    """CLOWNCAR -> CXXXXXXR"""
    if not ssid or len(ssid) <= 2:
        return ssid
    return ssid[0] + 'X' * (len(ssid) - 2) + ssid[-1]


def obfuscate_gps(lat=None, lon=None):
    """Return fixed privacy coordinates"""
    return f"LAT {PRIVACY_GPS_LAT:.3f} LON {PRIVACY_GPS_LON:.3f}"


class PauseMenu:
    """
    Pause menu shown when red button is pressed during operation.

    Menu Options:
    1. Resume - Return to main pagergotchi screen
    2. Theme - Cycle through themes (Default, Cyberpunk, Matrix, Synthwave)
    3. Deauth - Toggle ON/OFF
    4. Privacy - Toggle ON/OFF (obfuscates MACs, SSIDs, GPS)
    5. Exit - Quit pagergotchi cleanly
    """

    def __init__(self, display, agent=None):
        self.gfx = display
        self.agent = agent

        # Load settings from persistent storage
        self.settings = load_settings()

        # Override deauth from agent config if available
        if agent and hasattr(agent, '_config'):
            self.settings['deauth_enabled'] = agent._config.get('personality', {}).get('deauth', True)

    def _wait_button(self):
        """Wait for a button press using thread-safe event queue"""
        while True:
            # poll_input() reads hardware and populates the event queue
            self.gfx.poll_input()

            # Consume events from the thread-safe queue
            event = self.gfx.get_input_event()
            if event:
                button, event_type, timestamp = event
                # Only react to press events
                if event_type == Pager.EVENT_PRESS:
                    if button == Pager.BTN_UP:
                        return 'UP'
                    if button == Pager.BTN_DOWN:
                        return 'DOWN'
                    if button == Pager.BTN_LEFT:
                        return 'LEFT'
                    if button == Pager.BTN_RIGHT:
                        return 'RIGHT'
                    if button == Pager.BTN_A:  # GREEN = Select
                        return 'SELECT'
                    if button == Pager.BTN_B:  # RED = Back/Resume
                        return 'BACK'
            else:
                time.sleep(0.016)

    def _cycle_theme(self, direction):
        """Cycle theme forward or backward"""
        current = self.settings.get('theme', 'Default')
        try:
            idx = THEME_NAMES.index(current)
        except ValueError:
            idx = 0
        if direction == 'RIGHT':
            idx = (idx + 1) % len(THEME_NAMES)
        else:  # LEFT
            idx = (idx - 1) % len(THEME_NAMES)
        self.settings['theme'] = THEME_NAMES[idx]
        save_settings(self.settings)

    def _draw_menu(self, selected):
        """Draw the pause menu"""
        theme = get_menu_theme()
        self.gfx.clear(theme['bg'])

        # Title
        self.gfx.draw_ttf_centered(12, "PAUSED", theme['warning'], FONT_DEJAVU, TTF_LARGE)

        # Menu options
        current_theme = self.settings.get('theme', 'Default')
        options = [
            ('Resume', None, None),
            ('Theme:', current_theme, 'Synthwave'),  # (label, value, max_value for width calc)
            ('Deauth:', 'ON' if self.settings['deauth_enabled'] else 'OFF', 'OFF'),
            ('Privacy:', 'ON' if self.settings['privacy_mode'] else 'OFF', 'OFF'),
            ('Main Menu', None, None)
        ]

        y = 48
        for i, (label, value, max_value) in enumerate(options):
            is_selected = (i == selected)

            if value is not None:
                # Toggle/cycle option with value - use fixed width so label doesn't shift
                label_color = theme['selected'] if is_selected else theme['unselected']

                # Determine value color based on option type
                if label == 'Theme:':
                    value_color = theme['accent']  # Theme name in accent color
                else:
                    value_color = theme['on'] if value == 'ON' else theme['off']

                # Calculate fixed positions using max value width
                label_width = self.gfx.ttf_width(label, FONT_DEJAVU, TTF_MEDIUM)
                max_value_width = self.gfx.ttf_width(max_value, FONT_DEJAVU, TTF_MEDIUM)
                total_width = label_width + 8 + max_value_width  # 8px gap

                # Center the label+value
                base_x = (self.gfx.width - total_width) // 2
                self.gfx.draw_ttf(base_x, y + 2, label, label_color, FONT_DEJAVU, TTF_MEDIUM)
                self.gfx.draw_ttf(base_x + label_width + 8, y + 2, value, value_color, FONT_DEJAVU, TTF_MEDIUM)
            else:
                # Simple option (Resume, Main Menu)
                color = theme['selected'] if is_selected else theme['unselected']
                self.gfx.draw_ttf_centered(y + 2, label, color, FONT_DEJAVU, TTF_MEDIUM)

            y += 28

        self.gfx.flip()

    def show(self):
        """
        Show pause menu.
        Returns: 'continue' or 'main_menu'
        """
        # Wait for button that triggered menu to be released
        for _ in range(25):
            if self.gfx.peek_buttons() == 0:
                break
            time.sleep(0.02)
        # Clear any pending events and small debounce
        self.gfx.clear_input_events()
        time.sleep(0.05)

        selected = 0
        num_options = 5

        self._draw_menu(selected)

        while True:
            btn = self._wait_button()

            if btn == 'UP':
                selected = (selected - 1) % num_options
                self._draw_menu(selected)
            elif btn == 'DOWN':
                selected = (selected + 1) % num_options
                self._draw_menu(selected)
            elif btn in ['LEFT', 'RIGHT']:
                if selected == 1:  # Theme
                    self._cycle_theme(btn)
                    self._draw_menu(selected)
                elif selected == 2:  # Deauth
                    self.settings['deauth_enabled'] = not self.settings['deauth_enabled']
                    if self.agent and hasattr(self.agent, '_config'):
                        self.agent._config['personality']['deauth'] = self.settings['deauth_enabled']
                    save_settings(self.settings)
                    self._draw_menu(selected)
                elif selected == 3:  # Privacy
                    self.settings['privacy_mode'] = not self.settings['privacy_mode']
                    save_settings(self.settings)
                    self._draw_menu(selected)
            elif btn == 'SELECT':
                if selected == 0:  # Resume
                    return 'continue'
                elif selected == 1:  # Theme - cycle forward on select
                    self._cycle_theme('RIGHT')
                    self._draw_menu(selected)
                elif selected == 2:  # Deauth toggle
                    self.settings['deauth_enabled'] = not self.settings['deauth_enabled']
                    if self.agent and hasattr(self.agent, '_config'):
                        self.agent._config['personality']['deauth'] = self.settings['deauth_enabled']
                    save_settings(self.settings)
                    self._draw_menu(selected)
                elif selected == 3:  # Privacy toggle
                    self.settings['privacy_mode'] = not self.settings['privacy_mode']
                    save_settings(self.settings)
                    self._draw_menu(selected)
                elif selected == 4:  # Main Menu
                    return 'main_menu'
            elif btn == 'BACK':
                return 'continue'
