# PagerMesh - mesh <-> TAK bridge (Python standard library only)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Mesh -> TAK: every mesh node with a position becomes a TAK contact (CoT a-f-G-U-C,
#   uid "PagerMesh.!nodeid"), resent every 5 minutes and when it moves. Text on the
#   bridged mesh channel goes to TAK "All Chat Rooms" (GeoChat) under the sender's name.
# TAK -> mesh: GeoChat to "All Chat Rooms" goes out on the bridged mesh channel as
#   "[callsign] text" (at most one message every 5 s so the mesh is not flooded).
#   Direct messages are never bridged, in either direction.
#
# Links: tcp (plain, TAK Server 8087), tls (8089, client certificate; uses the
#   openssl command like PagerTAK, because python3-light has no ssl module), and
#   udp (send only, e.g. a TAK Server UDP input or a multicast group).

import os
import re
import socket
import subprocess
import threading
import time

ALL_ROOM = "All Chat Rooms"
UID_PREFIX = "PagerMesh."
RESEND = 300           # s between position reports of a node that did not move
STALE = 1200           # s a contact stays fresh in TAK without an update
TAK_TO_MESH_GAP = 5    # s between messages from TAK to the mesh


def esc(s):
    """XML text / attribute value (no xml module: python3-light ships without it)."""
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("'", "&apos;"))


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))


def unesc(s):
    return (s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
            .replace("&apos;", "'").replace("&amp;", "&"))


def cot_node(uid, callsign, lat, lon, remarks, t=None):
    t = t or time.time()
    return ('<event version="2.0" uid="%s" type="a-f-G-U-C" how="m-g" time="%s" start="%s" stale="%s">'
            '<point lat="%.7f" lon="%.7f" hae="9999999.0" ce="9999999.0" le="9999999.0"/>'
            '<detail><takv device="Meshtastic" platform="PagerMesh" os="Meshtastic" version="mesh"/>'
            '<contact callsign="%s"/><__group name="Cyan" role="Team Member"/>'
            '<remarks>%s</remarks></detail></event>') % (
        esc(uid), iso(t), iso(t), iso(t + STALE), lat, lon, esc(callsign), esc(remarks))


def cot_chat(sender_uid, sender_cs, text, lat=0.0, lon=0.0, t=None):
    t = t or time.time()
    mid = "%x%04x" % (int(t * 1000), os.getpid() & 0xFFFF) + os.urandom(3).hex()
    room = ALL_ROOM
    return ('<event version="2.0" uid="GeoChat.%s.%s.%s" type="b-t-f" how="h-g-i-g-o" time="%s" start="%s" stale="%s">'
            '<point lat="%.7f" lon="%.7f" hae="0" ce="9999999.0" le="9999999.0"/>'
            '<detail><__chat parent="RootContactGroup" groupOwner="false" messageId="%s" chatroom="%s" id="%s" senderCallsign="%s">'
            '<chatgrp uid0="%s" uid1="%s" id="%s"/></__chat>'
            '<link uid="%s" type="a-f-G-U-C" relation="p-p"/>'
            '<remarks source="BAO.F.ATAK.%s" to="%s" time="%s">%s</remarks></detail></event>') % (
        esc(sender_uid), esc(room), mid, iso(t), iso(t), iso(t + 86400), lat, lon,
        mid, esc(room), esc(room), esc(sender_cs), esc(sender_uid), esc(room), esc(room),
        esc(sender_uid), esc(sender_uid), esc(room), iso(t), esc(text))


RE_TYPE = re.compile(r'<event[^>]*\stype="([^"]*)"')
RE_UID0 = re.compile(r'<chatgrp[^>]*\suid0="([^"]*)"')
RE_LINK = re.compile(r'<link[^>]*\suid="([^"]*)"')
RE_ROOM = re.compile(r'<__chat[^>]*\schatroom="([^"]*)"')
RE_CS = re.compile(r'<__chat[^>]*\ssenderCallsign="([^"]*)"')
RE_REMARKS = re.compile(r"<remarks[^>]*>(.*?)</remarks>", re.S)


