"""Wi-Fi scanning on every adapter at once.

Each adapter gets its own thread and scans all the bands it supports, so a
tri-band adapter covers 2.4, 5 and 6 GHz in one sweep while the built-in radio
keeps sweeping 2.4 GHz beside it. Results come from `iw` (true dBm, full
security details), and NetworkManager starts the sweep when the app is not
allowed to. Nothing here connects to a network or probes one by name.
"""

import re
import shutil
import subprocess
import threading
import time

from . import faults


class ScanUnavailable(RuntimeError):
    pass


def channel_of(freq):
    if not freq:
        return None
    if 2412 <= freq <= 2472:
        return (freq - 2407) // 5
    if freq == 2484:
        return 14
    if 5000 <= freq <= 5900:
        return (freq - 5000) // 5
    if 5955 <= freq <= 7115:
        return (freq - 5950) // 5
    return None


def band_of(freq):
    if not freq:
        return ""
    return "2.4" if freq < 3000 else ("5" if freq < 5925 else "6")


def _word(text, index):
    words = text.split()
    return words[index] if -len(words) <= index < len(words) else ""


def _number(text, low, high):
    """A number within bounds, else None. Scan output carries text straight off the air: "inf" is a number too."""
    try:
        value = float(text)
    except ValueError:
        return None
    return value if low <= value <= high else None


def _unescape(text):
    """iw prints non-printable SSID bytes as \\xNN and a backslash as \\\\."""
    raw = bytearray()
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            if text[i + 1] == "x" and i + 3 < len(text):
                try:
                    raw.append(int(text[i + 2:i + 4], 16))
                    i += 4
                    continue
                except ValueError:
                    pass
            elif text[i + 1] == "\\":
                raw.append(0x5C)
                i += 2
                continue
        raw.extend(text[i].encode("utf-8", "replace"))
        i += 1
    return raw.decode("utf-8", "replace")


def capabilities(net):
    """The capability string WiGLE expects (Android style), e.g. [WPA2-PSK-CCMP][RSN-SAE-CCMP][ESS]."""
    parts = []

    def cipher(names):
        names = [n for n in names if n]
        if "CCMP" in names and "TKIP" in names:
            return "CCMP+TKIP"
        for want in ("GCMP-256", "CCMP-256", "GCMP", "CCMP", "TKIP"):
            if want in names:
                return want
        named = [n for n in names if re.fullmatch(r"[A-Za-z0-9-]{2,16}", n)]
        return named[0] if named else "CCMP"

    wpa, rsn = net.get("wpa"), net.get("rsn")
    if wpa:
        for suite in wpa.get("auth") or ["PSK"]:
            kind = "EAP" if suite.startswith(("IEEE 802.1X", "802.1X", "EAP")) else "PSK"
            parts.append("[WPA-%s-%s]" % (kind, cipher(wpa.get("pairwise", []))))
    if rsn:
        ciph = cipher(rsn.get("pairwise", []))
        for suite in rsn.get("auth") or ["PSK"]:
            upper = suite.upper()
            if "SAE" in upper:
                parts.append("[RSN-SAE-%s]" % ciph)
            elif "OWE" in upper:
                parts.append("[RSN-OWE-%s]" % ciph)
            elif "802.1X" in upper or "EAP" in upper or "SUITE-B" in upper or "SUITE B" in upper:
                parts.append("[WPA2-EAP-%s]" % ciph)
            elif "PSK" in upper:
                parts.append("[WPA2-PSK-%s]" % ciph)
            else:
                parts.append("[RSN-%s-%s]" % (re.sub(r"[^A-Z0-9.]+", "_", upper)[:16], ciph))
    if not wpa and not rsn and net.get("privacy"):
        parts.append("[WEP]")
    if net.get("wps"):
        parts.append("[WPS]")
    parts.append("[IBSS]" if net.get("ibss") else "[ESS]")
    return "".join(dict.fromkeys(parts))


def security_label(net):
    """Short label for the live screen."""
    caps = net.get("capabilities") or capabilities(net)
    if "SAE" in caps:
        return "WPA3" if "PSK" not in caps else "WPA2/3"
    if "OWE" in caps:
        return "OWE"
    if "EAP" in caps:
        return "EAP"
    if "WPA2" in caps:
        return "WPA2"
    if "WPA-" in caps:
        return "WPA"
    if "WEP" in caps:
        return "WEP"
    return "OPEN"


