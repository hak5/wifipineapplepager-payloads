# PagerMesh - mesh SIGINT: what the radio hears, per packet and per node (standard library only)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Works at the mesh level, from what the radio passes to its app: every packet it
# decodes, and packets for channels it has no key for (shown as ENCRYPTED, with
# sender, size, RSSI and SNR). Raw LoRa capture needs radio firmware changes and is
# not part of PagerMesh.
#
# Export: pcap (LINKTYPE_USER0 = 147, one Meshtastic MeshPacket protobuf per record,
# for a Wireshark Meshtastic dissector or your own tools) and CSV.

import struct
import threading
import time

KEEP_PACKETS = 3000
TRAIL_POINTS = 200
TRAIL_AGE = 86400
LINKTYPE_USER0 = 147


class Sigint:
    def __init__(self, port_names, node_id):
        self.port_names, self.node_id = port_names, node_id
        self.lock = threading.Lock()
        self.packets = []                 # dicts, newest last
        self.nodes = {}                   # num -> stats
        self.ports = {}                   # name -> count
        self.minutes = {}                 # epoch minute -> count
        self.trails = {}                  # num -> [(t, lat, lon)]
        self.started = time.time()
        self.total = 0

    def add(self, p):
        """p: decoded MeshPacket (meshproto.dec_packet) with '_raw'."""
        t = time.time()
        d = p.get("decoded")
        if d:
            port = self.port_names.get(d["portnum"], str(d["portnum"]))
            size = len(d.get("payload", b""))
        elif "encrypted" in p:
            port, size = "ENCRYPTED", p["encrypted"]
        else:
            port, size = "EMPTY", 0
        hops = None
        if p.get("hop_start") and "hop_limit" in p:
            hops = max(0, p["hop_start"] - p["hop_limit"])
        rec = {"t": t, "from": p.get("from", 0), "to": p.get("to", 0), "ch": p.get("channel", 0),
               "id": p.get("id", 0), "port": port, "size": size, "rssi": p.get("rx_rssi"),
               "snr": p.get("rx_snr"), "hops": hops, "mqtt": bool(p.get("via_mqtt")),
               "pki": bool(p.get("pki")), "raw": p.get("_raw", b"")}
        m = int(t // 60)
        with self.lock:
            self.total += 1
            self.packets.append(rec)
            del self.packets[:-KEEP_PACKETS]
            self.ports[port] = self.ports.get(port, 0) + 1
            self.minutes[m] = self.minutes.get(m, 0) + 1
            for k in [k for k in self.minutes if k < m - 60]:
                del self.minutes[k]
            n = self.nodes.setdefault(rec["from"], {"packets": 0, "ports": {}, "first": t, "last": t,
                                                    "rssi_sum": 0, "rssi_n": 0, "snr_sum": 0.0, "snr_n": 0,
                                                    "rssi": None, "snr": None, "enc": 0, "mqtt": 0, "bytes": 0})
            n["packets"] += 1
            n["bytes"] += size
            n["last"] = t
            n["ports"][port] = n["ports"].get(port, 0) + 1
            if port == "ENCRYPTED":
                n["enc"] += 1
            if rec["mqtt"]:
                n["mqtt"] += 1
            if rec["rssi"] is not None and not rec["mqtt"]:
                n["rssi"] = rec["rssi"]
                n["rssi_sum"] += rec["rssi"]
                n["rssi_n"] += 1
            if rec["snr"] is not None and not rec["mqtt"]:
                n["snr"] = rec["snr"]
                n["snr_sum"] += rec["snr"]
                n["snr_n"] += 1
        return rec

    def add_point(self, num, lat, lon, t=None):
        t = t or time.time()
        with self.lock:
            tr = self.trails.setdefault(num, [])
            if tr and abs(tr[-1][1] - lat) < 1e-6 and abs(tr[-1][2] - lon) < 1e-6:
                return
            tr.append((int(t), lat, lon))
            cut = t - TRAIL_AGE
            while tr and (tr[0][0] < cut or len(tr) > TRAIL_POINTS):
                tr.pop(0)

    def line(self, r):
        """One packets.log line."""
        to = "ALL" if r["to"] == 0xFFFFFFFF else self.node_id(r["to"])
        extra = ""
        if r["rssi"] is not None:
            extra += " rssi=%d" % r["rssi"]
        if r["snr"] is not None:
            extra += " snr=%.1f" % r["snr"]
        if r["hops"] is not None:
            extra += " hops=%d" % r["hops"]
        if r["mqtt"]:
            extra += " mqtt"
        if r["pki"]:
            extra += " pki"
        return "%s from=%s to=%s ch=%s id=%08x %s %dB%s" % (
            time.strftime("%H:%M:%S", time.localtime(r["t"])), self.node_id(r["from"]), to, r["ch"], r["id"],
            r["port"], r["size"], extra)

    def stats(self, name_of):
        with self.lock:
            nodes = []
            for num, n in self.nodes.items():
                nodes.append({"id": self.node_id(num), "name": name_of(num), "packets": n["packets"],
                              "bytes": n["bytes"], "enc": n["enc"], "mqtt": n["mqtt"],
                              "rssi": n["rssi"], "snr": n["snr"],
                              "rssi_avg": round(n["rssi_sum"] / n["rssi_n"], 1) if n["rssi_n"] else None,
                              "snr_avg": round(n["snr_sum"] / n["snr_n"], 1) if n["snr_n"] else None,
                              "last": int(n["last"]),
                              "top": sorted(n["ports"].items(), key=lambda kv: -kv[1])[:3]})
            nodes.sort(key=lambda r: -r["packets"])
            now_m = int(time.time() // 60)
            per_min = [self.minutes.get(m, 0) for m in range(now_m - 59, now_m + 1)]
            return {"total": self.total, "since": int(self.started), "ports": sorted(self.ports.items(), key=lambda kv: -kv[1]),
                    "per_min": per_min, "nodes": nodes[:100]}

    def recent(self, n=200):
        with self.lock:
            rows = self.packets[-n:]
        return [{k: (v if k != "raw" else None) for k, v in r.items() if k != "raw"} for r in rows]

    def trail_list(self):
        with self.lock:
            return {self.node_id(num): [[a, b, c] for a, b, c in tr] for num, tr in self.trails.items() if len(tr) > 1}

    def pcap(self):
        out = bytearray(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, LINKTYPE_USER0))
        with self.lock:
            rows = list(self.packets)
        for r in rows:
            raw = r["raw"] or b""
            sec = int(r["t"])
            out += struct.pack("<IIII", sec, int((r["t"] - sec) * 1e6), len(raw), len(raw)) + raw
        return bytes(out)

    def csv(self):
        head = "time,from,to,channel,id,port,bytes,rssi,snr,hops,mqtt,pki\n"
        with self.lock:
            rows = list(self.packets)
        out = [head]
        for r in rows:
            out.append("%s,%s,%s,%s,%08x,%s,%d,%s,%s,%s,%d,%d\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(r["t"])), self.node_id(r["from"]),
                "ALL" if r["to"] == 0xFFFFFFFF else self.node_id(r["to"]), r["ch"], r["id"], r["port"], r["size"],
                "" if r["rssi"] is None else r["rssi"], "" if r["snr"] is None else r["snr"],
                "" if r["hops"] is None else r["hops"], r["mqtt"], r["pki"]))
        return "".join(out)
