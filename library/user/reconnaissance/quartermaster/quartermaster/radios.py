"""One mode owns the radios at a time, so a wardrive and Recon can never overlap."""

import threading

_lock = threading.Lock()
_owner = None
NAMES = {"wardrive": "the wardrive", "recon": "Recon"}


class Busy(RuntimeError):
    pass


def claim(mode):
    global _owner
    with _lock:
        if _owner not in (None, mode):
            raise Busy("Stop %s first" % NAMES.get(_owner, _owner))
        _owner = mode


def release(mode):
    global _owner
    with _lock:
        if _owner == mode:
            _owner = None


def owner():
    return _owner
