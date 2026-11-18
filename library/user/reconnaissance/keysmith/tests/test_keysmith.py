#!/usr/bin/env python3
"""Unit tests for KEYSMITH.

Run from the repository root:

    python3 -m unittest discover -s keysmith/tests -v

Nothing here touches a radio, a real access point or a real DHCP server:
``iw``, ``wpa_supplicant`` and ``udhcpc`` are mocked or replaced with local
fixtures, so the suite is safe on a development host.

The algorithm expectations come straight from RouterKeygen's own test suite
(``test/AlgorithmsTest.cpp``, GPLv3, Rui Araujo / Luis Fonseca), which is the
authority on what the vendor key generators should produce.
"""

import argparse
import json
import os
import re
import shutil
import stat
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

import keysmith  # noqa: E402
from ks import keygens, matcher, scan, wpa  # noqa: E402

try:  # the UI pulls in lib/pagerctl only for the real device
    from ks import ui  # noqa: E402
except Exception:  # pragma: no cover - defensive
    ui = None


# --------------------------------------------------------------------------- #
# RouterKeygen vector table
# --------------------------------------------------------------------------- #

# (test name, ssid, bssid, algorithm, expected size, {index: key})
#
# Copied verbatim from RouterKeygen's test/AlgorithmsTest.cpp so the suite is
# self-contained on a device with no upstream checkout.
VECTORS = [
    ("testAliceItaly", "Alice-53847953", "00:25:53:35:a7:91", "AliceItaly", 1,
     {0: "7nfyuqlahytaml3bkcjasmtf"}),
    ("testAliceItaly2", "Alice-37588990", "00:23:8e:48:e7:d4", "AliceItaly", 4,
     {3: "9j4hm3ojq4brfdy6wcsuglwu"}),
    ("testAliceItaly3", "Alice-95535232", "00:8c:54:07:de:08", "AliceItaly", 1,
     {0: "e3eudsvbuu2i8zz2yalosd65"}),
    ("testAliceItaly4", "Alice-53023425", "00:25:53:05:e3:50", "AliceItaly", 4,
     {3: "gi0wdaa3crf6wsb53sf7bv5t"}),
    ("testAliceGermany", "ALICE-WLANC3", "00:1E:40:A0:84:C4", "AliceGermany",
     1, {0: "MGIwMjhjYTYzZmM0"}),
    ("testArcadyan", "Arcor-910B02", "00:12:BF:91:0B:EC", "Arcadyan", 1,
     {0: "F9C8C9DEF"}),
    ("testArcadyan2", "VodafoneGG11", "74:31:70:33:00:11", "Arcadyan", 2,
     {0: "58639029A", 1: "58639129A"}),
    ("testInterCable", "InterCable983996", "7C:05:07:29:F7:47", "InterCable", 2,
     {0: "m7c050729f748", 1: "m7c050729f749"}),
    ("testArnetPirelli", "WiFi-Arnet-0184", "74:88:8B:27:2B:F4",
     "ArnetPirelli", 7, {}),
    ("testArnetPirelli2", "ADSLPT-AB65637", "f0:84:2f:83:56:a2",
     "ArnetPirelli", 7, {}),
    ("testBelkin", "Belkin_C0DE", "94:44:52:00:C0:DE", "Belkin", 1,
     {0: "040D93B0"}),
    ("testBelkin2", "belkin.ed0", "94:44:52:00:ce:d0", "Belkin", 1,
     {0: "d49496b9"}),
    ("testBelkin3", "Belkin_24615A", "08:86:3b:24:61:5a", "Belkin", 1,
     {0: "2E4C5631"}),
    ("testCONN", "CONN-X", "", "Conn", 1, {0: "1234567890123"}),
    ("testDiscus", "Discus--DA1CC5", "00:1C:A2:DA:1C:C5", "Discus", 1,
     {0: "YW0150565"}),
    ("testEircom", "eircom2633 7520", "00:0f:cc:59:b0:9c", "Eircom", 1, {}),
    ("testHuawei", "INFINITUM1be2", "64:16:F0:35:1C:FD", "Huawei", 1,
     {0: "3432333133"}),
    ("testHuawei_HG24x", "", "00:46:4B:D3:CE:5F", "HG824x", 1,
     {0: "D3CE560D"}),
    ("testHuawei_HG24x2", "", "E0:24:7F:E5:80:01", "HG824x", 1,
     {0: "E57FF80C"}),
    ("testOTEBAUD", "OTEcb4c", "00:13:33:37:CB:4C", "OteBAUD", 1,
     {0: "000133337cb4c"}),
    ("testOTEHuawei", "OTEcb4c", "E8:39:DF:F5:12:34", "OteHuawei", 1,
     {0: "54919345"}),
    ("testPBS", "PBS-11222E", "38:22:9D:11:22:33", "PBS", 1, {}),
    ("testSitecom", "Sitecom", "00:0C:F6:01:23:45", "Sitecom", 4, {}),
    ("testSitecom2", "Sitecom", "00:0C:F6:01:2F:F5", "Sitecom", 4, {}),
    ("testSitecom3", "Sitecom", "00:0C:F6:01:2F:FE", "Sitecom", 4, {}),
    ("testSitecom4", "Sitecom", "00:0C:F6:F1:2F:FE", "Sitecom", 4, {}),
    ("testSitecomWRL400X", "SitecomF12FFE", "00:0C:F6:F1:2F:FE",
     "SitecomWLR400x", 9, {}),
    ("testSitecomWRL400X2", "SitecomF12FFE", "", "SitecomWLR400x", 9, {}),
    ("testSpeedport500", "WLAN-903704", "00:1D:19:90:37:DD", "Speedport500",
     1000, {}),
    ("testSpeedport5002", "WLAN-068370", "00:23:08:06:83:5b", "Speedport500",
     1000, {}),
    ("testTeletu", "TeleTu_00238EE528C7", "00:23:8E:E5:28:C7", "Teletu", 1,
     {0: "15301Y0013305"}),
    ("testThomson", "Thomson41518c", "", "Thomson", 3,
     {0: "1C2D56E083", 1: "69237B667A", 2: "8F524DED99"}),
    ("testBssid", "tplink", "F8:D1:11:1E:28:A5", "Bssid", 1,
     {0: "111E28A5"}),
    ("testBssid2", "Nemont", "00:04:ED:DD:8C:E0", "Bssid", 1,
     {0: "0004EDDD8CE0"}),
    ("testBssid3", "Claro-7296", "C4:12:F5:38:72:96", "Bssid", 2,
     {0: "C412F5387296", 1: "c412f5387296"}),
    ("testBssid4", "movistar_8c2022", "00:0A:C2:8C:20:2B", "Bssid", 1,
     {0: "000ac28c2022"}),
    ("testBssid5", "OTE37cb4c", "B0:75:D5:37:CB:4C", "Bssid", 1, {}),
    ("testBssid6", "ZTE-f24ab5", "08:3F:BC:F2:4A:B5", "Bssid", 1, {}),
    ("testBaseX", "SINGTEL-54F5", "00:26:75:DE:54:F6", "BaseX", 1, {}),
    ("testWifimediaR", "wifimedia_R-1234", "00:26:5B:1E:28:A5",
     "WifimediaR", 2,
     {0: "00265b1e28a0", 1: "00265B1E28A0"}),
]

