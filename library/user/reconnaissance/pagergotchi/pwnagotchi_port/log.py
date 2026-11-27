"""
Logging and session tracking for Pagergotchi
Provides LastSession class for session statistics
"""

import os
import json
import logging
from datetime import datetime

import pwnagotchi_port.utils as utils

# Payload directory paths (relative to this file's location)
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PAYLOAD_DIR = os.path.abspath(os.path.join(_THIS_DIR, '..'))
DATA_DIR = os.path.join(PAYLOAD_DIR, 'data')
SESSION_FILE = os.path.join(DATA_DIR, 'session.json')
LOG_FILE = os.path.join(DATA_DIR, 'pagergotchi.log')


class LastSession:
    """Track statistics from the last session"""

    def __init__(self, config):
        self._config = config
        self.duration = "00:00:00"
        self.duration_human = "0 minutes"
        self.deauthed = 0
        self.associated = 0
        self.handshakes = 0
        self.peers = 0
        self.last_peer = None
        self.epochs = 0

        # Try to load from saved file
        self._load()

    def _load(self):
        """Load last session data from file"""
        try:
            if os.path.exists(SESSION_FILE):
                with open(SESSION_FILE, 'r') as f:
                    data = json.load(f)
                    self.duration = data.get('duration', '00:00:00')
                    self.deauthed = data.get('deauthed', 0)
                    self.associated = data.get('associated', 0)
                    self.handshakes = data.get('handshakes', 0)
                    self.epochs = data.get('epochs', 0)
        except Exception as e:
            logging.debug(f"Could not load last session: {e}")

    def save(self, duration_secs=0, deauthed=0, associated=0, handshakes=0, epochs=0):
        """Save session data"""
        try:
            # Ensure data directory exists
            if not os.path.exists(DATA_DIR):
                os.makedirs(DATA_DIR)
            data = {
                'duration': utils.secs_to_hhmmss(duration_secs),
                'deauthed': deauthed,
                'associated': associated,
                'handshakes': handshakes,
                'epochs': epochs,
                'timestamp': datetime.now().isoformat()
            }
            with open(SESSION_FILE, 'w') as f:
                json.dump(data, f)
        except Exception as e:
            logging.debug(f"Could not save session: {e}")


def setup_logging(config):
    """Configure logging for Pagergotchi - only logs to file if debug enabled"""
    debug_enabled = config.get('main', {}).get('debug', False)

    # Set log level based on debug mode
    level = logging.DEBUG if debug_enabled else logging.WARNING

    # Configure root logger (console only, minimal output)
    logging.basicConfig(
        level=level,
        format='[%(asctime)s] [%(levelname)s] %(message)s',
        datefmt='%H:%M:%S'
    )

    # Only add file handler if debug is enabled
    if debug_enabled:
        try:
            # Ensure data directory exists
            if not os.path.exists(DATA_DIR):
                os.makedirs(DATA_DIR)
            file_handler = logging.FileHandler(LOG_FILE)
            file_handler.setLevel(logging.DEBUG)
            file_handler.setFormatter(logging.Formatter(
                '[%(asctime)s] [%(levelname)s] %(message)s',
                datefmt='%Y-%m-%d %H:%M:%S'
            ))
            logging.getLogger().addHandler(file_handler)
            logging.info(f"Debug logging enabled: {LOG_FILE}")
        except Exception as e:
            logging.warning(f"Could not set up log file: {e}")
