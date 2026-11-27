"""Alert tones: a small library of synthesized sounds, played one at a time with aplay off every scan thread.

The tone queue rules come from Dragon Detector (MIT, Valleytech Custom Solutions).
"""

import importlib.util
import io
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import wave

RATE = 22050
VOLUMES = {"high": 0.7, "medium": 0.4, "low": 0.2}
REPEAT_SECONDS, EXPIRE_SECONDS = 4.0, 10.0
PREEMPT, PREVIEW = 95, 1000
RETRY_SECONDS = (2.0, 10.0, 60.0)


def _seg(f0, f1, ms, kind="sine", level=1.0, curve="lin"):
    return (f0, f1, ms, kind, level, curve)


def _rest(ms):
    return (0, 0, ms, "sine", 0.0, "lin")


TONES = {
    "siren": ("Siren", [_seg(620, 1480, 600, "tri", 1.0, "exp"), _seg(1480, 620, 600, "tri", 1.0, "exp")]),
    "yelp": ("Yelp", [_seg(650, 1650, 170, "tri"), _seg(1650, 650, 170, "tri")] * 4),
    "chirp": ("Chirp", [_seg(2000, 3400, 55), _rest(45)] * 3 + [_seg(3300, 1900, 180, curve="exp")]),
    "shutter": ("Shutter", [_seg(0, 0, 10, "noise"), _rest(45), _seg(0, 0, 14, "noise", 0.8), _rest(70),
                            _seg(700, 2600, 320, "sine", 0.55, "exp")]),
    "ping": ("Ping", [_seg(2093, 2093, 180, "glass"), _seg(2637, 2637, 320, "glass")]),
    "blip": ("Blip", [_seg(880, 880, 50, level=0.55), _rest(35), _seg(1320, 1320, 70, level=0.55)]),
}
TONES["silent"] = ("Silent", [])
TONES["beep"] = ("Recon beep", [_seg(1760, 1760, 90, level=0.4), _rest(40), _seg(2349, 2349, 120, level=0.4)])
ORDER = ("siren", "yelp", "chirp", "shutter", "ping", "blip", "silent")


def name(tone):
    return TONES.get(tone, ("?",))[0]


