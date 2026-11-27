"""Recon screens: the live list of flagged devices, device details and a signal finder."""

import time

from .. import config, drive_watch, recon, tones
from . import icons
from .gfx import (AMBER, BG, CONTENT_BOTTOM, CYAN, FAINT, GOLD, GOLD_INK, GREEN, LINE, MUTED, RED, SURFACE, SURFACE_2,
                  TEXT, VIOLET, W, ago, bearing, clock, compass, distance_m, font, human_distance, rssi_color)
from .screens import TOP, Details, ListMixin, Screen, TextInput, empty_state, fmt_rssi, gps_text, plural, supported_alerts

PINK = (255, 120, 200)
CATEGORY_COLOR = {
    "flock": RED, "axon": RED, "glasses": AMBER, "skimmer": AMBER, "raven": AMBER, "airtag": PINK, "drone": CYAN,
    "alpr": RED, "camera": AMBER, "samsung_tag": PINK, "google_tag": PINK, "tile": PINK, "ring": AMBER,
    "deauth": AMBER, "eviltwin": AMBER, "ibeacon": MUTED, "hacker": (180, 140, 255), "lorawan": GREEN, "mine": GOLD,
    "listener": MUTED,
}
BANNER_FILL = {"flock": ((70, 12, 14), RED), "alpr": ((70, 12, 14), RED), "axon": ((70, 12, 14), RED),
               "mine": ((60, 44, 8), GOLD), "glasses": ((40, 28, 70), VIOLET)}
GRADE_COLOR = {recon.LOW: MUTED, recon.MEDIUM: AMBER, recon.STRONG: RED}
BANNER_H = 26
BANNER_TOP = CONTENT_BOTTOM - BANNER_H - 1
BLINK_SECONDS = 3.0
ADDRESS_KIND = {0: "public", 1: "random", 2: "public identity", 3: "random identity"}
OPERATOR_KIND = {0: "take-off point", 1: "live operator", 2: "fixed point"}


def category_pill(c, x, y, category, width=None):
    label = drive_watch.SHORT.get(category, "?")
    f = font("bold", 7)
    w = width or int(c.text_width(label, f)) + 8
    c.rect((x, y, x + w, y + 11), fill=CATEGORY_COLOR.get(category, MUTED), radius=3)
    c.text_center(x + w / 2, y + 2, label, f, BG)
    return w


def grade_dots(c, x, y, confidence):
    color = GRADE_COLOR.get(confidence, FAINT)
    for i in range(3):
        c.rect((x + i * 5, y, x + i * 5 + 3, y + 7), fill=color if i < confidence else LINE, radius=1)


def away(here, there):
    return "%s %s of you" % (human_distance(distance_m(here, there)), compass(bearing(here, there)))


def device_title(device):
    name = device.get("name") or ""
    if device["transport"] == "wifi":
        return name or "(hidden network)"
    return name or device.get("vendor") or device.get("label") or device["address"]