# Filled in from upstream at import time when the source tree is available.
_UPSTREAM_TEST = "/tmp/opencode/rk/routerkeygenPC-master/test/AlgorithmsTest.cpp"


def load_upstream_vectors(path=_UPSTREAM_TEST):
    """Parse RouterKeygen's QCOMPARE vectors into a list of dicts."""
    if not os.path.isfile(path):
        return []
    src = open(path).read()
    rows = []
    for name, body in re.findall(r"void (test\w*)\(\)\s*\{(.*?)\n    \}",
                                 src, re.S):
        wifi = re.search(r'QScanResult wifi\("([^"]*)",\s*"([^"]*)"\)', body)
        typ = re.search(r"typeid\(\*keygen\), typeid\((\w+)\)", body)
        if not wifi or not typ:
            continue
        pairs = [(int(i), v) for i, v in re.findall(
            r'QCOMPARE\(results\.at\((\d+)\),\s*QString\("([^"]*)"\)\)', body)]
        size = re.search(r"QCOMPARE\(results\.size\(\),\s*(\d+)\)", body)
        rows.append({
            "test": name, "ssid": wifi.group(1), "bssid": wifi.group(2),
            "algo": typ.group(1).replace("Keygen", ""),
            "size": int(size.group(1)) if size else None,
            "pairs": pairs,
        })
    return rows


class VectorTests(unittest.TestCase):
    """Every RouterKeygen test vector that maps to a registry entry."""

    NAME_MAP = {"TeleTu": "Teletu", "Teletu": "Teletu", "pldt": "Pldt"}

    def test_hand_picked_vectors(self):
        for name, ssid, bssid, algo, size, expected in VECTORS:
            with self.subTest(test=name):
                cands = matcher.candidates(ssid, bssid)
                chosen = next((c for c in cands if c.name == algo), None)
                self.assertIsNotNone(chosen, "matcher missed %s" % algo)
                keys = matcher.candidate_keys(chosen, ssid)
                self.assertEqual(len(keys), size)
                for idx, want in expected.items():
                    self.assertEqual(keys[idx], want)

    def test_upstream_vectors(self):
        rows = load_upstream_vectors()
        if not rows:
            self.skipTest("upstream RouterKeygen tree not present")
        checked = 0
        for row in rows:
            algo = self.NAME_MAP.get(row["algo"], row["algo"])
            if algo not in keygens.KEYGENS:
                continue
            if row["test"] == "testThomson":
                # 21.8M SHA-1 ops; already covered once by VECTORS above.
                continue
            with self.subTest(test=row["test"], algo=algo):
                cands = matcher.candidates(row["ssid"], row["bssid"])
                chosen = next((c for c in cands if c.name == algo), None)
                self.assertIsNotNone(chosen, "matcher missed %s for %r"
                                     % (algo, row["ssid"]))
                keys = matcher.candidate_keys(chosen, row["ssid"])
                if row["size"] is not None and row["test"] != "testThomson":
                    self.assertEqual(len(keys), row["size"])
                for idx, want in row["pairs"]:
                    self.assertGreater(len(keys), idx)
                    self.assertEqual(keys[idx], want)
                checked += 1
        self.assertGreaterEqual(checked, 30)


# --------------------------------------------------------------------------- #
# Matcher rules
# --------------------------------------------------------------------------- #

