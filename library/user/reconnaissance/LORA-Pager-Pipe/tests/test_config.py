import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import importlib.util
import contextlib
import io
import sqlite3
from contextlib import closing

from lpp_test_paths import PAYLOAD_ROOT
sys.path.insert(0, str(PAYLOAD_ROOT / "lib"))
from lpp import config
cli_spec = importlib.util.spec_from_file_location("pager_cli", PAYLOAD_ROOT / "lpp.py")
pager_cli = importlib.util.module_from_spec(cli_spec)
cli_spec.loader.exec_module(pager_cli)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "private/config.json"

    def raw(self, text):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(text, encoding="utf-8")
        os.chmod(self.path, 0o600)

    def test_defaults_are_isolated_and_uploads_disabled(self):
        first = config.load(self.path)
        first["uploads"]["wigle"]["enabled"] = True
        second = config.load(self.path)
        self.assertEqual(second["region"], "")
        self.assertFalse(second["uploads"]["wigle"]["enabled"])
        self.assertFalse(second["uploads"]["wigle"]["auto"])

    def test_valid_updates_preserve_other_fields_and_private_permissions(self):
        config.set_value("region", "US", self.path)
        config.set_value("uploads.wardrift.api_key", "TEST_ONLY", self.path)
        self.assertEqual(config.load(self.path)["region"], "US")
        self.assertEqual(config.load(self.path)["uploads"]["wardrift"]["api_key"], "TEST_ONLY")
        self.assertEqual(list(self.path.parent.glob(".config-*")), [])
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)

    def test_rejects_unknown_keys_wrong_types_and_injected_controls(self):
        for key, value in (("uploads.wardrift.endpoint", "https://example.com"),
                           ("uploads.wigle.enabled", "false"), ("mode", "invalid"),
                           ("region", "IN"), ("uploads.wigle.api_token", "secret\nvalue")):
            with self.subTest(key=key), self.assertRaises(config.ConfigError):
                config.set_value(key, value, self.path)

    def test_invalid_json_never_overwritten(self):
        self.raw('{"uploads":{"wigle":{"api_token":"TEST_SECRET"}},"unexpected":true}')
        before = self.path.read_bytes()
        with self.assertRaises(config.ConfigError):
            config.set_value("region", "US", self.path)
        self.assertEqual(self.path.read_bytes(), before)

    def test_duplicate_unknown_and_oversized_files_rejected(self):
        for text in ('{"region":"US","region":"ANZ"}', '{"uploads":{"bad":{}}}',
                     '{"mode":{}}', 'x' * (config.MAX_CONFIG_BYTES + 1)):
            self.raw(text)
            with self.assertRaises(config.ConfigError):
                config.load(self.path)

    def test_secret_get_is_blocked(self):
        config.set_value("uploads.wigle.api_token", "TEST_SECRET", self.path)
        with self.assertRaises(config.ConfigError) as caught:
            config.get_value("uploads.wigle.api_token", self.path)
        self.assertNotIn("TEST_SECRET", str(caught.exception))

    def test_symbolic_link_rejected(self):
        destination = Path(self.temporary.name) / "target.json"
        destination.write_text("{}")
        self.path.parent.mkdir()
        try:
            self.path.symlink_to(destination)
        except (OSError, NotImplementedError):
            self.skipTest("Symbolic link creation unavailable")
        with self.assertRaises(config.ConfigError):
            config.load(self.path)

    def test_cli_credentials_use_stdin_without_echo(self):
        env = dict(os.environ, LPP_CONFIG_PATH=str(self.path))
        cli = [sys.executable, str(PAYLOAD_ROOT / "lpp.py")]
        secret = "TEST_SECRET_NOT_A_REAL_CREDENTIAL"
        result = subprocess.run(cli + ["config", "set", "uploads.wdgwars.api_key", "--stdin"],
                                input=secret + "\n", text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)
        for args in (["config", "get", "uploads.wdgwars.api_key"],
                     ["config", "set", "uploads.wdgwars.api_key", secret],
                     ["config", "set", "uploads.wdgwars.api_key", "--invalid", secret]):
            result = subprocess.run(cli + args, text=True, capture_output=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_boolean_text_is_explicit(self):
        self.assertIs(config.parse_value("uploads.wigle.enabled", "false"), False)
        with self.assertRaises(config.ConfigError):
            config.parse_value("uploads.wigle.enabled", "yes")

    def test_credentials_are_bounded_ascii(self):
        for value in ("x" * 513, "token with spaces", "\u00e9"):
            with self.subTest(value=len(value)), self.assertRaises(config.ConfigError):
                config.set_value("uploads.wardrift.api_key", value, self.path)

    def test_missing_gps_warns_without_blocking_raw_capture(self):
        settings = config.load(self.path)
        settings.update(region="US", backend="lorapipe", serial_device=__file__)
        output = io.StringIO()
        with patch.object(pager_cli, "_module_available", return_value=True), \
                patch.object(pager_cli, "_meshtastic_running", return_value=False), \
                patch.object(pager_cli, "_collector_busy", return_value=False), \
                patch.object(pager_cli.socket, "create_connection", side_effect=OSError), \
                contextlib.redirect_stdout(output):
            result = pager_cli.doctor(settings)
        self.assertEqual(result, 0)
        self.assertIn("GPS unavailable", output.getvalue())

    def test_receipt_output_drops_unrecognized_server_text(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            pager_cli._print_upload("wdgwars", {"state": "incomplete", "states": {"pending": 1},
                "receipts": [{"reason": "TEST_SECRET", "counts": {"TEST_SECRET": 1, "imported": 2}}]})
        self.assertNotIn("TEST_SECRET", output.getvalue())
        self.assertIn("pending=1", output.getvalue())
        self.assertIn("imported=2", output.getvalue())

    def test_provider_failure_warns_without_blocking_raw_capture(self):
        settings = config.load(self.path)
        settings.update(region="US", mode="both", backend="lorapipe", serial_device=__file__)
        output = io.StringIO()
        with patch.object(pager_cli, "_module_available", return_value=True), \
                patch.object(pager_cli, "_meshtastic_running", return_value=False), \
                patch.object(pager_cli, "_collector_busy", return_value=False), \
                patch.object(pager_cli.socket, "create_connection", side_effect=OSError), \
                patch("lpp.decode._aes", side_effect=RuntimeError("TEST_PRIVATE_PROVIDER_DETAIL")), \
                patch("lpp.decode._verify_ed25519", side_effect=RuntimeError("TEST_PRIVATE_PROVIDER_DETAIL")), \
                contextlib.redirect_stdout(output):
            result = pager_cli.doctor(settings)
        self.assertEqual(result, 0)
        self.assertIn("AES self-test failed", output.getvalue())
        self.assertIn("Ed25519 self-test failed", output.getvalue())
        self.assertNotIn("TEST_PRIVATE_PROVIDER_DETAIL", output.getvalue())

    def test_crypto_selftests_check_actual_results(self):
        with patch("lpp.decode._aes", return_value=b"wrong"), \
                patch("lpp.decode._verify_ed25519", return_value=False):
            self.assertEqual(len(pager_cli._crypto_checks("both")), 2)

    def test_recent_snapshot_is_bounded_sanitized_and_excludes_unverified_devices(self):
        directory = Path(self.temporary.name)
        path = directory / "capture.sqlite3"
        with closing(sqlite3.connect(path)) as database:
            database.executescript("""CREATE TABLE observations(id INTEGER PRIMARY KEY, received_at REAL, record_json TEXT);
                CREATE TABLE devices(last_seen REAL, latest_json TEXT); PRAGMA user_version=1;""")
            for index in range(12):
                record = {"rssi_dbm": -70, "snr_db": 4.5, "profile": {"id": "meshtastic-US-LONG_FAST"},
                    "receiver_gps": {"latitude": 12.345678},
                    "decoded": {"protocol": "meshtastic", "source_id": "!12345678", "decode_status": "decoded",
                        "name": "Field\nNode", "text": "hello\x1b[2J", "key": "DO_NOT_SHOW"}}
                database.execute("INSERT INTO observations VALUES(?,?,?)", (index, 1700000000 + index, json.dumps(record)))
            database.execute("INSERT INTO devices VALUES(?,?)", (1700000011, json.dumps(record)))
            invalid = {"decoded": {"protocol": "meshcore", "source_id": "a" * 64,
                                  "public_key": "a" * 64, "signature_valid": False, "name": "Unverified"}}
            database.execute("INSERT INTO devices VALUES(?,?)", (1700000012, json.dumps(invalid)))
            database.commit()
        before = path.read_bytes()
        observations = pager_cli.recent_records(directory)
        devices = pager_cli.recent_records(directory, devices=True)
        text = "\n".join(observations + devices)
        self.assertEqual(len(observations), 16)
        self.assertEqual(len(devices), 2)
        self.assertIn("claimed", text)
        self.assertIn("R-70", text)
        self.assertNotIn("Unverified", text)
        self.assertNotIn("DO_NOT_SHOW", text)
        self.assertNotIn("12.345678", text)
        self.assertNotIn("\x1b", text)
        self.assertEqual(path.read_bytes(), before)

    def test_cli_advances_pending_uploads_without_reporting_completion(self):
        settings = config.load(self.path)
        settings["uploads"]["wdgwars"].update(enabled=True, auto=True, api_key="TEST_ONLY")
        pending = {"state": "incomplete", "stop_reason": "deadline", "requests": 2,
                   "services": {"wdgwars": {"state": "incomplete", "states": {"pending": 1}, "receipts": []}}}
        output = io.StringIO()
        with patch.object(config, "load", return_value=settings), \
                patch.object(pager_cli, "_upload_guard", return_value=contextlib.nullcontext()), \
                patch("lpp.session.finalize"), \
                patch("lpp.uploads.advance_uploads", return_value=pending, create=True) as advance, \
                contextlib.redirect_stdout(output):
            result = pager_cli.main(["upload", "--session", str(self.path.parent), "--automatic"])
        self.assertEqual(result, 0)
        self.assertEqual(advance.call_args.kwargs, {"automatic": True, "timeout": 240})
        self.assertIn("pending=1", output.getvalue())
        self.assertIn("Processing remains pending", output.getvalue())
        self.assertNotIn("TEST_ONLY", output.getvalue())


if __name__ == "__main__":
    unittest.main()
