#!/usr/bin/env python3
# Pager wardrive node: scans 6 GHz on one radio and feeds a Biscuit over ESP-NOW.
import argparse, json, os, signal, struct, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from espnow_node import Radio, text_msg, batch_msg, MSG, NAME, log, mac_str
import beacon_meta

IW = next((p for p in (os.path.join(d, "iw") for d in
           os.environ.get("PATH", "").split(":") + ["/usr/sbin", "/sbin", "/usr/bin", "/bin"])
           if os.access(p, os.X_OK)), "iw")

FW = "Pager:v1.0.0"
HOME_FREQ = 2437
REC_AP6 = 0x04
AP6_CODES = {"[OPEN]": 0, "[WEP]": 1, "[WPA_PSK]": 2, "[WPA2_PSK]": 3, "[WPA3_PSK]": 4, "[WPA_WPA2_PSK]": 5,
               "[WPA2_ENTERPRISE]": 6, "[WPA3_ENTERPRISE]": 7, "[WAPI_PSK]": 8, "[WPA2_WPA3_PSK]": 9,
               "[UNDEFINED]": 0x0C, "[OWE]": 0x0D, "[WPA_ENTERPRISE]": 0x0E, "[WPA2_WPA3_ENTERPRISE]": 0x0F}
CH6_PSC = [5, 21, 37, 53, 69, 85, 101, 117, 133, 149, 165, 181, 197, 213, 229]
CH6_ALL = list(range(1, 234, 4))


def freq6(ch):
    return 5950 + 5 * ch


def valid_channel(ch):
    return 1 <= ch <= 233 and (ch - 1) % 4 == 0


def radiotap_info(pkt):
    rlen = struct.unpack_from("<H", pkt, 2)[0]
    off, words = 4, []
    while True:
        (p,) = struct.unpack_from("<I", pkt, off)
        words.append(p)
        off += 4
        if not p & 0x80000000:
            break
    flags, sig, mhz = 0, None, 0
    for bit, (align, size) in enumerate(((8, 8), (1, 1), (1, 1), (2, 4), (2, 2), (1, 1))):
        if not words[0] & (1 << bit):
            continue
        off = (off + align - 1) & ~(align - 1)
        if bit == 1:
            flags = pkt[off]
        elif bit == 3:
            mhz = struct.unpack_from("<H", pkt, off)[0]
        elif bit == 5:
            sig = struct.unpack_from("<b", pkt, off)[0]
        off += size
    return rlen, flags, sig, mhz


def channel_6ghz(mhz):
    return (mhz - 5950) // 5 if 5925 <= mhz <= 7125 else None


def he_6ghz_primary(frame):
    c = 36
    while c + 2 <= len(frame):
        eid, ln = frame[c], frame[c + 1]
        val = frame[c + 2:c + 2 + ln]
        if len(val) < ln:
            return None
        if eid == 255 and ln >= 7 and val[0] == 36:
            params = val[1] | (val[2] << 8) | (val[3] << 16)
            o = 7 + (3 if params & (1 << 14) else 0) + (1 if params & (1 << 15) else 0)
            if params & (1 << 17) and ln >= o + 5:
                return val[o]
            return None
        c += 2 + ln
    return None


class Scanner:
    def __init__(self, resend_s):
        self.resend_s = resend_s
        self.last_sent = {}
        self.pending = {}
        self.seen = set()

    def on_frame(self, pkt, _rlen):
        try:
            rlen, flags, sig, mhz = radiotap_info(pkt)
        except (struct.error, IndexError):
            return
        fr = pkt[rlen:-4] if flags & 0x10 else pkt[rlen:]
        if len(fr) < 36 or sig is None:
            return
        rx_ch = channel_6ghz(mhz)
        if rx_ch is None:
            return
        bssid = fr[16:22]
        auth, _ch, _src = beacon_meta.parse(fr, 0)
        ch = he_6ghz_primary(fr) or rx_ch
        ssid, status = beacon_meta.ssid_raw(fr)
        if status == 3 or not valid_channel(ch):
            return
        self.seen.add(bssid)
        now = time.monotonic()
        if now - self.last_sent.get(bssid, -1e9) < self.resend_s:
            return
        prev = self.pending.get(bssid)
        if prev is None or sig > prev[2]:
            self.pending[bssid] = (ch, ssid, sig, auth)

    def take(self):
        out, now = [], time.monotonic()
        for bssid, rec in self.pending.items():
            self.last_sent[bssid] = now
            out.append((bssid,) + rec)
        self.pending.clear()
        return out


