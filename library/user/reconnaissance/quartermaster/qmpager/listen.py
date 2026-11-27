"""Wi-Fi on the Pager: every frame PineAP's monitor radio hears, read in a process of its own.

PineAP keeps wlan1mon in monitor mode and hops it across 2.4, 5 and 6 GHz. Quartermaster only reads
from it and never changes its channel, so PineAP and the Pager's own recon carry on as before. Beacons
and probe responses become the same network records an `iw` scan gives; probe requests, disconnect
floods and evil twin clashes go to Drive Alerts and Recon, as Deep scan does on the CardputerZero.
"""

import ctypes
import multiprocessing
import os
import socket
import struct
import threading
import time

from quartermaster import faults, monitor

INTERFACE = "wlan1mon"
ETH_P_ALL = 0x0003
LABEL = "Pager radio (PineAP monitor)"


SO_ATTACH_FILTER = 26
KEEP_BYTES = 4096
LD_B_ABS, LD_B_IND, LD_W_IND, TAX = 0x30, 0x50, 0x40, 0x07
AND_K, JEQ_K, RET_K = 0x54, 0x15, 0x06
OUIS = sorted(monitor.FLOCK_OUIS)


def program(ouis=OUIS):
    """Kernel filter: every management frame, and data frames only when an address is one of the Flock prefixes.

    Data frames are most of what a busy monitor radio hears and the frame reader only looks at them for those
    prefixes, so the rest are dropped before they reach Python. A radiotap header of 256 bytes or more is passed on
    for the reader to judge."""
    head = [(LD_B_ABS, 3), (JEQ_K, 0, "go", "keep"), ("go",), (LD_B_ABS, 2), (TAX, 0), (LD_B_IND, 0), (AND_K, 0x0C),
            (JEQ_K, 0x00, "keep", "data?"), ("data?",), (JEQ_K, 0x08, "addr2", "drop"), ("addr2",)]
    for at in (10, 4):
        head.append((LD_W_IND, at))
        head.append((AND_K, 0xFFFFFF00))
        for oui in ouis:
            head.append((JEQ_K, oui << 8, "keep", None))
    head += [("drop",), (RET_K, 0), ("keep",), (RET_K, KEEP_BYTES)]
    labels, code = {}, []
    for item in head:
        if len(item) == 1:
            labels[item[0]] = len(code)
        else:
            code.append(item)
    out = []
    for i, item in enumerate(code):
        op, k = item[0], item[1]
        jt = jf = 0
        if op == JEQ_K:
            jt = labels[item[2]] - i - 1 if item[2] else 0
            jf = labels[item[3]] - i - 1 if item[3] else 0
            if not 0 <= jt <= 255 or not 0 <= jf <= 255:
                raise ValueError("filter jump too far")
        out.append((op, jt, jf, k & 0xFFFFFFFF))
    return out


def attach(sock, code=None):
    code = code or program()
    raw = b"".join(struct.pack("HBBI", *ins) for ins in code)
    buffer = ctypes.create_string_buffer(raw, len(raw))
    fprog = struct.pack("HL", len(code), ctypes.addressof(buffer))
    sock.setsockopt(socket.SOL_SOCKET, SO_ATTACH_FILTER, fprog)
    return buffer


def run(code, packet):
    a = x = 0
    pc = 0
    while True:
        op, jt, jf, k = code[pc]
        pc += 1
        try:
            if op == LD_B_ABS:
                a = packet[k]
            elif op == TAX:
                x = a
            elif op == LD_B_IND:
                a = packet[x + k]
            elif op == LD_W_IND:
                a = struct.unpack(">I", packet[x + k:x + k + 4])[0]
            elif op == AND_K:
                a &= k
            elif op == JEQ_K:
                pc += jt if a == k else jf
            elif op == RET_K:
                return k
        except (IndexError, struct.error):
            return 0


def present(interface=INTERFACE, net="/sys/class/net"):
    return os.path.isdir(os.path.join(net, interface))


def adapter(interface=INTERFACE):
    return {"interface": interface, "label": LABEL, "bands": ["2.4", "5", "6"], "usb_id": "", "driver": "mt7921u",
            "external": False, "type": "803", "pager": True}


def capture(outbox, interface, rssi_step, opener=None):
    try:
        os.nice(5)
    except OSError:
        pass
    try:
        sock = opener() if opener else socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
        if not opener:
            sock.bind((interface, 0))
            try:
                attach(sock)
            except (OSError, ValueError):
                pass
        sock.settimeout(0.2)
    except OSError as exc:
        outbox.send(("error", "Cannot read %s: %s" % (interface, exc)))
        return
    worker = monitor.Worker(interface, rssi_step)
    while True:
        try:
            raw = sock.recv(4096)
        except socket.timeout:
            raw = None
        except OSError as exc:
            outbox.send(("error", "%s stopped: %s" % (interface, exc)))
            return
        now = time.monotonic()
        try:
            if raw:
                for event in worker.feed(raw, now):
                    outbox.send(event)
            networks = worker.tick(now)
            if networks:
                outbox.send(("networks", networks))
            found = worker.stats(now)
            if found is not None:
                outbox.send(("stats", found))
        except (EOFError, BrokenPipeError):
            return


