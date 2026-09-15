"""
Pagergotchi Main Entry Point
Based on original pwnagotchi/cli.py with MINIMAL changes
"""
import logging
import time
import signal
import sys
import os

# Add lib directory to path for pagerctl import
_lib_dir = os.path.join(os.path.dirname(__file__), '..', 'lib')
if os.path.abspath(_lib_dir) not in sys.path:
    sys.path.insert(0, os.path.abspath(_lib_dir))

from pagerctl import Pager

import pwnagotchi_port as pwnagotchi
from pwnagotchi_port import utils
from pwnagotchi_port import plugins
from pwnagotchi_port.agent import Agent
from pwnagotchi_port.ui.view import View


# Global exit flag - set by button thread
_exit_requested = False
_agent_ref = None  # Reference to agent for setting its exit flag
_button_monitor_stop = False  # Flag to stop button monitor thread
_button_monitor_thread_ref = None  # Reference to thread for cleanup


def _button_monitor_thread(display):
    """Background thread to monitor buttons and handle pause menu.

    Uses thread-safe event queue from pagerctl to reliably detect button presses.
    Handles menu navigation so agent can keep running in background.
    """
    global _exit_requested, _agent_ref, _button_monitor_stop

    logging.info("[BUTTON] Monitor thread started (using event queue)")

    while not _exit_requested and not _button_monitor_stop:
        try:
            # poll_input() reads hardware and populates the event queue
            display.poll_input()

            # Consume events from the thread-safe queue
            event = display.get_input_event()
            if not event:
                time.sleep(0.016)
                continue

            button, event_type, timestamp = event

            # Only react to press events
            if event_type != Pager.EVENT_PRESS:
                continue

            # Reset auto-dim timer; if screen was dimmed, consume this press
            view = _agent_ref._view if _agent_ref and hasattr(_agent_ref, '_view') else None
            if view and view.reset_activity():
                continue  # Screen was dimmed, just wake up without processing button

            # Check if menu is active
            in_menu = _agent_ref and getattr(_agent_ref, '_menu_active', False)

            if in_menu:
                # Handle menu navigation
                view = _agent_ref._view if _agent_ref else None
                if view and hasattr(view, 'handle_menu_input'):
                    result = view.handle_menu_input(button)
                    # Flush stale events that buffered during menu draw
                    display.poll_input()
                    display.clear_input_events()
                    if result == 'exit':
                        _exit_requested = True
                        if _agent_ref:
                            _agent_ref._exit_requested = True
                    elif result in ('main_menu', 'launch'):
                        # Return to main menu or launch another payload
                        # Keep _menu_active = True so pause menu stays visible until loop exits
                        if _agent_ref:
                            _agent_ref._return_to_menu = True
                            _agent_ref._return_target = result
                    elif result == 'resume':
                        if _agent_ref:
                            _agent_ref._menu_active = False
            else:
                # Not in menu - BTN_B opens menu
                if button == Pager.BTN_B:
                    logging.info("[BUTTON] RED button pressed - opening pause menu")
                    if _agent_ref:
                        _agent_ref._menu_active = True
                        # Initialize menu state on view
                        if hasattr(_agent_ref, '_view') and _agent_ref._view:
                            _agent_ref._view.init_pause_menu(_agent_ref)
                            # Flush stale events from menu init draw
                            display.poll_input()
                            display.clear_input_events()

            # No sleep after processing — go right back to polling

        except Exception as e:
            logging.debug("[BUTTON] Event error: %s", e)
            time.sleep(0.016)

    logging.info("[BUTTON] Monitor thread exiting")


def start_button_monitor(view):
    """Start background button monitoring thread"""
    global _button_monitor_stop, _button_monitor_thread_ref
    import threading

    # Reset stop flag
    _button_monitor_stop = False

    if hasattr(view, '_display') and view._display:
        # Clear any stale events from startup menu
        view._display.clear_input_events()
        # Sync button state by doing a poll
        view._display.poll_input()
        view._display.clear_input_events()

        t = threading.Thread(target=_button_monitor_thread, args=(view._display,), daemon=True)
        t.start()
        _button_monitor_thread_ref = t
        return t
    return None


def stop_button_monitor():
    """Stop the button monitor thread"""
    global _button_monitor_stop, _button_monitor_thread_ref

    _button_monitor_stop = True
    if _button_monitor_thread_ref and _button_monitor_thread_ref.is_alive():
        _button_monitor_thread_ref.join(timeout=0.5)
    _button_monitor_thread_ref = None


def should_exit():
    """Check if exit was requested"""
    return _exit_requested


