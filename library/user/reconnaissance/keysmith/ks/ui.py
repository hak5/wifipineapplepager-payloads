#!/usr/bin/env python3
"""KEYSMITH on-device UI (480x222).

Screens: TARGETS -> PLAN -> DERIVE -> HANDSHAKE -> RESULT.

The UI never touches the radio.  It reads ``/tmp/keysmith_state.json`` and
appends commands to ``/tmp/keysmith_cmd.jsonl``; the engine owns the hardware.
Either side can die without taking the other down with it.

Dev machine:
  python3 ks/ui.py --headless --sample --frames 3
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
for _p in (ROOT, os.path.join(ROOT, "lib")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

STATE = os.environ.get("KEYSMITH_STATE", "/tmp/keysmith_state.json")
CMD = os.environ.get("KEYSMITH_CMD", "/tmp/keysmith_cmd.jsonl")
KEY_FONT = os.path.join(ROOT, "fonts", "Roboto-Bold.ttf")


def rgb(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


BLACK = 0x0000
WHITE = 0xFFFF
RED = rgb(255, 48, 64)
DARKRED = rgb(44, 0, 10)
GREEN = rgb(0, 235, 130)
DIM = rgb(0, 96, 58)
DIM2 = rgb(0, 40, 26)
CYAN = rgb(0, 205, 255)
AMBER = rgb(255, 176, 32)
MAGENTA = rgb(238, 74, 200)
GRAY = rgb(116, 128, 124)
DARK = rgb(0, 14, 12)
PANEL = rgb(0, 20, 16)
SEL = rgb(0, 64, 56)

FOUND_SOUND = "keysmith_found:d=12,o=6,b=220:c7,e7,g7,c8"
NOPE_SOUND = "keysmith_nope:d=16,o=5,b=180:e5,c5"
TICK_SOUND = "keysmith_tick:d=32,o=6,b=240:c7"


def _truncate(text, n):
    text = str(text or "")
    if n <= 0:
        return ""
    return text if len(text) <= n else text[: max(0, n - 2)] + ".."


def _wrap(text, width):
    words = str(text or "").split()
    lines, cur = [], ""
    for word in words:
        if cur and len(cur) + 1 + len(word) > width:
            lines.append(cur)
            cur = word
        else:
            cur = word if not cur else cur + " " + word
    if cur:
        lines.append(cur)
    return lines or [""]


def load_state(path=None):
    path = path or STATE
    try:
        with open(path, "r") as fh:
            obj = json.load(fh)
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


def send_cmd(obj, path=None):
    try:
        with open(path or CMD, "a") as fh:
            fh.write(json.dumps(obj, separators=(",", ":")) + "\n")
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------- #
# Headless stub
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

    def __init__(self, width=480, height=222):
        self.width = width
        self.height = height
        self.calls = 0
        self.frames = 0
        self.events = []

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
    def get_input_event(self): return self.events.pop(0) if self.events else None
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
    def draw_ttf(self, *a): self._n()
    def draw_ttf_centered(self, *a): self._n()
    def ttf_width(self, text, font_path, font_size):
        return int(len(str(text)) * font_size * 0.56)
    def draw_number(self, *a): self._n()
    def text_width(self, text, size=1): return len(str(text)) * 6 * size
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

class KeysmithUI:
    FPS_DELAY_MS = 80
    DEBOUNCE_SEC = 2.5

    def __init__(self, pager):
        self.p = pager
        self.W = pager.width
        self.H = pager.height
        self.state = None
        self.screen = "scan"
        self.sel = 0
        self.sel_bssid = ""
        self.started = time.time()
        self.done = False
        self.status = ""
        self.status_until = 0.0
        self.quit_sent_at = 0.0
        self.last_phase = None

    # -- helpers ----------------------------------------------------------- #
    def note(self, text, secs=2.4):
        self.status = text
        self.status_until = time.time() + secs

    def play(self, melody, vibrate=0):
        try:
            self.p.play_rtttl(melody)
        except Exception:
            pass
        if vibrate:
            try:
                self.p.vibrate(vibrate)
            except Exception:
                pass

    # -- state ------------------------------------------------------------- #
    def sync(self):
        st = load_state()
        if st is None:
            return
        self.state = st
        phase = st.get("phase", "scan")
        target_screen = {
            "boot": "scan", "scan": "scan", "plan": "plan",
            "derive": "derive", "try": "try", "done": "done",
            "error": "error", "off": "scan",
        }.get(phase, "scan")
        if target_screen != self.screen:
            self.screen = target_screen
            if self.screen == "plan":
                self.play(TICK_SOUND)
            elif self.screen == "done":
                res = st.get("result") or {}
                if res.get("ok"):
                    self.play(FOUND_SOUND, vibrate=240)
                else:
                    self.play(NOPE_SOUND, vibrate=80)
        if phase == "off":
            self.done = True
            return
        self.last_phase = phase
        # Keep the selected AP addressable across rescans.
        if self.screen == "scan":
            aps = st.get("aps") or []
            if self.sel_bssid:
                for i, ap in enumerate(aps):
                    if ap.get("bssid") == self.sel_bssid:
                        self.sel = i
                        break
                else:
                    self.sel_bssid = ""
            if aps:
                self.sel = max(0, min(self.sel, len(aps) - 1))
                self.sel_bssid = aps[self.sel].get("bssid", "")

    def selected_ap(self):
        aps = (self.state or {}).get("aps") or []
        if not aps:
            return None
        return aps[max(0, min(self.sel, len(aps) - 1))]

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
            button, etype = ev[0], ev[1]
            if etype != self.p.EVENT_PRESS:
                continue
            if t - self.started < self.DEBOUNCE_SEC and \
                    button in (self.p.BTN_A, self.p.BTN_B):
                try:
                    self.p.clear_input_events()
                except Exception:
                    pass
                continue
            self.on_button(button)

    def move(self, delta):
        aps = (self.state or {}).get("aps") or []
        if not aps:
            return
        self.sel = (self.sel + delta) % len(aps)
        self.sel_bssid = aps[self.sel].get("bssid", "")

    def on_button(self, button):
        p = self.p
        if button in (p.BTN_UP, p.BTN_DOWN):
            if self.screen == "scan":
                self.move(-1 if button == p.BTN_UP else 1)
            return
        if button == p.BTN_A:
            if self.screen == "scan":
                self.plan_selected()
            elif self.screen == "plan":
                send_cmd({"cmd": "attack"})
                self.note("STARTING")
            elif self.screen in ("done", "error"):
                self.disconnect()
            return
        if button == p.BTN_B:
            if self.screen == "scan":
                self.quit()
            elif self.screen == "plan":
                send_cmd({"cmd": "scan"})
            elif self.screen in ("derive", "try"):
                send_cmd({"cmd": "stop"})
                self.note("ABORTING")
            else:
                send_cmd({"cmd": "scan"})

    def plan_selected(self):
        ap = self.selected_ap()
        if not ap:
            self.note("NO TARGETS")
            return
        if not ap.get("schemes"):
            self.note("NO KNOWN SCHEME")
            return
        send_cmd({"cmd": "plan", "ap": self.sel, "bssid": ap.get("bssid")})
        self.note("ANALYZING " + _truncate(ap.get("ssid", ""), 16))

    def disconnect(self):
        send_cmd({"cmd": "disconnect"})
        self.note("DISCONNECTING")
        send_cmd({"cmd": "scan"})

    def quit(self):
        if self.quit_sent_at:
            return
        self.quit_sent_at = time.time()
        send_cmd({"cmd": "shutdown"})
        self.note("SHUTTING DOWN")

    # -- drawing ----------------------------------------------------------- #
    def draw(self):
        p = self.p
        p.clear(BLACK)
        st = self.state
        if st is None:
            self.draw_header("KEYSMITH", "WAITING")
            p.draw_text_centered(90, "WAITING FOR ENGINE", CYAN, 2)
            p.draw_text_centered(122, _truncate(STATE, 46), GRAY, 1)
            self.draw_footer("[B] QUIT", "")
            p.flip()
            return
        screen = self.screen
        if screen == "plan":
            self.draw_plan()
        elif screen == "derive":
            self.draw_derive()
        elif screen == "try":
            self.draw_try()
        elif screen == "done":
            self.draw_result()
        elif screen == "error":
            self.draw_error()
        else:
            self.draw_scan()
        self.update_led()
        p.flip()

    def draw_header(self, left, right, accent=GREEN):
        p = self.p
        p.fill_rect(0, 0, self.W, 18, DARKRED)
        p.hline(0, 18, self.W, DIM)
        p.draw_text(6, 5, left, accent, 1)
        if right:
            w = p.text_width(right, 1)
            p.draw_text(self.W - w - 6, 5, right, GRAY, 1)

    def draw_footer(self, left, right="", right_color=RED):
        p = self.p
        p.fill_rect(0, self.H - 18, self.W, 18, DARK)
        p.hline(0, self.H - 18, self.W, DIM)
        p.draw_text(6, self.H - 13, left, GRAY, 1)
        if right:
            w = p.text_width(right, 1)
            p.draw_text(self.W - w - 6, self.H - 13, right, right_color, 1)
        if self.status and time.time() < self.status_until:
            w = p.text_width(self.status, 1)
            p.draw_text((self.W - w) // 2, self.H - 13, self.status, AMBER, 1)

    def draw_key(self, y, text):
        """Draw a passphrase as large as it will fit on one line.

        The TTF renderer is exact about width, so try smaller sizes until the
        whole key fits instead of guessing from character count.  Without the
        font (or on an old library) fall back to the bitmap font.
        """
        p = self.p
        text = str(text or "")
        if not text:
            return 0
        if os.path.isfile(KEY_FONT):
            sizes = (34, 30, 26, 22, 18, 15, 12)
            for size in sizes:
                try:
                    width = p.ttf_width(text, KEY_FONT, float(size))
                except Exception:
                    width = None
                if width is None:
                    break
                if 0 < width <= self.W - 20:
                    try:
                        p.draw_ttf_centered(y, text, WHITE, KEY_FONT,
                                            float(size))
                        return size
                    except Exception:
                        break
            # A 63-character passphrase never fits comfortably; use the
            # smallest readable size rather than silently falling back.
            try:
                p.draw_ttf_centered(y, text, WHITE, KEY_FONT,
                                    float(sizes[-1]))
                return sizes[-1]
            except Exception:
                pass
        size = 2 if len(text) > 15 else 3
        p.draw_text_centered(y, text, WHITE, size)
        return size

    def draw_bars(self, x, y, bars):
        for b in range(4):
            bh = 3 + b * 3
            color = GREEN if b < bars else DIM2
            self.p.fill_rect(x + b * 7, y + 12 - bh, 5, bh, color)

    def draw_scan(self):
        p = self.p
        st = self.state or {}
        aps = st.get("aps") or []
        total = sum(1 for a in aps if a.get("schemes"))
        self.draw_header("KEYSMITH // TARGETS",
                         ("%d/%d KEYED" % (total, len(aps))) if aps else "SWEEP",
                         CYAN)
        if not aps:
            dots = "." * (1 + int(time.time() * 2) % 3)
            p.draw_text_centered(86, "SWEEPING" + dots, GREEN, 2)
            p.draw_text_centered(116, "radio %s" % (st.get("iface") or "?"),
                                 GRAY, 1)
            p.draw_text_centered(134,
                                 "only APs with a known default-key scheme "
                                 "can be attacked", DIM, 1)
            self.draw_footer("[B] QUIT", "")
            return
        y0, row_h, rows = 23, 23, 7
        start = 0
        if self.sel >= rows:
            start = self.sel - rows + 1
        for i in range(start, min(len(aps), start + rows)):
            ap = aps[i]
            y = y0 + (i - start) * row_h
            selected = i == self.sel
            if selected:
                p.fill_rect(2, y - 1, self.W - 4, row_h - 2, SEL)
                p.fill_rect(2, y - 1, 3, row_h - 2, CYAN)
            self.draw_bars(10, y + 3, ap.get("bars", 0))
            ssid_color = WHITE if selected else GREEN
            if not ap.get("schemes"):
                ssid_color = GRAY
            p.draw_text(40, y + 3, _truncate(ap.get("ssid", "?"), 24),
                        ssid_color, 2)
            vendor = _truncate(ap.get("vendor") or ap.get("bssid", "")[:8], 10)
            p.draw_text(340, y + 4, vendor, GRAY, 1)
            enc = ap.get("enc", "?")
            enc_color = {"WPA2": GREEN, "WPA3": CYAN, "WPA": AMBER,
                         "WEP": RED, "OPEN": AMBER}.get(enc, GRAY)
            p.draw_text(340, y + 13, enc, enc_color, 1)
            n = ap.get("schemes", 0)
            badge_color = MAGENTA if n else DIM
            label = ("%d" % n) if n else "-"
            p.draw_text(self.W - 24, y + 4, label, badge_color, 2)
        sel = self.selected_ap()
        if sel and sel.get("schemes"):
            left = "[A] PLAN %s" % _truncate(sel.get("ssid", ""), 14)
        else:
            left = "[UP/DN] SELECT"
        self.draw_footer(left, "[B] QUIT")

    def draw_plan(self):
        p = self.p
        st = self.state or {}
        target = st.get("target") or {}
        plan = st.get("plan") or []
        self.draw_header("KEYSMITH // PLAN", "%d SCHEME%s"
                         % (len(plan), "" if len(plan) == 1 else "S"), CYAN)
        p.draw_text(10, 25, _truncate(target.get("ssid", "?"), 30), WHITE, 2)
        p.draw_text(10, 45, target.get("bssid", ""), GRAY, 1)
        p.draw_text(10, 56, "%s  %s  ch%s" % (
            _truncate(target.get("vendor") or "?", 12),
            target.get("enc", "?"), target.get("channel", "?")), GRAY, 1)
        y = 76
        shown = plan[:6]
        for entry in shown:
            name = entry.get("name", "?")
            note = entry.get("note", "")
            p.draw_text(14, y, name, GREEN, 1)
            if note:
                p.draw_text(130, y, _truncate(note, 22), DIM, 1)
            if entry.get("slow"):
                p.draw_text(self.W - 54, y, "SLOW", AMBER, 1)
            y += 17
        if len(plan) > len(shown):
            p.draw_text(14, y, "+%d more" % (len(plan) - len(shown)), DIM, 1)
        slow = any(e.get("slow") for e in plan)
        left = "[A] ATTACK"
        right = "SLOW" if slow else ""
        self.draw_footer(left, right, AMBER)

    def draw_derive(self):
        p = self.p
        st = self.state or {}
        self.draw_header("KEYSMITH // DERIVE", "KEYS %d" % st.get("derived", 0),
                         AMBER)
        dots = "." * (1 + int(time.time() * 3) % 3)
        p.draw_text_centered(44, "DERIVING" + dots, AMBER, 2)
        p.draw_text_centered(76, _truncate(st.get("derive_current") or "?", 34),
                             WHITE, 1)
        idx = st.get("derive_index", 0)
        total = max(1, st.get("derive_total", 1))
        self.draw_progress(120, idx / float(total), AMBER)
        p.draw_text_centered(146, "scheme %d/%d" % (idx, total), GRAY, 1)
        p.draw_text_centered(164, "found %d candidate%s"
                             % (st.get("derived", 0),
                                "" if st.get("derived", 0) == 1 else "s"),
                             DIM, 1)
        self.draw_footer("[B] ABORT", "")

    def draw_try(self):
        p = self.p
        st = self.state or {}
        idx = st.get("try_index", 0)
        total = max(1, st.get("try_total", 1))
        self.draw_header("KEYSMITH // HANDSHAKE",
                         "TRY %d/%d" % (idx + 1, total), CYAN)
        key = str(st.get("try_current") or "----------")
        self.draw_key(50, key)
        p.draw_text_centered(96, "candidate %d of %d" % (idx + 1, total),
                             GRAY, 1)
        attempts = st.get("attempts") or []
        last = attempts[-1] if attempts else None
        if last:
            color = GREEN if last.get("ok") else RED
            p.draw_text_centered(116, "%s  %s  %ss" % (
                last.get("algo", ""), last.get("reason", ""),
                last.get("elapsed", "")), color, 1)
        self.draw_progress(138, idx / float(total), CYAN)
        p.draw_text_centered(160, "4-way handshake", DIM, 1)
        self.draw_footer("[B] ABORT", "")

    def draw_result(self):
        p = self.p
        st = self.state or {}
        res = st.get("result") or {}
        target = st.get("target") or {}
        ok = bool(res.get("ok"))
        derived = bool(res.get("derived_only"))
        accent = GREEN if ok else (AMBER if derived else RED)
        title = "FOUND" if ok else ("DERIVED" if derived else "NO MATCH")
        self.draw_header("KEYSMITH // %s" % title,
                         _truncate(target.get("ssid", ""), 18), accent)
        p.draw_text(10, 24, _truncate(target.get("ssid", "?"), 34), WHITE, 1)
        p.draw_text(10, 35, target.get("bssid", ""), GRAY, 1)
        key = str(res.get("key") or st.get("key") or "")
        if key:
            self.draw_key(54, key)
            p.draw_text_centered(98, "via %s" % (res.get("algo") or "?"),
                                 MAGENTA, 1)
        else:
            p.draw_text_centered(62, "no candidate completed the handshake",
                                 RED, 1)
        y = 116
        if ok:
            line = "joined %s" % (res.get("ip") or "no lease")
            p.draw_text_centered(y, line, GREEN, 1)
            if res.get("router"):
                p.draw_text_centered(y + 14, "gateway %s   dns %s" % (
                    res.get("router"),
                    (res.get("dns") or ["-"])[0]), GRAY, 1)
        elif derived:
            p.draw_text_centered(y, "wpa_supplicant unavailable - key is "
                                 "unverified", AMBER, 1)
        else:
            p.draw_text_centered(y, res.get("reason") or "no key matched",
                                 RED, 1)
        p.draw_text_centered(y + 32, "%s attempt%s   %ss" % (
            res.get("attempts", 0),
            "" if res.get("attempts", 0) == 1 else "s",
            res.get("elapsed", "-")), DIM, 1)
        if ok:
            self.draw_footer("[A] DISCONNECT", "[B] BACK", GREEN)
        else:
            self.draw_footer("[A] DISCONNECT", "[B] BACK", GRAY)

    def draw_error(self):
        p = self.p
        st = self.state or {}
        self.draw_header("KEYSMITH // ERROR", "", RED)
        p.draw_text(14, 34, "ATTACK HALTED", RED, 2)
        msg = st.get("error") or st.get("message") or "unknown error"
        y = 70
        for line in _wrap(msg, 62)[:5]:
            p.draw_text(14, y, line, WHITE, 1)
            y += 15
        p.draw_text(14, y + 8, "loot: %s" % _truncate(st.get("loot", ""), 52),
                    DIM, 1)
        self.draw_footer("[B] BACK", "[B] BACK", GRAY)

    def draw_progress(self, y, frac, color):
        p = self.p
        frac = max(0.0, min(1.0, float(frac)))
        p.fill_rect(40, y, self.W - 80, 10, PANEL)
        p.rect(40, y, self.W - 80, 10, DIM)
        width = int((self.W - 84) * frac)
        if width > 0:
            p.fill_rect(42, y + 2, width, 6, color)

    def update_led(self):
        color = {"scan": (0, 90, 200), "plan": (0, 120, 160),
                 "derive": (255, 160, 0), "try": (0, 180, 255),
                 "done": (0, 220, 90), "error": (220, 30, 30)}.get(
                     self.screen, (0, 40, 40))
        try:
            self.p.led_rgb("power", *color)
        except Exception:
            pass

    # -- loop -------------------------------------------------------------- #
    def step(self):
        self.sync()
        if self.done:
            return
        self.handle_input()
        self.draw()
        if self.quit_sent_at and time.time() - self.quit_sent_at > 2.0:
            self.done = True

    def run(self):
        try:
            self.p.clear_input_events()
        except Exception:
            pass
        while not self.done:
            try:
                self.step()
            except Exception as exc:
                print("keysmith ui error: %r" % (exc,), file=sys.stderr)
                return 3
            self.p.delay(self.FPS_DELAY_MS)
        return 0


# --------------------------------------------------------------------------- #
# Sample state (headless render + tests)
# --------------------------------------------------------------------------- #

SAMPLE = {
    "version": "1.0.0",
    "phase": "scan",
    "iface": "wlan1",
    "scan_ok": True,
    "aps": [
        {"ssid": "SitecomF12FFE", "bssid": "00:0c:f6:f1:2f:fe", "rssi": -44,
         "bars": 4, "enc": "WPA2", "vendor": "Sitecom", "channel": 1,
         "freq": 2412, "band": "2.4", "schemes": 3},
        {"ssid": "Alice-53847953", "bssid": "00:25:53:35:a7:91", "rssi": -58,
         "bars": 3, "enc": "WPA2", "vendor": "Alice", "channel": 6,
         "freq": 2437, "band": "2.4", "schemes": 1},
        {"ssid": "Thomson41518c", "bssid": "00:1f:9f:41:51:8c", "rssi": -67,
         "bars": 2, "enc": "WPA2", "vendor": "", "channel": 11,
         "freq": 2462, "band": "2.4", "schemes": 1},
        {"ssid": "UPC1234567", "bssid": "64:7c:34:11:22:33", "rssi": -74,
         "bars": 1, "enc": "WPA2", "vendor": "", "channel": 3,
         "freq": 2422, "band": "2.4", "schemes": 1},
        {"ssid": "Cafe_Guest", "bssid": "aa:bb:cc:11:22:33", "rssi": -80,
         "bars": 1, "enc": "OPEN", "vendor": "", "channel": 9,
         "freq": 2452, "band": "2.4", "schemes": 0},
    ],
    "target": {"ssid": "SitecomF12FFE", "bssid": "00:0c:f6:f1:2f:fe",
               "vendor": "Sitecom", "enc": "WPA2", "channel": 1,
               "freq": 2412},
    "plan": [
        {"name": "Sitecom", "note": "", "slow": False,
         "mac": "000CF6F12FFE"},
        {"name": "SitecomWLR400x", "note": "", "slow": True,
         "mac": "000CF6F12FFE"},
        {"name": "SitecomWLR2100", "note": "", "slow": False,
         "mac": "000CF6F12FFE"},
    ],
    "derived": 21,
    "derive_index": 2,
    "derive_total": 3,
    "derive_current": "SitecomWLR400x",
    "derive_progress": 0.62,
    "try_index": 3,
    "try_total": 21,
    "try_current": "c6aBBBbg",
    "attempts": [
        {"key": "q69CB1kg", "algo": "Sitecom", "ok": False,
         "reason": "wrong key", "elapsed": 1.2},
        {"key": "44B5Dmyc", "algo": "Sitecom", "ok": False,
         "reason": "wrong key", "elapsed": 1.1},
        {"key": "N66zHMRc", "algo": "Sitecom", "ok": False,
         "reason": "wrong key", "elapsed": 1.3},
    ],
    "key": "c6aBBBbg",
    "result": {
        "ok": True, "verified": True, "key": "c6aBBBbg", "algo": "Sitecom",
        "ip": "192.168.0.23", "router": "192.168.0.1",
        "dns": ["192.168.0.1"], "attempts": 4, "elapsed": 5.6,
    },
    "message": "KEY FOUND - JOINED",
    "error": "",
    "loot": "/root/loot/keysmith",
    "started": 0, "updated": 0, "events": [],
}


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def main(argv=None):
    ap = argparse.ArgumentParser(description="KEYSMITH pager UI")
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--frames", type=int, default=3)
    ap.add_argument("--sample", action="store_true")
    ap.add_argument("--screen", default="",
                    help="headless: force scan|plan|derive|try|done|error")
    args = ap.parse_args(argv)
    if args.sample:
        args.headless = True

    if args.headless:
        p = FakePager()
    else:
        try:
            from pagerctl import Pager
        except Exception as exc:
            print("pagerctl unavailable: %r" % (exc,), file=sys.stderr)
            return 1
        try:
            subprocess.run(["/etc/init.d/pineapplepager", "stop"],
                           capture_output=True, timeout=5)
            time.sleep(0.4)
        except Exception:
            pass
        p = Pager()
        try:
            p.init()
        except Exception as exc:
            print("pager init failed: %r" % (exc,), file=sys.stderr)
            try:
                subprocess.run(["/etc/init.d/pineapplepager", "start"],
                               capture_output=True, timeout=5)
            except Exception:
                pass
            return 1
        p.set_rotation(270)

    ui = KeysmithUI(p)
    if args.sample:
        ui.state = json.loads(json.dumps(SAMPLE))
        if args.screen:
            ui.state["phase"] = {
                "scan": "scan", "plan": "plan", "derive": "derive",
                "try": "try", "done": "done", "error": "error",
            }.get(args.screen, "scan")
            if args.screen == "error":
                ui.state["error"] = ("no tri-band radio (phy1); refusing to "
                                     "touch the management uplink on phy0")
        ui.screen = {
            "scan": "scan", "plan": "plan", "derive": "derive",
            "try": "try", "done": "done", "error": "error",
        }.get(args.screen or ui.state.get("phase"), "scan")

    if args.headless:
        rc = 0
        try:
            for _ in range(max(1, args.frames)):
                if args.sample:
                    ui.draw()
                else:
                    ui.sync()
                    ui.draw()
        except Exception as exc:
            print("render failed: %r" % (exc,), file=sys.stderr)
            rc = 1
        st = ui.state or {}
        print("headless render: %d frame(s), screen=%s, phase=%s, aps=%d, "
              "draw_calls=%d" % (max(1, args.frames), ui.screen,
                                 st.get("phase"), len(st.get("aps") or []),
                                 getattr(p, "calls", 0)))
        return rc

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
        try:
            if ui.state and (ui.state.get("result") or {}).get("ok"):
                send_cmd({"cmd": "disconnect"})
        except Exception:
            pass
        for op in (p.cleanup, p.led_all_off):
            try:
                op()
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