class Recon(Screen, ListMixin):
    title = "RECON"
    refresh = 0.5
    VISIBLE = 6
    SORTS = ("threat", "signal", "recent")

    def __init__(self):
        self.index = self.top = 0
        self.show_all = False
        self.sort = 0

    def hints(self, app):
        if app.recon_running:
            return [("Space", "Stop"), ("OK", "Details"), ("A", "Flagged" if self.show_all else "All"),
                    ("S", self.SORTS[self.sort].title()), ("Esc", "Menu")]
        return [("Space", "Start"), ("T", "Watch list"), ("Esc", "Menu")]

    def render(self, c, app):
        app.recon.unseen_alerts = 0
        if app.recon_running:
            self.live(c, app)
        else:
            self.ready(c, app)

    def ready(self, c, app):
        cfg, r = app.cfg, app.recon
        y = TOP
        c.rect((4, y, W - 4, CONTENT_BOTTOM - 30), fill=SURFACE, radius=6)
        icons.draw(c, "eye", W - 46, y + 8, 32, LINE)
        watching = [k for k in recon.CATEGORIES if k in cfg.get("recon_categories", recon.CATEGORIES)]
        fix = app.gps.snapshot()
        radios = len(app.hw.adapters)
        rows = [("Radios", "%s + Bluetooth" % plural(radios, "Wi-Fi adapter") if radios else "Bluetooth only", TEXT),
                ("Watching", "%d of %d kinds, %d Wardrive only" % (
                    len(watching), len(recon.CATEGORIES),
                    len(supported_alerts(app, drive_watch.SQUACHWATCH_ORDER)) - len(recon.CATEGORIES)),
                 TEXT),
                ("Show", "%s and stronger" % recon.CONFIDENCE_NAMES[r.display_min()].lower(), TEXT),
                ("Alert", "%s and stronger%s" % (recon.CONFIDENCE_NAMES[r.alert_min()].lower(),
                                                 ", with sound" if cfg.get("recon_sound", True) else ""), TEXT),
                ("GPS", gps_text(fix), GREEN if fix.get("valid") else AMBER),
                ("Log", "Flagged devices, in quartermaster/recon", MUTED)]
        for i, (label, value, color) in enumerate(rows):
            c.text((12, y + 6 + i * 13), label, font("ui", 9), MUTED)
            c.text((70, y + 6 + i * 13), value, font("mono", 9), color, width=W - 126 if i < 3 else W - 84)
        by = CONTENT_BOTTOM - 25
        c.rect((4, by, W - 4, CONTENT_BOTTOM - 3), fill=GOLD, radius=6)
        c.text_center(W // 2, by + 5, "SPACE  ·  START RECON", font("display", 11), GOLD_INK)

    def live(self, c, app):
        r = app.recon
        summary = r.summary()
        y = TOP - 1
        tiles = [("FLAGGED", summary["flagged"], AMBER if summary["flagged"] else TEXT),
                 ("STRONG", summary["strong"], RED if summary["strong"] else TEXT),
                 ("WI-FI", summary["wifi"], TEXT), ("BLUETOOTH", summary["ble"], TEXT)]
        width = (W - 8 - 9) / 4
        for i, (label, value, color) in enumerate(tiles):
            x = 4 + i * (width + 3)
            c.rect((x, y, x + width, y + 27), fill=SURFACE, radius=5)
            c.text((x + 7, y + 3), label, font("bold", 7), MUTED)
            c.text((x + 7, y + 11), str(value), font("display", 13), color)
        c.text_right(W - 10, y + 15, clock(r.elapsed()), font("mono", 8), FAINT)
        y += 31
        errors = sorted(set(r.errors.values()))
        if errors:
            c.text((8, y), errors[0], font("ui", 8), AMBER, width=W - 16)
            y += 11
        devices = r.device_list(self.show_all, self.SORTS[self.sort])
        if not devices:
            c.text_center(W // 2, y + 16, "Nothing flagged nearby" if not self.show_all else "No devices heard yet",
                          font("bold", 11), TEXT)
            c.text_center(W // 2, y + 32, "Listening on Wi-Fi and Bluetooth. Flagged devices appear here.",
                          font("ui", 8), MUTED)
            if summary["wifi"] or summary["ble"]:
                heard = summary["wifi"] + summary["ble"]
                c.text_center(W // 2, y + 45, "Press A to list all %d devices heard." % heard, font("ui", 8), FAINT)
            return
        visible = self.VISIBLE = max(1, (CONTENT_BOTTOM - y) // 16)
        self.clamp(len(devices), visible)
        now = r.clock()
        for row, device in enumerate(devices[self.top:self.top + visible]):
            yy = y + row * 16
            stale = now - device["last_seen"] > 60
            if self.top + row == self.index:
                c.select(yy, 15)
            x = 9
            if device.get("category"):
                x += category_pill(c, x, yy + 2, device["category"], width=46) + 4
            else:
                c.text((x, yy + 3), "—", font("mono", 8), FAINT)
                x += 50
            wifi = device["transport"] == "wifi"
            c.text((x, yy + 3), "W" if wifi else "B", font("monob", 8), GOLD if wifi else CYAN)
            x += 10
            title = ("FOLLOWING  " if device.get("follow") else "") + device_title(device)
            c.text((x, yy + 2), title, font("ui", 10), RED if device.get("follow") else FAINT if stale else TEXT,
                   width=W - x - 98)
            if device.get("category"):
                grade_dots(c, W - 96, yy + 4, device.get("confidence", 0))
            c.signal_bars(W - 76, yy + 3, None if stale else device.get("rssi"))
            c.text_right(W - 34, yy + 3, fmt_rssi(device.get("rssi")), font("mono", 9),
                         FAINT if stale else rssi_color(device.get("rssi")))
            c.text_right(W - 12, yy + 3, ago(now - device["last_seen"]), font("mono", 8), MUTED)
        self.scrollbar(c, len(devices), visible, y0=y)

    def handle(self, key, app):
        r = app.recon
        running = app.recon_running
        devices = r.device_list(self.show_all, self.SORTS[self.sort]) if running else []
        if key == "SPACE":
            app.toggle_recon()
        elif running and self.move(key, len(devices), self.VISIBLE):
            pass
        elif key == "ENTER" and devices:
            device = devices[min(self.index, len(devices) - 1)]
            app.push(ReconDetail(device["transport"], device["address"]))
        elif key == "A" and running:
            self.show_all = not self.show_all
            self.index = self.top = 0
        elif key == "S" and running:
            self.sort = (self.sort + 1) % len(self.SORTS)
            self.index = self.top = 0
        elif key == "T" and not running:
            app.push(Categories())
        else:
            return super().handle(key, app)
        return True


class ReconDetail(Details):
    def __init__(self, transport, address):
        super().__init__("DEVICE")
        self.key = (transport, address)

    def hints(self, app):
        return [("OK", "Find it"), ("F/X", "Scroll"), ("Esc", "Back")]

    def rows(self, app):
        device = app.recon.device(*self.key)
        if device is None:
            return [("", "This device is no longer in the live list.", MUTED)]
        now = app.recon.clock()
        rows = []
        if device.get("category"):
            rows.append(("Kind", recon.CATEGORY_LABELS[device["category"]],
                         CATEGORY_COLOR.get(device["category"], TEXT)))
            rows.append(("Evidence", recon.CONFIDENCE_NAMES[device["confidence"]],
                         GRADE_COLOR.get(device["confidence"], TEXT)))
            if device.get("evidence"):
                rows.append(("", device["evidence"], MUTED))
            if device.get("vendor"):
                rows.append(("Vendor", device["vendor"]))
        else:
            rows.append(("Kind", "Not flagged", MUTED))
        if device.get("follow"):
            rows.append(("Following", "Heard at several places you have been, over ten minutes or more", RED))
        if device["transport"] == "wifi":
            radio = (device.get("channel") or "?", device.get("frequency") or "?", device.get("security") or "?")
            rows += [("Name", device.get("name") or "(hidden)"), ("Address", device["address"]),
                     ("Channel", "%s  ·  %s MHz  ·  %s" % radio)]
        else:
            rows += [("Name", device.get("name") or "—"),
                     ("Address", "%s (%s)" % (device["address"], ADDRESS_KIND.get(device.get("address_type"), "?")))]
            if device.get("address_type") in (1, 3):
                rows.append(("", "Random addresses change, so this device may appear again as a new row.", FAINT))
        signal = (fmt_rssi(device.get("rssi")), fmt_rssi(device.get("best_rssi")))
        rows.append(("Signal", "%s dBm now, best %s dBm" % signal, rssi_color(device.get("rssi"))))
        heard = (device["count"], ago(now - device["last_seen"]), ago(now - device["first_seen"]))
        rows.append(("Heard", "%d times, last %s ago, first %s ago" % heard))
        if device.get("best_fix"):
            rows.append(("Strongest at", "%.5f, %.5f" % device["best_fix"]))
        beacon = device.get("beacon")
        if beacon:
            u = beacon["uuid"]
            ids = (beacon["major"], beacon["minor"], beacon["measured_power"])
            rows += [("UUID", "%s-%s-%s-%s-%s" % (u[:8], u[8:12], u[12:16], u[16:20], u[20:])),
                     ("Major/minor", "%d / %d  ·  %d dBm at 1 m" % ids)]
        rid = device.get("remote_id")
        if rid:
            rows += self.drone_rows(app, rid)
        rows.append(("", "A match is broadcast evidence, not proof of recording, intent or ownership.", FAINT))
        return rows

    @staticmethod
    def drone_rows(app, rid):
        rows = []
        fix = app.gps.snapshot()
        here = (fix["latitude"], fix["longitude"]) if fix.get("valid") else None
        if rid.get("has_id"):
            rows.append(("Drone ID", rid["id"], CYAN))
        if rid.get("has_location"):
            there = (rid["latitude"], rid["longitude"])
            rows.append(("Aircraft", "%.5f, %.5f (self-reported)" % there, CYAN))
            if here:
                rows.append(("", away(here, there), CYAN))
            extra = []
            if rid.get("has_altitude"):
                extra.append("altitude %.0f m" % rid["altitude_m"])
            if rid.get("has_speed"):
                extra.append("%.1f m/s" % rid["speed_mps"])
            if extra:
                rows.append(("", ", ".join(extra), MUTED))
        if rid.get("has_operator"):
            there = (rid["operator_latitude"], rid["operator_longitude"])
            kind = OPERATOR_KIND.get(rid.get("operator_location_type"), "operator")
            rows.append(("Operator", "%.5f, %.5f (%s)" % (there[0], there[1], kind), AMBER))
            if here:
                rows.append(("", away(here, there), AMBER))
        return rows

    def handle(self, key, app):
        if key in ("ENTER", "T"):
            app.push(Finder(*self.key))
            return True
        return super().handle(key, app)


class Finder(Screen):
    """A large signal meter for walking towards a device."""

    title = "FIND"
    refresh = 0.25

    def __init__(self, transport, address):
        self.key = (transport, address)
        self.peak = None

    def hints(self, app):
        return [("R", "Reset peak"), ("Esc", "Back")]

    def render(self, c, app):
        device = app.recon.device(*self.key)
        if device is None:
            empty_state(c, "eye", "Device lost", "It has not been heard for a while.")
            return
        now = app.recon.clock()
        history = [(t, v) for t, v in device["rssi_history"] if v is not None and now - t < 30]
        rssi = device.get("rssi") if now - device["last_seen"] < 15 else None
        if rssi is not None and (self.peak is None or rssi > self.peak):
            self.peak = rssi
        y = TOP
        x = 8
        if device.get("category"):
            x += category_pill(c, 8, y + 1, device["category"]) + 6
        c.text((x, y), device_title(device), font("bold", 11), TEXT, width=W - x - 8)
        y += 18
        big = font("display", 40)
        color = rssi_color(rssi) if rssi is not None else FAINT
        c.text((10, y), fmt_rssi(rssi), big, color)
        c.text((14 + c.text_width(fmt_rssi(rssi), big), y + 26), "dBm", font("bold", 10), MUTED)
        trend, tint = "—", MUTED
        if len(history) >= 4:
            half = len(history) // 2
            old = sum(v for _, v in history[:half]) / half
            new = sum(v for _, v in history[half:]) / (len(history) - half)
            if new - old > 2:
                trend, tint = "WARMER", GREEN
            elif old - new > 2:
                trend, tint = "COLDER", AMBER
            else:
                trend = "STEADY"
        c.text_right(W - 10, y + 4, trend, font("display", 14), tint)
        c.text_right(W - 10, y + 24, "peak %s dBm" % fmt_rssi(self.peak), font("mono", 9), MUTED)
        beacon = device.get("beacon")
        estimate = recon.distance_from_rssi(rssi, beacon["measured_power"]) if beacon else None
        if estimate is not None:
            c.text_right(W - 10, y + 36, "≈ %s (rough)" % human_distance(estimate), font("mono", 9), FAINT)
        y += 54
        level = 0 if rssi is None else max(0.0, min(1.0, (rssi + 110) / 70))
        c.progress((10, y, W - 10, y + 10), level, fg=color if rssi is not None else LINE)
        y += 16
        height = CONTENT_BOTTOM - y - 2
        c.rect((10, y, W - 10, y + height), fill=SURFACE, radius=4)
        for (t0, v0), (t1, v1) in zip(history, history[1:]):
            x0 = 12 + (W - 24) * (1 - (now - t0) / 30.0)
            x1 = 12 + (W - 24) * (1 - (now - t1) / 30.0)
            y0 = y + height - 2 - (height - 4) * max(0, min(1, (v0 + 110) / 70))
            y1 = y + height - 2 - (height - 4) * max(0, min(1, (v1 + 110) / 70))
            c.line((x0, y0, x1, y1), fill=GOLD, width=2)
        c.text((14, y + 2), "LAST 30 s", font("bold", 7), FAINT)

    def handle(self, key, app):
        if key == "R":
            self.peak = None
            return True
        return super().handle(key, app)


class Categories(Screen, ListMixin):
    title = "WATCH LIST"
    VISIBLE = 8

    def __init__(self):
        self.index = self.top = 0

    def hints(self, app):
        return [("OK", "On / off"), ("A", "All on"), ("Esc", "Back")]

    def render(self, c, app):
        enabled = set(app.cfg.get("recon_categories", recon.CATEGORIES))
        names = supported_alerts(app, drive_watch.SQUACHWATCH_ORDER)
        self.clamp(len(names), self.VISIBLE)
        for row, name in enumerate(names[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 16
            if self.top + row == self.index:
                c.select(y, 15)
            category_pill(c, 10, y + 2, name, width=56)
            if name not in recon.CATEGORIES:
                c.text((72, y + 2), drive_watch.NAMES[name], font("ui", 10), FAINT, width=150)
                c.text_right(W - 12, y + 3, "Wardrive only", font("ui", 8), FAINT)
                continue
            on = name in enabled
            c.text((72, y + 2), drive_watch.NAMES[name], font("ui", 10), TEXT if on else FAINT, width=180)
            c.rect((W - 44, y + 3, W - 18, y + 12), fill=GOLD if on else SURFACE_2, radius=5)
            c.draw.ellipse((W - 30 if on else W - 43, y + 4, W - 21 if on else W - 34, y + 11),
                           fill=GOLD_INK if on else MUTED)
        self.scrollbar(c, len(names), self.VISIBLE)

    def handle(self, key, app):
        names = supported_alerts(app, drive_watch.SQUACHWATCH_ORDER)
        if self.move(key, len(names), self.VISIBLE):
            return True
        enabled = app.cfg.get("recon_categories", recon.CATEGORIES)
        if key in ("ENTER", "SPACE"):
            chosen = names[self.index]
            if chosen in recon.CATEGORIES:
                app.change("recon_categories", [k for k in recon.CATEGORIES if (k in enabled) != (k == chosen)])
        elif key == "A":
            app.change("recon_categories", list(recon.CATEGORIES))
        else:
            return super().handle(key, app)
        return True


def fresh_alert(app):
    """The newest Recon alert while it is still worth showing."""
    r = app.recon
    if r.state != "running" or not r.alerts or not r.unseen_alerts:
        return None
    alert = r.alerts[0]
    return alert if r.clock() - alert["time"] <= 10 and alert is not app.recon_hidden else None


def banner_y(app, screen):
    """Where alert banners go: just above the key hints, or at the top. On the Wardrive screen the top one sits
    under the counters, so they stay in view."""
    from .screens import Wardrive
    if app.cfg.get("alert_place", "bottom") != "top":
        return BANNER_TOP
    return Wardrive.BANNER_Y if isinstance(screen, Wardrive) else TOP - 2


def banner_box(c, y, fill, edge, age):
    """The frame of an alert banner. Its icon blinks once a second for the first seconds only."""
    c.rect((4, y, W - 4, y + BANNER_H), fill=fill, outline=edge, radius=6)
    lit = age >= BLINK_SECONDS or int(age * 2) % 2 == 0
    icons.draw(c, "alert", 10, y + 4, 18, edge if lit else tuple(v * 2 for v in fill))


def banner_text(c, y, title, detail, right, edge, note):
    small = font("mono", 8)
    room = W - 46 - (int(c.text_width(note, small)) + 8 if note else 0)
    c.text((34, y + 2), title, font("bold", 10), TEXT, width=W - 110)
    c.text((34, y + 14), detail, font("ui", 8), (230, 220, 210), width=room)
    if right:
        c.text_right(W - 12, y + 2, right, font("monob", 9), edge)
    if note:
        c.text_right(W - 12, y + 14, note, small, MUTED)


def alert_banner(c, app, screen=None):
    """A fresh Recon alert, shown over every screen except Recon itself. Del hides it."""
    r = app.recon
    alert = fresh_alert(app)
    if alert is None:
        return False
    strong = alert["confidence"] >= recon.STRONG or alert.get("follow")
    fill, edge = ((70, 12, 14), RED) if strong else ((60, 44, 8), AMBER)
    y = banner_y(app, screen)
    banner_box(c, y, fill, edge, r.clock() - alert["time"])
    detail = "%s  ·  %s" % (alert.get("name") or alert["address"], recon.CONFIDENCE_NAMES[alert["confidence"]])
    more = r.unseen_alerts - 1
    title = ("FOLLOWING?  " if alert.get("follow") else "") + alert["label"] + ("  +%d" % more if more > 0 else "")
    banner_text(c, y, title, detail, "%s dBm" % fmt_rssi(alert.get("rssi")), edge, "Del hide")
    return True


def tone_of(app, kind):
    tone = app.cfg.get("drive_alert_sounds", {}).get(kind)
    return tone if tone in tones.ORDER else drive_watch.DEFAULT_TONES.get(kind, "blip")


class AlertTypes(Screen, ListMixin):
    """Which kinds of device alert during a wardrive, and the tone of each."""

    title = "ALERT ME ABOUT"
    VISIBLE = 8

    def __init__(self):
        self.index = self.top = 0

    def hints(self, app):
        return [("OK", "On / off"), ("Z/C", "Tone"), ("T", "Mute"), ("P", "Play"), ("D", "Defaults")]

    def render(self, c, app):
        enabled = set(app.cfg.get("drive_alert_types", drive_watch.DEFAULT_TYPES))
        muted = set(app.cfg.get("drive_alert_mute", ()))
        sounding = app.cfg.get("drive_alert_tones", True)
        names = supported_alerts(app, drive_watch.TYPES)
        self.clamp(len(names), self.VISIBLE)
        for row, name in enumerate(names[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 16
            selected = self.top + row == self.index
            if selected:
                c.select(y, 15)
            on = name in enabled
            category_pill(c, 10, y + 2, name, width=56)
            c.text((72, y + 2), drive_watch.NAMES[name], font("ui", 10), TEXT if on else FAINT, width=112)
            tone = "Tone off" if name in muted else tones.name(tone_of(app, name))
            quiet = not on or not sounding or name in muted
            c.text_right(W - 50, y + 3, c.fit(tone, 82, font("mono", 8)), font("mono", 8),
                         FAINT if quiet else GOLD if selected else MUTED)
            c.rect((W - 44, y + 3, W - 18, y + 12), fill=GOLD if on else SURFACE_2, radius=5)
            c.draw.ellipse((W - 30 if on else W - 43, y + 4, W - 21 if on else W - 34, y + 11),
                           fill=GOLD_INK if on else MUTED)
        self.scrollbar(c, len(names), self.VISIBLE)

    def handle(self, key, app):
        names = supported_alerts(app, drive_watch.TYPES)
        if self.move(key, len(names), self.VISIBLE):
            return True
        chosen = names[self.index]
        enabled = app.cfg.get("drive_alert_types", drive_watch.DEFAULT_TYPES)
        if key in ("ENTER", "SPACE"):
            app.change("drive_alert_types", [k for k in drive_watch.TYPES if (k in enabled) != (k == chosen)])
        elif key.name in ("LEFT", "RIGHT"):
            order = tones.ORDER
            current = tone_of(app, chosen)
            step = -1 if key.name == "LEFT" else 1
            tone = order[(order.index(current) + step) % len(order)] if current in order else order[0]
            app.change("drive_alert_sounds", dict(app.cfg.get("drive_alert_sounds", {}), **{chosen: tone}))
            app.preview(tone)
        elif key == "T":
            muted = app.cfg.get("drive_alert_mute", [])
            app.change("drive_alert_mute", [k for k in drive_watch.TYPES if (k in muted) != (k == chosen)])
        elif key == "P":
            app.preview(tone_of(app, chosen))
        elif key == "D":
            app.confirm("Restore the defaults?", "Flock cameras, Axon body cams, Meta glasses and My alerts alert, "
                        "each with its own tone. Everything else is saved without an alert.", "Restore",
                        app.alert_defaults)
        else:
            return super().handle(key, app)
        return True


class MyAlerts(Screen, ListMixin):
    title = "MY ALERTS"
    VISIBLE = 7

    def __init__(self):
        self.index = self.top = 0

    def hints(self, app):
        return [("A", "Add"), ("D", "Remove"), ("Esc", "Back")]

    def render(self, c, app):
        entries = app.cfg.get("drive_watch", [])
        if not entries:
            empty_state(c, "alert", "Nothing on your list",
                        "Press A to add a Wi-Fi or Bluetooth name or address. veh matches every name that starts "
                        "with veh, and * or ? match any text. A match always alerts.")
            return
        self.clamp(len(entries), self.VISIBLE)
        for row, entry in enumerate(entries[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 16
            if self.top + row == self.index:
                c.select(y, 15)
            c.text((11, y + 2), entry, font("ui", 10), TEXT, width=W - 110)
            kind = "address" if config.is_mac(entry) else "pattern" if "*" in entry or "?" in entry else "name"
            c.text_right(W - 14, y + 3, kind, font("mono", 9), MUTED)
        self.scrollbar(c, len(entries), self.VISIBLE)
        c.text((10, CONTENT_BOTTOM - 13), "Alerts in every wardrive, whatever kind of device it is.",
               font("ui", 8), FAINT, width=W - 20)

    def handle(self, key, app):
        entries = list(app.cfg.get("drive_watch", []))
        self.clamp(len(entries), self.VISIBLE)
        if self.move(key, len(entries), self.VISIBLE):
            return True
        if key == "A":
            if len(entries) >= config.MAX_WATCH:
                app.toast("The list is full (%d entries)" % config.MAX_WATCH, AMBER)
            else:
                app.push(TextInput("Name, pattern or address", app.watch_add,
                                   hint="Such as veh* or a MAC address. Capitals do not matter.",
                                   limit=config.WATCH_LENGTH))
        elif key == "D" and entries:
            entry = entries[self.index]
            app.confirm("Remove it?", "%s will not alert by itself any more." % entry, "Remove",
                        lambda: app.change("drive_watch", [item for item in entries if item != entry]))
        else:
            return super().handle(key, app)
        return True


class SkipList(Screen, ListMixin):
    title = "NO ALERTS FOR"
    VISIBLE = 7

    def __init__(self):
        self.index = self.top = 0

    def hints(self, app):
        return [("D", "Remove"), ("Esc", "Back")]

    def render(self, c, app):
        entries = app.cfg.get("drive_alert_skip", [])
        if not entries:
            empty_state(c, "alert", "Nothing is silenced",
                        "Open an alert from the wardrive alert list and press N to stop alerts for that device. "
                        "It is still logged.")
            return
        self.clamp(len(entries), self.VISIBLE)
        for row, entry in enumerate(entries[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 16
            if self.top + row == self.index:
                c.select(y, 15)
            c.text((11, y + 2), entry, font("ui", 10), TEXT, width=W - 110)
            c.text_right(W - 14, y + 3, "address" if config.is_mac(entry) else "name", font("mono", 9), MUTED)
        self.scrollbar(c, len(entries), self.VISIBLE)
        c.text((10, CONTENT_BOTTOM - 13), "Still logged and uploaded. They just make no alert.",
               font("ui", 8), FAINT, width=W - 20)

    def handle(self, key, app):
        entries = list(app.cfg.get("drive_alert_skip", []))
        self.clamp(len(entries), self.VISIBLE)
        if self.move(key, len(entries), self.VISIBLE):
            return True
        if key == "D" and entries:
            entry = entries[self.index]
            app.confirm("Remove it?", "%s can alert again." % entry, "Remove",
                        lambda: app.change("drive_alert_skip", [item for item in entries if item != entry]))
        else:
            return super().handle(key, app)
        return True


def drive_alert(app):
    """The wardrive banner to show now, or None."""
    drive = app.drive
    watch = drive.watch if drive is not None and app.wardriving else None
    return watch.banner() if watch is not None else None


def drive_alert_banner(c, app, screen=None):
    """The wardrive banner, over every screen. OK still stops the wardrive; Del hides it and Q makes alerts quiet
    for 10 minutes."""
    view = drive_alert(app)
    if view is None:
        return False
    shown = view["alert"]
    fill, edge = BANNER_FILL.get(view["category"], ((60, 44, 8), AMBER))
    y = banner_y(app, screen)
    banner_box(c, y, fill, edge, view["age"] if view["category"] == "axon" else BLINK_SECONDS)
    fold = view["fold"]
    if view.get("summary"):
        title = "%d new alerts" % fold
        detail = ", ".join(drive_watch.NAMES.get(kind, kind) for kind in view["kinds"])
    elif shown.get("flood"):
        title, detail = shown["name"], shown["evidence"]
    else:
        title = shown["label"] + ("  ×%d" % fold if fold > 1 else "")
        detail = "%s  ·  %s" % (shown.get("name") or shown.get("address") or "—",
                                recon.CONFIDENCE_NAMES.get(shown["confidence"], ""))
        if shown.get("owner"):
            detail += "  ·  " + shown["owner"]
    rssi = view.get("rssi")
    banner_text(c, y, title, detail, "%s dBm" % fmt_rssi(rssi) if rssi is not None else "", edge,
                "Del hide · Q quiet")
    return True


def quiet_text(watch):
    """"9m" while alerts are quiet, or ""."""
    left = watch.quiet_left() if watch is not None else 0
    return "%dm" % max(1, -(-int(left) // 60)) if left > 0 else ""


def toggle_quiet(app):
    watch = app.drive.watch if app.drive is not None and app.wardriving else None
    if watch is None:
        return False
    if watch.quiet():
        app.toast("Quiet for 10 min. Alerts are still listed.")
    else:
        app.toast("Alert tones and banners are back")
    return True


class DriveAlerts(Screen, ListMixin):
    """The alerts of the wardrive running now, newest first. Read only."""

    title = "DRIVE ALERTS"
    VISIBLE = 7

    def __init__(self):
        self.index = self.top = 0

    @staticmethod
    def alerts(app):
        watch = app.drive.watch if app.drive is not None else None
        return watch.alert_list() if watch is not None else []

    def hints(self, app):
        watch = app.drive.watch if app.drive is not None else None
        quiet = quiet_text(watch)
        return [("OK", "Details"), ("Q", "End quiet (%s)" % quiet if quiet else "Quiet 10 min"), ("Esc", "Back")]

    def render(self, c, app):
        alerts = self.alerts(app)
        if not alerts:
            empty_state(c, "alert", "No alerts yet", "Alerts of this wardrive are listed here, newest first.")
            return
        self.clamp(len(alerts), self.VISIBLE)
        for row, shown in enumerate(alerts[self.top:self.top + self.VISIBLE]):
            y = TOP + row * 16
            if self.top + row == self.index:
                c.select(y, 15)
            c.text((9, y + 3), time.strftime("%H:%M", time.localtime(shown["time"])), font("mono", 8), MUTED)
            category_pill(c, 40, y + 2, shown["category"], width=50)
            title = shown["name"] if shown.get("flood") else shown.get("name") or shown.get("address") or "—"
            c.text((96, y + 2), title, font("ui", 10), AMBER if shown.get("flood") else TEXT, width=W - 210)
            if not shown.get("flood"):
                grade_dots(c, W - 108, y + 4, shown["confidence"])
                if shown.get("count", 1) > 1:
                    c.text_right(W - 58, y + 3, "×%d" % shown["count"], font("mono", 8), MUTED)
                c.text_right(W - 14, y + 3, "%s dBm" % fmt_rssi(shown.get("rssi")), font("mono", 8),
                             rssi_color(shown.get("rssi")))
        self.scrollbar(c, len(alerts), self.VISIBLE)

    def handle(self, key, app):
        alerts = self.alerts(app)
        if self.move(key, len(alerts), self.VISIBLE):
            return True
        if key == "ENTER" and alerts:
            app.push(DriveAlertDetail(alerts[min(self.index, len(alerts) - 1)]))
            return True
        if key == "Q" and toggle_quiet(app):
            return True
        return super().handle(key, app)


class DriveAlertDetail(Details):
    def __init__(self, shown):
        super().__init__("ALERT")
        self.shown = shown

    def silenceable(self):
        return not self.shown.get("flood") and self.shown.get("incident") not in ("burst", "deauth")

    def hints(self, app):
        hints = super().hints(app)
        return [("N", "No alerts")] + hints if self.silenceable() else hints

    def handle(self, key, app):
        if key == "N" and self.silenceable():
            app.silence_alert(self.shown)
            return True
        return super().handle(key, app)

    def rows(self, app):
        shown = self.shown
        rows = [("Kind", shown["label"], CATEGORY_COLOR.get(shown["category"], TEXT))]
        if not shown.get("flood"):
            rows.append(("Evidence", recon.CONFIDENCE_NAMES.get(shown["confidence"], ""),
                         GRADE_COLOR.get(shown["confidence"], TEXT)))
        if shown.get("evidence"):
            rows.append(("", shown["evidence"], MUTED))
        if shown.get("vendor"):
            rows.append(("Vendor", shown["vendor"]))
        if shown.get("name"):
            rows.append(("Name", shown["name"]))
        if shown.get("category") == "lorawan" and str(shown.get("address", "")).startswith("02:4C:57:"):
            rows.append(("NetID", shown["address"][9:].replace(":", "")))
        elif shown.get("address"):
            rows.append(("Address", shown["address"]))
        if shown.get("owner"):
            rows.append(("Owner", shown["owner"], PINK))
        if shown.get("rssi") is not None:
            rows.append(("Signal", "best %s dBm" % fmt_rssi(shown["rssi"]), rssi_color(shown["rssi"])))
        rows.append(("Heard", "%s, %s" % (plural(shown.get("count", 1), "time"),
                                          time.strftime("%H:%M:%S", time.localtime(shown["time"])))))
        if len(shown.get("via", ())) > 1:
            rows.append(("Heard by", " + ".join(shown["via"])))
        receiver = shown.get("receiver")
        if receiver:
            rows.append(("You were at", "%.5f, %.5f" % (receiver["latitude"], receiver["longitude"])))
        if shown.get("source") == "dragon":
            rows.append(("From", "Dragon Detector on USB"))
        rows.append(("", "A match is broadcast evidence, not proof of recording, intent or ownership.", FAINT))
        return rows
