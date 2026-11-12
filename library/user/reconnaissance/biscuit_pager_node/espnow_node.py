#!/usr/bin/env python3
# ESP-NOW node framing and raw monitor-mode radio; main() is the original bench spike.
import argparse, os, select, socket, struct, sys, time

OUI = bytes.fromhex("18fe34")
BCAST = b"\xff" * 6
ETH_P_ALL = 0x0003
TEXT_MAX = 200
MSG = dict(CORE_REQUEST=1, CORE_REPLY=2, HEARTBEAT=3, TEXT=4, ROLE_ASSIGN=5, OTA_COMMAND=6, FW_VERSION=7,
           STOP_SCAN=8, STOP_ACK=9, CONFIG_UPDATE=10, CONFIG_ACK=11, CONFIG_REQUEST=12, ROLE_ACK=15,
           ENCRYPT_CONFIG=16, IDENTIFY=17, WARDRIVE_BATCH=19, RELEASE=26)
NAME = {v: k for k, v in MSG.items()}
T0 = time.monotonic()


def log(*a):
    print(f"[{time.monotonic() - T0:8.3f}]", *a, flush=True)


def mac_str(b):
    return b.hex(":")


def text_msg(mtype, counter=0, text=b""):
    text = text[:TEXT_MAX]
    return struct.pack("<4sBIH", b"ENOW", mtype, counter, len(text)) + text.ljust(TEXT_MAX + 1, b"\0")


def ap_record(bssid, channel, rssi, auth, ssid):
    s = ssid.encode()[:32]
    return bytes([0x01]) + bssid + struct.pack("<BbBB", channel, rssi, auth, len(s)) + s


def batch_msg(seq, records):
    body = b"".join(records)
    return b"ENOW" + bytes([MSG["WARDRIVE_BATCH"], 2, seq & 0xFF, len(records)]) + body


