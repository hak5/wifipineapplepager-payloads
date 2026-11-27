#!/usr/bin/env python3
"""PagerMesh web console.

Runs inside the PagerMesh mesh service (mesh/pagermesh.py) as background
threads, so it reads the live mesh state directly and sends through the same
connection. Written for python3-light on OpenWrt: standard library only, no
http.server (a separate package there).

  GET  /                    the console (static/index.html)
  GET  /api/state?v=N       status, nodes, channels, chat (204 when unchanged)
  GET  /tiles/<src>/z/x/y.png   basemap tiles (cached in tiles/)
  POST /api/login           {"password"}
  POST /api/logout
  POST /api/chat            {"text", "to": "all"|"!nodeid", "channel": n}
  POST /api/position        send the Pager GPS position now
  POST /api/read            {"conv"}  mark a conversation read ("" = all)
  POST /api/delete          {"what": "msg"|"conv"|"all", "id"}  delete chat (memory + loot logs)
  GET  /api/setup           current connection + USB radio list
  POST /api/setup/test      {"conn", "host", "port", "dev"} -> connection test
  POST /api/setup/save      same fields -> handed to payload.sh (RUN/setup_req), which saves and restarts
  GET  /api/radio           radio settings, owner, channels (no secrets, no channel keys)
  POST /api/radio           {"changes": {key: value}} or {"owner": {"long", "short"}} or {"reboot": true}
  POST /api/channel         {"index", "name", "psk": keep|random|default|none, "role", "uplink", "downlink", "precision"}
  POST /api/radio/share     channel share link + QR (SVG); it carries the channel keys, so only on request
  GET  /api/node?id=!x      node details, traceroute result
  POST /api/node            {"id", "action": trace|reqpos|fav|unfav}
  POST /api/waypoint        {"lat", "lon", "name", "desc", "hours"} or {"delete": id}
  POST /api/cfg             PagerMesh settings (manual position, hide old nodes, DM alert, TAK bridge)
  GET  /api/sigint          traffic stats, recent packets, trails, preset scan
  POST /api/scan            {"dwell", "presets": [n...]} or {"stop": true}
  GET  /api/export/pcap|csv packet capture download

Security (same model as PagerTAK's console)
  - Password login (salted PBKDF2-SHA256, or iterated SHA-256 when the Python
    build has no OpenSSL); session cookie HttpOnly + SameSite=Strict.
  - Failed logins lock the client out (60 s, doubling, max 15 min).
  - Every POST needs the X-PagerMesh header, which a cross-site page cannot send.
  - Listens only on the addresses it is given (the Pager's USB / management
    address by default).
"""
import binascii
import hashlib
import hmac
import json
import os
import re
import socket
import socketserver
import sys
import threading
import time

MAX_HEADER = 16 * 1024
MAX_BODY = 16 * 1024
SESSION_TTL = 12 * 3600
COOKIE = "pmesh"

STATE = None
ARGS = None
PM = None                     # map helpers (map/pagermesh_map.py) for basemap tiles
PROBE = None                  # connection test, set by the mesh service
SWITCH = None                 # use a new radio connection now, set by the mesh service
SERVICE = None                # the mesh service (preset scan)
TEST_LOCK = threading.Lock()
SESSIONS = {}
FAILS = {}
LOCK = threading.Lock()
FETCH_SEM = threading.Semaphore(3)

MIME = {
    ".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8", ".png": "image/png", ".svg": "image/svg+xml",
    ".json": "application/json", ".ico": "image/x-icon",
}

# --------------------------------------------------------------------------
# passwords
# --------------------------------------------------------------------------

def hash_password(pw, salt=None, method=None, iters=None):
    salt = salt or binascii.hexlify(os.urandom(16)).decode()
    pwb = pw.encode("utf-8")
    if method is None:
        # PBKDF2 only when it is OpenSSL's C version; the pure-Python fallback is
        # far too slow on the Pager's MIPS CPU.
        f = getattr(hashlib, "pbkdf2_hmac", None)
        method = "pbkdf2" if f is not None and type(f).__name__ == "builtin_function_or_method" else "sha256i"
    if method == "pbkdf2":
        iters = iters or 20000
        h = hashlib.pbkdf2_hmac("sha256", pwb, salt.encode(), iters).hex()
    else:
        iters = iters or 5000
        d = hashlib.sha256(salt.encode() + pwb).digest()
        for _ in range(iters):
            d = hashlib.sha256(d + pwb).digest()
        h = d.hex()
    return "%s$%d$%s$%s" % (method, iters, salt, h)


