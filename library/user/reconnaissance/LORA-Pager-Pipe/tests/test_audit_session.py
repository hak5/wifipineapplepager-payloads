"""Offline checks of the content-redacted capture audit using synthetic data."""

from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest

from lpp_test_paths import PAYLOAD_ROOT, PROJECT_ROOT
sys.path.insert(0, str(PAYLOAD_ROOT / "lib"))

from lpp.profiles import select_profiles
from lpp.session import Store, atomic_json, create_session

AUDIT_PATH = PROJECT_ROOT / "tools" / "audit_session.py"
SPEC = importlib.util.spec_from_file_location("audit_session", AUDIT_PATH)
audit_session = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit_session)


def synthetic_records():
    profile = select_profiles("US")[0].to_dict()
    return [
        {"timestamp": 1700000000.25, "raw_hex": b"PRIVATE_PACKET_ALPHA".hex(),
         "profile": profile, "rssi_dbm": -97.5, "snr_db": -2.25, "crc_ok": True,
         "receiver_gps": {"valid": True, "latitude": 12.345678, "longitude": -23.456789},
         "decoded": {"protocol": "meshtastic", "decode_status": "decoded",
                     "source_id": "PRIVATE_NODE_ALPHA", "name": "PRIVATE_NAME_ALPHA"}},
        {"timestamp": 1700000001.5, "raw_hex": b"PRIVATE_PACKET_BRAVO".hex(),
         "profile": profile, "rssi_dbm": -110.0, "snr_db": 1.0, "crc_ok": None,
         "decoded": {"protocol": "PRIVATE_PROTOCOL", "decode_status": "PRIVATE_STATE"}},
    ]


def closed_session(root):
    directory = create_session(root)
    store = Store(directory)
    try:
        for record in synthetic_records():
            store.append(record)
    finally:
        store.close()
    mark_closed(directory, 2)
    return directory


def mark_closed(directory, saved):
    metadata = json.loads((directory / "session.json").read_text(encoding="utf8"))
    metadata.update(status="closed", counters={"received": saved, "saved": saved,
                    "queue_drops": 0, "decode_errors": 0, "write_errors": 0,
                    "PRIVATE_COUNTER": 12345},
                    errors=["PRIVATE_ERROR_CONTENT"], private_note="PRIVATE_METADATA")
    atomic_json(directory / "session.json", metadata)