class Radio:
    def __init__(self, iface, rate_500k):
        self.iface = iface
        self.mac = bytes.fromhex(open(f"/sys/class/net/{iface}/address").read().strip().replace(":", ""))
        self.on_mgmt = None
        self.sock = self._open()
        self.seq = 0
        # radiotap: rate (bit 2) + TX flags (bit 15); flags 0 keeps ACK/retry behaviour.
        self.rt = struct.pack("<BBHIBxH", 0, 0, 12, (1 << 2) | (1 << 15), rate_500k, 0)
        self.seen = {}
        self.stats = {"tx": 0, "tx_err": 0, "rx": 0, "dup": 0, "acks": 0}
        self.last_unicast_tx = 0.0

    passive = False
    no_rx = False

    def _open(self):
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
        s.bind((self.iface, 0))
        try:
            import array
            # Keep beacons (0x80), probe responses (0x50), action (0xd0) and ACK (0xd4) frames.
            prog = [(0x30, 0, 0, 3), (0x64, 0, 0, 8), (0x07, 0, 0, 0), (0x30, 0, 0, 2), (0x0C, 0, 0, 0),
                    (0x07, 0, 0, 0), (0x50, 0, 0, 0), (0x15, 3, 0, 0x80), (0x15, 2, 0, 0x50),
                    (0x15, 1, 0, 0xD0), (0x15, 0, 1, 0xD4), (0x06, 0, 0, 0xFFFF), (0x06, 0, 0, 0)]
            self._bpf = array.array("B", b"".join(struct.pack("<HBBI", *i) for i in prog))
            s.setsockopt(socket.SOL_SOCKET, 26, struct.pack("@HP", len(prog), self._bpf.buffer_info()[0]))
        except Exception as e:
            log("BPF filter not attached:", e)
        return s

    def send(self, dst, payload):
        assert 5 <= len(payload) <= 250
        if self.passive:
            return
        self.seq = (self.seq + 1) & 0xFFF
        hdr = struct.pack("<HH6s6s6sH", 0x00D0, 0, dst, self.mac, BCAST, self.seq << 4)
        body = b"\x7f" + OUI + os.urandom(4) + b"\xdd" + bytes([len(payload) + 5]) + OUI + b"\x04\x01" + payload
        try:
            self.sock.send(self.rt + hdr + body)
            self.stats["tx"] += 1
            if dst != BCAST:
                self.last_unicast_tx = time.monotonic()
        except OSError:
            self.stats["tx_err"] += 1

    def recv(self, timeout):
        if self.no_rx:
            time.sleep(timeout)
            return []
        r, _, _ = select.select([self.sock], [], [], timeout)
        out = []
        for _ in range(64 if r else 0):
            try:
                pkt = self.sock.recv(4096, socket.MSG_DONTWAIT)
            except BlockingIOError:
                break
            except OSError:
                self.stats["rx_err"] = self.stats.get("rx_err", 0) + 1
                time.sleep(0.5)
                self.sock.close()
                self.sock = self._open()
                break
            self.stats["raw"] = self.stats.get("raw", 0) + 1
            got = self._parse(pkt)
            if got:
                out.append(got)
        return out

    def _parse(self, pkt):
        if len(pkt) < 8:
            return None
        rlen = struct.unpack_from("<H", pkt, 2)[0]
        fr = pkt[rlen:]
        if self.on_mgmt and len(fr) >= 36 and fr[0] in (0x80, 0x50):
            self.on_mgmt(pkt, rlen)
            return None
        if len(fr) >= 10 and fr[0] == 0xD4 and fr[4:10] == self.mac:
            if time.monotonic() - self.last_unicast_tx < 0.05:
                self.stats["acks"] += 1
            return None
        if len(fr) < 24 + 15 or (fr[0] & 0xFC) != 0xD0:
            return None
        dst, src = fr[4:10], fr[10:16]
        if src == self.mac or dst not in (self.mac, BCAST):
            return None
        b = fr[24:]
        if b[0] != 0x7F or b[1:4] != OUI or b[8] != 0xDD or b[10:13] != OUI or b[13] != 4:
            return None
        payload = b[15 : 10 + b[9]]
        key = (src, struct.unpack_from("<H", fr, 22)[0] >> 4)
        now = time.monotonic()
        if now - self.seen.get(key, -9) < 2.0:
            self.stats["dup"] += 1
            return None
        self.seen[key] = now
        if len(self.seen) > 512:
            self.seen = {k: v for k, v in self.seen.items() if now - v < 2.0}
        self.stats["rx"] += 1
        return src, dst, payload


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default="wlan0mon")
    ap.add_argument("--fw", default="Pager:v0.0.1")
    ap.add_argument("--duration", type=float, default=120)
    ap.add_argument("--rate", type=int, default=2, help="radiotap rate in 500 kbps units (2 = 1 Mbps)")
    ap.add_argument("--test-ap", action="store_true", help="send a fake AP record while role=WiFi")
    ap.add_argument("--core", help="only accept a CORE_REPLY from this MAC")
    ap.add_argument("--passive", action="store_true", help="receive only, never transmit")
    ap.add_argument("--no-rx", action="store_true", help="transmit only, never read the socket")
    ap.add_argument("--req-interval", type=float, default=0.3)
    a = ap.parse_args()

    radio = Radio(a.iface, a.rate)
    radio.passive, radio.no_rx = a.passive, a.no_rx
    log(f"node MAC {mac_str(radio.mac)} on {a.iface}, fw={a.fw!r}")
    core = None
    role, token = 0, b"\0\0\0\0"
    hb = 0
    batch_seq = 0
    next_req = next_hb = next_cfgreq = next_ap = 0.0
    fw_tries, next_fw = 0, 0.0
    end = time.monotonic() + a.duration
    while time.monotonic() < end:
        now = time.monotonic()
        if core is None and now >= next_req:
            radio.send(BCAST, text_msg(MSG["CORE_REQUEST"], 0, b"bsc=1"))
            next_req = now + a.req_interval
        if core is not None:
            if fw_tries < 3 and now >= next_fw:
                radio.send(core, text_msg(MSG["FW_VERSION"], 0, a.fw.encode()))
                fw_tries += 1
                next_fw = now + 2.0
                log(f"TX FW_VERSION {a.fw!r} (try {fw_tries})")
            if now >= next_hb:
                radio.send(core, text_msg(MSG["HEARTBEAT"], hb))
                hb += 1
                next_hb = now + 3.0
            if now >= next_cfgreq:
                radio.send(core, text_msg(MSG["CONFIG_REQUEST"]))
                next_cfgreq = now + 30.0
            if a.test_ap and role == 1 and now >= next_ap:
                rec = ap_record(bytes.fromhex("021337506167"), 6, -55, 0x04, "PAGER-SPIKE-TEST")
                radio.send(core, batch_msg(batch_seq, [rec]))
                log(f"TX WARDRIVE_BATCH seq={batch_seq} records=1")
                batch_seq += 1
                next_ap = now + 5.0

        for src, dst, p in radio.recv(0.05):
            if p[:4] != b"ENOW" or len(p) < 11:
                log(f"RX non-ENOW from {mac_str(src)} len={len(p)}")
                continue
            t = p[4]
            counter, ln = struct.unpack_from("<IH", p, 5)
            txt = p[11 : 11 + min(ln, TEXT_MAX)]
            name = NAME.get(t, f"type{t}")
            if t == MSG["OTA_COMMAND"]:
                log(f"RX OTA_COMMAND from {mac_str(src)} (ignored; contents not logged)")
                continue
            if t != MSG["HEARTBEAT"]:
                log(f"RX {name} from {mac_str(src)} to {mac_str(dst)} counter={counter} len={ln} text={txt!r}")
            if t == MSG["CORE_REPLY"] and core is None:
                if b"wdbatch=" not in txt and b"nodecfg=" not in txt:
                    continue
                if a.core and mac_str(src) != a.core.lower():
                    continue
                if b"encrypt=1" in txt:
                    log("Core is in Secure (encrypted) mode; this spike only speaks Extended mode. Exiting.")
                    return 2
                core = src
                log(f"*** ADMITTED by Core {mac_str(core)}")
                next_fw = next_hb = next_cfgreq = time.monotonic()
            elif core is None or src != core:
                continue
            elif t == MSG["ROLE_ASSIGN"]:
                if ln == 5:
                    role, token = txt[0], txt[1:5]
                else:
                    role = txt[0] if ln > 0 else counter & 0xFF
                log(f"role={role} token={token.hex()} -> ROLE_ACK")
                radio.send(core, text_msg(MSG["ROLE_ACK"], role, token))
                next_ap = time.monotonic() + 1.0
            elif t == MSG["CONFIG_UPDATE"]:
                radio.send(core, text_msg(MSG["CONFIG_ACK"]))
            elif t == MSG["STOP_SCAN"]:
                role = 0
                radio.send(core, text_msg(MSG["STOP_ACK"]))
            elif t == MSG["RELEASE"]:
                log("released by Core; back to discovery")
                core, role, fw_tries = None, 0, 0
        if int(now) % 15 == 0 and now - getattr(main, "_last_stat", 0) > 1:
            main._last_stat = now
            log(f"stats {radio.stats} core={mac_str(core) if core else None} role={role} hb={hb}")
    log(f"done. stats {radio.stats} core={mac_str(core) if core else None} role={role}")
    return 0 if core else 1


if __name__ == "__main__":
    sys.exit(main())
