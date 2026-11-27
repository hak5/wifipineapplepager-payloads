"""Quartermaster's screens laid out for the Pager: 480x222 and a D-pad with a green and a red button.

The most used screens are drawn for the wide screen. Every other panel is the CardputerZero's own,
shown one to one in the middle: at 320x170 it fits whole, so nothing needs panning.
"""

import time

from PIL import Image

from quartermaster import __version__, accounts, qr
from quartermaster.ui import icons, recon_screens, screens
from quartermaster.ui.gfx import (AMBER, BG, CYAN, FOOTER_H, GOLD, GOLD_INK, GREEN, H, LINE, MUTED, RED,
                                  STATUS_H, SURFACE, SURFACE_2, TEXT, VIOLET, W, Canvas, clock, font)
from quartermaster.ui.keys import Key
from quartermaster.ui.square import SquareUI

from . import PAGER_VERSION, biscuit, biscuit_screen
from .keyboard import WIDE, Keyboard

WIDTH, HEIGHT = 480, 222
TOP = 24
BOTTOM = HEIGHT - 18
ROW = 22
HOME_COLUMNS = 5


def pager_cards(cards):
    from . import listen
    here = listen.present()
    radio = {"tag": "WIFI", "color": GREEN if here else AMBER, "title": listen.LABEL, "bands": ["2.4", "5", "6"],
             "detail": "Wardrives read every frame it hears. PineAP keeps its channels." if here else
             "wlan1mon is not up. Turn on PineAP or Recon, then open Quartermaster again."}
    kept = [card for card in cards if card.get("title") != "No Wi-Fi adapter found"]
    return [radio] + kept


