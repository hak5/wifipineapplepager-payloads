#!/usr/bin/env python3
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import remote_id_monitor as rid


def basic_id(name=b"USS-Enterprise"):
    message = bytearray(25)
    message[0] = 0x02
    message[1] = 0x14
    message[2:2 + len(name)] = name
    return bytes(message)


def location(latitude=407123456, longitude=-740123456):
    message = bytearray(25)
    message[0] = 0x12
    message[1] = 0x20
    message[2] = 90
    message[3] = 40
    message[4] = 0xFC
    struct.pack_into("<i", message, 5, latitude)
    struct.pack_into("<i", message, 9, longitude)
    struct.pack_into("<H", message, 13, 2200)
    struct.pack_into("<H", message, 15, 2300)
    struct.pack_into("<H", message, 17, 2100)
    message[19] = 0xA7
    message[20] = 0x04
    struct.pack_into("<H", message, 21, 1234)
    return bytes(message)


def message_pack(*messages):
    return bytes([0xF2, 25, len(messages)]) + b"".join(messages)


def beacon(payload=None, oui=rid.ASD_STAN_OUI):
    payload = payload or basic_id()
    frame = bytearray(36)
    frame[0] = 0x80
    frame[10:16] = b"\x02\x11\x22\x33\x44\x55"
    element = oui + bytes([0x0D, 7]) + payload
    frame.extend(bytes([221, len(element)]))
    frame.extend(element)
    return bytes(frame)


def nan_frame():
    frame = bytearray(44 + 25)
    frame[0] = 0xD0
    frame[4:10] = b"\x51\x6f\x9a\x01\x00\x00"
    frame[10:16] = b"\x02\xaa\xbb\xcc\xdd\xee"
    frame[24:30] = b"\x04\x09\x50\x6f\x9a\x13"
    frame[30] = 0x03
    frame[31] = 36
    frame[32] = 0
    frame[33:39] = b"\x88\x69\x19\x9d\x92\x09"
    frame[39] = 1
    frame[40] = 0
    frame[41] = 0x10
    frame[42] = 26
    frame[43] = 4
    frame[44:69] = basic_id()
    return bytes(frame)


def radiotap_packet(frame, rssi=-47, frequency=2412):
    present = (1 << 3) | (1 << 5)
    header = bytearray(struct.pack("<BBHI", 0, 0, 15, present))
    header.extend(struct.pack("<HH", frequency, 0x00A0))
    header.extend(struct.pack("b", rssi))
    header.extend(b"\x00\x00")
    return bytes(header) + frame


def pcap(packet):
    global_header = b"\xd4\xc3\xb2\xa1" + struct.pack("<HHIIII", 2, 4, 0, 0, 65535, 127)
    packet_header = struct.pack("<IIII", 1, 0, len(packet), len(packet))
    return global_header + packet_header + packet


class StartupCompatibilityTests(unittest.TestCase):
    def test_worker_self_check(self):
        self.assertEqual(rid.main(["--self-check"]), 0)

    def test_worker_self_check_subprocess_has_no_side_effects(self):
        worker = Path(__file__).with_name("remote_id_monitor.py")
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            result = subprocess.run(
                [sys.executable, "-B", str(worker), "--self-check"],
                cwd=directory, env=environment, capture_output=True, text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "")
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_launcher_uses_runtime_check_not_py_compile(self):
        launcher = Path(__file__).with_name("payload.sh").read_text()
        self.assertIn('"$PYTHON_BIN" -B "$WORKER" --self-check', launcher)
        self.assertIn("ImportError|ModuleNotFoundError|No module named", launcher)
        self.assertIn("remote-id-radar-startup.$$.log", launcher)
        self.assertIn("CONFIRMATION_DIALOG", launcher)
        self.assertIn("opkg -d mmc --force-reinstall install python3-light", launcher)
        self.assertIn("Requires internet and persistent storage changes", launcher)
        self.assertIn("/mmc/usr/bin", launcher)
        self.assertIn("LD_LIBRARY_PATH", launcher)
        self.assertIn('return 2', launcher)
        self.assertNotIn("python3 -m py_compile", launcher)
        self.assertNotIn("$(python3 ", launcher)
        self.assertNotIn("< <(python3 ", launcher)
        self.assertNotIn("\n  python3 ", launcher)