def parse_chat(ev):
    """GeoChat to All Chat Rooms -> (sender_uid, callsign, text), else None."""
    m = RE_TYPE.search(ev)
    if not m or m.group(1) != "b-t-f":
        return None
    room = RE_ROOM.search(ev)
    if room and unesc(room.group(1)) != ALL_ROOM:
        return None                                   # direct messages and other rooms stay in TAK
    uid = RE_UID0.search(ev) or RE_LINK.search(ev)
    uid = unesc(uid.group(1)) if uid else ""
    cs = RE_CS.search(ev)
    txt = RE_REMARKS.search(ev)
    if not txt:
        return None
    return uid, unesc(cs.group(1)) if cs else "TAK", unesc(txt.group(1)).strip()


def tls_error(err):
    """Short reason from openssl s_client's error output."""
    known = [("Connection refused", "connection refused - check the server address and port"),
             ("timed out", "no answer from the server"), ("No route", "server not reachable"),
             ("Name or service not known", "unknown host name"),
             ("certificate verify failed", "the server certificate does not match ca.pem"),
             ("unknown ca", "the server does not trust client.pem (wrong certificate?)"),
             ("bad certificate", "the server rejected client.pem"),
             ("certificate expired", "a certificate has expired"),
             ("no certificate", "the server wants a client certificate"),
             ("PEM", "client.pem could not be read (certificate and key, unencrypted PEM)")]
    for k, msg in known:
        if k.lower() in err.lower():
            return msg
    line = next((ln for ln in err.splitlines() if re.search("error|unable|fail|errno", ln, re.I)), "")
    return line.strip()[-90:] or "handshake failed"


class Link:
    """One connection to TAK. send(text) / recv() -> bytes ('' = closed) / close()."""

    def __init__(self, proto, host, port, cert_dir=""):
        self.proto, self.proc, self.sock, self.addr = proto, None, None, None
        hostb = host.encode("ascii", "ignore")       # no idna codec in python3-light
        if proto == "udp":
            ai = socket.getaddrinfo(hostb, int(port), socket.AF_INET, socket.SOCK_DGRAM)[0]
            self.addr = ai[4]
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            if self.addr[0].split(".")[0].isdigit() and 224 <= int(self.addr[0].split(".")[0]) <= 239:
                self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        elif proto == "tcp":
            self.sock = socket.create_connection((hostb, int(port)), 10)
            self.sock.settimeout(1.0)
        elif proto == "tls":
            cert = os.path.join(cert_dir, "client.pem")
            ca = os.path.join(cert_dir, "ca.pem")
            if not os.path.isfile(cert):
                raise OSError("no client.pem in %s" % cert_dir)
            args = ["openssl", "s_client", "-quiet", "-connect", "%s:%s" % (host, port), "-cert", cert, "-key", cert]
            if not re.match(r"^[0-9.]+$", host):
                args += ["-servername", host]
            if os.path.isfile(ca):
                args += ["-CAfile", ca, "-verify_return_error"]
            try:
                self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                             stderr=subprocess.PIPE, bufsize=0)
            except OSError:
                raise OSError("TLS needs the openssl command (opkg install openssl-util)")
            time.sleep(3)
            if self.proc.poll() is not None:
                err = self.proc.stderr.read().decode("utf-8", "replace")
                raise OSError("TLS: " + tls_error(err))
        else:
            raise OSError("unknown protocol %s" % proto)

    def send(self, text):
        data = text.encode("utf-8")
        if self.proto == "udp":
            self.sock.sendto(data, self.addr)
        elif self.proto == "tcp":
            self.sock.sendall(data + b"\n")
        else:
            self.proc.stdin.write(data + b"\n")
            self.proc.stdin.flush()

    def recv(self):
        """Bytes from TAK, None when nothing came in (1 s), b'' when closed."""
        if self.proto == "udp":
            time.sleep(1.0)
            return None
        if self.proto == "tcp":
            try:
                return self.sock.recv(65536)
            except socket.timeout:
                return None
        import select
        r, _, _ = select.select([self.proc.stdout], [], [], 1.0)
        if not r:
            return b"" if self.proc.poll() is not None else None
        return os.read(self.proc.stdout.fileno(), 65536)

    def close(self):
        try:
            if self.sock:
                self.sock.close()
            if self.proc:
                self.proc.kill()
                self.proc.wait(5)
        except (OSError, subprocess.TimeoutExpired):
            pass


