"""The aircraft viewer: the list of aircraft heard, one aircraft and its route, and the captures saved."""

import math

from .. import skyview
from .gfx import (AMBER, CONTENT_BOTTOM, CYAN, FAINT, GOLD, GREEN, LINE, MUTED, RED, SURFACE, TEXT, W, ago,
                  compass, font)
from .screens import TOP, WHITE, Details, ListMixin, Screen, empty_state, plural, size_text, when

UNKNOWN = "Unknown"
STALE_SECONDS = 60.0
RINGS = (1, 2, 5, 10, 20, 50, 100, 200, 500, 1000)
CATEGORIES = {"A1": "Light aircraft", "A2": "Small aircraft", "A3": "Large aircraft", "A4": "Large, strong wake",
              "A5": "Heavy aircraft", "A6": "High performance", "A7": "Helicopter", "B1": "Glider",
              "B2": "Balloon or airship", "B3": "Parachutist", "B4": "Ultralight", "B6": "Drone",
              "B7": "Spacecraft", "C1": "Emergency vehicle", "C2": "Service vehicle", "C3": "Obstacle",
              "C4": "Obstacle", "C5": "Obstacle"}
EMERGENCY = {"7500": "hijack", "7600": "radio failure", "7700": "emergency"}


def feet(value):
    return "—" if value is None else "{:,} ft".format(int(round(value)))


def knots(value):
    return "—" if value is None else "%d kt" % round(value)


def far(km, angle=None):
    if km is None:
        return "—"
    text = "%.1f km" % km if km < 10 else "%d km" % round(km)
    return text if angle is None else "%s %s" % (text, compass(angle))


def category(code):
    return "%s (%s)" % (CATEGORIES[code], code) if code in CATEGORIES else code or UNKNOWN


def place(seen, here):
    """(km, bearing) of an aircraft's last position from the user, or (None, None)."""
    if here is None or seen.lat is None:
        return None, None
    return skyview.kilometres(here, seen.lat, seen.lon), skyview.bearing(here, seen.lat, seen.lon)


def detail_rows(seen, here, now, points):
    """Everything known of one aircraft, as (label, value). What was not heard says so. points is how many
    positions were heard, which can be more than the route keeps."""
    def known(value, form="%s"):
        return UNKNOWN if value is None else form % value
    squawk = seen.squawk
    if squawk in EMERGENCY:
        squawk = "%s (%s)" % (squawk, EMERGENCY[squawk])
    heading = known(seen.track, "%.0f°")
    if seen.track is not None:
        heading += " " + compass(seen.track)
    elif seen.mag_heading is not None:
        heading = "%.0f° magnetic" % seen.mag_heading
    rate = seen.rate
    rows = [("ICAO", seen.hex.upper()), ("Callsign", (seen.flight or "").strip() or UNKNOWN),
            ("Squawk", squawk or UNKNOWN), ("Category", category(seen.category)),
            ("Altitude baro", UNKNOWN if seen.alt_baro is None else feet(seen.alt_baro)),
            ("Altitude GNSS", UNKNOWN if seen.alt_geom is None else feet(seen.alt_geom)),
            ("Ground speed", UNKNOWN if seen.gs is None else knots(seen.gs))]
    if seen.tas is not None or seen.ias is not None:
        rows.append(("Airspeed", "%d kt %s" % ((seen.tas, "true") if seen.tas is not None else
                                                 (seen.ias, "indicated"))))
    rows += [("Heading", heading),
             ("Vertical rate", UNKNOWN if rate is None else "Level" if not rate else "%+d ft/min" % rate)]
    if seen.lat is None:
        rows.append(("Position", UNKNOWN))
    else:
        age = now - seen.pos_time
        rows.append(("Position", "%.5f, %.5f" % (seen.lat, seen.lon) +
                     (" (%s ago)" % ago(age) if age > 10 else "")))
        km, angle = place(seen, here)
        rows.append(("From you", far(km, angle) if km is not None else "Unknown: no GPS fix"))
    rows += [("Messages", "{:,}".format(seen.messages) if seen.messages else UNKNOWN),
             ("First heard", ago(now - seen.first) + " ago"), ("Last heard", ago(now - seen.last) + " ago"),
             ("Signal", UNKNOWN if seen.rssi is None else "%.1f dBFS" % seen.rssi),
             ("Route", plural(points, "position") + " heard" if points else "No position heard yet")]
    return rows