class DecoderTests(unittest.TestCase):
    def test_message_pack_fields(self):
        system = bytearray(25)
        system[0] = 0x42
        system[1] = 1
        struct.pack_into("<i", system, 2, 407000000)
        struct.pack_into("<i", system, 6, -740000000)
        struct.pack_into("<H", system, 10, 3)
        system[12] = 12
        struct.pack_into("<H", system, 13, 2400)
        struct.pack_into("<H", system, 15, 2200)
        system[17] = 0x21
        struct.pack_into("<H", system, 18, 2300)
        struct.pack_into("<I", system, 20, 987654)
        operator = bytearray(25)
        operator[0] = 0x52
        operator[2:13] = b"OPERATOR-42"
        decoded, record = rid.decode_payload(message_pack(basic_id(), location(), bytes(system), bytes(operator)))
        self.assertTrue(decoded)
        self.assertEqual(record["uas_id"], "USS-Enterprise")
        self.assertEqual(record["id_type"], 1)
        self.assertEqual(record["ua_type"], 4)
        self.assertEqual(record["latitude_e7"], 407123456)
        self.assertEqual(record["longitude_e7"], -740123456)
        self.assertAlmostEqual(record["horizontal_speed_mps"], 10.0)
        self.assertAlmostEqual(record["vertical_speed_mps"], -2.0)
        self.assertAlmostEqual(record["geo_altitude_m"], 150.0)
        self.assertEqual(record["horizontal_accuracy"], 7)
        self.assertEqual(record["vertical_accuracy"], 10)
        self.assertEqual(record["operator_id"], "OPERATOR-42")
        self.assertEqual(record["area_radius_m"], 120)

    def test_wifi_beacon_and_legacy_oui(self):
        for oui in (rid.ASD_STAN_OUI, rid.LEGACY_REMOTE_ID_OUI):
            decoded, record = rid.decode_wifi_beacon(beacon(oui=oui))
            self.assertTrue(decoded)
            self.assertEqual(record["uas_id"], "USS-Enterprise")

    def test_ble_counter_is_skipped(self):
        service_data = b"\xfa\xff\x0d\x09" + location()
        decoded, record = rid.decode_ble_service_data(service_data)
        self.assertTrue(decoded)
        self.assertEqual(record["latitude_e7"], 407123456)
        self.assertEqual(record["longitude_e7"], -740123456)

    def test_ble_rejects_other_application_code(self):
        decoded, _ = rid.decode_ble_service_data(b"\xfa\xff\x01\x09" + location())
        self.assertFalse(decoded)

    def test_nan_action_frame(self):
        decoded, record = rid.decode_wifi_nan(nan_frame())
        self.assertTrue(decoded)
        self.assertEqual(record["uas_id"], "USS-Enterprise")

    def test_truncation_and_sentinels(self):
        with self.assertRaises(rid.DecodeError):
            rid.decode_payload(b"\xf2\x19\x02\x02")
        malformed_beacon = bytearray(b"\x80" + b"\x00" * 37)
        malformed_beacon[36] = 221
        malformed_beacon[37] = 20
        with self.assertRaises(rid.DecodeError):
            rid.decode_wifi_beacon(bytes(malformed_beacon))
        decoded, record = rid.decode_message(location(latitude=900000001))
        self.assertTrue(decoded)
        self.assertFalse(record["has_location"])

    def test_radiotap_metadata(self):
        frame, rssi, channel = rid.parse_radiotap(radiotap_packet(beacon()))
        self.assertEqual(frame, beacon())
        self.assertEqual(rssi, -47)
        self.assertEqual(channel, 1)

    def test_interface_channel_parser(self):
        output = "Interface wlan1mon\n\ttype monitor\n\tchannel 6 (2437 MHz), width: 20 MHz\n"
        self.assertEqual(rid.parse_interface_channel(output), 6)
        self.assertIsNone(rid.parse_interface_channel("Interface wlan1mon\n\ttype monitor\n"))

    def test_iw_uses_absolute_stock_path_when_available(self):
        if Path("/usr/sbin/iw").exists():
            self.assertEqual(rid.IW_COMMAND, "/usr/sbin/iw")

    def test_pcap_reader(self):
        packet = radiotap_packet(beacon())
        reader = rid.PcapReader(io.BytesIO(pcap(packet)))
        self.assertEqual(list(reader), [packet])

    def test_blue5_status_le_ready_formats(self):
        ready = (
            "Scan mode: LE + Classic\nLE scanning: enabled\n",
            "scanner active=1 classic=1 le=1 coded=0",
            "LE scan enabled: yes",
            "blue5 status\nlescan 1",
            '{"scanner":{"le_scan":true,"classic":true}}',
        )
        for output in ready:
            with self.subTest(output=output):
                self.assertEqual(rid.classify_blue5_status(output), rid.BLUE5_LE_READY)

    def test_blue5_status_classic_only_or_not_scanning(self):
        unavailable = (
            "BT Scan Mode: Classic only",
            "LE scanning: disabled\nClassic scanning: enabled",
            "blue5 status\nlescan 0",
            "scan_le=0",
            '{"scan":{"le":false,"classic":true}}',
        )
        for output in unavailable:
            with self.subTest(output=output):
                self.assertEqual(rid.classify_blue5_status(output), rid.BLUE5_LE_UNAVAILABLE)

    def test_blue5_status_unavailable_is_not_assumed_ready(self):
        for output in ("", "blue5 status: unknown", "adapter hci0"):
            with self.subTest(output=output):
                self.assertEqual(rid.classify_blue5_status(output), rid.BLUE5_STATUS_UNAVAILABLE)
        with mock.patch.object(rid.subprocess, "run", side_effect=FileNotFoundError):
            status, detail = rid.blue5_le_status()
        self.assertEqual(status, rid.BLUE5_STATUS_UNAVAILABLE)
        self.assertIn("not installed", detail)

    def test_blue5_status_distinguishes_absent_daemon(self):
        self.assertEqual(
            rid.classify_blue5_status('{"le":true,"daemon_running":false}'),
            rid.BLUE5_PROCESS_ABSENT,
        )
        result = mock.Mock(returncode=1, stdout="failed to connect: blue5 is not running")
        with mock.patch.object(rid.subprocess, "run", return_value=result) as run:
            status, _ = rid.blue5_le_status()
        self.assertEqual(status, rid.BLUE5_PROCESS_ABSENT)
        run.assert_called_once_with(
            ["blue5ctl", "status"], stdout=rid.subprocess.PIPE,
            stderr=rid.subprocess.STDOUT, text=True, timeout=3, check=False,
        )

    def test_pineap_gps_status_detects_searching_hardware_and_fix(self):
        searching = rid.parse_pineap_gps_status(
            "Fix=0 Location=0,0 Protocol=nmea Baud=9600 / "
            "Readiness=no signal SatsTracked=0 SatsStrong=0 SignalQuality=0%")
        self.assertEqual(searching["state"], "searching")
        self.assertTrue(searching["detected"])
        self.assertEqual(searching["readiness"], "no signal")
        fixed = rid.parse_pineap_gps_status(
            "Fix=1 / Location=38.1234,-77.5678 / Protocol=nmea / Baud=9600 / "
            "Readiness=ready / SatsTracked=9 / SatsStrong=7 / SignalQuality=80%")
        self.assertEqual(fixed["state"], "fix")
        self.assertEqual(fixed["point"], (38.1234, -77.5678))
        self.assertEqual(rid.parse_pineap_gps_status("unexpected successful response")["state"],
                         "unavailable")
        command = mock.Mock(returncode=1, stdout=(
            "Fix=0 Location=0,0 Protocol=nmea Baud=9600\n"
            "Readiness=no signal SatsTracked=0 SatsStrong=0 SignalQuality=0%"))
        with mock.patch.object(rid.subprocess, "run", return_value=command):
            live = rid.pineap_gps_status()
        self.assertEqual(live["state"], "searching")
        self.assertTrue(live["detected"])

    def test_pager_active_timeout_matches_marauder(self):
        self.assertEqual(rid.LOST_AFTER_SECONDS, 30)

    def test_btmon_extended_report(self):
        service = b"\xfa\xff\x0d\x09" + basic_id()
        ad = bytes([len(service) + 1, 0x16]) + service
        hex_lines = []
        for offset in range(0, len(ad), 16):
            chunk = ad[offset:offset + 16]
            hex_lines.append("        " + " ".join(f"{byte:02x}" for byte in chunk) + "  ........\n")
        text = [
            "      LE Extended Advertising Report (0x0d)\n",
            "        Num reports: 1\n",
            "        Entry 0\n",
            "          Data status: Complete\n",
            "          Address: 11:22:33:44:55:66 (Random)\n",
            "          RSSI: -61 dBm (0xc3)\n",
            f"          Data length: 0x{len(ad):02x}\n",
            *hex_lines,
            "        Service Data: Unknown (0xfffa)\n",
        ]
        reports = list(rid.iter_btmon_reports(text))
        self.assertEqual(reports, [("11:22:33:44:55:66", -61, ad)])
        service_records = rid.parse_advertising_data(reports[0][2])
        decoded, record = rid.decode_ble_service_data(service_records[0])
        self.assertTrue(decoded)
        self.assertEqual(record["uas_id"], "USS-Enterprise")

    def test_hci_legacy_advertisement(self):
        service = b"\xfa\xff\x0d\x09" + basic_id()
        ad = bytes([len(service) + 1, 0x16]) + service
        address = b"\x66\x55\x44\x33\x22\x11"
        report = bytes([0x02, 1, 0, 0]) + address + bytes([len(ad)]) + ad + struct.pack("b", -55)
        packet = bytes([0x04, 0x3E, len(report)]) + report
        parsed = rid.parse_hci_event(packet)
        self.assertEqual(parsed, [("11:22:33:44:55:66", -55, service)])
        decoded, record = rid.decode_ble_service_data(parsed[0][2])
        self.assertTrue(decoded)
        self.assertEqual(record["uas_id"], "USS-Enterprise")

    def test_btmon_rejects_unrelated_and_incomplete_data(self):
        unrelated = [
            "Address: 11:22:33:44:55:66\n",
            "RSSI: -40 dBm\n",
            "Data length: 0x02\n",
            "aa bb\n",
        ]
        self.assertEqual(list(rid.iter_btmon_reports(unrelated)), [])
        incomplete = [
            "LE Extended Advertising Report (0x0d)\n",
            "Entry 0\n",
            "Data status: Incomplete, more data to come\n",
            "Address: 11:22:33:44:55:66\n",
            "RSSI: -40 dBm\n",
            "Data length: 0x02\n",
            "aa bb\n",
        ]
        self.assertEqual(list(rid.iter_btmon_reports(incomplete)), [])

    def test_merge_preserves_serial_and_valid_location(self):
        record = {
            "uas_id": "SERIAL-1", "id_type": 1, "ua_type": 4,
            "has_location": True, "latitude_e7": 400000000,
            "longitude_e7": -740000000, "operator_id": "OP-1",
        }
        rid.merge_decoded_record(record, {
            "uas_id": "CAA-LOWER", "id_type": 2, "ua_type": 2,
            "has_location": False, "latitude_e7": 0, "longitude_e7": 0,
            "operator_id": "",
        })
        self.assertEqual(record["uas_id"], "SERIAL-1")
        self.assertEqual(record["id_type"], 1)
        self.assertTrue(record["has_location"])
        self.assertEqual(record["latitude_e7"], 400000000)
        self.assertEqual(record["operator_id"], "OP-1")

    def test_monitor_merges_transports_by_uas_id(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            monitor = rid.RemoteIdMonitor(root / "state", root / "events", root / "events.csv", root / "points.gpx")
            monitor.observe("02:11:22:33:44:55", rid.TRANSPORT_WIFI_BEACON, -50, 6, {"uas_id": "DRONE-1"})
            monitor.observe("aa:bb:cc:dd:ee:ff", rid.TRANSPORT_BLE, -60, 0, {"uas_id": "DRONE-1"})
            snapshot = monitor.snapshot()
            self.assertEqual(len(snapshot["records"]), 1)
            self.assertEqual(set(snapshot["records"][0]["transports"]), {rid.TRANSPORT_WIFI_BEACON, rid.TRANSPORT_BLE})

    def test_render_empty_and_detail(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            state.write_text(json.dumps({"status": "scanning", "started": 1, "frames": 10, "decoded": 0, "records": []}))
            self.assertIn("Scanning", rid.render_state(state))
            self.assertEqual(rid.list_state(state), ["No Remote ID devices"])
            state.write_text(json.dumps({
                "status": "degraded", "started": 1, "frames": 10,
                "decoded": 0, "records": [],
                "capture_errors": ["BLE unavailable: blue5 LE scanning is disabled; scanning Wi-Fi only"],
            }))
            rendered = rid.render_state(state)
            self.assertIn("Scanning Wi-Fi only; BLE unavailable.", rendered)
            self.assertNotIn("Scanning Wi-Fi + Bluetooth", rendered)

    def test_censor_matches_marauder_identifier_rules(self):
        self.assertEqual(rid.censor_identifier("1581FBLKC263C00B145X"), "158XXXXXXXXXXXXXXXXX")
        self.assertEqual(rid.censor_identifier("8c:1e:d9:d1:cb:bc"), "8c:1e:XX:XX:XX:XX")
        self.assertEqual(rid.censor_identifier("ABC"), "ABC")

    def test_censor_setting_persists_and_masks_ui_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = root / "settings.json"
            state = root / "state.json"
            rid.save_censor_setting(settings, True)
            self.assertTrue(rid.load_censor_setting(settings))
            record = {
                "uas_id": "1581FBLKC263C00B145X",
                "operator_id": "OPERATOR-123",
                "mac": "8c:1e:d9:d1:cb:bc",
                "transports": ["wifi-beacon"],
                "last_seen": 10,
                "has_location": True,
                "latitude_e7": 400000000,
                "longitude_e7": -740000000,
                "has_operator_location": True,
                "operator_latitude_e7": 400001000,
                "operator_longitude_e7": -740001000,
            }
            state.write_text(json.dumps({"status": "stopped", "started": 1, "records": [record]}))
            rendered = rid.render_state(state, censor=True)
            detail = rid.detail_state(state, 0, censor=True)
            self.assertIn("158XXXXXXXXXXXXXXXXX", rendered)
            self.assertNotIn(record["uas_id"], rendered)
            self.assertIn("MAC: 8c:1e:XX:XX:XX:XX", detail)
            self.assertIn("Operator: OPEXXXXXXXXX", detail)
            self.assertNotIn("40.", detail)
            self.assertIn("[censored]", detail)
            censored_state = dict(record, distance_m=123.0, bearing_deg=45.0)
            state.write_text(json.dumps({"status": "scanning", "started": 1,
                                         "records": [censored_state]}))
            self.assertNotIn("123m", rid.render_state(state, censor=True))
            self.assertEqual(json.loads(state.read_text())["records"][0]["uas_id"], record["uas_id"])
            rid.save_censor_setting(settings, False)
            self.assertFalse(rid.load_censor_setting(settings))

    def test_censor_masks_description_fallback_and_note(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            record = {
                "description": "DroneAlpha",
                "mac": "8c:1e:d9:d1:cb:bc",
                "transports": ["wifi-beacon"],
                "last_seen": 10,
            }
            state.write_text(json.dumps({"status": "stopped", "started": 1, "records": [record]}))
            detail = rid.detail_state(state, 0, censor=True)
            self.assertIn("DroXXXXXXX", detail)
            self.assertNotIn("DroneAlpha", detail)


if __name__ == "__main__":
    unittest.main()
