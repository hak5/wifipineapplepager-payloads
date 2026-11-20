"""Association probing for KEYSMITH.

Given a candidate passphrase, spin up a private ``wpa_supplicant`` on the
tri-band interface, watch its event log, and answer one question: did the
4-way handshake complete?

A wrong PSK is rejected by the AP after the second handshake message, which
``wpa_supplicant`` reports almost immediately.  The code keys off those exact
event strings, so a rejected candidate costs one second rather than a full
association timeout.
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time

from . import scan as scanmod

TMP = "/tmp"
PROBE_CONF = os.path.join(TMP, "keysmith_probe.conf")
LIVE_CONF = os.path.join(TMP, "keysmith_live.conf")
CTRL_DIR = os.path.join(TMP, "keysmith_ctrl")
PIDFILE = os.path.join(TMP, "keysmith_wpa.pid")

WPA_CANDIDATES = (
    "wpa_supplicant",
    "/usr/sbin/wpa_supplicant",
    "/mmc/usr/sbin/wpa_supplicant",
    "/usr/bin/wpa_supplicant",
    "/mmc/usr/bin/wpa_supplicant",
)
DHCP_CANDIDATES = ("udhcpc", "/sbin/udhcpc", "/mmc/sbin/udhcpc",
                   "/usr/sbin/udhcpc", "/mmc/usr/sbin/udhcpc")

SUCCESS_MARKS = ("CTRL-EVENT-CONNECTED",)
WRONG_MARKS = (
    "pre-shared key may be incorrect",
    "4-Way Handshake failed",
    "reason=WRONG_KEY",
    "reason=PREV_AUTH_NOT_VALID",
)
DRIVER_ERROR_MARKS = (
    "Failed to initialize driver",
    "No such device",
    "Could not read interface",
)


def _first(candidates):
    for name in candidates:
        if os.path.isabs(name):
            if os.access(name, os.X_OK):
                return name
        else:
            found = shutil.which(name)
            if found:
                return found
    return None


def wpa_bin():
    return _first(WPA_CANDIDATES)


def dhcp_bin():
    return _first(DHCP_CANDIDATES)


def _quote(text):
    return '"%s"' % str(text).replace("\\", "\\\\").replace('"', '\\"')


def conf_text(ssid, psk, bssid=None, freq=0, hidden=False):
    lines = [
        "ctrl_interface=%s" % CTRL_DIR,
        "update_config=0",
        "ap_scan=1",
        "",
        "network={",
        "    ssid=%s" % _quote(ssid),
        "    psk=%s" % _quote(psk),
        "    key_mgmt=WPA-PSK",
        "    proto=RSN WPA",
        "    pairwise=CCMP TKIP",
        "    group=CCMP TKIP",
        "    scan_ssid=1" if hidden else "",
    ]
    if bssid:
        lines.append("    bssid=%s" % bssid)
    if freq:
        lines.append("    scan_freq=%d" % int(freq))
    lines.append("}")
    return "\n".join([ln for ln in lines if ln != ""]) + "\n"


def write_conf(path, ssid, psk, bssid=None, freq=0, hidden=False):
    os.makedirs(CTRL_DIR, mode=0o700, exist_ok=True)
    with open(path, "w") as fh:
        fh.write(conf_text(ssid, psk, bssid, freq, hidden))
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return path


def _kill_tree(proc):
    if proc is None:
        return
    try:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
    except Exception:
        pass


class _LogTail:
    """Collect a child's output in a thread without blocking the poller."""

    def __init__(self, stream):
        self.lines = []
        self._lock = threading.Lock()
        self._stream = stream
        self._thread = threading.Thread(target=self._pump, daemon=True)
        self._thread.start()

    def _pump(self):
        try:
            for line in iter(self._stream.readline, ""):
                if not line:
                    break
                with self._lock:
                    self.lines.append(line.rstrip("\n"))
        except Exception:
            pass

    def snapshot(self):
        with self._lock:
            return list(self.lines)


def _start(conf, iface, driver, daemonize=False):
    binary = wpa_bin()
    if not binary:
        return None, "wpa_supplicant not installed"
    cmd = [binary, "-i", iface, "-c", conf]
    if driver:
        cmd[1:1] = ["-D", driver]
    if daemonize:
        cmd.insert(1, "-B")
        cmd[1:1] = ["-P", PIDFILE]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1), None


def probe(iface, ssid, psk, bssid=None, freq=0, hidden=False, timeout=9.0):
    """Test one passphrase.

    Returns ``{ok, wrong, reason, elapsed, log, driver}``.  ``ok`` is only
    true when the 4-way handshake completed; ``wrong`` means the AP rejected
    the key (as opposed to a timeout or a missing tool).
    """
    started = time.time()
    if not wpa_bin():
        return {"ok": False, "wrong": False, "reason": "no wpa_supplicant",
                "elapsed": 0.0, "log": [], "driver": None}
    conf = write_conf(PROBE_CONF, ssid, psk, bssid, freq, hidden)
    last_log = []
    for driver in ("nl80211", "wext", None):
        proc, err = _start(conf, iface, driver)
        if proc is None:
            return {"ok": False, "wrong": False, "reason": err,
                    "elapsed": time.time() - started, "log": [], "driver": driver}
        tail = _LogTail(proc.stdout)
        result = {"ok": False, "wrong": False, "reason": "timeout",
                  "elapsed": 0.0, "log": [], "driver": driver}
        while True:
            if proc.poll() is not None:
                result["reason"] = "wpa_supplicant exited"
                break
            lines = tail.snapshot()
            for line in lines:
                if any(mark in line for mark in SUCCESS_MARKS):
                    result.update(ok=True, wrong=False, reason="connected")
                    break
                if any(mark in line for mark in WRONG_MARKS):
                    result.update(ok=False, wrong=True, reason="wrong key")
                    break
            if result["ok"] or result["wrong"]:
                break
            if time.time() - started >= timeout:
                break
            time.sleep(0.12)
        last_log = tail.snapshot()
        result["log"] = last_log[-12:]
        _kill_tree(proc)
        if result["ok"] or result["wrong"]:
            result["elapsed"] = time.time() - started
            return result
        # A driver problem is worth one retry with the next backend; a real
        # timeout is not.
        if not any(any(m in ln for m in DRIVER_ERROR_MARKS) for ln in last_log):
            result["elapsed"] = time.time() - started
            return result
    return {"ok": False, "wrong": False, "reason": "no usable driver",
            "elapsed": time.time() - started, "log": last_log[-12:],
            "driver": None}