def check_password(pw, line):
    try:
        method, iters, salt, want = line.strip().split("$")
        got = hash_password(pw, salt, method, int(iters)).split("$")[3]
    except (ValueError, IndexError):
        return False
    return hmac.compare_digest(got, want)


def first_line(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.readline().rstrip("\n")
    except OSError:
        return ""

# --------------------------------------------------------------------------
# state for the browser
# --------------------------------------------------------------------------

def gps_info():
    f = first_line(os.path.join(ARGS.run, "gps")).split()
    if len(f) >= 9 and f[0] == "1":
        try:
            return {"fix": True, "lat": float(f[1]), "lon": float(f[2]), "sats": f[7]}
        except ValueError:
            pass
    return {"fix": False, "sats": f[7] if len(f) >= 8 else "-"}


def state_json():
    s = STATE
    import meshproto as mp
    with s.lock:
        per = {}
        chat = []
        for c in reversed(s.chat):                  # the last 100 messages of every conversation
            k = per.get(c["conv"], 0)
            if k < 100:
                per[c["conv"]] = k + 1
                chat.append(dict(c))
        chat.reverse()
        me = s.me().get("user", {})
        channels = [{"index": c["index"], "name": s.chan_label(c["index"]),
                     "private": str(c.get("psk_kind", "")).startswith("AES")}
                    for c in sorted(s.channels.values(), key=lambda c: c["index"])]
        out = {
            "version": s.version,
            "link": s.link, "error": s.error,
            "me": {"id": mp.node_id(s.my_num) if s.my_num else "", "long": me.get("long_name", ""),
                   "short": me.get("short_name", "")},
            "region": mp.REGIONS.get(s.region, "") if s.region is not None else "",
            "unread": s.unread, "last_pos": s.last_pos,
            "channels": channels or [{"index": 0, "name": "Primary"}],
        }
    out["nodes"] = s.node_rows()
    out["chat"] = chat
    out["convs"] = s.conversations()
    out["cfg"] = dict(s.cfg)
    out["waypoints"] = s.live_waypoints()
    out["notes"] = [{"t": t, "msg": m} for t, m in s.notes[-5:]]
    out["bridge"] = s.bridge.info() if s.bridge else {"status": "off"}
    sc = SERVICE.scan if SERVICE else {}
    out["scan"] = {"running": bool(sc.get("running")), "now": sc.get("now", ""), "done": len(sc.get("results", [])),
                   "total": len(sc.get("presets", []))}
    out["manual"] = s.manual() is not None and not s.gps_is_fix()
    out["gps"] = gps_info()
    out["pos_interval"] = first_line(os.path.join(ARGS.run, "pos_interval")) or str(ARGS.pos_interval)
    out["quick"] = [q for q in (ARGS.quick or "").split("|") if q]
    out["product"] = "PagerMesh"
    out["setup"] = bool(ARGS.setup)
    out["conn"] = {"mod": "Glytch Mesh Mod", "wifi": "Wi-Fi radio %s:%d" % (ARGS.host, ARGS.port),
                   "usb": "USB radio %s" % ARGS.dev}.get(ARGS.conn, ARGS.conn)
    return out


def setup_info():
    import meshproto as mp
    ports = []
    for dev in mp.serial_ports():
        label = dev
        try:
            real = os.path.realpath(dev)
            for link in os.listdir("/dev/serial/by-id"):
                if os.path.realpath(os.path.join("/dev/serial/by-id", link)) == real:
                    label = "%s (%s)" % (dev, link[:48])
        except OSError:
            pass
        if ARGS.gps_dev and os.path.realpath(dev) == os.path.realpath(ARGS.gps_dev):
            label += " - GPS"
        ports.append({"dev": dev, "label": label, "gps": "GPS" in label})
    return {"conn": "" if ARGS.setup else ARGS.conn, "host": ARGS.host if ARGS.conn == "wifi" else "", "port": ARGS.port,
            "dev": ARGS.dev, "ports": ports, "setup": bool(ARGS.setup)}


def setup_fields(b):
    conn = str(b.get("conn", ""))
    if conn not in ("mod", "wifi", "usb"):
        return None, "choose a connection type"
    host, dev = str(b.get("host", "")).strip(), str(b.get("dev", "")).strip()
    try:
        port = int(b.get("port") or 4403)
    except (TypeError, ValueError):
        return None, "bad port"
    if conn == "wifi":
        if not re.match(r"^[A-Za-z0-9.\-]{1,253}$", host):
            return None, "enter the radio's IP address or host name"
        if not 0 < port < 65536:
            return None, "bad port"
    elif conn == "usb":
        import meshproto as mp
        if dev not in mp.serial_ports():
            return None, "choose a USB radio"
    else:
        host, port, dev = "127.0.0.1", 4403, ""
    return {"conn": conn, "host": host, "port": port, "dev": dev}, ""


def STATE_PRESETS():
    import meshproto as mp
    return {k: mp.PRESETS[k] for k in mp.COMMON_PRESETS}


def check_cfg(v):
    """Reason the PagerMesh settings are not valid, or ''."""
    if "manual_pos" in v and v["manual_pos"]:
        try:
            a, b = (float(x) for x in v["manual_pos"].split(","))
            if not (-90 <= a <= 90 and -180 <= b <= 180):
                raise ValueError
        except ValueError:
            return "bad position"
        v["manual_pos"] = "%.6f,%.6f" % (a, b)
    for k in ("hide_age", "tak_port", "tak_chan", "pos_chan"):
        if k in v and v[k] and not v[k].isdigit():
            return "%s: enter a number" % k
    if v.get("tak_proto", "tcp") not in ("tcp", "tls", "udp"):
        return "protocol: tcp, tls or udp"
    if "tak_host" in v and v["tak_host"] and not re.match(r"^[A-Za-z0-9.\-]{1,253}$", v["tak_host"]):
        return "TAK server: an IP address or host name"
    if v.get("dm_alert", "sound") not in ("off", "sound", "popup"):
        return "DM alert: off, sound or popup"
    for k in ("tak_on", "tak_pos", "tak_chat"):
        if k in v and v[k] not in ("0", "1", "True", "False", "true", "false"):
            return "%s: on or off" % k
        if k in v:
            v[k] = "1" if v[k] in ("1", "True", "true") else "0"
    return ""


def node_info(nid):
    num = STATE.node_num(nid)
    rows = [r for r in STATE.node_rows() if r["num"] == num]
    if num is None or not rows:
        return 404, {"error": "node not found"}
    r = rows[0]
    st = STATE.sig.nodes.get(num, {})
    tr = STATE.traces.get(num, {})
    return 200, {"node": r, "trace": STATE.trace_text(num), "trace_done": bool(tr.get("done")),
                 "packets": st.get("packets", 0), "rssi": st.get("rssi"),
                 "rssi_avg": round(st["rssi_sum"] / st["rssi_n"], 1) if st.get("rssi_n") else None,
                 "trail": STATE.sig.trail_list().get(r["id"], [])}


def qr_svg(text):
    """QR code as an SVG (qrcodegen, MIT, ships in map/)."""
    try:
        import qrcodegen
    except ImportError:
        return ""
    q = qrcodegen.QrCode.encode_text(text, qrcodegen.QrCode.Ecc.MEDIUM)
    n, b = q.get_size(), 2
    parts = []
    for y in range(n):
        for x in range(n):
            if q.get_module(x, y):
                parts.append("M%d,%dh1v1h-1z" % (x + b, y + b))
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges">'
            '<rect width="100%%" height="100%%" fill="#fff"/><path d="%s" fill="#000"/></svg>') % (n + 2 * b, n + 2 * b, "".join(parts))