class MatcherTests(unittest.TestCase):
    def names(self, ssid, bssid):
        return [c.name for c in matcher.candidates(ssid, bssid)]

    def test_sitecom_chain_order(self):
        self.assertEqual(self.names("SitecomF12FFE", "00:0c:f6:f1:2f:fe"),
                         ["Sitecom", "SitecomWLR400x", "SitecomWLR2100"])

    def test_sitecom_ssid_digits(self):
        names = self.names("Sitecom123456", "00:0c:f6:12:34:56")
        self.assertIn("Sitecom", names)

    def test_alice_needs_known_ssid_prefix(self):
        # Upstream keys off the SSID prefix table (alice.txt), not the MAC:
        # when the beacon MAC does not match, the table MAC is substituted.
        self.assertIn("AliceItaly",
                      self.names("Alice-53847953", "00:25:53:35:a7:91"))
        self.assertIn("AliceItaly",
                      self.names("Alice-53847953", "aa:bb:cc:dd:ee:ff"))
        self.assertNotIn("AliceItaly",
                         self.names("Alice-99999999", "00:25:53:35:a7:91"))

    def test_alice_germany_any_ssid_case(self):
        self.assertIn("AliceGermany",
                      self.names("ALICE-WLANC3", "00:1E:40:A0:84:C4"))

    def test_zyxel_variants(self):
        self.assertIn("Zyxel", self.names("WLAN_1234", "00:1F:A4:01:23:45"))
        self.assertIn("Zyxel", self.names("OTE1A2B3C", "00:1F:A4:01:23:45"))

    def test_thomson_variant(self):
        self.assertIn("Thomson", self.names("Thomson41518c",
                                            "00:1f:9f:41:51:8c"))

    def test_speedport500_variant(self):
        # ^WLAN-[0-9A-F]{6}$ and the SSID digits mirror MAC bytes 4-5.
        names = self.names("WLAN-903704", "00:1D:19:90:37:DD")
        self.assertIn("Speedport500", names)
        self.assertNotIn("Speedport500",
                         self.names("WLAN-111111", "00:1D:19:90:37:DD"))

    def test_unknown_ssid(self):
        self.assertEqual(self.names("Cafe_Guest", "aa:bb:cc:11:22:33"), [])

    def test_upc_variant(self):
        self.assertIn("Upc07", self.names("UPC1234567", "00:11:22:33:44:55"))
        # Technicolor's Ubee boxes use a separate, unported generator.
        names = self.names("UPC1234567", "64:7c:34:11:22:33")
        self.assertNotIn("Upc07", names)

    def test_huawei_ote_needs_series(self):
        # Only the E8:39:DF:F5/F6/FD series has an OTE key table entry.
        self.assertIn("OteHuawei",
                      self.names("OTEcb4c", "E8:39:DF:F5:12:34"))
        self.assertNotIn("OteHuawei",
                         self.names("OTEcb4c", "00:11:22:33:44:55"))

    def test_empty_bssid_reconstructs_mac(self):
        # Vendor MAC rules rebuild a MAC from the SSID when the beacon hides it.
        names = self.names("Sitecom123456", "")
        self.assertTrue(names)

    def test_candidates_are_unique(self):
        for ssid, bssid in (("SitecomF12FFE", "00:0c:f6:f1:2f:fe"),
                            ("Alice-53847953", "00:25:53:35:a7:91"),
                            ("WLAN_1234", "00:1F:A4:01:23:45")):
            names = self.names(ssid, bssid)
            self.assertEqual(len(names), len(set(names)), (ssid, names))


class KeygenTests(unittest.TestCase):
    def test_registry_complete(self):
        self.assertEqual(len(keygens.KEYGENS), 42)

    def test_derive_dedupes(self):
        keys = keygens.derive("Sitecom", "Sitecom", "00:0C:F6:01:23:45")
        self.assertEqual(len(keys), len(set(keys)))
        self.assertEqual(keys[0], "c6aBBBbg")

    def test_unknown_algorithm(self):
        self.assertEqual(keygens.derive("Nope", "x", "00:11:22:33:44:55"), [])

    def test_slow_set(self):
        for name in ("Upc07", "SitecomWLR400x", "Speedport500"):
            self.assertIn(name, keygens.SLOW)

    def test_tele2_lookup(self):
        # Tele2 keys come from a MAC-prefix table; an unknown OUI yields none.
        self.assertEqual(keygens.derive("Tele2", "Tele2", "00:00:00:00:00:00"),
                         [])

    def test_ote_lookup_table_present(self):
        self.assertTrue(os.path.isfile(
            os.path.join(ROOT, "data", "ote_huawei.txt")))

    def test_belkin_wraps(self):
        keys = keygens.derive("Belkin", "Belkin.C0DE", "94:44:52:00:C0:DE")
        self.assertEqual(len(keys), 1)
        self.assertEqual(len(keys[0]), 8)

    def test_speedport500_size(self):
        keys = keygens.derive("Speedport500", "W724V Typ A",
                              "00:1f:9f:41:51:8c")
        self.assertEqual(len(keys), 1000)

    def test_upc07_fast_and_stable(self):
        start = time.time()
        keys = keygens.upc07("UPC1234567", "")
        self.assertEqual(len(keys), 80)
        self.assertLess(time.time() - start, 2.0)
        self.assertEqual(keys[0], "ZDUEKEST")


