#!/usr/bin/env python3
"""Full-screen Remote ID dashboard for the WiFi Pineapple Pager."""
import hashlib
import importlib.util
import json
import math
import os
import signal
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
PAGERCTL_REV = "30ef1028500ba1d0303d24ea5d62497407bac77d"
PAGERCTL_PY_SHA256 = "57238e7720498d0de65504efcebc1a8f27f8c1b952ed3bbb718595006d951b08"
PAGERCTL_SO_SHA256 = "f0f5d3213c77e360fa4cf912c5a122d2dd1b39713ae2cdf7c6ba6dc7ead5e4e5"
PAGERCTL_PATH = os.path.join(ROOT, "lib", "active")
FONT_PATH = os.path.join(ROOT, "fonts", "Lato-Medium.ttf")
FONT_SIZES = {1: 11, 2: 17, 3: 24, 4: 32}
MAP_RECT = (132, 43, 336, 142)
EARTH_M = 6371000.0


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def preflight():
    import ctypes  # noqa: F401 - verifies the split OpenWrt package.
    resolved = os.path.realpath(PAGERCTL_PATH)
    versions = os.path.realpath(os.path.join(ROOT, "lib", "versions")) + os.sep
    if not resolved.startswith(versions) or not os.path.basename(resolved).startswith(PAGERCTL_REV + "-"):
        raise ImportError("payload-local pagerctl active pointer is not pinned")
    module_path = os.path.join(PAGERCTL_PATH, "pagerctl.py")
    library_path = os.path.join(PAGERCTL_PATH, "libpagerctl.so")
    if not os.path.isfile(module_path) or not os.path.isfile(library_path):
        raise ImportError("exact payload-local pagerctl runtime is missing")
    if sha256_file(module_path) != PAGERCTL_PY_SHA256 or sha256_file(library_path) != PAGERCTL_SO_SHA256:
        raise ImportError("payload-local pagerctl runtime failed hash verification")
    if not os.path.isfile(FONT_PATH):
        raise ImportError("bundled dashboard font is missing")
    spec = importlib.util.spec_from_file_location("remote_id_pagerctl", module_path)
    if spec is None or spec.loader is None:
        raise ImportError("payload-local pagerctl runtime cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Pager


def _finite(value):
    try:
        value = float(value)
        return value if math.isfinite(value) else None
    except (TypeError, ValueError):
        return None


def valid_point(lat, lon):
    lat, lon = _finite(lat), _finite(lon)
    return lat is not None and lon is not None and -90 <= lat <= 90 and -180 <= lon <= 180 and (lat != 0 or lon != 0)


def record_point(record):
    if not isinstance(record, dict) or not record.get("has_location"):
        return None
    lat, lon = _finite(record.get("latitude_e7")), _finite(record.get("longitude_e7"))
    if lat is None or lon is None:
        return None
    lat, lon = lat / 1e7, lon / 1e7
    return (lat, lon) if valid_point(lat, lon) else None


def operator_point(record):
    if not isinstance(record, dict) or not record.get("has_operator_location"):
        return None
    lat, lon = _finite(record.get("operator_latitude_e7")), _finite(record.get("operator_longitude_e7"))
    if lat is None or lon is None:
        return None
    lat, lon = lat / 1e7, lon / 1e7
    return (lat, lon) if valid_point(lat, lon) else None


def gps_point(state):
    gps = state.get("gps") if isinstance(state, dict) else None
    if isinstance(gps, (list, tuple)) and len(gps) >= 2 and valid_point(gps[0], gps[1]):
        return float(gps[0]), float(gps[1])
    return None


def history_points(record):
    points = []
    if not isinstance(record, dict):
        return points
    for item in record.get("history", []) if isinstance(record.get("history", []), list) else []:
        if isinstance(item, dict) and valid_point(item.get("latitude"), item.get("longitude")):
            points.append((float(item["latitude"]), float(item["longitude"])))
    return points[-200:]


def collect_map_points(state):
    records = state.get("records", []) if isinstance(state, dict) else []
    records = records if isinstance(records, list) else []
    aircraft, operators, trails = [], [], []
    for record in records:
        point = record_point(record)
        operator = operator_point(record)
        trail = history_points(record)
        if point:
            aircraft.append(point)
        if operator:
            operators.append(operator)
        if trail:
            trails.append(trail)
    return aircraft, operators, trails, gps_point(state)


def map_projection(state, width=336, height=142):
    aircraft, operators, trails, pager = collect_map_points(state)
    points = aircraft + operators + [p for trail in trails for p in trail]
    if pager:
        origin = pager
        points.append(pager)
    elif points:
        origin = (sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points))
    else:
        origin = (0.0, 0.0)
    cosine = max(0.01, abs(math.cos(math.radians(origin[0]))))

    def metres(point):
        return (math.radians(point[1] - origin[1]) * EARTH_M * cosine,
                math.radians(point[0] - origin[0]) * EARTH_M)

    xy = [metres(point) for point in points]
    radius = max([50.0] + [max(abs(x), abs(y)) for x, y in xy]) * 1.08
    scale = min((width - 12) / (2 * radius), (height - 12) / (2 * radius))

    def project(point):
        x, y = metres(point)
        return (int(round(width / 2 + x * scale)), int(round(height / 2 - y * scale)))

    return {"origin": origin, "radius_m": radius, "project": project,
            "aircraft": aircraft, "operators": operators, "trails": trails, "pager": pager}