def ap_rec(kind, bssid, ch, rssi, code, ssid):
    return bytes([kind]) + bssid + struct.pack("<BbBB", ch, max(-128, min(127, rssi)), code, len(ssid)) + ssid


class Node:
    def __init__(self, a):
        self.a = a
        self.radio = Radio(a.iface, 2)
        self.scan = Scanner(a.resend)
        self.radio.on_mgmt = self.scan.on_frame
        self.core = None
        self.ap6 = False
        self.role = 0
        self.token = b"\0\0\0\0"
        self.hb = 0
        self.batch_seq = 0
        self.fw_tries = 0
        self.out = []
        self.sent = 0
        self.held6 = set()
        self.frames = 0
        self.sweeps = 0
        self.started = time.time()
        self.stop = False
        self.next = {"req": 0.0, "fw": 0.0, "hb": 0.0, "stats": 0.0}
        self.cur_freq = None
        self.switch_ms = []

    def tune(self, f):
        if f == self.cur_freq:
            return True
        t = time.monotonic()
        r = subprocess.run([IW, "dev", self.a.iface, "set", "freq", str(f)], capture_output=True)
        self.switch_ms.append((time.monotonic() - t) * 1000)
        self.switch_ms = self.switch_ms[-50:]
        if r.returncode != 0:
            return False
        self.cur_freq = f
        return True

    def send(self, payload):
        self.radio.send(self.core, payload)
        self.frames += 1

    def handle(self, src, p):
        if p[:4] != b"ENOW" or len(p) < 11:
            return
        t = p[4]
        counter, ln = struct.unpack_from("<IH", p, 5)
        txt = p[11:11 + min(ln, 200)]
        if t == MSG["OTA_COMMAND"]:
            log("ignored OTA_COMMAND")
            return
        if t == MSG["CORE_REPLY"] and self.core is None:
            if b"wdbatch=" not in txt and b"nodecfg=" not in txt:
                return
            if b"encrypt=1" in txt:
                log("Biscuit is in Secure node mode; switch it to Extended")
                self.status = "secure"
                return
            self.core, self.ap6 = src, b"ap6=1" in txt
            if self.ap6:
                self.held6.clear()
            self.fw_tries, now = 0, time.monotonic()
            self.next.update(fw=now, hb=now)
            log(f"joined Biscuit {mac_str(src)} reply={txt!r}")
            return
        if self.core is None or src != self.core:
            return
        if t == MSG["ROLE_ASSIGN"]:
            if ln == 5:
                self.role, self.token = txt[0], txt[1:5]
            else:
                self.role = txt[0] if ln > 0 else counter & 0xFF
            self.send(text_msg(MSG["ROLE_ACK"], self.role, self.token if ln == 5 else b""))
            log(f"role {self.role}")
        elif t == MSG["CONFIG_UPDATE"]:
            self.send(text_msg(MSG["CONFIG_ACK"]))
        elif t == MSG["STOP_SCAN"]:
            self.role = 0
            self.out.clear()
            self.send(text_msg(MSG["STOP_ACK"]))
            log("stopped by Biscuit")
        elif t == MSG["RELEASE"]:
            log("released by Biscuit")
            self.core, self.role = None, 0

    def listen(self, seconds):
        end = time.monotonic() + seconds
        while not self.stop:
            left = end - time.monotonic()
            if left <= 0:
                break
            for src, _dst, p in self.radio.recv(min(left, 0.05)):
                self.handle(src, p)

    def queue_records(self):
        body = []
        for bssid, ch, ssid, rssi, auth in self.scan.take():
            if not self.ap6:
                self.held6.add(bssid)
                continue
            r = ap_rec(REC_AP6, bssid, ch, rssi, AP6_CODES.get(auth, 0x0C), ssid)
            if sum(map(len, body)) + len(r) > 242:
                self.out.append((len(body), batch_msg(self.batch_seq, body)))
                self.batch_seq += 1
                body = []
            body.append(r)
        if body:
            self.out.append((len(body), batch_msg(self.batch_seq, body)))
            self.batch_seq += 1

    def home(self, seconds):
        self.tune(HOME_FREQ)
        now = time.monotonic()
        if self.core is None:
            if now >= self.next["req"]:
                self.radio.send(b"\xff" * 6, text_msg(MSG["CORE_REQUEST"], 0, b"bsc=1"))
                self.next["req"] = now + 0.3
        else:
            if self.fw_tries < 3 and now >= self.next["fw"]:
                self.send(text_msg(MSG["FW_VERSION"], 0, FW.encode()))
                self.fw_tries += 1
                self.next["fw"] = now + 2.0
            if now >= self.next["hb"]:
                self.send(text_msg(MSG["HEARTBEAT"], self.hb))
                self.hb += 1
                self.next["hb"] = now + 3.0
            for _ in range(min(len(self.out), 12)):
                n, payload = self.out.pop(0)
                self.send(payload)
                self.sent += n
                time.sleep(0.008)
        self.listen(seconds)

    def sweep_plan(self):
        return CH6_ALL if self.sweeps % 4 == 3 else CH6_PSC

    def write_stats(self, final=False):
        st = {
            "final": final, "uptime_s": int(time.time() - self.started),
            "biscuit": mac_str(self.core) if self.core else None, "role": self.role, "ap6": self.ap6,
            "seen": len(self.scan.seen), "sent": self.sent,
            "held_6ghz": len(self.held6), "frames": self.frames, "acks": self.radio.stats["acks"],
            "queued": len(self.out), "sweeps": self.sweeps,
            "switch_ms": round(sum(self.switch_ms) / len(self.switch_ms), 1) if self.switch_ms else None,
        }
        tmp = self.a.stats + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, self.a.stats)

    def run(self):
        log(f"{FW} on {self.a.iface} {mac_str(self.radio.mac)} 6 GHz")
        end = time.monotonic() + self.a.duration if self.a.duration else float("inf")
        plan, idx = [], 0
        while not self.stop and time.monotonic() < end:
            if self.core is None or self.role != 1:
                self.home(0.25)
            else:
                slot_end = time.monotonic() + self.a.scan_slot
                while time.monotonic() < slot_end and not self.stop:
                    if idx >= len(plan):
                        plan, idx = self.sweep_plan(), 0
                        self.sweeps += 1
                    ch = plan[idx]
                    idx += 1
                    if self.tune(freq6(ch)):
                        self.listen(self.a.dwell / 1000)
                self.queue_records()
                self.home(self.a.home_slot)
            if time.monotonic() >= self.next["stats"]:
                self.write_stats()
                self.next["stats"] = time.monotonic() + 2.0
        self.write_stats(final=True)
        log("stopped", json.dumps({"sent": self.sent, "held6": len(self.held6), "frames": self.frames}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default="wlan1mon")
    ap.add_argument("--dwell", type=int, default=110, help="ms per channel")
    ap.add_argument("--scan-slot", type=float, default=0.9, help="seconds scanning between check-ins")
    ap.add_argument("--home-slot", type=float, default=0.15, help="seconds on channel 6 per check-in")
    ap.add_argument("--resend", type=float, default=5.0, help="seconds before re-sending a BSSID")
    ap.add_argument("--duration", type=float, default=0, help="0 = run until stopped")
    ap.add_argument("--stats", default="/tmp/biscuit_node_stats.json")
    a = ap.parse_args()
    node = Node(a)

    def stop(*_):
        node.stop = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    node.run()


if __name__ == "__main__":
    main()
