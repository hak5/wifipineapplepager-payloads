"""Biscuit node mode: the Pager scans 6 GHz and nothing else, and hands every network it hears to a Biscuit or
Biscuit Pro over ESP-NOW.

The Biscuit is the manager. It talks to its nodes on 2.4 GHz channel 6 and logs what they send with its own GPS,
so the Pager only goes back to channel 6 to talk to it and never reports a network heard there.

It works exactly like CodeHedge's Biscuit Pager Node payload (by GSHD and Hedge,
https://github.com/hak5/wifipineapplepager-payloads/pull/396), the reference for every Quartermaster node mode. There
is no pairing on the Pager: it asks for a Biscuit on channel 6 until one answers, and the Biscuit Manager app's node
search finds it and adds it, as a Pager (firmware `Pager:v1.1.0`). It then sends only what that payload sends, with
the same timings.
"""

import multiprocessing
import os
import select
import socket
import struct
import subprocess
import threading
import time

from quartermaster import faults, monitor

INTERFACE = "wlan1mon"
FIRMWARE = b"Pager:v1.1.0"
HOME_MHZ = 2437
ESPRESSIF = b"\x18\xfe\x34"
BROADCAST = b"\xff" * 6
ETH_P_ALL = 0x0003
TEXT_MAX = 200

CORE_REQUEST, CORE_REPLY, HEARTBEAT, TEXT, ROLE_ASSIGN, OTA_COMMAND, FW_VERSION = 1, 2, 3, 4, 5, 6, 7
STOP_SCAN, STOP_ACK, CONFIG_UPDATE, CONFIG_ACK, CONFIG_REQUEST, ROLE_ACK = 8, 9, 10, 11, 12, 15
WARDRIVE_BATCH, RELEASE = 19, 26
SCAN_ROLE = 1
AP6_RECORD = 0x04
BATCH_ROOM = 242
SEND_PER_VISIT = 12

PSC = tuple(range(5, 230, 16))
EVERY = tuple(range(1, 234, 4))
DWELL, SCAN_SLOT, HOME_SLOT = 0.11, 0.9, 0.15
REQUEST_GAP, HEARTBEAT_GAP, FIRMWARE_GAP, FIRMWARE_AGAIN = 0.3, 3.0, 2.0, 30.0
RESEND_SECONDS = 5.0
LOST_SECONDS = 20.0
ACK_WINDOW = 0.05
STATUS_GAP = 1.0

OFF, STARTING, SEARCHING, JOINED, SCANNING, SECURE, OLD, STOPPING, FAILED = (
    "off", "starting", "searching", "joined", "scanning", "secure", "old", "stopping", "failed")

RADIOTAP = struct.pack("<BBHIBxH", 0, 0, 12, 1 << 2 | 1 << 15, 2, 0)

SO_ATTACH_FILTER = 26
FILTER = (
    (0x30, 0, 0, 3), (0x64, 0, 0, 8), (0x07, 0, 0, 0), (0x30, 0, 0, 2), (0x0C, 0, 0, 0), (0x07, 0, 0, 0),
    (0x50, 0, 0, 0), (0x15, 3, 0, 0x80), (0x15, 2, 0, 0x50), (0x15, 1, 0, 0xD0), (0x15, 0, 1, 0xD4),
    (0x06, 0, 0, 4096), (0x06, 0, 0, 0),
)

UCI_HOLD = (("uci", "set", "pineapd.%s.hop=0" % INTERFACE), ("uci", "set", "pineapd.%s.channel=6" % INTERFACE))
UCI_RELEASE = (("uci", "-q", "revert", "pineapd.%s.hop" % INTERFACE),
               ("uci", "-q", "revert", "pineapd.%s.channel" % INTERFACE))
PINEAPD = "/etc/init.d/pineapd"
MARKER = "/tmp/quartermaster-biscuit-radio"


