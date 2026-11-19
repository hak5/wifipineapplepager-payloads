#!/usr/bin/env python3
import hashlib
import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import gui
import remote_id_monitor as rid


class FakePager:
    def __init__(self): self.calls = []
    @staticmethod
    def rgb(r, g, b): return (r, g, b)
    def _call(self, name, *args): self.calls.append((name, args))
    def clear(self, *args): self._call("clear", *args)
    def fill_rect(self, *args): self._call("fill_rect", *args)
    def rect(self, *args): self._call("rect", *args)
    def hline(self, *args): self._call("hline", *args)
    def vline(self, *args): self._call("vline", *args)
    def line(self, *args): self._call("line", *args)
    def fill_circle(self, *args): self._call("fill_circle", *args)
    def draw_ttf(self, x, y, text, color, font, size): self._call("text", x, y, str(text), color, size); return len(str(text))


def record(name="SERIAL-SECRET-123", lat=40.0, lon=-74.0):
    return {
        "uas_id": name, "mac": "8c:1e:d9:d1:cb:bc", "has_location": True,
        "latitude_e7": int(lat * 1e7), "longitude_e7": int(lon * 1e7),
        "has_operator_location": True, "operator_latitude_e7": int((lat + .0002) * 1e7),
        "operator_longitude_e7": int((lon + .0002) * 1e7), "operator_id": "OPERATOR-SECRET",
        "history": [{"latitude": lat - .0002, "longitude": lon - .0002}, {"latitude": lat, "longitude": lon}],
        "rssi": -52, "transports": ["wifi-beacon"], "channel": 6, "ua_type": 4,
        "operational_status": 2, "geo_altitude_valid": True, "geo_altitude_m": 101.5,
        "horizontal_speed_valid": True, "horizontal_speed_mps": 12.5,
        "direction_valid": True, "direction_deg": 88.0,
    }


class ProjectionTests(unittest.TestCase):
    def test_projection_uses_pager_origin_and_minimum_radius(self):
        state = {"gps": [40.0, -74.0], "records": [record(lat=40.0001)]}
        result = gui.map_projection(state)
        self.assertEqual(result["origin"], (40.0, -74.0))
        self.assertGreaterEqual(result["radius_m"], 50)
        self.assertEqual(result["project"]((40.0, -74.0)), (168, 71))

    def test_no_gps_derives_origin_and_omits_pager(self):
        state = {"gps": None, "records": [record()]}
        result = gui.map_projection(state)
        self.assertIsNone(result["pager"])
        self.assertNotEqual(result["origin"], (0.0, 0.0))
        pager = FakePager(); gui.draw_main(pager, state)
        green = pager.rgb(88, 235, 145)
        green_markers = [c for c in pager.calls if c[0] == "fill_circle" and c[1][-1] == green]
        self.assertEqual(green_markers, [])

    def test_trails_are_red_connected_segments(self):
        pager = FakePager(); gui.draw_main(pager, {"records": [record()]})
        red = pager.rgb(246, 74, 82)
        self.assertTrue(any(call[0] == "line" and call[1][-1] == red for call in pager.calls))

    def test_malformed_points_are_ignored(self):
        malformed = {"has_location": True, "latitude_e7": "bad", "longitude_e7": None,
                     "history": [None, {}, {"latitude": 999, "longitude": 1}]}
        state = {"gps": ["nan", 0], "records": [malformed, None]}
        result = gui.map_projection(state)
        self.assertEqual(result["aircraft"], [])
        self.assertEqual(result["trails"], [])
        self.assertIsNone(result["pager"])


class NavigationTests(unittest.TestCase):
    def setUp(self): self.state = {"records": [record("ONE"), record("TWO")]}
    def test_main_select_and_open(self):
        self.assertEqual(gui.navigate(0, 0, "right", self.state)[:2], (0, 1))
        self.assertEqual(gui.navigate(0, 1, "down", self.state)[:2], (2, 1))
    def test_carousel_wrap_up_and_exit(self):
        count = gui.page_count(self.state)
        self.assertEqual(gui.navigate(count - 1, 0, "right", self.state)[0], 1)
        self.assertEqual(gui.navigate(1, 0, "left", self.state)[0], count - 1)
        self.assertEqual(gui.navigate(2, 0, "up", self.state)[0], 0)
        self.assertTrue(gui.navigate(0, 0, "b", self.state)[2])

    def test_page_token_survives_record_reordering(self):
        for item in self.state["records"]:
            item["record_key"] = item["uas_id"]
        token = gui.page_token(self.state, 1)
        reordered = {"records": list(reversed(self.state["records"]))}
        page = gui.page_for_token(reordered, token)
        self.assertEqual(gui.page_token(reordered, page), token)


