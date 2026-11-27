"""Screens. Each draws into the content area and handles logical keys.

Esc goes back everywhere, the arrow keys move and OK opens or confirms.
"""

import calendar
import functools
import json
import os
import re
import time

from .. import (__version__, accounts, adsb, config, flasher, hardware, lora, mesh, powerguard, qr, recon,
                updates_check, uploads, wigle)
from ..nodes import NEWER, NO_HUB, NOT_ON_HUB, NOT_PLUGGED, OLDER, PAIR_SECONDS, UNPLUGGED
from ..tracker import BLE, BT, WIFI
from . import icons, splash
from .gfx import (AMBER, BAND_COLOR, BG, CONTENT_BOTTOM, CONTENT_TOP, CYAN, FAINT, GOLD, GOLD_DIM, GOLD_INK, GREEN,
                  LINE, MUTED, RED, SURFACE, SURFACE_2, TEXT, W, ago, clock, font, image, rssi_color)

TOP = CONTENT_TOP + 3
WHITE = (255, 255, 255)
SECURITY_COLOR = {"OPEN": RED, "WEP": RED, "WPA": AMBER, "OWE": CYAN}
STAMP = re.compile(r"quartermaster_(\d{8})-(\d{6})")
SITE_SHORT = {"wigle": "WiGLE", "wdgwars": "WDG", "wardrift": "DRIFT"}
REPO = "github.com/valleytechsolutions/Quartermaster"
THANKS = ("Thanks to justcallmekoko, Code_Hedge, Ekoms_Savior, Jesse Hale, ChrisDaCrunk, Vileer from "
          "Hacker\u00a0Gadgets, LocoSp, Awok and Talking Sasquach")
BOARD_NAMES = {"stamp-c5": "Stamp-C5"}
# The status light of each board, as #LED takes it, with the name in the list and the short name on the row.
LIGHTS = (("gpio,27,1", "XIAO ESP32-C5", "XIAO"), ("ws2812,27", "ESP32-C5-DevKitC-1", "DevKitC"),
          ("gpio,28", "Stamp-C5", "Stamp-C5"), ("none", "No light", "None"))
BOOT_HELP = ("XIAO: hold BOOT while you plug it in.", "Stamp-C5: hold G28 to GND while you plug it in.",
             "DevKit: hold BOOT and press RESET.")


class Screen:
    title = ""
    refresh = 1.0
    chrome = True
    text_mode = False

    def hints(self, app):
        return [("Esc", "Back")]

    def render(self, c, app):
        raise NotImplementedError

    def handle(self, key, app):
        if key in ("ESC", "BACKSPACE"):
            app.pop()
            return True
        return False

    def closed(self, app):
        """Called once when the screen leaves the stack."""


class Modal(Screen):
    pass


