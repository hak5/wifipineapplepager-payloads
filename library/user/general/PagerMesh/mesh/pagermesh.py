#!/usr/bin/env python3
"""PagerMesh mesh service for the WiFi Pineapple Pager.

Holds one connection to meshtasticd's TCP API (default 127.0.0.1:4403, the same
API the Meshtastic phone app uses), keeps the node list and chat, sends chat
and the Pager's GPS position, and optionally serves the web console.
Python standard library only (python3-light).

It shares state with payload.sh through files in its runtime directory
(default /tmp/pagermesh), so the Pager menus and the map stay simple shell:

  read   gps                 fix lat lon hae ce speed track sats epoch (written by payload.sh)
         pos_interval        seconds between automatic position broadcasts (0 = off)
         outbox/*.cmd        commands from payload.sh (see handle_cmd)
  write  status              state|my_id|my_name|region|nodes|last_error|last_pos
         nodes               id|short|long|range_m|bearing|battery|snr|hops|age_s|lat|lon|num
         channels            index|name
         tracks.d/<id>       lat|lon|name|cot_type|team|epoch|kind|stale  (for the map viewer)
         inbox               epoch|label|from|text   (new messages, appended)
         lastchat            epoch|label|from|text   (map banner)
         unread              count of unread messages
         convs               conv|title|unread|last_epoch|count   (newest first)
         thread              mid|epoch|dir|who|status|text        (written by the "thread" command)
  loot   chat_YYYYMMDD.log   iso|dir|label|from_id|from|to|conv|mid|text
                             conv = dm:!nodeid | ch:<index>; the last 7 days are loaded at start

  pagermesh.py --check            one-shot: connect, print "OK ..." or "FAIL ..."
  pagermesh.py --setup ...        web console only, for choosing the connection (no radio needed)
  pagermesh.py --nodes            one-shot: print the node list
  pagermesh.py --run DIR ...      the service
  pagermesh.py --hash-password    web console password hash (stdin -> stdout)
"""
import argparse
import glob
import hashlib
import json
import math
import os
import random
import signal
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import meshproto as mp  # noqa: E402
import radiocfg  # noqa: E402
import sigint  # noqa: E402
import takbridge  # noqa: E402

TRACK_TYPE = "a-f-G-U-C"          # map viewer: friendly ground unit
TRACK_TEAM = "Green"
HEARTBEAT_SEC = 60
FILES_SEC = 2
CHAT_KEEP = 3000                  # messages kept in memory (7 days of history)
HISTORY_DAYS = 7
THREAD_MAX = 40                   # messages in RUN/thread for the Pager
WAYPOINT_TYPE = "b-m-p-w"         # map viewer: waypoint
TRACE_TIMEOUT = 90
# PagerMesh settings shared with payload.sh (RUN/config, key=value; payload.sh keeps them
# in the Pager config). Changes from the web console go to RUN/cfg_req for payload.sh.
APP_CFG = ("manual_pos", "hide_age", "dm_alert", "tak_on", "tak_proto", "tak_host", "tak_port",
           "tak_pos", "tak_chat", "tak_chan", "pos_chan")


def now():
    return int(time.time())


def write_atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data)
    os.replace(tmp, path)


def first_line(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.readline().strip()
    except OSError:
        return ""


def clean(v, n=200):
    """One line, no field separators (|) and no control characters."""
    v = "".join(ch if ch >= " " else " " for ch in str(v))
    return v.replace("|", "/")[:n]


def inbox_line(e):
    return "%d|%s|%s|%s\n" % (e["t"], clean(e["label"], 40), clean(e["from"], 40), clean(e["text"], 400))


def loot_line(e):
    """iso|dir|label|from_id|from|to|conv|mid|text"""
    return "|".join([time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(e["t"])), e["dir"],
                     clean(e["label"], 40), e["from_id"], clean(e["from"], 40), e["to"],
                     e["conv"], e["mid"], clean(e["text"], 400)])


def parse_loot(ln):
    """A loot chat line -> chat dict, or None. Older chat logs (before conversations) have 7 fields."""
    f = ln.split("|")
    if len(f) == 9:
        iso, d, label, from_id, frm, to, conv, mid, text = f
    elif len(f) == 7:
        iso, d, label, from_id, frm, to, text = f
        conv = ("dm:" + (from_id if d == "in" else to)) if label == "DM" else "ch:0"
        mid = "L" + hashlib.sha1(ln.encode("utf-8", "replace")).hexdigest()[:14]
    else:
        return None
    if d not in ("in", "out") or not (conv.startswith("dm:") or conv.startswith("ch:")):
        return None
    try:
        t = int(time.mktime(time.strptime(iso, "%Y-%m-%dT%H:%M:%S")))
    except (ValueError, OverflowError):
        return None
    direct = conv.startswith("dm:")
    ch = 0
    if not direct:
        try:
            ch = int(conv[3:])
        except ValueError:
            pass
    return {"t": t, "dir": d, "label": label, "conv": conv, "mid": mid, "channel": ch, "direct": direct,
            "from_id": from_id, "from": frm, "short": frm[:4], "to": to, "to_name": "",
            "text": text, "status": "", "id": 0}


def dist_bearing(lat1, lon1, lat2, lon2):
    r = math.radians
    p1, p2, dl = r(lat1), r(lat2), r(lon2 - lon1)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 2 * 6371000 * math.asin(min(1.0, math.sqrt(a)))
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return round(d), round((math.degrees(math.atan2(y, x)) + 360) % 360)


