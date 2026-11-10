#!/usr/bin/env python3
"""Unit tests for VENUS.

Run from the repository root:

    python3 -m unittest discover -s venus/tests -v

These tests never touch a radio or a real network device. Anything that would
run iw/hostapd/aireplay-ng is mocked, so they are safe on a development host.
"""

import argparse
import copy
import http.client
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

import pager_ui  # noqa: E402
import venus  # noqa: E402


# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #

STATION_DUMP = """\
Station 3c:22:fb:1a:2b:3c (on wlan1)
\tconnected time: 42 seconds
\tinactive time: 120 ms
\trx bytes: 18342
\ttx bytes: 90211
\tsignal: -48 [-52, -44] dBm
\tsignal avg: -49 dBm
\ttx bitrate: 433.3 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2
Station 24:6f:28:aa:bb:cc (on wlan1)
\tconnected time: 7 seconds
\trx bytes: 120
\ttx bytes: 480
\tsignal: -71 [-75, -68] dBm
"""

SCAN_OUTPUT = """\
BSS aa:bb:cc:11:22:33 (on wlan0)
\tfreq: 2437
\tsignal: -41.00 dBm
\tcapability: ESS ShortSlotTime (0x0401)
\tSSID: Cafe_Guest
\tDS Parameter set: channel 6
BSS aa:bb:cc:44:55:66 (on wlan0)
\tfreq: 5180
\tsignal: -57.00 dBm
\tcapability: ESS Privacy SpectrumMgmt (0x0511)
\tSSID: Corp-WiFi
\tRSN:
\t\t* Version: 1
\t\t* Group cipher: CCMP
\t\t* Authentication suites: PSK SAE
\tDS Parameter set: channel 36
BSS aa:bb:cc:77:88:99 (on wlan0)
\tfreq: 2462
\tsignal: -66.00 dBm
\tcapability: ESS Privacy (0x0411)
\tSSID: HomeNet
\tWPA:
\t\t* Version: 1
\tDS Parameter set: channel 11
BSS aa:bb:cc:dd:ee:ff (on wlan0)
\tfreq: 6135
\tsignal: -72.00 dBm
\tcapability: ESS (0x0401)
\tSSID: SixthGen
\tDS Parameter set: channel 37
"""


def make_args(tmp, **overrides):
    base = dict(
        loot=os.path.join(tmp, "loot"),
        state=os.path.join(tmp, "state.json"),
        cmd=os.path.join(tmp, "cmd.jsonl"),
        ap_ip="192.168.69.1",
        http_port=80,
        portal_dir=os.path.join(ROOT, "portal"),
        portal_title="Sign in to Wi-Fi",
        capture=True,
        password="",
        country="US",
        no_portal=True,
        lure=False,
        no_lure=False,
        no_guard=False,
        iface=None,
        recon_iface=None,
        scan_interval=6.0,
        lure_interval=8.0,
        oui_file="",
        duration=0,
    )
    base.update(overrides)
    return argparse.Namespace(**base)


# --------------------------------------------------------------------------- #
# Parsers and pure helpers
# --------------------------------------------------------------------------- #