class ListMixin:
    index = 0
    top = 0

    def move(self, key, count, visible):
        if not count:
            return False
        step = {"UP": -1, "DOWN": 1, "PAGEUP": -visible, "PAGEDOWN": visible}.get(key.name)
        if step is None:
            return False
        self.index = max(0, min(count - 1, self.index + step)) if abs(step) > 1 else (self.index + step) % count
        self.clamp(count, visible)
        return True

    def clamp(self, count, visible):
        self.index = max(0, min(self.index, max(0, count - 1)))
        if self.index < self.top:
            self.top = self.index
        if self.index >= self.top + visible:
            self.top = self.index - visible + 1
        self.top = max(0, min(self.top, max(0, count - visible)))

    def scrollbar(self, c, count, visible, x=W - 4, y0=TOP, y1=CONTENT_BOTTOM - 2):
        if count <= visible:
            return
        c.rect((x, y0, x + 1, y1), fill=LINE)
        span = y1 - y0
        height = max(8, span * visible // count)
        y = y0 + (span - height) * self.top // max(1, count - visible)
        c.rect((x - 1, y, x + 2, y + height), fill=MUTED, radius=1)


def empty_state(c, icon, title, detail):
    icons.draw(c, icon, W // 2 - 14, 40, 28, LINE)
    c.text_center(W // 2, 76, title, font("bold", 12), TEXT)
    for i, line in enumerate(c.wrap(detail, 280, font("ui", 10))[:4]):
        c.text_center(W // 2, 94 + i * 13, line, font("ui", 10), MUTED)


def fmt_rssi(value):
    return "—" if value is None else "%d" % round(value)


def log_epoch(name):
    match = STAMP.match(name)
    if not match:
        return None
    try:
        return calendar.timegm(time.strptime(match.group(1) + match.group(2), "%Y%m%d%H%M%S"))
    except ValueError:
        return None


def when(epoch):
    return time.strftime("%b %d  %H:%M", time.localtime(epoch)) if epoch else "Unknown time"


def size_text(size):
    if size >= 1024 * 1024:
        return "%.1f MB" % (size / 1048576)
    return "%d KB" % max(1, size // 1024)


def line_count(path, headers):
    try:
        with open(path, "rb") as source:
            return max(0, sum(1 for _ in source) - headers)
    except OSError:
        return None


def plural(count, word):
    return "%d %s%s" % (count, word, "" if count == 1 else "s")


@functools.lru_cache(maxsize=1)
def bundled_firmware():
    """The version of the node firmware that came with Quartermaster."""
    try:
        with open(flasher.MANIFEST, encoding="utf-8") as f:
            return str(json.load(f)["version"])
    except (OSError, ValueError, KeyError, TypeError):
        return ""


def board_name(node):
    return BOARD_NAMES.get(node.get("board") or "", "ESP32-C5")


def light_name(node):
    if not node["led"]:
        return "Not set"
    return next((short for value, _, short in LIGHTS if value == node["led"]), node["led"])


def default_name(node):
    return "%s %s" % (board_name(node), node["id"][-4:].upper())


def old_firmware(node):
    """True when the firmware that came with Quartermaster is newer than the node's."""
    return node["error"] == OLDER or updates_check.newer(bundled_firmware(), node["firmware"] or "")


def node_word(node):
    """The word the lists show for a node, and its colour."""
    if node["updating"]:
        return "Updating", GOLD
    if not node["connected"] and node.get("wireless"):
        return ("Waiting", FAINT) if node["error"] == NO_HUB else ("Not heard", FAINT)
    if not node["connected"]:
        return "Not plugged in", FAINT
    if node["error"] == OLDER:
        return "Old firmware", AMBER
    if node["error"] == NEWER:
        return "Newer firmware", AMBER
    if node.get("hub"):
        return ("Hub", GREEN) if node["hub_ready"] else ("Hub", AMBER)
    if node["state"] == "run":
        return "Scanning", GREEN
    if old_firmware(node):
        return "Old firmware", AMBER
    return "Ready", MUTED


def channels_text(node):
    return "ch " + " ".join(str(channel) for channel in node["plan_channels"])


def link_text(node):
    """When a wireless node was last heard and how well the hub hears it."""
    parts = []
    if node["last_heard"] is not None:
        parts.append("heard %s ago" % ago(node["last_heard"]))
    if node.get("link_rssi") is not None:
        parts.append("%d dBm" % node["link_rssi"])
    return "  ".join(parts)


def hub_note(app):
    """A line for the Nodes list about the hub, or None."""
    hub = app.nodes.hub()
    if hub is None:
        return None
    if not hub["connected"]:
        return "The hub is unplugged. Wireless nodes wait for it.", AMBER
    if hub["error"]:
        return hub["error"], AMBER
    return None


def gps_text(fix):
    if fix.get("valid"):
        text = "%.5f, %.5f" % (fix["latitude"], fix["longitude"])
        if fix.get("satellites"):
            text += "  %d sats" % fix["satellites"]
        return text
    if fix.get("source", "none") == "none":
        return "No GPS found"
    return "Searching for a fix"


def gps_help(app):
    if app.square:
        return "Plug in a USB GPS or connect a receiver through gpsd."
    return "Plug in a USB GPS, the LoRa cap or a Grove GPS."


def supported_alerts(app, names):
    return [name for name in names if name != "lorawan"] if app.square else names


def gps_wait(app, s):
    """What the GPS is doing while a wardrive waits for its first usable fix, and what to do about it."""
    fix = s["gps"]
    source = fix.get("source", "none")
    satellites = fix.get("satellites")
    plugged = [port for port in app.hw.gps_ports if port.get("kind") == "usb" and port.get("likely")]
    if app.cfg.get("gps_source") == "off":
        return "GPS is off in Settings", "Turn it on in Settings to log."
    if source != "none":
        if s["gps_weak"]:
            detail = "%s: fix too weak (HDOP %.1f)" % (source, fix["hdop"])
        elif fix.get("valid"):
            old = (fix.get("age_seconds") or 0) > wigle.FIX_MAX_AGE
            return "%s: fix %s" % (source, "too old" if old else "not usable yet"), \
                "Waiting for a current position and time."
        elif satellites:
            detail = "%s: %s in view" % (source, plural(satellites, "satellite"))
        else:
            detail = "%s: searching for satellites" % source
        return detail, "Give it a clear view of the sky."
    if plugged:
        return plugged[0]["label"] + " found", "Waiting for it to send a position."
    return "No GPS found", gps_help(app)


class Splash(Screen):
    chrome = False
    refresh = 0.04

    def __init__(self):
        self.started = None

    def hints(self, app):
        return []

    def render(self, c, app):
        if self.started is None:
            self.started = time.monotonic()
        c.image.paste(splash.frame(min(1.0, (time.monotonic() - self.started) / splash.SECONDS)), (0, 0))

    def done(self):
        return self.started is not None and time.monotonic() - self.started >= splash.SECONDS + splash.HOLD

    def handle(self, key, app):
        app.pop()
        return True


class Home(Screen):
    title = "QUARTERMASTER"
    TILES = [("W", "Wardrive", "wifi"), ("R", "Recon", "eye"), ("L", "Logs", "folder"), ("U", "Uploads", "cloud"),
             ("H", "Hardware", "chip"), ("S", "Settings", "sliders"), ("K", "Keys", "key"), ("A", "About", "anchor")]
    COLUMNS = 4

    def __init__(self):
        self.index = 0

    def hints(self, app):
        return [("OK", "Open"), ("Space", "Stop wardrive" if app.wardriving else "Start wardrive"), ("Letter", "Jump")]

    def subtitle(self, label, app):
        if label == "Wardrive":
            if app.wardriving:
                if app.drive.waiting:
                    return "No fix yet", AMBER
                return "REC " + clock(app.drive.elapsed()), RED
            radios = len(app.hw.adapters) + len(app.nodes.in_use())
            return (plural(radios, "radio") if radios else "BLE only"), MUTED
        if label == "Recon":
            if app.recon_running:
                summary = app.recon.summary()
                if summary["flagged"]:
                    return "%d flagged" % summary["flagged"], RED if summary["strong"] else AMBER
                return "Watching", GREEN
            return "Surveillance", MUTED
        if label == "Logs":
            count = len(app.log_files())
            return ("%d saved" % count if count else "None yet"), MUTED
        if label == "Uploads":
            status = app.upload_status()
            if status["uploading"]:
                return "Sending", GOLD
            if not status["keys"]:
                return "Add keys", AMBER if status["files"] else MUTED
            if status["waiting"]:
                return "%d waiting" % status["waiting"], AMBER
            return ("All sent", GREEN) if status["files"] else ("Ready", MUTED)
        if label == "Hardware":
            if app.hw.stalled:
                return "Check adapter", AMBER
            fix = app.gps.snapshot()
            if fix.get("valid"):
                return "GPS fix", GREEN
            return ("No GPS", AMBER) if fix.get("source", "none") == "none" else ("GPS searching", AMBER)
        if label == "Settings":
            return "Scan and log", MUTED
        if label == "Keys":
            return "%d of 3 set" % len(accounts.ready(app.accounts())), MUTED
        return "v" + __version__, MUTED

    def render(self, c, app):
        gap, x0 = 4, 4
        tw = (W - 2 * x0 - gap * (self.COLUMNS - 1)) // self.COLUMNS
        th = 63
        for i, (letter, label, icon) in enumerate(self.TILES):
            x, y = x0 + (i % self.COLUMNS) * (tw + gap), TOP + (i // self.COLUMNS) * (th + gap)
            selected = i == self.index
            text, color = self.subtitle(label, app)
            live = (label == "Wardrive" and app.wardriving) or (label == "Recon" and app.recon_running)
            c.rect((x, y, x + tw, y + th), fill=SURFACE_2 if selected else SURFACE, outline=GOLD if selected else LINE,
                   radius=6)
            icons.draw(c, "record" if live and label == "Wardrive" else icon, x + 7, y + 7, 18,
                       color if live else (GOLD if selected else TEXT))
            c.text((x + tw - 7, y + 6), letter, font("monob", 9), GOLD if selected else FAINT, anchor="ra")
            c.text((x + 7, y + 32), label, font("bold", 11), TEXT, width=tw - 10)
            c.text((x + 7, y + 48), text, font("mono", 8), color, width=tw - 10)

    def handle(self, key, app):
        count = len(self.TILES)
        if key.name in ("LEFT", "RIGHT"):
            self.index = (self.index + (1 if key == "RIGHT" else -1)) % count
        elif key.name in ("UP", "DOWN"):
            self.index = (self.index + self.COLUMNS) % count
        elif key == "ENTER":
            app.open(self.TILES[self.index][1])
        elif key == "SPACE":
            if app.wardriving:
                app.ask_stop_wardrive()
            else:
                app.start_wardrive()
        elif key.name in [tile[0] for tile in self.TILES]:
            self.index = next(i for i, tile in enumerate(self.TILES) if tile[0] == key.name)
            app.open(self.TILES[self.index][1])
        elif key in ("ESC", "BACKSPACE", "Q"):
            app.ask_quit()
        else:
            return False
        return True


class Wardrive(Screen):
    title = "WARDRIVE"
    refresh = 0.25
    NEXT = {"all": "wifi", "wifi": "ble", "ble": "all"}
    LABEL = {"all": "All", "wifi": "Wi-Fi", "ble": "Bluetooth"}
    KINDS = {"all": None, "wifi": (WIFI,), "ble": (BLE, BT)}
    BANNER_Y = TOP + 59

    def __init__(self, app):
        self.filter = app.cfg.get("live_list", "all")

    def hints(self, app):
        if app.drive is not None and app.drive.waiting:
            hints = [("OK", "Stop"), ("Esc", "Menu")]
        else:
            hints = [("OK", "Stop + save"), ("Tab", self.LABEL[self.filter]), ("Esc", "Menu")]
        if app.drive is not None and app.drive.watch is not None:
            hints.insert(2, ("A", "Alerts"))
            if app.drive.watch.quiet_left() > 0:
                hints.insert(3, ("Q", "End quiet"))
        return hints

    @staticmethod
    def waiting(c, app, s, y):
        """The drive has not had a usable fix yet: the timer, the counters and the log start with the first one."""
        c.rect((4, y, W - 4, y + 43), fill=SURFACE, radius=5)
        c.rect((4, y, 7, y + 43), fill=AMBER, radius=1)
        on = int(time.monotonic() * 2) % 2 == 0
        c.draw.ellipse((14, y + 7, 22, y + 15), fill=AMBER if on else SURFACE, outline=AMBER)
        c.text((28, y + 2), "Waiting for GPS fix", font("display", 16), AMBER, width=W - 40)
        detail, hint = gps_wait(app, s)
        c.text((14, y + 21), detail, font("ui", 10), TEXT, width=W - 26)
        c.text((14, y + 32), hint, font("ui", 8), MUTED, width=W - 26)

    @staticmethod
    def warning(app, s):
        fix = s["gps"]
        if s["error"]:
            return s["error"], RED
        waiting = s.get("waiting_for_fix")
        if not waiting and not fix.get("valid"):
            if fix.get("source", "none") == "none":
                return "No GPS found. Logging pauses until one has a fix.", AMBER
            return "GPS fix lost. Logging pauses until it is back.", AMBER
        if not waiting and s["gps_weak"]:
            return "GPS fix is too weak. Logging waits for a better one.", AMBER
        errors = ["%s: %s" % (a["interface"], a["error"]) for a in s["adapters"] if a.get("error")]
        if errors:
            return errors[0], AMBER
        if app.hw.stalled:
            return "%s is not starting. See Hardware." % app.hw.stalled[0]["label"], AMBER
        parked = (s.get("power") or {}).get("parked")
        if parked:
            return "%s paused to save USB power. Use a powered hub." % parked[0], AMBER
        if s["ble_error"]:
            return s["ble_error"], AMBER
        if not app.square and (s.get("lora") or {}).get("state") == mesh.FAILED:
            return "The LoRa cap stopped listening. See Hardware.", AMBER
        if not app.square and s.get("lora") is not None and not app.cfg.get("country_set"):
            return "LoRa uses the %s band. Set your country in Settings." % lora.region_name(
                app.cfg.get("country", "US")), AMBER
        return None

    def render(self, c, app):
        drive = app.drive
        if drive is None:
            return
        s = drive.status()
        waiting = s["waiting_for_fix"]
        y = TOP - 1
        x = 4
        if waiting:
            self.waiting(c, app, s, y)
        else:
            counters = (("WI-FI", s["wifi"], GOLD), ("BLUETOOTH", s["ble"], CYAN), ("LOGGED", s["rows"], GREEN))
            for i, (label, value, color) in enumerate(counters):
                cx = 4 + i * 105
                c.rect((cx, y, cx + 101, y + 43), fill=SURFACE, radius=5)
                c.text((cx + 6, y + 2), label, font("ui", 8), MUTED)
                text = "{:,}".format(value)
                size = 30 if len(text) <= 5 else 24 if len(text) <= 6 else 19
                c.put((cx + 6, y + 41), text, font("display", size), color, "ls")
        y += 46
        for band in () if waiting else ("2.4", "5", "6"):
            x += c.pill(x, y, "%s GHz %d" % (band, s["bands"].get(band, 0)), font("monob", 8), BG, BAND_COLOR[band],
                        height=11) + 4
        watch = s.get("watch")
        from .recon_screens import BANNER_H, BANNER_TOP, banner_y, drive_alert, quiet_text
        quiet = quiet_text(drive.watch)
        if quiet:
            x += c.pill(x, y, "Q " + quiet, font("monob", 8), BG, MUTED, height=11) + 4
        elif watch and watch["alerts"]:
            x += c.pill(x, y, "!%d" % watch["alerts"], font("monob", 8), BG, RED if watch["urgent"] else AMBER,
                        height=11) + 4
        deep = s.get("deep")
        if deep and deep.get("monitor"):
            flock = (deep.get("counts") or {}).get("flock", 0)
            many = len(deep.get("listeners") or ())
            x += c.pill(x, y, "DEEP" + ("x%d" % many if many > 1 else "") + (" F%d" % flock if flock else ""),
                        font("monob", 8), BG, GOLD, height=11) + 4
        guard, notice = drive.guard, (s.get("power") or {}).get("notice")
        if notice and guard is not None and guard.said != notice["id"]:
            guard.said = notice["id"]
            app.toast(notice["text"], AMBER, 6)
        if watch and watch["speaker"] is False and not drive.watch.speaker_said:
            drive.watch.speaker_said = True
            app.toast("No speaker found: alerts show on screen only", AMBER, 5)
        small = font("ui", 8)
        extra = []
        if s.get("aircraft") is not None:
            extra.append(("%d aircraft" % s["aircraft"],
                          (s.get("adsb") or {}).get("state") in (adsb.RUNNING, adsb.SYSTEM)))
        if s.get("mesh") is not None:
            extra.append(("%d mesh" % s["mesh"], (s.get("lora") or {}).get("state") == mesh.LISTENING))
        nodes = sum(1 for a in s["adapters"] if a.get("method") == "node")
        radios = [plural(count, word) for count, word in ((len(s["adapters"]) - nodes, "radio"), (nodes, "node"))
                  if count]
        radios = " + ".join(radios) or "0 radios"
        needed = sum(int(c.text_width(text, small)) + 8 for text, _ in extra)
        if extra and W - 12 - int(c.text_width(radios, small)) - needed + 8 < x + 2:
            radios = plural(len(s["adapters"]), "radio")
        c.text_right(W - 4, y + 1, radios, small, MUTED)
        right = W - 12 - int(c.text_width(radios, small))
        for text, fine in extra:
            if right - c.text_width(text, small) < x + 2:
                break
            c.text_right(right, y + 1, text, small, MUTED if fine else AMBER)
            right -= int(c.text_width(text, small)) + 8
        y += 14
        bottom = CONTENT_BOTTOM
        if app.screen is self and drive_alert(app) is not None:
            if banner_y(app, self) == BANNER_TOP:
                bottom = BANNER_TOP - 2
            else:
                y = self.BANNER_Y + BANNER_H + 3
        warning = self.warning(app, s)
        if warning:
            c.text((5, y - 1), warning[0], font("ui", 9), warning[1], width=W - 10)
            y += 12
        if waiting:
            c.text_center(W // 2, y + 4, "Radios are warming up. Nothing is counted yet.", font("ui", 9), MUTED)
            c.text_center(W // 2, y + 17, "The timer, the counters and the log start at the fix.", font("ui", 9),
                          MUTED)
            return
        devices = drive.tracker.recent(max(0, (bottom - y) // 13), self.KINDS[self.filter])
        for device in devices:
            wifi = device.kind == WIFI
            c.tag(4, y + 1, (device.band or "?") if wifi else "BT", BAND_COLOR.get(device.band, GOLD) if wifi else CYAN,
                  21)
            name = device.name or ("(hidden)" if wifi else device.mac)
            c.text((29, y), name, font("ui", 10), FAINT if device.ignored else TEXT if device.name else MUTED,
                   width=150)
            if device.ignored:
                c.text((184, y + 1), "IGNORED", font("monob", 8), FAINT)
            elif wifi:
                c.text((184, y + 1), device.security, font("monob", 8), SECURITY_COLOR.get(device.security, MUTED))
                c.text_right(248, y + 1, "ch%s" % (device.channel or "?"), font("mono", 8), MUTED)
            c.text_right(W - 24, y + 1, fmt_rssi(device.rssi) if device.rssi is not None else "", font("mono", 8),
                         rssi_color(device.rssi))
            c.signal_bars(W - 20, y + 1, device.rssi, rssi_color(device.rssi))
            y += 13
        if not devices:
            c.text_center(W // 2, y + 14, "Listening…", font("ui", 11), MUTED)

    def handle(self, key, app):
        if key in ("ENTER", "S"):
            app.ask_stop_wardrive()
        elif key == "A" and app.drive is not None and app.drive.watch is not None:
            from .recon_screens import DriveAlerts
            app.push(DriveAlerts())
        elif key == "Q" and not key.repeat and app.drive is not None and app.drive.watch is not None:
            from .recon_screens import toggle_quiet
            toggle_quiet(app)
        elif key.name in ("TAB", "LEFT", "RIGHT"):
            if not key.repeat:
                self.filter = self.NEXT[self.filter]
        else:
            return super().handle(key, app)
        return True


class Summary(Screen):
    def __init__(self, status):
        self.s = status
        saved = status["log"] or status.get("aircraft_log") or status.get("mesh_log")
        self.title = "WARDRIVE SAVED" if saved and not status["failed"] else "WARDRIVE ENDED"

    def hints(self, app):
        return [("Esc", "Menu"), ("L", "Logs"), ("U", "Uploads"), ("W", "New wardrive")]

    def render(self, c, app):
        s = self.s
        files = s.get("files", 0)
        saved = s["log"] or s.get("aircraft_log") or s.get("mesh_log") or ""
        rows = [("Wi-Fi networks", "{:,}".format(s["wifi"])), ("Bluetooth devices", "{:,}".format(s["ble"])),
                ("2.4 / 5 / 6 GHz", "%d / %d / %d" % tuple(s["bands"].get(b, 0) for b in ("2.4", "5", "6"))),
                ("WiGLE rows", "{:,}".format(s["rows"])),
                ("Time", "No fix" if s.get("waiting_for_fix") else clock(s["elapsed"])),
                ("Saved as", (saved.rsplit("/", 1)[-1][14:29] + ("  +%d more" % (files - 1) if files > 1 else ""))
                 if saved else "Nothing" if s["failed"] else "Nothing: GPS never had a fix")]
        sky, heard = s.get("aircraft"), s.get("mesh")
        if sky is not None and heard is not None:
            rows.insert(2, ("Aircraft / mesh nodes", "{:,} / {:,}".format(sky, heard)))
        elif sky is not None or heard is not None:
            rows.insert(2, ("Aircraft" if heard is None else "Mesh nodes", "{:,}".format(sky if heard is None
                                                                                         else heard)))
        step = 17 if len(rows) <= 6 else 15
        if s["failed"]:
            c.text((8, TOP - 1), s["failed"], font("ui", 9), RED, width=W - 16)
        for i, (label, value) in enumerate(rows):
            y = TOP + (12 if s["failed"] else 0) + i * step
            c.text((8, y), label, font("ui", 10), MUTED)
            c.text_right(W - 8, y, value, font("bold", 10), TEXT if label != "Saved as" or saved else AMBER)
            c.line((8, y + 14, W - 8, y + 14))
        if s["failed"]:
            return
        status = app.upload_status()
        sites = [info["name"] for service, info in status["services"].items()
                 if info["configured"] and service in uploads.sites(saved)]
        if s.get("waiting_for_fix"):
            text, color = "Start again once the GPS has a fix.", AMBER
        elif not saved:
            text, color = "A GPS fix is needed before rows can be logged.", MUTED
        elif not sites:
            text, color = "Press K to add your upload keys.", AMBER
        elif not status["auto"]:
            text, color = "Automatic uploads are off. Press U to send it.", MUTED
        else:
            text, color = "Uploading to %s." % ", ".join(sites), GREEN
        c.text((8, TOP + 106), text, font("ui", 9), color, width=W - 16)

    def handle(self, key, app):
        if key == "L":
            app.open("Logs")
        elif key == "U":
            app.open("Uploads")
        elif key == "K":
            app.open("Keys")
        elif key == "W":
            app.start_wardrive()
        elif key in ("ESC", "BACKSPACE", "ENTER"):
            app.home()
        else:
            return False
        return True


class Hardware(Screen):
    title = "HARDWARE"
    VISIBLE = 5

    def __init__(self):
        self.top = 0

    def hints(self, app):
        if sky_ready(app)[0]:
            return [("A", "Aircraft"), ("F/X", "Scroll"), ("Esc", "Back")]
        return [("F/X", "Scroll"), ("Esc", "Back")]

    def cards(self, app):
        scanning, status = {}, app.drive.status() if app.wardriving else None
        if status is not None:
            scanning = {a["interface"]: a for a in status["adapters"]}
        cards = []
        for item in app.hw.stalled:
            title, detail = hardware.stall_words(item)
            cards.append({"tag": "!", "color": AMBER, "title": title, "edge": AMBER, "detail": detail,
                          "detail_color": AMBER})
        deep = status.get("deep") if status is not None else None
        monitor = (deep or {}).get("monitor")
        guard = (status or {}).get("power") or {}
        parked = set(guard.get("parked") or ()) | set((deep or {}).get("paused") or ())
        listeners = {item["interface"]: item for item in (deep or {}).get("listeners") or ()}
        originals = {item["original"] for item in listeners.values()}
        if monitor is not None:
            originals.add(monitor.get("original"))
        joining = set((deep or {}).get("joining") or ())
        for adapter in app.hw.adapters:
            live = scanning.get(adapter["interface"])
            if monitor is not None and adapter["interface"] == monitor.get("interface"):
                cards.append(self.monitor_card(monitor, deep, live))
                continue
            if adapter["interface"] in listeners:
                cards.append(self.listen_card(listeners[adapter["interface"]]))
                continue
            if adapter["interface"] in originals:
                continue
            card = {"tag": "USB" if adapter["external"] else "INT", "color": GOLD if adapter["external"] else MUTED,
                    "title": "%s  %s" % (adapter["interface"], adapter["label"]), "bands": adapter["bands"],
                    "right": adapter["band_label"]}
            if adapter["interface"] in parked:
                card.update(detail="Paused to save USB power", detail_color=AMBER, right="")
            elif adapter["interface"] in joining:
                card.update(detail="Starts listening in a moment", right="")
            elif live and live.get("error"):
                card.update(bands=(), detail=live["error"], detail_color=AMBER, right="")
            elif live:
                card["right"] = plural(live.get("sweeps") or 0, "sweep")
            elif not adapter["bands"]:
                card.update(detail="No usable bands reported", detail_color=AMBER, right="")
            if deep is not None and not card.get("detail"):
                card.update(self.deep_words(adapter, deep, monitor))
            cards.append(card)
        shown = {a["interface"] for a in app.hw.adapters}
        if deep is not None and monitor is not None and monitor.get("interface") not in shown:
            cards.append(self.monitor_card(monitor, deep, scanning.get(monitor.get("interface"))))
        for name, item in listeners.items():
            if name not in shown and (monitor is None or name != monitor.get("interface")):
                cards.append(self.listen_card(item))
        card = self.deep_card(app, deep)
        if card is not None:
            cards.append(card)
        cards.extend(self.power_cards(app, guard))
        known = app.nodes.known()
        if not app.hw.adapters and not any(node["connected"] for node in known):
            cards.append({"tag": "WIFI", "color": AMBER, "title": "No Wi-Fi adapter found",
                          "detail": "Bluetooth still scans. Plug in a USB adapter any time."})
        cards.extend(self.node_card(node) for node in known)
        for node in app.nodes.found():
            cards.append({"tag": "NEW", "color": GOLD, "title": "New node found  " + default_name(node),
                          "detail": "Add it under Settings > Nodes."})
        for card in (self.aircraft_card(app, status), self.lora_card(app, status)):
            if card is not None:
                cards.append(card)
        fix = app.gps.snapshot()
        source = fix.get("source", "none")
        plugged = [port for port in app.hw.gps_ports if port.get("kind") == "usb" and port.get("likely")]
        if app.cfg.get("gps_source") == "off":
            title, detail = "GPS is off in Settings", "Rows cannot be logged without a position."
        elif source != "none":
            title, detail = source, gps_text(fix) if fix.get("valid") else "No fix yet. It needs a view of the sky."
        elif plugged:
            title, detail = plugged[0]["label"] + " found", "Waiting for it to send a position."
        else:
            title, detail = "No GPS found", gps_help(app)
        cards.append({"tag": "GPS", "color": GREEN if fix.get("valid") else AMBER, "title": title, "detail": detail,
                      "right": "HDOP %.1f" % fix["hdop"] if fix.get("valid") and isinstance(
                          fix.get("hdop"), (int, float)) else ""})
        for radio in app.hw.bluetooth or [None]:
            if radio is None:
                cards.append({"tag": "BT", "color": AMBER, "title": "No Bluetooth adapter found",
                              "detail": "Bluetooth devices cannot be logged."})
            else:
                cards.append({"tag": "BT", "color": CYAN, "title": "%s  %s" % (radio["name"], radio["label"]),
                              "detail": "Scans Bluetooth LE and classic" if app.cfg.get("ble", True)
                              else "Bluetooth scan is off in Settings"})
        return cards

    @staticmethod
    def power_cards(app, guard):
        """The USB power estimate, and what Power guard eased in this wardrive."""
        cards = []
        if guard.get("line"):
            cards.append({"tag": "USB", "color": MUTED, "title": guard["line"],
                          "detail": "Estimate. Listening adapters draw less."})
        for title, detail, problem in powerguard.load_cards(guard.get("load") or getattr(app.hw, "power", None)):
            card = {"tag": "PWR", "color": AMBER if problem else MUTED, "title": title, "detail": detail}
            if problem:
                card.update(edge=AMBER, detail_color=AMBER)
            cards.append(card)
        if guard.get("troubles"):
            if guard.get("parked"):
                title = "USB power ran short: %s paused" % plural(len(guard["parked"]), "adapter")
            elif guard.get("eased"):
                title = "USB power ran short: adapters eased"
            else:
                title = "USB power ran short"
            reason = guard.get("reason") or ""
            detail = reason if guard.get("eased") else ("%s. Use a powered USB hub." % reason if reason else
                                                        "Use a powered USB hub.")
            cards.append({"tag": "PWR", "color": AMBER, "edge": AMBER, "title": title, "detail": detail,
                          "detail_color": AMBER})
        if guard.get("usb_limit"):
            cards.append({"tag": "USB", "color": AMBER, "edge": AMBER, "title": "USB port at its limit",
                          "detail": "%s. Extra adapters eased." % (guard.get("limit_reason") or "USB errors"),
                          "detail_color": AMBER})
        for state in (guard.get("revive") or {}).values():
            if state.get("needs_power"):
                cards.append({"tag": "!", "color": AMBER, "edge": AMBER, "title": "%s needs power" % state["label"],
                              "detail": "Reset %d times, still off. Use a powered USB hub." % state["tries"],
                              "detail_color": AMBER})
            elif state.get("tries"):
                cards.append({"tag": "!", "color": AMBER, "title": state["label"],
                              "detail": "Dropped out. USB reset %d of %d." % (state["tries"], powerguard.RESET_TRIES),
                              "detail_color": AMBER})
        return cards

    @staticmethod
    def listen_card(item):
        """A second or further adapter listening with All adapters listen."""
        return {"tag": "MON", "color": GOLD, "title": "%s  %s" % (item["interface"], item.get("label", "")),
                "detail": "Listens on its own %s" % plural(item.get("channels") or 0, "channel"),
                "right": item.get("original", "")}

    @staticmethod
    def monitor_card(monitor, deep, live):
        stats = deep.get("stats") or {}
        heard = "ch 11·6·1 + 2.4 GHz" if deep.get("plan") == "flock" else "ch 11·6·1 + 2.4 + 5 GHz busy"
        listeners = deep.get("listeners") or ()
        mine = next((item for item in listeners if item["interface"] == monitor.get("interface")), None)
        if len(listeners) > 1 and mine is not None:
            heard = "ch 11·6·1 + %d more, %d listen" % (max(0, mine["channels"] - 3), len(listeners))
        parts = ["Deep scan: " + heard]
        if stats.get("frames_per_s") is not None:
            parts.append("{:,} fr/s".format(int(stats["frames_per_s"])))
            parts.append("%.1f%% dropped" % (stats.get("dropped_share") or 0.0))
        counts = deep.get("counts") or {}
        right = "%d Flock" % counts.get("flock", 0)
        if deep.get("level", 0) >= 3:
            parts = ["Busy CPU: Flock channels only"]
        card = {"tag": "MON", "color": GOLD, "title": "%s  %s" % (monitor.get("interface"), monitor.get("label", "")),
                "detail": "  ·  ".join(parts), "right": right}
        if live and live.get("error"):
            card.update(detail=live["error"], detail_color=AMBER)
        return card

    @staticmethod
    def deep_words(adapter, deep, monitor):
        """Why an adapter scans normally while Deep scan is on, and the tuning line."""
        words = {}
        reason = (deep.get("reasons") or {}).get(adapter["interface"])
        if monitor is not None and "6" in adapter.get("bands", ()):
            words = {"detail": "Keeps 6 GHz"}
        elif reason:
            problem = reason.startswith(("No monitor", "Connected", "Only 6"))
            words = {"detail": reason, "detail_color": AMBER if problem else FAINT}
        tuning = (deep.get("tuning") or {}).get(adapter["interface"])
        if tuning and tuning.get("eased"):
            words = {"detail": (words["detail"] + "  ·  " if words.get("detail") else "") +
                     "Tuning undone to save USB power", "detail_color": AMBER}
        elif tuning and not tuning.get("error"):
            tx = tuning.get("txpower")
            limit = tuning.get("limit")
            line = "Power save off · tx %s dBm%s" % ("%g" % tx if tx is not None else "?",
                                                     " (limit %g)" % limit if limit is not None else "")
            if adapter.get("autosuspend") in ("on", "auto"):
                line += " · autosuspend %s" % ("off" if adapter["autosuspend"] == "on" else "on")
            words = {"detail": (words["detail"] + "  ·  " if words.get("detail") else "") + line,
                     "detail_color": words.get("detail_color", MUTED)}
        return words

    @staticmethod
    def deep_card(app, deep):
        """Deep scan's own line: why it does not listen, or the helper's state."""
        from .. import radio_helper
        if not app.cfg.get("deep_scan"):
            return None
        if deep is None:
            if not os.path.exists(radio_helper.SOCKET):
                return {"tag": "DEEP", "color": AMBER, "edge": AMBER, "title": "Deep scan",
                        "detail": radio_helper.words("missing"), "detail_color": AMBER}
            return {"tag": "DEEP", "color": MUTED, "title": "Deep scan",
                    "detail": "Starts with the next wardrive or Recon."}
        if deep.get("state") != "ready":
            return {"tag": "DEEP", "color": AMBER, "edge": AMBER, "title": "Deep scan",
                    "detail": radio_helper.words(deep.get("state"), deep.get("detail", "")), "detail_color": AMBER}
        if deep.get("error"):
            return {"tag": "DEEP", "color": AMBER, "edge": AMBER, "title": "Deep scan", "detail": deep["error"],
                    "detail_color": AMBER}
        if deep.get("unavailable"):
            return {"tag": "DEEP", "color": AMBER, "title": "Deep scan unavailable", "detail": deep["unavailable"],
                    "detail_color": AMBER}
        return None

    @staticmethod
    def aircraft_card(app, status):
        """The RTL-SDR stick, when aircraft are on in Settings or one is plugged in. On Auto, while one is plugged
        in or the wardrive listens with it."""
        plugged, on = getattr(app.hw, "sdr", []), app.cfg.get("adsb", "auto")
        live = status.get("adsb") if status is not None else None
        if not plugged and (on is False or on == "auto" and live is None):
            return None
        card = {"tag": "SDR", "color": GOLD, "title": "Radio for aircraft (RTL-SDR)"}
        if on is False:
            state = adsb.OFF
        elif live is not None:
            state = live["state"]
        elif not plugged:
            state = adsb.NO_DONGLE
        elif getattr(app.hw, "sky_use", "") == adsb.SYSTEM:
            state = adsb.SYSTEM
        elif not getattr(app.hw, "decoder", ""):
            state = adsb.NO_TOOLS
        else:
            state = getattr(app.hw, "sky_use", "") or adsb.READY
        card["detail"] = adsb.WORDS[state]
        view = ("K3: Aircraft" if app.square else "A: viewer") if sky_ready(app)[0] else ""
        if state in (adsb.RUNNING, adsb.SYSTEM):
            count = "%d aircraft" % live["aircraft"] if live is not None else ""
            card.update(detail_color=GREEN, right=" · ".join(part for part in (count, view) if part))
        elif state == adsb.OFF:
            card.update(color=FAINT, detail_color=FAINT, right=view)
        elif state != adsb.READY:
            card.update(color=AMBER, edge=AMBER, detail_color=AMBER)
        else:
            card["right"] = view
        return card

    @staticmethod
    def lora_card(app, status):
        """The Cap LoRa-1262: on On always, on Off and Auto once it was found."""
        if app.square:
            return None
        cap, on = app.cap, app.cfg.get("lora", "auto")
        live = status.get("lora") if status is not None else None
        if live is None and not cap.found and on is not True:
            return None
        country = app.cfg.get("country", "US")
        card = {"tag": "LORA", "color": GOLD, "title": "Cap LoRa-1262 for mesh nodes",
                "right": lora.region_name(country)}
        if on is False:
            return dict(card, color=FAINT, detail=mesh.WORDS[lora.OFF], detail_color=FAINT, right="")
        if live is not None and live["state"] == mesh.LISTENING:
            return dict(card, detail=live["detail"], detail_color=GREEN, right=plural(live["packets"], "packet"))
        if live is not None:
            state = live["reason"] or live["state"]
        elif not lora.plan(country):
            state = mesh.NO_BAND
        elif cap.found and not app.cfg.get("country_set"):
            return dict(card, detail="Set your country in Settings.", detail_color=AMBER)
        elif cap.found:
            return dict(card, detail="Ready. It listens in the next wardrive.")
        else:
            state = cap.state
        card.update(detail=mesh.WORDS.get(state, mesh.WORDS[mesh.FAILED]), right="")
        if state != lora.CHECKING:
            card.update(color=AMBER, edge=AMBER, detail_color=AMBER)
        return card

    @staticmethod
    def node_card(node):
        if node["wireless"] and not node["port"]:
            return Hardware.wireless_card(node)
        card = {"tag": "NODE", "color": GOLD, "title": "%s  %s" % (node["name"], board_name(node))}
        if node["hub"] and node["connected"] and not node["error"] and not node["updating"]:
            count = plural(node["wireless_nodes"], "wireless node")
            card.update(tag="HUB", detail="Hub for %s. It does not scan." % count, right="firmware " + node["firmware"])
            return card
        if node["updating"]:
            card.update(detail="Being updated", detail_color=GOLD)
        elif not node["connected"]:
            card.update(color=FAINT, detail="Not plugged in", detail_color=FAINT)
        elif node["error"]:
            card.update(color=AMBER, edge=AMBER, detail=node["error"], detail_color=AMBER)
        elif node["in_use"]:
            card.update(bands=node["plan_bands"], detail=channels_text(node), right=plural(node["sweeps"], "sweep"))
        elif old_firmware(node):
            card.update(detail="Old firmware. Update it under Settings > Nodes.", detail_color=AMBER)
        else:
            card.update(detail="Ready. It scans in the next wardrive or Recon.", right="firmware " + node["firmware"])
        return card

    @staticmethod
    def wireless_card(node):
        card = {"tag": "NODE", "color": GOLD, "title": "%s  wireless" % node["name"],
                "right": "" if node["error"] else link_text(node)}
        if not node["connected"]:
            card.update(color=FAINT, detail=node["error"], detail_color=FAINT)
        elif node["error"]:
            card.update(color=AMBER, edge=AMBER, detail=node["error"], detail_color=AMBER)
        elif node["in_use"]:
            card.update(bands=node["plan_bands"], detail=channels_text(node))
        else:
            card.update(detail="Ready. It scans in the next wardrive or Recon.")
        return card

    def render(self, c, app):
        cards = self.cards(app)
        self.top = max(0, min(self.top, len(cards) - self.VISIBLE))
        for i, card in enumerate(cards[self.top:self.top + self.VISIBLE]):
            y = TOP - 2 + i * 27
            c.rect((4, y, W - 9, y + 25), fill=SURFACE, outline=card.get("edge"), radius=5)
            c.tag(8, y + 2, card["tag"], card["color"], 25)
            c.text((37, y + 1), card["title"], font("bold", 10), TEXT, width=W - 52)
            right = card.get("right") or ""
            if right:
                c.text_right(W - 14, y + 14, right, font("ui", 8), MUTED)
            x = 37
            for band in card.get("bands", ()):
                x += c.pill(x, y + 15, band + " GHz", font("monob", 8), BG, BAND_COLOR[band], height=8) + 3
            if card.get("detail"):
                room = W - 20 - x - (int(c.text_width(right, font("ui", 8))) + 6 if right else 0)
                c.text((x, y + 14), card["detail"], font("ui", 8), card.get("detail_color", MUTED), width=room)
        if len(cards) > self.VISIBLE:
            span = CONTENT_BOTTOM - 2 - TOP
            height = max(8, span * self.VISIBLE // len(cards))
            c.rect((W - 4, TOP, W - 3, CONTENT_BOTTOM - 2), fill=LINE)
            y = TOP + (span - height) * self.top // (len(cards) - self.VISIBLE)
            c.rect((W - 5, y, W - 2, y + height), fill=MUTED, radius=1)

    def handle(self, key, app):
        if key.name in ("UP", "DOWN"):
            self.top = max(0, self.top + (1 if key == "DOWN" else -1))
            return True
        if key == "A" and not key.repeat:
            ready, why = sky_ready(app)
            if ready:
                from .sky_screens import AircraftList
                app.push(AircraftList(app))
            else:
                app.toast(why, AMBER, 4)
            return True
        return super().handle(key, app)


def sky_ready(app):
    """Whether the aircraft viewer can show anything now, and why not: an RTL-SDR stick must be plugged in and
    rtl_adsb installed. During a wardrive the viewer reads what the wardrive hears, so the wardrive must listen."""
    if app.wardriving:
        live = app.drive.aircraft
        if live is None:
            return False, "This wardrive does not listen for aircraft"
        state = live.status()["state"]
        return state in (adsb.RUNNING, adsb.SYSTEM), adsb.WORDS.get(state, "")
    use = getattr(app.hw, "sky_use", "")
    if use == adsb.SYSTEM:
        return True, ""
    if not getattr(app.hw, "sdr", []):
        return False, "No RTL-SDR stick is plugged in"
    if use == adsb.BUSY:
        return False, adsb.WORDS[adsb.BUSY]
    if "rtl_adsb" not in os.path.basename(getattr(app.hw, "decoder", "") or ""):
        return False, adsb.WORDS[adsb.NO_TOOLS]
    return True, ""


def upload_mark(c, x, y, mark):
    """One dot per site: green sent, amber waiting, red refused, hollow when no key is saved."""
    box = (x - 4, y, x + 4, y + 8)
    if mark == "done":
        c.draw.ellipse(box, fill=GREEN)
    elif mark == "rejected":
        c.draw.ellipse(box, fill=RED)
    elif mark == "waiting":
        c.draw.ellipse(box, outline=AMBER, width=2)
    elif mark == "none":
        c.line((x - 3, y + 4, x + 3, y + 4), fill=FAINT)
    else:
        c.draw.ellipse(box, outline=LINE, width=1)


class Logs(Screen, ListMixin):
    title = "LOGS"
    VISIBLE = 7
    refresh = 2.0
    COLUMNS = (222, 256, 290)

    def __init__(self):
        self.index = self.top = 0

    def hints(self, app):
        return [("OK", "Details"), ("U", "Upload now"), ("F/X", "Move"), ("Esc", "Back")]

    def render(self, c, app):
        files = app.log_files()
        if not files:
            empty_state(c, "folder", "No wardrives saved yet",
                        "Start a wardrive from the menu. Each one is saved as a WiGLE file in quartermaster/logs.")
            return
        c.text((11, TOP - 1), plural(len(files), "log"), font("bold", 7), FAINT)
        for x, service in zip(self.COLUMNS, uploads.SERVICES):
            c.text_center(x, TOP - 1, SITE_SHORT[service], font("bold", 7), FAINT)
        self.clamp(len(files), self.VISIBLE)
        saved = app.accounts()
        for row, entry in enumerate(files[self.top:self.top + self.VISIBLE]):
            y = TOP + 10 + row * 17
            if self.top + row == self.index:
                c.select(y, 15)
            c.text((11, y + 2), when(entry["epoch"]), font("mono", 10), TEXT)
            if entry["active"]:
                c.pill(116, y + 2, "REC", font("monob", 8), WHITE, (150, 24, 28), height=11)
                continue
            if entry.get("aircraft"):
                c.pill(116, y + 2, "AIR", font("monob", 8), BG, GOLD, height=11)
            elif entry.get("mesh"):
                c.pill(116, y + 2, "MESH", font("monob", 8), BG, CYAN, height=11)
            c.text_right(196, y + 3, size_text(entry["size"]), font("mono", 9), MUTED)
            marks = app.uploader.marks(entry["name"], saved)
            for x, service in zip(self.COLUMNS, uploads.SERVICES):
                upload_mark(c, x, y + 4, marks[service])
        self.scrollbar(c, len(files), self.VISIBLE, y0=TOP + 10)

    def handle(self, key, app):
        files = app.log_files()
        self.clamp(len(files), self.VISIBLE)
        if self.move(key, len(files), self.VISIBLE):
            return True
        if key == "ENTER" and files:
            app.push(LogDetail(files[self.index]))
        elif key == "U":
            app.upload_now()
        else:
            return super().handle(key, app)
        return True


class Details(Screen, ListMixin):
    """Scrollable list of labelled values."""

    VISIBLE = 10

    def __init__(self, title):
        self.title = title
        self.index = self.top = 0

    def rows(self, app):
        return []

    def hints(self, app):
        return [("F/X", "Scroll"), ("Esc", "Back")]

    def layout(self, c, app):
        out = []
        for label, value, *rest in self.rows(app):
            color = rest[0] if rest else TEXT
            lines = c.wrap(str(value), W - (96 if label else 22), font("mono", 9)) or [""]
            out.append((label, lines[0], color))
            out.extend((None if label else "", line, color) for line in lines[1:])
        return out

    def render(self, c, app):
        rows = self.layout(c, app)
        self.top = max(0, min(self.top, max(0, len(rows) - self.VISIBLE)))
        for i, (label, value, color) in enumerate(rows[self.top:self.top + self.VISIBLE]):
            y = TOP + i * 13
            if label:
                c.text((8, y), label, font("ui", 9), MUTED)
            c.text((84 if (label or label is None) else 8, y), value, font("mono", 9), color)
        self.index = self.top
        self.scrollbar(c, len(rows), self.VISIBLE)

    def handle(self, key, app):
        step = {"UP": -1, "DOWN": 1, "PAGEUP": -self.VISIBLE, "PAGEDOWN": self.VISIBLE}.get(key.name)
        if step is not None:
            self.top = max(0, self.top + step)
            return True
        return super().handle(key, app)


class LogDetail(Details):
    def __init__(self, entry):
        super().__init__("LOG")
        self.entry = entry
        self.counts = None

    def hints(self, app):
        return [("U", "Upload again"), ("D", "Delete"), ("Esc", "Back")]

    def rows(self, app):
        entry = self.entry
        path, aircraft, heard = entry["path"], entry.get("aircraft"), entry.get("mesh")
        if self.counts is None and aircraft:
            self.counts = (None, line_count(adsb.summary_path(path), 1))
        elif self.counts is None and heard:
            self.counts = (None, line_count(mesh.summary_path(path), 1))
        elif self.counts is None:
            self.counts = (wigle.data_rows(path),
                           line_count(path.with_name(path.name.replace(".wigle.csv", ".summary.csv")), 1))
        rows = [("Recorded", when(entry["epoch"])), ("File", entry["name"]), ("Size", size_text(entry["size"]))]
        if self.counts[0] is not None:
            rows.append(("Rows", "{:,}".format(self.counts[0])))
        if self.counts[1] is not None:
            rows.append(("Aircraft" if aircraft else "Mesh nodes" if heard else "Devices",
                         "{:,}".format(self.counts[1])))
        if path == app.active_log():
            rows.append(("", "Still recording. It is sent after the wardrive stops.", AMBER))
            return rows
        marks = app.uploader.marks(entry["name"], app.accounts())
        for service in uploads.SERVICES:
            record = app.uploader.ledger.entry(entry["name"], service)
            name = accounts.SERVICE_NAMES[service]
            if marks[service] == "done":
                rows.append((name, record.get("detail") or "Sent", GREEN))
            elif marks[service] == "rejected":
                rows.append((name, record.get("detail") or "Refused", RED))
            elif marks[service] == "waiting":
                rows.append((name, record.get("detail") or "Waiting to be sent", AMBER))
            elif marks[service] == "none":
                rows.append((name, record.get("detail") or "Not for %s" % name, FAINT))
            else:
                rows.append((name, "No key saved", FAINT))
        if aircraft:
            rows.append(("", "Aircraft go to WDGWars and Wardrift only.", FAINT))
        elif heard:
            rows.append(("", "Mesh nodes go to WDGWars and Wardrift only.", FAINT))
        else:
            rows.append(("", "Download it from the phone setup page, under Keys.", FAINT))
        return rows

    def handle(self, key, app):
        if key == "U":
            app.upload_now(self.entry["name"])
        elif key == "D":
            if self.entry["path"] == app.active_log():
                app.toast("Stop the wardrive before deleting its log", AMBER)
            else:
                app.confirm("Delete this log?", "The file is removed from this device. Sites that already have "
                            "it keep their copy.", "Delete", lambda: app.delete_log(self.entry), danger=True)
        else:
            return super().handle(key, app)
        return True


def test_line(app, service):
    """The latest key check for a site as (text, color), or None."""
    state, detail = app.tests.get(service, ("", ""))
    if not state:
        return None
    color = {"busy": MUTED, uploads.DONE: GREEN, uploads.AUTH: RED}.get(state, AMBER)
    return detail, color


class Uploads(Screen):
    title = "UPLOADS"

    def hints(self, app):
        return [("OK", "Upload now"), ("T", "Test keys"), ("K", "Keys"), ("Esc", "Back")]

    @staticmethod
    def headline(status, now):
        if status["current"]:
            name, service = status["current"]
            return "Sending %s to %s" % (name[14:29], accounts.SERVICE_NAMES[service]), GOLD
        if not status["keys"]:
            return "Add a key to start uploading", AMBER
        if not status["files"]:
            return "No finished logs yet", MUTED
        if status["waiting"]:
            if status["next_try"]:
                wait = clock(max(0, status["next_try"] - now))[3:]
                return "%s waiting. Next try in %s" % (plural(status["waiting"], "upload"), wait), AMBER
            if not status["auto"]:
                return "%s waiting. Press OK to send" % plural(status["waiting"], "upload"), AMBER
            return "%s waiting" % plural(status["waiting"], "upload"), AMBER
        refused = sum(info["refused"] for info in status["services"].values())
        if refused:
            return "%s refused. Open the log to see why" % plural(refused, "upload"), RED
        return "Every log has been sent", GREEN

    def render(self, c, app):
        status = app.upload_status()
        text, color = self.headline(status, app.uploader.clock())
        c.text((8, TOP - 2), text, font("bold", 10), color, width=W - 100)
        c.text_right(W - 8, TOP - 1, "Automatic" if status["auto"] else "Manual", font("ui", 9), MUTED)
        for i, service in enumerate(uploads.SERVICES):
            info = status["services"][service]
            y = TOP + 14 + i * 38
            c.rect((4, y, W - 4, y + 35), fill=SURFACE, radius=5)
            c.text((10, y + 3), info["name"], font("bold", 11), TEXT)
            refused = info["blocked"] or info["last_state"] == uploads.AUTH
            if not info["configured"]:
                label, fg, bg = "NO KEY", MUTED, SURFACE_2
            elif refused:
                label, fg, bg = "KEY REFUSED", WHITE, (150, 24, 28)
            else:
                label, fg, bg = "KEY SAVED", GOLD, GOLD_DIM
            width = int(c.text_width(label, font("monob", 8))) + 8
            c.pill(W - 10 - width, y + 4, label, font("monob", 8), fg, bg, height=11)
            x = 10
            for count, word, tint in ((info["sent"], "sent", GREEN), (info["waiting"], "waiting", AMBER),
                                      (info["refused"], "refused", RED)):
                x += c.text((x, y + 17), "%d %s" % (count, word), font("mono", 9), tint if count else FAINT) + 10
            line = test_line(app, service)
            if line is None:
                line = (info["last"], MUTED) if info["last"] else \
                    (("Ready", FAINT) if info["configured"] else ("Press K to add your key", FAINT))
            c.text_right(W - 10, y + 18, c.fit(line[0], W - 30 - x, font("ui", 8)), font("ui", 8), line[1])

    def handle(self, key, app):
        if key == "ENTER":
            app.upload_now()
        elif key == "T":
            ready = accounts.ready(app.accounts())
            if not ready:
                app.toast("Add a key first: press K", AMBER)
            for service in ready:
                app.test_key(service)
        elif key == "K":
            app.push(Keys())
        else:
            return super().handle(key, app)
        return True


FIELD_SERVICE = {field: service for service, fields in accounts.SERVICES.items() for field in fields}


class Keys(Screen, ListMixin):
    title = "KEYS"
    VISIBLE = 5

    def __init__(self):
        self.index = self.top = 0

    def hints(self, app):
        if self.index == 0:
            return [("OK", "Open"), ("F/X", "Move"), ("Esc", "Back")]
        return [("OK", "Type it"), ("T", "Test"), ("D", "Remove"), ("Esc", "Back")]

    def render(self, c, app):
        saved = app.accounts()
        for row in range(len(accounts.FIELDS) + 1):
            y = TOP + row * 17
            if row == self.index:
                c.select(y, 15)
            if row == 0:
                icons.draw(c, "phone", 10, y + 2, 12, GOLD)
                c.text((26, y + 2), "Set up from a phone or PC", font("bold", 10), GOLD)
                c.text_right(W - 14, y + 2, "Easiest  ›", font("ui", 9), MUTED)
                continue
            field, label, _ = accounts.FIELDS[row - 1]
            value = saved.get(field, "")
            c.text((11, y + 2), label, font("ui", 10), TEXT)
            c.text_right(W - 14, y + 3, accounts.masked(value) if value else "Not set", font("mono", 9),
                         GREEN if value else FAINT)
        y = TOP + 5 * 17 + 4
        c.line((8, y, W - 8, y))
        if self.index == 0:
            lines = [("Scan a QR code, then paste all your keys in a web page.", MUTED),
                     ("Or pick a key below and type it on the Cardputer.", FAINT)]
        else:
            field, _, where = accounts.FIELDS[self.index - 1]
            lines = [("Find it at " + where, MUTED)]
            line = test_line(app, FIELD_SERVICE[field])
            lines.append(line or ("Press T to check that the key works.", FAINT))
        for i, (text, color) in enumerate(lines):
            c.text((10, y + 5 + i * 13), text, font("ui", 9), color, width=W - 20)

    def handle(self, key, app):
        if self.move(key, len(accounts.FIELDS) + 1, self.VISIBLE):
            return True
        if self.index == 0:
            if key == "ENTER":
                app.push(PhoneSetup(app))
                return True
            return super().handle(key, app)
        field, label, where = accounts.FIELDS[self.index - 1]
        service = FIELD_SERVICE[field]
        if key == "ENTER":
            app.push(TextInput(label, lambda value: app.save_key(field, value), hint="Find it at " + where,
                               limit=accounts.MAX_LENGTH, secret=bool(app.square)))
        elif key == "T":
            if accounts.configured(app.accounts(), service):
                app.test_key(service)
            else:
                app.toast("Save the %s key first" % accounts.SERVICE_NAMES[service], AMBER)
        elif key == "D":
            if app.accounts().get(field):
                app.confirm("Remove this key?", "%s is erased from this device." % label, "Remove",
                            lambda: app.save_key(field, ""), danger=True)
        else:
            return super().handle(key, app)
        return True


class PhoneSetup(Screen):
    title = "PHONE SETUP"
    refresh = 0.5

    def __init__(self, app):
        self.server = None
        self.error = ""
        self.addresses = []
        self.checked = 0.0
        self.code = (None, None)
        self.check(app)

    def hints(self, app):
        return [("Esc", "Close the page")]

    def check(self, app):
        self.checked = time.monotonic()
        self.addresses = app.hw.addresses()
        if self.addresses and self.server is None and not self.error:
            try:
                self.server = app.setup_server().start()
            except OSError as exc:
                self.error = "The setup page could not start: %s" % (exc.strerror or exc)

    def render(self, c, app):
        if time.monotonic() - self.checked > 3:
            self.check(app)
        if self.error:
            return empty_state(c, "phone", "Setup page unavailable", self.error)
        if self.server is None or not self.addresses:
            return empty_state(c, "phone", "Not on a network",
                               "Join Wi-Fi in the CardputerZero settings first. This screen updates by itself. "
                               "You can also type keys on the Cardputer.")
        url = "http://%s:%d" % (self.addresses[0], self.server.port)
        link = "%s/#%s" % (url, self.server.pin)
        if self.code[0] != link:
            try:
                self.code = (link, qr.image(link, scale=4, border=2))
            except ValueError:
                self.code = (link, None)
        picture = self.code[1]
        x = 8
        if picture is not None:
            c.paste(picture, (4, CONTENT_TOP + (CONTENT_BOTTOM - CONTENT_TOP - picture.height) // 2 + 1))
            x = 4 + picture.width + 8
        c.text((x, TOP), "Scan with your phone", font("bold", 11), GOLD)
        c.text((x, TOP + 16), "or open this in a browser:", font("ui", 9), MUTED)
        c.text((x, TOP + 29), url, font("bold", 10), TEXT, width=W - x - 4)
        c.text((x, TOP + 48), "PIN", font("ui", 9), MUTED)
        c.text((x, TOP + 58), "%s %s" % (self.server.pin[:3], self.server.pin[3:]), font("display", 24), GOLD)
        if self.server.locked:
            status, color = "Too many wrong PINs. Reopen this screen.", RED
        elif self.server.saves:
            status, color = "Saved from the page ✓", GREEN
        elif self.server.visits:
            status, color = "Page opened", GREEN
        else:
            status, color = "Waiting for your phone…", MUTED
        c.text((x, TOP + 91), status, font("ui", 9), color, width=W - x - 4)
        for i, line in enumerate(c.wrap("Use the same Wi-Fi as the Cardputer. The page closes when you leave "
                                        "this screen.", W - x - 6, font("ui", 8))[:3]):
            c.text((x, TOP + 105 + i * 10), line, font("ui", 8), FAINT)

    def closed(self, app):
        if self.server is not None:
            self.server.stop()
            self.server = None


class Settings(Screen, ListMixin):
    title = "SETTINGS"
    VISIBLE = 7
    WHILE_SCANNING = {key for section, entries in config.SECTIONS
                      if section in ("SCANNING", "DEEP SCAN", "LOGGING", "GPS")
                      for key, _, _, _ in entries} - {"ignore"}
    HELPER_EVERY = 5.0
    PI_HELP = {"gps_source": "Auto finds a USB receiver or uses gpsd.",
               "country": "Nodes use the Wi-Fi channels allowed in this country.",
               "check_updates": "Checks GitHub for a newer DIY package.",
               "auto_upload": "Automatic sends finished logs whenever the Pi is online.",
               "alert_place": "Where alerts appear. K3 opens the alert controls."}

    def __init__(self, diy=False):
        self.index, self.top = 1, 0
        self._helper = None
        self.items = []
        for section, entries in config.SECTIONS:
            self.items.append((None, section, None, ""))
            if not diy:
                self.items.extend(entries)
                continue
            for key, label, choices, help_line in entries:
                if key in ("lora", "gps_power"):
                    continue
                if key == "gps_source":
                    choices = [(value, name) for value, name in choices if value != "/dev/ttyS0"]
                self.items.append((key, label, choices, self.PI_HELP.get(key, help_line)))

    def hints(self, app):
        return [("OK", "Change"), ("Z/C", "Step"), ("F/X", "Move"), ("Esc", "Back")]

    @staticmethod
    def value(app, key):
        if key == "ignore":
            return plural(len(app.cfg.get("ignore", ())), "name")
        if key == "recon_categories":
            return "%d of %d" % (len(app.cfg.get(key, ())), len(recon.CATEGORIES))
        if key == "drive_alert_types":
            from ..drive_watch import TYPES
            names = supported_alerts(app, TYPES)
            return "%d of %d" % (sum(name in app.cfg.get(key, ()) for name in names), len(names))
        if key == "gps_source" and app.square and app.cfg.get(key) == "/dev/ttyS0":
            return "/dev/ttyS0"
        if key == "drive_alert_skip":
            return plural(len(app.cfg.get(key, ())), "device")
        if key == "drive_watch":
            count = len(app.cfg.get(key, ()))
            return "%d %s" % (count, "entry" if count == 1 else "entries")
        if key == "nodes":
            found = len(app.nodes.found())
            return plural(len(app.cfg.get("nodes", ())), "node") + (", %d new" % found if found else "")
        if key == "flash_node":
            return ""
        if key == "check_updates":
            return "v" + __version__
        return config.shown(key, app.cfg.get(key))

    def helper_words(self, app, key):
        """What the radio helper's state means for a Deep scan setting, when it is not ready; "" otherwise."""
        if key not in config.HELPER_SETTINGS or not app.cfg.get(key):
            return ""
        now = time.monotonic()
        if self._helper is None or now - self._helper[0] >= self.HELPER_EVERY:
            from .. import radio_helper
            self._helper = (now,) + radio_helper.state(app.cfg)
        state, words = self._helper[1], self._helper[2]
        return "" if state in ("ready", "off") else words

    def skip_headers(self, direction):
        for _ in range(len(self.items)):
            if self.items[self.index][0] is not None:
                return
            self.index = (self.index + direction) % len(self.items)

    def locked(self, app, key):
        return app.wardriving and key in self.WHILE_SCANNING

    def render(self, c, app):
        self.skip_headers(1)
        self.clamp(len(self.items), self.VISIBLE)
        for row, (key, label, choices, _) in enumerate(self.items[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 15
            if key is None:
                c.text((11, y + 3), label, font("bold", 7), GOLD)
                c.line((16 + c.text_width(label, font("bold", 7)), y + 7, W - 12, y + 7), fill=LINE)
                continue
            selected = self.top + row == self.index
            if selected:
                c.select(y - 1, 14)
            c.text((11, y), label, font("ui", 10), FAINT if self.locked(app, key) else TEXT)
            c.text_right(W - 22, y + 1, self.value(app, key), font("mono", 9), GOLD if selected else MUTED)
            c.text((W - 18, y - 1), "›", font("bold", 11), FAINT)
        self.scrollbar(c, len(self.items), self.VISIBLE, y1=TOP + self.VISIBLE * 15 - 2)
        key, _, _, help_text = self.items[self.index]
        helper = self.helper_words(app, key)
        if self.locked(app, key):
            help_text, color = "Stop the wardrive to change this setting.", AMBER
        elif helper:
            help_text, color = "Helper: " + helper, AMBER
        else:
            color = MUTED
        for i, line in enumerate(c.wrap(help_text, W - 20, font("ui", 9))[:2]):
            c.text((10, TOP + self.VISIBLE * 15 + 3 + i * 11), line, font("ui", 9), color)

    def handle(self, key, app):
        if self.move(key, len(self.items), self.VISIBLE):
            self.skip_headers(-1 if key.name == "UP" else 1)
            self.clamp(len(self.items), self.VISIBLE)
            return True
        name, label, choices, _ = self.items[self.index]
        if key.name not in ("ENTER", "LEFT", "RIGHT", "SPACE"):
            return super().handle(key, app)
        if key.repeat:
            return True
        if name == "ignore":
            app.push(IgnoreList())
        elif name == "recon_categories":
            from .recon_screens import Categories
            app.push(Categories())
        elif name == "drive_alert_types":
            from .recon_screens import AlertTypes
            app.push(AlertTypes())
        elif name == "drive_watch":
            from .recon_screens import MyAlerts
            app.push(MyAlerts())
        elif name == "drive_alert_skip":
            from .recon_screens import SkipList
            app.push(SkipList())
        elif name == "nodes":
            app.push(Nodes())
            if not app.cfg.get("country_set") and not self.locked(app, "country"):
                app.push(Picker("Where are you?", [(value, text, "") for value, text in config.COUNTRIES],
                                app.cfg.get("country"), lambda value: app.change("country", value)))
        elif name == "flash_node":
            app.push(FlashTargets())
        elif name == "check_updates":
            app.push(Updates())
            app.check_updates()
        elif name == "deep_scan_adapter" and not self.locked(app, name):
            choices = [("auto", "Auto", "Picks a spare adapter")]
            for adapter in hardware.wifi_adapters():
                if adapter.get("external"):
                    choices.append((adapter["interface"], adapter["interface"], adapter.get("label", "")))
            app.push(Picker(label, choices, app.cfg.get(name), lambda value: app.change(name, value)))
        elif self.locked(app, name):
            app.toast("Stop the wardrive to change this", AMBER)
        elif key == "ENTER" and len(choices) > 2:
            app.push(Picker(label, [(value, text, "") for value, text in choices], app.cfg.get(name),
                            lambda value: app.change(name, value)))
        else:
            values = [value for value, _ in choices]
            index = values.index(app.cfg[name]) if app.cfg.get(name) in values else 0
            app.change(name, values[(index + (-1 if key == "LEFT" else 1)) % len(values)])
        return True


class IgnoreList(Screen, ListMixin):
    title = "IGNORED NETWORKS"
    VISIBLE = 7

    def __init__(self):
        self.index = self.top = 0

    def hints(self, app):
        return [("A", "Add"), ("D", "Remove"), ("Esc", "Back")]

    def render(self, c, app):
        entries = app.cfg.get("ignore", [])
        if not entries:
            empty_state(c, "wifi", "Nothing is ignored",
                        "Press A to add a Wi-Fi name or MAC address, such as your home network or phone hotspot. "
                        "It still shows on screen but is never logged or uploaded.")
            return
        self.clamp(len(entries), self.VISIBLE)
        for row, entry in enumerate(entries[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 16
            if self.top + row == self.index:
                c.select(y, 15)
            c.text((11, y + 2), entry, font("ui", 10), TEXT, width=W - 110)
            c.text_right(W - 14, y + 3, "address" if config.is_mac(entry) else "name", font("mono", 9), MUTED)
        self.scrollbar(c, len(entries), self.VISIBLE)
        c.text((10, CONTENT_BOTTOM - 13), "Never logged or uploaded. Paste a long list from the phone setup page.",
               font("ui", 8), FAINT, width=W - 20)

    def handle(self, key, app):
        entries = list(app.cfg.get("ignore", []))
        self.clamp(len(entries), self.VISIBLE)
        if self.move(key, len(entries), self.VISIBLE):
            return True
        if key == "A":
            if len(entries) >= config.MAX_IGNORED:
                app.toast("The list is full (%d entries)" % config.MAX_IGNORED, AMBER)
            else:
                app.push(TextInput("Wi-Fi name or MAC address", lambda value: app.ignore(value),
                                   hint="Exactly as it is shown, capitals included.", limit=64))
        elif key == "D" and entries:
            entry = entries[self.index]
            app.confirm("Stop ignoring it?", "%s will be logged again." % entry, "Remove",
                        lambda: app.change("ignore", [item for item in entries if item != entry]))
        else:
            return super().handle(key, app)
        return True


class Nodes(Screen, ListMixin):
    title = "NODES"
    VISIBLE = 6

    def __init__(self):
        self.index = self.top = 0

    @staticmethod
    def rows(app):
        rows = [("new", node) for node in app.nodes.found()] + [("known", node) for node in app.nodes.known()]
        hub = app.nodes.hub()
        if hub is not None and hub["ready"]:
            rows.append(("pair", None))
        return rows

    def hints(self, app):
        rows = self.rows(app)
        if not rows:
            return [("Esc", "Back")]
        self.clamp(len(rows), self.VISIBLE)
        word = {"new": "Add", "pair": "Pair"}.get(rows[self.index][0], "Open")
        return [("OK", word), ("F/X", "Move"), ("Esc", "Back")]

    def render(self, c, app):
        rows = self.rows(app)
        if not rows:
            empty_state(c, "chip", "No nodes yet",
                        app.nodes.error or "Plug in an ESP32-C5 board that runs the node firmware. To put the "
                        "firmware on a board, use Settings > Flash a node.")
            return
        self.clamp(len(rows), self.VISIBLE)
        for row, (kind, node) in enumerate(rows[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 17
            if self.top + row == self.index:
                c.select(y, 15)
            if kind == "new":
                c.text((11, y + 2), "New node found", font("bold", 10), GOLD, width=130)
                c.text((150, y + 3), default_name(node), font("mono", 8), MUTED, width=95)
                c.text_right(W - 14, y + 2, "OK to add", font("ui", 9), GOLD)
                continue
            if kind == "pair":
                c.text((11, y + 2), "Add a wireless node", font("ui", 10), GOLD, width=200)
                c.text((W - 18, y), "›", font("bold", 11), FAINT)
                continue
            word, color = node_word(node)
            kind_text = "wireless" if node["wireless"] and not node["port"] else "hub" if node["hub"] else \
                board_name(node) if node["board"] else ""
            c.text((11, y + 2), node["name"], font("ui", 10), TEXT, width=130)
            c.text((150, y + 3), kind_text, font("mono", 8), MUTED, width=95)
            c.text_right(W - 14, y + 2, word, font("ui", 9), color)
        self.scrollbar(c, len(rows), self.VISIBLE, y1=TOP + self.VISIBLE * 17 - 2)
        note, color = (app.nodes.error, AMBER) if app.nodes.error else hub_note(app) or \
            ("Up to %d nodes. Each one scans its share of the channels." % config.MAX_NODES, FAINT)
        c.text((10, CONTENT_BOTTOM - 13), note, font("ui", 8), color, width=W - 20)

    def handle(self, key, app):
        rows = self.rows(app)
        self.clamp(len(rows), self.VISIBLE)
        if self.move(key, len(rows), self.VISIBLE):
            return True
        if key == "ENTER" and rows:
            kind, node = rows[self.index]
            if kind == "known":
                app.push(NodeDetail(node["id"]))
                return True
            if kind == "pair":
                if app.nodes.pair():
                    app.push(Pairing())
                else:
                    app.toast("The hub is not ready yet", AMBER)
                return True
            name = default_name(node)
            try:
                app.nodes.add(node["id"], name)
            except ValueError as exc:
                app.toast(str(exc), AMBER)
                return True
            app.toast("%s added" % name, GREEN)
            self.index = next((i for i, (kind, item) in enumerate(self.rows(app))
                               if kind == "known" and item["id"] == node["id"]), self.index)
            return True
        return super().handle(key, app)


class NodeDetail(Screen, ListMixin):
    title = "NODE"
    VISIBLE = 5
    HELP = {"name": "The name shown in lists and on the Hardware screen.",
            "ble": "Bluetooth halves the node's time for Wi-Fi.",
            "light": "Which light the board has. Identify needs it.",
            "identify": "Blinks its light for 5 seconds, to tell it from the others.",
            "hub": "Stays plugged in and talks to the wireless nodes. It does not scan.",
            "update": "Writes the firmware that came with Quartermaster. Settings stay.",
            "remove": "Quartermaster stops using it. Press OK on it in Nodes to add it back.",
            "forget": "The hub forgets it. Hold BOOT on it for 2 seconds to add it again."}
    STRANDED = "Hold BOOT on it for 2 seconds, then add it from Nodes."

    def __init__(self, node_id):
        self.node_id = node_id
        self.index = self.top = 0

    def node(self, app):
        node = app.nodes.node(self.node_id)
        return node if node["configured"] else None

    @staticmethod
    def actions(node):
        air = node["wireless"] and not node["port"]
        actions = [("name", "Name", node["name"])]
        if not node["hub"]:
            actions.append(("ble", "Bluetooth", "On" if node["ble"] else "Off"))
        actions.append(("light", "Light", light_name(node)))
        actions.append(("identify", "Identify", "Blink its light"))
        if not node["wireless"] and (node["hub"] or "espnow" in node["capabilities"]):
            actions.append(("hub", "Hub for wireless nodes", "On" if node["hub"] else "Off"))
        if old_firmware(node) and not air:
            actions.append(("update", "Update firmware", "%s to %s" % (node["firmware"], bundled_firmware())))
        return actions + [("forget" if node["wireless"] else "remove", "Remove", "")]

    def hints(self, app):
        return [("OK", "Change"), ("F/X", "Move"), ("Esc", "Back")]

    def render(self, c, app):
        node = self.node(app)
        if node is None:
            return
        actions = self.actions(node)
        self.clamp(len(actions), self.VISIBLE)
        word, color = node_word(node)
        y0 = TOP - 2
        c.rect((4, y0, W - 4, y0 + 38), fill=SURFACE, radius=5)
        c.text((10, y0 + 2), node["name"], font("bold", 11), TEXT, width=200)
        c.text_right(W - 10, y0 + 3, word, font("ui", 9), color)
        air = node["wireless"] and not node["port"]
        if node["firmware"]:
            kind = "wireless" if air else "hub" if node["hub"] else \
                "chip %s  %d MB flash" % (node["chip"], node["flash_mb"] or 0)
            facts = "%s  firmware %s  %s" % (board_name(node), node["firmware"], kind)
        else:
            facts = "Not heard since Quartermaster started" if air else "Not seen since Quartermaster started"
        c.text((10, y0 + 16), facts, font("mono", 8), MUTED, width=W - 20)
        if node["error"] and (node["connected"] or air or node["error"] not in (NOT_PLUGGED, UNPLUGGED)):
            left, tint = node["error"], AMBER
        elif node["hub"] and node["hub_ready"]:
            left, tint = "Hub for %s" % plural(node["wireless_nodes"], "wireless node"), TEXT
        elif node["plan_channels"]:
            left, tint = channels_text(node), TEXT
        else:
            left, tint = "Channels are shared out when a scan starts", FAINT
        right = []
        if node["connected"] and not node["hub"]:
            right.append("{:,} network{}".format(node["networks"], "" if node["networks"] == 1 else "s"))
        if air:
            right.append(link_text(node))
        elif node["last_heard"] is not None:
            right.append("heard %s ago" % ago(node["last_heard"]))
        right = "  ".join(part for part in right if part) if tint != AMBER else ""
        c.text_right(W - 10, y0 + 27, right, font("mono", 8), MUTED)
        room = W - 26 - (int(c.text_width(right, font("mono", 8))) if right else 0)
        c.text((10, y0 + 27), left, font("mono", 8), tint, width=room)
        for row, (key, label, value) in enumerate(actions[self.top:self.top + self.VISIBLE]):
            y = y0 + 43 + row * 15
            selected = self.top + row == self.index
            if selected:
                c.select(y - 1, 14)
            c.text((11, y), label, font("ui", 10), RED if key in ("remove", "forget") else TEXT)
            c.text_right(W - 22, y + 1, value, font("mono", 9), GOLD if selected else MUTED)
            c.text((W - 18, y - 1), "›", font("bold", 11), FAINT)
        self.scrollbar(c, len(actions), self.VISIBLE, y0=y0 + 42, y1=y0 + 41 + self.VISIBLE * 15)
        stranded = node["error"] == NOT_ON_HUB and actions[self.index][0] == "forget"
        c.text((10, y0 + 45 + min(len(actions), self.VISIBLE) * 15),
               self.STRANDED if node["error"] == NOT_ON_HUB and not stranded else self.HELP[actions[self.index][0]],
               font("ui", 9), AMBER if node["error"] == NOT_ON_HUB and not stranded else MUTED, width=W - 20)

    def handle(self, key, app):
        node = self.node(app)
        if node is None:
            return super().handle(key, app)
        actions = self.actions(node)
        self.clamp(len(actions), self.VISIBLE)
        if self.move(key, len(actions), self.VISIBLE):
            return True
        if key.name not in ("ENTER", "LEFT", "RIGHT", "SPACE"):
            return super().handle(key, app)
        if key.repeat:
            return True
        action, node_id = actions[self.index][0], self.node_id
        if action == "ble":
            app.nodes.set_ble(node_id, not node["ble"])
        elif action == "hub":
            stranded = 0 if node["hub"] else app.nodes.stranded(node_id)
            waiting = app.nodes.wireless() if node["hub"] else 0
            if stranded:
                app.confirm("Move the hub here?", "Your %s must be added again. Hold BOOT on each one for 2 seconds."
                            % plural(stranded, "wireless node"), "Move", lambda: self.make_hub(app, node_id))
            elif waiting:
                app.confirm("Stop the hub?", self.stops(waiting), "Stop", lambda: self.make_hub(app, node_id, False))
            else:
                self.make_hub(app, node_id, not node["hub"])
        elif key != "ENTER":
            return True
        elif action == "name":
            app.push(TextInput("Node name", lambda value: app.nodes.rename(node_id, value), initial=node["name"],
                               hint="Up to %d letters." % config.NODE_NAME_MAX, limit=config.NODE_NAME_MAX))
        elif action == "light":
            current = node["led"] or ("gpio,28" if node["board"] == "stamp-c5" else None)
            app.push(Picker("Its light", [(value, label, "") for value, label, _ in LIGHTS], current,
                            lambda value: self.set_light(app, node_id, value)))
        elif action == "identify":
            if not node["led"] or node["led"] == "none":
                app.toast("Set its light first", AMBER)
            elif app.nodes.identify(node_id):
                app.toast("Its light blinks for 5 seconds")
            elif node["wireless"] and not node["port"]:
                app.toast("It is not heard right now", AMBER)
            else:
                app.toast("It is not plugged in", AMBER)
        elif action == "update":
            target = next((t for t in flash_targets(app) if t["node"] == node_id), None)
            if target is None:
                app.toast("Plug it in first", AMBER)
            else:
                app.ask_flash(target)
        elif action == "remove":
            waiting = app.nodes.wireless() if node["hub"] else 0
            app.confirm("Remove this node?", "%s is no longer used. Press OK on it in Nodes to add it back.%s"
                        % (node["name"], " " + self.stops(waiting) if waiting else ""),
                        "Remove", lambda: app.remove_node(node_id), danger=True)
        elif action == "forget":
            app.confirm("Remove this node?", "The hub forgets %s. Hold BOOT on it for 2 seconds to add it again."
                        % node["name"], "Remove", lambda: app.remove_node(node_id), danger=True)
        return True

    @staticmethod
    def stops(count):
        return "Your %s stop%s until this node is the hub again." % (plural(count, "wireless node"),
                                                                     "s" if count == 1 else "")

    @staticmethod
    def set_light(app, node_id, value):
        def chosen():
            try:
                app.nodes.set_led(node_id, value)
            except ValueError as exc:
                app.toast(str(exc), AMBER)
        if value == "gpio,28":
            app.confirm("Use G28 as its light?", "Only on a Stamp-C5. Its BOOT button then stops working, so holding "
                        "it cannot add the node to a hub again.", "Use G28", chosen)
        else:
            chosen()

    @staticmethod
    def make_hub(app, node_id, on=True):
        try:
            app.nodes.set_hub(node_id, on)
        except ValueError as exc:
            app.toast(str(exc), AMBER)
            return
        app.toast("It is the hub now. It does not scan." if on else "It scans again")


class Pairing(Screen, ListMixin):
    """Settings > Nodes > Add a wireless node. The hub's pairing window stays open while this screen does."""

    title = "ADD A WIRELESS NODE"
    VISIBLE = 4

    def __init__(self):
        self.index = self.top = 0
        self.pending, self.added = set(), []

    def follow(self, app):
        """A node being added shows as added once it is in the settings."""
        names = app.nodes.names()
        for node_id in sorted(self.pending & set(names)):
            self.pending.discard(node_id)
            self.added.append(node_id)
        return names

    def rows(self, app, names=None):
        names = app.nodes.names() if names is None else names
        return [("join", join) for join in app.nodes.joining() if join["id"] not in self.added] + \
            [("added", {"id": node_id, "name": names[node_id]}) for node_id in self.added if node_id in names]

    def hints(self, app):
        rows = self.rows(app)
        if rows and rows[min(self.index, len(rows) - 1)][0] == "join":
            return [("OK", "Add"), ("F/X", "Move"), ("Esc", "Done")]
        hub = app.nodes.hub()
        if hub is not None and hub["ready"] and not hub["pairing"]:
            return [("OK", "Pair again"), ("Esc", "Done")]
        return [("Esc", "Done")]

    def render(self, c, app):
        names = self.follow(app)
        hub = app.nodes.hub()
        left = hub["pairing"] if hub is not None and hub["ready"] else 0
        y0 = TOP - 2
        c.rect((4, y0, W - 4, y0 + 40), fill=SURFACE, radius=5)
        if hub is None or not hub["connected"]:
            first, second, color = "The hub is unplugged.", "Plug it in to add wireless nodes.", AMBER
        elif not hub["ready"]:
            first, second, color = "Waiting for the hub to answer.", hub["error"] or "This takes a few seconds.", AMBER
        elif left:
            first, second, color = "Hold BOOT on the new node for 2 seconds.", \
                "If its light is set, it blinks fast while it looks.", TEXT
            c.text_right(W - 12, y0 + 5, "%d:%02d" % divmod(left, 60), font("display", 24), GOLD)
        else:
            first, second, color = "Pairing is closed.", "Press OK to open it again.", MUTED
        c.text((10, y0 + 6), first, font("bold", 10), color, width=W - 90)
        c.text((10, y0 + 22), second, font("ui", 9), MUTED, width=W - 90)
        rows = self.rows(app, names)
        self.clamp(len(rows), self.VISIBLE)
        if not rows and left:
            c.text_center(W // 2, y0 + 62, "No new node has asked yet", font("ui", 10), FAINT)
        for row, (kind, item) in enumerate(rows[self.top:self.top + self.VISIBLE]):
            y = y0 + 46 + row * 17
            if self.top + row == self.index:
                c.select(y, 15)
            if kind == "join":
                c.text((11, y + 2), "New wireless node", font("bold", 10), GOLD, width=130)
                c.text((150, y + 3), default_name(item), font("mono", 8), MUTED, width=95)
                c.text_right(W - 14, y + 2, "Adding…" if item["adding"] else "OK to add", font("ui", 9), GOLD)
            else:
                c.text((11, y + 2), item["name"], font("ui", 10), TEXT, width=200)
                c.text_right(W - 14, y + 2, "Added", font("ui", 9), GREEN)
        self.scrollbar(c, len(rows), self.VISIBLE, y0=y0 + 46, y1=y0 + 44 + self.VISIBLE * 17)
        note = hub["note"] if hub is not None else ""
        c.text((10, CONTENT_BOTTOM - 13), note or "The hub takes up to %d wireless nodes." % config.MAX_WIRELESS,
               font("ui", 8), AMBER if note else FAINT, width=W - 20)

    def handle(self, key, app):
        self.follow(app)
        rows = self.rows(app)
        self.clamp(len(rows), self.VISIBLE)
        if self.move(key, len(rows), self.VISIBLE):
            return True
        if key != "ENTER":
            return super().handle(key, app)
        if key.repeat:
            return True
        hub = app.nodes.hub()
        if rows and rows[self.index][0] == "join":
            join = rows[self.index][1]
            if join["adding"]:
                return True
            name = default_name(join)
            try:
                sent = app.nodes.admit(join["id"], name)
            except ValueError as exc:
                app.toast(str(exc), AMBER)
                return True
            if sent:
                self.pending.add(join["id"])
            else:
                app.toast("The hub is not ready yet", AMBER)
        elif hub is not None and hub["ready"] and not hub["pairing"]:
            app.nodes.pair(PAIR_SECONDS)
        return True

    def closed(self, app):
        app.nodes.pair(0)


def flash_targets(app):
    """What can be flashed: the nodes plugged in, then the ports of ESP32-C5 boards that run no node firmware."""
    ports = {port["real"]: port for port in app.hw.serial_ports}
    targets = []
    for node in app.nodes.known() + app.nodes.found():
        if not node["connected"] or not node["port"]:
            continue
        port = ports.pop(os.path.realpath(node["port"]), None)
        targets.append({"node": node["id"], "path": node["port"], "native": port["native"] if port else True,
                        "title": node["name"] if node["configured"] else default_name(node),
                        "detail": "%s to %s" % (node["firmware"], bundled_firmware()) if old_firmware(node)
                        else "Up to date", "mode": "update", "configured": node["configured"]})
    gps = app.cfg.get("gps_source", "auto")
    gps = os.path.realpath(gps) if gps.startswith("/") else None
    for port in ports.values():
        if hardware.port_mark(port["real"]) in ("gps", "node") or port["real"] == gps:
            continue
        targets.append({"node": None, "path": port["path"], "native": port["native"],
                        "title": "%s on %s" % ("ESP32-C5" if port["native"] else "USB serial", port["name"]),
                        "detail": "No node firmware", "mode": "first", "configured": False})
    return targets


def boot_help(c, y, color=MUTED):
    for i, line in enumerate(BOOT_HELP):
        c.text((10, y + i * 12), line, font("ui", 9), color, width=W - 20)


class FlashTargets(Screen, ListMixin):
    title = "FLASH A NODE"
    VISIBLE = 5

    def __init__(self):
        self.index = self.top = 0

    def hints(self, app):
        if app.flash_blocked() or not flash_targets(app):
            return [("Esc", "Back")]
        return [("OK", "Flash"), ("F/X", "Move"), ("Esc", "Back")]

    def render(self, c, app):
        blocked = app.flash_blocked()
        if blocked:
            empty_state(c, "chip", blocked, "Flashing restarts the board and takes over its port, so it cannot "
                                            "happen while Quartermaster scans.")
            return
        targets = flash_targets(app)
        if not targets:
            icons.draw(c, "chip", W // 2 - 12, TOP + 2, 24, LINE)
            c.text_center(W // 2, TOP + 30, "No board found", font("bold", 12), TEXT)
            c.text_center(W // 2, TOP + 47, "Plug in an ESP32-C5 board. If it does not show up:", font("ui", 9), MUTED)
            boot_help(c, TOP + 65, FAINT)
            return
        self.clamp(len(targets), self.VISIBLE)
        for row, target in enumerate(targets[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 17
            if self.top + row == self.index:
                c.select(y, 15)
            c.text((11, y + 2), target["title"], font("ui", 10), TEXT, width=170)
            c.text_right(W - 14, y + 3, target["detail"], font("mono", 9),
                         AMBER if target["detail"] not in ("Up to date", "No node firmware") else MUTED)
        self.scrollbar(c, len(targets), self.VISIBLE, y1=TOP + self.VISIBLE * 17 - 2)
        c.text((10, CONTENT_BOTTOM - 25), "First install erases the board. Update keeps its settings.",
               font("ui", 8), FAINT, width=W - 20)
        c.text((10, CONTENT_BOTTOM - 13), "Firmware %s came with Quartermaster." % bundled_firmware(), font("ui", 8),
               FAINT, width=W - 20)

    def handle(self, key, app):
        targets = [] if app.flash_blocked() else flash_targets(app)
        self.clamp(len(targets), self.VISIBLE)
        if self.move(key, len(targets), self.VISIBLE):
            return True
        if key == "ENTER" and targets:
            app.ask_flash(targets[self.index])
            return True
        return super().handle(key, app)


class Flashing(Screen):
    title = "FLASHING"
    refresh = 0.25
    PERMANENT = (flasher.NOT_C5, flasher.TOO_BIG, flasher.LOCKED, flasher.DAMAGED, flasher.NO_SERIAL)
    PERMANENT_STARTS = tuple(words.split("%")[0] for words in (flasher.EARLY, flasher.NEWER, flasher.SMALL))

    def __init__(self, job):
        self.job = job

    def permanent(self):
        """A failure that trying again on the same board cannot mend."""
        error = self.job.error or ""
        return error in self.PERMANENT or error.startswith(self.PERMANENT_STARTS)

    def hints(self, app):
        if self.job.state == "failed" and self.job.error == flasher.LAYOUT and self.job.mode != "first":
            return [("OK", "First install"), ("Esc", "Back")]
        if self.job.state == "failed" and self.permanent():
            return [("Esc", "Back")]
        if self.job.state == "failed":
            return [("OK", "Try again"), ("Esc", "Back")]
        if self.job.state == "done":
            return [("OK", "Done")]
        return []

    def render(self, c, app):
        job = self.job
        c.text((10, TOP), job.target["title"], font("bold", 12), GOLD, width=W - 20)
        what = "Update to firmware %s" if job.mode == "update" else "First install of firmware %s"
        c.text((10, TOP + 17), what % bundled_firmware(), font("ui", 9), MUTED, width=W - 20)
        bar = (10, TOP + 36, W - 52, TOP + 46)
        if job.state == "failed":
            c.text((10, TOP + 34), "It did not work", font("bold", 11), RED)
            lines = c.wrap(job.error, W - 20, font("ui", 9))[:3]
            for i, line in enumerate(lines):
                c.text((10, TOP + 50 + i * 12), line, font("ui", 9), TEXT)
            if job.needs_boot:
                boot_help(c, TOP + 54 + len(lines) * 12)
            return
        done = job.state == "done"
        c.progress(bar, 1.0 if done else job.fraction, GREEN if done else GOLD)
        c.text_right(W - 10, TOP + 35, "%d %%" % round(100 * (1.0 if done else job.fraction)), font("bold", 10),
                     GREEN if done else GOLD)
        if done:
            lines = [("Done. It starts again as a node by itself.", GREEN)]
            if not job.target["configured"]:
                lines.append(("Then add it under Settings > Nodes.", MUTED))
        elif job.state == "writing":
            lines = [("Writing the firmware. This takes about a minute.", MUTED),
                     ("Do not unplug the board.", AMBER)]
        elif job.waiting:
            lines = [("Waiting for the port…", MUTED), ("It is busy for a moment.", FAINT)]
        else:
            lines = [("Getting the board ready…", MUTED), ("Do not unplug the board.", AMBER)]
        for i, (line, color) in enumerate(lines):
            c.text((10, TOP + 56 + i * 13), line, font("ui", 9), color, width=W - 20)

    def handle(self, key, app):
        state, job = self.job.state, self.job
        if state == "failed" and key == "ENTER" and job.error == flasher.LAYOUT and job.mode != "first":
            app.confirm("Install from scratch?", "This erases the board and its settings.", "Install",
                        lambda: app.retry_flash(job, "first"), danger=True)
        elif state == "failed" and key == "ENTER" and not self.permanent():
            app.retry_flash(self.job)
        elif state in ("done", "failed") and key in ("ENTER", "ESC", "BACKSPACE"):
            app.pop()
        elif state not in ("done", "failed") and key in ("ESC", "BACKSPACE"):
            app.toast("Wait until it is done. Do not unplug the board.", AMBER)
        else:
            return False
        return True


class Updates(Screen):
    title = "UPDATES"
    refresh = 0.5
    COLORS = {updates_check.LATEST: GREEN, updates_check.STORE: GOLD, updates_check.GITHUB: GOLD}

    def hints(self, app):
        return [("OK", "Check again"), ("Esc", "Back")]

    def render(self, c, app):
        state, text = app.update_state()
        c.text((10, TOP + 2), "Quartermaster %s" % __version__, font("bold", 12), GOLD)
        if state in ("busy", ""):
            text, color = "Checking…", MUTED
        else:
            color = self.COLORS.get(state, AMBER)
        for i, line in enumerate(c.wrap(text, W - 20, font("ui", 10))[:3]):
            c.text((10, TOP + 24 + i * 14), line, font("ui", 10), color)
        install = "Use the DIY package to update your Pi." if app.square else "Use the AppStore on the Cardputer."
        note = c.wrap("Apps never update by themselves. %s Quartermaster only asks, and never downloads anything."
                      % install, W - 20, font("ui", 8))[:3]
        for i, line in enumerate(note):
            c.text((10, CONTENT_BOTTOM - 2 - (len(note) - i) * 11), line, font("ui", 8), FAINT)

    def handle(self, key, app):
        if key == "ENTER":
            app.check_updates()
            return True
        return super().handle(key, app)


class About(Screen):
    title = "ABOUT"

    def hints(self, app):
        return [("T", "Tips"), ("Esc", "Back")]

    def render(self, c, app):
        c.paste(image("quartermaster-logo-dark.png", (120, 84)), (8, TOP + 3))
        c.text((126, TOP + 2), "Quartermaster", font("display", 17), GOLD)
        c.text((126, TOP + 23), "Version %s" % __version__, font("ui", 10), TEXT)
        c.text((126, TOP + 36), "Wardriver for every radio", font("ui", 9), MUTED)
        c.text((126, TOP + 47), "for the Raspberry Pi" if app.square else "for the CardputerZero", font("ui", 9), MUTED)
        c.text((126, TOP + 60), REPO, font("ui", 7), FAINT)
        for i, line in enumerate(c.wrap(THANKS, W - 134, font("ui", 7))[:3]):
            c.text((126, TOP + 69 + i * 8), line, font("ui", 7), MUTED)
        y = CONTENT_BOTTOM - 37
        c.rect((8, y, W - 8, y + 34), fill=WHITE, radius=6)
        c.paste(image("bwm-logo.png", (28, 28)), (16, y + 3))
        c.paste(image("vts-logo.png", (28, 28)), (W - 42, y + 3))
        c.text_center(W // 2, y + 5, "Valleytech Solutions", font("bold", 11), (0, 0, 0))
        c.text_center(W // 2, y + 19, "GPL-3.0 open source", font("ui", 9), (90, 90, 90))

    def handle(self, key, app):
        if key == "T":
            app.push(Tips())
            return True
        return super().handle(key, app)


class Tips(Details):
    def __init__(self):
        super().__init__("TIPS")

    def rows(self, app):
        controls = [
            ("F  X  Z  C", "Up, down, left, right. The arrow keys work too."),
            ("OK", "Open or confirm"),
            ("Esc", "Back"),
            ("Sym", "Then a key: the symbol printed on it"),
            ("Tab", "In a text box: lists every symbol"),
            ("Space", "Start or stop a wardrive from the menu"),
        ]
        battery_help = ("At 5 % battery a running wardrive is saved in full and keeps recording. "
                        "When the battery is almost empty, a running wardrive is saved and Quartermaster closes, "
                        "so that the Cardputer can switch off safely.")
        if app.square:
            battery_help = ("When a system battery gauge reports 5 %, a running wardrive is saved in full and "
                            "keeps recording. Almost empty, a running wardrive is saved and Quartermaster closes.")
            controls = [("Joystick", "Move through menus. Press the stick or K1 to select."),
                        ("K2", "Go back."),
                        ("K3", "Open actions. Choose Pan details to read a wider screen."),
                        ("Text", "K3 opens the keyboard. Move to a character and press K1. K3 closes it."),
                        ("USB", "An external keyboard works too.")]
        return [("", "Keys", GOLD), *controls,
            ("", "Wardrive", GOLD),
            ("", "Every Wi-Fi adapter scans at once, with Bluetooth beside them. Rows are logged only with a GPS "
                 "fix, so WiGLE accepts every one.", MUTED),
            ("", "Each device is listed once. Its strongest and weakest sightings are always written, which is "
                 "the closest and the farthest point you heard it from.", MUTED),
            ("", battery_help, MUTED),
            ("", "Uploads", GOLD),
            ("", "Add your keys once under Keys. Finished logs are then sent to WiGLE, WDGWars and Wardrift "
                 "whenever the device is online.", MUTED),
            ("", "Recon", GOLD),
            ("", "Watches for cameras, trackers and other surveillance gear. It never runs together with a "
                 "wardrive.", MUTED),
            ("", "A match is broadcast evidence, not proof of recording, intent or ownership.", FAINT),
        ]


class Picker(Modal, ListMixin):
    VISIBLE = 6

    def __init__(self, title, options, current=None, on_select=None):
        self.title = title
        self.options = options
        self.on_select = on_select
        self.index = next((i for i, option in enumerate(options) if option[0] == current), 0)
        self.top = 0
        self.clamp(len(options), self.VISIBLE)

    def hints(self, app):
        return [("OK", "Select"), ("Esc", "Cancel")]

    def render(self, c, app):
        x0, y0, x1 = 34, 20, W - 34
        y1 = y0 + 28 + min(self.VISIBLE, len(self.options)) * 17
        c.rect((x0, y0, x1, y1), fill=SURFACE, outline=GOLD_DIM, radius=7)
        c.text((x0 + 10, y0 + 6), self.title, font("bold", 11), GOLD, width=x1 - x0 - 20)
        for row, (_, label, detail) in enumerate(self.options[self.top:self.top + self.VISIBLE]):
            y = y0 + 24 + row * 17
            selected = self.top + row == self.index
            if selected:
                c.rect((x0 + 4, y, x1 - 4, y + 15), fill=GOLD, radius=4)
            c.text((x0 + 10, y + 2), label, font("ui", 10), GOLD_INK if selected else TEXT, width=x1 - x0 - 24)
            if detail:
                c.text_right(x1 - 10, y + 3, detail, font("mono", 8), GOLD_INK if selected else MUTED)
        self.scrollbar(c, len(self.options), self.VISIBLE, x=x1 - 3, y0=y0 + 25, y1=y1 - 4)

    def handle(self, key, app):
        if self.move(key, len(self.options), self.VISIBLE):
            return True
        if key == "ENTER":
            app.pop()
            if self.on_select:
                self.on_select(self.options[self.index][0])
            return True
        return super().handle(key, app)


class Confirm(Modal):
    """A question with Cancel and one action. `extra` adds a third choice, (label, callback, what it does), drawn
    as the risky one: the stop dialog's "Stop, don't save". While it is the one chosen, the dialog says what it
    does instead of what the action does: a small screen shows one choice at a time."""

    def __init__(self, title, detail, action, callback, danger=False, default=0, extra=None):
        self.title, self.detail, self.action, self.callback = title, detail, action, callback
        self.danger = danger
        self.choice = default
        self.extra = extra

    @property
    def labels(self):
        return ("Cancel", self.action) + ((self.extra[0],) if self.extra else ())

    @property
    def words(self):
        return self.extra[2] if self.extra and self.choice == 2 else self.detail

    def hints(self, app):
        return [("Z/C", "Choose"), ("OK", "Confirm"), ("Esc", "Cancel")]

    def render(self, c, app):
        labels = self.labels
        x0, y0, x1, y1 = (36, 32, W - 36, 136) if len(labels) == 2 else (8, 32, W - 8, 136)
        c.rect((x0, y0, x1, y1), fill=SURFACE, outline=LINE, radius=8)
        c.text((x0 + 12, y0 + 9), self.title, font("bold", 12), TEXT, width=x1 - x0 - 24)
        for i, line in enumerate(c.wrap(self.words, x1 - x0 - 24, font("ui", 9))[:4]):
            c.text((x0 + 12, y0 + 28 + i * 12), line, font("ui", 9), MUTED)
        width = (x1 - x0 - 24 - 6 * (len(labels) - 1)) // len(labels)
        for i, label in enumerate(labels):
            x = x0 + 12 + i * (width + 6)
            selected = i == self.choice
            risky = i == 2 or self.danger and i == 1
            fill = (RED if risky else GOLD) if selected else SURFACE_2
            c.rect((x, y1 - 25, x + width, y1 - 8), fill=fill, radius=5)
            c.text_center(x + width // 2, y1 - 22, label, font("bold", 10),
                          (WHITE if risky else GOLD_INK) if selected else TEXT)

    def handle(self, key, app):
        if key.name in ("LEFT", "RIGHT", "TAB", "UP", "DOWN"):
            if not key.repeat:
                step = -1 if key.name in ("LEFT", "UP") else 1
                self.choice = (self.choice + step) % len(self.labels)
        elif key == "ENTER":
            app.pop()
            if self.choice == 1:
                self.callback()
            elif self.choice == 2:
                self.extra[1]()
        elif key == "Y":
            app.pop()
            self.callback()
        elif key in ("N", "ESC", "BACKSPACE"):
            app.pop()
        else:
            return False
        return True


class TextInput(Modal):
    refresh = 0.5
    SYMBOLS = "-_.@:/!#$%&*+=?~()[]{}<>'\"`^|\\,;"
    COLUMNS = 16

    def __init__(self, title, on_submit, initial="", hint="", limit=64, secret=False):
        self.title, self.on_submit, self.hint, self.limit = title, on_submit, hint, limit
        self.secret = secret
        self.value = initial
        self.picking = False
        self.cell = 0

    @property
    def text_mode(self):
        return not self.picking

    def hints(self, app):
        if self.picking:
            return [("F/X/Z/C", "Move"), ("OK", "Add"), ("Tab", "Close")]
        return [("OK", "Save"), ("Tab", "Symbols"), ("Del", "Erase"), ("Esc", "Cancel")]

    def render(self, c, app):
        x0, y0, x1, y1 = 14, 38, W - 14, 122
        c.rect((x0, y0, x1, y1), fill=SURFACE, outline=GOLD_DIM, radius=8)
        c.text((x0 + 12, y0 + 8), self.title, font("bold", 11), GOLD, width=x1 - x0 - 24)
        c.rect((x0 + 10, y0 + 28, x1 - 10, y0 + 48), fill=BG, outline=LINE, radius=4)
        shown = self.display_value()[-41:]
        width = c.text((x0 + 16, y0 + 32), shown, font("mono", 10), TEXT)
        if int(time.monotonic() * 2) % 2 == 0:
            c.rect((x0 + 17 + width, y0 + 32, x0 + 18 + width, y0 + 44), fill=GOLD)
        if self.picking:
            for i, symbol in enumerate(self.SYMBOLS):
                x, y = x0 + 18 + i % self.COLUMNS * 16, y0 + 52 + i // self.COLUMNS * 15
                if i == self.cell:
                    c.rect((x, y, x + 15, y + 13), fill=GOLD, radius=3)
                c.put((x + 8, y + 7), symbol, font("monob", 12), GOLD_INK if i == self.cell else TEXT, "mm")
            return
        c.text_right(x1 - 12, y0 + 53, "%d typed" % len(self.value), font("mono", 8), FAINT)
        for i, line in enumerate(c.wrap(self.hint, x1 - x0 - 90, font("ui", 8))[:3]):
            c.text((x0 + 12, y0 + 53 + i * 10), line, font("ui", 8), MUTED)

    def insert(self, text):
        if len(self.value) < self.limit:
            self.value += text

    def display_value(self):
        return "•" * len(self.value) if self.secret else self.value

    def handle(self, key, app):
        if self.picking:
            return self.pick(key)
        if key == "ENTER":
            app.pop()
            if self.value.strip():
                self.on_submit(self.value.strip())
        elif key == "ESC":
            app.pop()
        elif key == "TAB":
            self.picking = True
        elif key.name in ("BACKSPACE", "DELETE"):
            self.value = self.value[:-1]
        elif key.char and key.char.isprintable():
            self.insert(key.char)
        else:
            return False
        return True

    def pick(self, key):
        step = {"LEFT": -1, "RIGHT": 1, "UP": -self.COLUMNS, "DOWN": self.COLUMNS}.get(key.name)
        if step:
            self.cell = (self.cell + step) % len(self.SYMBOLS)
        elif key == "ENTER":
            self.insert(self.SYMBOLS[self.cell])
            self.picking = False
        elif key in ("TAB", "ESC"):
            self.picking = False
        elif key.name in ("BACKSPACE", "DELETE"):
            self.value = self.value[:-1]
        else:
            return False
        return True