class WideUI(SquareUI):
    def __init__(self):
        super().__init__(240)
        self.size = WIDTH
        self.top, self.bottom, self.row = TOP, BOTTOM, ROW
        self.body = font("ui", 15)
        self.small = font("ui", 12)
        self.bold = font("bold", 16)
        self.title = font("bold", 15)
        self.big = font("display", 34)

    def canvas(self):
        return Canvas((WIDTH, HEIGHT))

    def heading(self, c, title, battery=None, app=None):
        c.rect((0, 0, WIDTH - 1, TOP - 2), fill=SURFACE)
        right = WIDTH - 6
        if battery:
            level = battery["percent"]
            color = GREEN if battery["charging"] else RED if level <= 10 else AMBER if level <= 20 else MUTED
            c.battery(right - 22, 6, level, color, color)
            right -= 27
            reading = "%d%%" % level
            c.text_right(right, 4, reading, self.small, color)
            right -= int(c.text_width(reading, self.small)) + 10
        if app is not None:
            fix = app.gps.snapshot()
            if fix.get("valid"):
                word, color = "GPS", GREEN
            elif fix.get("source", "none") == "none":
                word, color = "No GPS", MUTED
            else:
                word, color = "GPS…", AMBER
            c.text_right(right, 4, word, self.small, color)
            right -= int(c.text_width(word, self.small)) + 10
            if app.wardriving:
                rec = "REC " + clock(app.drive.elapsed()) if not app.drive.waiting else "NO FIX"
                width = int(c.text_width(rec, self.small)) + 14
                c.rect((right - width, 4, right, 19), fill=(70, 10, 10) if not app.drive.waiting else SURFACE_2,
                       outline=RED if not app.drive.waiting else AMBER, radius=7)
                c.text((right - width + 7, 4), rec, self.small, RED if not app.drive.waiting else AMBER)
                right -= width + 8
        c.text((8, 3), title, self.title, GOLD, width=max(10, right - 14))
        c.line((0, TOP - 2, WIDTH - 1, TOP - 2))

    def footer(self, c, text):
        c.rect((0, BOTTOM, WIDTH - 1, HEIGHT - 1), fill=SURFACE)
        c.line((0, BOTTOM, WIDTH - 1, BOTTOM))
        c.text((8, BOTTOM + 2), text, self.small, MUTED, width=WIDTH - 16)

    def rows(self, c, entries, selected, start=None, bottom=None, x0=0, x1=WIDTH, values=None):
        y = TOP + 3 if start is None else start
        count = max(1, ((BOTTOM if bottom is None else bottom) - y) // ROW)
        first = max(0, min(selected - count // 2, len(entries) - count))
        if len(entries) > count:
            track = count * ROW
            c.rect((x1 - 3, y + first * track // len(entries), x1 - 2,
                    y + (first + count) * track // len(entries)), fill=GOLD)
        for i in range(first, min(first + count, len(entries))):
            active = i == selected
            if active:
                c.rect((x0 + 4, y, x1 - 7, y + ROW - 2), fill=SURFACE_2, outline=GOLD, radius=4)
            value = values[i] if values else ""
            room = x1 - x0 - 22
            if value:
                width = int(c.text_width(value, self.small)) + 8
                c.text_right(x1 - 13, y + 3, value, self.small, GOLD if active else MUTED)
                room -= width
            c.text((x0 + 10, y + 2), entries[i], self.body, TEXT if active else MUTED, width=room)
            y += ROW

    def paragraph(self, c, text, y, color=TEXT, end=None, face=None, offset=0, x0=8, x1=WIDTH - 8):
        face = face or self.body
        height = face.size + 4
        end = BOTTOM if end is None else end
        lines = c.wrap(text, x1 - x0, face)
        visible = max(1, (end - y) // height)
        first = min(offset, max(0, len(lines) - visible))
        for line in lines[first:first + visible]:
            c.text((x0, y), line, face, color)
            y += height
        return y

    def notice(self, text):
        c = self.canvas()
        self.heading(c, "QUARTERMASTER")
        self.paragraph(c, text, TOP + 12)
        return c.image

    def handle(self, key, app):
        screen = app.screen
        self.sync(screen)
        if not self.mode and isinstance(screen, screens.Home) and key.name in ("UP", "DOWN", "LEFT", "RIGHT"):
            step = {"LEFT": -1, "RIGHT": 1, "UP": -HOME_COLUMNS, "DOWN": HOME_COLUMNS}[key.name]
            screen.index = (screen.index + step) % len(screen.TILES)
            return True
        if isinstance(screen, screens.TextInput) and self.mode != "actions":
            return self.typing(key, screen, app)
        return super().handle(key, app)

    def sync(self, screen):
        if screen is not self.screen:
            self.kb = Keyboard()
        super().sync(screen)

    def typing(self, key, screen, app):
        name = key.name
        kb = self.sync_kb()
        if name in ("UP", "DOWN", "LEFT", "RIGHT"):
            kb.move(name)
        elif name == "ENTER" and not key.repeat:
            done = kb.press()
            if done is None:
                return True
            if done[0] == "type":
                screen.insert(done[1])
            elif done[0] == "delete":
                screen.value = screen.value[:-1]
            else:
                screen.handle(Key("ENTER"), app)
        elif name == "TAB":
            screen.handle(Key("ENTER"), app)
        elif name == "ESC":
            if screen.value:
                screen.value = screen.value[:-1]
            else:
                screen.handle(Key("ESC"), app)
        elif name in ("BACKSPACE", "DELETE"):
            screen.value = screen.value[:-1]
        elif key.char and key.char.isprintable():
            screen.insert(key.char)
        else:
            return False
        return True

    def home(self, c, app, screen):
        w = (WIDTH - 10) // HOME_COLUMNS
        h = (BOTTOM - TOP - 8) // 2
        for i, (_, label, icon) in enumerate(screen.TILES):
            x, y = 5 + i % HOME_COLUMNS * w, TOP + 3 + i // HOME_COLUMNS * (h + 3)
            active = i == screen.index
            c.rect((x + 2, y, x + w - 3, y + h - 1), fill=SURFACE_2 if active else SURFACE,
                   outline=GOLD if active else LINE, radius=7, width=2 if active else 1)
            detail, color = screen.subtitle(label, app)
            icons.draw(c, icon, x + w // 2 - 15, y + 9, 30, GOLD if active else MUTED)
            c.text_center(x + w // 2, y + 44, label, self.bold, TEXT if active else MUTED)
            c.text_center(x + w // 2, y + 64, c.fit(detail, w - 14, self.small), self.small, color)

    def counter(self, c, box, label, value, color):
        x0, y0, x1, y1 = box
        c.rect(box, fill=SURFACE, radius=6)
        c.rect((x0, y0, x0 + 3, y1), fill=color, radius=1)
        c.text((x0 + 11, y0 + 4), label, self.small, MUTED)
        text = format(value, ",")
        face = self.big if c.text_width(text, self.big) < x1 - x0 - 18 else font("display", 24)
        c.text((x0 + 10, y0 + 20), text, face, color)

    def wardrive(self, c, app, screen):
        if app.drive is None:
            return
        s = app.drive.status()
        if s["waiting_for_fix"]:
            y = TOP + 8
            c.rect((8, y, WIDTH - 8, y + 92), fill=SURFACE, radius=8)
            c.rect((8, y, 12, y + 92), fill=AMBER, radius=2)
            on = int(time.monotonic() * 2) % 2 == 0
            c.draw.ellipse((24, y + 14, 38, y + 28), fill=AMBER if on else SURFACE, outline=AMBER)
            c.text((48, y + 8), "Waiting for GPS fix", font("display", 26), AMBER, width=WIDTH - 70)
            detail, hint = screens.gps_wait(app, s)
            self.paragraph(c, detail, y + 44, TEXT, face=self.body, x0=24, x1=WIDTH - 20)
            self.paragraph(c, hint, y + 68, MUTED, face=self.small, x0=24, x1=WIDTH - 20)
            return
        watch = app.drive.watch
        alerts = len(watch.alerts) if watch is not None else None
        fourth = ("Alerts", alerts, RED) if alerts is not None else ("Rows", s["rows"], GREEN)
        mesh = s.get("mesh")
        tiles = [("Wi-Fi", s["wifi"], GOLD), ("Bluetooth", s["ble"], CYAN),
                 ("Mesh", mesh, VIOLET) if mesh is not None else ("Rows", s["rows"], GREEN), fourth]
        if fourth[0] == "Rows" and tiles[2][0] == "Rows":
            tiles[3] = ("Aircraft", s.get("aircraft") or 0, VIOLET) if s.get("aircraft") is not None else \
                ("Radios", len(s["adapters"]), MUTED)
        half = 252
        tw, th = (half - 14) // 2, (BOTTOM - TOP - 12) // 2
        for i, (label, value, color) in enumerate(tiles):
            x, y = 6 + i % 2 * (tw + 4), TOP + 4 + i // 2 * (th + 4)
            self.counter(c, (x, y, x + tw, y + th), label, value or 0, color)
        x0 = half
        warning = screen.warning(app, s)
        y = TOP + 4
        if warning:
            y = self.paragraph(c, warning[0], y, warning[1], face=self.small, x0=x0, x1=WIDTH - 8) + 2
        label = screen.LABEL[screen.filter]
        c.text((x0, y), "Live · " + label, self.small, GOLD)
        c.text_right(WIDTH - 8, y, format(s["rows"], ",") + " rows", self.small, MUTED)
        y += self.small.size + 6
        limit = max(0, (BOTTOM - y) // 20)
        for device in app.drive.tracker.recent(limit, screen.KINDS[screen.filter]):
            rssi = getattr(device, "best_rssi", None) or getattr(device, "rssi", None)
            name = device.name or device.mac
            if rssi is not None:
                c.text_right(WIDTH - 8, y + 1, "%d" % rssi, self.small, MUTED)
            c.text((x0, y), name, self.body, TEXT, width=WIDTH - x0 - 44)
            y += 20

    def confirm(self, c, screen):
        y = self.paragraph(c, screen.title, TOP + 6, GOLD, face=self.bold)
        y1 = BOTTOM - 40
        self.paragraph(c, screen.detail, y + 4, end=y1 - 4, face=self.body, offset=self.detail_line)
        for i, label in enumerate(("Cancel", screen.action)):
            x = 8 + i * (WIDTH - 16) // 2
            selected = i == screen.choice
            fill = RED if selected and i and screen.danger else GOLD if selected else SURFACE_2
            c.rect((x, y1, x + (WIDTH - 16) // 2 - 8, BOTTOM - 6), fill=fill, radius=6)
            c.text_center(x + (WIDTH - 16) // 4 - 4, y1 + 8, c.fit(label, (WIDTH - 16) // 2 - 20, self.bold),
                          self.bold, GOLD_INK if selected else TEXT)

    def editor(self, c, screen):
        kb = self.sync_kb()
        y = TOP + 3
        field = screen.value
        while field and c.text_width(field, self.body) > WIDTH - 90:
            field = field[1:]
        c.rect((6, y, WIDTH - 7, y + ROW + 2), fill=SURFACE, outline=LINE, radius=4)
        width = c.text((12, y + 3), field, self.body, TEXT)
        if int(time.monotonic() * 2) % 2 == 0:
            c.rect((13 + width, y + 4, 15 + width, y + ROW - 2), fill=GOLD)
        c.text_right(WIDTH - 14, y + 5, "%d typed" % len(screen.value), self.small, MUTED)
        y += ROW + 7
        rows = kb.rows() + [kb.action_row()]
        step = (BOTTOM - y - 2) // len(rows)
        for r, row in enumerate(rows):
            action = r == len(rows) - 1
            weights = [WIDE.get(name, 1) for name, _ in row] if action else [1] * len(row)
            unit = (WIDTH - 8) / (sum(weights) if action else max(len(line) for line in kb.rows()))
            x = 4.0
            for i, item in enumerate(row):
                w = unit * weights[i]
                label = item[1] if action else item
                active = r == kb.row and i == kb.col
                fill = GOLD if active else SURFACE_2 if action else SURFACE
                c.rect((int(x) + 1, y + 1, int(x + w) - 2, y + step - 2), fill=fill,
                       outline=GOLD if active else LINE, radius=4)
                face = self.small if action else self.bold
                c.put((int(x + w / 2), y + step // 2), label, face, GOLD_INK if active else TEXT, "mm")
                x += w
            y += step
        return "Green type · Hold green save · Red delete, or back when empty"

    def sync_kb(self):
        if getattr(self, "kb", None) is None:
            self.kb = Keyboard()
        return self.kb

    def viewport(self, c, app, screen):
        source = Canvas()
        screen.render(source, app)
        body = source.image.crop((0, STATUS_H + 1, W, H - FOOTER_H))
        zoom = min((WIDTH - 8) / body.width, (BOTTOM - TOP - 2) / body.height)
        body = body.resize((int(body.width * zoom), int(body.height * zoom)), Image.Resampling.BILINEAR)
        x = (WIDTH - body.width) // 2
        y = TOP + (BOTTOM - TOP - body.height) // 2
        c.paste(body, (x, y))

    def phone(self, c, screen, app):
        if time.monotonic() - screen.checked > 3:
            screen.check(app)
        if screen.error or not screen.server or not screen.addresses:
            self.paragraph(c, screen.error or "Connect the Pager and your phone to the same network.", TOP + 10)
            return
        url = "http://%s:%d" % (screen.addresses[0], screen.server.port)
        link = "%s/#%s" % (url, screen.server.pin)
        if self.phone_qr[0] != link:
            try:
                tile = qr.image(link, scale=1, border=3)
                scale = max(1, (BOTTOM - TOP - 6) // tile.width)
                tile = tile.resize((tile.width * scale,) * 2, Image.Resampling.NEAREST)
            except ValueError:
                tile = None
            self.phone_qr = link, tile
        tile = self.phone_qr[1]
        x0 = 10
        if tile:
            c.paste(tile, (10, TOP + 3))
            x0 = tile.width + 22
        status = "PIN " + screen.server.pin
        if screen.server.locked:
            status = "Locked. Open setup again."
        elif screen.server.saves:
            status = "Keys saved"
        y = self.paragraph(c, "Scan with your phone, or open:", TOP + 8, MUTED, face=self.small, x0=x0)
        y = self.paragraph(c, url, y + 2, TEXT, face=self.body, x0=x0)
        self.paragraph(c, status, y + 8, GOLD, face=self.bold, x0=x0)

    def settings(self, c, app, screen):
        screen.skip_headers(1)
        key, label, _, detail = screen.items[screen.index]
        section = next(label for key, label, _, _ in reversed(screen.items[:screen.index]) if key is None)
        self.heading(c, "SETTINGS · " + section.upper(), app.hw.battery, app)
        entries, values, selected = [], [], 0
        for i, (k, name, _, _) in enumerate(screen.items):
            if k is None:
                continue
            if i == screen.index:
                selected = len(entries)
            entries.append(name)
            values.append(screen.value(app, k) or "")
        split = BOTTOM - 40
        self.rows(c, entries, selected, bottom=split, values=values)
        if screen.locked(app, key):
            detail = "Stop the wardrive to change this."
        c.line((0, split, WIDTH - 1, split))
        self.paragraph(c, screen.helper_words(app, key) or detail or "", split + 4, MUTED, face=self.small)

    def logs(self, c, app, screen):
        files = app.log_files()
        if not files:
            self.paragraph(c, "No wardrives saved yet.", TOP + 12)
            return
        screen.clamp(len(files), screen.VISIBLE)
        labels = [screens.when(item["epoch"]) for item in files]
        values = [("REC  " if item["active"] else "") + screens.size_text(item["size"]) for item in files]
        self.rows(c, labels, screen.index, values=values)

    def hardware(self, c, app, screen):
        cards = pager_cards(screen.cards(app))
        if not cards:
            return
        screen.top = min(screen.top, len(cards) - 1)
        self.rows(c, [card["title"] for card in cards], screen.top, x1=200,
                  values=None)
        card = cards[screen.top]
        x0 = 210
        c.line((202, TOP, 202, BOTTOM))
        y = TOP + 6
        c.text((x0, y), card["tag"], self.small, card["color"])
        c.text_right(WIDTH - 8, y, "%d / %d" % (screen.top + 1, len(cards)), self.small, MUTED)
        y = self.paragraph(c, card["title"], y + self.small.size + 6, face=self.bold, x0=x0)
        if card.get("right"):
            y = self.paragraph(c, card["right"], y + 2, GOLD, face=self.small, x0=x0)
        if card.get("bands"):
            y = self.paragraph(c, " / ".join(card["bands"]) + " GHz", y + 2, CYAN, face=self.small, x0=x0)
        if card.get("detail"):
            self.paragraph(c, card["detail"], y + 2, card.get("detail_color", MUTED), face=self.small, x0=x0)

    def biscuit(self, c, app, screen):
        screen.tick(app)
        link = app.biscuit
        s = link.status()
        if not link.running:
            y = TOP + 8
            c.text((10, y), "Biscuit 6 GHz node", font("display", 26), GOLD, width=WIDTH - 20)
            y = y + 38
            if s["error"] and link.state == biscuit.FAILED:
                y = self.paragraph(c, s["error"], y, RED, face=self.small, x0=10) + 4
            self.paragraph(c, biscuit_screen.HELP, y, TEXT, x0=10)
            return "Green start node · Red back"
        word, detail, color = biscuit_screen.WORDS.get(s["state"], biscuit_screen.WORDS[biscuit.FAILED])
        half = 252
        tw, th = (half - 14) // 2, (BOTTOM - TOP - 12) // 2
        tiles = [("6 GHz heard", s.get("heard", 0), GOLD), ("Sent to Biscuit", s.get("sent", 0), GREEN),
                 ("Updates sent", s.get("updates", 0), CYAN), ("Waiting", s.get("queued", 0), MUTED)]
        for i, (label, value, tint) in enumerate(tiles):
            x, y = 6 + i % 2 * (tw + 4), TOP + 4 + i // 2 * (th + 4)
            self.counter(c, (x, y, x + tw, y + th), label, value or 0, tint)
        x0 = half
        y = TOP + 4
        c.text((x0, y), word, font("display", 24), color, width=WIDTH - x0 - 8)
        y = self.paragraph(c, detail, y + 32, TEXT, face=self.small, x0=x0)
        lines = ["Biscuit " + s["biscuit"] if s.get("biscuit") else "No Biscuit yet"]
        if s.get("channel"):
            lines.append("6 GHz channel %d" % s["channel"])
        if s.get("heard_ago") is not None:
            lines.append("Biscuit heard %ds ago" % s["heard_ago"])
        lines.append("Reports as %s" % biscuit.FIRMWARE.decode())
        lines.append("On for " + clock(s.get("seconds", 0)))
        for line in lines:
            if y + self.small.size > BOTTOM - 2:
                break
            c.text((x0, y + 2), line, self.small, MUTED, width=WIDTH - x0 - 8)
            y += self.small.size + 5
        return "Green stop node · Red menu, node keeps running"

    def about(self, c):
        y = self.paragraph(c, "Quartermaster " + __version__, TOP + 8, GOLD, face=self.bold)
        y = self.paragraph(c, "for the Hak5 WiFi Pineapple Pager, payload " + PAGER_VERSION, y + 2)
        y = self.paragraph(c, "Valleytech Solutions · GPL-3.0", y + 4, MUTED, face=self.small)
        self.paragraph(c, "Lists and rules from SquachWatch (Talking Sasquach), flock-you and Dragon Detector.",
                       y + 4, MUTED, face=self.small)

    def banner(self, c, app, banners):
        message, color = "", AMBER
        at_top = app.cfg.get("alert_place") == "top"
        if "drive" in banners:
            view = recon_screens.drive_alert(app)
            if view:
                message = view["alert"].get("label") or "Drive alert"
                color = RED
        elif "recon" in banners:
            alert = recon_screens.fresh_alert(app)
            if alert:
                message, color = alert["label"], RED
        if app.toast_text and time.monotonic() < app.toast_until:
            message, color = app.toast_text, app.toast_color
            at_top = False
        if not message:
            return
        lines = c.wrap(message, WIDTH - 60, self.bold)[:2]
        h = len(lines) * (self.bold.size + 4) + 10
        y = TOP + 2 if at_top else BOTTOM - h - 2
        c.rect((4, y, WIDTH - 5, y + h), fill=SURFACE, outline=color, radius=6, width=2)
        c.rect((4, y, 10, y + h), fill=color, radius=2)
        yy = y + 5
        for line in lines:
            c.text((18, yy), line, self.bold, color)
            yy += self.bold.size + 4
        c.text_right(WIDTH - 12, y + 5, "Red hides", self.small, MUTED)

    def render(self, app, banners):
        screen = app.screen
        self.sync(screen)
        c = self.canvas()
        if isinstance(screen, screens.Splash):
            source = Canvas()
            screen.render(source, app)
            scaled = source.image.resize((int(W * (HEIGHT / H)), HEIGHT), Image.Resampling.BILINEAR)
            c.rect((0, 0, WIDTH - 1, HEIGHT - 1), fill=BG)
            c.paste(scaled, ((WIDTH - scaled.width) // 2, 0))
            return c.image
        self.heading(c, (screen.title or "Quartermaster").upper(), app.hw.battery, app)
        foot = "Green open · Hold green actions · Red back"
        if self.mode == "actions":
            self.heading(c, "ACTIONS", app.hw.battery, app)
            self.rows(c, [label for label, _ in self.actions], self.index)
            foot = "Green choose · Red back"
        elif self.mode == "pan":
            self.mode = ""
            self.viewport(c, app, screen)
        elif isinstance(screen, screens.Home):
            self.home(c, app, screen)
            foot = "D-pad move · Green open · Hold green actions · Hold red 2 s to exit"
        elif isinstance(screen, screens.Wardrive):
            self.wardrive(c, app, screen)
            foot = "Green stop and save · Hold green actions · Red menu"
        elif isinstance(screen, screens.Confirm):
            c.rect((0, TOP - 1, WIDTH, BOTTOM), fill=BG)
            self.confirm(c, screen)
            foot = "Left / Right choose · Green confirm"
        elif isinstance(screen, screens.Picker):
            self.rows(c, [label for _, label, _ in screen.options], screen.index)
            foot = "Up / Down choose · Green pick · Red back"
        elif isinstance(screen, screens.TextInput):
            foot = self.editor(c, screen)
        elif isinstance(screen, screens.PhoneSetup):
            self.phone(c, screen, app)
            foot = "Red back · Hold green actions"
        elif isinstance(screen, screens.Settings):
            self.settings(c, app, screen)
            foot = "Up / Down setting · Left / Right or green change · Red back"
        elif isinstance(screen, screens.Hardware):
            self.hardware(c, app, screen)
            foot = "Up / Down device · Hold green actions · Red back"
        elif isinstance(screen, screens.Keys):
            labels = ["Phone / PC setup"] + [label for _, label, _ in accounts.FIELDS]
            self.rows(c, labels, screen.index)
        elif isinstance(screen, screens.Logs):
            self.logs(c, app, screen)
            foot = "Green open · Hold green actions · Red back"
        elif isinstance(screen, screens.Updates):
            state, text = app.update_state()
            y = self.paragraph(c, "Version " + __version__, TOP + 8, GOLD, face=self.bold)
            self.paragraph(c, "Checking…" if state in ("busy", "") else text, y + 4)
            foot = "Green check · Red back"
        elif isinstance(screen, biscuit_screen.BiscuitScreen):
            foot = self.biscuit(c, app, screen)
        elif isinstance(screen, screens.About):
            self.about(c)
        else:
            self.viewport(c, app, screen)
            foot = "Red back · Hold green actions"
        if not self.mode and not isinstance(screen, screens.Modal):
            self.banner(c, app, banners)
        self.footer(c, foot)
        return c.image

    def options(self, app):
        return [entry for entry in super().options(app) if entry[1] != "pan"]
