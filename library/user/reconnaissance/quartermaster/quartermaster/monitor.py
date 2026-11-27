"""Deep scan's frame reader: radiotap and 802.11 frames from the monitor adapter in, networks and detections out.

It runs in a process of its own, so reading frames never holds up the screen or the managed scans. Beacons and
probe responses become network records shaped exactly like the ones `iw` scans give, so the wardrive logs them the
same way. Probe requests, data frames and disconnect frames only get quick byte checks here; the few that may be a
Flock camera go to the main process with their bytes for Recon's classifier.

The Flock rules follow flock-you by colonelpanichacks (MIT), with community research by @NitekryDPaul and
DeFlockJoplin. The disconnect flood counter is ported from SquachWatch-CYD (GPL-3.0).
"""

from collections import deque
import time

from .wifi import band_of, capabilities, channel_of, security_label

FLOCK_OUIS = frozenset((
    0x70c94e, 0x3c9180, 0xd8f3bc, 0x803049, 0xb83532, 0x145afc, 0x744ca1, 0x083a88, 0x9c2f9d, 0xc03532,
    0x940853, 0xe4aaea, 0xf46add, 0xe00af6, 0x24b2b9, 0x00f48d, 0xd03957, 0xe8d0fc, 0xe04f43, 0xb81ea4,
    0x700894, 0x588e81, 0xec1bbd, 0x5800e3, 0x9035ea, 0x5c93a2, 0x646e69, 0x14b5cd, 0xb41e52, 0x00037f,
    0x826bf2))
ESPRESSIF_LEFT_OUT = frozenset((0x3c71bf, 0x4827ea, 0xa4cf12))
RSSI_FLOOR = -95
FRAME_BYTES = 512
SNAP_LENGTHS = (24, 32, 2048)
PARSE_AGAIN, PARSE_AGAIN_SLOW = 2.0, 5.0
SLOW_PARSE = b"S"
FLUSH_SECONDS = 1.0
HOP_WINDOW, HOP_APART_MHZ = 3.0, 25
EVENT_GAP = 1.0
CLASH_WINDOW, CLASH_QUIET = 5.0, 30.0
DEAUTH_THRESHOLD, DEAUTH_BCAST, DEAUTH_BCAST_ALL = 12, 6, 24
DEAUTH_WINDOW, DEAUTH_COOLDOWN, DEAUTH_SENDERS = 3.0, 15.0, 4
BROADCAST = b"\xff" * 6
CIPHERS = {1: "WEP-40", 2: "TKIP", 4: "CCMP", 5: "WEP-104", 8: "GCMP", 9: "GCMP-256", 10: "CCMP-256"}
AKMS = {1: "IEEE 802.1X", 2: "PSK", 3: "FT/IEEE 802.1X", 4: "FT/PSK", 5: "IEEE 802.1X/SHA-256", 6: "PSK/SHA-256",
        8: "SAE", 9: "FT/SAE", 11: "IEEE 802.1X/SUITE-B", 12: "IEEE 802.1X/SUITE-B-192", 18: "OWE",
        24: "SAE-EXT-KEY"}
WPA_CIPHERS = {1: "WEP-40", 2: "TKIP", 4: "CCMP", 5: "WEP-104"}
WPA_AKMS = {1: "IEEE 802.1X", 2: "PSK"}
RSN_OUI, WPA_OUI = b"\x00\x0f\xac", b"\x00\x50\xf2"


def mac_text(raw):
    return ":".join("%02X" % b for b in raw)


def flock_oui(raw):
    return (raw[0] << 16 | raw[1] << 8 | raw[2]) in FLOCK_OUIS