def censor_name(value):
    value = str(value or "")
    return value[:3] + "X" * max(0, len(value) - 3)


def censor_mac(value):
    parts = str(value or "").split(":")
    return ":".join(parts[:2] + ["XX"] * 4) if len(parts) == 6 else censor_name(value)


def identity(record, censor=False):
    value = record.get("uas_id") or record.get("description") or record.get("mac") or "Unknown"
    if not censor:
        return str(value)
    return censor_mac(value) if str(value).count(":") == 5 else censor_name(value)


def operator_id(record, censor=False):
    value = str(record.get("operator_id") or "Unknown")
    return censor_name(value) if censor else value


def records(state):
    value = state.get("records", []) if isinstance(state, dict) else []
    return [record for record in value if isinstance(record, dict)] if isinstance(value, list) else []


def operator_records(state):
    return [record for record in records(state) if record.get("operator_id") or operator_point(record)]


def page_count(state):
    return 1 + len(records(state)) + len(operator_records(state))


def record_key(record):
    return str(record.get("record_key") or record.get("uas_id") or record.get("mac") or "")


def page_token(state, page):
    recs, ops = records(state), operator_records(state)
    if 1 <= page <= len(recs):
        return "aircraft", record_key(recs[page - 1])
    op_index = page - 1 - len(recs)
    if 0 <= op_index < len(ops):
        return "operator", record_key(ops[op_index])
    return None


def page_for_token(state, token):
    if not token:
        return 0
    kind, key = token
    recs = records(state)
    source = recs if kind == "aircraft" else operator_records(state)
    for index, record in enumerate(source):
        if record_key(record) == key:
            return 1 + index if kind == "aircraft" else 1 + len(recs) + index
    return 0


def navigate(page, selected, button, state):
    count = page_count(state)
    aircraft_count = len(records(state))
    selected = min(max(0, selected), max(0, aircraft_count - 1))
    if button == "up":
        return 0, selected, False
    if button == "b":
        return page, selected, True
    if page == 0:
        if button == "left" and aircraft_count:
            selected = (selected - 1) % aircraft_count
        elif button == "right" and aircraft_count:
            selected = (selected + 1) % aircraft_count
        elif button == "down" and aircraft_count:
            page = 1 + selected
    elif button == "left" and count > 1:
        page = 1 + ((page - 2) % (count - 1))
    elif button == "right" and count > 1:
        page = 1 + (page % (count - 1))
    return page, selected, False