def turned(degrees):
    """A difference between two longitudes, the short way round."""
    return (degrees + 180.0) % 360.0 - 180.0


def shown_name(viewer, code):
    seen = viewer.find(code)
    return seen.name if seen is not None else code.upper()


def ring_km(needed):
    return next((ring for ring in RINGS if ring >= needed), RINGS[-1])


def draw_route(c, box, parts, here, face, heading=None):
    """The track an aircraft flew while it was heard, north up, inside box (x0, y0, x1, y1).

    With a GPS fix the user is the cross in the middle, and the two rings are the distances the label gives.
    Without one the middle is the middle of the track. parts are the lists of positions the viewer gives: each is
    one line, so no line is drawn over a time in which the aircraft was not heard. Returns the distance of the
    outer ring in km."""
    x0, y0, x1, y1 = box
    cx, cy, radius = (x0 + x1) // 2, (y0 + y1) // 2, min(x1 - x0, y1 - y0) // 2 - 2
    points = [point for part in parts for point in part]
    c.rect(box, fill=SURFACE, radius=4)
    if here is not None:
        middle = here
    elif points:
        middle = (sum(p[1] for p in points) / len(points),
                  points[0][2] + sum(turned(p[2] - points[0][2]) for p in points) / len(points))
    else:
        middle = (0.0, 0.0)
    east = 111.32 * math.cos(math.radians(middle[0]))
    spots = [(turned(p[2] - middle[1]) * east, (p[1] - middle[0]) * 110.57) for p in points]
    outer = ring_km(max([math.hypot(x, y) for x, y in spots] + [0.5]))
    scale = radius / outer
    for part in (0.5, 1.0):
        r = int(radius * part)
        c.draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=LINE)
    c.line((cx, cy - radius, cx, cy - radius + 4), fill=MUTED)
    c.put((cx + 3, y0 + 2), "N", face, MUTED)
    if here is not None:
        c.line((cx - 3, cy, cx + 3, cy), fill=GREEN)
        c.line((cx, cy - 3, cx, cy + 3), fill=GREEN)
    dots = [(cx + x * scale, cy - y * scale) for x, y in spots]
    first = 0
    for part in parts:
        if len(part) > 1:
            c.draw.line(dots[first:first + len(part)], fill=GOLD, width=1)
        else:
            c.draw.point(dots[first], fill=GOLD)
        first += len(part)
    if dots:
        c.draw.ellipse((dots[0][0] - 1, dots[0][1] - 1, dots[0][0] + 1, dots[0][1] + 1), fill=MUTED)
        x, y = dots[-1]
        c.draw.ellipse((x - 3, y - 3, x + 3, y + 3), fill=GOLD)
        if heading is not None:
            angle = math.radians(heading)
            c.line((x, y, x + 9 * math.sin(angle), y - 9 * math.cos(angle)), fill=WHITE)
    return outer


def ring_words(outer, name="Rings "):
    return "%s%g / %d km" % (name, outer / 2, outer)


def state_words(status):
    """(title, detail) for a viewer that shows no aircraft."""
    if status["listening"]:
        return "Listening for aircraft", ("Aircraft show up here as the stick hears them. The antenna needs a "
                                          "view of the sky.")
    return "Not listening", status["detail"] or "The radio is starting."