def should_return_to_menu():
    """Check if return to main menu was requested"""
    if _agent_ref and getattr(_agent_ref, '_return_to_menu', False):
        return True
    return False




def do_auto_mode(agent):
    """
    Main loop - Based on original pwnagotchi/cli.py do_auto_mode()
    Changes: added debug logging, exit button check, broadcast deauth for PineAP
    Returns: 'main_menu' to return to startup menu, 'exit' to quit completely
    """
    global _agent_ref, _exit_requested
    logging.info("entering auto mode ...")

    agent.mode = 'auto'
    agent._exit_requested = False  # Initialize exit flag on agent
    agent._return_to_menu = False  # Return to startup menu flag
    agent._return_target = 'main_menu'  # Where to go: 'main_menu' or 'bjorn'
    agent._menu_active = False  # Menu overlay state
    _agent_ref = agent  # Store reference for button thread

    # Start button monitor thread BEFORE agent.start() so pause works immediately
    start_button_monitor(agent._view)

    agent.start()

    while not should_exit() and not should_return_to_menu():
        try:
            # Menu runs as overlay - agent keeps working
            # Button monitor thread handles menu input
            # View draws menu overlay when _menu_active is True

            # recon on all channels
            logging.debug("[LOOP] Starting recon phase...")
            agent.recon()

            if should_exit() or should_return_to_menu():
                break

            # get nearby access points grouped by channel
            channels = agent.get_access_points_by_channel()
            logging.debug("[LOOP] Found %d channels with APs", len(channels))

            # for each channel
            for ch, aps in channels:
                if should_exit() or should_return_to_menu():
                    break

                time.sleep(1)
                logging.debug("[LOOP] Setting channel %d (%d APs)", ch, len(aps))
                agent.set_channel(ch)

                if not agent.is_stale() and agent.any_activity():
                    logging.info("%d access points on channel %d" % (len(aps), ch))

                # for each ap on this channel
                for ap in aps:
                    if should_exit() or should_return_to_menu():
                        break

                    hostname = ap.get('hostname', ap.get('mac', 'unknown'))

                    # send an association frame in order to get for a PMKID
                    logging.debug("[ATTACK] Associating with %s", hostname)
                    agent.associate(ap)

                    # deauth all client stations in order to get a full handshake
                    # (original behavior: only targeted deauth, skip if no clients)
                    clients = ap.get('clients', [])
                    if clients:
                        logging.debug("[ATTACK] Deauthing %d clients from %s", len(clients), hostname)
                        for sta in clients:
                            if should_exit() or should_return_to_menu():
                                break
                            agent.deauth(ap, sta)

            if should_exit() or should_return_to_menu():
                break

            # End of epoch
            logging.debug("[LOOP] Epoch complete, calling next_epoch()")
            agent.next_epoch()

        except Exception as e:
            if str(e).find("wifi.interface not set") > 0:
                logging.exception("main loop exception due to unavailable wifi device (%s)", e)
                logging.info("sleeping 60 seconds then advancing to next epoch")
                time.sleep(60)
                agent.next_epoch()
            else:
                logging.exception("main loop exception (%s)", e)

    if should_return_to_menu():
        target = getattr(_agent_ref, '_return_target', 'main_menu') if _agent_ref else 'main_menu'
        logging.info("[LOOP] Return requested, target=%s", target)
        return target
    logging.info("[LOOP] Exit requested, leaving main loop")
    return 'exit'