def _text(p, x, y, value, color, scale=1):
    value = str(value).replace("\n", " ").replace("\r", " ")
    return p.draw_ttf(x, y, value, color, FONT_PATH, FONT_SIZES.get(scale, scale))


def _distance(value):
    value = _finite(value)
    if value is None:
        return "--"
    return "%.0f m" % value if value < 1000 else "%.1f km" % (value / 1000)


def _measure(record, valid_key, value_key, suffix, decimals=1):
    value = _finite(record.get(value_key))
    if not record.get(valid_key) or value is None:
        return "--"
    return (("%." + str(decimals) + "f %s") % (value, suffix))


def _position(point, censor=False):
    if point is None:
        return "GPS unavailable"
    return "CENSORED" if censor else "%.6f, %.6f" % point


def gps_badge(state):
    status = state.get("gps_status") if isinstance(state, dict) else None
    if not isinstance(status, dict):
        return "GPS STATUS UNKNOWN", "amber"
    gps_state = status.get("state")
    satellites = status.get("satellites_tracked")
    suffix = " %s SAT" % satellites if isinstance(satellites, int) else ""
    if gps_state == "fix":
        return "GPS FIX" + suffix, "green"
    if gps_state == "searching":
        readiness = str(status.get("readiness") or "").lower()
        if "no signal" in readiness:
            return "GPS NO SIGNAL" + suffix, "red"
        if "weak" in readiness:
            return "GPS WEAK" + suffix, "amber"
        return "GPS SEARCH" + suffix, "amber"
    if gps_state == "not-detected":
        return "GPS NOT DETECTED", "red"
    return "GPS STATUS UNKNOWN", "amber"


def _colors(p):
    return {"bg": p.rgb(3, 8, 13), "panel": p.rgb(10, 23, 32), "grid": p.rgb(34, 54, 64),
            "white": p.rgb(235, 244, 247), "muted": p.rgb(124, 149, 162), "cyan": p.rgb(0, 220, 235),
            "magenta": p.rgb(238, 61, 164), "green": p.rgb(88, 235, 145), "red": p.rgb(246, 74, 82),
            "amber": p.rgb(249, 193, 78)}