def radiotap(buf):
    """(header length, frame end, dBm or None, MHz or None) of a radiotap frame, or None when it cannot be used."""
    n = len(buf)
    if n < 8 or buf[0] != 0:
        return None
    length = buf[2] | buf[3] << 8
    if length < 8 or length > n:
        return None
    first = present = int.from_bytes(buf[4:8], "little")
    at = 8
    while present & 0x80000000:
        if at + 4 > length:
            return None
        present = int.from_bytes(buf[at:at + 4], "little")
        at += 4
    flags, freq, rssi = 0, None, None
    for bit, size, align in ((0, 8, 8), (1, 1, 1), (2, 1, 1), (3, 4, 2), (4, 2, 1), (5, 1, 1)):
        if not first >> bit & 1:
            continue
        at = (at + align - 1) & ~(align - 1)
        if at + size > length:
            return None
        if bit == 1:
            flags = buf[at]
        elif bit == 3:
            freq = buf[at] | buf[at + 1] << 8
        elif bit == 5:
            value = buf[at]
            rssi = value - 256 if value > 127 else value
        at += size
    if flags & 0x40:
        return None
    end = n - 4 if flags & 0x10 and n - length not in SNAP_LENGTHS else n
    if end < length:
        return None
    return length, end, rssi, freq


def elements(body):
    """(id, bytes) of each element until the first one that does not fit."""
    at, n = 0, len(body)
    while at + 2 <= n:
        ie, size = body[at], body[at + 1]
        if at + 2 + size > n:
            return
        yield ie, body[at + 2:at + 2 + size]
        at += 2 + size


def _suite(raw, names, oui):
    if raw[:3] == oui and raw[3] in names:
        return names[raw[3]]
    return "%02x-%02x-%02x:%d" % (raw[0], raw[1], raw[2], raw[3])


def _security(body, ciphers, akms, oui):
    """{"pairwise", "auth"} of an RSN or WPA element body that starts at its version, or None when cut short."""
    if len(body) < 2:
        return None
    out = {"pairwise": [], "auth": []}
    at = 2
    if len(body) < at + 4:
        out["pairwise"], out["auth"] = ["CCMP"], ["PSK"]
        return out
    at += 4
    for field, names in (("pairwise", ciphers), ("auth", akms)):
        if len(body) < at + 2:
            return out
        count = body[at] | body[at + 1] << 8
        at += 2
        for _ in range(count):
            if len(body) < at + 4:
                return out
            out[field].append(_suite(body[at:at + 4], names, oui))
            at += 4
    return out


def frequency_of(band, channel):
    if not channel:
        return None
    if band == "2.4":
        return 2484 if channel == 14 else 2407 + 5 * channel
    if band == "5":
        return 5000 + 5 * channel
    if band == "6":
        return 5950 + 5 * channel
    return None


def _he_6ghz_primary(body):
    if len(body) < 7:
        return None
    params = body[1] | body[2] << 8 | body[3] << 16
    at = 7
    if params >> 14 & 1:
        at += 3
    if params >> 15 & 1:
        at += 1
    if params >> 17 & 1 and len(body) >= at + 5:
        return body[at]
    return None


def parse_beacon(frame, rssi, listen_freq, interface=""):
    """A beacon or probe response as the network record `wifi.parse_iw_scan` gives, or None."""
    if len(frame) < 36:
        return None
    caps = frame[34] | frame[35] << 8
    net = {"bssid": mac_text(frame[16:22]), "ssid": "", "rssi": float(rssi), "channel": None, "frequency": None,
           "privacy": bool(caps & 0x10), "ibss": bool(caps & 0x02), "wps": False, "wpa": None, "rsn": None,
           "last_seen_ms": 0, "hidden": True}
    ds = ht = he = None
    for ie, body in elements(frame[36:]):
        if ie == 0:
            raw = bytes(body[:32])
            ssid = raw.decode("utf-8", "replace") if raw.strip(b"\0") else ""
            net["ssid"], net["hidden"] = ssid[:32], ssid == ""
        elif ie == 3 and len(body) >= 1:
            ds = body[0]
        elif ie == 61 and len(body) >= 1:
            ht = body[0]
        elif ie == 48:
            net["rsn"] = _security(bytes(body), CIPHERS, AKMS, RSN_OUI)
        elif ie == 221 and len(body) >= 4:
            if body[:4] == b"\x00\x50\xf2\x01":
                net["wpa"] = _security(bytes(body[4:]), WPA_CIPHERS, WPA_AKMS, WPA_OUI)
            elif body[:4] == b"\x00\x50\xf2\x04":
                net["wps"] = True
        elif ie == 255 and len(body) >= 1 and body[0] == 36:
            he = _he_6ghz_primary(body)
    listen = band_of(listen_freq) if listen_freq else ""
    if listen == "6":
        band, channel = "6", he or channel_of(listen_freq)
    elif listen == "5":
        band, channel = "5", ht or ds or channel_of(listen_freq)
    elif listen == "2.4":
        band, channel = "2.4", ds or ht or channel_of(listen_freq)
    else:
        return None
    if band == "2.4" and not 1 <= (channel or 0) <= 14:
        channel = channel_of(listen_freq)
    net["frequency"] = frequency_of(band, channel)
    net["channel"] = channel_of(net["frequency"])
    if net["channel"] is None:
        return None
    net["band"] = band_of(net["frequency"])
    net["capabilities"] = capabilities(net)
    net["security"] = security_label(net)
    net["interface"] = interface
    return net