def render(tone, volume="high"):
    """The tone as signed 16-bit samples at RATE."""
    import numpy as np
    peak = 32767 * VOLUMES.get(volume, VOLUMES["high"])
    noise = np.random.default_rng(7)
    out, phase = [], 0.0
    for f0, f1, ms, kind, level, curve in TONES[tone][1]:
        n = int(RATE * ms / 1000)
        if n <= 0:
            continue
        t = np.arange(n) / n
        if kind == "noise":
            wave_ = noise.uniform(-1.0, 1.0, n)
        elif not f0:
            out.append(np.zeros(n))
            continue
        else:
            freq = f0 * (f1 / f0) ** t if curve == "exp" else f0 + (f1 - f0) * t
            angle = phase + np.cumsum(2 * math.pi * freq / RATE)
            phase = float(angle[-1]) % (2 * math.pi)
            if kind == "tri":
                wave_ = 2 / math.pi * np.arcsin(np.sin(angle))
            elif kind == "square":
                wave_ = np.where(np.sin(angle) >= 0, 1.0, -1.0)
            elif kind == "glass":
                wave_ = (np.sin(angle) + 0.35 * np.sin(2.76 * angle)) / 1.35 * np.exp(-5 * t)
            else:
                wave_ = np.sin(angle)
        fade = max(1, min(int(RATE * 0.004), n // 2))
        ramp = np.arange(n)
        envelope = np.minimum(1.0, np.minimum(ramp / fade, (n - ramp) / fade))
        out.append(wave_ * envelope * level)
    samples = np.concatenate(out) if out else np.zeros(0)
    return np.clip(samples * peak, -32767, 32767).astype("<i2")


def wav_bytes(tone, volume="high"):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(render(tone, volume).tobytes())
    return buffer.getvalue()


def find_player():
    if importlib.util.find_spec("numpy") is None:
        return None
    return shutil.which("aplay")


class ToneQueue:
    """One waiting request per kind. A kind that played under four seconds ago is not asked again, a request
    left waiting ten seconds lapses, and the most important waiting kind plays first."""

    def __init__(self):
        self.pending, self.last = {}, {}

    def request(self, kind, sound, priority, now, force=False):
        if not force and now - self.last.get(kind, -REPEAT_SECONDS) < REPEAT_SECONDS:
            return False
        held = self.pending.get(kind)
        self.pending[kind] = (priority, held[1] if held else now, sound)
        return True

    def best(self, now):
        for kind in [k for k, (_, at, _) in self.pending.items() if now - at > EXPIRE_SECONDS]:
            del self.pending[kind]
        return max((item[0] for item in self.pending.values()), default=None)

    def take(self, now):
        if self.best(now) is None:
            return None
        kind = max(self.pending, key=lambda k: self.pending[k][0])
        priority, _, sound = self.pending.pop(kind)
        self.last[kind] = now
        return kind, priority, sound


class Player:
    """Plays tones with aplay on a thread of its own, one at a time. Asking never waits for anything."""

    def __init__(self, directory=None, popen=subprocess.Popen, clock=time.monotonic):
        self.command = find_player()
        self.directory = Path(directory) if directory else None
        self.popen, self.clock = popen, clock
        self.queue = ToneQueue()
        self.failed = False
        self.played = 0
        self.failures, self.retry_at = 0, 0.0
        self._child, self._child_priority = None, 0
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._thread = None
        self._stopping = False

    def available(self):
        return bool(self.command) and not self.failed

    def play(self, tone, volume="high", kind=None, priority=50, preview=False):
        if tone not in TONES or tone == "silent" or not self.available():
            return False
        with self._lock:
            if preview:
                self.queue.pending.pop("preview", None)
            accepted = self.queue.request("preview" if preview else (kind or tone), (tone, volume),
                                          PREVIEW if preview else priority, self.clock(), force=preview)
            if accepted and self._thread is None:
                self._stopping = False
                self._thread = threading.Thread(target=self._run, daemon=True, name="tones")
                self._thread.start()
        if accepted:
            self._wake.set()
        return accepted

    def stop(self):
        self._stopping = True
        self._wake.set()
        thread, self._thread = self._thread, None
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2)
        self._end_child()

    def hush(self):
        """Drop the tones waiting and cut off the one playing."""
        with self._lock:
            self.queue.pending.clear()
            self._end_child()

    def _end_child(self):
        child, self._child = self._child, None
        if child is not None and child.poll() is None:
            try:
                child.terminate()
            except OSError:
                pass

    def _run(self):
        while not self._stopping:
            self._wake.wait(0.05 if self.queue.pending else None)
            self._wake.clear()
            try:
                self.step()
            except Exception:
                from . import faults
                faults.note("Alert tone")

    def step(self):
        """Start the next tone when the speaker is free. Returns the kind started, if any."""
        with self._lock:
            now = self.clock()
            child = self._child
            running = child is not None and child.poll() is None
            if child is not None and not running:
                self._child = None
                if child.poll():
                    self.retry_at = now + RETRY_SECONDS[min(self.failures, len(RETRY_SECONDS) - 1)]
                    self.failures += 1
                else:
                    self.failures = 0
            best = self.queue.best(now)
            if best is None or self.failed or now < self.retry_at:
                return None
            if running:
                if best < PREEMPT or best <= self._child_priority and best < PREVIEW:
                    return None
                self._end_child()
            kind, priority, (tone, volume) = self.queue.take(now)
        try:
            path = self.path(tone, volume)
            child = self.popen([self.command, "-q", str(path)], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            self.failed = True
            return None
        with self._lock:
            self._child, self._child_priority = child, priority
            self.played += 1
        return kind

    def path(self, tone, volume):
        directory = self.directory or Path(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()) / (
            "quartermaster-tones-%d" % os.getuid())
        path = directory / ("%s-%s.wav" % (tone, volume))
        if not path.exists():
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            tmp = path.with_name("." + path.name + ".%d" % threading.get_ident())
            tmp.write_bytes(wav_bytes(tone, volume))
            os.replace(tmp, path)
        return path
