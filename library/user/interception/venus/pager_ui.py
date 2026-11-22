#!/usr/bin/env python3
"""
pager_ui.py - VENUS on-device flytrap UI (WiFi Pineapple Pager).

Two screens:
  RECON  live AP list; A clones the selected SSID into a trap
  TRAP   spiderweb with one animated fly per captured client; A toggles the
         deauth lure, B drops the trap and returns to recon

The UI never touches the radios. It reads /tmp/venus_state.json (written by
venus.py) and appends commands to /tmp/venus_cmd.jsonl. Either process can
die without taking the other down.

Run headless on a development machine:
  python3 pager_ui.py --headless --sample --frames 3
"""

import argparse
import hashlib
import json
import math
import os
import signal
import subprocess
import sys
import time


HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "lib")
if LIB not in sys.path:
    sys.path.insert(0, LIB)

STATE = os.environ.get("VENUS_STATE", "/tmp/venus_state.json")
CMD = os.environ.get("VENUS_CMD", "/tmp/venus_cmd.jsonl")


def rgb(r, g, b):
    """RGB565, same encoding libpagerctl uses."""
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


# Palette
BLACK = 0x0000
WHITE = 0xFFFF
RED = rgb(255, 40, 56)
DARKRED = rgb(38, 0, 8)
GREEN = rgb(0, 240, 120)
DIM = rgb(0, 74, 44)
DIM2 = rgb(0, 34, 24)
CYAN = rgb(0, 210, 255)
AMBER = rgb(255, 176, 32)
MAGENTA = rgb(240, 60, 200)
GRAY = rgb(110, 120, 118)
DARK = rgb(0, 12, 10)
PANEL = rgb(0, 18, 14)
SEL = rgb(0, 62, 58)

CHIRP = "venus_catch:d=16,o=6,b=220:g6,c7,e7"
PING = "venus_ping:d=16,o=6,b=240:c7,e7"
ALARM = "venus_alarm:d=8,o=6,b=200:c7,c7,c7"
DOWN = "venus_down:d=8,o=5,b=160:e5,c5"

RTTTL_VIBRATE_ONLY = 2


# --------------------------------------------------------------------------- #
# State + commands
# --------------------------------------------------------------------------- #

def load_state(path=None):
    path = path or STATE
    try:
        with open(path, "r") as f:
            obj = json.load(f)
        if not isinstance(obj, dict):
            return None
        obj.setdefault("phase", "recon")
        obj.setdefault("aps", [])
        obj.setdefault("clients", [])
        obj.setdefault("counts", {})
        obj.setdefault("events", [])
        return obj
    except Exception:
        return None


def send_cmd(obj, path=None):
    path = path or CMD
    try:
        with open(path, "a") as f:
            f.write(json.dumps(obj, separators=(",", ":")) + "\n")
        return True
    except Exception:
        return False


def _hms(seconds):
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def _truncate(text, n):
    text = str(text or "")
    return text if len(text) <= n else text[: max(0, n - 2)] + ".."


def fly_geometry(mac, maxr):
    """Deterministic polar position for a MAC, so flies don't jump frames."""
    d = hashlib.sha1(mac.encode("utf-8", "ignore")).digest()
    ang = ((d[0] << 8) | d[1]) / 65535.0 * (2 * math.pi)
    rr = 0.30 + (((d[2] << 8) | d[3]) / 65535.0) * 0.62
    return ang, rr * maxr


def vendor_color(vendor, random_mac=False):
    if random_mac:
        return MAGENTA
    v = (vendor or "").lower()
    if any(k in v for k in ("espressif", "tuya", "iot", "realtek", "mediatek")):
        return AMBER
    if "apple" in v:
        return WHITE
    if any(k in v for k in ("samsung", "google", "amazon", "roku", "sonos")):
        return CYAN
    return GREEN


def rssi_bars(rssi):
    try:
        r = int(rssi)
    except Exception:
        return 0
    if r >= -50:
        return 4
    if r >= -62:
        return 3
    if r >= -74:
        return 2
    if r >= -85:
        return 1
    return 0


# --------------------------------------------------------------------------- #
# Headless pager stub (lets the renderer run on a dev machine)
# --------------------------------------------------------------------------- #

