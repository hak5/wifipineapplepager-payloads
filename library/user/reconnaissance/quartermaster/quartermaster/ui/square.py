"""Square HAT menus and a one-to-one viewport for Quartermaster's detailed panels."""

import string
import time

from PIL import Image

from .. import __version__, accounts, qr
from . import icons, recon_screens, screens, sky_screens
from .gfx import (AMBER, BG, CYAN, FOOTER_H, GOLD, GOLD_INK, GREEN, H, LINE, MUTED, RED, STATUS_H,
                  SURFACE, SURFACE_2, TEXT, W, Canvas, clock, font)
from .gfx import ago as gfx_ago
from .keys import Key


class SquareUI:
    def __init__(self, size):
        self.size = size
        self.large = size == 240
        self.top = 26 if self.large else 17
        self.bottom = size - (23 if self.large else 15)
        self.row = 27 if self.large else 18
        self.body = font("ui", 15 if self.large else 11)
        self.small = font("ui", 12 if self.large else 9)
        self.bold = font("bold", 16 if self.large else 11)
        self.screen = None

    def sync(self, screen):
        if screen is not self.screen:
            self.screen, self.mode = screen, ""
            self.x, self.y = 0, STATUS_H + 1
            self.index, self.cell = 0, 0
            self.detail_line = 0
            self.actions = []
            self.phone_qr = (None, None)

    def canvas(self):
        return Canvas((self.size, self.size))

    def heading(self, c, title, battery=None):
        c.rect((0, 0, self.size - 1, self.top - 1), fill=SURFACE)
        room = self.size - 8
        if battery:
            level = battery["percent"]
            color = GREEN if battery["charging"] else RED if level <= 10 else AMBER if level <= 20 else MUTED
            right = self.size - 4
            if self.large:
                c.battery(right - 22, (self.top - 10) // 2, level, color, color)
                right -= 26
            reading = "%d%%" % level
            c.text_right(right, (self.top - self.small.size) // 2 - 1, reading, self.small, color)
            room = right - c.text_width(reading, self.small) - 7
        face = self.small if not self.large and c.text_width(title, self.bold) > room else self.bold
        c.text((4, 1), title, face, GOLD, width=room)
        c.line((0, self.top - 1, self.size - 1, self.top - 1))

    def footer(self, c, text):
        c.rect((0, self.bottom, self.size - 1, self.size - 1), fill=SURFACE)
        c.line((0, self.bottom, self.size - 1, self.bottom))
        c.text((3, self.bottom + 1), text, self.small, MUTED, width=self.size - 6)

    def rows(self, c, entries, selected, start=None, bottom=None):
        y = self.top + 2 if start is None else start
        count = max(1, ((self.bottom if bottom is None else bottom) - y) // self.row)
        first = max(0, min(selected - count // 2, len(entries) - count))
        if len(entries) > count:
            track = count * self.row
            thumb_top = y + first * track // len(entries)
            thumb_bottom = y + (first + count) * track // len(entries)
            c.line((self.size - 1, thumb_top, self.size - 1, thumb_bottom), fill=GOLD)
        for i in range(first, min(first + count, len(entries))):
            name = entries[i]
            if i == selected:
                c.rect((2, y, self.size - 3, y + self.row - 2), fill=SURFACE_2, outline=GOLD, radius=3)
            c.text((6, y + 1), name, self.body, TEXT if i == selected else MUTED, width=self.size - 13)
            y += self.row

    def paragraph(self, c, text, y, color=TEXT, end=None, face=None, offset=0):
        face = face or self.body
        height = face.size + 3
        end = self.bottom if end is None else end
        lines = c.wrap(text, self.size - 10, face)
        visible = max(1, (end - y) // height)
        first = min(offset, max(0, len(lines) - visible))
        for line in lines[first:first + visible]:
            c.text((5, y), line, face, color)
            y += height
        return y

    def notice(self, text):
        c = self.canvas()
        self.heading(c, "Quartermaster")
        self.paragraph(c, text, self.top + 8)
        return c.image

    def options(self, app):
        screen = app.screen
        actions = []
        for key, label in screen.hints(app):
            if key in ("Esc", "OK", "Letter") or "/" in key:
                continue
            name = {"Space": "SPACE", "Tab": "TAB", "Del": "BACKSPACE"}.get(key, key.upper())
            if isinstance(screen, screens.Wardrive) and name == "TAB":
                label = "Filter: " + label
            actions.append((label, name))
        if app.banners():
            actions.append(("Dismiss alert", "DELETE"))
            if "drive" in app.banners() and not any(key == "Q" for _, key in actions):
                actions.append(("Quiet 10 min", "Q"))
        if isinstance(screen, screens.PhoneSetup):
            actions.append(("Address and PIN", "address"))
        if not isinstance(screen, (screens.Home, screens.Splash, screens.TextInput)):
            actions.append(("Pan details", "pan"))
        return actions

    def handle(self, key, app):
        screen = app.screen
        self.sync(screen)
        name = key.name
        if self.mode == "actions":
            if name in ("UP", "DOWN"):
                self.index = (self.index + (1 if name == "DOWN" else -1)) % len(self.actions)
            elif name in ("TAB", "ESC"):
                self.mode = ""
            elif name == "ENTER" and not key.repeat:
                _, chosen = self.actions[self.index]
                self.mode = chosen if chosen in ("pan", "address") else ""
                if not self.mode:
                    command = Key(chosen)
                    if not app.banner_key(command):
                        screen.handle(command, app)
            return True
        if self.mode == "address":
            if name in ("ESC", "TAB", "ENTER"):
                self.mode = ""
            return True
        if self.mode == "pan":
            if name in ("UP", "DOWN", "LEFT", "RIGHT"):
                stride = max(12, self.size // 4)
                self.x += {"LEFT": -stride, "RIGHT": stride}.get(name, 0)
                self.y += {"UP": -stride, "DOWN": stride}.get(name, 0)
                self.clamp_view()
            elif name in ("ENTER", "TAB", "ESC"):
                self.mode = ""
            return True
        if isinstance(screen, screens.TextInput):
            if name == "TAB":
                self.mode = "" if self.mode == "type" else "type"
                return True
            if self.mode == "type":
                moves = {"UP": -8, "DOWN": 8, "LEFT": -1, "RIGHT": 1}
                if name in moves:
                    self.cell = (self.cell + moves[name]) % len(self.characters())
                elif name == "ENTER":
                    char = self.characters()[self.cell]
                    if char == "⌫":
                        screen.handle(Key("BACKSPACE"), app)
                    elif char == "✓":
                        screen.handle(Key("ENTER"), app)
                    else:
                        screen.insert(char)
                elif name == "ESC":
                    self.mode = ""
                else:
                    return False
                return True
            return False
        if name == "TAB" and not isinstance(screen, screens.Splash):
            self.actions = self.options(app)
            if self.actions:
                self.index, self.mode = 0, "actions"
            return True
        if isinstance(screen, screens.Home) and name in ("UP", "DOWN", "LEFT", "RIGHT"):
            delta = -1 if name in ("UP", "LEFT") else 1
            screen.index = (screen.index + delta) % len(screen.TILES)
            return True
        if isinstance(screen, screens.Confirm) and name in ("UP", "DOWN"):
            self.detail_line = max(0, self.detail_line + (1 if name == "DOWN" else -1))
            return True
        return False

    @staticmethod
    def characters():
        return "⌫✓ " + string.ascii_lowercase + string.ascii_uppercase + string.digits + string.punctuation

    def editor(self, c, screen):
        y = self.top + 4
        field = screen.display_value()
        while field and c.text_width(field, self.body) > self.size - 16:
            field = field[1:]
        c.rect((3, y, self.size - 4, y + self.row), fill=SURFACE, outline=LINE, radius=3)
        c.text((7, y + 1), field + "|", self.body, TEXT)
        y += self.row + 4
        if self.mode != "type":
            self.paragraph(c, screen.hint or "Use K3 to enter text.", y, MUTED, face=self.small)
            return "OK save · K3 keyboard"
        chars = self.characters()
        first = self.cell // 32 * 32
        step = max(12, (self.bottom - y) // 4)
        for i, char in enumerate(chars[first:first + 32]):
            x, yy = i % 8 * self.size // 8, y + i // 8 * step
            active = first + i == self.cell
            if active:
                c.rect((x + 1, yy, x + self.size // 8 - 1, yy + step - 1), fill=GOLD, radius=2)
            c.put((x + self.size // 16, yy + step // 2), "␣" if char == " " else char, self.body,
                  GOLD_INK if active else TEXT, "mm")
        return "OK type · K3 close"

    def home(self, c, app, screen):
        band = self.row + 2
        self.rows(c, [label for _, label, _ in screen.TILES], screen.index, bottom=self.bottom - band)
        _, label, icon = screen.TILES[screen.index]
        detail, color = screen.subtitle(label, app)
        y = self.bottom - band
        icons.draw(c, icon, 5, y + 1, self.row - 4, color)
        c.text((self.row + 5, y + 1), detail, self.small, color, width=self.size - self.row - 10)

    def wardrive(self, c, app, screen):
        if app.drive is None:
            return
        s = app.drive.status()
        y = self.top + 2
        if s["waiting_for_fix"]:
            y = self.paragraph(c, "Waiting for GPS fix", y, AMBER)
            self.paragraph(c, " ".join(screens.gps_wait(app, s)), y + 2, MUTED, face=self.small)
            return
        c.text((5, y), clock(s["elapsed"]), self.body, GOLD)
        fix = s["gps"].get("valid")
        c.text_right(self.size - 5, y, "GPS fix" if fix else "No fix", self.small, GREEN if fix else AMBER)
        y += self.row
        counts = [("Wi-Fi", s["wifi"], GOLD), ("Bluetooth", s["ble"], CYAN), ("Rows", s["rows"], GREEN)]
        for label, value, color in counts:
            c.text((5, y), label, self.body, MUTED)
            c.text_right(self.size - 6, y, format(value, ","), self.bold, color)
            y += self.row
        warning = screen.warning(app, s)
        if warning:
            self.paragraph(c, warning[0], y, warning[1], face=self.small)
            return
        extras = []
        if s.get("aircraft") is not None:
            extras.append("Aircraft %d" % s["aircraft"])
        nodes = sum(1 for adapter in s["adapters"] if adapter.get("method") == "node")
        if nodes:
            extras.append(screens.plural(nodes, "node"))
        if extras:
            y = self.paragraph(c, " · ".join(extras), y, GOLD, face=self.small)
        limit = (self.bottom - y) // (self.small.size + 3)
        if limit > 0:
            for device in app.drive.tracker.recent(limit, screen.KINDS[screen.filter]):
                c.text((5, y), device.name or device.mac, self.small, TEXT, width=self.size - 10)
                y += self.small.size + 3

    def confirm(self, c, screen):
        y = self.paragraph(c, screen.title, 4, GOLD, face=self.bold)
        y1 = self.bottom - self.row - 3
        self.paragraph(c, screen.words, y + 3, end=y1, face=self.small, offset=self.detail_line)
        face = self.body if c.text_width(screen.action, self.body) <= self.size // 2 - 10 else self.small
        if screen.extra or c.text_width(screen.action, face) > self.size // 2 - 10:
            action = screen.labels[screen.choice]
            fill = RED if screen.choice == 2 or screen.choice and screen.danger else GOLD
            c.rect((2, y1, self.size - 3, self.bottom - 3), fill=fill, radius=3)
            c.text((5, y1 + 1), "‹ " + action + " ›", self.body, GOLD_INK, width=self.size - 10)
            return
        for i, label in enumerate(("Cancel", screen.action)):
            x = i * self.size // 2 + 2
            selected = i == screen.choice
            fill = RED if selected and i and screen.danger else GOLD if selected else SURFACE_2
            c.rect((x, y1, x + self.size // 2 - 4, self.bottom - 3), fill=fill, radius=3)
            c.text((x + 3, y1 + 1), label, face, GOLD_INK if selected else TEXT, width=self.size // 2 - 10)

    def clamp_view(self):
        self.x = max(0, min(W - self.size, self.x))
        self.y = max(STATUS_H + 1, min(H - FOOTER_H - (self.bottom - self.top), self.y))

    def viewport(self, c, app, screen):
        source = Canvas()
        screen.render(source, app)
        if self.mode != "pan" and source.selected_row:
            first, last = source.selected_row
            self.y = min(self.y, first)
            self.y = max(self.y, last + 2 - (self.bottom - self.top))
        self.clamp_view()
        height = min(self.bottom - self.top, H - FOOTER_H - self.y)
        y = self.top + (self.bottom - self.top - height) // 2
        c.paste(source.image.crop((self.x, self.y, self.x + self.size, self.y + height)), (0, y))

    def phone(self, c, screen, app):
        if time.monotonic() - screen.checked > 3:
            screen.check(app)
        if screen.error or not screen.server or not screen.addresses:
            self.paragraph(c, screen.error or "Connect the Pi and phone to the same network.", self.top + 6)
            return
        url = "http://%s:%d" % (screen.addresses[0], screen.server.port)
        link = "%s/#%s" % (url, screen.server.pin)
        if self.phone_qr[0] != link:
            try:
                tile = qr.image(link, scale=1, border=4)
                scale = max(1, (self.bottom - self.top - self.row - 2) // tile.width)
                tile = tile.resize((tile.width * scale,) * 2, Image.Resampling.NEAREST)
            except ValueError:
                tile = None
            self.phone_qr = link, tile
        tile = self.phone_qr[1]
        status = "PIN " + screen.server.pin
        if screen.server.locked:
            status = "Locked. Reopen setup."
        elif screen.server.saves:
            status = "Keys saved"
        if tile and self.mode != "address":
            c.paste(tile, ((self.size - tile.width) // 2, self.top + 1))
            c.text_center(self.size // 2, self.top + tile.height + 2, status, self.small, GOLD)
            return
        y = self.top + 5
        y = self.paragraph(c, url, y, face=self.small)
        self.paragraph(c, status, y, GOLD, face=self.small)

    def settings(self, c, app, screen):
        screen.skip_headers(1)
        key, label, _, detail = screen.items[screen.index]
        section = next(label for key, label, _, _ in reversed(screen.items[:screen.index]) if key is None)
        self.heading(c, section, app.hw.battery)
        y = self.paragraph(c, label, self.top + 3, face=self.bold)
        value = screen.value(app, key)
        if value:
            y = self.paragraph(c, value, y + 2, GOLD)
        if screen.locked(app, key):
            detail = "Stop the wardrive to change this."
        self.paragraph(c, screen.helper_words(app, key) or detail, y + 4, MUTED, face=self.small)

    def logs(self, c, app, screen):
        files = app.log_files()
        if not files:
            self.paragraph(c, "No wardrives saved yet", self.top + 6)
            return
        screen.clamp(len(files), screen.VISIBLE)
        self.rows(c, [screens.when(item["epoch"]) for item in files], screen.index,
                  bottom=self.bottom - self.row)
        active = files[screen.index]
        detail = ("REC  " if active["active"] else "") + screens.size_text(active["size"])
        c.text((5, self.bottom - self.row), detail, self.small, GOLD)

    def hardware(self, c, app, screen):
        cards = screen.cards(app)
        if not cards:
            return
        screen.top = min(screen.top, len(cards) - 1)
        card = cards[screen.top]
        y = self.top + 3
        c.text((5, y), card["tag"], self.small, card["color"])
        c.text_right(self.size - 5, y, "%d / %d" % (screen.top + 1, len(cards)), self.small, MUTED)
        y = self.paragraph(c, card["title"], y + self.small.size + 5, face=self.bold)
        if card.get("right"):
            y = self.paragraph(c, card["right"], y + 2, GOLD, face=self.small)
        if card.get("bands"):
            y = self.paragraph(c, " / ".join(card["bands"]) + " GHz", y + 2, CYAN, face=self.small)
        if card.get("detail"):
            self.paragraph(c, card["detail"], y + 2, card.get("detail_color", MUTED), face=self.small)

    def aircraft(self, c, app, screen):
        """The aircraft heard: one per row, and what is known of the chosen one below the list."""
        status, rows = screen.viewer.status(), screen.rows(app)
        screen.notice(app)
        capture = status["capture"]
        line = self.small.size + 3
        if not rows:
            title, detail = sky_screens.state_words(status)
            y = self.paragraph(c, title, self.top + 4, GOLD if status["listening"] else AMBER)
            self.paragraph(c, detail, y + 2, MUTED, end=self.bottom - line if capture else None, face=self.small)
            if capture:
                c.text_right(self.size - 5, self.bottom - line, "REC", self.small, RED)
            return
        band = 2 * line + 2
        self.rows(c, [seen.name for seen, _, _ in rows], screen.index, bottom=self.bottom - band)
        seen, km, angle = rows[screen.index]
        y = self.bottom - band
        c.line((0, y - 1, self.size - 1, y - 1))
        c.text((5, y), "%s  %s" % (sky_screens.feet(seen.altitude), sky_screens.knots(seen.gs)), self.small, TEXT,
               width=self.size - 10)
        y += line
        c.text((5, y), sky_screens.far(km, angle), self.small, GOLD)
        age = gfx_ago(screen.viewer.mono() - seen.last)
        c.text_right(self.size - 5, y, "REC  " + age if capture else age, self.small, RED if capture else MUTED)

    def aircraft_detail(self, c, app, screen):
        lines = []
        for label, value, *_ in screen.rows(app):
            lines.append("%s: %s" % (label, value) if label else str(value))
        height = self.small.size + 3
        wrapped = [part for line in lines for part in c.wrap(line, self.size - 10, self.small)]
        visible = max(1, (self.bottom - self.top - 4) // height)
        screen.top = max(0, min(screen.top, len(wrapped) - visible))
        y = self.top + 3
        for line in wrapped[screen.top:screen.top + visible]:
            c.text((5, y), line, self.small, TEXT)
            y += height

    def route(self, c, app, screen):
        """The track on a map as wide as the screen, with what the rings mean under it. One step down, the
        positions heard are listed, newest first. Returns the footer."""
        viewer = screen.viewer
        seen, here, parts = viewer.find(screen.code), viewer.here(), viewer.parts(screen.code)
        points = [point for part in parts for point in part]
        line = self.small.size + 3
        if screen.top and points:
            rows = screen.recent(here)
            visible = max(1, (self.bottom - self.top - 4) // line - 1)
            screen.top = min(screen.top, max(1, len(rows) - visible + 1))
            y = self.top + 2
            c.text((5, y), screens.plural(len(rows), "position"), self.small, GOLD, width=self.size - 10)
            for age, alt, km in rows[screen.top - 1:screen.top - 1 + visible]:
                y += line
                c.text((5, y), gfx_ago(age), self.small, MUTED)
                c.text_right(self.size * 5 // 8, y, sky_screens.feet(alt), self.small, TEXT)
                c.text_right(self.size - 5, y, sky_screens.far(km), self.small, GOLD if km is not None else MUTED)
            return "↕ scroll · K2 back"
        screen.top = 0
        box = (2, self.top + 1, self.size - 3, self.bottom - line - 2)
        outer = sky_screens.draw_route(c, box, parts, here, self.small, seen.heading if seen is not None else None)
        words = sky_screens.ring_words(outer) if points else "No position heard yet"
        if points and here is None:
            words += " · no GPS"
            if c.text_width(words, self.small) > self.size - 8:
                words = sky_screens.ring_words(outer, "") + " · no GPS"
        c.text((4, self.bottom - line - 1), words, self.small, GOLD if points else MUTED, width=self.size - 8)
        return "↓ positions · K2 back" if points else "K2 back"

    def captures(self, c, app, screen):
        entries = screen.entries()
        if not entries:
            self.paragraph(c, "No captures saved yet", self.top + 6)
            return
        screen.clamp(len(entries), screen.VISIBLE)
        self.rows(c, [screens.when(entry["epoch"]) for entry in entries], screen.index,
                  bottom=self.bottom - self.row)
        entry = entries[screen.index]
        c.text((5, self.bottom - self.row), "%s  %s" % (screens.size_text(entry["size"]), screen.kinds(entry)),
               self.small, GOLD, width=self.size - 10)

    def render(self, app, banners):
        screen = app.screen
        self.sync(screen)
        c = self.canvas()
        if isinstance(screen, screens.Splash):
            source = Canvas()
            screen.render(source, app)
            source.image.thumbnail((self.size, self.size), Image.Resampling.LANCZOS)
            c.paste(source.image, (0, (self.size - source.image.height) // 2))
            return c.image
        self.heading(c, screen.title or "Quartermaster", app.hw.battery)
        foot = "OK select · K3 actions"
        if self.mode == "actions":
            self.heading(c, "Actions", app.hw.battery)
            self.rows(c, [label for label, _ in self.actions], self.index)
            foot = "OK select · K2 back"
        elif self.mode == "pan":
            self.viewport(c, app, screen)
            foot = "Pan with stick · K2 exit"
        elif isinstance(screen, screens.Home):
            self.home(c, app, screen)
        elif isinstance(screen, screens.Wardrive):
            self.wardrive(c, app, screen)
            foot = "OK stop · K3 actions"
        elif isinstance(screen, screens.Confirm):
            c.rect((0, 0, self.size, self.bottom), fill=BG)
            self.confirm(c, screen)
            foot = "↔ choose · OK confirm"
        elif isinstance(screen, screens.Picker):
            self.rows(c, [label for _, label, _ in screen.options], screen.index)
        elif isinstance(screen, screens.TextInput):
            foot = self.editor(c, screen)
        elif isinstance(screen, screens.PhoneSetup):
            self.phone(c, screen, app)
            foot = "K2 back · K3 actions"
        elif isinstance(screen, screens.Settings):
            self.settings(c, app, screen)
            foot = "↕ setting · OK change"
        elif isinstance(screen, screens.Hardware):
            self.hardware(c, app, screen)
            foot = "↕ device · K3 actions"
        elif isinstance(screen, screens.Keys):
            labels = ["Phone / PC setup"] + [label for _, label, _ in accounts.FIELDS]
            self.rows(c, labels, screen.index)
        elif isinstance(screen, screens.Logs):
            self.logs(c, app, screen)
        elif isinstance(screen, screens.Updates):
            state, text = app.update_state()
            y = self.paragraph(c, "Version " + __version__, self.top + 3, GOLD)
            self.paragraph(c, "Checking…" if state in ("busy", "") else text, y + 3, face=self.small)
            foot = "OK check · K2 back"
        elif isinstance(screen, sky_screens.AircraftList):
            self.aircraft(c, app, screen)
            foot = "OK details · K3 actions"
        elif isinstance(screen, sky_screens.AircraftRoute):
            foot = self.route(c, app, screen)
        elif isinstance(screen, sky_screens.AircraftDetail):
            self.aircraft_detail(c, app, screen)
            foot = "↕ scroll · OK route"
        elif isinstance(screen, sky_screens.Captures):
            self.captures(c, app, screen)
            foot = "K2 back · K3 actions"
        elif isinstance(screen, screens.About):
            y = self.paragraph(c, "Quartermaster " + __version__, self.top + 3, GOLD)
            y = self.paragraph(c, "Raspberry Pi DIY", y + 2)
            y = self.paragraph(c, "Valleytech Solutions", y + 2, MUTED, face=self.small)
            self.paragraph(c, "GPL-3.0", y + 1, MUTED, face=self.small)
        else:
            self.viewport(c, app, screen)
            foot = "K2 back · K3 actions"
        if not self.mode and not isinstance(screen, screens.Modal):
            message, color = "", AMBER
            at_top = app.cfg.get("alert_place") == "top"
            if "drive" in banners:
                view = recon_screens.drive_alert(app)
                if view:
                    message = view["alert"].get("label") or "Drive alert"
            elif "recon" in banners:
                alert = recon_screens.fresh_alert(app)
                if alert:
                    message = alert["label"]
            if app.toast_text and time.monotonic() < app.toast_until:
                message, color = app.toast_text, app.toast_color
                at_top = False
            if message:
                lines = c.wrap(message, self.size - 10, self.small)[:3]
                h = len(lines) * (self.small.size + 3) + 3
                y = self.top + 1 if at_top else self.bottom - h
                c.rect((1, y - 1, self.size - 2, y + h), fill=SURFACE, outline=color, radius=3)
                for line in lines:
                    c.text((5, y), line, self.small, color)
                    y += self.small.size + 3
        self.footer(c, foot)
        return c.image