class Bridge:
    """Runs in its own thread inside the mesh service."""

    def __init__(self, state, cfg, cert_dirs):
        self.s, self.cfg, self.cert_dirs = state, cfg, cert_dirs
        self.link = None
        self.status, self.error = "off", ""
        self.sent = self.recv_n = self.to_mesh = 0
        self.last_sent = {}                 # node num -> (time, lat, lon)
        self.outq = []                      # CoT strings
        self.meshq = []                     # (text) TAK -> mesh
        self.lock = threading.Lock()
        self.kick = threading.Event()
        self.stop = threading.Event()

    # ---- settings (from the PagerMesh config)
    def conf(self):
        c = self.cfg()
        try:
            port = int(c.get("tak_port") or 0)
        except ValueError:
            port = 0
        try:
            chan = int(c.get("tak_chan")) if str(c.get("tak_chan", "")).strip() != "" else -1
        except ValueError:
            chan = -1
        proto = c.get("tak_proto") or "tcp"
        return {"on": c.get("tak_on") == "1", "proto": proto, "host": (c.get("tak_host") or "").strip(),
                "port": port or {"tls": 8089, "tcp": 8087, "udp": 8087}.get(proto, 8087),
                "pos": c.get("tak_pos", "1") == "1", "chat": c.get("tak_chat", "1") == "1" and self.chan_private(chan), "chan": chan}

    def chan_private(self, idx):
        """TAK chat is only bridged to a channel with its own AES key. No key, the default key and the
        well-known "simple" keys can be read by anyone with Meshtastic (channel 0 is public on most meshes)."""
        ch = self.s.channels.get(idx) if idx >= 0 else None
        return bool(ch) and str(ch.get("psk_kind", "")).startswith("AES")

    def chat_note(self):
        c = self.cfg()
        if c.get("tak_chat", "1") != "1":
            return "chat off"
        try:
            idx = int(c.get("tak_chan")) if str(c.get("tak_chan", "")).strip() != "" else -1
        except ValueError:
            idx = -1
        if idx < 0:
            return "chat paused: pick a mesh channel with its own key"
        if not self.chan_private(idx):
            return "chat paused: %s is a public channel - pick one with its own key" % self.s.chan_label(idx)
        return "chat on %s" % self.s.chan_label(idx)

    def cert_dir(self):
        for d in self.cert_dirs:
            if d and os.path.isfile(os.path.join(d, "client.pem")):
                return d
        return self.cert_dirs[0] if self.cert_dirs else ""

    def info(self):
        c = self.conf()
        return {"status": self.status, "error": self.error, "sent": self.sent, "received": self.recv_n,
                "to_mesh": self.to_mesh, "proto": c["proto"], "port": c["port"], "on": c["on"], "chat": self.chat_note(),
                "cert": "PagerTAK certs" if "PagerTAK" in self.cert_dir() else "PagerMesh certs",
                "has_cert": os.path.isfile(os.path.join(self.cert_dir(), "client.pem"))}

    def restart(self):
        """Settings changed: drop the link, the loop reconnects with the new settings."""
        self.kick.set()

    # ---- hooks from the mesh service
    def on_chat(self, entry):
        """A chat line was added (in or out). Channel text on the bridged channel goes to TAK."""
        c = self.conf()
        if not (c["on"] and c["chat"]) or entry.get("direct") or entry.get("from_tak"):
            return
        if entry.get("channel", 0) != c["chan"]:
            return
        num = None
        try:
            num = int(entry["from_id"][1:], 16)
        except (KeyError, ValueError):
            pass
        uid = UID_PREFIX + entry.get("from_id", "mesh")
        name = entry.get("from") or entry.get("from_id", "mesh")
        lat = lon = 0.0
        n = self.s.nodes.get(num, {}).get("position", {}) if num is not None else {}
        if "lat" in n:
            lat, lon = n["lat"], n["lon"]
        with self.lock:
            self.outq.append(cot_chat(uid, name, entry["text"], lat, lon))

    def nodes_to_tak(self):
        if not self.conf()["pos"]:
            return
        t = time.time()
        rows = self.s.node_rows()
        for r in rows:
            if r["me"] or r["lat"] is None or (r["age_s"] is not None and r["age_s"] > 7200):
                continue
            last = self.last_sent.get(r["num"])
            if last and t - last[0] < RESEND and (last[1], last[2]) == (r["lat"], r["lon"]):
                continue
            name = r["long"] or r["short"] or r["id"]
            rm = ["Meshtastic %s" % r["id"]]
            if r["battery"] is not None:
                rm.append("battery %s%%" % r["battery"] if r["battery"] <= 100 else "external power")
            if r["snr"] is not None:
                rm.append("SNR %s dB" % r["snr"])
            if r["hops"] is not None:
                rm.append("%s hop%s" % (r["hops"], "" if r["hops"] == 1 else "s"))
            if r["age_s"] is not None:
                rm.append("heard %d min ago" % (r["age_s"] // 60))
            with self.lock:
                self.outq.append(cot_node(UID_PREFIX + r["id"], name, r["lat"], r["lon"],
                                          ", ".join(rm) + " - via PagerMesh", t))
            self.last_sent[r["num"]] = (t, r["lat"], r["lon"])

    # ---- the loop
    def run(self):
        delay = 5
        while not self.stop.is_set():
            c = self.conf()
            if not c["on"] or not c["host"]:
                self.status, self.error = ("off" if not c["on"] else "no server"), ""
                self.kick.wait(2)
                self.kick.clear()
                continue
            self.status = "connecting"
            try:
                self.link = Link(c["proto"], c["host"], c["port"], self.cert_dir())
            except Exception as e:  # noqa: BLE001 - any failure: report it and retry
                self.status, self.error = "disconnected", (str(e) or type(e).__name__)[:120]
                self.kick.wait(delay)
                self.kick.clear()
                delay = min(60, delay * 2)
                continue
            self.status, self.error, delay = "connected", "", 5
            self.last_sent.clear()
            self.kick.clear()
            try:
                self.session(c)
            except Exception as e:  # noqa: BLE001
                self.error = (str(e) or type(e).__name__)[:120]
            finally:
                self.link.close()
                self.link = None
            self.status = "disconnected"
            self.kick.wait(3)
            self.kick.clear()

    def session(self, c):
        buf = b""
        last_nodes = last_mesh = 0
        while not self.stop.is_set() and not self.kick.is_set():
            t = time.time()
            if t - last_nodes >= 15:
                self.nodes_to_tak()
                last_nodes = t
            with self.lock:
                q, self.outq = self.outq, []
            for ev in q:
                self.link.send(ev)
                self.sent += 1
            data = self.link.recv()
            if data == b"":
                raise OSError("TAK server closed the connection")
            if data:
                buf += data
                while b"</event>" in buf:
                    ev, buf = buf.split(b"</event>", 1)
                    j = ev.find(b"<event")
                    if j < 0:
                        continue
                    self.recv_n += 1
                    self.on_tak_event(ev[j:].decode("utf-8", "replace") + "</event>", c)
                if len(buf) > 200000:
                    buf = b""
            if self.meshq and t - last_mesh >= TAK_TO_MESH_GAP:
                txt = self.meshq.pop(0)
                ok, _m = self.s.send_text(txt, None, c["chan"], from_tak=True)
                if ok:
                    self.to_mesh += 1
                last_mesh = t

    def on_tak_event(self, ev, c):
        if not c["chat"]:
            return
        chat = parse_chat(ev)
        if not chat:
            return
        uid, cs, text = chat
        if uid.startswith(UID_PREFIX) or not text:
            return                                    # our own mesh messages coming back
        if len(self.meshq) < 20:
            self.meshq.append("[%s] %s" % (cs[:20], " ".join(text.split())))