class State:
    """Everything known about the mesh. One lock; the web console reads it too."""

    def __init__(self, run, loot):
        self.run, self.loot = run, loot
        self.lock = threading.RLock()
        self.link = "starting"
        self.error = ""
        self.my_num = None
        self.nodes = {}
        self.channels = {}
        self.region = None
        self.hop_limit = 0
        self.chat = []                   # dicts, newest last; each has conv, mid, read
        self.pending = {}                # packet id -> chat dict (waiting for ack)
        self.unread = 0
        self.last_pos = 0
        self.dirty = True
        self.version = 0                 # bumps on every change (web console polls it)
        self.outq = []                   # ToRadio payloads waiting to be sent
        self.wake = threading.Event()
        self.sections = {}               # (cfg|mod, section) -> raw settings from the radio
        self.channels_all = {}           # index -> channel, disabled ones too
        self.owner_raw = b""
        self.metadata = {}
        self.cfg = {}                    # PagerMesh settings (APP_CFG)
        self.traces = {}                 # node num -> traceroute result
        self.waypoints = {}              # id -> waypoint dict
        self.notes = []                  # short messages for the web console (settings saved, ...)
        self.sig = sigint.Sigint(mp.PORT_NAMES, mp.node_id)
        self.bridge = None

    # ---- PagerMesh settings
    def load_cfg(self):
        try:
            with open(os.path.join(self.run, "config"), encoding="utf-8") as fh:
                for ln in fh:
                    k, _, v = ln.rstrip("\n").partition("=")
                    if k in APP_CFG:
                        self.cfg[k] = v
        except OSError:
            pass

    def set_cfg(self, values, persist=True):
        """Change PagerMesh settings now and (persist) hand them to payload.sh to keep."""
        clean_v = {}
        for k, v in values.items():
            if k not in APP_CFG:
                continue
            v = clean(v, 120).strip()
            clean_v[k] = v
        if not clean_v:
            return
        with self.lock:
            self.cfg.update(clean_v)
            self.touch()
        try:
            write_atomic(os.path.join(self.run, "config"), "".join("%s=%s\n" % kv for kv in sorted(self.cfg.items())))
            if persist:
                with open(os.path.join(self.run, "cfg_req"), "a", encoding="utf-8") as fh:
                    fh.write("".join("%s=%s\n" % kv for kv in sorted(clean_v.items())))
        except OSError:
            pass
        if self.bridge and any(k.startswith("tak_") for k in clean_v):
            self.bridge.restart()

    def cfg_int(self, k, default=0):
        try:
            return int(self.cfg.get(k) or default)
        except ValueError:
            return default

    def note(self, msg):
        with self.lock:
            self.notes.append((now(), msg))
            del self.notes[:-10]
            self.touch()

    # ---- helpers
    def touch(self):
        self.dirty = True
        self.version += 1

    def me(self):
        return self.nodes.get(self.my_num, {})

    def name_of(self, num):
        u = self.nodes.get(num, {}).get("user", {})
        return u.get("long_name") or u.get("short_name") or mp.node_id(num)

    def short_of(self, num):
        u = self.nodes.get(num, {}).get("user", {})
        return u.get("short_name") or mp.node_id(num)[-4:]

    def chan_label(self, idx):
        c = self.channels.get(idx)
        if c and c["name"]:
            return c["name"]
        return "Primary" if idx == 0 else "Ch%d" % idx

    def gps(self):
        """Pager GPS fix (lat, lon, alt) from payload.sh, else the manual position set on the
        web map (lat, lon, None), else None."""
        f = first_line(os.path.join(self.run, "gps")).split()
        if len(f) >= 4 and f[0] == "1":
            try:
                alt = float(f[3]) if f[3] != "-" else None
                return float(f[1]), float(f[2]), alt
            except ValueError:
                pass
        return self.manual()

    def manual(self):
        try:
            a, b = (float(x) for x in self.cfg.get("manual_pos", "").split(","))
            if -90 <= a <= 90 and -180 <= b <= 180:
                return a, b, None
        except ValueError:
            pass
        return None

    def gps_is_fix(self):
        return first_line(os.path.join(self.run, "gps")).startswith("1 ")

    def origin(self):
        g = self.gps()
        if g:
            return g[0], g[1]
        p = self.me().get("position", {})
        if "lat" in p:
            return p["lat"], p["lon"]
        return None

    # ---- incoming
    def update_node(self, n):
        num = n.get("num")
        if num is None:
            return
        with self.lock:
            cur = self.nodes.setdefault(num, {"num": num})
            for k, v in n.items():
                if k in ("user", "position", "metrics") and isinstance(v, dict):
                    cur.setdefault(k, {}).update(v)
                else:
                    cur[k] = v
            self.touch()

    def heard(self, pkt):
        num = pkt.get("from")
        if num is None or num == self.my_num:
            return
        n = {"num": num, "last_heard": pkt.get("rx_time") or now()}
        if "rx_snr" in pkt:
            n["snr"] = pkt["rx_snr"]
        if pkt.get("hop_start") and "hop_limit" in pkt:
            n["hops_away"] = max(0, pkt["hop_start"] - pkt["hop_limit"])
        self.update_node(n)

    def add_chat(self, entry, log=True):
        entry.setdefault("read", entry["dir"] == "out")
        entry.setdefault("mid", "%d-%08x" % (entry["t"], entry.get("id") or random.randint(1, 0xFFFFFFFF)))
        with self.lock:
            self.chat.append(entry)
            del self.chat[:-CHAT_KEEP]
            self.touch()
        if not log:
            return
        if self.bridge:
            try:
                self.bridge.on_chat(entry)
            except Exception as e:  # noqa: BLE001 - the bridge must never break chat
                sys.stderr.write("tak bridge: %s\n" % e)
        day = time.strftime("%Y%m%d", time.localtime(entry["t"]))
        try:
            os.makedirs(self.loot, exist_ok=True)
            with open(os.path.join(self.loot, "chat_%s.log" % day), "a", encoding="utf-8") as fh:
                fh.write(loot_line(entry) + "\n")
        except OSError:
            pass

    # ---- conversations: dm:!nodeid (one per contact) and ch:<index> (one per channel)
    def conv_title(self, conv, fallback=""):
        if conv.startswith("dm:"):
            try:
                num = int(conv[4:], 16)
            except ValueError:
                return fallback or conv[3:]
            n = self.name_of(num)
            return "DM " + (fallback if n == mp.node_id(num) and fallback else n)
        try:
            return self.chan_label(int(conv[3:]))
        except ValueError:
            return conv[3:]

    def unread_total(self):
        with self.lock:
            return sum(1 for c in self.chat if not c["read"])

    def conversations(self):
        """[{conv, title, unread, last, count}] newest first."""
        convs = {}
        with self.lock:
            for c in self.chat:
                v = convs.setdefault(c["conv"], {"conv": c["conv"], "unread": 0, "last": 0, "count": 0, "name": ""})
                v["count"] += 1
                v["last"] = max(v["last"], c["t"])
                if not c["read"]:
                    v["unread"] += 1
                if c["dir"] == "in" and c.get("direct"):
                    v["name"] = c.get("from", "")
                elif c["dir"] == "out" and c.get("direct") and not v["name"]:
                    v["name"] = c.get("to_name", "")
            out = sorted(convs.values(), key=lambda v: -v["last"])
            for v in out:
                v["title"] = self.conv_title(v["conv"], v.pop("name"))
        return out

    def mark_read(self, conv=""):
        with self.lock:
            for c in self.chat:
                if not conv or c["conv"] == conv:
                    c["read"] = True
            self.unread = self.unread_total()
            self.touch()

    def thread(self, conv, limit=THREAD_MAX):
        with self.lock:
            return [dict(c) for c in self.chat if c["conv"] == conv][-limit:]

    def delete_chat(self, what, key=""):
        """what = msg (key = mid) | conv (key = conv) | all. Removes it from memory and the loot logs."""
        if what == "msg":
            gone = lambda c: c.get("mid") == key          # noqa: E731
        elif what == "conv":
            gone = lambda c: c.get("conv") == key         # noqa: E731
        elif what == "all":
            gone = lambda c: True                         # noqa: E731
        else:
            return False, "unknown delete"
        if what != "all" and not key:
            return False, "nothing chosen"
        with self.lock:
            before = len(self.chat)
            self.chat = [c for c in self.chat if not gone(c)]
            n = before - len(self.chat)
            for pid in [k for k, e in self.pending.items() if gone(e)]:
                del self.pending[pid]
            self.unread = self.unread_total()
            self.touch()
        n = max(n, self.delete_loot(gone, what == "all"))
        try:
            if what == "all" or n:
                last = [c for c in self.chat if c["dir"] == "in"][-1:]
                if last:
                    write_atomic(os.path.join(self.run, "lastchat"), inbox_line(last[0]))
                elif os.path.exists(os.path.join(self.run, "lastchat")):
                    os.remove(os.path.join(self.run, "lastchat"))
        except OSError:
            pass
        if not n:
            return False, "not found"
        return True, "deleted %d message%s" % (n, "" if n == 1 else "s")

    def delete_loot(self, gone, everything):
        n = 0
        for path in sorted(glob.glob(os.path.join(self.loot, "chat_*.log"))):
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    lines = fh.read().splitlines()
            except OSError:
                continue
            keep = []
            for ln in lines:
                e = parse_loot(ln)
                if e is not None and (everything or gone(e)):
                    n += 1
                else:
                    keep.append(ln)
            if len(keep) == len(lines):
                continue
            try:
                if keep:
                    write_atomic(path, "\n".join(keep) + "\n")
                else:
                    os.remove(path)
            except OSError:
                pass
        return n

    def load_history(self, days=HISTORY_DAYS):
        """Last <days> of chat from the loot logs (shown as read)."""
        since = now() - days * 86400
        out = []
        for path in sorted(glob.glob(os.path.join(self.loot, "chat_*.log"))):
            day = os.path.basename(path)[5:13]
            try:
                if time.mktime(time.strptime(day, "%Y%m%d")) < since - 86400:
                    continue
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for ln in fh:
                        e = parse_loot(ln.rstrip("\n"))
                        if e is not None and e["t"] >= since:
                            e["read"] = True
                            out.append(e)
            except (OSError, ValueError, OverflowError):
                continue
        out.sort(key=lambda e: e["t"])
        with self.lock:
            self.chat = out[-CHAT_KEEP:] + self.chat
            del self.chat[:-CHAT_KEEP]
            self.touch()
        return len(out)

    def on_packet(self, pkt):
        d = pkt.get("decoded")
        if not d:
            self.heard(pkt)                           # encrypted for a channel we don't have: still heard
            return
        self.heard(pkt)
        port, payload, frm = d["portnum"], d["payload"], pkt.get("from", 0)
        try:
            if port == mp.PORT_TEXT:
                txt = payload.decode("utf-8", "replace")
                direct = pkt.get("to") not in (None, mp.BROADCAST)
                label = "DM" if direct else self.chan_label(pkt.get("channel", 0))
                entry = {"t": pkt.get("rx_time") or now(), "dir": "in", "label": label,
                         "conv": ("dm:" + mp.node_id(frm)) if direct else "ch:%d" % pkt.get("channel", 0),
                         "channel": pkt.get("channel", 0), "direct": direct,
                         "from_id": mp.node_id(frm), "from": self.name_of(frm),
                         "short": self.short_of(frm), "to": mp.node_id(pkt.get("to")),
                         "text": txt, "status": "", "id": pkt.get("id", 0)}
                self.add_chat(entry)
                with self.lock:
                    self.unread = self.unread_total()
                line = inbox_line(entry)
                try:
                    with open(os.path.join(self.run, "inbox"), "a", encoding="utf-8") as fh:
                        fh.write(line)
                    write_atomic(os.path.join(self.run, "lastchat"), line)
                except OSError:
                    pass
            elif port == mp.PORT_POSITION:
                p = mp.dec_position(payload)
                if "lat" in p:
                    p["rx"] = pkt.get("rx_time") or now()
                    self.update_node({"num": frm, "position": p})
                    self.sig.add_point(frm, p["lat"], p["lon"])
                    if d.get("request_id"):
                        self.note("Position from %s" % self.name_of(frm))
            elif port == mp.PORT_WAYPOINT:
                w = mp.dec_waypoint(payload)
                if w["id"]:
                    w["from"], w["t"] = frm, now()
                    with self.lock:
                        if w["expire"] and w["expire"] < now() or "lat" not in w:
                            self.waypoints.pop(w["id"], None)
                        else:
                            self.waypoints[w["id"]] = w
                        self.touch()
            elif port == mp.PORT_TRACEROUTE and d.get("request_id"):
                r = mp.dec_route(payload)
                with self.lock:
                    tr = self.traces.get(frm) or {"t": now()}
                    tr.update(r)
                    tr["done"], tr["t_done"] = True, now()
                    self.traces[frm] = tr
                    self.touch()
                self.note("Traceroute to %s: %s" % (self.name_of(frm), self.trace_text(frm)))
            elif port == mp.PORT_NODEINFO:
                self.update_node({"num": frm, "user": mp.dec_user(payload)})
            elif port == mp.PORT_TELEMETRY:
                m = mp.dec_telemetry(payload)
                if m:
                    self.update_node({"num": frm, "metrics": m})
            elif port == mp.PORT_ROUTING and d.get("request_id"):
                err = mp.dec_routing_error(payload)
                with self.lock:
                    e = self.pending.pop(d["request_id"], None)
                    if e is not None:
                        e["status"] = "delivered" if err == 0 else "failed"
                        self.touch()
        except ValueError:
            pass                                       # malformed payload: ignore it

    # ---- outgoing
    def queue(self, payload):
        with self.lock:
            self.outq.append(payload)
        self.wake.set()

    def send_text(self, msg, to=None, channel=0, from_tak=False):
        """to = node number for a direct message, None for the channel.
        from_tak = sent by the TAK bridge (not sent back to TAK)."""
        msg = mp.clip_text(clean(msg, 400).strip())
        if not msg:
            return False, "empty message"
        if self.link != "connected":
            return False, "not connected to meshtasticd"
        pid = mp.new_packet_id()
        dest = mp.BROADCAST if to is None else to
        self.queue(mp.text_packet(msg, dest, 0 if to is not None else channel, self.hop_limit, pid))
        entry = {"t": now(), "dir": "out", "label": "DM" if to is not None else self.chan_label(channel),
                 "conv": ("dm:" + mp.node_id(dest)) if to is not None else "ch:%d" % channel,
                 "channel": channel, "direct": to is not None, "from_id": mp.node_id(self.my_num),
                 "from": self.name_of(self.my_num) if self.my_num else "me", "short": "me",
                 "to": mp.node_id(dest) if to is not None else "all", "to_name": self.name_of(to) if to is not None else "",
                 "text": msg, "status": "sent" if to is None else "pending", "id": pid, "from_tak": from_tak}
        if to is not None:
            with self.lock:
                self.pending[pid] = entry
        self.add_chat(entry)
        return True, "sent"

    def pos_chan(self):
        """Channel for the Pager's position, or None: nothing is shared until a channel is chosen."""
        v = str(self.cfg.get("pos_chan", "")).strip()
        return int(v) if v.isdigit() else None

    def send_position(self):
        ch = self.pos_chan()
        if ch is None:
            return False, "position sharing is off - pick a channel: Settings > Send position > Share on"
        g = self.gps()
        if not g:
            return False, "no GPS fix"
        if self.link != "connected":
            return False, "not connected to meshtasticd"
        self.queue(mp.position_packet(g[0], g[1], g[2], now(), ch, self.hop_limit,
                                      source=3 if self.gps_is_fix() else 1))
        with self.lock:
            self.last_pos = now()
            if self.my_num is not None:
                cur = self.nodes.setdefault(self.my_num, {"num": self.my_num})
                cur.setdefault("position", {}).update({"lat": g[0], "lon": g[1]})
            self.touch()
        return True, "position sent"

    # ---- radio settings (AdminMessage to our own radio; most changes reboot it)
    def radio_view(self):
        """Current radio settings for the console (no secrets, no channel keys)."""
        with self.lock:
            sec = dict(self.sections)
            chans = sorted(self.channels.values(), key=lambda c: c["index"])
            me = self.me().get("user", {})
        return {"values": radiocfg.current(sec), "settings": radiocfg.describe(),
                "have": sorted("%s.%d" % k for k in sec),
                "owner": {"long": me.get("long_name", ""), "short": me.get("short_name", "")},
                "channels": [{k: c.get(k) for k in ("index", "name", "role", "psk_kind", "uplink", "downlink", "precision")}
                             for c in chans],
                "metadata": {"firmware": self.metadata.get("firmware", ""),
                             "hw": mp.hw_name(self.metadata.get("hw_model", me.get("hw_model"))),
                             "has_wifi": self.metadata.get("has_wifi")}}

    def can_admin(self):
        if self.link != "connected" or self.my_num is None:
            return False, "not connected to the radio"
        return True, ""

    def set_owner(self, long_name, short_name):
        ok, msg = self.can_admin()
        if not ok:
            return ok, msg
        long_name, short_name = clean(long_name, 60).strip(), clean(short_name, 10).strip()
        if not long_name and not short_name:
            return False, "enter a name"
        if len(long_name.encode("utf-8")) > 39:
            return False, "long name: at most 39 characters"
        if short_name and (len(short_name) > 4 or len(short_name.encode("utf-8")) > 4):
            return False, "short name: at most 4 characters"
        self.queue(mp.admin_packet(self.my_num, mp.adm_set_owner(long_name, short_name)))
        u = {}
        if long_name:
            u["long_name"] = long_name
        if short_name:
            u["short_name"] = short_name
        self.update_node({"num": self.my_num, "user": u})
        return True, "name saved on the radio"

    def set_radio(self, changes):
        """changes {setting key: value}. One begin/commit, so the radio reboots once."""
        ok, msg = self.can_admin()
        if not ok:
            return ok, msg
        try:
            with self.lock:
                sec = dict(self.sections)
            parts, labels, _risky = radiocfg.build(sec, changes)
        except ValueError as e:
            return False, str(e)
        if not parts:
            return True, "nothing changed"
        self.queue(mp.admin_packet(self.my_num, mp.adm_begin()))
        for kind, section, raw in parts:
            adm = mp.adm_set_config(section, raw) if kind == radiocfg.CFG else mp.adm_set_module(section, raw)
            self.queue(mp.admin_packet(self.my_num, adm))
            with self.lock:
                self.sections[(kind, section)] = raw
        self.queue(mp.admin_packet(self.my_num, mp.adm_commit()))
        self.touch()
        return True, "saved: %s - the radio restarts to apply it" % ", ".join(labels)

    def set_channel(self, index, **kw):
        ok, msg = self.can_admin()
        if not ok:
            return ok, msg
        with self.lock:
            cur = self.channels_all.get(index)
        try:
            raw = radiocfg.build_channel(cur, index, rand=os.urandom, **kw)
        except ValueError as e:
            return False, str(e)
        self.queue(mp.admin_packet(self.my_num, mp.adm_begin()))
        self.queue(mp.admin_packet(self.my_num, mp.adm_set_channel(raw)))
        self.queue(mp.admin_packet(self.my_num, mp.adm_commit()))
        c = mp.dec_channel(raw)
        with self.lock:
            self.channels_all[index] = c
            if c["role"]:
                self.channels[index] = c
            else:
                self.channels.pop(index, None)
            self.touch()
        return True, "channel %d saved" % index

    def share_url(self):
        """meshtastic.org link with every enabled channel (it carries the channel keys)."""
        with self.lock:
            chans = sorted((c for c in self.channels.values() if c.get("role")), key=lambda c: (c["role"] != 1, c["index"]))
            lora = self.sections.get((radiocfg.CFG, radiocfg.LORA), b"")
        if not chans:
            return None
        return mp.channel_url([c.get("settings_raw", b"") for c in chans], lora)

    def reboot_radio(self):
        ok, msg = self.can_admin()
        if not ok:
            return ok, msg
        self.queue(mp.admin_packet(self.my_num, mp.adm_reboot(2)))
        return True, "the radio restarts"

    # ---- node tools
    def node_num(self, v):
        try:
            return int(str(v).strip().lstrip("!"), 16)
        except ValueError:
            return None

    def traceroute(self, num):
        if self.link != "connected":
            return False, "not connected to the radio"
        if num is None or num == self.my_num:
            return False, "choose another node"
        with self.lock:
            tr = self.traces.get(num)
            if tr and not tr.get("done") and now() - tr["t"] < 30:
                return False, "a traceroute to this node is running"
            self.traces[num] = {"t": now(), "done": False}
            self.touch()
        self.queue(mp.traceroute_packet(num, self.hop_limit))
        return True, "traceroute sent to %s - the answer can take a minute" % self.name_of(num)

    def trace_text(self, num):
        tr = self.traces.get(num)
        if not tr:
            return ""
        if not tr.get("done"):
            return "waiting..." if now() - tr["t"] < TRACE_TIMEOUT else "no answer"

        def hop(n, snr):
            return "%s%s" % (self.short_of(n), "" if snr is None else " (%.1f dB)" % snr)

        def path(nodes, snrs, a, b):
            out = [self.short_of(a)]
            for i, n in enumerate(nodes):
                out.append(hop(n, snrs[i] if i < len(snrs) else None))
            out.append(hop(b, snrs[len(nodes)] if len(nodes) < len(snrs) else None))
            return " > ".join(out)
        txt = path(tr.get("route", []), tr.get("snr_towards", []), self.my_num, num)
        if tr.get("route_back") or tr.get("snr_back"):
            txt += "  |  back: " + path(tr.get("route_back", []), tr.get("snr_back", []), num, self.my_num)
        return txt

    def request_position(self, num):
        if self.link != "connected":
            return False, "not connected to the radio"
        if num is None or num == self.my_num:
            return False, "choose another node"
        g = self.gps()
        self.queue(mp.position_request(num, g[0] if g else None, g[1] if g else None, self.hop_limit))
        return True, "position requested from %s" % self.name_of(num)

    def favorite(self, num, on):
        ok, msg = self.can_admin()
        if not ok:
            return ok, msg
        if num is None or num == self.my_num:
            return False, "choose another node"
        self.queue(mp.admin_packet(self.my_num, mp.adm_favorite(num, on)))
        self.update_node({"num": num, "favorite": bool(on)})
        return True, "%s %s favorites" % (self.name_of(num), "added to" if on else "removed from")

    def send_waypoint(self, lat, lon, name, desc="", hours=24, wid=None, channel=0):
        if self.link != "connected":
            return False, "not connected to the radio"
        try:
            lat, lon = float(lat), float(lon)
            hours = float(hours or 0)
        except (TypeError, ValueError):
            return False, "bad position"
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            return False, "bad position"
        name = clean(name, 30).strip() or "Waypoint"
        w = {"id": wid or random.randint(1, 0x7FFFFFFF), "lat": lat, "lon": lon, "name": name,
             "description": clean(desc, 100).strip(), "expire": int(now() + hours * 3600) if hours > 0 else 0,
             "from": self.my_num, "t": now(), "icon": 0x1F4CD}
        self.queue(mp.waypoint_packet(w, channel, self.hop_limit))
        with self.lock:
            self.waypoints[w["id"]] = w
            self.touch()
        return True, "waypoint %s sent" % name

    def delete_waypoint(self, wid):
        with self.lock:
            w = self.waypoints.pop(wid, None)
            self.touch()
        if not w:
            return False, "not found"
        if w.get("from") == self.my_num and self.link == "connected":
            w = dict(w, expire=1)                       # an expired copy removes it on the other radios
            self.queue(mp.waypoint_packet(w, 0, self.hop_limit))
            return True, "waypoint deleted on the mesh"
        return True, "waypoint removed here"

    def live_waypoints(self):
        t = now()
        with self.lock:
            for k in [k for k, w in self.waypoints.items() if w.get("expire") and w["expire"] < t]:
                del self.waypoints[k]
            return [dict(w, owner=self.name_of(w["from"]) if w.get("from") else "") for w in self.waypoints.values()]

    # ---- views
    def node_rows(self, max_age=0):
        org = self.origin()
        rows = []
        t = now()
        with self.lock:
            items = list(self.nodes.items())
        for num, n in items:
            u, p, m = n.get("user", {}), n.get("position", {}), n.get("metrics", {})
            age = (t - n["last_heard"]) if n.get("last_heard") else None
            if max_age and num != self.my_num and (age is None or age > max_age):
                continue
            pt = p.get("rx") or p.get("time")
            r = {"num": num, "id": u.get("id") or mp.node_id(num), "short": u.get("short_name", ""),
                 "long": u.get("long_name", ""), "me": num == self.my_num,
                 "lat": p.get("lat"), "lon": p.get("lon"), "battery": m.get("battery"),
                 "voltage": m.get("voltage"), "snr": n.get("snr"), "hops": n.get("hops_away"),
                 "age_s": age, "range_m": None, "bearing": None,
                 "hw": mp.hw_name(u.get("hw_model")), "role": mp.ROLES.get(u.get("role", 0), ""),
                 "mqtt": bool(n.get("via_mqtt")), "fav": bool(n.get("favorite")),
                 "pos_age": (t - pt) if pt and pt <= t + 60 else None,
                 "ch_util": m.get("ch_util"), "air_tx": m.get("air_tx")}
            if not r["me"] and org and r["lat"] is not None:
                r["range_m"], r["bearing"] = dist_bearing(org[0], org[1], r["lat"], r["lon"])
            rows.append(r)
        rows.sort(key=lambda r: (not r["me"], r["age_s"] if r["age_s"] is not None else 1 << 30))
        return rows

    def write_files(self, max_age):
        rows = self.node_rows()
        hide = self.cfg_int("hide_age")
        lines = []
        for r in rows:
            if hide and not r["me"] and (r["age_s"] is None or r["age_s"] > hide):
                continue
            lines.append("|".join("" if r[k] is None else clean(r[k], 40) for k in
                                  ("id", "short", "long", "range_m", "bearing", "battery", "snr", "hops",
                                   "age_s", "lat", "lon", "num")))
        me = self.me().get("user", {})
        region = mp.REGIONS.get(self.region, str(self.region)) if self.region is not None else ""
        write_atomic(os.path.join(self.run, "nodes"), "\n".join(lines) + ("\n" if lines else ""))
        write_atomic(os.path.join(self.run, "status"), "|".join([
            self.link, mp.node_id(self.my_num) if self.my_num else "", clean(me.get("long_name", ""), 40),
            region, str(max(0, len(rows) - 1)), clean(self.error, 120), str(self.last_pos)]) + "\n")
        with self.lock:
            ch = sorted(self.channels.values(), key=lambda c: c["index"])
        write_atomic(os.path.join(self.run, "channels"),
                     "".join("%d|%s|%s\n" % (c["index"], clean(self.chan_label(c["index"]), 40),
                                              "private" if str(c.get("psk_kind", "")).startswith("AES") else "public") for c in ch))
        write_atomic(os.path.join(self.run, "unread"), "%d\n" % self.unread)
        write_atomic(os.path.join(self.run, "convs"), "".join(
            "%s|%s|%d|%d|%d\n" % (v["conv"], clean(v["title"], 40), v["unread"], v["last"], v["count"])
            for v in self.conversations()))
        # map viewer tracks: one file per node with a position
        tdir = os.path.join(self.run, "tracks.d")
        os.makedirs(tdir, exist_ok=True)
        keep = set()
        for r in rows:
            if r["me"] or r["lat"] is None or (r["age_s"] is not None and r["age_s"] > max_age):
                continue
            fn = r["id"].replace("!", "n")
            keep.add(fn)
            name = r["long"] or r["short"] or r["id"]
            heard = now() - (r["age_s"] or 0)
            write_atomic(os.path.join(tdir, fn), "%s|%s|%s|%s|%s|%d|client|0\n" % (
                r["lat"], r["lon"], clean(name, 24), TRACK_TYPE, TRACK_TEAM, heard))
        for w in self.live_waypoints():
            fn = "w%x" % w["id"]
            keep.add(fn)
            write_atomic(os.path.join(tdir, fn), "%s|%s|%s|%s|%s|%d|waypoint|%d\n" % (
                w["lat"], w["lon"], clean("WP " + w["name"], 24), WAYPOINT_TYPE, "White", now(), w.get("expire") or 0))
        for path in glob.glob(os.path.join(tdir, "*")):
            if os.path.basename(path) not in keep and not path.endswith(".tmp"):
                try:
                    os.remove(path)
                except OSError:
                    pass
        self.dirty = False


