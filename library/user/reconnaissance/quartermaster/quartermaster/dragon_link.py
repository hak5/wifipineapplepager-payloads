"""A Dragon Detector on USB: its alerts join the alerts of a wardrive.

Dragon Detector (Valleytech Custom Solutions, MIT) prints one line for every new detection on its USB port:
`ALERT <family>: <name> / <rssi> dBm / <evidence>`. Its radar hears Wi-Fi frames that scanning cannot, such as the
probe requests of Flock cameras. Only those lines are read, and each is graded with Recon's own evidence grades,
because Dragon Detector's evidence texts are the same as Recon's.
"""

from collections import deque
from pathlib import Path
import re
import threading
import time

from . import faults, recon
from .recon_vendors import VENDOR_PREFIXES

MAX_LINE = 512
TITLES = {"Flock": "flock", "Body cameras": "axon", "Camera glasses": "glasses", "ALPR vendor": "alpr",
          "Camera vendor": "camera", "Ring": "ring", "Drone / Remote ID": "drone", "Acoustic sensors": "raven",
          "Serial module": "skimmer", "Flipper": "hacker", "Pineapple": "hacker", "Pwnagotchi": "hacker",
          "Nyanbox": "hacker", "HaleHound": "hacker", "Biscuit": "hacker", "Find My / DULT": "airtag",
          "SmartTag": "samsung_tag", "Google Find Hub": "google_tag", "Tile": "tile", "iBeacon": "ibeacon",
          "Disconnect burst": "deauth", "SSID conflict": "eviltwin", "BLE advert burst": "hacker",
          "Dragon fox": "hacker", "WATCH LIST HIT": "mine"}
INCIDENTS = {"Disconnect burst": "deauth", "SSID conflict": "eviltwin", "BLE advert burst": "burst"}
_ALERT = re.compile(r"ALERT (?P<title>[^:]+): (?:(?P<name>.*?) / )?(?P<rssi>-?[0-9]+) dBm / (?P<evidence>.*)")
_GRADE = re.compile(r"\(\s*\"\w+\",\s*(LOW|MEDIUM|STRONG),\s*\"([^\"\n]+)\"\s*\)")
_grades = None


def grades():
    """{evidence text: grade} for every fixed evidence text Recon gives."""
    global _grades
    if _grades is None:
        found = {evidence: recon._CONF[grade] for _, _, grade, evidence in VENDOR_PREFIXES}
        try:
            source = Path(recon.__file__).read_text(encoding="utf-8")
            found.update((evidence, getattr(recon, grade)) for grade, evidence in _GRADE.findall(source))
        except OSError:
            pass
        _grades = found
    return _grades


def recognised(lines):
    """Whether what a board said when asked for a node is Dragon Detector's answer."""
    return any(line.startswith((b"Commands: status, contacts", b"DRAGON DETECTOR ")) for line in lines)


def parse(line):
    """The alert of one line, or None when the line is not a detection."""
    match = _ALERT.fullmatch(line.strip())
    if match is None or match["title"] not in TITLES:
        return None
    category, evidence = TITLES[match["title"]], match["evidence"]
    incident = INCIDENTS.get(match["title"])
    if category == "mine":
        confidence = recon.STRONG
    elif incident:
        confidence = recon.MEDIUM
    elif match["title"] == "Dragon fox":
        confidence = recon.LOW
    else:
        confidence = grades().get(evidence, recon.MEDIUM)
    alert = {"category": category, "name": (match["name"] or "")[:64], "rssi": int(match["rssi"]),
             "confidence": confidence, "evidence": evidence[:160], "title": match["title"], "source": "dragon"}
    if incident:
        alert["incident"] = incident
    return alert


class DragonLink:
    """Reads one Dragon Detector's port on a thread of its own and hands each detection to sink()."""

    def __init__(self, path, port, sink, gone=None, text=()):
        self.path, self.port, self.sink, self.gone = path, port, sink, gone
        self.version = ""
        self.alerts = 0
        self.recent = deque(maxlen=20)
        self.closed = False
        self._buffer = b""
        self._stop = threading.Event()
        self._thread = None
        for line in text:
            self.line(line)

    def start(self):
        try:
            self.port.write(b"badge info\n")
        except (OSError, ValueError, TypeError):
            pass
        self._thread = threading.Thread(target=self._run, daemon=True, name="dragon-detector")
        self._thread.start()

    def _run(self):
        try:
            while not self._stop.is_set() and self.pump():
                pass
        except Exception:
            faults.note("Dragon Detector")
        self._close()

    def pump(self):
        try:
            data = self.port.read(max(1, self.port.in_waiting))
        except (OSError, ValueError, TypeError):
            return False
        if data:
            self.take(data)
        return True

    def take(self, data):
        lines = (self._buffer + data).split(b"\n")
        self._buffer = lines.pop()
        if len(self._buffer) > MAX_LINE:
            self._buffer = b""
        for line in lines:
            if len(line) <= MAX_LINE:
                self.line(line)

    def line(self, raw):
        text = raw.rstrip(b"\r").decode("utf-8", "replace")
        if text.startswith("BADGE_INFO "):
            self.version = text.split()[1][:16] if len(text.split()) > 1 else ""
            return
        alert = parse(text)
        if alert is None:
            return
        alert["time"] = time.time()
        self.alerts += 1
        self.recent.appendleft(alert)
        try:
            self.sink(alert)
        except Exception:
            faults.note("A Dragon Detector alert")

    def stop(self):
        self._stop.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=1.0)
        self._close()

    def _close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.port.close()
        except (OSError, ValueError, TypeError):
            pass
        if self.gone is not None:
            self.gone()