class FakePager:
    BTN_UP = 0x01
    BTN_DOWN = 0x02
    BTN_LEFT = 0x04
    BTN_RIGHT = 0x08
    BTN_A = 0x10
    BTN_B = 0x20
    BTN_POWER = 0x40
    EVENT_PRESS = 1
    EVENT_RELEASE = 2

    def __init__(self):
        self.width = 480
        self.height = 222
        self.frames = 0
        self.calls = 0

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def _n(self, *a, **k):
        self.calls += 1

    def init(self): self._n()
    def cleanup(self): self._n()
    def set_rotation(self, r): self._n()
    def clear(self, c=0): self._n()
    def flip(self): self.frames += 1
    def delay(self, ms): pass
    def get_ticks(self): return int(time.time() * 1000)
    def get_input_event(self): return None
    def peek_buttons(self): return 0
    def clear_input_events(self): self._n()
    def fill_rect(self, *a): self._n()
    def rect(self, *a): self._n()
    def hline(self, *a): self._n()
    def vline(self, *a): self._n()
    def line(self, *a): self._n()
    def circle(self, *a): self._n()
    def fill_circle(self, *a): self._n()
    def draw_text(self, *a): self._n()
    def draw_text_centered(self, *a): self._n()
    def draw_number(self, *a): self._n()
    def text_width(self, text, size=1):
        return len(str(text)) * 6 * size
    def play_rtttl(self, *a, **k): self._n()
    def stop_audio(self): self._n()
    def vibrate(self, ms=200): self._n()
    def vibrate_pattern(self, p): self._n()
    def led_rgb(self, *a): self._n()
    def led_dpad(self, *a): self._n()
    def led_all_off(self): self._n()
    def set_brightness(self, p): return 0
    def draw_image_scaled(self, *a): self._n()
    def load_image(self, *a): return None
    def free_image(self, *a): self._n()


# --------------------------------------------------------------------------- #
# UI
# --------------------------------------------------------------------------- #