def parse_iw_scan(text):
    """Networks from `iw dev <if> scan` or `scan dump`, with everything WiGLE wants."""
    networks, current, block = [], None, None
    for line in text.split("\n"):
        match = re.match(r"BSS ((?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})", line)
        if match:
            current = {"bssid": match.group(1).upper(), "ssid": "", "rssi": None, "channel": None,
                       "frequency": None, "privacy": False, "ibss": False, "wps": False, "wpa": None,
                       "rsn": None, "last_seen_ms": None, "hidden": False}
            networks.append(current)
            block = None
            continue
        if line.startswith("BSS "):
            current = None
        if current is None or not line.startswith(("\t", " ")):
            continue
        stripped = line.strip()
        indent = len(line) - len(line.lstrip("\t "))
        if stripped.startswith("* ") and block is not None and indent >= 2:
            key, _, value = stripped[2:].partition(":")
            key, values = key.strip().lower(), value.split()
            if key == "pairwise ciphers":
                block["pairwise"] = values
            elif key == "group cipher":
                block["group"] = values
            elif key == "authentication suites":
                # "IEEE 802.1X" is one suite printed as two words.
                suites = re.findall(r"IEEE 802\.1X(?:/\S+)?|\S+", value.strip())
                block["auth"] = suites
            continue
        if not stripped.startswith("* "):
            block = None
        if stripped.startswith("freq:"):
            value = _number(_word(stripped, 1), 1, 99999)
            if value is not None:
                current["frequency"] = int(value)
        elif stripped.startswith("signal:"):
            value = _number(_word(stripped, 1), -200, 100)
            if value is not None:
                current["rssi"] = value
        elif stripped.startswith("last seen:"):
            match = re.search(r"\b([0-9]{1,12}) ms ago", stripped)
            if match:
                current["last_seen_ms"] = int(match.group(1))
        elif stripped.startswith("SSID:"):
            ssid = _unescape(line.split("SSID:", 1)[1].strip())
            if ssid.strip("\x00") == "":
                ssid = ""
            current["ssid"] = ssid[:32]
            current["hidden"] = ssid == ""
        elif stripped.startswith(("DS Parameter set: channel", "* primary channel:")):
            value = _number(_word(stripped, -1), 1, 233)
            if value is not None and (current["channel"] is None or stripped.startswith("DS")):
                current["channel"] = int(value)
        elif stripped.startswith("RSN:"):
            block = current["rsn"] = {"pairwise": [], "auth": []}
        elif stripped.startswith("WPA:"):
            block = current["wpa"] = {"pairwise": [], "auth": []}
        elif stripped.startswith("WPS:"):
            current["wps"] = True
        elif stripped.startswith("capability:"):
            current["privacy"] = "Privacy" in stripped
            current["ibss"] = "IBSS" in stripped
    for net in networks:
        # The frequency is authoritative; the DS channel can be wrong on 5/6 GHz.
        net["channel"] = channel_of(net["frequency"]) or net["channel"]
        net["band"] = band_of(net["frequency"])
        net["capabilities"] = capabilities(net)
        net["security"] = security_label(net)
    return networks


class AdapterScanner:
    """Scans one interface. `scan()` returns only what was heard in this sweep."""

    def __init__(self, adapter, runner=subprocess.run, clock=time.monotonic):
        self.adapter = adapter
        self.interface = adapter["interface"]
        self.runner = runner
        self.clock = clock
        self.method = None
        self.last_error = ""
        self.sweeps = 0
        self.last_sweep_seconds = None
        self.direct = None          # None: untested, True: iw may trigger scans, False: use NetworkManager
        self.sleep = time.sleep
        self.poll_seconds = 1.0
        self.sweep_timeout = 12.0

    def _run(self, args, timeout=20):
        return self.runner(args, capture_output=True, text=True, errors="replace", timeout=timeout, check=False)

    def scan(self):
        started = self.clock()
        text = None
        helper = self.adapter.get("helper")
        if helper is not None:
            text = self._helper_sweep(helper)
        if text is None and not shutil.which("iw"):
            raise ScanUnavailable("The iw tool is missing")
        if text is None and self.direct is not False:
            # A direct trigger returns when the sweep ends, with fresh results. It needs
            # CAP_NET_ADMIN; without it NetworkManager triggers the sweep instead.
            result = self._run(["iw", "dev", self.interface, "scan"])
            if result.returncode == 0:
                self.direct, self.method, text = True, "iw", result.stdout
            elif "not permitted" in (result.stderr or "").lower() or "(-1)" in (result.stderr or ""):
                self.direct = False
            elif "busy" not in (result.stderr or "").lower() and self.direct is None:
                self.direct = False
        if text is None:
            text = self._managed_sweep(started)
            self.method = "nm+iw"
        elapsed = self.clock() - started
        self.sweeps += 1
        self.last_sweep_seconds = elapsed
        limit = int(elapsed * 1000) + 1500
        networks = [n for n in parse_iw_scan(text)
                    if n["rssi"] is not None and (n["last_seen_ms"] is None or n["last_seen_ms"] <= limit)]
        for net in networks:
            net["interface"] = self.interface
        return networks

    def _helper_sweep(self, helper):
        """A sweep the radio helper starts, when Direct scans is on. None sends the adapter back to the usual way."""
        from .radio_helper import HelperError
        try:
            text = helper.request("scan", iface=self.interface)["text"]
        except HelperError as exc:
            self.last_error = str(exc)[:80]
            if "busy" not in str(exc).lower():
                self.adapter = dict(self.adapter, helper=None)
            return None
        self.method = "helper"
        return text

    def _managed_sweep(self, started):
        """Ask NetworkManager for a sweep, then read the kernel's results once they stop arriving.

        The request returns at once and the radio needs a few seconds to cover every band, so
        the results are polled until the number heard since the request holds steady."""
        if shutil.which("nmcli"):
            self._run(["nmcli", "device", "wifi", "rescan", "ifname", self.interface], timeout=10)
        previous, text, deadline = -1, "", started + self.sweep_timeout
        while True:
            self.sleep(self.poll_seconds)
            result = self._run(["iw", "dev", self.interface, "scan", "dump"])
            if result.returncode != 0:
                self.last_error = (result.stderr or "scan failed").strip().splitlines()[-1][:80]
                raise ScanUnavailable("%s: %s" % (self.interface, self.last_error))
            text = result.stdout
            window = (self.clock() - started) * 1000 + 300
            fresh = sum(1 for n in parse_iw_scan(text) if n["last_seen_ms"] is not None and n["last_seen_ms"] <= window)
            if (fresh and fresh == previous) or self.clock() >= deadline:
                return text
            previous = fresh