class AircraftList(Screen, ListMixin):
    title = "AIRCRAFT"
    VISIBLE = 7
    refresh = 1.0
    ORDERS = {"near": "nearest first", "latest": "latest first"}

    def __init__(self, app):
        self.index = self.top = 0
        self.order, self.chosen, self._said = "near", None, ""
        self.viewer = app.sky_open()

    def hints(self, app):
        saving = self.viewer.capture is not None
        return [("OK", "Details"), ("S", "End capture" if saving else "Save capture"), ("Tab", "Sort"),
                ("L", "Captures"), ("Esc", "Back")]

    def rows(self, app):
        """The aircraft in view, with the one chosen kept under the cursor as the list changes order."""
        rows = self.viewer.planes(self.order, self.viewer.here())
        codes = [row[0].hex for row in rows]
        if self.chosen in codes:
            self.index = codes.index(self.chosen)
        self.clamp(len(rows), self.VISIBLE)
        self.chosen = codes[self.index] if codes else None
        return rows

    def notice(self, app):
        """Say once why a capture ended by itself."""
        note = self.viewer.note
        if note and note != self._said:
            app.toast(note, AMBER, 5)
        self._said = note

    def render(self, c, app):
        self.notice(app)
        status, rows = self.viewer.status(), self.rows(app)
        capture = status["capture"]
        if not rows:
            empty_state(c, "wifi", *state_words(status))
        if capture:
            words = "REC  %s · %s" % (plural(capture["points"], "position"), plural(capture["frames"], "frame"))
            c.text_right(W - 10, TOP - 1, words, font("bold", 7), RED)
        elif rows:
            c.text_right(W - 10, TOP - 1, status["detail"], font("bold", 7),
                         FAINT if status["listening"] else AMBER)
        if not rows:
            return
        c.text((11, TOP - 1), "%d aircraft · %s" % (len(rows), self.ORDERS[self.order]), font("bold", 7), FAINT)
        now = self.viewer.mono()
        for line, (seen, km, angle) in enumerate(rows[self.top:self.top + self.VISIBLE]):
            y = TOP + 10 + line * 17
            if self.top + line == self.index:
                c.select(y, 15)
            age = now - seen.last
            color = TEXT if age <= STALE_SECONDS else FAINT
            c.text((11, y + 2), seen.name, font("mono", 10), color if seen.flight else CYAN if color == TEXT else FAINT)
            c.text_right(132, y + 3, "—" if seen.altitude is None else "%dft" % seen.altitude, font("mono", 9),
                         MUTED if color == TEXT else FAINT)
            c.text_right(178, y + 3, "—" if seen.gs is None else "%dkt" % round(seen.gs), font("mono", 9),
                         MUTED if color == TEXT else FAINT)
            c.text_right(262, y + 3, far(km, angle), font("mono", 9), GOLD if km is not None else FAINT)
            c.text_right(W - 12, y + 3, ago(age), font("mono", 9), MUTED if color == TEXT else FAINT)
        self.scrollbar(c, len(rows), self.VISIBLE, y0=TOP + 10)

    def toggle_capture(self, app):
        viewer = self.viewer
        if viewer.capture is None:
            why = viewer.capture_start()
            if why:
                return app.toast(why, RED, 5)
            return app.toast("Capture started. It saves until you end it or go back.", GREEN, 5)
        name = viewer.capture_finish()
        app.toast("Capture saved in quartermaster/aircraft" if name else
                  viewer.note or "Nothing was heard, so nothing was saved", GREEN if name else AMBER, 5)
        self._said = viewer.note

    def handle(self, key, app):
        rows = self.rows(app)
        if self.move(key, len(rows), self.VISIBLE):
            self.chosen = rows[self.index][0].hex
            return True
        if key == "ENTER":
            if rows:
                app.push(AircraftDetail(self.viewer, rows[self.index][0].hex))
        elif key == "S" and not key.repeat:
            self.toggle_capture(app)
        elif key.name == "TAB":
            if not key.repeat:
                self.order = "latest" if self.order == "near" else "near"
        elif key == "L":
            app.push(Captures(self.viewer))
        else:
            return super().handle(key, app)
        return True

    def closed(self, app):
        app.sky_close()


class AircraftDetail(Details):
    VISIBLE = 10
    refresh = 1.0

    def __init__(self, viewer, code):
        self.viewer, self.code = viewer, code
        super().__init__("")

    title = property(lambda self: "AIRCRAFT " + shown_name(self.viewer, self.code), lambda self, value: None)

    def hints(self, app):
        return [("OK", "Route"), ("F/X", "Scroll"), ("Esc", "Back")]

    def rows(self, app):
        seen = self.viewer.find(self.code)
        if seen is None:
            return [("", "This aircraft is no longer in the list.", AMBER)]
        return detail_rows(seen, self.viewer.here(), self.viewer.mono(), seen.heard)

    def handle(self, key, app):
        if key in ("ENTER", "R"):
            app.push(AircraftRoute(self.viewer, self.code))
            return True
        return super().handle(key, app)