class VenusUI:
    FPS_DELAY_MS = 66          # ~15 fps is plenty and leaves CPU for the engine
    DEBOUNCE_SEC = 2.5
    CATCH_FLASH_SEC = 1.4
    FLY_ENTER_SEC = 1.6

    def __init__(self, pager):
        self.p = pager
        self.W = pager.width
        self.H = pager.height
        self.state = None
        self.screen = "recon"
        self.sel_ap = 0
        self.sel_client = 0
        self.known_macs = set()
        self.fly_seen = {}
        self.baselined = False
        self.catch_until = 0.0
        self.catch_label = ""
        self.last_portal = 0
        self.last_submit = 0
        self.phase_prev = None
        self.started = time.time()
        self.done = False
        self.lure_local = False
        self.lure_sent_at = 0.0
        self.quit_sent_at = 0.0
        self.status = ""
        self.status_until = 0.0
        self.repeat = {}
        self.waiting_engine = False

    # -- feedback ---------------------------------------------------------- #
    def note(self, text, secs=2.0):
        self.status = text
        self.status_until = time.time() + secs

    def play(self, melody, vibrate=0, led=None):
        try:
            self.p.play_rtttl(melody)
        except Exception:
            pass
        if vibrate:
            try:
                self.p.vibrate(vibrate)
            except Exception:
                pass
        if led:
            try:
                for direction in ("up", "down", "left", "right"):
                    self.p.led_rgb(direction, *led)
            except Exception:
                pass

    def led_idle(self):
        try:
            if self.screen == "trap":
                if self.lure_local:
                    pulse = 90 + int(120 * (0.5 + 0.5 * math.sin(time.time() * 6)))
                    for d in ("up", "down", "left", "right"):
                        self.p.led_rgb(d, pulse, 0, 0)
                else:
                    for d in ("up", "down", "left", "right"):
                        self.p.led_rgb(d, 0, 42, 22)
            else:
                for d in ("up", "down", "left", "right"):
                    self.p.led_rgb(d, 0, 20, 34)
        except Exception:
            pass

    # -- state sync -------------------------------------------------------- #
    def sync(self):
        st = load_state()
        if st is None:
            self.waiting_engine = True
            return
        # Heartbeat. The engine writes state ~every 0.4 s while trapping, but
        # a recon `iw scan` can block the loop for many seconds, so only
        # enforce a tight deadline once the AP is up.
        try:
            age = max(0.0, time.time() - float(st.get("ts") or 0))
        except Exception:
            age = 0.0
        limit = 10.0 if st.get("phase") in ("trap", "arming") else 45.0
        if st.get("phase") != "stopped" and st.get("ts") and age > limit:
            self.waiting_engine = True
            return
        self.waiting_engine = False
        self.state = st
        phase = st.get("phase", "recon")
        if phase != self.phase_prev:
            self.on_phase_change(self.phase_prev, phase)
            self.phase_prev = phase

        if self.screen == "recon":
            aps = st.get("aps") or []
            if aps:
                self.sel_ap = max(0, min(self.sel_ap, len(aps) - 1))
            else:
                self.sel_ap = 0
        if self.screen == "trap":
            clients = st.get("clients") or []
            if clients:
                self.sel_client = max(0, min(self.sel_client, len(clients) - 1))
            else:
                self.sel_client = 0

        counts = st.get("counts") or {}
        portal = int(counts.get("portal_hits", 0) or 0)
        submit = int(counts.get("submissions", 0) or 0)
        if self.baselined and portal > self.last_portal:
            self.play(PING, vibrate=90, led=(0, 90, 255))
            self.note("PORTAL HIT")
        if self.baselined and submit > self.last_submit:
            self.play(CHIRP, vibrate=220, led=(0, 160, 255))
            self.note("FORM CAPTURED")
        self.last_portal = max(self.last_portal, portal)
        self.last_submit = max(self.last_submit, submit)

        # The engine may refuse the lure (no second radio / no aireplay-ng).
        if phase == "trap" and time.time() - self.lure_sent_at > 2.0:
            self.lure_local = bool(st.get("lure"))

        # New flies (only after the trap screen has baselined once).
        if self.screen == "trap":
            clients = st.get("clients") or []
            current = set()
            for c in clients:
                mac = c.get("mac", "")
                current.add(mac)
                if mac not in self.fly_seen:
                    self.fly_seen[mac] = time.time() if self.baselined else time.time() - 30
                if self.baselined and mac not in self.known_macs:
                    self.catch_until = time.time() + self.CATCH_FLASH_SEC
                    self.catch_label = f"{_truncate(c.get('vendor','Unknown'), 16)}"
                    self.play(CHIRP, vibrate=180, led=(255, 20, 20))
                    self.note("CAUGHT " + mac[-8:].upper())
            self.known_macs = current

    def on_phase_change(self, old, new):
        if new == "trap" and old != "trap":
            self.screen = "trap"
            self.sel_client = 0
            self.baselined = False
            self.fly_seen = {}
            self.known_macs = set()
            self.lure_local = bool((self.state or {}).get("lure"))
            self.play(CHIRP, vibrate=120, led=(0, 200, 90))
            self.note("TRAP ARMED")
        elif new in ("recon", "stopped") and old == "trap":
            if new == "recon":
                self.screen = "recon"
                self.baselined = False
                self.note("TRAP DOWN")
                self.play(DOWN, vibrate=80, led=(0, 60, 40))
            else:
                self.screen = "recon"
                self.done = True
        elif new == "arming":
            self.note("ARMING TRAP...")
        elif new == "recon" and old == "arming":
            # hostapd/DHCP failed to come up; the engine rolled back.
            self.screen = "recon"
            self.baselined = False
            self.note("TRAP FAILED")
            self.play(DOWN, vibrate=140, led=(120, 0, 0))
        elif new == "recon" and old in (None, "stopped"):
            self.screen = "recon"

        if new == "trap":
            # First trap frame: everything currently on the web is "already
            # there", so a UI restart doesn't fire a dozen catch sounds.
            st = self.state or {}
            for c in (st.get("clients") or []):
                mac = c.get("mac", "")
                self.known_macs.add(mac)
                self.fly_seen.setdefault(mac, time.time() - 30)
            self.baselined = True
            self.last_portal = int((st.get("counts") or {}).get("portal_hits", 0) or 0)
            self.last_submit = int((st.get("counts") or {}).get("submissions", 0) or 0)

    # -- input ------------------------------------------------------------- #
    def handle_input(self):
        t = time.time()
        while True:
            try:
                ev = self.p.get_input_event()
            except Exception:
                ev = None
            if not ev:
                break
            button, etype, _ = ev
            if etype != self.p.EVENT_PRESS:
                continue
            if t - self.started < self.DEBOUNCE_SEC and button in (self.p.BTN_B, self.p.BTN_A):
                # stale event from the button that launched the payload
                self.p.clear_input_events()
                continue
            self.on_button(button)

    def move(self, delta):
        t = time.time()
        if self.screen == "recon":
            aps = (self.state or {}).get("aps") or []
            if aps:
                self.sel_ap = (self.sel_ap + delta) % len(aps)
        else:
            clients = (self.state or {}).get("clients") or []
            if clients:
                self.sel_client = (self.sel_client + delta) % len(clients)

    def on_button(self, button):
        p = self.p
        if self.waiting_engine:
            if button == p.BTN_B:
                self.quit()
            return
        if button in (p.BTN_UP, p.BTN_DOWN):
            self.move(-1 if button == p.BTN_UP else 1)
            return
        if button == p.BTN_A:
            if self.screen == "recon":
                self.start_trap()
            else:
                self.toggle_lure()
            return
        if button == p.BTN_B:
            if self.screen == "trap":
                self.drop_trap()
            else:
                self.quit()

    def start_trap(self):
        aps = (self.state or {}).get("aps") or []
        if not aps:
            self.note("NO TARGETS")
            return
        ap = dict(aps[self.sel_ap])
        if not ap.get("ssid"):
            self.note("HIDDEN SSID - SKIP")
            return
        send_cmd({"cmd": "trap", "ap": ap})
        self.screen = "trap"
        self.baselined = False
        self.fly_seen = {}
        self.known_macs = set()
        self.catch_until = 0.0
        self.sel_client = 0
        self.note("TRAPPING " + _truncate(ap.get("ssid", ""), 18), 3)

    def toggle_lure(self):
        st = self.state or {}
        if not st.get("lure_available"):
            self.note("LURE UNAVAILABLE")
            return
        self.lure_local = not bool(st.get("lure"))
        send_cmd({"cmd": "lure", "on": self.lure_local})
        self.lure_sent_at = time.time()
        self.note("LURE " + ("ON" if self.lure_local else "OFF"))
        self.play(PING if self.lure_local else DOWN,
                  vibrate=90, led=(255, 30, 30) if self.lure_local else (0, 60, 40))

    def drop_trap(self):
        send_cmd({"cmd": "untrap"})
        self.screen = "recon"
        self.baselined = False
        self.known_macs = set()
        self.fly_seen = {}
        self.catch_until = 0.0
        self.note("DROPPING TRAP")

    def quit(self):
        if self.quit_sent_at:
            return
        self.quit_sent_at = time.time()
        send_cmd({"cmd": "shutdown"})
        self.note("SHUTTING DOWN")

    # -- drawing ----------------------------------------------------------- #
    def draw(self):
        p = self.p
        t = time.time()
        p.clear(BLACK)
        st = self.state

        if self.waiting_engine or st is None:
            self.draw_header("VENUS", "WAITING")
            p.draw_text_centered(94, "WAITING FOR ENGINE", CYAN, 2)
            p.draw_text_centered(122, _truncate(STATE, 44), GRAY, 1)
            self.draw_footer("[B] QUIT", "")
            p.flip()
            return

        phase = st.get("phase", "recon")
        if self.screen == "trap" and phase in ("arming",):
            self.draw_arming()
            p.flip()
            return
        if self.screen == "trap" and phase == "trap":
            self.draw_trap(t)
        else:
            if phase == "trap" and self.screen != "trap":
                # engine is trapped but UI went back: reflect reality
                self.screen = "trap"
                self.draw_trap(t)
            else:
                self.draw_recon(t)
        self.led_idle()
        p.flip()

    def draw_header(self, left, right, accent=GREEN):
        p = self.p
        p.fill_rect(0, 0, self.W, 18, DARKRED)
        p.hline(0, 18, self.W, DIM)
        p.draw_text(6, 5, left, accent, 1)
        if right:
            w = p.text_width(right, 1)
            p.draw_text(self.W - w - 6, 5, right, GRAY, 1)

    def draw_footer(self, left, right):
        p = self.p
        p.fill_rect(0, self.H - 18, self.W, 18, DARK)
        p.hline(0, self.H - 18, self.W, DIM)
        p.draw_text(6, self.H - 13, left, GRAY, 1)
        if right:
            w = p.text_width(right, 1)
            p.draw_text(self.W - w - 6, self.H - 13, right, RED, 1)
        if self.status and time.time() < self.status_until:
            w = p.text_width(self.status, 1)
            p.draw_text((self.W - w) // 2, self.H - 13, self.status, AMBER, 1)

    def draw_recon(self, t):
        p = self.p
        st = self.state
        aps = st.get("aps") or []
        self.draw_header("VENUS // SELECT TARGET", f"{len(aps)} AP", CYAN)

        if not aps:
            dots = "." * (1 + int(t * 2) % 3)
            p.draw_text_centered(92, "SCANNING" + dots, GREEN, 2)
            p.draw_text_centered(120, f"{st.get('ap_iface') or '?'}  /  "
                                      f"{st.get('recon_iface') or '?'}", GRAY, 1)
            p.draw_text_centered(140, "walk closer or wait for the sweep", DIM, 1)
            self.draw_footer("[B] QUIT", "")
            return

        y0, row_h, rows = 23, 21, 8
        start = 0
        if self.sel_ap >= rows:
            start = self.sel_ap - rows + 1
        for i in range(start, min(len(aps), start + rows)):
            ap = aps[i]
            y = y0 + (i - start) * row_h
            selected = i == self.sel_ap
            if selected:
                p.fill_rect(2, y - 1, self.W - 4, 19, SEL)
                p.fill_rect(2, y - 1, 3, 19, CYAN)
            enc = ap.get("enc", "?")
            enc_color = {"OPN": AMBER, "WEP": RED, "WPA": AMBER,
                         "WPA2": GREEN, "WPA3": CYAN}.get(enc, GRAY)
            p.draw_text(10, y + 2, _truncate(ap.get("ssid", "?"), 30),
                        WHITE if selected else GREEN, 1)
            ch = ap.get("channel", "?")
            band = ap.get("band", "")
            p.draw_text(248, y + 2, f"ch{ch}", GRAY, 1)
            p.draw_text(286, y + 2, f"{band}G", DIM, 1)
            bars = rssi_bars(ap.get("rssi"))
            for b in range(4):
                bx = 320 + b * 8
                bh = 3 + b * 3
                color = GREEN if b < bars else DIM2
                p.fill_rect(bx, y + 15 - bh, 6, bh, color)
            rssi = ap.get("rssi")
            rtxt = f"{rssi:>4}" if isinstance(rssi, int) else "  --"
            p.draw_text(360, y + 2, rtxt, GRAY, 1)
            p.draw_text(400, y + 2, enc, enc_color, 1)
            if selected:
                p.draw_text(452, y + 2, ">", CYAN, 1)

        sel = aps[self.sel_ap] if aps else None
        left = "[UP/DN] SELECT   [A] TRAP"
        right = "[B] QUIT"
        if sel:
            left = f"[A] TRAP {_truncate(sel.get('ssid',''), 14)}   [UP/DN] SELECT"
        self.draw_footer(left, right)

    def draw_arming(self):
        p = self.p
        st = self.state or {}
        self.draw_header("VENUS // ARMING", "", AMBER)
        dots = "." * (1 + int(time.time() * 3) % 3)
        p.draw_text_centered(82, "SPINNING THE WEB" + dots, AMBER, 2)
        p.draw_text_centered(112, _truncate(st.get("ssid") or "", 34), WHITE, 1)
        p.draw_text_centered(130, f"ch{st.get('channel')}  {st.get('ap_iface') or ''}", GRAY, 1)
        self.draw_footer("[B] ABORT", "")

    def _web(self, cx, cy, maxr):
        p = self.p
        for frac in (0.20, 0.42, 0.64, 0.84, 1.0):
            p.circle(cx, cy, int(maxr * frac), DIM)
        for i in range(12):
            a = i * math.pi / 6.0
            p.line(cx, cy, int(cx + maxr * math.cos(a)),
                   int(cy + maxr * math.sin(a)), DIM)
        # A few cross-strands for texture.
        for i in range(12):
            a1 = i * math.pi / 6.0
            a2 = (i + 1) * math.pi / 6.0
            r1, r2 = maxr * 0.42, maxr * 0.64
            p.line(int(cx + r1 * math.cos(a1)), int(cy + r1 * math.sin(a1)),
                   int(cx + r2 * math.cos(a2)), int(cy + r2 * math.sin(a2)),
                   DIM2)

    def draw_trap(self, t):
        p = self.p
        st = self.state or {}
        clients = st.get("clients") or []
        counts = st.get("counts") or {}
        ssid = _truncate(st.get("ssid") or "OPEN", 16)
        lure = bool(st.get("lure"))
        lure_txt = "LURE" if lure else ""
        head_right = f"ch{st.get('channel','?')}  {len(clients)} CAUGHT"
        if lure and int(t * 2) % 2 == 0:
            head_right = "LURE " + head_right
        self.draw_header(f"VENUS // {ssid}", head_right,
                         RED if lure else GREEN)

        cx, cy, maxr = 142, 112, 84
        self._web(cx, cy, maxr)

        # Fly placement + entrance animation.
        for idx, c in enumerate(clients):
            mac = c.get("mac", "")
            ang, rr = fly_geometry(mac, maxr)
            seen = self.fly_seen.get(mac, t - 30)
            age = max(0.0, t - seen)
            if age < self.FLY_ENTER_SEC:
                k = age / self.FLY_ENTER_SEC
                k = 1 - (1 - k) ** 3
                rr = maxr * 1.25 * (1 - k) + rr * k
            ang += math.sin(t * 3.0 + (idx * 1.7)) * 0.035
            x = int(cx + rr * math.cos(ang))
            y = int(cy + rr * math.sin(ang))
            active = c.get("active", True)
            color = vendor_color(c.get("vendor"), c.get("random_mac"))
            if not active:
                color = GRAY
            if idx == self.sel_client:
                p.circle(x, y, 7, CYAN)
                p.circle(x, y, 8, DIM)
            # wings + body
            p.fill_circle(x - 2, y - 2, 2, DIM if not active else color)
            p.fill_circle(x + 2, y - 2, 2, DIM if not active else color)
            p.fill_circle(x, y, 2, RED if active else GRAY)
            if idx == self.sel_client:
                p.draw_text(min(x + 10, 210), max(20, y - 4),
                            c.get("mac", "")[-5:], CYAN, 1)

        if not clients:
            p.draw_text_centered(cy - 8, "THE WEB IS EMPTY", DIM, 1)
            p.draw_text_centered(cy + 8, "waiting for a victim...", DIM2, 1)

        # Catch flash
        if t < self.catch_until:
            p.rect(2, 20, self.W - 4, self.H - 40, RED)
            p.rect(3, 21, self.W - 6, self.H - 42, RED)
            p.fill_rect(120, 72, 260, 30, BLACK)
            p.draw_text_centered(78, "CAUGHT", RED, 3)
            p.draw_text_centered(106, self.catch_label.upper(), WHITE, 1)

        # Right panel
        px = 284
        p.fill_rect(px, 20, self.W - px, self.H - 40, PANEL)
        p.vline(px, 20, self.H - 40, DIM)
        p.draw_text(px + 8, 25, "CAUGHT", DIM, 1)
        p.draw_number(px + 8, 37, int(counts.get("clients", 0) or 0), RED, 3)
        p.draw_text(px + 78, 25, "WEB", DIM, 1)
        p.draw_number(px + 78, 37, int(counts.get("portal_hits", 0) or 0), CYAN, 3)
        p.draw_text(px + 8, 66, f"FORMS {int(counts.get('submissions',0) or 0)}",
                    AMBER, 1)
        p.draw_text(px + 78, 66, f"UP {_hms(st.get('uptime', 0))}", GRAY, 1)
        p.hline(px + 6, 78, self.W - px - 12, DIM2)

        # client rows
        y = 84
        if clients:
            shown = min(len(clients), 4)
            start = 0
            if self.sel_client >= shown:
                start = self.sel_client - shown + 1
            for i in range(start, min(len(clients), start + shown)):
                c = clients[i]
                row_y = y + (i - start) * 17
                if i == self.sel_client:
                    p.fill_rect(px + 4, row_y - 1, self.W - px - 8, 16, SEL)
                mac = c.get("mac", "")
                label = f"{mac[-8:]}"
                v = _truncate(c.get("vendor", "?"), 9)
                p.draw_text(px + 8, row_y + 1, label, WHITE, 1)
                p.draw_text(px + 72, row_y + 1, v,
                            vendor_color(c.get("vendor"), c.get("random_mac")), 1)
                r = c.get("rssi")
                p.draw_text(self.W - 34, row_y + 1,
                            f"{r}" if r is not None else "--", GRAY, 1)
        else:
            p.draw_text(px + 8, y + 2, "no devices yet", DIM, 1)

        # selected detail
        details_y = self.H - 58
        p.hline(px + 6, details_y, self.W - px - 12, DIM2)
        sel = clients[self.sel_client] if clients and self.sel_client < len(clients) else None
        if sel:
            ip = sel.get("ip") or "-"
            host = _truncate(sel.get("hostname") or "-", 18)
            p.draw_text(px + 8, details_y + 4, f"IP {ip}", GREEN, 1)
            p.draw_text(px + 8, details_y + 15, f"HOST {host}", CYAN, 1)
            last = max(0, int(t - (sel.get("last_seen") or t)))
            srssi = sel.get("rssi")
            p.draw_text(px + 8, details_y + 26,
                        f"RSSI {srssi if srssi is not None else '--'}  "
                        f"IDLE {last}s", GRAY, 1)
        else:
            p.draw_text(px + 8, details_y + 6, "A: lure   B: drop trap", DIM, 1)

        left = "[UP/DN] FLY   [A] LURE   [B] BACK"
        right = "LURE ON" if lure else ""
        self.draw_footer(left, right)

    # -- loop -------------------------------------------------------------- #
    def step(self):
        self.sync()
        self.handle_input()
        self.draw()
        # Quit handshake: wait for the engine to acknowledge shutdown.
        if self.quit_sent_at and time.time() - self.quit_sent_at > 2.5:
            self.done = True

    def run(self):
        try:
            self.p.clear_input_events()
        except Exception:
            pass
        while not self.done:
            try:
                self.step()
            except Exception as e:
                # A renderer failure must not wedge the payload; drop to the
                # LOG fallback in payload.sh.
                print(f"venus ui error: {e}", file=sys.stderr)
                return 3
            self.p.delay(self.FPS_DELAY_MS)
        return 0


# --------------------------------------------------------------------------- #
# Sample state for headless rendering
# --------------------------------------------------------------------------- #

SAMPLE = {
    "version": 1, "ts": 0, "uptime": 137, "phase": "trap",
    "ssid": "Cafe_Guest", "channel": 6, "bssid": "aa:bb:cc:11:22:33",
    "ap_iface": "wlan1", "recon_iface": "wlan0", "ap_ip": "192.168.69.1",
    "http_port": 80, "password": False, "portal": True, "lure": True,
    "lure_available": True,
    "aps": [
        {"bssid": "aa:bb:cc:11:22:33", "ssid": "Cafe_Guest", "channel": 6,
         "freq": 2437, "rssi": -41, "enc": "OPN", "band": "2.4"},
        {"bssid": "aa:bb:cc:44:55:66", "ssid": "Corp-WiFi", "channel": 36,
         "freq": 5180, "rssi": -57, "enc": "WPA3", "band": "5"},
        {"bssid": "aa:bb:cc:77:88:99", "ssid": "HomeNet", "channel": 11,
         "freq": 2462, "rssi": -66, "enc": "WPA2", "band": "2.4"},
    ],
    "clients": [
        {"mac": "3c:22:fb:1a:2b:3c", "ip": "192.168.69.10", "hostname": "iPhone",
         "vendor": "Apple", "random_mac": False, "rssi": -48,
         "first_seen": 0, "last_seen": 0, "active": True, "portal_hits": 1},
        {"mac": "24:6f:28:aa:bb:cc", "ip": "192.168.69.11", "hostname": "",
         "vendor": "Espressif", "random_mac": False, "rssi": -63,
         "first_seen": 0, "last_seen": 0, "active": True, "portal_hits": 0},
        {"mac": "da:a1:19:44:55:66", "ip": "", "hostname": "",
         "vendor": "Private (randomized)", "random_mac": True, "rssi": -71,
         "first_seen": 0, "last_seen": 0, "active": True, "portal_hits": 0},
    ],
    "events": [], "counts": {"clients": 3, "portal_hits": 1, "submissions": 1},
    "error": None,
}


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def main(argv=None):
    ap = argparse.ArgumentParser(description="VENUS pager UI")
    ap.add_argument("--headless", action="store_true",
                    help="render with a no-op pager (dev machine)")
    ap.add_argument("--frames", type=int, default=3)
    ap.add_argument("--sample", action="store_true",
                    help="use the built-in sample state (implies --headless)")
    ap.add_argument("--recon", action="store_true",
                    help="headless: start on the recon screen")
    args = ap.parse_args(argv)

    if args.sample:
        args.headless = True

    if args.headless:
        p = FakePager()
    else:
        try:
            from pagerctl import Pager  # noqa: F401
        except Exception as e:
            print(f"pagerctl unavailable: {e}", file=sys.stderr)
            return 1
        # Stop the stock UI so we own the framebuffer and input device.
        try:
            subprocess.run(["/etc/init.d/pineapplepager", "stop"],
                           capture_output=True, timeout=5)
            time.sleep(0.5)
        except Exception:
            pass
        p = Pager()
        try:
            p.init()
        except Exception as e:
            print(f"pager init failed: {e}", file=sys.stderr)
            # We already stopped the stock UI; put it back so the payload's
            # LOG fallback has a functioning display.
            try:
                subprocess.run(["/etc/init.d/pineapplepager", "start"],
                               capture_output=True, timeout=5)
            except Exception:
                pass
            return 1
        p.set_rotation(270)

    ui = VenusUI(p)
    if args.sample:
        sample = json.loads(json.dumps(SAMPLE))
        if args.recon:
            sample["phase"] = "recon"
            sample["ssid"] = None
            sample["lure"] = False
        ui.state = sample
        ui.phase_prev = sample["phase"]
        ui.screen = "recon" if args.recon else "trap"
        t = time.time()
        for c in ui.state["clients"]:
            c["first_seen"] = t - 30
            c["last_seen"] = t
        if not args.recon:
            for c in ui.state["clients"]:
                ui.known_macs.add(c["mac"])
                ui.fly_seen[c["mac"]] = t - 30
            ui.baselined = True
            ui.sel_client = 0

    if args.headless:
        rc = 0
        try:
            for _ in range(max(1, args.frames)):
                if args.sample:
                    ui.state = ui.state or dict(SAMPLE)
                else:
                    # No sample: read the live engine state file so this can
                    # be pointed at `venus.py simulate` for a full dry run.
                    ui.sync()
                ui.draw()
        except Exception as e:
            print(f"render failed: {e}", file=sys.stderr)
            rc = 1
        print(f"headless render: {args.frames} frame(s), "
              f"screen={ui.screen}, phase={(ui.state or {}).get('phase')}, "
              f"aps={len((ui.state or {}).get('aps') or [])}, "
              f"clients={len((ui.state or {}).get('clients') or [])}, "
              f"draw_calls={getattr(p, 'calls', 0)}")
        return rc

    # Real hardware path.
    def _sig(sig, frame):
        ui.done = True

    try:
        signal.signal(signal.SIGTERM, _sig)
        signal.signal(signal.SIGINT, _sig)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except Exception:
        pass

    rc = 1
    try:
        rc = ui.run()
    finally:
        # Best effort: stop the trap and wait for the engine to confirm it is
        # down before returning the screen (and radio) to pineapplepager.
        try:
            if ui.state and ui.state.get("phase") in ("trap", "arming"):
                send_cmd({"cmd": "untrap"})
                deadline = time.time() + 3.0
                while time.time() < deadline:
                    st = load_state()
                    if st and st.get("phase") in ("recon", "stopped"):
                        break
                    time.sleep(0.15)
        except Exception:
            pass
        try:
            p.cleanup()
        except Exception:
            pass
        try:
            p.led_all_off()
        except Exception:
            pass
        try:
            subprocess.run(["/etc/init.d/pineapplepager", "start"],
                           capture_output=True, timeout=5)
        except Exception:
            pass
    return rc


if __name__ == "__main__":
    sys.exit(main())