# --------------------------------------------------------------------------- #
# Scan parsing
# --------------------------------------------------------------------------- #

IW_SCAN = """\
BSS 00:0c:f6:f1:2f:fe(on wlan1)
\tlast seen: 1204.552s [boottime]
\tTSF: 123456789 usec (0d, 00:02:03)
\tfreq: 2412
\tbeacon interval: 100 TUs
\tsignal: -44.00 dBm
\tcapability: ESS Privacy ShortSlotTime (0x0411)
\tSSID: SitecomF12FFE
\tSupported rates: 1.0* 2.0* 5.5* 11.0* 6.0 9.0 12.0 18.0
\tDS Parameter set: channel 1
\tRSN:\t * Version: 1
\t\t * Group cipher: CCMP
\t\t * Pairwise ciphers: CCMP
\t\t * Authentication suites: PSK
BSS 00:25:53:35:a7:91(on wlan1)
\tfreq: 2437
\tsignal: -61.00 dBm
\tcapability: ESS Privacy (0x0411)
\tSSID: Alice-53847953
\tRSN:\t * Version: 1
\t\t * Authentication suites: SAE
BSS aa:bb:cc:11:22:33(on wlan1)
\tfreq: 5180
\tsignal: -78.00 dBm
\tSSID: Cafe_Guest
BSS 00:1f:9f:41:51:8c(on wlan1)
\tfreq: 2462
\tsignal: -70.00 dBm
\tcapability: ESS Privacy (0x0411)
\tSSID: Thomson41518c
\tWPA:\t * Version: 1
"""


class ScanTests(unittest.TestCase):
    def test_parse_iw_scan(self):
        aps = scan.parse_scan(IW_SCAN)
        self.assertEqual(len(aps), 4)
        sitecom = aps[0]
        self.assertEqual(sitecom["ssid"], "SitecomF12FFE")
        self.assertEqual(sitecom["enc"], "WPA2")
        self.assertEqual(sitecom["channel"], 1)
        self.assertEqual(sitecom["vendor"], "Sitecom")
        self.assertEqual(sitecom["bars"], 4)
        self.assertEqual(aps[1]["enc"], "WPA3")
        self.assertEqual(aps[2]["enc"], "OPEN")
        self.assertEqual(aps[2]["band"], "5")
        self.assertEqual(aps[3]["enc"], "WPA")

    def test_parse_empty(self):
        self.assertEqual(scan.parse_scan(""), [])
        self.assertEqual(scan.parse_scan("garbage\n"), [])

    def test_channel_for_freq(self):
        self.assertEqual(scan.channel_for_freq(2412), 1)
        self.assertEqual(scan.channel_for_freq(2484), 14)
        self.assertEqual(scan.channel_for_freq(5180), 36)
        self.assertEqual(scan.channel_for_freq(0), 0)

    def test_band_for_freq(self):
        self.assertEqual(scan.band_for_freq(2412), "2.4")
        self.assertEqual(scan.band_for_freq(5180), "5")
        self.assertEqual(scan.band_for_freq(6115), "6")

    def test_signal_bars(self):
        self.assertEqual(scan.signal_bars(-40), 4)
        self.assertEqual(scan.signal_bars(-70), 2)
        self.assertEqual(scan.signal_bars(-95), 0)

    def test_vendor_lookup(self):
        self.assertEqual(scan.vendor_for("00:25:53:35:a7:91"), "Pirelli")
        self.assertEqual(scan.vendor_for("94:44:52:00:c0:de"), "Belkin")
        self.assertEqual(scan.vendor_for("AA:BB:CC:DD:EE:FF"), "")

    def test_oui_table_well_formed(self):
        for key in scan._OUI:
            self.assertRegex(key, r"^[0-9A-F]{6}$")

    def test_scan_sorts_by_signal(self):
        with mock.patch.object(scan, "run", return_value=(0, IW_SCAN)):
            aps = scan.scan("wlan1")
        self.assertEqual([a["rssi"] for a in aps],
                         sorted([a["rssi"] for a in aps], reverse=True))

    def test_scan_retries_passive(self):
        calls = []

        def fake(cmd, timeout=25):
            calls.append(cmd)
            if len(calls) == 1:
                return 1, "command failed: Network is down (-100)"
            return 0, IW_SCAN

        with mock.patch.object(scan, "run", side_effect=fake):
            aps = scan.scan("wlan1")
        self.assertEqual(len(aps), 4)
        self.assertIn("passive", calls[1])

    def test_pick_iface_never_phy0(self):
        table = [
            {"iface": "wlan0mgmt", "phy": 0, "type": "managed", "addr": ""},
            {"iface": "wlan1mon", "phy": 1, "type": "monitor", "addr": ""},
            {"iface": "wlan1", "phy": 1, "type": "managed", "addr": ""},
        ]
        with mock.patch.object(scan, "list_ifaces", return_value=table):
            self.assertEqual(scan.pick_iface(), "wlan1")
            self.assertEqual(scan.pick_iface("wlan0mgmt"), "wlan1")

    def test_pick_iface_missing_phy1(self):
        table = [{"iface": "wlan0", "phy": 0, "type": "managed", "addr": ""}]
        with mock.patch.object(scan, "list_ifaces", return_value=table):
            self.assertIsNone(scan.pick_iface())

    def test_prep_refuses_monitor_vif(self):
        ok, msg = scan.prep_iface("wlan1mon")
        self.assertFalse(ok)
        self.assertIn("monitor", msg)