class PagerListen:
    """Stands where Deep scan stands in a wardrive or in Recon, with the Pager's monitor radio as its listener."""

    def __init__(self, cfg, interface=INTERFACE, process=None):
        self.cfg = cfg
        self.interface = interface
        self.process_factory = process
        self.state, self.detail, self.error = "off", "", ""
        self.monitor = None
        self.vif = interface
        self.sinks = {}
        self.stats = {}
        self.counts = {"flock": 0, "deauth": 0, "networks": 0}
        self.roles = {}
        self.tuning = {}
        self.listeners = {}
        self.paused, self.joining = set(), {}
        self.level, self.all_mode, self.cap, self.dropped, self.joined = 0, False, 1, 0, 0
        self._proc = self._outbox = None
        self._stop = threading.Event()
        self._thread = None

    def open(self):
        if not present(self.interface):
            self.state, self.detail = "unavailable", "%s is not there" % self.interface
            return False
        self.state = "ready"
        return True

    def plan_roles(self, adapters, nodes=()):
        self.roles = {"monitor": adapter(self.interface), "reasons": {}}
        return [a for a in adapters if a["interface"] != self.interface]

    def start(self, wifi_sink, frame_sink=None, deauth_sink=None, clash_sink=None):
        self.sinks = {"networks": wifi_sink, "frame": frame_sink, "deauth": deauth_sink, "clash": clash_sink}
        self.monitor = dict(adapter(self.interface), original=self.interface, role="monitor")
        self.listeners = {self.interface: {"adapter": adapter(self.interface), "original": self.interface}}
        self._stop.clear()
        if self.process_factory:
            self._proc, self._outbox = self.process_factory(self.interface, self.cfg.get("rssi_step", 4))
        else:
            context = multiprocessing.get_context("fork")
            self._outbox, writer = context.Pipe(duplex=False)
            self._proc = context.Process(target=capture, args=(writer, self.interface, self.cfg.get("rssi_step", 4)),
                                         daemon=True, name="pager-listen")
            self._proc.start()
            writer.close()
        self.state = "listening"
        self._thread = threading.Thread(target=self._dispatch, daemon=True, name="pager-listen-dispatch")
        self._thread.start()
        return True

    def _dispatch(self):
        while not self._stop.is_set():
            try:
                if not self._outbox.poll(0.5):
                    continue
                kind, payload = self._outbox.recv()
            except (EOFError, OSError, ValueError):
                if not self._stop.is_set():
                    self.error = "The Pager radio stopped sending frames."
                    self.state = "stopped"
                return
            try:
                self.handle(kind, payload)
            except Exception:
                faults.note("Pager radio")

    def handle(self, kind, payload):
        if kind == "error":
            self.error, self.state = payload, "stopped"
            return
        if kind == "stats":
            self.stats = payload
            return
        if kind == "frame":
            self.counts["flock"] += 1
        elif kind == "deauth":
            self.counts["deauth"] += 1
        elif kind == "networks":
            self.counts["networks"] += len(payload)
        sink = self.sinks.get(kind)
        if sink is None:
            return
        if kind == "networks":
            sink(payload, self.monitor)
        else:
            sink(payload)

    def managed(self, adapters):
        return [a for a in adapters if a["interface"] != self.interface and not a.get("pager")]

    def tune(self, adapters):
        pass

    def scanners(self, adapters):
        return adapters

    def follow(self, adapters, present_now=None, nodes=None, held=()):
        return self.managed(adapters)

    def watched(self):
        return []

    def moving(self):
        return set()

    def ease(self, name):
        return False

    def forget(self, name):
        pass

    def shed(self, why=""):
        return None

    def radio_status(self):
        return [{"interface": self.interface, "method": "monitor", "sweeps": 0, "sweep_seconds": None,
                 "error": self.error, "label": LABEL, "bands": ["2.4", "5", "6"],
                 "frames_per_s": self.stats.get("frames_per_s"), "flock": self.counts["flock"],
                 "original": self.interface, "channels": len(self.stats.get("channels", {}))}]

    def stop(self):
        self._stop.set()
        proc, self._proc = self._proc, None
        if proc is not None:
            try:
                proc.terminate()
                proc.join(2)
            except (OSError, AttributeError):
                pass
        if self._outbox is not None:
            try:
                self._outbox.close()
            except OSError:
                pass
        self.state = "off"
        self.listeners = {}

    def status(self):
        listeners = [{"interface": self.interface, "original": self.interface, "label": LABEL,
                      "bands": ["2.4", "5", "6"], "channels": len(self.stats.get("channels", {}))}] \
            if self.listeners else []
        return {"state": self.state, "detail": self.detail, "monitor": self.monitor, "vif": self.vif,
                "reasons": {}, "unavailable": "", "stats": dict(self.stats), "counts": dict(self.counts),
                "error": self.error, "tuning": {}, "plan": "pineap", "level": 0, "all": False,
                "listeners": listeners, "cap": 1, "paused": [], "joining": [], "dropped": 0, "joined": 0}
