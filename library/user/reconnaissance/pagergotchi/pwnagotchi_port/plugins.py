"""
Plugin system stub for Pagergotchi
Provides no-op implementations since plugins aren't supported on Pager
"""

import logging

# No plugins loaded
loaded = {}


def on(event, *args, **kwargs):
    """
    No-op plugin event handler

    In original pwnagotchi, this would dispatch events to all loaded plugins.
    Here we just log and ignore.
    """
    logging.debug(f"[plugins] Event: {event} (no plugins loaded)")
    pass


def load(config):
    """Load plugins - no-op for Pager"""
    logging.info("[plugins] Plugin system disabled on Pager")
    pass


def unload():
    """Unload plugins - no-op"""
    pass