def connect(iface, ssid, psk, bssid=None, freq=0, hidden=False,
            dhcp_timeout=25, assume_ok=False, driver=None):
    """Associate for real and stay associated.

    Verifies the key first (so a bad key cannot strand the radio), then
    relaunches ``wpa_supplicant`` as a daemon and requests a lease.  Pass
    ``assume_ok`` when :func:`probe` has just confirmed the same key, to skip
    a redundant handshake.
    """
    if assume_ok:
        check = {"ok": True, "driver": driver or "nl80211",
                 "reason": "verified", "log": [], "elapsed": 0.0}
    else:
        check = probe(iface, ssid, psk, bssid, freq, hidden)
    if not check.get("ok"):
        return {"ok": False, "reason": check.get("reason", "handshake failed"),
                "probe": check, "ip": "", "router": "", "dns": []}
    conf = write_conf(LIVE_CONF, ssid, psk, bssid, freq, hidden)
    driver = check.get("driver")
    proc, err = _start(conf, iface, driver, daemonize=True)
    if proc is None:
        return {"ok": False, "reason": err, "probe": check, "ip": "",
                "router": "", "dns": []}
    try:
        proc.wait(timeout=6)
    except subprocess.TimeoutExpired:
        # -B should have exited; a lingering parent is harmless.
        pass
    lease = dhcp(iface, timeout=dhcp_timeout)
    return {"ok": True, "reason": "connected", "probe": check,
            "ip": lease.get("ip", ""), "router": lease.get("router", ""),
            "dns": lease.get("dns", []), "lease": lease, "driver": driver}


# --------------------------------------------------------------------------- #
# DHCP
# --------------------------------------------------------------------------- #

def payload_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def dhcp_script():
    path = os.path.join(payload_root(), "lib", "udhcpc.script")
    if os.path.isfile(path):
        return path
    return None


def iface_ip(iface):
    rc, out = scanmod.run(["ip", "-4", "addr", "show", "dev", iface], timeout=6)
    m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", out)
    return m.group(1) if m else ""


def iface_cidr(iface):
    rc, out = scanmod.run(["ip", "-4", "addr", "show", "dev", iface], timeout=6)
    m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+/\d+)", out)
    return m.group(1) if m else ""


def _parse_lease_text(text):
    lease = {"ip": "", "router": "", "dns": []}
    m = re.search(r"lease of\s+(\d+\.\d+\.\d+\.\d+)\s+obtained", text)
    if m:
        lease["ip"] = m.group(1)
    m = re.search(r"router\s+(\d+\.\d+\.\d+\.\d+)", text)
    if m:
        lease["router"] = m.group(1)
    lease["dns"] = re.findall(r"dns\s+(\d+\.\d+\.\d+\.\d+)", text)
    return lease


def dhcp(iface, timeout=25):
    """Request a lease without touching the Pager's default route."""
    binary = dhcp_bin()
    if not binary:
        return {"ok": False, "reason": "no DHCP client", "ip": "",
                "router": "", "dns": []}
    script = dhcp_script()
    cmd = [binary, "-i", iface, "-n", "-q", "-f", "-t", "6", "-T", "3"]
    if script:
        cmd += ["-s", script]
    rc, out = scanmod.run(cmd, timeout=timeout)
    lease = _parse_lease_text(out)
    ip = lease["ip"] or iface_ip(iface)
    lease["ok"] = bool(ip)
    lease["ip"] = ip
    lease["raw"] = out[-1200:]
    if not ip:
        lease["reason"] = "no lease"
    return lease


def release(iface):
    """Drop our association and address, leaving the stock radio alone."""
    pid = ""
    try:
        with open(PIDFILE, "r") as fh:
            pid = fh.read().strip()
    except OSError:
        pass
    if pid.isdigit():
        try:
            os.kill(int(pid), signal.SIGTERM)
        except OSError:
            pass
    # Outlive the daemon briefly, then clear the address we added.
    time.sleep(0.6)
    scanmod.run(["ip", "addr", "flush", "dev", iface], timeout=6)
    for path in (PIDFILE, LIVE_CONF, PROBE_CONF):
        try:
            os.unlink(path)
        except OSError:
            pass


def connected(iface):
    """True when wpa_supplicant still reports a completed association."""
    pid = ""
    try:
        with open(PIDFILE, "r") as fh:
            pid = fh.read().strip()
    except OSError:
        return False
    if not pid.isdigit():
        return False
    try:
        os.kill(int(pid), 0)
    except OSError:
        return False
    return True