def draw_map(p, state, colors, censor=False):
    x, y, width, height = MAP_RECT
    p.fill_rect(x, y, width, height, colors["panel"])
    p.rect(x, y, width, height, colors["grid"])
    p.hline(x, y + height // 2, width, colors["grid"])
    p.vline(x + width // 2, y, height, colors["grid"])
    label, color = gps_badge(state)
    _text(p, x + 170, y + 5, label, colors[color])
    if censor:
        _text(p, x + 92, y + 62, "POSITION CENSORED", colors["amber"], 2)
        return None
    projection = map_projection(state, width, height)
    project = projection["project"]
    for trail in projection["trails"]:
        previous = None
        for point in trail:
            px, py = project(point); current = (x + px, y + py)
            if previous:
                p.line(previous[0], previous[1], current[0], current[1], colors["red"])
            previous = current
    for point in projection["aircraft"]:
        px, py = project(point); p.fill_circle(x + px, y + py, 4, colors["cyan"])
    for point in projection["operators"]:
        px, py = project(point); p.fill_circle(x + px, y + py, 4, colors["magenta"])
    if projection["pager"]:
        px, py = project(projection["pager"]); p.fill_circle(x + px, y + py, 4, colors["green"])
    _text(p, x + 7, y + 5, "R %.0fm" % projection["radius_m"], colors["muted"])
    return projection


def draw_main(p, state, selected=0, censor=False):
    c = _colors(p); p.clear(c["bg"]); recs = records(state)
    active = state.get("active_count", sum(not r.get("is_lost") for r in recs))
    _text(p, 12, 5, "REMOTE ID / LIVE AIRSPACE", c["white"], 2)
    detected = state.get("detected_count", len(recs))
    _text(p, 12, 31, "TOTAL", c["muted"]); _text(p, 12, 47, detected, c["cyan"], 4)
    _text(p, 12, 86, "ACTIVE", c["muted"]); _text(p, 12, 102, active, c["green"], 4)
    draw_map(p, state, c, censor)
    if recs:
        selected = min(max(0, selected), len(recs) - 1)
        _text(p, 12, 151, "TARGET %d/%d" % (selected + 1, len(recs)), c["muted"])
        _text(p, 12, 167, identity(recs[selected], censor)[:16], c["white"], 2)
    else:
        _text(p, 12, 160, "NO TARGETS", c["muted"], 2)
    _footer(p, "LEFT/RIGHT SELECT   DOWN DETAILS   B EXIT", c)


def _footer(p, hint, c):
    p.fill_rect(0, 198, 480, 24, c["panel"]); p.hline(0, 198, 480, c["grid"]); _text(p, 12, 204, hint, c["white"])


def _field(p, x, y, label, value, c, accent=None):
    _text(p, x, y, label, c["muted"]); _text(p, x, y + 14, value, accent or c["white"], 2)


def draw_aircraft(p, record, index, total, censor=False):
    c = _colors(p); p.clear(c["bg"]); gps_fields = "distance_m" in record and "bearing_deg" in record
    _text(p, 12, 5, "AIRCRAFT %d/%d" % (index + 1, total), c["cyan"], 2)
    _text(p, 174, 5, identity(record, censor)[:27], c["white"], 2)
    _field(p, 12, 35, "TYPE / STATUS", "%s / %s" % (
        {0:"None",1:"Aeroplane",2:"Helicopter",3:"Gyroplane",4:"Hybrid Lift",5:"Ornithopter",6:"Glider",7:"Kite",8:"Balloon",9:"Captive",10:"Airship",11:"Parachute",12:"Rocket",13:"Tethered",14:"Ground",15:"Other"}.get(record.get("ua_type"), "Unknown"),
        {0:"Undeclared",1:"Ground",2:"Airborne",3:"Emergency",4:"RID failure"}.get(record.get("operational_status"), "Unknown")), c)
    _field(p, 12, 72, "RSSI / TRANSPORT / CH / AGE", "%s dBm  %s  %s  %ss" % (record.get("rssi", "--"), ",".join(record.get("transports", []))[:18], record.get("channel", "--"), record.get("last_seen_age_s", 0)), c)
    point = record_point(record); _field(p, 12, 109, "LOCATION", _position(point, censor), c)
    altitude = _measure(record, "geo_altitude_valid", "geo_altitude_m", "m")
    speed = _measure(record, "horizontal_speed_valid", "horizontal_speed_mps", "m/s")
    heading = _measure(record, "direction_valid", "direction_deg", "deg", 0)
    _field(p, 12, 146, "ALT / SPEED / HEADING", "%s  %s  %s" % (altitude, speed, heading), c)
    bearing = _finite(record.get("bearing_deg"))
    if censor:
        _field(p, 330, 109, "FROM PAGER", "CENSORED", c, c["amber"])
    elif gps_fields and bearing is not None and _finite(record.get("distance_m")) is not None:
        _field(p, 330, 109, "FROM PAGER", "%s / %.0f deg" % (_distance(record.get("distance_m")), bearing), c, c["green"])
    else:
        _field(p, 330, 109, "FROM PAGER", "GPS unavailable", c, c["amber"])
    _footer(p, "LEFT/RIGHT CAROUSEL   UP MAP   B EXIT", c)


def draw_operator(p, record, index, total, censor=False):
    c = _colors(p); p.clear(c["bg"]); point = operator_point(record)
    _text(p, 12, 5, "OPERATOR %d/%d" % (index + 1, total), c["magenta"], 2)
    _field(p, 12, 39, "OPERATOR ID", operator_id(record, censor)[:36], c)
    _field(p, 12, 82, "LOCATION", _position(point, censor), c)
    altitude = _measure(record, "operator_altitude_valid", "operator_altitude_geo_m", "m")
    _field(p, 12, 125, "ALTITUDE", altitude, c)
    operator_bearing = _finite(record.get("operator_bearing_deg"))
    if censor:
        _field(p, 245, 125, "FROM PAGER", "CENSORED", c, c["amber"])
    elif operator_bearing is not None and _finite(record.get("operator_distance_m")) is not None:
        _field(p, 245, 125, "FROM PAGER", "%s / %.0f deg" % (_distance(record.get("operator_distance_m")), operator_bearing), c, c["green"])
    else:
        _field(p, 245, 125, "FROM PAGER", "GPS unavailable", c, c["amber"])
    _footer(p, "LEFT/RIGHT CAROUSEL   UP MAP   B EXIT", c)


def draw_page(p, state, page=0, selected=0, censor=False):
    recs, ops = records(state), operator_records(state)
    if page <= 0 or page >= 1 + len(recs) + len(ops):
        draw_main(p, state, selected, censor)
    elif page <= len(recs):
        draw_aircraft(p, recs[page - 1], page - 1, len(recs), censor)
    else:
        op_index = page - 1 - len(recs); draw_operator(p, ops[op_index], op_index, len(ops), censor)


def process_alive(pid):
    try:
        with open("/proc/%d/stat" % pid) as handle:
            return handle.read().rsplit(")", 1)[1].strip().split(None, 1)[0] != "Z"
    except (OSError, IndexError):
        return False


def load_state(path):
    try:
        with open(path) as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def run(state_path, worker_pid, censor=False):
    Pager = preflight(); running = [True]
    def stop(*_): running[0] = False
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    page, selected, dead_since = 0, 0, None
    detail_token, selected_key = None, None
    with Pager() as p:
        p.set_rotation(270); p.clear_input_events()
        while running[0]:
            state = load_state(state_path)
            if detail_token:
                page = page_for_token(state, detail_token)
                if page == 0:
                    detail_token = None
            recs = records(state)
            if selected_key:
                for index, record in enumerate(recs):
                    if record_key(record) == selected_key:
                        selected = index
                        break
                else:
                    selected, selected_key = 0, None
            selected = min(selected, max(0, len(recs) - 1))
            draw_page(p, state, page, selected, censor); p.flip()
            alive = process_alive(worker_pid)
            dead_since = None if alive else (dead_since or time.monotonic())
            if dead_since and time.monotonic() - dead_since >= 1.0:
                return 2
            until = time.monotonic() + 0.2
            while running[0] and time.monotonic() < until:
                _, pressed, _ = p.poll_input(); button = None
                if pressed & Pager.BTN_B: button = "b"
                elif pressed & Pager.BTN_UP: button = "up"
                elif pressed & Pager.BTN_DOWN: button = "down"
                elif pressed & Pager.BTN_LEFT: button = "left"
                elif pressed & Pager.BTN_RIGHT: button = "right"
                if button:
                    page, selected, quit_now = navigate(page, selected, button, state)
                    detail_token = page_token(state, page)
                    recs = records(state)
                    selected_key = record_key(recs[selected]) if recs else None
                    p.clear_input_events()
                    if quit_now: running[0] = False
                time.sleep(0.02)


def main(argv=None):
    argv = list(argv if argv is not None else os.sys.argv[1:])
    if "--check" in argv:
        preflight(); return 0
    def option(name, default):
        return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else default
    result = run(option("--state", "/tmp/remote-id-radar.json"), int(option("--worker-pid", "0")), "--censor" in argv)
    return 0 if result is None else result


if __name__ == "__main__":
    raise SystemExit(main())
