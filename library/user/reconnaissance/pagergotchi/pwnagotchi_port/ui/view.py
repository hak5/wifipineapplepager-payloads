"""
View - Main UI rendering for Pagergotchi
Adapted from original pwnagotchi for native Pager display

Uses libpagerctl.so for native rendering instead of PIL
"""

import os
import sys
import threading
import logging
import random
import time
from threading import Lock

# Add lib directory to path for pagerctl import
_lib_dir = os.path.join(os.path.dirname(__file__), '..', '..', 'lib')
if os.path.abspath(_lib_dir) not in sys.path:
    sys.path.insert(0, os.path.abspath(_lib_dir))

from pagerctl import Pager

import pwnagotchi_port as pwnagotchi
import pwnagotchi_port.plugins as plugins
import pwnagotchi_port.ui.faces as faces
import pwnagotchi_port.utils as utils

from pwnagotchi_port.ui.components import Text, LabeledValue, Line
from pwnagotchi_port.ui.state import State
from pwnagotchi_port.voice import Voice
from pwnagotchi_port.ui.menu import (
    load_settings, save_settings, obfuscate_gps, get_view_theme, get_menu_theme,
    THEME_NAMES, FONT_DEJAVU, TTF_MEDIUM, TTF_LARGE, TTF_SMALL
)


# Font settings - use absolute path on Pager
# Font directory relative to this file (works on both dev machine and Pager)
_this_dir = os.path.dirname(os.path.abspath(__file__))
_payload_dir = os.path.abspath(os.path.join(_this_dir, '..', '..'))
_fonts_dir = os.path.join(_payload_dir, 'fonts')
FONT_PATH = os.path.join(_fonts_dir, 'DejaVuSansMono.ttf')

# Font sizes
FACE_TTF_SIZE = 64.0   # ASCII face size
LABEL_TTF_SIZE = 22.0  # Labels like CH, APS, UPTIME, BAT, etc.

# Padding between text and lines (in pixels)
LINE_PADDING = 5

# Auto-dim settings
AUTO_DIM_OPTIONS = [0, 30, 60]  # 0=Off, others are seconds
AUTO_DIM_LEVELS = [20, 30, 40, 50, 60]  # Brightness % when dimmed


def discover_launchers():
    """Scan for launch_*.sh files in payload directory.
    Returns list of (title, path) for each launcher found, excluding launch_pagergotchi.sh."""
    launchers = []
    try:
        for name in sorted(os.listdir(_payload_dir)):
            if not name.startswith('launch_') or not name.endswith('.sh'):
                continue
            if name == 'launch_pagergotchi.sh':
                continue
            path = os.path.join(_payload_dir, name)
            # Extract title and requirements from header comments
            title = name.replace('launch_', '').replace('.sh', '').capitalize()
            requires = None
            try:
                with open(path, 'r') as f:
                    for line in f:
                        if line.startswith('# Title:'):
                            title = line.split(':', 1)[1].strip()
                        elif line.startswith('# Requires:'):
                            requires = line.split(':', 1)[1].strip()
                        elif not line.startswith('#') and line.strip():
                            break
            except Exception:
                pass
            # Skip if required path doesn't exist
            if requires and not os.path.exists(requires):
                continue
            launchers.append((title, path))
    except Exception as e:
        logging.debug("Launcher discovery error: %s", e)
    return launchers

# Base layout - line positions calculated dynamically based on font height
LAYOUT = {
    'width': 480,
    'height': 222,
    'channel': (5, 0),
    'aps': (160, 0),
    'uptime': (340, 0),
    # line1 y-position calculated as: LABEL_TTF_SIZE + LINE_PADDING
    # line2 y-position calculated as: bottom_text_y - LINE_PADDING
    'shakes': (5, 0),  # y calculated dynamically
    'mode': (350, 0),  # y calculated dynamically (right-aligned)
    'name': (5, 0),    # y calculated dynamically
    'face': (10, 0),   # y calculated dynamically
    'status': {
        'pos': (180, 0),  # y calculated dynamically
        'max': 22
    },
    'friend_face': (0, 0),
    'friend_name': (40, 0),
    'gps': (150, 0),
}


