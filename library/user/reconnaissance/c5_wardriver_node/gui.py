#!/usr/bin/env python3
"""JCMK live dashboard for the C5 Wardriver Pager node."""
import argparse
import hashlib
import importlib.util
import json
import os
import signal
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
PAGERCTL_REV = "30ef1028500ba1d0303d24ea5d62497407bac77d"
PAGERCTL_PY_SHA256 = "57238e7720498d0de65504efcebc1a8f27f8c1b952ed3bbb718595006d951b08"
PAGERCTL_SO_SHA256 = "f0f5d3213c77e360fa4cf912c5a122d2dd1b39713ae2cdf7c6ba6dc7ead5e4e5"
PAGERCTL_PATH = os.path.join(ROOT, "lib", "active")
FONT_PATH = os.path.join(ROOT, "fonts", "Lato-Medium.ttf")
LOGO_PATH = os.path.join(ROOT, "jcmk_mark.png")
FONT_SIZES = {1: 11, 2: 18, 3: 25, 4: 33}

PSC = [5, 21, 37, 53, 69, 85, 101, 117, 133, 149, 165, 181, 197, 213, 229]


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def preflight():
    import ctypes  # noqa: F401 - proves the split OpenWrt package is complete.
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
        raise ImportError("bundled JCMK dashboard font is missing")
    if not os.path.isfile(LOGO_PATH):
        raise ImportError("JCMK splash mark is missing")
    spec = importlib.util.spec_from_file_location("jcmk_pagerctl", module_path)
    if spec is None or spec.loader is None:
        raise ImportError("payload-local pagerctl runtime cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Pager


def process_alive(pid):
    if pid <= 0:
        return False
    try:
        with open("/proc/%s/stat" % pid) as handle:
            # The command may contain spaces/parentheses; state follows the final ).
            state = handle.read().rsplit(")", 1)[1].strip().split(None, 1)[0]
        return state != "Z"
    except (OSError, IndexError):
        return False


def dashboard_status(st, age, node_alive):
    if not node_alive:
        return "NODE ERROR", "error"
    if age >= 8:
        return "STATS STALE", "warn"
    if st.get("core"):
        ack_age = st.get("ack_age_s")
        if ack_age is None or ack_age > 12:
            return "CORE UNVERIFIED", "warn"
        return "CORE LINKED", "ok"
    return "PAIRING", "warn"


def _number(value, ceiling=9999):
    try:
        value = int(value)
    except (TypeError, ValueError):
        value = 0
    if value > ceiling:
        return "%d+" % ceiling
    return str(max(0, value))


def _duration(seconds):
    seconds = max(0, int(seconds or 0))
    return "%02d:%02d:%02d" % (seconds // 3600, seconds // 60 % 60, seconds % 60)


def _text(p, x, y, value, color, scale=1):
    return p.draw_ttf(x, y, str(value), color, FONT_PATH, FONT_SIZES.get(scale, scale))


def draw_dashboard(p, st, age=0, node_alive=True, details=False, logo_handle=None):
    bg = p.rgb(4, 9, 15)
    panel = p.rgb(9, 20, 29)
    panel2 = p.rgb(13, 27, 38)
    grid = p.rgb(34, 51, 63)
    white = p.rgb(235, 244, 247)
    muted = p.rgb(128, 150, 164)
    cyan = p.rgb(0, 218, 235)
    magenta = p.rgb(236, 63, 164)
    green = p.rgb(102, 232, 156)
    amber = p.rgb(250, 195, 92)
    red = p.rgb(246, 91, 91)

    status, tone = dashboard_status(st, age, node_alive)
    status_color = green if tone == "ok" else red if tone == "error" else amber
    p.clear(bg)

    # Header
    if logo_handle is None:
        p.draw_image_file(10, 5, LOGO_PATH)
    else:
        p.draw_image(10, 5, logo_handle)
    _text(p, 48, 4, "JCMK  /  C5 NODE", white, 2)
    _text(p, 49, 25, "6 GHz WARDRIVE UPLINK", muted)
    pill_w = max(76, p.ttf_width(status, FONT_PATH, FONT_SIZES[1]) + 18)
    pill_x = 468 - pill_w
    p.fill_rect(pill_x, 8, pill_w, 24, panel2)
    p.fill_rect(pill_x, 8, 4, 24, status_color)
    _text(p, pill_x + 10, 16, status, status_color)
    if details:
        _draw_details(p, st, panel, panel2, grid, white, muted, cyan, magenta, green, amber, red)
    else:
        _draw_activity(p, st, panel, panel2, grid, white, muted, cyan, magenta, green, amber)

    # Distinct two-tab rail: D-pad switches pages; red B exits.
    tabs = ((14, 78, "OVERVIEW", not details, cyan),
            (98, 88, "TELEMETRY", details, magenta))
    for x, width, label, active, accent in tabs:
        p.fill_rect(x, 201, width, 17, panel2)
        if active:
            p.fill_rect(x, 201, 4, 17, accent)
        _text(p, x + 9, 204, label, white if active else muted)
    _text(p, 211, 204, "UP %s" % _duration(st.get("uptime_s")), muted)
    p.fill_rect(391, 201, 67, 17, p.rgb(52, 14, 22))
    p.fill_rect(391, 201, 4, 17, red)
    _text(p, 401, 204, "B  EXIT", white)


def _draw_activity(p, st, panel, panel2, grid, white, muted, cyan, magenta, green, amber):
    # Device metric and link health rail.
    p.fill_rect(12, 52, 120, 136, panel)
    _text(p, 22, 61, "DEVICES", muted)
    devices = _number(st.get("devices", st.get("seen", 0)))
    device_scale = 4
    if st.get("devices_capped"):
        devices += "+"
        device_scale = 3
    _text(p, 22, 78, devices, white, device_scale)
    _text(p, 22, 112, "DETECTED", cyan)
    _text(p, 22, 142, "CORE", muted)
    pair = st.get("paired_core") or st.get("core") or "--"
    pair = pair.upper().replace(":", "")
    _text(p, 22, 157, pair[-6:] if pair != "--" else "------", green if st.get("core") else amber, 2)
    _text(p, 22, 178, "ACK %s" % _number(st.get("acked", 0), 999), muted)

    # Rolling 6 GHz channel activity chart.
    p.fill_rect(142, 52, 326, 136, panel)
    _text(p, 152, 61, "CHANNEL ACTIVITY", muted)
    _text(p, 390, 61, "6 GHz PSC", cyan)
    values = st.get("channel_activity") or [0] * len(PSC)
    values = list(values)[:len(PSC)] + [0] * max(0, len(PSC) - len(values))
    peak = max([float(v or 0) for v in values] + [1.0])
    hottest = max(range(len(values)), key=lambda i: float(values[i] or 0)) if values else -1
    graph_y, graph_h = 82, 72
    for i, channel in enumerate(PSC):
        x = 153 + i * 20
        value = float(values[i] or 0)
        height = int((value / peak) * 66) if value else 2
        color = magenta if i == hottest and value else cyan
        p.fill_rect(x, graph_y + graph_h - height, 12, height, color)
        # The Pager bitmap font is six pixels wide; alternate labels avoid
        # collisions while retaining a clear scale across all 15 PSC bars.
        if i % 2 == 0 or i == len(PSC) - 1:
            label = str(channel)
            label_w = p.ttf_width(label, FONT_PATH, FONT_SIZES[1])
            _text(p, x + max(0, (12 - label_w) // 2), 160, label, muted)
    _text(p, 152, 177, "Q %s" % _number(st.get("queued", 0), 999), amber)
    _text(p, 210, 177, "TX %s" % _number(st.get("sent", 0), 9999), muted)
    _text(p, 284, 177, "DROP %s" % _number(st.get("dropped", 0), 999), muted)
    _text(p, 382, 177, "DEDUP %s" % _number(st.get("deduped", 0), 9999), muted)


def _draw_details(p, st, panel, panel2, grid, white, muted, cyan, magenta, green, amber, red):
    metrics = (
        ("SENT", st.get("sent", 0), cyan),
        ("ACKED", st.get("acked", 0), green),
        ("QUEUE", st.get("queued", 0), amber),
        ("DROP", st.get("dropped", 0), red),
    )
    for i, (label, value, color) in enumerate(metrics):
        x = 12 + i * 114
        p.fill_rect(x, 52, 104, 58, panel)
        _text(p, x + 9, 61, label, muted)
        _text(p, x + 9, 79, _number(value), color, 3)

    latest = st.get("latest") or {}
    p.fill_rect(12, 120, 456, 68, panel)
    _text(p, 22, 129, "LATEST NETWORK", muted)
    ssid = str(latest.get("ssid") or "--").replace("\n", "_").replace("\r", "_")[:18]
    _text(p, 22, 146, ssid, white, 2)
    bssid = str(latest.get("bssid") or "--").upper()
    _text(p, 22, 169, bssid, muted)
    _text(p, 250, 146, "CH %s" % latest.get("channel", "--"), magenta, 2)
    _text(p, 345, 146, "%s dBm" % latest.get("rssi", "--"), cyan, 2)
    ack_age = st.get("ack_age_s")
    _text(p, 250, 172, "ACK AGE %s" % ("--" if ack_age is None else "%ss" % ack_age), muted)
    _text(p, 370, 172, "SWEEP %s" % _number(st.get("sweeps", 0), 9999), muted)


def run(args):
    Pager = preflight()
    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    details = False
    with Pager() as p:
        p.set_rotation(270)
        p.clear_input_events()
        logo_handle = p.load_image(LOGO_PATH)
        if not logo_handle:
            raise RuntimeError("could not load JCMK splash mark")
        try:
            worker_dead_since = None
            while running:
                st = {}
                age = 999
                try:
                    with open(args.stats) as handle:
                        st = json.load(handle)
                    age = time.time() - os.path.getmtime(args.stats)
                except (OSError, ValueError):
                    pass
                node_alive = process_alive(args.node_pid)
                draw_dashboard(p, st, age, node_alive, details, logo_handle)
                p.flip()
                if not node_alive:
                    worker_dead_since = worker_dead_since or time.monotonic()
                    if time.monotonic() - worker_dead_since >= 1.0:
                        return 2
                else:
                    worker_dead_since = None
                until = time.monotonic() + 0.2
                while running and time.monotonic() < until:
                    _, pressed, _ = p.poll_input()
                    if pressed & Pager.BTN_B:
                        running = False
                    elif pressed & Pager.BTN_RIGHT:
                        details = True
                        p.clear_input_events()
                    elif pressed & Pager.BTN_LEFT:
                        details = False
                        p.clear_input_events()
                    time.sleep(0.02)
        finally:
            p.free_image(logo_handle)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--stats", default="/tmp/c5-pager-node.json")
    parser.add_argument("--node-pid", type=int, default=0)
    args = parser.parse_args(argv)
    if args.check:
        preflight()
        return 0
    result = run(args)
    return 0 if result is None else result


if __name__ == "__main__":
    raise SystemExit(main())