def message(kind, counter=0, text=b""):
    text = bytes(text)[:TEXT_MAX]
    return struct.pack("<4sBIH", b"ENOW", kind, counter & 0xFFFFFFFF, len(text)) + text.ljust(TEXT_MAX + 1, b"\0")


def read_message(payload):
    """(kind, counter, text) of a Biscuit message, or None."""
    if len(payload) < 11 or payload[:4] != b"ENOW":
        return None
    counter, size = struct.unpack_from("<IH", payload, 5)
    return payload[4], counter, bytes(payload[11:11 + min(size, TEXT_MAX)])


def record(bssid, channel, rssi, code, ssid):
    ssid = bytes(ssid)[:32]
    rssi = max(-128, min(127, int(round(rssi))))
    return bytes([AP6_RECORD]) + bytes(bssid) + struct.pack("<BbBB", channel, rssi, code, len(ssid)) + ssid


def batch(seq, records):
    return b"ENOW" + bytes((WARDRIVE_BATCH, 2, seq & 0xFF, len(records))) + b"".join(records)


def batches(seq, records):
    """Records packed into as few batches as fit, as (next seq, [(payload, bssids)])."""
    out, body, ids, used = [], [], [], 0
    for bssid, raw in records:
        if body and used + len(raw) > BATCH_ROOM:
            out.append((batch(seq, body), ids))
            seq, body, ids, used = seq + 1, [], [], 0
        body.append(raw)
        ids.append(bssid)
        used += len(raw)
    if body:
        out.append((batch(seq, body), ids))
        seq += 1
    return seq & 0xFF, out


def action_frame(dst, src, seq, payload, nonce=None):
    if not 5 <= len(payload) <= 250:
        raise ValueError("ESP-NOW payloads are 5 to 250 bytes")
    nonce = os.urandom(4) if nonce is None else nonce
    header = struct.pack("<HH6s6s6sH", 0x00D0, 0, dst, src, BROADCAST, (seq & 0xFFF) << 4)
    body = b"\x7f" + ESPRESSIF + nonce + b"\xdd" + bytes([len(payload) + 5]) + ESPRESSIF + b"\x04\x01" + payload
    return header + body


def read_action(frame):
    """(destination, source, sequence, payload) of an ESP-NOW frame, or None."""
    if len(frame) < 39 or frame[0] & 0xFC != 0xD0:
        return None
    body = frame[24:]
    if body[0] != 0x7F or body[1:4] != ESPRESSIF or body[8] != 0xDD or body[10:13] != ESPRESSIF or body[13] != 4:
        return None
    end = 10 + body[9]
    if end > len(body) or body[9] < 5:
        return None
    return bytes(frame[4:10]), bytes(frame[10:16]), struct.unpack_from("<H", frame, 22)[0] >> 4, bytes(body[15:end])


def mac_text(raw):
    return ":".join("%02X" % b for b in raw)


def auth_code(net):
    """The Biscuit's security code for a network that `monitor.parse_beacon` read."""
    rsn, wpa = net.get("rsn"), net.get("wpa")
    if rsn:
        akms = [a.upper() for a in rsn.get("auth") or []]
        if any("OWE" in a for a in akms):
            return 0x0D
        sae = any("SAE" in a for a in akms)
        psk = any("PSK" in a for a in akms)
        if any("SUITE-B" in a for a in akms):
            return 0x07
        if any("802.1X" in a for a in akms):
            return 0x0F if sae else 0x06
        if sae:
            return 0x09 if psk else 0x04
        return 0x05 if wpa else 0x03
    if wpa:
        return 0x0E if any("802.1X" in a.upper() for a in wpa.get("auth") or []) else 0x02
    return 0x01 if net.get("privacy") else 0x00


def raw_ssid(frame):
    for ie, body in monitor.elements(frame[36:]):
        if ie == 0:
            raw = bytes(body[:32])
            return raw if raw.strip(b"\0") else b""
    return b""