class ParserTests(unittest.TestCase):
    def test_station_dump(self):
        s = venus.parse_station_dump(STATION_DUMP)
        self.assertEqual(len(s), 2)
        apple = s["3c:22:fb:1a:2b:3c"]
        self.assertEqual(apple["rssi"], -48)
        self.assertEqual(apple["rx_bytes"], 18342)
        self.assertEqual(apple["tx_bytes"], 90211)
        self.assertEqual(apple["connected_time"], 42)
        self.assertEqual(apple["inactive_time"], 120)
        self.assertEqual(s["24:6f:28:aa:bb:cc"]["rssi"], -71)

    def test_station_dump_empty_and_garbage(self):
        self.assertEqual(venus.parse_station_dump(""), {})
        self.assertEqual(venus.parse_station_dump("no stations here"), {})

    def test_leases(self):
        txt = (
            "1700000000 3c:22:fb:1a:2b:3c 192.168.69.10 iPhone-7 01:3c:22:fb\n"
            "1700000000 24:6f:28:aa:bb:cc 192.168.69.11 * *\n"
            "not a lease line\n"
        )
        leases = venus.parse_leases(txt)
        self.assertEqual(leases["3c:22:fb:1a:2b:3c"]["ip"], "192.168.69.10")
        self.assertEqual(leases["3c:22:fb:1a:2b:3c"]["hostname"], "iPhone-7")
        self.assertEqual(leases["24:6f:28:aa:bb:cc"]["hostname"], "")
        self.assertNotIn("not", leases)

    def test_arp(self):
        txt = (
            "IP address       HW type     Flags       HW address            Mask     Device\n"
            "192.168.69.10    0x1         0x2         3c:22:fb:1a:2b:3c     *        wlan1\n"
            "192.168.69.11    0x1         0x0         00:00:00:00:00:00     *        wlan1\n"
        )
        arp = venus.parse_arp(txt)
        self.assertEqual(arp, {"3c:22:fb:1a:2b:3c": "192.168.69.10"})

    def test_scan_parses_bands_and_security(self):
        aps = venus.parse_iw_scan(SCAN_OUTPUT)
        self.assertEqual(len(aps), 4)
        by_ssid = {a["ssid"]: a for a in aps}
        self.assertEqual(by_ssid["Cafe_Guest"]["enc"], "OPN")
        self.assertEqual(by_ssid["Cafe_Guest"]["band"], "2.4")
        self.assertEqual(by_ssid["Cafe_Guest"]["channel"], 6)
        self.assertEqual(by_ssid["Corp-WiFi"]["enc"], "WPA3")
        self.assertEqual(by_ssid["Corp-WiFi"]["band"], "5")
        self.assertEqual(by_ssid["HomeNet"]["enc"], "WPA")
        self.assertEqual(by_ssid["SixthGen"]["band"], "6")
        self.assertEqual(by_ssid["SixthGen"]["channel"], 37)
        for ap in aps:
            self.assertNotIn("_flags", ap)

    def test_scan_empty(self):
        self.assertEqual(venus.parse_iw_scan(""), [])

    def test_channel_derivation(self):
        self.assertEqual(venus.channel_from_scan({"channel": 6}), 6)
        self.assertEqual(venus.channel_from_scan({"channel": 0, "freq": 2437}), 6)
        self.assertEqual(venus.channel_from_scan({"channel": 0, "freq": 2484}), 14)
        self.assertEqual(venus.channel_from_scan({"channel": 0, "freq": 5180}), 36)
        self.assertEqual(venus.channel_from_scan({"channel": 0, "freq": 6135}), 37)
        self.assertEqual(venus.channel_from_scan({}, fallback=11), 11)

    def test_band_derivation(self):
        self.assertEqual(venus.band_for_freq(2437), "2.4")
        self.assertEqual(venus.band_for_freq(5180), "5")
        self.assertEqual(venus.band_for_freq(6135), "6")
        self.assertEqual(venus.band_for_freq("bad"), "2.4")

    def test_iface_band_support(self):
        dev = ("phy#0\n\tInterface wlan0\n\t\ttype managed\n"
               "phy#1\n\tInterface wlan1\n\t\ttype managed\n")
        phy0 = ("Wiphy phy0\n\tBand 1:\n\t\tFrequencies:\n"
                "\t\t\t* 2412 MHz [1] (20.0 dBm)\n"
                "\t\t\t* 5180 MHz [36] (20.0 dBm)\n")
        phy1 = ("Wiphy phy1\n\tBand 1:\n\t\tFrequencies:\n"
                "\t\t\t* 2412 MHz [1] (20.0 dBm)\n")

        def fake_run(cmd, timeout=20, **kw):
            if cmd[:2] == ["iw", "dev"]:
                return subprocess.CompletedProcess(cmd, 0, dev, "")
            if cmd[:3] == ["iw", "phy", "phy0"]:
                return subprocess.CompletedProcess(cmd, 0, phy0, "")
            if cmd[:3] == ["iw", "phy", "phy1"]:
                return subprocess.CompletedProcess(cmd, 0, phy1, "")
            return subprocess.CompletedProcess(cmd, 1, "", "no")

        with mock.patch.object(venus, "run", side_effect=fake_run):
            self.assertEqual(venus.iface_band_support("wlan0"), {"2.4", "5"})
            self.assertEqual(venus.iface_band_support("wlan1"), {"2.4"})
            self.assertIsNone(venus.iface_band_support("wlan9"))

    def test_mac_flags(self):
        self.assertTrue(venus.is_random_mac("da:a1:19:44:55:66"))
        self.assertFalse(venus.is_random_mac("3c:22:fb:1a:2b:3c"))
        self.assertTrue(venus.is_multicast_mac("ff:ff:ff:ff:ff:ff"))
        self.assertFalse(venus.is_multicast_mac("3c:22:fb:1a:2b:3c"))

    def test_vendor_lookup(self):
        self.assertEqual(venus.vendor_for_mac("3c:22:fb:1a:2b:3c"), "Apple")
        self.assertEqual(venus.vendor_for_mac("24:6f:28:aa:bb:cc"), "Espressif")
        self.assertEqual(venus.vendor_for_mac("da:a1:19:44:55:66"),
                         "Private (randomized)")
        self.assertEqual(venus.vendor_for_mac("ff:ff:ff:ff:ff:ff"), "Unknown")
        self.assertEqual(venus.vendor_for_mac("00:11:99:dd:ee:ff"), "Unknown")
        self.assertEqual(venus.vendor_for_mac(""), "Unknown")

    def test_external_oui_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("001122 (hex) Test Vendor One\n")
            f.write("00-11-33   (hex)\t\tTest Vendor Two\n")
            path = f.name
        try:
            self.assertEqual(venus.vendor_for_mac("00:11:22:00:00:00", path),
                             "Test Vendor One")
            self.assertEqual(venus.vendor_for_mac("00:11:33:00:00:00", path),
                             "Test Vendor Two")
        finally:
            os.unlink(path)

    def test_html_escape(self):
        self.assertEqual(venus._html_escape("<x>&\"'"),
                         "&lt;x&gt;&amp;&quot;'")

    def test_hms_and_truncate(self):
        self.assertEqual(pager_ui._hms(0), "00:00")
        self.assertEqual(pager_ui._hms(65), "01:05")
        self.assertEqual(pager_ui._hms(3661), "1:01:01")
        self.assertEqual(pager_ui._truncate("abcdef", 4), "ab..")
        self.assertEqual(pager_ui._truncate("abc", 4), "abc")

    def test_rssi_bars(self):
        self.assertEqual(pager_ui.rssi_bars(-40), 4)
        self.assertEqual(pager_ui.rssi_bars(-60), 3)
        self.assertEqual(pager_ui.rssi_bars(-70), 2)
        self.assertEqual(pager_ui.rssi_bars(-80), 1)
        self.assertEqual(pager_ui.rssi_bars(-95), 0)
        self.assertEqual(pager_ui.rssi_bars(None), 0)

    def test_fly_geometry_is_stable_and_in_bounds(self):
        a1, r1 = pager_ui.fly_geometry("3c:22:fb:1a:2b:3c", 84)
        a2, r2 = pager_ui.fly_geometry("3c:22:fb:1a:2b:3c", 84)
        self.assertEqual((a1, r1), (a2, r2))
        self.assertGreaterEqual(r1, 84 * 0.30)
        self.assertLessEqual(r1, 84 * 0.92)
        self.assertGreaterEqual(a1, 0)
        self.assertLessEqual(a1, 2 * 3.141592653589793)


# --------------------------------------------------------------------------- #
# Config builders and DNS
# --------------------------------------------------------------------------- #

