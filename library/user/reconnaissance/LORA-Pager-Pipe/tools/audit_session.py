#!/usr/bin/env python3
"""Read-only, content-redacted consistency check of one closed capture session."""

from collections import Counter
from contextlib import closing
import itertools
import json
from pathlib import Path
import sqlite3
import struct
import sys

MAX_JSON = 32768
MAX_RECORDS = 1000000
PROTOCOLS = {"meshtastic", "meshcore", "unknown"}
STATES = {"decoded", "encrypted", "crypto_unavailable", "signature_invalid",
          "header_only", "raw", "malformed", "crc_error", "decoder_error"}
COUNTERS = {"received", "saved", "queue_drops", "decode_errors", "write_errors"}


class AuditError(ValueError):
    pass


def read_object(path, limit=65536):
    with path.open("rb") as source:
        raw = source.read(limit + 1)
    if len(raw) > limit:
        raise AuditError("metadata_size")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise AuditError("metadata_shape")
    return value


def packet_bytes(record):
    encoded = record.get("raw_hex")
    if not isinstance(encoded, str) or not 2 <= len(encoded) <= 510 or len(encoded) % 2:
        raise AuditError("raw_length")
    raw = bytes.fromhex(encoded)
    if not 1 <= len(raw) <= 255:
        raise AuditError("raw_length")
    return raw


def json_packets(path, decoded_counts):
    with path.open("rb") as source:
        for count in range(MAX_RECORDS + 1):
            line = source.readline(MAX_JSON + 2)
            if not line:
                return
            if count == MAX_RECORDS or len(line) > MAX_JSON + 1 or not line.endswith(b"\n"):
                raise AuditError("jsonl_bound_or_partial_line")
            record = json.loads(line)
            if not isinstance(record, dict) or record.get("schema_version") != 1:
                raise AuditError("observation_schema")
            decoded = record.get("decoded", {})
            if not isinstance(decoded, dict):
                decoded = {}
            protocol = decoded.get("protocol")
            state = decoded.get("decode_status")
            protocol = protocol if isinstance(protocol, str) and protocol in PROTOCOLS else "unknown"
            state = state if isinstance(state, str) and state in STATES else "other"
            decoded_counts[protocol + "." + state] += 1
            yield packet_bytes(record)


def sqlite_packets(path, result):
    # A closed, checkpointed session can be read without creating WAL/SHM files.
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True, timeout=1)) as database:
        database.execute("PRAGMA query_only=ON")
        database.execute("PRAGMA trusted_schema=OFF")
        version = database.execute("PRAGMA user_version").fetchone()[0]
        result["sqlite_schema_version"] = version if type(version) is int else None
        if version != 1:
            raise AuditError("sqlite_schema")
        rows = database.execute("SELECT substr(raw,1,256), substr(record_json,1,32769) FROM observations ORDER BY id")
        for count, (raw, text) in enumerate(rows):
            if count >= MAX_RECORDS or not isinstance(raw, bytes) or not 1 <= len(raw) <= 255:
                raise AuditError("sqlite_raw_bound")
            if not isinstance(text, str) or len(text) > MAX_JSON:
                raise AuditError("sqlite_record_bound")
            record = json.loads(text)
            if not isinstance(record, dict) or packet_bytes(record) != raw:
                result["sqlite_record_raw_equal"] = False
            yield raw


def pcap_packets(path):
    with path.open("rb") as source:
        header = source.read(24)
        if len(header) != 24:
            raise AuditError("pcap_header")
        magic, major, minor, _zone, _sig, snaplen, linktype = struct.unpack("<IHHIIII", header)
        if (magic, major, minor, linktype) != (0xA1B2C3D4, 2, 4, 270) or snaplen != 290:
            raise AuditError("pcap_format")
        for count in range(MAX_RECORDS + 1):
            header = source.read(16)
            if not header:
                return
            if count == MAX_RECORDS or len(header) != 16:
                raise AuditError("pcap_record_header")
            _seconds, micros, included, original = struct.unpack("<IIII", header)
            if micros >= 1000000 or included != original or not 36 <= included <= snaplen:
                raise AuditError("pcap_record_length")
            frame = source.read(included)
            if len(frame) != included or frame[0] != 1 or struct.unpack(">H", frame[2:4])[0] != 35:
                raise AuditError("loratap_frame")
            yield frame[35:]


def signatures(paths):
    result = []
    for path in paths:
        try:
            info = path.stat()
            result.append((info.st_size, info.st_mtime_ns))
        except FileNotFoundError:
            result.append(None)
    return result


def audit(directory):
    metadata = read_object(directory / "session.json")
    state = metadata.get("status")
    state = state if state in {"created", "capturing", "closed", "interrupted"} else "unknown"
    values = metadata.get("counters", {})
    values = values if isinstance(values, dict) else {}
    counters = {key: values[key] for key in COUNTERS if type(values.get(key)) is int and values[key] >= 0}
    result = {"schema_version": metadata.get("schema_version") if type(metadata.get("schema_version")) is int else None,
              "status": state, "counters": counters,
              "session_error_count": len(metadata.get("errors", [])) if isinstance(metadata.get("errors"), list) else None,
              "sqlite_record_raw_equal": True, "raw_bytes_equal": True}
    if state != "closed" or result["schema_version"] != 1:
        result.update(passed=False, reason="session_not_closed_or_schema_unsupported")
        return result
    paths = [directory / name for name in ("session.json", "observations.jsonl", "capture.sqlite3", "lora.pcap", "capture.sqlite3-wal")]
    before = signatures(paths)
    if before[4] is not None and before[4][0] != 0:
        result.update(passed=False, reason="closed_session_has_uncheckpointed_wal")
        return result
    decoded_counts = Counter()
    generators = [json_packets(paths[1], decoded_counts), sqlite_packets(paths[2], result), pcap_packets(paths[3])]
    counts = [0, 0, 0]
    missing = object()
    try:
        for row in itertools.zip_longest(*generators, fillvalue=missing):
            for index, item in enumerate(row):
                if item is not missing:
                    counts[index] += 1
            if missing in row or not row[0] == row[1] == row[2]:
                result["raw_bytes_equal"] = False
    finally:
        for generator in generators:
            generator.close()
    result["counts"] = dict(zip(("jsonl", "sqlite", "pcap"), counts))
    result["counts_equal"] = counts[0] == counts[1] == counts[2]
    result["saved_count_equal"] = counters.get("saved") == counts[0]
    result["decoded_status_counts"] = dict(sorted(decoded_counts.items()))
    result["files_stable"] = before == signatures(paths)
    result["passed"] = all(result[key] for key in ("counts_equal", "saved_count_equal", "raw_bytes_equal", "sqlite_record_raw_equal", "files_stable"))
    return result


def main():
    if len(sys.argv) != 2:
        print('{"passed":false,"reason":"one_session_directory_argument_required"}')
        return 2
    try:
        result = audit(Path(sys.argv[1]))
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0 if result["passed"] else 1
    except Exception:
        # Paths, packet fields and exception text never leave this audit.
        print('{"passed":false,"reason":"invalid_or_unreadable_capture_files"}')
        return 2


if __name__ == "__main__":
    sys.exit(main())