class WifiFleet:
    """One scan thread per adapter; results are pushed to `sink(networks, adapter)`.

    `refresh()` may be called at any time with the adapters now present: new ones start
    scanning at once and unplugged ones drop out without disturbing the rest. With `stagger` set, the first sweeps of
    USB adapters start that many seconds apart, and one plugged in later waits that long, so that their power spikes
    do not land together."""

    def __init__(self, adapters, sink, interval=0.0, scanner=AdapterScanner, clock=time.monotonic):
        self.adapters = list(adapters)
        self.sink = sink
        self.interval = interval
        self.scanner_class = scanner
        self.clock = clock
        self.stagger = 0.0
        self.spacing = {}
        self._next_start = None
        self._began = False
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.running = {}      # interface -> (scanner, stop event, thread)

    @property
    def scanners(self):
        with self.lock:
            return [entry[0] for entry in self.running.values()]

    def start(self):
        self.refresh(self.adapters)

    def refresh(self, adapters):
        present = {a["interface"]: a for a in adapters}
        with self.lock:
            for name in [n for n in self.running if n not in present]:
                self.running.pop(name)[1].set()
            for name, adapter in present.items():
                if name in self.running or self.stopped.is_set():
                    continue
                scanner, gone = self.scanner_class(adapter), threading.Event()
                thread = threading.Thread(target=self._loop, args=(scanner, gone, self._delay(adapter)), daemon=True,
                                          name="wifi-" + name)
                self.running[name] = (scanner, gone, thread)
                thread.start()
            self._began = True

    def _delay(self, adapter):
        """How long a new adapter waits before its first sweep. Call this with the lock held."""
        if not self.stagger or not adapter.get("external"):
            return 0.0
        now = self.clock()
        delay = max(0.0, (self._next_start or now) - now)
        if self._began:
            delay = max(delay, self.stagger)
        self._next_start = now + delay + self.stagger
        return delay

    def space(self, interface, seconds):
        """A longer pause between the sweeps of one adapter, to spread out the power it draws."""
        self.spacing[interface] = seconds

    def _loop(self, scanner, gone, delay=0.0):
        failures = 0
        if delay and gone.wait(delay):
            return
        while not self.stopped.is_set() and not gone.is_set():
            try:
                networks = scanner.scan()
                failures = 0
                scanner.last_error = ""
                if not gone.is_set():
                    self.sink(networks, scanner.adapter)
                gone.wait(self.interval + self.spacing.get(scanner.interface, 0.0))
            except Exception as exc:
                known = isinstance(exc, (ScanUnavailable, OSError, subprocess.SubprocessError))
                if not known:
                    faults.note("Wi-Fi scan on %s" % scanner.interface)
                scanner.last_error = str(exc)[:80] if known else "Scan failed (%s). Trying again." % type(exc).__name__
                failures += 1
                # Busy radios recover quickly; an unplugged adapter backs off until it is dropped.
                gone.wait(min(10.0, 0.5 * failures))

    def stop(self):
        self.stopped.set()
        with self.lock:
            entries = list(self.running.values())
            self.running = {}
        for _, gone, thread in entries:
            gone.set()
        for _, _, thread in entries:
            thread.join(timeout=25)

    def status(self):
        return [{"interface": s.interface, "method": s.method, "sweeps": s.sweeps,
                 "sweep_seconds": s.last_sweep_seconds, "error": s.last_error,
                 "label": s.adapter.get("label", ""), "bands": s.adapter.get("bands", [])}
                for s in self.scanners]