class RenderTests(unittest.TestCase):
    def texts(self, pager): return [args[2] for name, args in pager.calls if name == "text"]
    def test_aircraft_gps_and_no_gps_fields(self):
        with_gps = record(); with_gps.update(distance_m=123.4, bearing_deg=45.0)
        pager = FakePager(); gui.draw_aircraft(pager, with_gps, 0, 1)
        self.assertIn("123 m / 45 deg", self.texts(pager))
        pager = FakePager(); gui.draw_aircraft(pager, record(), 0, 1)
        self.assertIn("GPS unavailable", self.texts(pager))
        self.assertFalse(any("0 m / 0" in text for text in self.texts(pager)))

    def test_operator_distance_only_when_computable(self):
        item = record(); item.update(operator_distance_m=345.0, operator_bearing_deg=270.0)
        pager = FakePager(); gui.draw_operator(pager, item, 0, 1)
        self.assertIn("345 m / 270 deg", self.texts(pager))
        pager = FakePager(); gui.draw_operator(pager, record(), 0, 1)
        self.assertIn("GPS unavailable", self.texts(pager))

    def test_censor_never_leaks_identifiers_at_display_sink(self):
        state = {"records": [record()], "active_count": 1}
        for page in range(gui.page_count(state)):
            pager = FakePager(); gui.draw_page(pager, state, page, 0, censor=True)
            output = " ".join(self.texts(pager))
            self.assertNotIn("SERIAL-SECRET-123", output)
            self.assertNotIn("OPERATOR-SECRET", output)
            self.assertNotIn("8c:1e:d9:d1:cb:bc", output)
        self.assertEqual(gui.identity(state["records"][0], True), "SERXXXXXXXXXXXXXX")

    def test_malformed_state_loader_and_draw(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state"
            path.write_text("not json")
            self.assertEqual(gui.load_state(str(path)), {})
            path.write_text("[]")
            self.assertEqual(gui.load_state(str(path)), {})
        pager = FakePager(); gui.draw_page(pager, {"records": "bad"})
        self.assertIn("NO TARGETS", self.texts(pager))


class StateAndIntegrityTests(unittest.TestCase):
    def test_detected_count_survives_bounded_record_eviction(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(rid, "MAX_TRACKED_RECORDS", 2):
            root = Path(directory); monitor = rid.RemoteIdMonitor(root/"s", root/"e", root/"c", root/"g")
            for index in range(3):
                monitor.observe("00:00:00:00:00:%02X" % index, "Wi-Fi", -50, 6, {})
            snapshot = monitor.snapshot()
            self.assertEqual(snapshot["detected_count"], 3)
            self.assertEqual(len(snapshot["records"]), 2)

    def test_worker_operator_range_requires_gps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); monitor = rid.RemoteIdMonitor(root/"s", root/"e", root/"c", root/"g")
            item = record(); self.assertNotIn("operator_distance_m", monitor.public_record(item))
            monitor.gps = (40.0, -74.0); monitor.gps_updated = time.time()
            public = monitor.public_record(item)
            self.assertIn("distance_m", public); self.assertIn("operator_distance_m", public)
            self.assertGreater(public["operator_distance_m"], 0)

    def test_stale_gps_omits_pager_position_and_ranges(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); monitor = rid.RemoteIdMonitor(root/"s", root/"e", root/"c", root/"g")
            monitor.records["sample"] = record()
            monitor.gps = (40.0, -74.0)
            monitor.gps_updated = time.time() - rid.GPS_STALE_SECONDS - 1
            snapshot = monitor.snapshot()
            self.assertIsNone(snapshot["gps"])
            self.assertNotIn("distance_m", snapshot["records"][0])
            self.assertNotIn("operator_distance_m", snapshot["records"][0])

    def test_preflight_rejects_corrupt_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); version = root/"lib"/"versions"/(gui.PAGERCTL_REV + "-x"); version.mkdir(parents=True)
            (version/"pagerctl.py").write_text("bad"); (version/"libpagerctl.so").write_bytes(b"bad")
            (root/"lib"/"active").symlink_to(Path("versions")/version.name); (root/"font").write_bytes(b"font")
            with mock.patch.object(gui, "ROOT", str(root)), mock.patch.object(gui, "PAGERCTL_PATH", str(root/"lib"/"active")), mock.patch.object(gui, "FONT_PATH", str(root/"font")):
                with self.assertRaisesRegex(ImportError, "hash verification"):
                    gui.preflight()

    def test_assets_and_installer_are_pinned(self):
        root = Path(__file__).parent
        self.assertGreater((root/"fonts"/"Lato-Medium.ttf").stat().st_size, 600000)
        self.assertIn("Open Font License (OFL)", (root/"fonts"/"OFL-Lato.txt").read_text())
        installer = (root/"install_pagerctl.sh").read_text()
        self.assertIn(gui.PAGERCTL_REV, installer)
        self.assertIn(gui.PAGERCTL_PY_SHA256, installer)
        self.assertIn(gui.PAGERCTL_SO_SHA256, installer)

    def test_payload_lifecycle_contract(self):
        payload = Path(__file__).with_name("payload.sh")
        source = payload.read_text()
        for token in ("UI_TAKEOVER", "UI_RELEASE", "stop_pid", "kill -9", "wait", "confirmed", "bound_log", "--worker-pid", "--censor"):
            self.assertIn(token, source)
        self.assertIn('[ "$count" -lt 75 ]', source)
        self.assertNotIn(b"\0", payload.read_bytes())
        self.assertNotIn("pineap", source.lower())
        self.assertIn("--wifi-channel 6", source)

    def test_production_gui_keeps_python_light_imports(self):
        source = Path(gui.__file__).read_text()
        self.assertNotIn("pathlib", source)
        self.assertNotIn("subprocess", source)
        self.assertNotIn("threading", source)


if __name__ == "__main__": unittest.main()
