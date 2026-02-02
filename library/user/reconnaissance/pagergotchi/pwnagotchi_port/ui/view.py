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
_fonts_dir = os.path.abspath(os.path.join(_this_dir, '..', '..', 'fonts'))
FONT_PATH = os.path.join(_fonts_dir, 'DejaVuSansMono.ttf')

# Font sizes
FACE_TTF_SIZE = 64.0   # ASCII face size
LABEL_TTF_SIZE = 22.0  # Labels like CH, APS, UPTIME, BAT, etc.

# Padding between text and lines (in pixels)
LINE_PADDING = 5

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
                # Don't overwrite "Returning to menu..." screen
                if getattr(self, '_returning_to_menu', False):
                    time.sleep(delay)
                    continue

                # Check if menu is active
                if self._agent and getattr(self._agent, '_menu_active', False):
                    self._draw_pause_menu()
                else:
                    self.update()
            except Exception as e:
                logging.warning(f"Display update error: {e}")
            time.sleep(delay)

    def init_pause_menu(self, agent):
        """Initialize pause menu state"""
        self._menu_selected = 0
        self._menu_settings = load_settings()
        # Sync deauth from agent config
        if agent and hasattr(agent, '_config'):
            self._menu_settings['deauth_enabled'] = agent._config.get('personality', {}).get('deauth', True)

    def handle_menu_input(self, button):
        """Handle button input for pause menu. Returns 'main_menu', 'resume', or None."""
        if not hasattr(self, '_menu_selected'):
            self._menu_selected = 0
        if not hasattr(self, '_menu_settings'):
            self._menu_settings = load_settings()

        num_options = 6  # Resume, Theme, Deauth, Privacy, Main Menu, Exit
        needs_redraw = True

        if button == Pager.BTN_UP:
            self._menu_selected = (self._menu_selected - 1) % num_options
        elif button == Pager.BTN_DOWN:
            self._menu_selected = (self._menu_selected + 1) % num_options
        elif button in (Pager.BTN_LEFT, Pager.BTN_RIGHT):
            if self._menu_selected == 1:  # Theme
                self._cycle_theme(button)
            elif self._menu_selected == 2:  # Deauth
                self._toggle_deauth()
            elif self._menu_selected == 3:  # Privacy
                self._toggle_privacy()
        elif button == Pager.BTN_A:  # Select
            if self._menu_selected == 0:  # Resume
                return 'resume'
            elif self._menu_selected == 1:  # Theme - cycle forward
                self._cycle_theme(Pager.BTN_RIGHT)
            elif self._menu_selected == 2:  # Deauth
                self._toggle_deauth()
            elif self._menu_selected == 3:  # Privacy
                self._toggle_privacy()
            elif self._menu_selected == 4:  # Main Menu
                # Show "returning to menu" screen immediately
                self._draw_returning_screen()
                return 'main_menu'
            elif self._menu_selected == 5:  # Exit Pagergotchi
                return 'exit'
        elif button == Pager.BTN_B:  # Back = Resume
            return 'resume'
        else:
            needs_redraw = False

        # Immediate redraw for responsive feel
        if needs_redraw:
            self._draw_pause_menu()

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

    def _toggle_deauth(self):
        """Toggle deauth setting"""
        self._menu_settings['deauth_enabled'] = not self._menu_settings['deauth_enabled']
        if self._agent and hasattr(self._agent, '_config'):
            self._agent._config['personality']['deauth'] = self._menu_settings['deauth_enabled']
        save_settings(self._menu_settings)

    def _toggle_privacy(self):
        """Toggle privacy mode"""
        self._menu_settings['privacy_mode'] = not self._menu_settings['privacy_mode']
        save_settings(self._menu_settings)

    def _draw_pause_menu(self):
        """Draw pause menu overlay"""
        if not hasattr(self, '_menu_selected'):
            self._menu_selected = 0
        if not hasattr(self, '_menu_settings'):
            self._menu_settings = load_settings()

        theme = get_menu_theme()
        selected = self._menu_selected

        self._display.clear(theme['bg'])

        # Title
        self._display.draw_ttf_centered(12, "PAUSED", theme['warning'], FONT_DEJAVU, TTF_LARGE)

        # Subtitle showing agent is still running
        self._display.draw_ttf_centered(38, "(still hunting)", theme['dim'], FONT_DEJAVU, TTF_SMALL)

        # Menu options with max_value for fixed-width alignment
        current_theme = self._menu_settings.get('theme', 'Default')
        options = [
            ('Resume', None, None),
            ('Theme:', current_theme, 'Synthwave'),  # (label, value, max_value)
            ('Deauth:', 'ON' if self._menu_settings.get('deauth_enabled', True) else 'OFF', 'OFF'),
            ('Privacy:', 'ON' if self._menu_settings.get('privacy_mode', False) else 'OFF', 'OFF'),
            ('Main Menu', None, None),
            ('Exit Pagergotchi', None, None)
        ]

        y = 58
        for i, (label, value, max_value) in enumerate(options):
            is_selected = (i == selected)

            if value is not None:
                # Toggle/cycle option with value - use fixed width so label doesn't shift
                label_color = theme['selected'] if is_selected else theme['unselected']

                if label == 'Theme:':
                    value_color = theme['accent']
                else:
                    value_color = theme['on'] if value == 'ON' else theme['off']

                # Calculate fixed positions using max value width
                label_width = self._display.ttf_width(label, FONT_DEJAVU, TTF_MEDIUM)
                max_value_width = self._display.ttf_width(max_value, FONT_DEJAVU, TTF_MEDIUM)
                total_width = label_width + 8 + max_value_width  # 8px gap

                # Center the label+value
                base_x = (self._width - total_width) // 2
                self._display.draw_ttf(base_x, y, label, label_color, FONT_DEJAVU, TTF_MEDIUM)
                self._display.draw_ttf(base_x + label_width + 8, y, value, value_color, FONT_DEJAVU, TTF_MEDIUM)
            else:
                # Simple option (Resume, Main Menu)
                color = theme['selected'] if is_selected else theme['unselected']
                self._display.draw_ttf_centered(y, label, color, FONT_DEJAVU, TTF_MEDIUM)

            y += 28

        self._display.flip()

    def _draw_returning_screen(self):
        """Draw 'Returning to menu...' screen while waiting"""
        # Set flag to prevent refresh thread from overwriting this screen
        self._returning_to_menu = True

        theme = get_menu_theme()
        self._display.clear(theme['bg'])

        # Center message vertically
        self._display.draw_ttf_centered(90, "Returning to menu...", theme['warning'], FONT_DEJAVU, TTF_LARGE)
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