def wildcard_probe(frame):
    """True when a probe request carries an empty SSID element, False for a named one, None without one."""
    for ie, body in elements(frame[24:]):
        if ie == 0:
            return len(body) == 0
    return None


class DeauthCounter:
    """SquachWatch's disconnect flood rule: 12 frames in 3 s from one sender, 6 of them to everyone, or 24 to
    everyone from any senders. Four senders are tracked and one still counting is never pushed out."""

    def __init__(self):
        self.senders = [None] * DEAUTH_SENDERS
        self.all_start, self.all_bcast = None, 0
        self.last_fire = None

    def feed(self, sender, bcast, now):
        if self.all_start is None or now - self.all_start > DEAUTH_WINDOW:
            self.all_start, self.all_bcast = now, 0
        if bcast:
            self.all_bcast += 1
        slot = next((s for s in self.senders if s is not None and s["mac"] == sender), None)
        if slot is None:
            free = [i for i, s in enumerate(self.senders) if s is None or now - s["start"] > DEAUTH_WINDOW]
            if free:
                index = min(free, key=lambda i: -1 if self.senders[i] is None else self.senders[i]["start"])
                slot = self.senders[index] = {"mac": sender, "start": now, "count": 0, "bcast": 0}
        if slot is not None and now - slot["start"] > DEAUTH_WINDOW:
            slot.update(start=now, count=0, bcast=0)
        if slot is not None:
            slot["count"] += 1
            if bcast:
                slot["bcast"] += 1
        one = slot is not None and (slot["count"] >= DEAUTH_THRESHOLD or slot["bcast"] >= DEAUTH_BCAST)
        anyone = self.all_bcast >= DEAUTH_BCAST_ALL
        if not (one or anyone):
            return None
        if self.last_fire is not None and now - self.last_fire <= DEAUTH_COOLDOWN:
            return None
        self.last_fire = now
        if one:
            return {"sender": sender, "count": slot["count"], "bcast": slot["bcast"], "any": False}
        return {"sender": sender, "count": self.all_bcast, "bcast": self.all_bcast, "any": True}


def _apart(a, b):
    """Two listen frequencies that one sender cannot reach by bleeding into the neighbouring channels."""
    if (a < 3000) != (b < 3000):
        return True
    return abs(a - b) >= HOP_APART_MHZ if a < 3000 else a != b