def sources():
    if PM is None:
        return []
    srcs = PM.load_sources(os.path.join(ARGS.map_dir, "sources"))
    return [{"name": x["name"], "slug": x["slug"], "minz": x["minz"], "maxz": x["maxz"]} for x in srcs]


def tile(slug, z, x, y):
    if PM is None:
        return None
    path = os.path.join(ARGS.tiles, slug, str(z), str(x), "%d.png" % y)
    if not os.path.isfile(path):
        src = next((s for s in PM.load_sources(os.path.join(ARGS.map_dir, "sources")) if s["slug"] == slug), None)
        if src is None or "example.com" in src["url"]:
            return None
        with FETCH_SEM:
            if not os.path.isfile(path) and not PM.fetch_tile(src, path, z, x, y):
                return None
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None

# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

def unquote(s):
    s = s.replace("+", " ")
    out, i = bytearray(), 0
    b = s.encode("utf-8", "replace")
    while i < len(b):
        if b[i:i + 1] == b"%" and i + 2 < len(b) and re.match(rb"[0-9A-Fa-f]{2}", b[i + 1:i + 3]):
            out.append(int(b[i + 1:i + 3], 16))
            i += 3
        else:
            out.append(b[i])
            i += 1
    return out.decode("utf-8", "replace")


class Req:
    def __init__(self, method, path, query, headers, body, ip, version):
        self.method, self.path, self.query, self.headers = method, path, query, headers
        self.body, self.ip, self.version = body, ip, version

    def cookie(self, name):
        for part in self.headers.get("cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == name:
                return v
        return ""

    def json(self):
        try:
            v = json.loads(self.body.decode("utf-8") or "{}")
            return v if isinstance(v, dict) else {}
        except (ValueError, UnicodeDecodeError):
            return {}


class Handler(socketserver.BaseRequestHandler):
    def setup(self):
        self.request.settimeout(20)
        self.buf = b""
        self.keep = False

    def read_request(self):
        buf = self.buf
        while b"\r\n\r\n" not in buf:
            chunk = self.request.recv(8192)
            if not chunk:
                return None
            buf += chunk
            if len(buf) > MAX_HEADER:
                return "too_big"
        head, _, rest = buf.partition(b"\r\n\r\n")
        lines = head.decode("iso-8859-1").split("\r\n")
        try:
            method, target, version = lines[0].split(" ", 2)
        except ValueError:
            return None
        headers = {}
        for line in lines[1:]:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
        try:
            n = int(headers.get("content-length", "0"))
        except ValueError:
            n = 0
        if n > MAX_BODY or n < 0:
            return "too_big"
        body, self.buf = rest[:n], rest[n:]
        while len(body) < n:
            chunk = self.request.recv(min(65536, n - len(body)))
            if not chunk:
                break
            body += chunk
        path, _, query = target.partition("?")
        q = {}
        for part in query.split("&"):
            if part:
                k, _, v = part.partition("=")
                q[unquote(k)] = unquote(v)
        return Req(method.upper(), unquote(path), q, headers, body[:n], self.client_address[0],
                   version.strip().upper())

    def send(self, code, body=b"", ctype="application/json", extra=None):
        reason = {200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                  404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large",
                  429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable"}.get(code, "OK")
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        h = ["HTTP/1.1 %d %s" % (code, reason), "Content-Type: " + ctype, "Content-Length: %d" % len(body),
             "Connection: " + ("keep-alive" if self.keep else "close"), "X-Content-Type-Options: nosniff",
             "X-Frame-Options: DENY", "Referrer-Policy: no-referrer",
             "Content-Security-Policy: default-src 'self'; img-src 'self' data: blob:; "
             "style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'"]
        if ctype.startswith("application/json"):
            h.append("Cache-Control: no-store")
        for k, v in (extra or {}).items():
            h.append("%s: %s" % (k, v))
        try:
            self.request.sendall(("\r\n".join(h) + "\r\n\r\n").encode() + body)
        except OSError:
            pass

    def handle(self):
        for _ in range(500):
            try:
                req = self.read_request()
            except (OSError, socket.timeout):
                return
            if req is None:
                return
            if req == "too_big":
                self.keep = False
                self.send(413, {"error": "too large"})
                return
            conn = req.headers.get("connection", "").lower()
            self.keep = (req.version == "HTTP/1.1" and conn != "close") or conn == "keep-alive"
            try:
                self.route(req)
            except Exception as e:  # keep serving; report to the browser
                sys.stderr.write("web error %s %s: %r\n" % (req.method, req.path, e))
                self.keep = False
                self.send(500, {"error": "server error"})
            if not self.keep:
                return
            self.request.settimeout(15)

    def authed(self, req):
        tok = req.cookie(COOKIE)
        t = time.time()
        with LOCK:
            exp = SESSIONS.get(tok)
            if tok and exp and exp > t:
                SESSIONS[tok] = t + SESSION_TTL
                return True
        return False

    def login(self, req):
        t = time.time()
        with LOCK:
            cnt, until = FAILS.get(req.ip, (0, 0))
        if until > t:
            return self.send(429, {"error": "Too many attempts. Try again in %d s." % int(until - t)})
        pw = str(req.json().get("password", ""))[:200]
        auth = first_line(ARGS.auth)
        if auth and pw and check_password(pw, auth):
            tok = binascii.hexlify(os.urandom(24)).decode()
            with LOCK:
                FAILS.pop(req.ip, None)
                for k in [k for k, v in SESSIONS.items() if v < t]:
                    del SESSIONS[k]
                while len(SESSIONS) >= 20:
                    del SESSIONS[min(SESSIONS, key=SESSIONS.get)]
                SESSIONS[tok] = t + SESSION_TTL
            return self.send(200, {"ok": True},
                             extra={"Set-Cookie": "%s=%s; HttpOnly; SameSite=Strict; Path=/" % (COOKIE, tok)})
        cnt += 1
        lock = 0 if cnt < 5 else min(900, 60 * (2 ** (cnt - 5)))
        with LOCK:
            FAILS[req.ip] = (cnt, t + lock)
        time.sleep(1)
        return self.send(401, {"error": "Wrong password" + (" - locked for %d s" % lock if lock else "")})

    def static(self, name):
        root = os.path.realpath(os.path.join(ARGS.web_dir, "static"))
        path = os.path.realpath(os.path.join(root, name))
        if not path.startswith(root + os.sep) or not os.path.isfile(path):
            return self.send(404, b"not found", "text/plain")
        with open(path, "rb") as fh:
            data = fh.read()
        ext = os.path.splitext(path)[1].lower()
        cache = {"Cache-Control": "no-cache"} if ext in (".html", ".js", ".css") else {"Cache-Control": "max-age=86400"}
        return self.send(200, data, MIME.get(ext, "application/octet-stream"), cache)

    def route(self, req):
        p = req.path
        if req.method == "GET" and (p == "/" or p.startswith("/static/")):
            return self.static("index.html" if p == "/" else p[len("/static/"):])
        if req.method == "GET" and p == "/favicon.ico":
            return self.send(204)
        if req.method == "POST":
            if req.headers.get("x-pagermesh") != "1":
                return self.send(403, {"error": "missing X-PagerMesh header"})
            if p == "/api/login":
                return self.login(req)
        if not self.authed(req):
            return self.send(401, {"error": "login required"})
        if req.method == "GET":
            if p == "/api/state":
                if req.query.get("v") == str(STATE.version):
                    return self.send(204)
                return self.send(200, state_json())
            if p == "/api/setup":
                return self.send(200, setup_info())
            if p == "/api/sources":
                return self.send(200, {"sources": sources(), "default": ARGS.map_source})
            if p == "/api/radio":
                return self.send(200, STATE.radio_view())
            if p == "/api/node":
                return self.send(*node_info(req.query.get("id", "")))
            if p == "/api/sigint":
                sc = dict(SERVICE.scan) if SERVICE else {}
                return self.send(200, {"stats": STATE.sig.stats(STATE.name_of), "packets": STATE.sig.recent(150),
                                       "trails": STATE.sig.trail_list(),
                                       "scan": {k: sc.get(k) for k in ("running", "now", "presets", "dwell", "results", "orig")},
                                       "presets": [[k, v] for k, v in sorted(STATE_PRESETS().items())]})
            if p in ("/api/export/pcap", "/api/export/csv"):
                stamp = time.strftime("%Y%m%d-%H%M%S")
                if p.endswith("pcap"):
                    return self.send(200, STATE.sig.pcap(), "application/vnd.tcpdump.pcap",
                                     {"Content-Disposition": 'attachment; filename="pagermesh-%s.pcap"' % stamp})
                return self.send(200, STATE.sig.csv(), "text/csv",
                                 {"Content-Disposition": 'attachment; filename="pagermesh-%s.csv"' % stamp})
            m = re.match(r"^/tiles/([a-z0-9_]+)/(\d+)/(\d+)/(\d+)\.png$", p)
            if m:
                data = tile(m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)))
                if data is None:
                    return self.send(404, b"", "image/png")
                return self.send(200, data, "image/png", {"Cache-Control": "max-age=86400"})
            return self.send(404, {"error": "not found"})
        if req.method == "POST":
            b = req.json()
            if p == "/api/logout":
                with LOCK:
                    SESSIONS.pop(req.cookie(COOKIE), None)
                return self.send(200, {"ok": True}, extra={"Set-Cookie": COOKIE + "=; Max-Age=0; Path=/"})
            if p == "/api/chat":
                dest = str(b.get("to", "all"))
                to = None
                if dest.startswith("!"):
                    try:
                        to = int(dest[1:], 16)
                    except ValueError:
                        return self.send(400, {"error": "bad destination"})
                try:
                    ch = int(b.get("channel", 0))
                except (TypeError, ValueError):
                    ch = 0
                ok, msg = STATE.send_text(str(b.get("text", ""))[:400], to, ch)
                return self.send(200 if ok else 503, {"ok": ok, "message": msg})
            if p == "/api/position":
                ok, msg = STATE.send_position()
                return self.send(200 if ok else 503, {"ok": ok, "message": msg})
            if p in ("/api/setup/test", "/api/setup/save"):
                f, err = setup_fields(b)
                if f is None:
                    return self.send(400, {"ok": False, "message": err})
                if p == "/api/setup/save":
                    # live = this service switches now; payload.sh only stores it (no restart, no new sign-in)
                    live = not ARGS.setup and SWITCH is not None
                    tmp = os.path.join(ARGS.run, "setup_req.tmp")
                    with open(tmp, "w", encoding="utf-8") as fh:
                        fh.write("conn=%(conn)s\nhost=%(host)s\nport=%(port)d\ndev=%(dev)s\n" % f)
                        fh.write("live=%d\n" % live)
                    os.replace(tmp, os.path.join(ARGS.run, "setup_req"))
                    if live:
                        SWITCH(f["conn"], f["host"], f["port"], f["dev"])
                    return self.send(200, {"ok": True, "live": live, "message": "Saved."})
                # never open a second connection to the radio in use: radios allow one API client
                in_use = not ARGS.setup and f["conn"] == ARGS.conn and (
                    (f["conn"] == "usb" and f["dev"] == ARGS.dev) or
                    (f["conn"] != "usb" and f["host"] == ARGS.host and f["port"] == ARGS.port))
                if in_use:
                    if STATE.link == "connected":
                        return self.send(200, {"ok": True, "message": "Connected now with these settings."})
                    return self.send(200, {"ok": False, "message": "PagerMesh is using these settings now and is %s%s." % (
                        STATE.link, (": " + STATE.error) if STATE.error else "")})
                if not TEST_LOCK.acquire(blocking=False):
                    return self.send(429, {"ok": False, "message": "a test is already running"})
                try:
                    ok, msg = PROBE(f["conn"], f["host"], f["port"], f["dev"]) if PROBE else (False, "not available")
                finally:
                    TEST_LOCK.release()
                return self.send(200, {"ok": ok, "message": msg})
            if p == "/api/radio":
                if b.get("reboot"):
                    ok, msg = STATE.reboot_radio()
                elif isinstance(b.get("owner"), dict):
                    ok, msg = STATE.set_owner(str(b["owner"].get("long", "")), str(b["owner"].get("short", "")))
                elif isinstance(b.get("changes"), dict):
                    ok, msg = STATE.set_radio({str(k): v for k, v in b["changes"].items()})
                else:
                    ok, msg = False, "nothing to change"
                return self.send(200 if ok else 400, {"ok": ok, "message": msg})
            if p == "/api/channel":
                try:
                    idx = int(b.get("index"))
                    kw = {k: b[k] for k in ("name", "psk", "role", "uplink", "downlink", "precision") if k in b}
                    if "role" in kw:
                        kw["role"] = int(kw["role"])
                    ok, msg = STATE.set_channel(idx, **kw)
                except (TypeError, ValueError) as e:
                    ok, msg = False, str(e) or "bad channel"
                return self.send(200 if ok else 400, {"ok": ok, "message": msg})
            if p == "/api/radio/share":
                url = STATE.share_url()
                if not url:
                    return self.send(404, {"ok": False, "message": "no channels yet"})
                return self.send(200, {"ok": True, "url": url, "svg": qr_svg(url)})
            if p == "/api/node":
                num = STATE.node_num(b.get("id", ""))
                act = str(b.get("action", ""))
                if act == "trace":
                    ok, msg = STATE.traceroute(num)
                elif act == "reqpos":
                    ok, msg = STATE.request_position(num)
                elif act in ("fav", "unfav"):
                    ok, msg = STATE.favorite(num, act == "fav")
                else:
                    ok, msg = False, "unknown action"
                return self.send(200 if ok else 400, {"ok": ok, "message": msg})
            if p == "/api/waypoint":
                if b.get("delete") is not None:
                    try:
                        ok, msg = STATE.delete_waypoint(int(b["delete"]))
                    except (TypeError, ValueError):
                        ok, msg = False, "bad id"
                else:
                    ok, msg = STATE.send_waypoint(b.get("lat"), b.get("lon"), str(b.get("name", "")),
                                                  str(b.get("desc", "")), b.get("hours", 24))
                return self.send(200 if ok else 400, {"ok": ok, "message": msg})
            if p == "/api/cfg":
                vals = {str(k): str(v) for k, v in b.items() if isinstance(v, (str, int, float, bool))}
                bad = check_cfg(vals)
                if bad:
                    return self.send(400, {"ok": False, "message": bad})
                STATE.set_cfg(vals)
                return self.send(200, {"ok": True, "message": "saved"})
            if p == "/api/scan":
                if not SERVICE:
                    return self.send(503, {"ok": False, "message": "not available"})
                if b.get("stop"):
                    ok, msg = SERVICE.stop_scan()
                else:
                    pres = b.get("presets") or None
                    try:
                        pres = [int(x) for x in pres] if pres else None
                        ok, msg = SERVICE.start_scan(pres, int(b.get("dwell") or 60))
                    except (TypeError, ValueError):
                        ok, msg = False, "bad scan settings"
                return self.send(200 if ok else 400, {"ok": ok, "message": msg})
            if p == "/api/read":
                STATE.mark_read(str(b.get("conv", ""))[:40])
                return self.send(200, {"ok": True})
            if p == "/api/delete":
                ok, msg = STATE.delete_chat(str(b.get("what", "")), str(b.get("id", ""))[:60])
                return self.send(200 if ok else 404, {"ok": ok, "message": msg})
            return self.send(404, {"error": "not found"})
        return self.send(405, {"error": "method not allowed"})


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def __init__(self, addr, handler):
        if ":" in addr[0]:
            self.address_family = socket.AF_INET6
        socketserver.ThreadingTCPServer.__init__(self, addr, handler)

    def handle_error(self, request, client_address):
        pass


def start(state, args):
    """Called by the mesh service. Returns True when at least one address listens."""
    global STATE, ARGS, PM
    STATE, ARGS = state, args
    if not first_line(args.auth):
        sys.stderr.write("web: no password set (%s)\n" % args.auth)
        return False
    try:
        sys.path.insert(0, os.path.realpath(args.map_dir))
        import pagermesh_map as pm  # noqa: E402
        PM = pm
    except ImportError as e:
        sys.stderr.write("web: map helpers not available (%s) - no basemaps\n" % e)
    ok = False
    for addr in [a.strip() for a in args.bind.split(",") if a.strip()]:
        try:
            srv = Server((addr, args.web_port), Handler)
        except OSError as e:
            sys.stderr.write("web: cannot listen on %s:%d (%s)\n" % (addr, args.web_port, e))
            continue
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        sys.stderr.write("web: listening on http://%s:%d\n" % (addr, args.web_port))
        ok = True
    return ok