class ConfigTests(unittest.TestCase):
    def test_hostapd_open_24(self):
        conf = venus.build_hostapd_conf("wlan1", "Cafe_Guest", 6, 2437)
        self.assertIn("interface=wlan1", conf)
        self.assertIn("ssid=Cafe_Guest", conf)
        self.assertIn("hw_mode=g", conf)
        self.assertIn("channel=6", conf)
        self.assertIn("ieee80211n=1", conf)
        self.assertNotIn("wpa=2", conf)

    def test_hostapd_wpa2_5ghz(self):
        conf = venus.build_hostapd_conf("wlan1", "Corp", 36, 5180,
                                        password="hunter22")
        self.assertIn("hw_mode=a", conf)
        self.assertIn("channel=36", conf)
        self.assertIn("ieee80211ac=1", conf)
        self.assertIn("wpa=2", conf)
        self.assertIn("wpa_passphrase=hunter22", conf)

    def test_hostapd_6ghz(self):
        conf = venus.build_hostapd_conf("wlan2", "Sixth", 37, 6135)
        self.assertIn("hw_mode=a", conf)
        self.assertIn("ieee80211ax=1", conf)
        self.assertIn("op_class=131", conf)

    def test_short_password_is_not_applied(self):
        conf = venus.build_hostapd_conf("wlan1", "x", 1, 2412, password="short")
        self.assertNotIn("wpa=2", conf)

    def test_hostapd_minimal_drops_optional_ht(self):
        conf = venus.build_hostapd_conf("venus0", "Corp", 36, 5180, minimal=True)
        self.assertIn("hw_mode=a", conf)
        self.assertIn("channel=36", conf)
        self.assertNotIn("ieee80211ac=1", conf)
        self.assertNotIn("ieee80211n=1", conf)
        conf2 = venus.build_hostapd_conf("venus0", "x", 6, 2437, minimal=True)
        self.assertNotIn("ieee80211n=1", conf2)

    def test_dnsmasq_wildcard(self):
        conf = venus.build_dnsmasq_conf("wlan1", "192.168.69.1",
                                        "/tmp/l", "/tmp/p")
        self.assertIn("interface=wlan1", conf)
        self.assertIn("bind-interfaces", conf)
        self.assertIn("dhcp-range=192.168.69.10,192.168.69.100,12h", conf)
        self.assertIn("address=/#/192.168.69.1", conf)
        self.assertIn("dhcp-option=3,192.168.69.1", conf)
        self.assertIn("dhcp-leasefile=/tmp/l", conf)

    def test_dnsmasq_dhcp_only(self):
        conf = venus.build_dnsmasq_conf("wlan1", "192.168.69.1",
                                        "/tmp/l", "/tmp/p", dns=False)
        self.assertIn("port=0", conf)
        self.assertNotIn("address=/#/", conf)

    def test_dns_a_response(self):
        query = (b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
                 b"\x07example\x03com\x00\x00\x01\x00\x01")
        resp = venus.build_dns_response(query, "192.168.69.1")
        self.assertIsNotNone(resp)
        self.assertEqual(resp[:2], b"\x12\x34")
        self.assertEqual(resp[2:4], b"\x81\x80")
        self.assertEqual(resp[6:8], b"\x00\x01")     # one answer
        self.assertEqual(resp[-4:], socket.inet_aton("192.168.69.1"))

    def test_dns_non_a_response_has_no_answer(self):
        query = (b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
                 b"\x07example\x03com\x00\x00\x1c\x00\x01")  # AAAA
        resp = venus.build_dns_response(query, "192.168.69.1")
        self.assertIsNotNone(resp)
        self.assertEqual(resp[6:8], b"\x00\x00")

    def test_dns_ignores_responses_and_short_packets(self):
        self.assertIsNone(venus.build_dns_response(b"", "1.2.3.4"))
        self.assertIsNone(venus.build_dns_response(b"\x00" * 8, "1.2.3.4"))
        query = (b"\x12\x34\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00"
                 b"\x01a\x00\x00\x01\x00\x01")
        self.assertIsNone(venus.build_dns_response(query, "1.2.3.4"))

    def test_parse_form_decodes_percent_and_plus(self):
        body = (b"email=test%40example.com&password=hunter%2Btwo"
                b"&empty=&flag")
        fields = venus._parse_form(body)
        self.assertEqual(fields["email"], "test@example.com")
        self.assertEqual(fields["password"], "hunter+two")
        self.assertEqual(fields["empty"], "")
        self.assertEqual(fields["flag"], "")
        self.assertEqual(venus._parse_form(b""), {})

    def test_unquote_handles_bad_escapes(self):
        self.assertEqual(venus._unquote("%41%42"), "AB")
        self.assertEqual(venus._unquote("a+b"), "a b")
        # A stray '%' is preserved rather than raising.
        self.assertIn("%", venus._unquote("%zz"))


# --------------------------------------------------------------------------- #
# DHCP responder (pure, no sockets)
# --------------------------------------------------------------------------- #