class AuditSessionTests(unittest.TestCase):
    def cli(self, directory):
        return subprocess.run([sys.executable, str(AUDIT_PATH), str(directory)],
                              capture_output=True, text=True, timeout=10, check=False)

    def assert_redacted(self, output, directory):
        for private in ("PRIVATE_", "12.345678", "23.456789", str(directory),
                        directory.as_posix()):
            self.assertNotIn(private, output)
        for record in synthetic_records():
            self.assertNotIn(record["raw_hex"], output)

    def test_closed_store_session_matches_all_formats_without_changing_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = closed_session(tmp)
            before = {path.name: (path.read_bytes(), path.stat().st_mtime_ns)
                      for path in directory.iterdir()}
            result = audit_session.audit(directory)
            self.assertTrue(result["passed"])
            self.assertEqual(result["counts"], {"jsonl": 2, "sqlite": 2, "pcap": 2})
            self.assertEqual(result["decoded_status_counts"],
                             {"meshtastic.decoded": 1, "unknown.other": 1})
            self.assertEqual(result["session_error_count"], 1)
            self.assertTrue(result["sqlite_record_raw_equal"])
            self.assertTrue(result["saved_count_equal"])
            self.assertTrue(result["files_stable"])
            after = {path.name: (path.read_bytes(), path.stat().st_mtime_ns)
                     for path in directory.iterdir()}
            self.assertEqual(before, after)

    def test_changed_pcap_packet_is_detected_even_when_counts_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = closed_session(tmp)
            path = directory / "lora.pcap"
            contents = bytearray(path.read_bytes())
            contents[-1] ^= 1
            path.write_bytes(contents)
            result = audit_session.audit(directory)
            self.assertFalse(result["passed"])
            self.assertFalse(result["raw_bytes_equal"])
            self.assertTrue(result["counts_equal"])
            self.assertTrue(result["sqlite_record_raw_equal"])

    def test_missing_complete_pcap_packet_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = closed_session(tmp)
            path = directory / "lora.pcap"
            contents = path.read_bytes()
            first_frame_length = struct.unpack_from("<I", contents, 24 + 8)[0]
            path.write_bytes(contents[:24 + 16 + first_frame_length])
            result = audit_session.audit(directory)
            self.assertFalse(result["passed"])
            self.assertFalse(result["counts_equal"])
            self.assertFalse(result["raw_bytes_equal"])
            self.assertEqual(result["counts"], {"jsonl": 2, "sqlite": 2, "pcap": 1})

    def test_sqlite_json_must_agree_with_its_raw_blob(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = closed_session(tmp)
            with closing(sqlite3.connect(directory / "capture.sqlite3")) as db:
                record = json.loads(db.execute(
                    "SELECT record_json FROM observations WHERE id=1").fetchone()[0])
                record["raw_hex"] = "00"
                db.execute("UPDATE observations SET record_json=? WHERE id=1",
                           (json.dumps(record),))
                db.commit()
                db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            result = audit_session.audit(directory)
            self.assertFalse(result["passed"])
            self.assertFalse(result["sqlite_record_raw_equal"])
            self.assertTrue(result["raw_bytes_equal"])

    def test_unfinished_sessions_are_refused_before_capture_files_are_opened(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = create_session(tmp)
            for state in ("created", "capturing", "interrupted"):
                with self.subTest(status=state):
                    atomic_json(directory / "session.json", {
                        "schema_version": 1, "status": state})
                    result = audit_session.audit(directory)
                    self.assertFalse(result["passed"])
                    self.assertEqual(result["reason"],
                                     "session_not_closed_or_schema_unsupported")
                    self.assertNotIn("counts", result)

    def test_uncheckpointed_wal_is_refused_despite_closed_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = create_session(tmp)
            store = Store(directory)
            try:
                store.append(synthetic_records()[0])
                store.flush()
                mark_closed(directory, 1)
                wal = directory / "capture.sqlite3-wal"
                self.assertGreater(wal.stat().st_size, 0)
                before = wal.read_bytes()
                result = audit_session.audit(directory)
                self.assertFalse(result["passed"])
                self.assertEqual(result["reason"], "closed_session_has_uncheckpointed_wal")
                self.assertNotIn("counts", result)
                self.assertEqual(wal.read_bytes(), before)
            finally:
                store.close()
            self.assertTrue(audit_session.audit(directory)["passed"])

    def test_cli_success_only_reports_allowlisted_summaries(self):
        with tempfile.TemporaryDirectory(prefix="PRIVATE_PATH_") as tmp:
            directory = closed_session(tmp)
            completed = self.cli(directory)
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(completed.stderr, "")
            self.assertTrue(json.loads(completed.stdout)["passed"])
            self.assert_redacted(completed.stdout, directory)

    def test_cli_errors_redact_content_and_paths(self):
        for failure in ("invalid_json", "partial_pcap", "missing_pcap"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix="PRIVATE_PATH_") as tmp:
                directory = closed_session(tmp)
                if failure == "invalid_json":
                    (directory / "observations.jsonl").write_text(
                        "PRIVATE_INVALID_PACKET_CONTENT\n", encoding="utf8")
                elif failure == "partial_pcap":
                    path = directory / "lora.pcap"
                    path.write_bytes(path.read_bytes()[:-1])
                else:
                    (directory / "lora.pcap").unlink()
                completed = self.cli(directory)
                self.assertEqual(completed.returncode, 2)
                self.assertEqual(completed.stderr, "")
                self.assertEqual(json.loads(completed.stdout), {
                    "passed": False, "reason": "invalid_or_unreadable_capture_files"})
                self.assert_redacted(completed.stdout, directory)


if __name__ == "__main__":
    unittest.main()