class View:
    """
    Main UI View for Pagergotchi

    Renders to native Pager display using libpagerctl.so
    """

    def __init__(self, config, impl=None, state=None):
        self._agent = None
        self._config = config
        self._lock = Lock()
        self._frozen = False
        self._render_cbs = []

        # Log font path for debugging
        logging.info(f"[UI] Font path: {FONT_PATH}")
        logging.info(f"[UI] Font exists: {os.path.exists(FONT_PATH)}")

        # Initialize display
        self._display = Pager()
        self._display.init()
        self._display.set_rotation(270)  # Landscape mode

        # Get base layout
        self._layout = LAYOUT.copy()
        self._width = self._layout['width']
        self._height = self._layout['height']

        # Calculate font heights for dynamic layout
        label_height = self._display.ttf_height(FONT_PATH, LABEL_TTF_SIZE)
        face_height = self._display.ttf_height(FONT_PATH, FACE_TTF_SIZE)
        logging.info(f"[UI] Label height: {label_height}, Face height: {face_height}")

        # Calculate dynamic positions based on font heights
        # Top row at y=0: CH, APS, UPTIME
        # Line1 below top row
        line1_y = label_height + LINE_PADDING

        # Bottom row: PWND, BAT
        bottom_text_y = self._height - label_height
        # Line2 above bottom row
        line2_y = bottom_text_y - LINE_PADDING

        # Middle section
        name_y = line1_y + LINE_PADDING
        status_y = name_y
        friend_y = name_y

        # GPS just above line2 (LINE_PADDING gap)
        gps_y = line2_y - label_height - LINE_PADDING

        # Face positioned 75% down from line1, 25% up from line2
        # X position uses LINE_PADDING for consistent left margin
        face_x = LINE_PADDING
        available_height = line2_y - line1_y - face_height
        face_y = line1_y + int(available_height * 0.75)

        # Calculate max characters for status text wrap based on available width
        status_x = 220  # Status text starts at x=220 (moved right to avoid face overlap)
        status_margin = 10  # Right margin
        available_width = self._width - status_x - status_margin
        # Get character width (DejaVuSansMono is monospace, so all chars same width)
        char_width = self._display.ttf_width('M', FONT_PATH, LABEL_TTF_SIZE)
        status_max_chars = available_width // char_width if char_width > 0 else 22
        logging.info(f"[UI] Status wrap: available={available_width}px, char={char_width}px, max_chars={status_max_chars}")

        # Initialize voice
        lang = config.get('main', {}).get('lang', 'en')
        self._voice = Voice(lang=lang)

        # Setup faces from config
        faces_config = config.get('ui', {}).get('faces', {})
        faces.load_from_config(faces_config)

        # Initialize UI state with elements - positions calculated dynamically
        self._state = State(state={
            'channel': LabeledValue(color=0, label='CH ', value='00',
                                   position=(5, 0),
                                   ttf_font=FONT_PATH,
                                   ttf_size=LABEL_TTF_SIZE),
            'aps': LabeledValue(color=0, label='APS ', value='0',
                               position=(0, 0),  # x ignored for center align
                               align='center',
                               ttf_font=FONT_PATH,
                               ttf_size=LABEL_TTF_SIZE),
            'uptime': LabeledValue(color=0, label='UP ', value='00:00:00',
                                  position=(0, 0),  # x ignored for right align
                                  align='right',
                                  ttf_font=FONT_PATH,
                                  ttf_size=LABEL_TTF_SIZE),
            'line1': Line([(0, line1_y), (self._width, line1_y)], color=0),
            'line2': Line([(0, line2_y), (self._width, line2_y)], color=0),
            'face': Text(value=faces.SLEEP,
                        position=(face_x, face_y),
                        color=0,
                        ttf_font=FONT_PATH,
                        ttf_size=FACE_TTF_SIZE),
            'friend_name': Text(value=None,
                               position=(40, friend_y),
                               color=0,
                               ttf_font=FONT_PATH,
                               ttf_size=LABEL_TTF_SIZE),
            'name': Text(value='%s>' % pwnagotchi.name(),
                        position=(5, name_y),
                        color=0,
                        ttf_font=FONT_PATH,
                        ttf_size=LABEL_TTF_SIZE),
            'status': Text(value=self._voice.default(),
                          position=(status_x, status_y),
                          color=0,
                          wrap=True,
                          max_length=status_max_chars,
                          ttf_font=FONT_PATH,
                          ttf_size=LABEL_TTF_SIZE),
            'shakes': LabeledValue(label='PWND ', value='0',
                                  color=0,
                                  position=(5, bottom_text_y),
                                  ttf_font=FONT_PATH,
                                  ttf_size=LABEL_TTF_SIZE),
            'gps': Text(value='',
                       position=(0, gps_y),  # x ignored for right align
                       color=0,
                       align='right',
                       ttf_font=FONT_PATH,
                       ttf_size=LABEL_TTF_SIZE),
            'battery': Text(value='BAT ?',
                           position=(0, bottom_text_y),  # x ignored for right align
                           color=0,
                           align='right',
                           ttf_font=FONT_PATH,
                           ttf_size=LABEL_TTF_SIZE),
        })

        # Set font sizes
        self._state._state['face'].font_size = Pager.FONT_LARGE  # Larger face
        self._state._state['name'].font_size = Pager.FONT_MEDIUM
        self._state._state['status'].font_size = Pager.FONT_MEDIUM

        if state:
            for key, value in state.items():
                self._state.set(key, value)

        plugins.on('ui_setup', self)

        # Apply saved brightness setting
        settings = load_settings()
        brightness = settings.get('brightness', 100)
        self._display.set_brightness(brightness)

        # Auto-dim state
        self._last_activity_time = time.time()
        self._is_dimmed = False
        self._dim_level = 20

        # Start refresh thread
        self._refresh_stop = False
        self._returning_to_menu = False
        fps = config.get('ui', {}).get('fps', 2.0)
        if fps > 0.0:
            self._ignore_changes = ()
            threading.Thread(target=self._refresh_handler, daemon=True).start()
        else:
            self._ignore_changes = ('uptime', 'name')

        # Start dedicated uptime thread for 1-second updates
        self._uptime_stop = False
        threading.Thread(target=self._uptime_handler, daemon=True).start()

    def set_agent(self, agent):
        self._agent = agent

    def reset_activity(self):
        """Reset activity timer. Returns True if screen was dimmed (caller should consume the button press)."""
        self._last_activity_time = time.time()
        if self._is_dimmed:
            self._is_dimmed = False
            settings = load_settings()
            brightness = settings.get('brightness', 100)
            self._display.set_brightness(brightness)
            return True
        return False

    def _check_auto_dim(self):
        """Dim screen if idle for auto_dim seconds (0=disabled)."""
        if self._is_dimmed:
            return
        settings = load_settings()
        timeout = settings.get('auto_dim', 0)
        if timeout > 0 and time.time() - self._last_activity_time >= timeout:
            self._is_dimmed = True
            self._dim_level = settings.get('auto_dim_level', 20)
            self._display.set_brightness(self._dim_level)

    def has_element(self, key):
        return self._state.has_element(key)

    def add_element(self, key, elem):
        self._state.add_element(key, elem)

    def remove_element(self, key):
        self._state.remove_element(key)

    def width(self):
        return self._width

    def height(self):
        return self._height

    def on_state_change(self, key, cb):
        self._state.add_listener(key, cb)

    def on_render(self, cb):
        if cb not in self._render_cbs:
            self._render_cbs.append(cb)

    def _refresh_handler(self):
        """Background thread to refresh display"""
        delay = 1.0 / self._config.get('ui', {}).get('fps', 2.0)
        while not self._refresh_stop:
            try:
                # Skip all rendering/IO when menu is active — button handler owns
                # drawing and auto-dim is unnecessary during active menu use
                if self._agent and getattr(self._agent, '_menu_active', False):
                    time.sleep(delay)
                    continue

                # Don't overwrite "Returning to menu..." screen
                if getattr(self, '_returning_to_menu', False):
                    time.sleep(delay)
                    continue

                self._check_auto_dim()
                self.update()
            except Exception as e:
                logging.warning(f"Display update error: {e}")
            time.sleep(delay)

    def init_pause_menu(self, agent):
        """Initialize pause menu state and draw immediately"""
        self._menu_row = 0
        self._menu_col = 0
        self._menu_settings = load_settings()
        self._available_launchers = discover_launchers()
        # Sync deauth from agent config
        if agent and hasattr(agent, '_config'):
            self._menu_settings['deauth_enabled'] = agent._config.get('personality', {}).get('deauth', True)
        # Draw immediately so menu appears without waiting for refresh thread
        self._draw_pause_menu()

    def _get_bottom_items(self):
        """Build list of bottom menu items (action label, return value).
        Launchers are auto-discovered from launch_*.sh files."""
        items = [
            ('Back to Pagergotchi', 'resume'),
            ('Exit to Main Menu', 'main_menu'),
        ]
        for title, path in getattr(self, '_available_launchers', []):
            items.append((f'Exit to {title}', ('launch', path)))
        items.append(('Exit Pagergotchi', 'exit'))
        return items

    def handle_menu_input(self, button):
        """Handle button input for pause menu. Returns action string or None.

        Layout — rows 0-2 are two columns, rows 3+ are centered bottom items:
          Row 0: [Theme, Brightness]
          Row 1: [Deauth, Auto Dim]
          Row 2: [Privacy, Dim Level]
          Row 3+: Back / Main Menu / Launchers / Exit

        Uses partial redraws for navigation — only redraws changed items.
        """
        if not hasattr(self, '_menu_row'):
            self._menu_row = 0
            self._menu_col = 0
        if not hasattr(self, '_menu_settings'):
            self._menu_settings = load_settings()

        bottom_items = self._get_bottom_items()
        total_rows = 3 + len(bottom_items)
        old_row, old_col = self._menu_row, self._menu_col

        if button == Pager.BTN_UP:
            self._menu_row = (self._menu_row - 1) % total_rows
            self._partial_redraw_menu([(old_row, old_col), (self._menu_row, self._menu_col)])
        elif button == Pager.BTN_DOWN:
            self._menu_row = (self._menu_row + 1) % total_rows
            self._partial_redraw_menu([(old_row, old_col), (self._menu_row, self._menu_col)])
        elif button == Pager.BTN_LEFT:
            if self._menu_row < 3 and self._menu_col != 0:
                self._menu_col = 0
                self._partial_redraw_menu([(old_row, 1), (self._menu_row, 0)])
        elif button == Pager.BTN_RIGHT:
            if self._menu_row < 3 and self._menu_col != 1:
                self._menu_col = 1
                self._partial_redraw_menu([(old_row, 0), (self._menu_row, 1)])
        elif button == Pager.BTN_A:  # Green = Select / cycle value
            row, col = self._menu_row, self._menu_col
            if row < 3:
                # Column settings — cycle forward on select
                action = [(self._cycle_theme, self._adjust_brightness),
                          (self._toggle_deauth, self._cycle_auto_dim),
                          (self._toggle_privacy, self._cycle_dim_level)]
                action[row][col](Pager.BTN_RIGHT)
                if row == 0 and col == 0:  # Theme changed — colors change everywhere
                    self._draw_pause_menu()
                else:
                    self._partial_redraw_menu([(row, col)])
            else:
                # Bottom action items
                idx = row - 3
                result = bottom_items[idx][1]
                if isinstance(result, tuple) and result[0] == 'launch':
                    self._write_next_payload(result[1])
                    self._draw_returning_screen("Launching...")
                    return 'launch'
                if result == 'main_menu':
                    self._draw_returning_screen()
                return result
        elif button == Pager.BTN_B:  # Red = Resume
            return 'resume'

        return None

    def _cycle_theme(self, button):
        """Cycle through themes"""
        current = self._menu_settings.get('theme', 'Default')
        try:
            idx = THEME_NAMES.index(current)
        except ValueError:
            idx = 0
        if button == Pager.BTN_RIGHT:
            idx = (idx + 1) % len(THEME_NAMES)
        else:
            idx = (idx - 1) % len(THEME_NAMES)
        self._menu_settings['theme'] = THEME_NAMES[idx]
        save_settings(self._menu_settings)

    def _toggle_deauth(self, _button=None):
        """Toggle deauth setting"""
        self._menu_settings['deauth_enabled'] = not self._menu_settings['deauth_enabled']
        if self._agent and hasattr(self._agent, '_config'):
            self._agent._config['personality']['deauth'] = self._menu_settings['deauth_enabled']
        save_settings(self._menu_settings)

    def _toggle_privacy(self, _button=None):
        """Toggle privacy mode"""
        self._menu_settings['privacy_mode'] = not self._menu_settings['privacy_mode']
        save_settings(self._menu_settings)

    def _adjust_brightness(self, button):
        """Cycle screen brightness in 10% steps (20-100%, wraps around)"""
        current = self._menu_settings.get('brightness', 100)
        if button == Pager.BTN_RIGHT:
            new_val = current + 10
            if new_val > 100:
                new_val = 20
        else:
            new_val = current - 10
            if new_val < 20:
                new_val = 100

        self._menu_settings['brightness'] = new_val
        self._display.set_brightness(new_val)
        save_settings(self._menu_settings)

    def _cycle_auto_dim(self, button):
        """Cycle auto-dim timeout: Off, 30s, 60s"""
        current = self._menu_settings.get('auto_dim', 0)
        try:
            idx = AUTO_DIM_OPTIONS.index(current)
        except ValueError:
            idx = 0
        if button == Pager.BTN_RIGHT:
            idx = (idx + 1) % len(AUTO_DIM_OPTIONS)
        else:
            idx = (idx - 1) % len(AUTO_DIM_OPTIONS)
        self._menu_settings['auto_dim'] = AUTO_DIM_OPTIONS[idx]
        # Reset activity timer when changing the setting
        self._last_activity_time = time.time()
        self._is_dimmed = False
        save_settings(self._menu_settings)

    def _cycle_dim_level(self, button):
        """Cycle dim brightness level: 20%, 40%"""
        current = self._menu_settings.get('auto_dim_level', 20)
        try:
            idx = AUTO_DIM_LEVELS.index(current)
        except ValueError:
            idx = 0  # Default to 20%
        if button == Pager.BTN_RIGHT:
            idx = (idx + 1) % len(AUTO_DIM_LEVELS)
        else:
            idx = (idx - 1) % len(AUTO_DIM_LEVELS)
        self._menu_settings['auto_dim_level'] = AUTO_DIM_LEVELS[idx]
        save_settings(self._menu_settings)

    def _get_menu_item_text(self, row, col):
        """Get (label, value) for a column settings item at (row, col)."""
        current_theme = self._menu_settings.get('theme', 'Default')
        auto_dim_val = self._menu_settings.get('auto_dim', 0)
        auto_dim_str = 'Off' if auto_dim_val == 0 else f'{auto_dim_val}s'
        dim_level = self._menu_settings.get('auto_dim_level', 20)
        dim_level_str = f'{dim_level}%'

        items = [
            [('Theme:', current_theme), ('Brightness:', f"{self._menu_settings.get('brightness', 100)}%")],
            [('Deauth:', 'ON' if self._menu_settings.get('deauth_enabled', True) else 'OFF'), ('Auto Dim:', auto_dim_str)],
            [('Privacy:', 'ON' if self._menu_settings.get('privacy_mode', False) else 'OFF'), ('Dim Level:', dim_level_str)],
        ]
        return items[row][col]

    def _partial_redraw_menu(self, positions):
        """Redraw only the specified menu positions. Much faster than full redraw."""
        theme = get_menu_theme()
        col_x = [30, 260]
        start_y = 48
        row_h = 26
        bottom_items = self._get_bottom_items()
        bottom_y = start_y + 3 * row_h + 6
        col_w = [col_x[1] - col_x[0], 480 - col_x[1]]

        for r, c in positions:
            if r < 3:
                # Column setting item
                x = col_x[c]
                y = start_y + r * row_h
                self._display.fill_rect(x, y, col_w[c], row_h, theme['bg'])

                label, value = self._get_menu_item_text(r, c)
                is_sel = (self._menu_row == r and self._menu_col == c)
                label_color = theme['selected'] if is_sel else theme['unselected']

                if label in ('Theme:', 'Brightness:', 'Auto Dim:', 'Dim Level:'):
                    value_color = theme['accent']
                else:
                    value_color = theme['on'] if value == 'ON' else theme['off']

                label_w = self._display.ttf_width(label, FONT_DEJAVU, TTF_MEDIUM)
                self._display.draw_ttf(x, y, label, label_color, FONT_DEJAVU, TTF_MEDIUM)
                self._display.draw_ttf(x + label_w + 6, y, value, value_color, FONT_DEJAVU, TTF_MEDIUM)
            else:
                # Bottom action item
                idx = r - 3
                if idx < len(bottom_items):
                    y = bottom_y + idx * 22
                    self._display.fill_rect(0, y, 480, 22, theme['bg'])

                    label = bottom_items[idx][0]
                    is_sel = (self._menu_row == r)
                    color = theme['selected'] if is_sel else theme['unselected']
                    self._display.draw_ttf_centered(y, label, color, FONT_DEJAVU, TTF_MEDIUM)

        self._display.flip()

    def _draw_pause_menu(self):
        """Draw pause menu overlay — full redraw (used for init and theme changes)."""
        if not hasattr(self, '_menu_row'):
            self._menu_row = 0
            self._menu_col = 0
        if not hasattr(self, '_menu_settings'):
            self._menu_settings = load_settings()

        theme = get_menu_theme()
        row, col = self._menu_row, self._menu_col

        self._display.clear(theme['bg'])

        # Title
        self._display.draw_ttf_centered(10, "PAUSED", theme['warning'], FONT_DEJAVU, TTF_LARGE)

        # --- Column settings (rows 0-2) ---
        current_theme = self._menu_settings.get('theme', 'Default')
        auto_dim_val = self._menu_settings.get('auto_dim', 0)
        auto_dim_str = 'Off' if auto_dim_val == 0 else f'{auto_dim_val}s'
        dim_level = self._menu_settings.get('auto_dim_level', 20)
        dim_level_str = f'{dim_level}%'

        # (left_label, left_value, right_label, right_value)
        col_rows = [
            ('Theme:', current_theme,
             'Brightness:', f"{self._menu_settings.get('brightness', 100)}%"),
            ('Deauth:', 'ON' if self._menu_settings.get('deauth_enabled', True) else 'OFF',
             'Auto Dim:', auto_dim_str),
            ('Privacy:', 'ON' if self._menu_settings.get('privacy_mode', False) else 'OFF',
             'Dim Level:', dim_level_str),
        ]

        col_x = [30, 260]
        start_y = 48
        row_h = 26

        for r, (ll, lv, rl, rv) in enumerate(col_rows):
            y = start_y + r * row_h
            for c, (label, value) in enumerate([(ll, lv), (rl, rv)]):
                x = col_x[c]
                is_sel = (row == r and col == c)
                label_color = theme['selected'] if is_sel else theme['unselected']

                if label in ('Theme:', 'Brightness:', 'Auto Dim:', 'Dim Level:'):
                    value_color = theme['accent']
                else:
                    value_color = theme['on'] if value == 'ON' else theme['off']

                label_w = self._display.ttf_width(label, FONT_DEJAVU, TTF_MEDIUM)
                self._display.draw_ttf(x, y, label, label_color, FONT_DEJAVU, TTF_MEDIUM)
                self._display.draw_ttf(x + label_w + 6, y, value, value_color, FONT_DEJAVU, TTF_MEDIUM)

        # --- Bottom action items (rows 3+) ---
        bottom_items = self._get_bottom_items()
        bottom_y = start_y + 3 * row_h + 6

        for i, (label, _action) in enumerate(bottom_items):
            y = bottom_y + i * 22
            is_sel = (row == 3 + i)
            color = theme['selected'] if is_sel else theme['unselected']
            self._display.draw_ttf_centered(y, label, color, FONT_DEJAVU, TTF_MEDIUM)

        self._display.flip()

    def _write_next_payload(self, launcher_path):
        """Write the next payload launcher path for payload.sh to pick up"""
        next_payload_file = os.path.join(_payload_dir, 'data', '.next_payload')
        try:
            with open(next_payload_file, 'w') as f:
                f.write(launcher_path)
        except Exception as e:
            logging.warning("Failed to write .next_payload: %s", e)

    def _draw_returning_screen(self, message="Returning to menu..."):
        """Draw transition screen while waiting"""
        # Set flag to prevent refresh thread from overwriting this screen
        self._returning_to_menu = True

        theme = get_menu_theme()
        self._display.clear(theme['bg'])

        # Center message vertically
        self._display.draw_ttf_centered(90, message, theme['warning'], FONT_DEJAVU, TTF_LARGE)
        self._display.draw_ttf_centered(130, "Please wait", theme['dim'], FONT_DEJAVU, TTF_MEDIUM)

        self._display.flip()

    def _uptime_handler(self):
        """Dedicated thread to update uptime every second"""
        while not self._uptime_stop:
            try:
                uptime_secs = pwnagotchi.uptime()
                time_str = utils.secs_to_hhmmss(uptime_secs)
                self.set('uptime', time_str)
            except Exception as e:
                logging.debug(f"Uptime update error: {e}")
            time.sleep(1.0)

    def set(self, key, value):
        self._state.set(key, value)

    def get(self, key):
        return self._state.get(key)

    def _get_random_face(self, face_or_faces):
        if isinstance(face_or_faces, list):
            return random.choice(face_or_faces)
        return face_or_faces

    def on_starting(self):
        self.set('status', self._voice.on_starting())
        self.set('face', self._get_random_face(faces.AWAKE))
        self.update()

    def on_manual_mode(self, last_session):
        self.set('mode', 'MANU')
        self.set('face', self._get_random_face(faces.SAD) if (last_session.epochs > 3 and last_session.handshakes == 0) else self._get_random_face(faces.HAPPY))
        self.set('status', self._voice.on_last_session_data(last_session))
        self.update()

    def is_normal(self):
        face = self._state.get('face')
        return face not in (
            faces.INTENSE, faces.COOL, faces.BORED, faces.HAPPY,
            faces.EXCITED, faces.MOTIVATED, faces.DEMOTIVATED,
            faces.SMART, faces.SAD, faces.LONELY
        )

    def on_keys_generation(self):
        self.set('face', self._get_random_face(faces.AWAKE))
        self.set('status', self._voice.on_keys_generation())
        self.update()

    def on_normal(self):
        self.set('face', self._get_random_face(faces.AWAKE))
        self.set('status', self._voice.on_normal())
        self.update()

    def set_closest_peer(self, peer, num_total):
        if peer is None:
            self.set('friend_name', None)
        else:
            name = f'{peer.name()} ({peer.pwnd_total()})'
            self.set('friend_name', name)
        self.update()

    def on_new_peer(self, peer):
        if peer.first_encounter():
            face = self._get_random_face(random.choice([faces.AWAKE, faces.COOL]))
        elif peer.is_good_friend(self._config):
            face = self._get_random_face(random.choice([faces.MOTIVATED, faces.FRIEND, faces.HAPPY]))
        else:
            face = self._get_random_face(random.choice([faces.EXCITED, faces.HAPPY, faces.SMART]))

        self.set('face', face)
        self.set('status', self._voice.on_new_peer(peer))
        self.update()
        time.sleep(3)

    def on_lost_peer(self, peer):
        self.set('face', self._get_random_face(faces.LONELY))
        self.set('status', self._voice.on_lost_peer(peer))
        self.update()

    def on_free_channel(self, channel):
        self.set('face', self._get_random_face(faces.SMART))
        self.set('status', self._voice.on_free_channel(channel))
        self.update()

    def on_reading_logs(self, lines_so_far=0):
        self.set('face', self._get_random_face(faces.SMART))
        self.set('status', self._voice.on_reading_logs(lines_so_far))
        self.update()

    def _should_exit_wait(self):
        """Check if we should exit wait early (exit or return to menu requested)"""
        if not self._agent:
            return False
        return (getattr(self._agent, '_exit_requested', False) or
                getattr(self._agent, '_return_to_menu', False))

    def wait(self, secs, sleeping=True):
        """
        Wait for specified seconds with face animation

        This is THE KEY METHOD for pwnagotchi behavior - it cycles
        through faces and status messages during wait periods.
        """
        was_normal = self.is_normal()
        part = secs / 10.0

        for step in range(0, 10):
            # Check if exit or menu return was requested
            if self._should_exit_wait():
                return

            # Keep previous face/status for first few steps if not normal
            if was_normal or step > 5:
                if sleeping:
                    self.set('face', self._get_random_face(faces.SLEEP))
                    if secs > 1:
                        self.set('status', self._voice.on_napping(int(secs)))
                    else:
                        self.set('status', self._voice.on_awakening())
                else:
                    self.set('status', self._voice.on_waiting(int(secs)))

                    # Alternate looking left/right
                    good_mood = self._agent.in_good_mood() if self._agent else False
                    if step % 2 == 0:
                        self.set('face', self._get_random_face(faces.LOOK_R_HAPPY if good_mood else faces.LOOK_R))
                    else:
                        self.set('face', self._get_random_face(faces.LOOK_L_HAPPY if good_mood else faces.LOOK_L))

            # Sleep in smaller chunks so exit/menu is responsive
            chunk = min(part, 0.1)  # Check every 100ms for fast response
            remaining = part
            while remaining > 0:
                if self._should_exit_wait():
                    return
                time.sleep(min(chunk, remaining))
                remaining -= chunk
            secs -= part

        self.on_normal()

    def on_shutdown(self):
        self.set('face', self._get_random_face(faces.SLEEP))
        self.set('status', self._voice.on_shutdown())
        self.update(force=True)
        self._frozen = True

    def on_bored(self):
        self.set('face', self._get_random_face(faces.BORED))
        self.set('status', self._voice.on_bored())
        self.update()

    def on_sad(self):
        self.set('face', self._get_random_face(faces.SAD))
        self.set('status', self._voice.on_sad())
        self.update()

    def on_angry(self):
        self.set('face', self._get_random_face(faces.ANGRY))
        self.set('status', self._voice.on_angry())
        self.update()

    def on_motivated(self, reward):
        self.set('face', self._get_random_face(faces.MOTIVATED))
        self.set('status', self._voice.on_motivated(reward))
        self.update()

    def on_demotivated(self, reward):
        self.set('face', self._get_random_face(faces.DEMOTIVATED))
        self.set('status', self._voice.on_demotivated(reward))
        self.update()

    def on_excited(self):
        self.set('face', self._get_random_face(faces.EXCITED))
        self.set('status', self._voice.on_excited())
        self.update()

    def on_assoc(self, ap):
        self.set('face', self._get_random_face(faces.INTENSE))
        self.set('status', self._voice.on_assoc(ap))
        self.update()

    def on_deauth(self, sta):
        self.set('face', self._get_random_face(faces.COOL))
        self.set('status', self._voice.on_deauth(sta))
        self.update()

    def on_miss(self, who):
        self.set('face', self._get_random_face(faces.SAD))
        self.set('status', self._voice.on_miss(who))
        self.update()

    def on_grateful(self):
        self.set('face', self._get_random_face(faces.GRATEFUL))
        self.set('status', self._voice.on_grateful())
        self.update()

    def on_lonely(self):
        self.set('face', self._get_random_face(faces.LONELY))
        self.set('status', self._voice.on_lonely())
        self.update()

    def on_handshakes(self, new_shakes):
        self.set('face', self._get_random_face(faces.HAPPY))
        self.set('status', self._voice.on_handshakes(new_shakes))
        self.update()

    def on_unread_messages(self, count, total):
        self.set('face', self._get_random_face(faces.EXCITED))
        self.set('status', self._voice.on_unread_messages(count, total))
        self.update()
        time.sleep(5.0)

    def on_uploading(self, to):
        self.set('face', self._get_random_face(faces.UPLOAD))
        self.set('status', self._voice.on_uploading(to))
        self.update(force=True)

    def on_rebooting(self):
        self.set('face', self._get_random_face(faces.BROKEN))
        self.set('status', self._voice.on_rebooting())
        self.update()

    def on_custom(self, text):
        self.set('face', self._get_random_face(faces.DEBUG))
        self.set('status', self._voice.custom(text))
        self.update()

    def update(self, force=False, new_data=None):
        """Render all UI elements to display"""
        if new_data:
            for key, val in new_data.items():
                self.set(key, val)

        with self._lock:
            if self._frozen:
                return

            # Don't draw if pause menu is active
            if hasattr(self, '_agent') and self._agent and getattr(self._agent, '_menu_active', False):
                return

            state = self._state
            changes = state.changes(ignore=self._ignore_changes)

            if force or len(changes):
                # Get current theme colors
                theme = get_view_theme()

                # Clear display with theme background
                self._display.clear(theme['bg'])

                # Apply theme colors to components before drawing
                for key, elem in state.items():
                    try:
                        if key == 'face':
                            elem.color = theme['face']
                        elif key in ('line1', 'line2'):
                            elem.color = theme['line']
                        elif key in ('channel', 'aps', 'uptime', 'shakes', 'battery', 'gps'):
                            elem.color = theme['label']
                        elif key in ('name', 'status'):
                            elem.color = theme['text']
                        elif key == 'friend_name':
                            elem.color = theme['status']
                        else:
                            elem.color = theme['text']

                        elem.draw(self._display)
                    except Exception as e:
                        logging.debug(f"Error drawing {key}: {e}")

                # Flip buffer to display
                self._display.flip()

                # Call render callbacks
                for cb in self._render_cbs:
                    try:
                        cb(None)  # No canvas in native mode
                    except:
                        pass

                state.reset()

    def cleanup(self):
        """Clean up display"""
        self._refresh_stop = True
        self._uptime_stop = True
        # Small delay to let threads see the stop flags
        time.sleep(0.1)
        self._display.cleanup()