class AircraftRoute(Screen):
    refresh = 1.0
    VISIBLE = 8

    def __init__(self, viewer, code):
        self.viewer, self.code = viewer, code
        self.top = 0

    title = property(lambda self: "ROUTE " + shown_name(self.viewer, self.code))

    def hints(self, app):
        return [("F/X", "Points"), ("Esc", "Back")]

    def recent(self, here):
        """The positions heard, newest first, as (age in seconds, altitude, km from the user or None)."""
        now = self.viewer.mono()
        return [(now - p[0], p[3], skyview.kilometres(here, p[1], p[2]) if here is not None else None)
                for p in reversed(self.viewer.track(self.code))]

    def render(self, c, app):
        seen, here = self.viewer.find(self.code), self.viewer.here()
        parts = self.viewer.parts(self.code)
        points = [point for part in parts for point in part]
        small = font("mono", 8)
        outer = draw_route(c, (4, TOP - 2, 134, CONTENT_BOTTOM - 2), parts, here, small,
                           seen.heading if seen is not None else None)
        x = 142
        c.text((x, TOP - 1), ring_words(outer), font("bold", 9), GOLD)
        if here is not None:
            c.text((x, TOP + 11), "You are the cross. North is up.", font("ui", 8), MUTED, width=W - x - 6)
        else:
            c.text((x, TOP + 11), "No GPS fix: the track is centred.", font("ui", 8), AMBER, width=W - x - 6)
        if not points:
            c.text((x, TOP + 30), "No position heard yet.", font("ui", 9), MUTED, width=W - x - 6)
            return
        rows = self.recent(here)
        self.top = max(0, min(self.top, max(0, len(rows) - self.VISIBLE)))
        c.text((x, TOP + 24), plural(len(rows), "position") + ", newest first", font("bold", 7), FAINT)
        for line, (age, alt, km) in enumerate(rows[self.top:self.top + self.VISIBLE]):
            y = TOP + 34 + line * 12
            c.text((x, y), ago(age), font("mono", 9), MUTED)
            c.text_right(x + 96, y, "—" if alt is None else "%dft" % alt, font("mono", 9), TEXT)
            c.text_right(W - 8, y, far(km), font("mono", 9), GOLD if km is not None else FAINT)

    def handle(self, key, app):
        step = {"UP": -1, "DOWN": 1, "PAGEUP": -self.VISIBLE, "PAGEDOWN": self.VISIBLE}.get(key.name)
        if step is not None:
            self.top = max(0, self.top + step)
            return True
        return super().handle(key, app)


class Captures(Screen, ListMixin):
    title = "CAPTURES"
    VISIBLE = 6
    refresh = 2.0

    def __init__(self, viewer):
        self.index = self.top = 0
        self.viewer = viewer

    def hints(self, app):
        return [("D", "Delete"), ("F/X", "Move"), ("Esc", "Back")]

    def entries(self):
        return skyview.captures(self.viewer.folder)

    @staticmethod
    def kinds(entry):
        return " + ".join(name for name, there in (("track", entry["track"]), ("frames", entry["frames"])) if there)

    def render(self, c, app):
        entries = self.entries()
        if not entries:
            empty_state(c, "folder", "No captures saved yet",
                        "Save one from the aircraft list. It is kept in quartermaster/aircraft.")
            return
        self.clamp(len(entries), self.VISIBLE)
        c.text((11, TOP - 1), plural(len(entries), "capture"), font("bold", 7), FAINT)
        for line, entry in enumerate(entries[self.top:self.top + self.VISIBLE]):
            y = TOP + 10 + line * 17
            if self.top + line == self.index:
                c.select(y, 15)
            c.text((11, y + 2), when(entry["epoch"]), font("mono", 10), TEXT)
            c.text((124, y + 3), self.kinds(entry), font("mono", 9), MUTED)
            c.text_right(W - 12, y + 3, size_text(entry["size"]), font("mono", 9), MUTED)
        self.scrollbar(c, len(entries), self.VISIBLE, y0=TOP + 10)
        c.text((11, CONTENT_BOTTOM - 14), "Files: quartermaster/aircraft/" + entries[self.index]["stem"] + ".*",
               font("ui", 8), FAINT, width=W - 22)

    def delete(self, app, entry):
        gone = skyview.delete(entry)
        app.dirty = True
        app.toast("Capture deleted" if gone else "The capture could not be deleted", GOLD if gone else RED)

    def handle(self, key, app):
        entries = self.entries()
        self.clamp(len(entries), self.VISIBLE)
        if self.move(key, len(entries), self.VISIBLE):
            return True
        if key == "D" and entries and not key.repeat:
            entry = entries[self.index]
            app.confirm("Delete this capture?", "%s is removed from the device." % when(entry["epoch"]), "Delete",
                        lambda: self.delete(app, entry), danger=True)
            return True
        return super().handle(key, app)

