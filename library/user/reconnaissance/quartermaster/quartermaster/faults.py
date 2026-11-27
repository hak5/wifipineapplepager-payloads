"""Unexpected errors are noted in a file, so a wardrive carries on and the cause can still be found."""

import threading
import time
import traceback

from . import __version__

LIMIT_BYTES = 200_000
QUIET_SECONDS = 60

path = None
_lock = threading.Lock()
_recent = {}


def note(where):
    """Record the error being handled. The same error in the same place is written once a minute at most."""
    report = traceback.format_exc()
    key = (where, report.rstrip().rsplit("\n", 1)[-1])
    now = time.monotonic()
    with _lock:
        if path is None or now - _recent.get(key, -QUIET_SECONDS) < QUIET_SECONDS:
            return
        if len(_recent) > 100:
            _recent.clear()
        _recent[key] = now
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            fresh = not path.exists() or path.stat().st_size > LIMIT_BYTES
            with open(path, "w" if fresh else "a", encoding="utf-8", errors="replace") as out:
                out.write("%s  Quartermaster %s  %s\n%s\n"
                          % (time.strftime("%Y-%m-%d %H:%M:%S"), __version__, where, report))
        except OSError:
            pass
