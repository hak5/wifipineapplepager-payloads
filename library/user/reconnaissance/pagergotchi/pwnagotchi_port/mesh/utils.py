"""
Mesh networking stub for Pagergotchi
Mesh/advertising is disabled on Pager - no bluetooth, limited resources
"""

import logging


class AsyncAdvertiser:
    """
    Stub for mesh advertising - no-op on Pager

    Original pwnagotchi uses this to broadcast presence to nearby units.
    We don't have the resources or bluetooth for this on the Pager.
    """

    def __init__(self, config, view, keypair):
        self._config = config
        self._view = view
        self._keypair = keypair
        self._peers = {}
        self._closest_peer = None
        logging.debug("[mesh] AsyncAdvertiser disabled on Pager")

    def fingerprint(self):
        """Return device fingerprint (simplified)"""
        return "pager-0000"

    def start_advertising(self):
        """No-op - no mesh on Pager"""
        pass

    def stop_advertising(self):
        """No-op"""
        pass

    def _update_advertisement(self, session):
        """No-op"""
        pass
