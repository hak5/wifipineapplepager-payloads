"""GPS on the Pager: the Pager's own gpsd, set up by itself.

The Pager reads its GPS through gpsd, on the port and speed picked under Settings > GPS. When gpsd hears no GPS,
each USB serial port is tried at the usual speeds with the Pager's own GPS_CONFIGURE, as picking it in Settings
would, until gpsd reports. The Pager's status bar then shows that GPS too. Without gpsd, ports are read directly.
"""

import json
import os
import re
import shutil
import socket
import subprocess
import time

from quartermaster import hardware
from quartermaster.gnss import GPS

SPEEDS = (9600, 115200, 4800, 38400)
USB_PORT = re.compile(r"tty(USB|ACM)\d+$")
BY_PATH = "/dev/serial/by-path"
LISTEN_SECONDS = 6.0
SETTLE_SECONDS = 2.0
RETRY_SECONDS = 300.0
KEPT_AWAY = ("node", "meshtastic", "dragon")


def gpsd_up(port=2947):
    try:
        socket.create_connection(("127.0.0.1", port), 1).close()
        return True
    except OSError:
        return False


def hears(stopped, seconds=LISTEN_SECONDS, port=2947):
    """True when gpsd reads a GPS within the time: a TPV or SKY report, or a device it found a driver for."""
    deadline = time.monotonic() + seconds
    while not stopped.is_set() and time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), 1) as sock:
                sock.settimeout(0.5)
                sock.sendall(b'?WATCH={"enable":true,"json":true};\n')
                buffer = b""
                while not stopped.is_set() and time.monotonic() < deadline:
                    try:
                        part = sock.recv(8192)
                    except socket.timeout:
                        continue
                    if not part:
                        break
                    buffer = (buffer + part)[-65536:]
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        try:
                            message = json.loads(line)
                        except ValueError:
                            continue
                        if not isinstance(message, dict):
                            continue
                        kind = message.get("class")
                        if kind in ("TPV", "SKY"):
                            return True
                        if kind == "DEVICE" and message.get("driver"):
                            return True
                        if kind == "DEVICES" and any(isinstance(d, dict) and d.get("driver")
                                                     for d in message.get("devices") or ()):
                            return True
        except OSError:
            stopped.wait(0.5)
    return False


def stable_name(path, by_path=BY_PATH):
    real = os.path.realpath(path)
    try:
        for name in sorted(os.listdir(by_path)):
            link = os.path.join(by_path, name)
            if os.path.realpath(link) == real:
                return link
    except OSError:
        pass
    return path


def current(run=subprocess.run):
    """The port and speed gpsd is set to, when the Pager keeps them in UCI."""
    found = []
    for key in ("gpsd.core.device", "gpsd.core.speed"):
        try:
            out = run(["uci", "-q", "get", key], capture_output=True, text=True, timeout=5)
            found.append(out.stdout.strip() if out.returncode == 0 else "")
        except (OSError, subprocess.SubprocessError):
            found.append("")
    return tuple(found)


class PagerGPS(GPS):
    def __init__(self, *args, which=shutil.which, run=subprocess.run, up=gpsd_up, listen=hears, **kwargs):
        super().__init__(*args, **kwargs)
        self.which, self.shell, self.up, self.listen = which, run, up, listen
        self.tried = {}
        self.setting_up = ""

    def _search(self, stopped):
        if self.mode == "off":
            return False
        if self.mode in ("auto", "gpsd") and self._gpsd(stopped):
            return True
        if self.mode == "auto" and self.up() and self.which("GPS_CONFIGURE"):
            return self.set_up(stopped)
        if self.mode != "gpsd" and not stopped.is_set():
            self._serial(stopped)
        return False

    def ports(self):
        now = time.monotonic()
        out = []
        for port in self._ports():
            path = port["path"]
            if not USB_PORT.search(os.path.realpath(path)) and not USB_PORT.search(path):
                continue
            if hardware.port_mark(path) in KEPT_AWAY or hardware.port_holder(path) in KEPT_AWAY:
                continue
            if now - self.tried.get(path, -RETRY_SECONDS) < RETRY_SECONDS:
                continue
            out.append(port)
        present = {p["path"] for p in self._ports()}
        self.tried = {path: at for path, at in self.tried.items() if path in present}
        return out

    def configure(self, port, speed):
        try:
            self.shell(["GPS_CONFIGURE", port, str(speed)], capture_output=True, timeout=30)
            self.shell(["/etc/init.d/gpsd", "restart"], capture_output=True, timeout=30)
            return True
        except (OSError, subprocess.SubprocessError):
            return False

    def set_up(self, stopped):
        """Point the Pager's gpsd at each USB serial port and speed in turn. True once gpsd hears a GPS."""
        ports = self.ports()
        if not ports:
            return False
        before = current(self.shell)
        for port in ports:
            path = port["path"]
            self.tried[path] = time.monotonic()
            name = stable_name(path)
            for speed in SPEEDS:
                if stopped.is_set() or self.mode != "auto":
                    return False
                self.setting_up = "%s at %d" % (port.get("label") or path, speed)
                if not self.configure(name, speed):
                    self.setting_up = ""
                    return False
                stopped.wait(SETTLE_SECONDS)
                if self.listen(stopped):
                    self.setting_up = ""
                    hardware.mark_port(path, "gps")
                    return True
            if hardware.port_mark(path) is None:
                hardware.mark_port(path, "checked")
        self.setting_up = ""
        if all(before):
            self.configure(*before)
        return False