class Worker:
    """Turns relayed frames into network batches and events. `feed` and `tick` return what to hand on."""

    def __init__(self, interface="qmmon0", rssi_step=4, clock=time.monotonic):
        self.interface, self.rssi_step, self.clock = interface, rssi_step, clock
        self.parse_again = PARSE_AGAIN
        self.parsed = {}
        self.pending = {}
        self.flushed_at = None
        self.probes = {}
        self.sent = {}
        self.beacons = {}
        self.clashed = {}
        self.deauth = DeauthCounter()
        self.frames = self.dropped = self.received = 0
        self.rate_frames, self.rate_at = 0, None
        self.channel_frames = {}
        self.gaps = deque(maxlen=64)
        self._switched = deque(maxlen=8)
        self.cpu_at, self.cpu_used = None, 0.0

    def feed_batch(self, received, dropped, freq, switched, frames, now=None):
        now = self.clock() if now is None else now
        self.received, self.dropped = received, dropped
        if switched and switched not in self._switched:
            if self._switched and frames:
                self.gaps.append(max(0.0, now - switched))
            self._switched.append(switched)
        out = []
        for raw in frames:
            out.extend(self.feed(raw, now, freq))
        return out

    def feed(self, raw, now, listen_freq=0):
        """One radiotap frame. Returns events: ("frame", dict), ("deauth", dict) or ("clash", dict)."""
        if self.flushed_at is None:
            self.flushed_at = now
        head = radiotap(raw)
        if head is None:
            return []
        length, end, rssi, freq = head
        frame = raw[length:end]
        if len(frame) < 24 or frame[0] & 3:
            return []
        freq = freq or listen_freq
        self.frames += 1
        if freq:
            self.channel_frames[freq] = self.channel_frames.get(freq, 0) + 1
        fc = frame[0]
        kind = (fc >> 2) & 3
        addr1, addr2, addr3 = frame[4:10], frame[10:16], frame[16:22]
        if kind == 0 and fc in (0x80, 0x50):
            out = list(self._beacon(frame, rssi, freq, now))
            if fc == 0x50 and rssi is not None and rssi >= RSSI_FLOOR and not addr1[0] & 1 and flock_oui(addr1):
                out.extend(self._event("addr1", addr1, rssi, freq, frame, now))
            return out
        if kind == 0 and fc in (0xc0, 0xa0):
            return list(self._deauth(frame, rssi, freq, now))
        if kind not in (0, 2) or rssi is None or rssi < RSSI_FLOOR:
            return []
        out = []
        if flock_oui(addr2):
            if kind == 0 and fc == 0x40:
                wildcard = wildcard_probe(frame)
                if wildcard:
                    out.extend(self._event("probe", addr2, rssi, freq, frame, now, self._hopping(addr2, freq, now)))
                else:
                    out.extend(self._event("addr2", addr2, rssi, freq, frame, now))
            else:
                out.extend(self._event("addr2", addr2, rssi, freq, frame, now))
        if not addr1[0] & 1 and flock_oui(addr1):
            out.extend(self._event("addr1", addr1, rssi, freq, frame, now))
        if kind == 0 and flock_oui(addr3) and addr3 != addr2 and addr3 != addr1:
            out.extend(self._event("addr3", addr3, rssi, freq, frame, now))
        return out

    def _hopping(self, addr, freq, now):
        seen = self.probes.setdefault(bytes(addr), deque(maxlen=32))
        seen.append((now, freq or 0))
        while seen and now - seen[0][0] > HOP_WINDOW:
            seen.popleft()
        if len(self.probes) > 512:
            for key in [k for k, v in self.probes.items() if not v or now - v[-1][0] > HOP_WINDOW][:256]:
                del self.probes[key]
        return bool(freq) and any(_apart(freq, other) for _, other in seen if other)

    def _event(self, rule, addr, rssi, freq, frame, now, hopping=False):
        key = (bytes(addr), rule, hopping)
        last = self.sent.get(key)
        if last is not None and now - last < EVENT_GAP:
            return ()
        self.sent[key] = now
        if len(self.sent) > 2048:
            self.sent = {k: v for k, v in self.sent.items() if now - v < EVENT_GAP}
        return (("frame", {"rule": rule, "address": mac_text(addr), "rssi": rssi, "channel": channel_of(freq),
                           "frequency": freq, "frame": bytes(frame[:FRAME_BYTES]), "hopping": hopping}),)

    def _deauth(self, frame, rssi, freq, now):
        sender = bytes(frame[10:16])
        fired = self.deauth.feed(sender, bytes(frame[4:10]) == BROADCAST, now)
        if fired is None:
            return ()
        fired.update(sender=mac_text(sender), rssi=rssi, channel=channel_of(freq))
        return (("deauth", fired),)

    def _beacon(self, frame, rssi, freq, now):
        if rssi is None:
            return ()
        key = bytes(frame[16:22])
        cached = self.parsed.get(key)
        if cached is None or now - cached[0] >= self.parse_again or abs(rssi - cached[1]) >= self.rssi_step:
            net = parse_beacon(frame, rssi, freq, self.interface)
            if net is None:
                return ()
            self.parsed[key] = (now, rssi, net)
            if len(self.parsed) > 8192:
                self.parsed = {k: v for k, v in self.parsed.items() if now - v[0] < self.parse_again}
            out = self._clash(key, net, now)
        else:
            net, out = cached[2], ()
        held = self.pending.get(key)
        if held is None or rssi > held["rssi"]:
            self.pending[key] = dict(net, rssi=float(rssi))
        return out

    def _clash(self, key, net, now):
        """The same access point beaconing on two channels at once, or open and protected: evidence for a twin."""
        last = self.beacons.get(key)
        self.beacons[key] = (now, net["channel"], net["privacy"])
        if len(self.beacons) > 4096:
            self.beacons = {k: v for k, v in self.beacons.items() if now - v[0] < CLASH_WINDOW}
        if last is None or now - last[0] > CLASH_WINDOW:
            return ()
        if last[1] == net["channel"] and last[2] == net["privacy"]:
            return ()
        if now - self.clashed.get(key, -CLASH_QUIET) < CLASH_QUIET:
            return ()
        self.clashed[key] = now
        what = "on channels %s and %s" % (last[1], net["channel"]) if last[1] != net["channel"] else \
            "both open and protected"
        return (("clash", {"bssid": net["bssid"], "ssid": net["ssid"],
                           "evidence": "Same access point %s %s within %d s" % (net["bssid"], what, CLASH_WINDOW)}),)

    def tick(self, now=None):
        """The networks heard since the last call, once a second, strongest sighting of each."""
        now = self.clock() if now is None else now
        if self.flushed_at is None:
            self.flushed_at = now
        if now - self.flushed_at < FLUSH_SECONDS:
            return None
        self.flushed_at = now
        networks, self.pending = list(self.pending.values()), {}
        return networks

    def stats(self, now=None, cpu=None):
        now = self.clock() if now is None else now
        cpu = time.process_time() if cpu is None else cpu
        if self.rate_at is None:
            self.rate_at, self.rate_frames, self.cpu_at, self.cpu_used = now, self.frames, now, cpu
            return None
        if now - self.rate_at < 10.0:
            return None
        span = now - self.rate_at
        gaps = sorted(self.gaps)
        found = {"frames_per_s": round((self.frames - self.rate_frames) / span, 1),
                 "received": self.received, "dropped": self.dropped,
                 "dropped_share": round(100.0 * self.dropped / self.received, 2) if self.received else 0.0,
                 "cpu": round(100.0 * (cpu - self.cpu_used) / span, 1),
                 "parse_us": round(1e6 * (cpu - self.cpu_used) / (self.frames - self.rate_frames), 1)
                 if self.frames > self.rate_frames else None,
                 "switch_gap_ms": round(1000 * gaps[len(gaps) // 2]) if gaps else None,
                 "channels": {f: round(n / span, 2) for f, n in self.channel_frames.items()}}
        self.rate_at, self.rate_frames, self.cpu_used = now, self.frames, cpu
        self.channel_frames = {}
        return found


def run(inbox, outbox, interface, rssi_step):
    """The worker process: relayed batches in, ("networks" | "frame" | "deauth" | "clash" | "stats", ...) out."""
    import os
    from .radio_helper import split_batch
    try:
        os.nice(5)
    except OSError:
        pass
    worker = Worker(interface, rssi_step)
    while True:
        try:
            if inbox.poll(0.2):
                body = inbox.recv_bytes()
                if body == b"":
                    break
                if body == SLOW_PARSE:
                    worker.parse_again = PARSE_AGAIN_SLOW
                    continue
                batch = split_batch(body)
                if batch is not None:
                    for event in worker.feed_batch(*batch):
                        outbox.send(event)
            networks = worker.tick()
            if networks:
                outbox.send(("networks", networks))
            found = worker.stats()
            if found is not None:
                outbox.send(("stats", found))
        except (EOFError, OSError):
            break