class Service:
    def __init__(self, args):
        self.a = args
        self.s = State(args.run, args.loot)
        self.stop = threading.Event()
        self.kick = threading.Event()          # set by switch(): reconnect now, skip the retry wait
        self.stream = None
        self.scan = {}
        self.connects = 0

    def switch(self, conn, host, port, dev):
        """Web console Save: use the new radio connection right away.
        payload.sh stores it in the Pager config (RUN/setup_req)."""
        self.a.conn, self.a.host, self.a.port, self.a.dev = conn, host, int(port), dev
        self.s.link, self.s.error = "connecting", ""
        self.s.touch()
        self.kick.set()
        st = self.stream
        if st is not None:
            try:
                st.close(polite=True)            # the read loop fails and reconnects with the new settings
            except OSError:
                pass

    # ---- payload.sh commands: outbox/<n>.cmd
    #   text\n<dest: all | !nodeid>\n<channel index>\n<message...>
    #   pos
    #   read [conv]     (chat was viewed: clear unread; no conv = all)
    #   thread <conv>   (write RUN/thread for the Pager)
    #   del msg <mid> | del conv <conv> | del all
    def handle_cmd(self, body):
        lines = body.split("\n")
        cmd = lines[0].strip()
        if cmd == "text" and len(lines) >= 4:
            dest, chan, msg = lines[1].strip(), lines[2].strip(), "\n".join(lines[3:]).strip()
            to = None
            if dest.startswith("!"):
                try:
                    to = int(dest[1:], 16)
                except ValueError:
                    return False, "bad destination"
            try:
                ch = int(chan or 0)
            except ValueError:
                ch = 0
            return self.s.send_text(msg, to, ch)
        if cmd == "pos":
            return self.s.send_position()
        if cmd == "read" or cmd.startswith("read "):
            self.s.mark_read(cmd[5:].strip())
            self.s.write_files(self.a.max_age)
            return True, "ok"
        if cmd.startswith("thread "):
            rows = self.s.thread(cmd[7:].strip())
            write_atomic(os.path.join(self.a.run, "thread"), "".join(
                "%s|%d|%s|%s|%s|%s\n" % (c["mid"], c["t"], c["dir"],
                                         clean("me" if c["dir"] == "out" else (c.get("from") or c["from_id"]), 24),
                                         c.get("status", ""), clean(c["text"], 400)) for c in rows))
            return True, "%d" % len(rows)
        if cmd.startswith("del "):
            f = cmd.split(None, 2)
            ok, msg = self.s.delete_chat(f[1] if len(f) > 1 else "", f[2] if len(f) > 2 else "")
            self.s.write_files(self.a.max_age)
            return ok, msg
        kv = {}
        for ln in lines[1:]:
            k, sep, v = ln.partition("=")
            if sep:
                kv[k.strip()] = v
        if cmd == "radio":                       # RUN/radio for the Pager menus (no secrets)
            r = self.s.radio_view()
            out = ["%s=%s" % (k, ("set" if v else "") if isinstance(v, bool) and k.endswith(("psk", "password")) else
                              (int(v) if isinstance(v, bool) else v)) for k, v in sorted(r["values"].items())]
            out += ["owner.long=%s" % r["owner"]["long"], "owner.short=%s" % r["owner"]["short"],
                    "firmware=%s" % r["metadata"]["firmware"], "hw=%s" % r["metadata"]["hw"]]
            write_atomic(os.path.join(self.a.run, "radio"), "\n".join(clean(x, 120) for x in out) + "\n")
            ch = []
            for d in r["settings"]:
                for num, name in d.get("choices", []):
                    ch.append("%s|%s|%s" % (d["key"], num, name))
            write_atomic(os.path.join(self.a.run, "choices"), "\n".join(ch) + "\n")
            return (True, "ok") if r["values"] else (False, "the radio has not sent its settings yet")
        if cmd == "set":
            return self.s.set_radio(kv)
        if cmd == "owner":
            return self.s.set_owner(kv.get("long", ""), kv.get("short", ""))
        if cmd == "reboot":
            return self.s.reboot_radio()
        if cmd == "cfg":                         # payload.sh already saved these: use them now
            self.s.set_cfg(kv, persist=False)
            return True, "ok"
        if cmd.startswith(("trace ", "reqpos ", "fav ", "node ", "trace_result ")):
            f = cmd.split()
            num = self.s.node_num(f[1]) if len(f) > 1 else None
            if f[0] == "trace":
                return self.s.traceroute(num)
            if f[0] == "trace_result":
                t = self.s.trace_text(num)
                return (True, t) if t else (False, "no traceroute yet")
            if f[0] == "reqpos":
                return self.s.request_position(num)
            if f[0] == "fav":
                return self.s.favorite(num, len(f) > 2 and f[2] == "1")
            return self.node_details(num)
        if cmd == "share":
            url = self.s.share_url()
            if not url:
                return False, "no channels yet"
            write_atomic(os.path.join(self.a.run, "share"), url + "\n")
            return True, "ok"
        if cmd == "bridge":
            b = self.s.bridge.info() if self.s.bridge else {"status": "off"}
            if not b.get("on"):
                return True, "off"
            return True, "%s%s - sent %d, from TAK %d - %s" % (b["status"], (": " + b["error"]) if b.get("error") else "",
                                                               b.get("sent", 0), b.get("received", 0), b.get("chat", ""))
        if cmd == "sigint":
            st = self.s.sig.stats(self.s.name_of)
            sc = self.scan
            out = ["Packets: %d since %s, last minute %d" % (st["total"], time.strftime("%H:%M", time.localtime(st["since"])),
                                                              st["per_min"][-1] if st["per_min"] else 0),
                   "Types: " + ", ".join("%s %d" % kv for kv in st["ports"][:5])]
            for n in st["nodes"][:8]:
                out.append("%s: %d pkts, RSSI %s, SNR %s%s" % (n["name"][:16], n["packets"],
                                                               "-" if n["rssi"] is None else n["rssi"],
                                                               "-" if n["snr"] is None else n["snr"],
                                                               ", %d encrypted" % n["enc"] if n["enc"] else ""))
            if sc.get("running"):
                out.append("Preset scan: %s (%d/%d)" % (sc.get("now", ""), len(sc.get("results", [])), len(sc.get("presets", []))))
            for r in sc.get("results", []):
                out.append("  %s: %s" % (r["preset"], r.get("error") or "%d pkts, %d nodes" % (r["packets"], r["nodes"])))
            write_atomic(os.path.join(self.a.run, "sigint"), "\n".join(clean(x, 120) for x in out) + "\n")
            return True, "ok"
        if cmd == "export":
            stamp = time.strftime("%Y%m%d-%H%M%S")
            try:
                os.makedirs(self.a.loot, exist_ok=True)
                with open(os.path.join(self.a.loot, "capture_%s.pcap" % stamp), "wb") as fh:
                    fh.write(self.s.sig.pcap())
                write_atomic(os.path.join(self.a.loot, "capture_%s.csv" % stamp), self.s.sig.csv())
            except OSError as e:
                return False, str(e)[:80]
            return True, "capture_%s.pcap / .csv (%d packets)" % (stamp, len(self.s.sig.packets))
        if cmd.startswith("scan"):
            f = cmd.split()
            if len(f) > 1 and f[1] == "stop":
                return self.stop_scan()
            return self.start_scan(None, int(f[1]) if len(f) > 1 and f[1].isdigit() else 60)
        return False, "unknown command"

    def node_details(self, num):
        """RUN/node: details of one node for the Pager, one line each."""
        rows = [r for r in self.s.node_rows() if r["num"] == num]
        if not rows:
            return False, "node not found"
        r = rows[0]
        st = self.s.sig.nodes.get(num, {})

        def age(v):
            if v is None:
                return "-"
            return "%ds" % v if v < 60 else "%dm" % (v // 60) if v < 3600 else "%dh" % (v // 3600) if v < 86400 else "%dd" % (v // 86400)
        out = ["%s (%s) %s" % (r["long"] or r["id"], r["short"] or "-", r["id"]),
               "Hardware: %s  Role: %s" % (r["hw"] or "?", r["role"] or "?"),
               "Heard %s ago  SNR %s  Hops %s%s" % (age(r["age_s"]), "-" if r["snr"] is None else r["snr"],
                                                   "-" if r["hops"] is None else r["hops"], "  via MQTT" if r["mqtt"] else ""),
               "Battery %s  Position %s" % ("-" if r["battery"] is None else ("PWR" if r["battery"] > 100 else "%s%%" % r["battery"]),
                                            "none" if r["lat"] is None else "%.5f, %.5f (%s old)" % (r["lat"], r["lon"], age(r["pos_age"]))),
               "Packets heard: %d  RSSI %s dBm%s" % (st.get("packets", 0), "-" if st.get("rssi") is None else st["rssi"],
                                                     "  Favorite" if r["fav"] else "")]
        tr = self.s.trace_text(num)
        if tr:
            out.append("Traceroute: " + tr)
        write_atomic(os.path.join(self.a.run, "node"), "\n".join(clean(x, 200) for x in out) + "\n")
        return True, "ok"

    # ---- preset scan: listen on each modem preset for a while, then put the radio back
    def start_scan(self, presets=None, dwell=60):
        s = self.s
        if self.scan.get("running"):
            return False, "a scan is running"
        ok, msg = s.can_admin()
        if not ok:
            return ok, msg
        lora = s.sections.get((radiocfg.CFG, radiocfg.LORA))
        if not lora:
            return False, "the radio has not sent its LoRa settings"
        presets = [p for p in (presets or mp.COMMON_PRESETS) if p in mp.PRESETS]
        dwell = max(20, min(600, int(dwell)))
        self.scan = {"running": True, "stop": False, "presets": presets, "dwell": dwell, "results": [],
                     "now": "", "started": now(), "orig": mp.PRESETS.get(radiocfg.current(s.sections).get("lora.modem_preset", 0), "?")}
        try:
            os.makedirs(self.a.loot, exist_ok=True)
            write_atomic(os.path.join(self.a.loot, ".scan_restore"), lora.hex() + "\n")
        except OSError:
            pass
        threading.Thread(target=self._scan, args=(lora, presets, dwell), daemon=True).start()
        return True, "preset scan started: %d presets, %d s each" % (len(presets), dwell)

    def stop_scan(self):
        if not self.scan.get("running"):
            return False, "no scan running"
        self.scan["stop"] = True
        return True, "stopping - the radio goes back to its own settings"

    def _wait_reconnect(self, before, timeout=120):
        end = time.time() + timeout
        while time.time() < end and not self.stop.is_set():
            if self.connects > before and self.s.link == "connected":
                return True
            time.sleep(0.5)
        return False

    def _scan(self, orig_lora, presets, dwell):
        s, sc = self.s, self.scan
        try:
            for p in presets:
                if sc["stop"] or self.stop.is_set():
                    break
                sc["now"] = mp.PRESETS[p]
                s.touch()
                before = self.connects
                ok, msg = s.set_radio({"lora.modem_preset": p})
                if not ok:
                    sc["results"].append({"preset": mp.PRESETS[p], "error": msg})
                    continue
                if msg != "nothing changed" and not self._wait_reconnect(before):
                    sc["results"].append({"preset": mp.PRESETS[p], "error": "radio did not come back"})
                    continue
                base_n = s.sig.total
                t0 = time.time()
                while time.time() - t0 < dwell and not sc["stop"] and not self.stop.is_set():
                    time.sleep(0.5)
                with s.sig.lock:
                    got = [r for r in s.sig.packets if r["t"] >= t0 and not r["mqtt"]]
                rssi = [r["rssi"] for r in got if r["rssi"] is not None]
                sc["results"].append({"preset": mp.PRESETS[p], "packets": s.sig.total - base_n,
                                      "nodes": len(set(r["from"] for r in got)),
                                      "encrypted": sum(1 for r in got if r["port"] == "ENCRYPTED"),
                                      "best_rssi": max(rssi) if rssi else None,
                                      "seconds": int(time.time() - t0)})
                s.touch()
        finally:
            sc["now"] = "restoring"
            s.touch()
            # put the radio back exactly as it was (wait for the link if a reboot is still going on)
            end = time.time() + 120
            while s.link != "connected" and time.time() < end and not self.stop.is_set():
                time.sleep(0.5)
            if s.sections.get((radiocfg.CFG, radiocfg.LORA)) != orig_lora and s.my_num is not None:
                before = self.connects
                s.queue(mp.admin_packet(s.my_num, mp.adm_begin()))
                s.queue(mp.admin_packet(s.my_num, mp.adm_set_config(radiocfg.LORA, orig_lora)))
                s.queue(mp.admin_packet(s.my_num, mp.adm_commit()))
                with s.lock:
                    s.sections[(radiocfg.CFG, radiocfg.LORA)] = orig_lora
                self._wait_reconnect(before)
            try:
                os.remove(os.path.join(self.a.loot, ".scan_restore"))
            except OSError:
                pass
            sc["running"], sc["now"] = False, ""
            s.note("Preset scan finished - radio back on %s" % sc.get("orig", "its own preset"))

    def poll_outbox(self):
        for path in sorted(glob.glob(os.path.join(self.a.run, "outbox", "*.cmd"))):
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    body = fh.read()
                os.remove(path)
            except OSError:
                continue
            ok, msg = self.handle_cmd(body)
            try:
                write_atomic(path[:-4] + ".res", ("ok|" if ok else "err|") + msg + "\n")
            except OSError:
                pass

    def pos_interval(self):
        v = first_line(os.path.join(self.a.run, "pos_interval"))
        try:
            return int(v)
        except ValueError:
            return self.a.pos_interval

    # ---- packet log for troubleshooting: RUN/packets.log, last ~400 packets
    def log_packet(self, rec, pkt):
        """RUN/packets.log: every packet the radio passes on (last ~400), with RSSI / SNR."""
        line = self.s.sig.line(rec)
        d = pkt.get("decoded")
        if d and d["portnum"] == mp.PORT_TEXT:
            line += " %r" % d["payload"][:40].decode("utf-8", "replace")
        path = os.path.join(self.a.run, "packets.log")
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            self.pkt_lines = getattr(self, "pkt_lines", 0) + 1
            if self.pkt_lines > 500:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    keep = fh.readlines()[-400:]
                write_atomic(path, "".join(keep))
                self.pkt_lines = 400
        except OSError:
            pass

    # ---- connection
    def connect(self):
        st = mp.open_stream(self.a.conn, self.a.host, self.a.port, self.a.dev, timeout=15)
        nonce = random.randint(1, 0x7FFFFFFF)
        if nonce in (69420, 69421):              # reserved "special" nonces in the firmware
            nonce += 2
        st.send(mp.want_config(nonce))
        deadline = time.time() + 60
        while time.time() < deadline:
            kind, v = mp.dec_fromradio(st.read())
            self.dispatch(kind, v)
            if kind == "config_complete" and v == nonce:
                return st
        st.close()
        raise ConnectionError("no config from meshtasticd")

    def dispatch(self, kind, v):
        s = self.s
        if kind == "my_info":
            with s.lock:
                s.my_num = v
                s.touch()
        elif kind == "node_info":
            raw = v.pop("user_raw", None)
            if raw is not None and v.get("num") == s.my_num:
                s.owner_raw = raw
            s.update_node(v)
        elif kind == "channel":
            with s.lock:
                s.channels_all[v["index"]] = v
                if v["role"] != 0:
                    s.channels[v["index"]] = v
                else:
                    s.channels.pop(v["index"], None)
                s.touch()
        elif kind == "metadata":
            s.metadata = v
        elif kind == "module_config":
            with s.lock:
                s.sections[(radiocfg.MOD, v[0])] = v[1]
        elif kind == "config":
            if "_section" in v:
                with s.lock:
                    s.sections[(radiocfg.CFG, v["_section"])] = v["_raw"]
            with s.lock:
                if "region" in v:
                    s.region = v["region"]
                if v.get("hop_limit"):
                    s.hop_limit = v["hop_limit"]
                s.touch()
        elif kind == "packet":
            self.log_packet(s.sig.add(v), v)
            s.on_packet(v)
        elif kind == "rebooted":
            raise ConnectionError("radio rebooted")

    def session(self):
        s = self.s
        st = self.connect()
        self.stream = st
        self.connects += 1
        raw = getattr(self, "pending_restore", None)
        if raw and s.my_num is not None:
            self.pending_restore = None
            if s.sections.get((radiocfg.CFG, radiocfg.LORA)) != raw:
                for adm in (mp.adm_begin(), mp.adm_set_config(radiocfg.LORA, raw), mp.adm_commit()):
                    s.queue(mp.admin_packet(s.my_num, adm))
                s.note("Put the radio back on its LoRa settings from before an unfinished preset scan")
            try:
                os.remove(os.path.join(self.a.loot, ".scan_restore"))
            except OSError:
                pass
        s.link, s.error = "connected", ""
        s.touch()
        st.settimeout(0.5)
        last_hb = last_files = time.time()
        while not self.stop.is_set() and not self.kick.is_set():
            try:
                kind, v = mp.dec_fromradio(st.read())
                self.dispatch(kind, v)
            except socket.timeout:
                pass
            except ValueError as e:
                sys.stderr.write("bad frame skipped: %s\n" % e)
            with s.lock:
                q, s.outq = s.outq, []
            for payload in q:
                st.send(payload)
            self.poll_outbox()
            t = time.time()
            if t - last_hb > HEARTBEAT_SEC:
                st.send(mp.heartbeat())
                last_hb = t
            iv = self.pos_interval()
            if iv > 0 and t - s.last_pos >= iv and s.pos_chan() is not None and s.gps():
                s.send_position()
            if s.dirty or t - last_files > 15:
                if t - last_files >= FILES_SEC or not s.dirty:
                    s.write_files(self.a.max_age)
                    last_files = t
        st.close()

    def run(self):
        s = self.s
        if self.a.setup:                          # setup mode: only the web console
            os.makedirs(self.a.run, exist_ok=True)
            s.link, s.error = "setup", ""
            self.start_web()
            s.write_files(self.a.max_age)
            while not self.stop.is_set():
                time.sleep(0.5)
            return
        # a restart (for example turning the web console on) keeps the position timer
        try:
            s.last_pos = int(first_line(os.path.join(self.a.run, "status")).split("|")[6])
        except (IndexError, ValueError):
            pass
        os.makedirs(os.path.join(self.a.run, "outbox"), exist_ok=True)
        os.makedirs(os.path.join(self.a.run, "tracks.d"), exist_ok=True)
        s.load_cfg()
        s.bridge = takbridge.Bridge(s, lambda: s.cfg, [os.path.realpath(d) for d in self.a.certs.split(",") if d])
        threading.Thread(target=s.bridge.run, daemon=True).start()
        self.check_scan_restore()
        try:
            n = s.load_history()
            if n:
                sys.stderr.write("chat: %d messages from the last %d days\n" % (n, HISTORY_DAYS))
        except OSError as e:
            sys.stderr.write("chat history not loaded: %s\n" % e)
        if self.a.web_port:
            self.start_web()
        delay = 3
        while not self.stop.is_set():
            s.link = "connecting"
            s.touch()
            try:
                s.write_files(self.a.max_age)
            except OSError:
                pass
            if self.kick.is_set():                     # switch(): new radio, start the retry timer over
                self.kick.clear()
                delay = 3
            before = self.connects
            try:
                self.session()
                delay = 3
            except Exception as e:  # any failure: report it and retry, never take the web console down
                if self.kick.is_set():                 # switch(): closed on purpose, reconnect with the new radio
                    continue
                if self.connects > before:             # it was connected (e.g. the radio restarted): retry soon
                    delay = 3
                s.link, s.error = "disconnected", (str(e) or type(e).__name__)[:120]
                with s.lock:
                    s.pending.clear()
                s.touch()
                try:
                    s.write_files(self.a.max_age)
                except OSError:
                    pass
                sys.stderr.write("mesh: %s\n" % e)
                # keep answering payload.sh while waiting to reconnect
                end = time.time() + delay
                while time.time() < end and not self.stop.is_set() and not self.kick.is_set():
                    self.poll_outbox()
                    time.sleep(0.5)
                delay = min(30, delay * 2)
            finally:
                self.stream = None

    def check_scan_restore(self):
        """A preset scan was cut off (PagerMesh stopped): put the radio's LoRa settings back."""
        path = os.path.join(self.a.loot, ".scan_restore")
        h = first_line(path)
        if not h:
            return
        try:
            raw = bytes.fromhex(h)
        except ValueError:
            return
        self.pending_restore = raw

    def start_web(self):
        try:
            sys.path.insert(0, os.path.realpath(self.a.web_dir))
            import pagermesh_web as web
        except ImportError as e:
            sys.stderr.write("web console not available: %s\n" % e)
            write_atomic(os.path.join(self.a.run, "web"), "err\n")
            return
        web.PROBE = probe
        web.SWITCH = self.switch
        web.SERVICE = self
        ok = web.start(self.s, self.a)
        if not ok:
            sys.stderr.write("web console did not start\n")
        try:
            write_atomic(os.path.join(self.a.run, "web"), "ok\n" if ok else "err\n")
        except OSError:
            pass


def probe(conn, host="127.0.0.1", port=4403, dev="", timeout=20):
    """Connection test for setup: (ok, message). Opens its own connection."""
    a = argparse.Namespace(conn=conn, host=host, port=port, dev=dev, run="/tmp", loot="/tmp",
                           max_age=7200, pos_interval=0)
    svc = Service(a)
    try:
        st = svc.connect()
    except socket.timeout:
        return False, "no answer from the radio"
    except ConnectionRefusedError:
        return False, "%s:%d refused the connection - is Wi-Fi (and its TCP API) on in the radio?" % (host, port)
    except OSError as e:
        if conn == "wifi" and e.errno in (101, 110, 113):
            return False, "cannot reach %s - is the Pager on the same network as the radio?" % host
        if conn == "wifi" and isinstance(e, socket.gaierror):
            return False, "unknown host name %s" % host
        if conn == "usb" and e.errno in (13, 16):
            return False, "%s is in use or not allowed (another program has it open?)" % dev
        return False, (e.strerror or str(e))[:120]
    except Exception as e:  # noqa: BLE001 - shown to the user as the test result
        return False, (str(e) or type(e).__name__)[:120]
    st.close()
    s = svc.s
    me = s.me().get("user", {})
    region = mp.REGIONS.get(s.region, "?")
    msg = "%s %s, %d nodes, region %s" % (me.get("long_name") or "node", mp.node_id(s.my_num),
                                         max(0, len(s.nodes) - 1), region)
    if region == "UNSET":
        msg += " - set the region in Radio settings"
    return True, msg


def one_shot(a):
    """--check / --nodes: connect, read the node DB, disconnect."""
    svc = Service(a)
    try:
        st = svc.connect()
    except Exception as e:  # noqa: BLE001
        print("FAIL %s" % (str(e) or type(e).__name__))
        return 1
    st.close()
    s = svc.s
    if a.check:
        me = s.me().get("user", {})
        print("OK %s %s (%s) nodes=%d region=%s" % (
            mp.node_id(s.my_num), me.get("long_name", "?"), me.get("short_name", "?"), len(s.nodes),
            mp.REGIONS.get(s.region, "?")))
    if a.nodes:
        rows = s.node_rows()
        if a.json:
            print(json.dumps(rows))
        else:
            for r in rows:
                print("|".join("" if r[k] is None else str(r[k]) for k in
                               ("id", "short", "long", "me", "range_m", "bearing", "battery", "snr",
                                "hops", "age_s", "lat", "lon")))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="PagerMesh mesh service")
    ap.add_argument("--conn", default="mod", choices=("mod", "wifi", "usb"),
                    help="mod = meshtasticd on the Pager (Glytch Mesh Mod), wifi = radio's TCP API, usb = radio's serial API")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4403)
    ap.add_argument("--dev", default="", help="USB radio serial device (usb)")
    ap.add_argument("--setup", action="store_true")
    ap.add_argument("--gps-dev", default="", help="serial device used by the GPS (hidden from the USB radio list)")
    ap.add_argument("--run", default="/tmp/pagermesh")
    ap.add_argument("--loot", default="/root/loot/PagerMesh")
    ap.add_argument("--max-age", type=int, default=7200, help="seconds before a node drops off the map")
    ap.add_argument("--pos-interval", type=int, default=900, help="seconds between position broadcasts (0 = off)")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--nodes", action="store_true")
    ap.add_argument("--json", action="store_true")
    # web console
    ap.add_argument("--web-port", type=int, default=0)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--auth", default="")
    ap.add_argument("--web-dir", default=os.path.join(HERE, "..", "web"))
    ap.add_argument("--map-dir", default=os.path.join(HERE, "..", "map"))
    ap.add_argument("--tiles", default=os.path.join(HERE, "..", "tiles"))
    ap.add_argument("--map-source", default="")
    ap.add_argument("--quick", default="", help="quick messages, | separated (web console buttons)")
    ap.add_argument("--certs", default=os.path.join(HERE, "..", "certs") + "," +
                    os.path.join(HERE, "..", "..", "PagerTAK", "certs"),
                    help="TAK client certificate folders (client.pem, ca.pem), first one with client.pem wins")
    ap.add_argument("--hash-password", action="store_true")
    a = ap.parse_args(argv)

    if a.hash_password:
        sys.path.insert(0, os.path.realpath(a.web_dir))
        import pagermesh_web as web
        pw = sys.stdin.readline().rstrip("\r\n")
        if len(pw) < 8:
            print("ERROR password must be at least 8 characters", file=sys.stderr)
            return 2
        print(web.hash_password(pw))
        return 0
    if a.check or a.nodes:
        return one_shot(a)

    svc = Service(a)

    def stop(*_):
        svc.stop.set()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    svc.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