# --------------------------------------------------------------------------- #
# wpa_supplicant handling
# --------------------------------------------------------------------------- #

class FakeStream:
    """Line stream that hands out scripted output on each readline."""

    def __init__(self, lines):
        self.lines = list(lines)

    def readline(self):
        if self.lines:
            return self.lines.pop(0) + "\n"
        time.sleep(0.02)
        return ""


class FakeProc:
    def __init__(self, lines, exit_after=None):
        self.stdout = FakeStream(lines)
        self.pid = 4242
        self._exited = False
        self._exit_after = exit_after
        self.signals = []

    def poll(self):
        return 0 if self._exited else None

    def send_signal(self, sig):
        self.signals.append(sig)
        self._exited = True

    def kill(self):
        self._exited = True

    def wait(self, timeout=None):
        self._exited = True
        return 0


class WpaTests(unittest.TestCase):
    def test_conf_quote_escapes(self):
        text = wpa.conf_text('my"ssid', 'pa\\ss', "00:11:22:33:44:55", 2412)
        self.assertIn('ssid="my\\"ssid"', text)
        self.assertIn('psk="pa\\\\ss"', text)
        self.assertIn("bssid=00:11:22:33:44:55", text)
        self.assertIn("scan_freq=2412", text)

    def test_conf_hidden(self):
        self.assertIn("scan_ssid=1", wpa.conf_text("x", "y", hidden=True))
        self.assertNotIn("scan_ssid=1", wpa.conf_text("x", "y"))

    def test_probe_wrong_key(self):
        proc = FakeProc(["Trying to associate with 00:25:53:35:a7:91",
                         "WPA: 4-Way Handshake failed - pre-shared key may be "
                         "incorrect"])
        with mock.patch.object(wpa, "wpa_bin", return_value="/bin/true"), \
                mock.patch.object(wpa, "write_conf", return_value="/tmp/x"), \
                mock.patch.object(wpa, "_start", return_value=(proc, None)):
            res = wpa.probe("wlan1", "Sitecom", "wrong", timeout=2)
        self.assertFalse(res["ok"])
        self.assertTrue(res["wrong"])
        self.assertEqual(res["reason"], "wrong key")
        self.assertTrue(proc.signals, "probe must stop the supplicant")

    def test_probe_success(self):
        proc = FakeProc(["CTRL-EVENT-CONNECTED - Connection to 00:25:53:35:"
                         "a7:91 completed [id=0 id_str=]"])
        with mock.patch.object(wpa, "wpa_bin", return_value="/bin/true"), \
                mock.patch.object(wpa, "write_conf", return_value="/tmp/x"), \
                mock.patch.object(wpa, "_start", return_value=(proc, None)):
            res = wpa.probe("wlan1", "Sitecom", "right", timeout=2)
        self.assertTrue(res["ok"])
        self.assertEqual(res["reason"], "connected")

    def test_probe_without_supplicant(self):
        with mock.patch.object(wpa, "wpa_bin", return_value=None):
            res = wpa.probe("wlan1", "x", "y")
        self.assertFalse(res["ok"])
        self.assertEqual(res["reason"], "no wpa_supplicant")

    def test_probe_retries_driver_error(self):
        bad = FakeProc(["Failed to initialize driver 'nl80211'"])
        good = FakeProc(["CTRL-EVENT-CONNECTED - Connection completed"])
        starts = []

        def start(conf, iface, driver, daemonize=False):
            starts.append(driver)
            return (bad if driver == "nl80211" else good), None

        with mock.patch.object(wpa, "wpa_bin", return_value="/bin/true"), \
                mock.patch.object(wpa, "write_conf", return_value="/tmp/x"), \
                mock.patch.object(wpa, "_start", side_effect=start):
            res = wpa.probe("wlan1", "x", "y", timeout=2)
        self.assertTrue(res["ok"])
        self.assertEqual(starts[0], "nl80211")
        self.assertEqual(starts[1], "wext")

    def test_probe_timeout(self):
        proc = FakeProc(["Trying to associate"])
        with mock.patch.object(wpa, "wpa_bin", return_value="/bin/true"), \
                mock.patch.object(wpa, "write_conf", return_value="/tmp/x"), \
                mock.patch.object(wpa, "_start", return_value=(proc, None)):
            res = wpa.probe("wlan1", "x", "y", timeout=0.3)
        self.assertFalse(res["ok"])
        self.assertEqual(res["reason"], "timeout")

    def test_parse_lease(self):
        lease = wpa._parse_lease_text(
            "udhcpc: lease of 192.168.0.23 obtained from 192.168.0.1, "
            "lease time 86400\nrouter 192.168.0.1\ndns 192.168.0.1\n"
            "dns 1.1.1.1\n")
        self.assertEqual(lease["ip"], "192.168.0.23")
        self.assertEqual(lease["router"], "192.168.0.1")
        self.assertEqual(lease["dns"], ["192.168.0.1", "1.1.1.1"])

    def test_dhcp_without_client(self):
        with mock.patch.object(wpa, "dhcp_bin", return_value=None):
            lease = wpa.dhcp("wlan1")
        self.assertFalse(lease["ok"])
        self.assertEqual(lease["reason"], "no DHCP client")

    def test_dhcp_script_installed(self):
        path = wpa.dhcp_script()
        self.assertIsNotNone(path)
        self.assertTrue(os.access(path, os.X_OK))
        text = open(path).read()
        code = "\n".join(line for line in text.splitlines()
                         if not line.strip().startswith("#"))
        self.assertNotIn("default via", code,
                         "must not steal the Pager's default route")
        self.assertNotIn("resolv.conf", code)

    def test_connect_skips_redundant_probe(self):
        with mock.patch.object(wpa, "probe") as probe, \
                mock.patch.object(wpa, "write_conf", return_value="/tmp/x"), \
                mock.patch.object(wpa, "_start",
                                  return_value=(FakeProc([]), None)), \
                mock.patch.object(wpa, "dhcp",
                                  return_value={"ok": True, "ip": "10.0.0.2",
                                                "router": "10.0.0.1",
                                                "dns": []}):
            res = wpa.connect("wlan1", "x", "y", assume_ok=True,
                              driver="nl80211")
        probe.assert_not_called()
        self.assertTrue(res["ok"])
        self.assertEqual(res["ip"], "10.0.0.2")