class DHCPTests(unittest.TestCase):
    @staticmethod
    def _discover(mac=b"\xaa\xbb\xcc\x00\x00\x01", xid=b"\x11\x22\x33\x44"):
        header = (bytes([1, 1, 6, 0]) + xid + struct.pack("!HH", 0, 0)
                  + b"\x00" * 4 + b"\x00" * 4 + b"\x00" * 8 + mac
                  + b"\x00" * 10 + b"\x00" * 64 + b"\x00" * 128
                  + venus.DHCP_MAGIC)
        opts = (venus._dhcp_option(53, 1)
                + venus._dhcp_option(55, b"\x01\x03\x06\x0c") + b"\xff")
        return header + opts

    def test_parse_discover(self):
        req = venus.parse_dhcp_packet(self._discover())
        self.assertIsNotNone(req)
        self.assertEqual(req["type"], 1)
        self.assertEqual(req["mac"], "aa:bb:cc:00:00:01")
        self.assertEqual(req["xid"], b"\x11\x22\x33\x44")
        self.assertNotIn(50, req["options"])

    def test_parse_rejects_non_dhcp(self):
        self.assertIsNone(venus.parse_dhcp_packet(b""))
        self.assertIsNone(venus.parse_dhcp_packet(b"\x00" * 240))
        # Wrong magic
        bad = bytearray(self._discover())
        bad[236:240] = b"\x00\x00\x00\x00"
        self.assertIsNone(venus.parse_dhcp_packet(bytes(bad)))
        # op == 2 (server->client) is rejected
        server = bytearray(self._discover())
        server[0] = 2
        self.assertIsNone(venus.parse_dhcp_packet(bytes(server)))

    def test_offer_reply_round_trip(self):
        req = venus.parse_dhcp_packet(self._discover())
        reply = venus.build_dhcp_reply(req, 2, "192.168.69.10", "192.168.69.1")
        self.assertEqual(reply[0], 2)
        self.assertEqual(socket.inet_ntoa(reply[16:20]), "192.168.69.10")
        self.assertEqual(reply[236:240], venus.DHCP_MAGIC)
        # server identifier option is present
        self.assertIn(b"\x36\x04", reply)  # option 54, len 4
        self.assertIn(socket.inet_aton("192.168.69.1"), reply)

    def test_ack_includes_router_and_dns(self):
        req = venus.parse_dhcp_packet(self._discover())
        reply = venus.build_dhcp_reply(req, 5, "192.168.69.10", "192.168.69.1")
        self.assertIn(socket.inet_aton("255.255.255.0"), reply)  # netmask
        self.assertIn(socket.inet_aton("192.168.69.1"), reply)

    def test_udp_ip_frame_checksums(self):
        req = venus.parse_dhcp_packet(self._discover())
        reply = venus.build_dhcp_reply(req, 2, "192.168.69.10", "192.168.69.1")
        frame = venus.build_udp_ip_frame(
            "02:00:00:00:00:01", "ff:ff:ff:ff:ff:ff",
            "192.168.69.1", "255.255.255.255", 67, 68, reply)
        self.assertEqual(frame[12:14], struct.pack("!H", venus.ETH_P_IP))
        ip = frame[14:]
        self.assertEqual(venus._checksum(ip[:20]), 0)
        udp = ip[(ip[0] & 0x0f) * 4:]
        sport, dport, ulen, _ = struct.unpack("!HHHH", udp[:8])
        self.assertEqual((sport, dport), (67, 68))
        self.assertEqual(ulen, 8 + len(reply))

    def test_lease_pool_and_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "leases")
            r = venus.DHCPResponder("venus0", "192.168.69.1", path)
            t = time.time()
            self.assertEqual(r.allocate("aa:bb:cc:00:00:01", t),
                             "192.168.69.10")
            self.assertEqual(r.allocate("aa:bb:cc:00:00:01", t),
                             "192.168.69.10")  # stable offer
            self.assertEqual(r.allocate("aa:bb:cc:00:00:02", t),
                             "192.168.69.11")
            self.assertFalse(r._available("192.168.69.10",
                                          "aa:bb:cc:00:00:02", t))
            r.commit("aa:bb:cc:00:00:01", "192.168.69.10", "phone", t)
            r.flush_leases()
            with open(path) as f:
                line = f.read().splitlines()[0]
            self.assertIn("aa:bb:cc:00:00:01", line)
            self.assertIn("192.168.69.10", line)
            self.assertIn("phone", line)


# --------------------------------------------------------------------------- #
# Engine
# --------------------------------------------------------------------------- #

class EngineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.args = make_args(self.tmp.name)
        self.engine = venus.Engine(self.args)

    def tearDown(self):
        self.tmp.cleanup()

    def test_ensure_paths_creates_loot_and_cmd(self):
        self.engine.ensure_paths()
        self.assertTrue(os.path.isdir(self.args.loot))
        self.assertTrue(os.path.isdir(os.path.join(self.args.loot, "captures")))
        self.assertTrue(os.path.exists(self.args.cmd))
        self.assertEqual(self.engine.cmd_offset, 0)

    def test_snapshot_shape(self):
        self.engine.ensure_paths()
        self.engine.ap_iface = "wlan1"
        self.engine.recon_iface = "wlan0"
        self.engine.leasefile = "/tmp/venus_leases"
        snap = self.engine.snapshot()
        for key in ("version", "ts", "uptime", "phase", "ssid", "channel",
                    "bssid", "ap_iface", "recon_iface", "ap_ip", "http_port",
                    "password", "portal", "lure", "lure_available", "aps",
                    "clients", "events", "counts", "error"):
            self.assertIn(key, snap)
        self.assertEqual(snap["phase"], "recon")
        self.assertTrue(snap["lure_available"])
        self.assertFalse(snap["lure"])

    def test_lure_available_respects_no_lure(self):
        args = make_args(self.tmp.name, no_lure=True)
        eng = venus.Engine(args)
        self.assertFalse(eng.snapshot()["lure_available"])

    def test_no_lure_ignores_lure_command(self):
        args = make_args(self.tmp.name, no_lure=True)
        eng = venus.Engine(args)
        eng.ensure_paths()
        with open(args.cmd, "a") as f:
            f.write('{"cmd":"lure","on":true}\n')
        eng.read_commands()
        self.assertFalse(eng.lure)

    def test_atomic_state_roundtrip(self):
        self.engine.ensure_paths()
        self.engine.write_state()
        with open(self.args.state) as f:
            snap = json.load(f)
        self.assertEqual(snap["version"], venus.STATE_VERSION)
        self.assertEqual(snap["phase"], "recon")
        self.assertFalse(os.path.exists(self.args.state + ".tmp"))

    def test_command_file_offset_ignores_stale_lines(self):
        self.engine.ensure_paths()
        with open(self.args.cmd, "w") as f:
            f.write('{"cmd":"quit"}\n')      # stale, before offset
        self.engine.cmd_offset = os.path.getsize(self.args.cmd)
        with open(self.args.cmd, "a") as f:
            f.write('{"cmd":"lure","on":true}\n')
        self.engine.read_commands()
        self.assertTrue(self.engine.lure)
        self.assertTrue(self.engine.running)

    def test_quit_command(self):
        self.engine.ensure_paths()
        with open(self.args.cmd, "a") as f:
            f.write('{"cmd":"quit"}\n')
        self.engine.read_commands()
        self.assertFalse(self.engine.running)

    def test_trap_without_ssid_is_rejected_without_hardware(self):
        self.engine.ensure_paths()
        with open(self.args.cmd, "a") as f:
            f.write(json.dumps({"cmd": "trap", "ap": {"ssid": ""}}) + "\n")
        self.engine.read_commands()
        self.assertEqual(self.engine.phase, "recon")
        self.assertIn("hidden", (self.engine.last_error or "").lower())

    def test_clear_command(self):
        self.engine.clients["3c:22:fb:1a:2b:3c"] = {"mac": "3c:22:fb:1a:2b:3c",
                                                   "first_seen": 1}
        self.engine.events.append({"x": 1})
        self.engine.handle_command({"cmd": "clear"})
        self.assertEqual(self.engine.clients, {})
        self.assertEqual(len(self.engine.events), 1)  # the new INFO event

    def test_rescan_command_calls_scan(self):
        with mock.patch.object(self.engine, "scan_once") as scan:
            self.engine.handle_command({"cmd": "rescan"})
            scan.assert_called_once_with()

    def test_ap_runtime_iface_prefers_vif(self):
        self.engine.ap_iface = "wlan1"
        self.assertEqual(self.engine.ap_runtime_iface(), "wlan1")
        self.engine.ap = mock.Mock()
        self.engine.ap.ap_iface = "venus0"
        self.assertEqual(self.engine.ap_runtime_iface(), "venus0")

    def test_create_ap_vif_uses_hidden_type(self):
        calls = []

        def fake_run(cmd, timeout=20, **kw):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with mock.patch.object(venus, "phy_for_iface", return_value="phy0"), \
                mock.patch.object(venus, "delete_vif"), \
                mock.patch.object(venus, "iface_exists", return_value=True), \
                mock.patch.object(venus, "run", side_effect=fake_run):
            ok, name = venus.create_ap_vif("wlan1", "venus0")
        self.assertTrue(ok)
        self.assertEqual(name, "venus0")
        self.assertIn(["iw", "phy", "phy0", "interface", "add", "venus0",
                       "type", "__ap"], calls)

    def test_rogueap_falls_back_to_base_radio(self):
        def fake_run(cmd, timeout=20, **kw):
            if cmd[:2] == ["iw", "phy"] and "interface" in cmd:
                return subprocess.CompletedProcess(cmd, 1, "", "no space")
            if cmd[:2] == ["iw", "dev"] and "info" in cmd:
                return subprocess.CompletedProcess(cmd, 0, "type managed", "")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        rogue = venus.RogueAP(self.engine, "wlan1", "Net", 6, 2437)
        with mock.patch.object(venus, "phy_for_iface", return_value="phy0"), \
                mock.patch.object(venus, "iface_exists", return_value=False), \
                mock.patch.object(venus, "run", side_effect=fake_run):
            rogue._prepare_interface()
        self.assertEqual(rogue.mode, "base")
        self.assertEqual(rogue.ap_iface, "wlan1")
        self.assertEqual(rogue.orig_type, "managed")

    def test_tick_clients_uses_runtime_ap_iface(self):
        self.engine.ensure_paths()
        self.engine.ap = mock.Mock()
        self.engine.ap.ap_iface = "venus0"
        self.engine.ap_iface = "wlan1"
        seen = []

        def fake_run(cmd, timeout=20, **kw):
            seen.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with mock.patch.object(venus, "run", side_effect=fake_run), \
                mock.patch.object(venus, "read_text", return_value=""):
            self.engine.tick_clients()
        self.assertIn(["iw", "dev", "venus0", "station", "dump"], seen)

    def test_phy_is_busy_uplink(self):
        with mock.patch.object(venus, "default_route_iface",
                               return_value="wlan0cli"), \
                mock.patch.object(venus, "phy_interfaces",
                                  return_value=["wlan0", "wlan0cli", "wlan0mon"]), \
                mock.patch.object(venus, "iface_is_up", return_value=False):
            self.assertTrue(venus.phy_is_busy("phy0"))

    def test_phy_is_busy_firmware_ap(self):
        with mock.patch.object(venus, "default_route_iface", return_value=None), \
                mock.patch.object(venus, "phy_interfaces",
                                  return_value=["wlan0", "wlan0mgmt"]), \
                mock.patch.object(venus, "iface_is_up", return_value=True):
            self.assertTrue(venus.phy_is_busy("phy0"))

    def test_phy_is_not_busy_idle_radio(self):
        with mock.patch.object(venus, "default_route_iface", return_value=None), \
                mock.patch.object(venus, "phy_interfaces",
                                  return_value=["wlan0", "wlan0mon"]), \
                mock.patch.object(venus, "iface_is_up", return_value=False):
            self.assertFalse(venus.phy_is_busy("phy0"))

    def test_safe_ap_radio_prefers_idle_radio(self):
        self.engine.ap_iface = "wlan0"
        with mock.patch.object(self.engine, "_base_radios",
                               return_value=["wlan0", "wlan1", "wlan2"]), \
                mock.patch.object(self.engine, "_band_ok", return_value=True), \
                mock.patch.object(venus, "phy_for_iface",
                                  side_effect=lambda i: "phy0" if i == "wlan0"
                                  else "phy1"), \
                mock.patch.object(venus, "phy_is_busy",
                                  side_effect=lambda p: p == "phy0"):
            self.assertEqual(self.engine._safe_ap_radio("2.4"), "wlan1")

    def test_safe_ap_radio_refuses_when_all_busy(self):
        self.engine.ap_iface = "wlan0"
        with mock.patch.object(self.engine, "_base_radios",
                               return_value=["wlan0", "wlan1"]), \
                mock.patch.object(self.engine, "_band_ok", return_value=True), \
                mock.patch.object(venus, "phy_for_iface", return_value="phy0"), \
                mock.patch.object(venus, "phy_is_busy", return_value=True):
            self.assertIsNone(self.engine._safe_ap_radio("2.4"))

    def test_safe_ap_radio_no_guard_returns_busy_radio(self):
        self.engine.args.no_guard = True
        self.engine.ap_iface = "wlan0"
        with mock.patch.object(self.engine, "_base_radios",
                               return_value=["wlan0", "wlan1"]), \
                mock.patch.object(self.engine, "_band_ok", return_value=True), \
                mock.patch.object(venus, "phy_for_iface", return_value="phy0"), \
                mock.patch.object(venus, "phy_is_busy", return_value=True):
            self.assertEqual(self.engine._safe_ap_radio("2.4"), "wlan0")

    def test_mac_for_ip_uses_clients_then_arp(self):
        self.engine.clients["3c:22:fb:1a:2b:3c"] = {
            "mac": "3c:22:fb:1a:2b:3c", "ip": "192.168.69.10"}
        self.engine.arp_map["24:6f:28:aa:bb:cc"] = "192.168.69.11"
        self.assertEqual(self.engine.mac_for_ip("192.168.69.10"),
                         "3c:22:fb:1a:2b:3c")
        self.assertEqual(self.engine.mac_for_ip("192.168.69.11"),
                         "24:6f:28:aa:bb:cc")
        self.assertIsNone(self.engine.mac_for_ip("10.0.0.1"))

    def test_portal_page_substitution_and_fallback(self):
        self.engine.ensure_paths()
        self.engine.trap_ap = {"ssid": 'Cafe <Guest>'}
        body = self.engine.portal_page("index")
        self.assertIn("Cafe &lt;Guest&gt;", body)
        self.assertIn("Sign in to Wi-Fi", body)
        self.assertNotIn("{{SSID}}", body)
        success = self.engine.portal_page("success")
        self.assertIn("connected", success.lower())

        missing = make_args(self.tmp.name, portal_dir="/nonexistent")
        eng2 = venus.Engine(missing)
        eng2.trap_ap = {"ssid": "FallbackNet"}
        self.assertIn("FallbackNet", eng2.portal_page("index"))
        self.assertNotIn("{{SSID}}", eng2.portal_page("index"))

    def test_tick_clients_merges_station_and_lease(self):
        self.engine.ensure_paths()
        self.engine.ap = object()
        self.engine.ap_iface = "wlan1"
        leases = ("9999999999 3c:22:fb:1a:2b:3c 192.168.69.10 phone *\n")
        arp = ("IP address       HW type     Flags       HW address            Mask     Device\n"
               "192.168.69.10    0x1         0x2         3c:22:fb:1a:2b:3c     *        wlan1\n")

        def fake_read(path, limit=65536):
            if path == self.engine.leasefile:
                return leases
            if path == "/proc/net/arp":
                return arp
            return ""

        fake = subprocess.CompletedProcess(["iw"], 0, STATION_DUMP, "")
        with mock.patch.object(venus, "run", return_value=fake), \
                mock.patch.object(venus, "read_text", side_effect=fake_read):
            self.engine.tick_clients()

        self.assertEqual(len(self.engine.clients), 2)
        apple = self.engine.clients["3c:22:fb:1a:2b:3c"]
        self.assertEqual(apple["vendor"], "Apple")
        self.assertEqual(apple["ip"], "192.168.69.10")
        self.assertEqual(apple["hostname"], "phone")
        self.assertEqual(apple["rssi"], -48)
        self.assertTrue(apple["active"])
        self.assertEqual(self.engine.counts["clients"], 2)
        iot = self.engine.clients["24:6f:28:aa:bb:cc"]
        self.assertEqual(iot["vendor"], "Espressif")
        self.assertEqual(iot["rssi"], -71)

    def test_client_goes_inactive_when_station_disappears(self):
        self.engine.ensure_paths()
        self.engine.ap = object()
        self.engine.ap_iface = "wlan1"
        now = [1000.0]
        empty = subprocess.CompletedProcess(["iw"], 0, "", "")
        with mock.patch.object(venus, "now", side_effect=lambda: now[0]), \
                mock.patch.object(venus, "run", return_value=empty), \
                mock.patch.object(venus, "read_text", return_value=""):
            self.engine.tick_clients()
            self.engine.clients["3c:22:fb:1a:2b:3c"] = {
                "mac": "3c:22:fb:1a:2b:3c", "ip": "", "hostname": "",
                "vendor": "Apple", "random_mac": False, "rssi": -50,
                "first_seen": 900.0, "last_seen": 900.0, "connected_time": 0,
                "inactive_time": None, "rx_bytes": 0, "tx_bytes": 0,
                "portal_hits": 0, "active": True}
            now[0] = 1020.0
            self.engine.tick_clients()
        self.assertFalse(self.engine.clients["3c:22:fb:1a:2b:3c"]["active"])

    def test_portal_accounting_attaches_mac(self):
        self.engine.clients["3c:22:fb:1a:2b:3c"] = {
            "mac": "3c:22:fb:1a:2b:3c", "ip": "192.168.69.10",
            "portal_hits": 0}
        self.engine.note_portal("192.168.69.10", "GET", "/", "ua")
        self.assertEqual(self.engine.counts["portal_hits"], 1)
        self.assertEqual(self.engine.clients["3c:22:fb:1a:2b:3c"]["portal_hits"], 1)

    def test_submission_written_with_redaction(self):
        args = make_args(self.tmp.name, capture=False)
        eng = venus.Engine(args)
        eng.ensure_paths()
        eng.note_submission(
            "192.168.69.10", "/submit", "ua",
            {"email": "a@b", "password": "secret"}, b"x")
        path = os.path.join(args.loot, "portal_submissions.jsonl")
        with open(path) as f:
            rec = json.loads(f.readline())
        self.assertEqual(rec["fields"]["email"], "[redacted]")
        self.assertEqual(rec["fields"]["password"], "[redacted]")
        self.assertEqual(eng.counts["submissions"], 1)

    def test_submission_written_in_clear_when_capture_enabled(self):
        self.engine.ensure_paths()
        self.engine.note_submission(
            "192.168.69.10", "/submit", "ua",
            {"email": "a@b", "password": "secret"}, b"x")
        path = os.path.join(self.args.loot, "portal_submissions.jsonl")
        with open(path) as f:
            rec = json.loads(f.readline())
        self.assertEqual(rec["fields"]["password"], "secret")