class Sightings:
    """6 GHz networks waiting to go to the Biscuit: the strongest sighting of each, sent again no sooner than 5 s
    after the last send, as CodeHedge's node does."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.pending = {}
        self.sent = {}
        self.heard = set()

    def add(self, bssid, channel, rssi, code, ssid):
        self.heard.add(bssid)
        now = self.clock()
        last = self.sent.get(bssid)
        if last is not None and now - last[0] < RESEND_SECONDS:
            return
        held = self.pending.get(bssid)
        if held is None or rssi > held[1]:
            self.pending[bssid] = (channel, rssi, code, ssid)

    def take(self):
        now = self.clock()
        out = []
        for bssid, (channel, rssi, code, ssid) in self.pending.items():
            out.append((bssid, record(bssid, channel, rssi, code, ssid)))
            self.sent[bssid] = (now, rssi)
        self.pending.clear()
        if len(self.sent) > 4096:
            self.sent = {k: v for k, v in self.sent.items() if now - v[0] < RESEND_SECONDS}
        return out


class Radio:
    """The monitor radio as the node uses it: frames in and out, and one frequency at a time."""

    def __init__(self, interface=INTERFACE, runner=subprocess.run):
        self.interface = interface
        self.runner = runner
        with open("/sys/class/net/%s/address" % interface) as f:
            self.mac = bytes.fromhex(f.read().strip().replace(":", ""))
        self.sock = self.open()
        self.freq = None
        self.seq = 0

    def open(self):
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
        sock.bind((self.interface, 0))
        try:
            import ctypes
            raw = b"".join(struct.pack("HBBI", *ins) for ins in FILTER)
            self._filter = ctypes.create_string_buffer(raw, len(raw))
            sock.setsockopt(socket.SOL_SOCKET, SO_ATTACH_FILTER,
                            struct.pack("HL", len(FILTER), ctypes.addressof(self._filter)))
        except (OSError, ImportError):
            pass
        return sock

    def tune(self, mhz):
        if mhz == self.freq:
            return True
        done = self.runner(["iw", "dev", self.interface, "set", "freq", str(mhz)], capture_output=True, timeout=5)
        if done.returncode != 0:
            return False
        self.freq = mhz
        return True

    def send(self, dst, payload):
        self.seq = (self.seq + 1) & 0xFFF
        try:
            self.sock.send(RADIOTAP + action_frame(dst, self.mac, self.seq, payload))
            return True
        except OSError:
            return False

    def recv(self, timeout):
        ready, _, _ = select.select([self.sock], [], [], max(0.0, timeout))
        out = []
        for _ in range(64 if ready else 0):
            try:
                out.append(self.sock.recv(4096, socket.MSG_DONTWAIT))
            except BlockingIOError:
                break
            except OSError:
                time.sleep(0.2)
                try:
                    self.sock.close()
                    self.sock = self.open()
                except OSError:
                    pass
                break
        return out

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Node:
    """One run of node mode: ask for a Biscuit until one takes the Pager, then scan 6 GHz for it while it asks."""

    def __init__(self, radio, report, clock=time.monotonic):
        self.radio, self.report = radio, report
        self.clock = clock
        self.sightings = Sightings(clock)
        self.stopped = False
        self.core = None
        self.ap6 = False
        self.role = 0
        self.state = SEARCHING
        self.hb = 0
        self.seq = 0
        self.outbox = []
        self.sent = 0
        self.sent_ids = set()
        self.tx_errors = 0
        self.acks = 0
        self.last_unicast = -1e9
        self.last_heard = None
        self.last_ack = None
        self.firmware_tries = 0
        self.sweeps = 0
        self.plan, self.at = [], 0
        self.channel = None
        self.next = {"request": 0.0, "firmware": 0.0, "heartbeat": 0.0, "status": 0.0}
        self.tune_failures = 0
        self.seen = {}

    def send(self, dst, payload):
        if self.radio.send(dst, payload):
            if dst != BROADCAST:
                self.last_unicast = self.clock()
            return True
        self.tx_errors += 1
        return False

    def frame(self, raw):
        got = monitor.radiotap(raw)
        if got is None:
            return
        length, end, rssi, freq = got
        fr = raw[length:end]
        if len(fr) >= 10 and fr[0] == 0xD4:
            if fr[4:10] == self.radio.mac and self.clock() - self.last_unicast < ACK_WINDOW:
                self.acks += 1
            return
        if fr[:1] in (b"\x80", b"\x50"):
            if self.state == SCANNING and freq and 5925 <= freq <= 7125 and rssi is not None:
                self.network(fr, rssi, freq)
            return
        action = read_action(fr)
        if action is None:
            return
        dst, src, seq, payload = action
        if src == self.radio.mac or dst not in (self.radio.mac, BROADCAST):
            return
        now = self.clock()
        if now - self.seen.get((src, seq), -9.0) < 2.0:
            return
        self.seen[(src, seq)] = now
        if len(self.seen) > 512:
            self.seen = {k: v for k, v in self.seen.items() if now - v < 2.0}
        got = read_message(payload)
        if got is not None:
            self.handle(src, *got)

    def network(self, fr, rssi, freq):
        net = monitor.parse_beacon(fr, rssi, freq)
        if net is None or net.get("band") != "6" or not net.get("channel"):
            return
        channel = net["channel"]
        if not 1 <= channel <= 233 or (channel - 1) % 4:
            return
        self.sightings.add(bytes(fr[16:22]), channel, rssi, auth_code(net), raw_ssid(fr))

    def handle(self, src, kind, counter, text):
        now = self.clock()
        if kind == CORE_REPLY:
            # The Biscuit that answers takes the Pager, as with CodeHedge's node: adding it is done on the Biscuit.
            if b"wdbatch=" not in text and b"nodecfg=" not in text:
                return
            if self.core is not None:
                if src == self.core:
                    self.firmware_tries, self.next["firmware"] = 0, now
                return
            if b"encrypt=1" in text:
                self.state = SECURE
                return
            self.core, self.ap6, self.role = src, b"ap6=1" in text, 0
            self.state = JOINED if self.ap6 else OLD
            self.last_heard, self.last_ack = now, None
            self.firmware_tries = 0
            self.next.update(firmware=now, heartbeat=now)
            return
        if self.core is None or src != self.core:
            return
        self.last_heard = now
        if kind == ROLE_ASSIGN:
            if len(text) == 5:
                self.role, token = text[0], text[1:5]
            else:
                self.role, token = (text[0] if text else counter & 0xFF), b""
            self.send(self.core, message(ROLE_ACK, self.role, token))
            self.firmware_tries, self.next["firmware"] = 0, now
            if self.ap6:
                self.state = SCANNING if self.role == SCAN_ROLE else JOINED
        elif kind == CONFIG_UPDATE:
            self.send(self.core, message(CONFIG_ACK))
        elif kind == STOP_SCAN:
            self.role = 0
            self.outbox.clear()
            self.sightings.pending.clear()
            if self.ap6:
                self.state = JOINED
            self.send(self.core, message(STOP_ACK))
        elif kind == RELEASE:
            self.lost()

    def lost(self):
        self.core, self.role, self.ap6, self.last_ack = None, 0, False, None
        self.outbox.clear()
        self.state = SEARCHING

    def listen(self, seconds):
        end = self.clock() + seconds
        while not self.stopped:
            left = end - self.clock()
            if left <= 0:
                return
            for raw in self.radio.recv(min(left, 0.05)):
                try:
                    self.frame(raw)
                except (IndexError, struct.error, ValueError):
                    pass

    def home(self, seconds):
        if not self.radio.tune(HOME_MHZ):
            self.tune_failures += 1
        self.channel = None
        now = self.clock()
        if self.core is not None and self.last_ack is not None and now - self.last_ack > LOST_SECONDS:
            self.lost()
        if self.core is None:
            if now >= self.next["request"]:
                self.send(BROADCAST, message(CORE_REQUEST, 0, b"bsc=1"))
                self.next["request"] = now + REQUEST_GAP
        else:
            self.check_in(now)
        acks = self.acks
        self.listen(seconds)
        if self.acks > acks:
            self.last_ack = self.clock()

    def check_in(self, now):
        if now >= self.next["firmware"]:
            self.send(self.core, message(FW_VERSION, 0, FIRMWARE))
            self.firmware_tries += 1
            self.next["firmware"] = now + (FIRMWARE_GAP if self.firmware_tries < 3 else FIRMWARE_AGAIN)
        if now >= self.next["heartbeat"]:
            self.send(self.core, message(HEARTBEAT, self.hb))
            self.hb += 1
            self.next["heartbeat"] = now + HEARTBEAT_GAP
        for _ in range(min(len(self.outbox), SEND_PER_VISIT)):
            payload, ids = self.outbox[0]
            if not self.send(self.core, payload):
                break
            self.outbox.pop(0)
            self.sent += len(ids)
            self.sent_ids.update(ids)
            time.sleep(0.008)

    def scan(self):
        end = self.clock() + SCAN_SLOT
        while not self.stopped and self.state == SCANNING and self.clock() < end:
            if self.at >= len(self.plan):
                self.sweeps += 1
                self.plan, self.at = (EVERY if self.sweeps % 4 == 0 else PSC), 0
            channel = self.plan[self.at]
            self.at += 1
            if self.radio.tune(5950 + 5 * channel):
                self.channel = channel
                self.listen(DWELL)
            else:
                self.tune_failures += 1
        self.seq, packed = batches(self.seq, self.sightings.take())
        self.outbox.extend(packed)
        del self.outbox[:-200]

    def status(self, final=False):
        return {"state": self.state, "biscuit": mac_text(self.core) if self.core else None, "ap6": self.ap6,
                "role": self.role, "heard": len(self.sightings.heard), "sent": len(self.sent_ids),
                "updates": self.sent, "queued": sum(len(ids) for _, ids in self.outbox), "acks": self.acks,
                "tx_errors": self.tx_errors, "channel": self.channel, "sweeps": self.sweeps,
                "heard_ago": round(self.clock() - self.last_heard, 1) if self.last_heard is not None else None,
                "tune_failures": self.tune_failures, "final": final}

    def run(self):
        while not self.stopped:
            if self.state == SCANNING:
                self.scan()
                self.home(HOME_SLOT)
            else:
                self.home(0.25)
            if self.clock() >= self.next["status"]:
                self.report(("status", self.status()))
                self.next["status"] = self.clock() + STATUS_GAP
        self.report(("status", self.status(final=True)))


def node_process(outbox, interface):
    import signal
    try:
        os.nice(-5)
    except OSError:
        pass
    try:
        radio = Radio(interface)
    except OSError as exc:
        outbox.send(("error", "Cannot use %s: %s" % (interface, exc)))
        return

    def report(item):
        try:
            outbox.send(item)
        except (BrokenPipeError, EOFError, OSError):
            node.stopped = True
    node = Node(radio, report)

    def stop(*_):
        node.stopped = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        node.run()
    finally:
        radio.close()


def run_quiet(command, runner=subprocess.run, timeout=20):
    try:
        return runner(list(command), capture_output=True, timeout=timeout).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def hold_radio(runner=subprocess.run, marker=MARKER, settle=3.0):
    """Stop PineAP hopping wlan1mon so that node mode alone chooses its channel."""
    with open(marker, "w") as f:
        f.write("%d\n" % os.getpid())
    ok = all(run_quiet(command, runner) for command in UCI_HOLD)
    ok = run_quiet((PINEAPD, "restart"), runner, timeout=30) and ok
    time.sleep(settle)
    return ok


def release_radio(runner=subprocess.run, marker=MARKER):
    """Hand wlan1mon back to PineAP as it was."""
    for command in UCI_RELEASE:
        run_quiet(command, runner)
    run_quiet((PINEAPD, "restart"), runner, timeout=30)
    try:
        os.unlink(marker)
    except OSError:
        pass


class BiscuitLink:
    """Node mode as the screens see it: start, stop, and what the node process last said.

    One thread owns each run from holding the radio to handing it back, so a stop never races a start."""

    def __init__(self, interface=INTERFACE, process=None, hold=hold_radio, release=release_radio, present=None):
        self.interface = interface
        self.process_factory = process
        self.hold, self.release = hold, release
        self.present = present or (lambda: os.path.isdir("/sys/class/net/%s" % interface))
        self.state, self.error = OFF, ""
        self.live = {}
        self.started = None
        self._proc = self._pipe = self._thread = None
        self._lock = threading.Lock()
        self._wanted = False

    @property
    def running(self):
        return self.state not in (OFF, FAILED)

    def start(self):
        with self._lock:
            if self.running:
                return False
            if not self.present():
                self.state, self.error = FAILED, "%s is not up. Turn on PineAP, then try again." % self.interface
                return False
            self.state, self.error = STARTING, ""
            self.live, self.started = {}, time.monotonic()
            self._wanted = True
            self._thread = threading.Thread(target=self._run, daemon=True, name="biscuit-node")
            self._thread.start()
        return True

    def _run(self):
        held = False
        try:
            held = True
            self.hold()
            if self._wanted:
                self._spawn()
                if self._wanted:
                    self.state = SEARCHING
                self._read()
        except Exception as exc:
            faults.note("Biscuit node")
            self.error = str(exc) or "Node mode stopped."
        finally:
            self._kill()
            if held:
                try:
                    self.release()
                except Exception:
                    faults.note("Biscuit node radio")
            with self._lock:
                failed = self._wanted
                if failed and not self.error:
                    self.error = "Node mode stopped by itself."
                self.state = FAILED if failed else OFF
                self._wanted = False

    def _spawn(self):
        if self.process_factory:
            self._proc, self._pipe = self.process_factory(self.interface)
            return
        context = multiprocessing.get_context("fork")
        self._pipe, writer = context.Pipe(duplex=False)
        self._proc = context.Process(target=node_process, args=(writer, self.interface), daemon=True,
                                     name="biscuit-node")
        self._proc.start()
        writer.close()

    def _read(self):
        while self._wanted:
            try:
                if not self._pipe.poll(0.5):
                    continue
                kind, payload = self._pipe.recv()
            except (EOFError, OSError, ValueError):
                return
            if kind == "error":
                self.error = payload
            elif kind == "status":
                self.live = payload
                if self._wanted:
                    self.state = payload["state"]

    def _kill(self):
        proc, self._proc = self._proc, None
        if proc is not None:
            try:
                proc.terminate()
                proc.join(3)
                if proc.is_alive():
                    proc.kill()
                    proc.join(1)
            except (OSError, AttributeError, ValueError):
                pass
        pipe, self._pipe = self._pipe, None
        if pipe is not None:
            try:
                pipe.close()
            except OSError:
                pass

    def stop(self, wait=False):
        with self._lock:
            thread = self._thread
            if self.running and self.state != STOPPING:
                self._wanted = False
                self.state = STOPPING
                proc = self._proc
                if proc is not None:
                    try:
                        proc.terminate()
                    except (OSError, AttributeError, ValueError):
                        pass
        if wait and thread is not None and thread is not threading.current_thread():
            thread.join(45)

    def status(self):
        return dict(self.live, state=self.state, error=self.error,
                    seconds=int(time.monotonic() - self.started) if self.started and self.running else 0)