# --------------------------------------------------------------------------- #
# Engine
# --------------------------------------------------------------------------- #

def engine_args(tmpdir, **overrides):
    parser = keysmith.build_parser()
    argv = ["run",
            "--state", os.path.join(tmpdir, "state.json"),
            "--cmd", os.path.join(tmpdir, "cmd.jsonl"),
            "--loot", os.path.join(tmpdir, "loot"),
            "--max-tries", "6",
            "--probe-timeout", "0.3"]
    args = parser.parse_args(argv)
    for key, value in overrides.items():
        setattr(args, key, value)
    return args


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="keysmith-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.args = engine_args(self.tmp)

    def make_engine(self):
        eng = keysmith.Engine(self.args)
        eng.aps = [
            {"ssid": "SitecomF12FFE", "bssid": "00:0c:f6:f1:2f:fe",
             "rssi": -44, "freq": 2412, "channel": 1, "enc": "WPA2",
             "vendor": "Sitecom", "schemes": 3, "bars": 4, "band": "2.4"},
            {"ssid": "Cafe_Guest", "bssid": "aa:bb:cc:11:22:33",
             "rssi": -70, "freq": 2437, "channel": 6, "enc": "OPEN",
             "vendor": "", "schemes": 0, "bars": 2, "band": "2.4"},
        ]
        eng.iface = "wlan1"
        return eng

    def read_state(self, eng):
        with open(eng.state_path) as fh:
            return json.load(fh)

    def test_plan_target(self):
        eng = self.make_engine()
        eng.plan_target(0)
        self.assertEqual(eng.phase, "plan")
        self.assertEqual([p["name"] for p in eng.plan],
                         ["Sitecom", "SitecomWLR400x", "SitecomWLR2100"])
        state = self.read_state(eng)
        self.assertEqual(state["target"]["ssid"], "SitecomF12FFE")
        self.assertEqual(len(state["plan"]), 3)

    def test_plan_by_bssid_after_rescan(self):
        eng = self.make_engine()
        eng.aps.reverse()
        eng.plan_target(0, "00:0c:f6:f1:2f:fe")
        self.assertEqual(eng.target["ssid"], "SitecomF12FFE")

    def test_plan_unknown_scheme(self):
        eng = self.make_engine()
        eng.plan_target(1)
        self.assertEqual(eng.plan, [])
        self.assertIn("no known scheme", eng.message)

    def test_attack_success_writes_loot(self):
        eng = self.make_engine()
        eng.plan_target(0)
        probe = {"ok": True, "wrong": False, "reason": "connected",
                 "elapsed": 0.4, "driver": "nl80211", "log": []}
        link = {"ok": True, "reason": "connected", "ip": "192.168.0.23",
                "router": "192.168.0.1", "dns": ["192.168.0.1"],
                "probe": probe, "driver": "nl80211"}
        with mock.patch.object(keysmith.wpa, "probe", return_value=probe), \
                mock.patch.object(keysmith.wpa, "connect", return_value=link), \
                mock.patch.object(keysmith.time, "sleep"):
            eng.attack()
        self.assertEqual(eng.phase, "done")
        self.assertTrue(eng.result["ok"])
        self.assertEqual(eng.result["ip"], "192.168.0.23")
        self.assertTrue(os.path.isfile(
            os.path.join(self.tmp, "loot", "found.txt")))
        self.assertTrue(os.path.isfile(
            os.path.join(self.tmp, "loot", "keys_000cf6f12ffe.txt")))
        state = self.read_state(eng)
        self.assertEqual(state["result"]["key"], eng.result["key"])
        self.assertEqual(state["phase"], "done")

    def test_attack_stops_after_max_tries(self):
        eng = self.make_engine()
        eng.plan_target(0)
        probe = {"ok": False, "wrong": True, "reason": "wrong key",
                 "elapsed": 0.2, "driver": "nl80211", "log": []}
        with mock.patch.object(keysmith.wpa, "probe", return_value=probe), \
                mock.patch.object(keysmith.time, "sleep"):
            eng.attack()
        self.assertEqual(eng.phase, "done")
        self.assertFalse(eng.result["ok"])
        self.assertEqual(len(eng.attempts), 6)
        self.assertIn("no key", eng.result["reason"])

    def test_attack_derived_only_without_supplicant(self):
        eng = self.make_engine()
        eng.plan_target(0)
        with mock.patch.object(keysmith.wpa, "wpa_bin", return_value=None):
            eng.attack()
        self.assertEqual(eng.phase, "done")
        self.assertTrue(eng.result["derived_only"])
        self.assertFalse(eng.result["ok"])
        self.assertTrue(eng.result["key"])

    def test_attack_stops_on_command(self):
        eng = self.make_engine()
        eng.plan_target(0)

        def stop_soon(*a, **k):
            with open(eng.cmd_path, "a") as fh:
                fh.write('{"cmd":"stop"}\n')
            return {"ok": False, "wrong": True, "reason": "wrong key",
                    "elapsed": 0.1, "driver": "nl80211", "log": []}

        with mock.patch.object(keysmith.wpa, "probe", side_effect=stop_soon), \
                mock.patch.object(keysmith.time, "sleep"):
            eng.attack()
        self.assertEqual(eng.phase, "done")
        self.assertEqual(eng.result["reason"], "stopped")
        self.assertLessEqual(len(eng.attempts), 2)

    def test_scan_once_marks_schemes(self):
        eng = keysmith.Engine(self.args)
        aps = [
            {"ssid": "SitecomF12FFE", "bssid": "00:0c:f6:f1:2f:fe",
             "rssi": -44, "freq": 2412, "channel": 1, "enc": "WPA2"},
            {"ssid": "Cafe_Guest", "bssid": "aa:bb:cc:11:22:33",
             "rssi": -80, "freq": 2437, "channel": 6, "enc": "OPEN"},
        ]
        with mock.patch.object(keysmith.scanmod, "pick_iface",
                               return_value="wlan1"), \
                mock.patch.object(keysmith.scanmod, "prep_iface",
                                  return_value=(True, "ok")), \
                mock.patch.object(keysmith.scanmod, "scan", return_value=aps):
            eng.scan_once()
        self.assertEqual(eng.iface, "wlan1")
        self.assertEqual(eng.aps[0]["ssid"], "SitecomF12FFE")
        self.assertEqual(eng.aps[0]["schemes"], 3)
        self.assertEqual(eng.aps[1]["schemes"], 0)

    def test_pick_radio_without_phy1(self):
        eng = keysmith.Engine(self.args)
        with mock.patch.object(keysmith.scanmod, "pick_iface",
                               return_value=None):
            self.assertFalse(eng.pick_radio())
        self.assertEqual(eng.phase, "error")
        self.assertIn("phy1", eng.error)

    def test_commands_are_consumed_once(self):
        eng = self.make_engine()
        with open(eng.cmd_path, "w") as fh:
            fh.write('{"cmd":"scan"}\nnot json\n{"cmd":"stop"}\n')
        cmds = eng.poll_commands()
        self.assertEqual([c["cmd"] for c in cmds], ["scan", "stop"])
        self.assertEqual(eng.poll_commands(), [])

    def test_handles_disconnect(self):
        eng = self.make_engine()
        with mock.patch.object(keysmith.wpa, "release") as release:
            eng._handle({"cmd": "disconnect"})
        release.assert_called_once_with("wlan1")
        self.assertEqual(eng.phase, "scan")

    def test_atomic_state_write(self):
        eng = self.make_engine()
        eng.save()
        state = self.read_state(eng)
        self.assertEqual(state["version"], keysmith.VERSION)
        self.assertEqual(state["phase"], "boot")
        leftovers = [n for n in os.listdir(self.tmp) if ".tmp." in n]
        self.assertEqual(leftovers, [])