def load_config(config_path=None):
    """Load configuration - simplified for Pager"""
    # Default configuration matching original pwnagotchi defaults.toml
    config = {
        'main': {
            'name': 'pagergotchi',
            'iface': 'wlan1mon',
            'mon_start_cmd': '',
            'no_restart': True,
            'whitelist': [],
        },
        'personality': {
            # Timing
            'recon_time': 30,
            'max_inactive_scale': 2,
            'recon_inactive_multiplier': 2,
            'hop_recon_time': 10,
            'min_recon_time': 5,
            # Attacks
            'associate': True,
            'deauth': True,
            # Throttling - ORIGINAL VALUES from defaults.toml
            'throttle_a': 0.4,
            'throttle_d': 0.9,
            # Limits
            'ap_ttl': 120,
            'sta_ttl': 300,
            'min_rssi': -200,
            'max_interactions': 3,
            'max_misses_for_recon': 10,
            # Mood (reduced for more dynamic personality)
            'bored_num_epochs': 5,   # ~5 min of inactivity
            'sad_num_epochs': 10,    # ~10 min of inactivity
            # angry triggers at 2x sad = ~20 min
            'excited_num_epochs': 10,
            'bond_encounters_factor': 20000,
            # Channels (empty = all)
            'channels': [],
        },
        'bettercap': {
            'hostname': '127.0.0.1',
            'scheme': 'http',
            'port': 8081,
            'username': 'pwnagotchi',
            'password': 'pwnagotchi',
            'handshakes': '/root/loot/handshakes/pagergotchi',
            'silence': ['wifi.client.probe'],
        },
        'ui': {
            'fps': 2.0,
            'display': {'type': 'pager'},
            'faces': {},
        }
    }

    # Try to load from config file
    if config_path and os.path.exists(config_path):
        try:
            import configparser
            cp = configparser.ConfigParser()
            cp.read(config_path)

            if 'capture' in cp:
                config['main']['iface'] = cp.get('capture', 'interface', fallback='wlan1mon')
                config['bettercap']['handshakes'] = cp.get('capture', 'output_dir', fallback='/root/loot/handshakes/pagergotchi')

            if 'channels' in cp:
                channels_str = cp.get('channels', 'channels', fallback='')
                if channels_str:
                    config['personality']['channels'] = [int(c.strip()) for c in channels_str.split(',')]

            if 'whitelist' in cp:
                ssids = cp.get('whitelist', 'ssids', fallback='')
                if ssids:
                    config['main']['whitelist'] = [s.strip() for s in ssids.split(',')]

            if 'general' in cp:
                config['main']['debug'] = cp.getboolean('general', 'debug', fallback=False)

            if 'deauth' in cp:
                config['personality']['deauth'] = cp.getboolean('deauth', 'enabled', fallback=True)

            if 'timing' in cp:
                config['personality']['throttle_d'] = cp.getfloat('timing', 'throttle_d', fallback=0.9)
                config['personality']['throttle_a'] = cp.getfloat('timing', 'throttle_a', fallback=0.4)

            logging.info("Loaded config from %s", config_path)
        except Exception as e:
            logging.warning("Config load error: %s, using defaults", e)

    return config


def main():
    """Main entry point for Pagergotchi"""
    from pwnagotchi_port.log import setup_logging

    # Find config file (relative to this script's location)
    _this_dir = os.path.dirname(os.path.abspath(__file__))
    _payload_dir = os.path.abspath(os.path.join(_this_dir, '..'))
    config_paths = [
        os.path.join(_payload_dir, 'config.conf'),
        './config.conf',
        '../config.conf',
    ]

    config_path = None
    for path in config_paths:
        if os.path.exists(path):
            config_path = path
            break

    # Load config
    config = load_config(config_path)

    # Setup logging (only logs to file if debug=true in config)
    setup_logging(config)

    # Set name
    pwnagotchi.set_name(config['main'].get('name', 'pagergotchi'))

    # Load plugins (stub)
    plugins.load(config)

    # Main loop - allows returning to startup menu
    while True:
        # Show startup menu (Pager-specific addition)
        from pwnagotchi_port.ui.menu import StartupMenu
        startup_menu = StartupMenu(config)

        try:
            if not startup_menu.show_main_menu():
                logging.info("User chose to exit from menu")
                startup_menu.cleanup()
                return 0
        finally:
            startup_menu.cleanup()

        # Reload config in case whitelist changed
        config = load_config(config_path)

        # Create display/view
        view = View(config)

        # Create agent
        agent = Agent(view=view, config=config)

        # Signal handler
        def signal_handler(sig, frame):
            logging.info("Received signal %d, shutting down...", sig)
            stop_button_monitor()
            agent._save_recovery_data()
            agent.stop()  # Stop backend and cleanup tcpdump
            view.on_shutdown()
            view.cleanup()
            sys.exit(0)

        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)

        result = 'exit'
        try:
            result = do_auto_mode(agent)
        except KeyboardInterrupt:
            logging.info("Interrupted by user")
        finally:
            # Clear menu state first to prevent pause menu from being drawn during cleanup
            agent._menu_active = False
            # Stop button monitor to prevent it from accessing cleaned up resources
            stop_button_monitor()
            agent._save_recovery_data()
            agent.stop()  # Stop backend and cleanup tcpdump
            view.on_shutdown()
            view.cleanup()

        # Check result
        if result == 'launch':
            logging.info("Exiting with code 42 to launch next payload")
            return 42

        if result != 'main_menu':
            break

        logging.info("Returning to main menu...")
        # Reset global flags for next run
        global _exit_requested, _agent_ref
        _exit_requested = False
        _agent_ref = None

    return 0


if __name__ == '__main__':
    sys.exit(main())