# --------------------------------------------------------------------------- #
# Live portal (loopback only)
# --------------------------------------------------------------------------- #

class PortalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.args = make_args(self.tmp.name)
        self.engine = venus.Engine(self.args)
        self.engine.ensure_paths()
        self.engine.trap_ap = {"ssid": "TestNet", "channel": 6}
        self.engine.ap_ip = "127.0.0.1"
        self.engine.ap_iface = "lo"
        self.engine.http_port = self._free_port()
        self.server = venus.PortalServer(self.engine, "127.0.0.1",
                                         self.engine.http_port)
        self.assertTrue(self.server.start())

    def tearDown(self):
        self.server.stop()
        self.tmp.cleanup()

    @staticmethod
    def _free_port():
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def _request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.engine.http_port,
                                          timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read()
        status = resp.status
        hdrs = dict(resp.getheaders())
        conn.close()
        return status, hdrs, data

    def test_index_renders_cloned_ssid(self):
        status, hdrs, body = self._request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(b"TestNet", body)
        self.assertEqual(self.engine.counts["portal_hits"], 1)

    def test_success_page(self):
        status, _, body = self._request("GET", "/success")
        self.assertEqual(status, 200)
        self.assertIn(b"connected", body.lower())

    def test_captive_probe_redirects(self):
        for path in ("/generate_204", "/hotspot-detect.html",
                     "/connecttest.txt", "/ncsi.txt"):
            status, hdrs, _ = self._request("GET", path)
            self.assertEqual(status, 302, path)
            self.assertEqual(hdrs.get("Location"), "http://127.0.0.1/")

    def test_form_post_is_captured(self):
        body = "email=test%40example.com&password=hunter2"
        status, _, page = self._request(
            "POST", "/submit", body,
            {"Content-Type": "application/x-www-form-urlencoded",
             "Content-Length": str(len(body))})
        self.assertEqual(status, 200)
        self.assertIn(b"connected", page.lower())
        path = os.path.join(self.args.loot, "portal_submissions.jsonl")
        with open(path) as f:
            rec = json.loads(f.readline())
        self.assertEqual(rec["fields"]["email"], "test@example.com")
        self.assertEqual(rec["fields"]["password"], "hunter2")
        self.assertEqual(rec["path"], "/submit")