# --------------------------------------------------------------------------- #
# UI
# --------------------------------------------------------------------------- #

@unittest.skipIf(ui is None, "UI module unavailable")
class UITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="keysmith-ui-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.state_path = os.path.join(self.tmp, "state.json")
        self.cmd_path = os.path.join(self.tmp, "cmd.jsonl")
        self.patches = [
            mock.patch.object(ui, "STATE", self.state_path),
            mock.patch.object(ui, "CMD", self.cmd_path),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.pager = ui.FakePager()
        self.ui = ui.KeysmithUI(self.pager)
        self.ui.started = 0.0
        self.write_state("scan")

    def write_state(self, phase, **extra):
        state = json.loads(json.dumps(ui.SAMPLE))
        state["phase"] = phase
        state.update(extra)
        with open(self.state_path, "w") as fh:
            json.dump(state, fh)

    def commands(self):
        if not os.path.exists(self.cmd_path):
            return []
        return [json.loads(line) for line in open(self.cmd_path)
                if line.strip()]

    def press(self, button):
        self.pager.events.append((button, self.pager.EVENT_PRESS))
        self.ui.handle_input()

    def test_render_every_screen(self):
        for phase, screen in (("scan", "scan"), ("plan", "plan"),
                              ("derive", "derive"), ("try", "try"),
                              ("done", "done"), ("error", "error")):
            with self.subTest(phase=phase):
                self.write_state(phase)
                self.ui.sync()
                self.ui.draw()
                self.assertEqual(self.ui.screen, screen)
        self.assertGreater(self.pager.calls, 50)

    def test_waits_for_engine(self):
        os.unlink(self.state_path)
        self.ui.state = None
        self.ui.draw()
        self.assertGreater(self.pager.calls, 0)

    def test_selection_wraps(self):
        self.ui.sync()
        self.ui.sel = 0
        self.press(self.pager.BTN_UP)
        self.assertEqual(self.ui.sel, 4)
        self.press(self.pager.BTN_DOWN)
        self.assertEqual(self.ui.sel, 0)

    def test_a_plans_selected_ap(self):
        self.ui.sync()
        self.ui.sel = 0
        self.press(self.pager.BTN_A)
        cmds = self.commands()
        self.assertEqual(cmds[-1]["cmd"], "plan")
        self.assertEqual(cmds[-1]["bssid"], "00:0c:f6:f1:2f:fe")

    def test_a_on_unkeyed_ap_is_rejected(self):
        self.ui.sync()
        self.ui.sel = 4
        self.press(self.pager.BTN_A)
        self.assertEqual(self.commands(), [])
        self.assertIn("NO KNOWN SCHEME", self.ui.status)

    def test_b_on_scan_shuts_down(self):
        self.ui.sync()
        self.press(self.pager.BTN_B)
        self.assertEqual(self.commands()[-1]["cmd"], "shutdown")
        self.ui.quit_sent_at = time.time() - 3.0
        self.ui.step()
        self.assertTrue(self.ui.done)

    def test_a_on_plan_starts_attack(self):
        self.write_state("plan")
        self.ui.sync()
        self.press(self.pager.BTN_A)
        self.assertEqual(self.commands()[-1]["cmd"], "attack")

    def test_b_on_derive_aborts(self):
        self.write_state("derive")
        self.ui.sync()
        self.press(self.pager.BTN_B)
        self.assertEqual(self.commands()[-1]["cmd"], "stop")

    def test_a_on_result_disconnects(self):
        self.write_state("done")
        self.ui.sync()
        self.press(self.pager.BTN_A)
        names = [c["cmd"] for c in self.commands()]
        self.assertIn("disconnect", names)

    def test_debounce_ignores_launch_press(self):
        self.ui.started = time.time()
        self.press(self.pager.BTN_B)
        self.assertEqual(self.commands(), [])

    def test_state_refresh_updates_screen(self):
        self.write_state("try")
        self.ui.sync()
        self.assertEqual(self.ui.screen, "try")
        self.write_state("done")
        self.ui.sync()
        self.assertEqual(self.ui.screen, "done")

    def test_result_key_rendered(self):
        self.write_state("done")
        self.ui.sync()
        seen = []
        self.pager.draw_text_centered = (
            lambda *a, **k: seen.append(a[1] if len(a) > 1 else ""))
        self.pager.draw_ttf_centered = (
            lambda *a, **k: seen.append(a[1] if len(a) > 1 else ""))
        self.ui.draw_result()
        self.assertIn("c6aBBBbg", seen)

    def test_key_shrinks_to_fit(self):
        self.write_state("done")
        self.ui.sync()
        sizes = []

        def ttf_width(text, font, size):
            return int(len(text) * size * 0.56)

        def draw_ttf(y, text, color, font, size):
            sizes.append(size)

        self.pager.ttf_width = ttf_width
        self.pager.draw_ttf_centered = draw_ttf
        self.ui.draw_key(50, "a" * 63)
        self.assertEqual(sizes, [12.0])
        sizes.clear()
        self.ui.draw_key(50, "c6aBBBbg")
        self.assertEqual(sizes, [34.0])

    def test_key_bitmap_fallback(self):
        seen = []
        self.pager.draw_text_centered = (
            lambda *a, **k: seen.append((a[1], a[3])))
        with mock.patch.object(ui, "KEY_FONT", "/nonexistent/font.ttf"):
            self.ui.draw_key(50, "c6aBBBbg")
            self.ui.draw_key(50, "a" * 20)
        self.assertEqual(seen, [("c6aBBBbg", 3), ("a" * 20, 2)])

    def test_off_phase_exits(self):
        self.write_state("off")
        self.ui.sync()
        self.assertTrue(self.ui.done)


# --------------------------------------------------------------------------- #
# Payload manifest
# --------------------------------------------------------------------------- #

class PayloadTests(unittest.TestCase):
    def test_payload_sh_manifest(self):
        path = os.path.join(ROOT, "payload.sh")
        self.assertTrue(os.path.isfile(path))
        text = open(path).read()
        for field in ("# Title:", "# Author:", "# Description:",
                      "# Version:", "# Category:", "# Firmware:"):
            self.assertIn(field, text)
        self.assertTrue(os.access(path, os.X_OK))
        self.assertIn("keysmith.py", text)
        self.assertIn("ks/ui.py", text)

    def test_payload_sh_syntax(self):
        path = os.path.join(ROOT, "payload.sh")
        proc = subprocess.run(["bash", "-n", path], capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())

    def test_no_hardcoded_payload_path(self):
        # Search globs are fine; a literal assignment or cd is not.
        for name in ("payload.sh", "keysmith.py"):
            text = open(os.path.join(ROOT, name)).read()
            for pattern in ('PAYLOAD_DIR="/root/payloads',
                            "PAYLOAD_DIR='/root/payloads",
                            "cd /root/payloads",
                            "/mmc/root/payloads/user/reconnaissance"):
                self.assertNotIn(pattern, text, "%s must self-locate" % name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