# --------------------------------------------------------------------------- #
# UI logic (headless pager)
# --------------------------------------------------------------------------- #

class UITests(unittest.TestCase):
    def setUp(self):
        self.p = pager_ui.FakePager()
        self.ui = pager_ui.VenusUI(self.p)
        self.ui.state = copy.deepcopy(pager_ui.SAMPLE)
        self.ui.phase_prev = "trap"

    def test_sample_trap_draws(self):
        self.ui.screen = "trap"
        self.ui.draw()
        self.assertEqual(self.p.frames, 1)
        self.assertGreater(self.p.calls, 20)

    def test_sample_recon_draws(self):
        self.ui.state["phase"] = "recon"
        self.ui.screen = "recon"
        self.ui.draw()
        self.assertEqual(self.p.frames, 1)
        self.assertGreater(self.p.calls, 10)

    def test_empty_web_draws(self):
        self.ui.screen = "trap"
        self.ui.state["clients"] = []
        self.ui.state["counts"] = {"clients": 0, "portal_hits": 0,
                                   "submissions": 0}
        self.ui.draw()
        self.assertEqual(self.p.frames, 1)

    def test_waiting_engine_draws(self):
        self.ui.state = None
        self.ui.waiting_engine = True
        self.ui.draw()
        self.assertEqual(self.p.frames, 1)

    def test_stale_trap_heartbeat_shows_waiting(self):
        st = copy.deepcopy(pager_ui.SAMPLE)
        st["phase"] = "trap"
        st["ts"] = time.time() - 30
        with mock.patch.object(pager_ui, "load_state", return_value=st):
            self.ui.sync()
        self.assertTrue(self.ui.waiting_engine)

    def test_fresh_trap_heartbeat_keeps_state(self):
        st = copy.deepcopy(pager_ui.SAMPLE)
        st["phase"] = "trap"
        st["ts"] = time.time()
        with mock.patch.object(pager_ui, "load_state", return_value=st):
            self.ui.sync()
        self.assertFalse(self.ui.waiting_engine)
        self.assertEqual(self.ui.state["phase"], "trap")

    def test_stale_recon_heartbeat_is_tolerated(self):
        # A recon scan can block the engine for many seconds.
        st = copy.deepcopy(pager_ui.SAMPLE)
        st["phase"] = "recon"
        st["ts"] = time.time() - 30
        with mock.patch.object(pager_ui, "load_state", return_value=st):
            self.ui.sync()
        self.assertFalse(self.ui.waiting_engine)

    def test_arming_rollback_returns_to_recon(self):
        self.ui.screen = "trap"
        self.ui.on_phase_change("recon", "arming")
        self.assertEqual(self.ui.screen, "trap")
        self.ui.on_phase_change("arming", "recon")
        self.assertEqual(self.ui.screen, "recon")

    def test_phase_change_to_trap_sets_screen(self):
        self.ui.state["phase"] = "trap"
        self.ui.screen = "recon"
        self.ui.on_phase_change("recon", "trap")
        self.assertEqual(self.ui.screen, "trap")
        self.assertTrue(self.ui.baselined)
        self.assertIn("3c:22:fb:1a:2b:3c", self.ui.known_macs)

    def test_new_client_triggers_catch_flash(self):
        self.ui.screen = "trap"
        self.ui.baselined = True
        self.ui.known_macs = {"3c:22:fb:1a:2b:3c"}
        self.ui.state["clients"].append({
            "mac": "f0:18:98:4d:5e:6f", "ip": "192.168.69.12",
            "hostname": "MacBook", "vendor": "Apple", "random_mac": False,
            "rssi": -51, "first_seen": 0, "last_seen": 0, "active": True,
            "portal_hits": 0})
        with mock.patch.object(pager_ui, "load_state",
                               return_value=self.ui.state):
            self.ui.sync()
        self.assertGreater(self.ui.catch_until, time.time())
        self.assertIn("f0:18:98:4d:5e:6f", self.ui.known_macs)

    def test_start_trap_sends_command(self):
        with mock.patch.object(pager_ui, "send_cmd") as send:
            self.ui.start_trap()
            send.assert_called_once()
            cmd = send.call_args[0][0]
            self.assertEqual(cmd["cmd"], "trap")
            self.assertEqual(cmd["ap"]["ssid"], "Cafe_Guest")
        self.assertEqual(self.ui.screen, "trap")

    def test_start_trap_skips_hidden_ssid(self):
        self.ui.state["aps"][0]["ssid"] = ""
        with mock.patch.object(pager_ui, "send_cmd") as send:
            self.ui.start_trap()
            send.assert_not_called()
        self.assertIn("HIDDEN", self.ui.status)

    def test_start_trap_no_targets(self):
        self.ui.state["aps"] = []
        with mock.patch.object(pager_ui, "send_cmd") as send:
            self.ui.start_trap()
            send.assert_not_called()
        self.assertIn("NO TARGETS", self.ui.status)

    def test_drop_trap_sends_untrap(self):
        self.ui.screen = "trap"
        with mock.patch.object(pager_ui, "send_cmd") as send:
            self.ui.drop_trap()
            send.assert_called_once_with({"cmd": "untrap"})
        self.assertEqual(self.ui.screen, "recon")

    def test_quit_guard_sends_once(self):
        with mock.patch.object(pager_ui, "send_cmd") as send:
            self.ui.quit()
            self.ui.quit()
            send.assert_called_once_with({"cmd": "shutdown"})

    def test_toggle_lure_unavailable(self):
        self.ui.state["lure_available"] = False
        with mock.patch.object(pager_ui, "send_cmd") as send:
            self.ui.toggle_lure()
            send.assert_not_called()
        self.assertIn("UNAVAILABLE", self.ui.status)

    def test_toggle_lure_enables(self):
        self.ui.state["lure_available"] = True
        self.ui.state["lure"] = False
        with mock.patch.object(pager_ui, "send_cmd") as send:
            self.ui.toggle_lure()
            send.assert_called_once_with({"cmd": "lure", "on": True})
        self.assertTrue(self.ui.lure_local)

    def test_input_debounce_then_acts(self):
        events = [(self.p.BTN_A, self.p.EVENT_PRESS, 0)]
        with mock.patch.object(self.p, "get_input_event",
                               side_effect=lambda: events.pop(0) if events else None):
            with mock.patch.object(pager_ui, "send_cmd") as send:
                self.ui.started = time.time()
                self.ui.handle_input()
                send.assert_not_called()

        events = [(self.p.BTN_A, self.p.EVENT_PRESS, 0)]
        with mock.patch.object(self.p, "get_input_event",
                               side_effect=lambda: events.pop(0) if events else None):
            with mock.patch.object(pager_ui, "send_cmd") as send:
                self.ui.started = time.time() - self.ui.DEBOUNCE_SEC - 1
                self.ui.handle_input()
                send.assert_called_once()

    def test_move_wraps_and_clamps(self):
        self.ui.screen = "trap"
        self.ui.sel_client = 0
        self.ui.move(-1)
        self.assertEqual(self.ui.sel_client,
                         len(self.ui.state["clients"]) - 1)
        self.ui.move(1)
        self.assertEqual(self.ui.sel_client, 0)

    def test_load_state_missing_returns_none(self):
        self.assertIsNone(pager_ui.load_state("/nonexistent/venus.json"))

    def test_send_cmd_writes_jsonl(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cmd.jsonl")
            self.assertTrue(pager_ui.send_cmd({"cmd": "rescan"}, path=path))
            with open(path) as f:
                self.assertEqual(json.loads(f.readline())["cmd"], "rescan")


# --------------------------------------------------------------------------- #
# Packaging
# --------------------------------------------------------------------------- #

class PayloadTests(unittest.TestCase):
    def test_payload_shell_syntax(self):
        payload = os.path.join(ROOT, "payload.sh")
        result = subprocess.run(["bash", "-n", payload],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_required_files_exist(self):
        for name in ("venus.py", "pager_ui.py", "payload.sh",
                     "venus.conf.example", "portal/index.html",
                     "portal/success.html", "lib/pagerctl.py",
                     "lib/libpagerctl.so"):
            self.assertTrue(os.path.isfile(os.path.join(ROOT, name)), name)

    def test_python_sources_compile(self):
        for name in ("venus.py", "pager_ui.py", "lib/pagerctl.py"):
            path = os.path.join(ROOT, name)
            with open(path) as f:
                source = f.read()
            compile(source, path, "exec")

    def test_install_pkg_extracts_ipk(self):
        import gzip
        import io
        import tarfile

        import install_pkg

        # Build a fake .ipk: gzip( tar(debian-binary, data.tar.gz) ),
        # where data.tar.gz is a gzip'd tar holding ./usr/share/venustest/f.txt.
        inner_buf = io.BytesIO()
        with tarfile.open(fileobj=inner_buf, mode="w:") as inner:
            payload = b"hello venus\n"
            ti = tarfile.TarInfo("./usr/share/venustest/f.txt")
            ti.size = len(payload)
            inner.addfile(ti, io.BytesIO(payload))
        inner_gz = gzip.compress(inner_buf.getvalue())

        outer_buf = io.BytesIO()
        with tarfile.open(fileobj=outer_buf, mode="w:") as outer:
            for name, data in (("./debian-binary", b"2.0\n"),
                               ("./data.tar.gz", inner_gz)):
                ti = tarfile.TarInfo(name)
                ti.size = len(data)
                outer.addfile(ti, io.BytesIO(data))
        ipk_bytes = gzip.compress(outer_buf.getvalue())

        with tempfile.TemporaryDirectory() as d:
            ipk_path = os.path.join(d, "fake_1.0-r1_mipsel_24kc.ipk")
            with open(ipk_path, "wb") as f:
                f.write(ipk_bytes)
            n = install_pkg.install_ipk(ipk_path, dest=d)
            self.assertEqual(n, 1)
            out = os.path.join(d, "usr", "share", "venustest", "f.txt")
            self.assertTrue(os.path.isfile(out))
            with open(out, "rb") as f:
                self.assertEqual(f.read(), b"hello venus\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
