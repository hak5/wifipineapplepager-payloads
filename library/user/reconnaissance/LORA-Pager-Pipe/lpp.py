#!/usr/bin/env python3
"""Command-line entry point used by the native Pager payload."""

import argparse
from contextlib import closing, contextmanager
import importlib.util
import json
import math
import os
from pathlib import Path
import socket
import sqlite3
import sys
import time
from datetime import datetime, timezone
import re

# AES and Ed25519 use OpenSSL's default provider. The Pager's MMC packages do
# not need the legacy provider, which can fail to load from the root overlay.
os.environ.setdefault("CRYPTOGRAPHY_OPENSSL_NO_LEGACY", "1")

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from lpp import config
from lpp.profiles import select_profiles


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally repeats rejected arguments, which may be credentials.
        raise ValueError("Invalid command arguments; use --help")


def parser():
    result = Arguments(description="LORA-Pager-Pipe local capture and export tools")
    actions = result.add_subparsers(dest="action", required=True, parser_class=Arguments)
    configuration = actions.add_parser("config")
    commands = configuration.add_subparsers(dest="config_action", required=True, parser_class=Arguments)
    get = commands.add_parser("get")
    get.add_argument("key")
    put = commands.add_parser("set")
    put.add_argument("key")
    put.add_argument("value", nargs="?")
    put.add_argument("--stdin", action="store_true")
    actions.add_parser("dependencies")
    actions.add_parser("doctor")
    sessions = actions.add_parser("session")
    session_actions = sessions.add_subparsers(dest="session_action", required=True, parser_class=Arguments)
    create = session_actions.add_parser("new")
    create.add_argument("--root", type=Path, default=Path("/root/loot/lora-pager-pipe"))
    attach = session_actions.add_parser("attach")
    attach.add_argument("--session", required=True, type=Path)
    attach.add_argument("--kind", required=True, choices=("wifi_csv", "wifi_pcap"))
    attach.add_argument("--path", required=True, type=Path)
    for action in ("capture", "status", "observations", "devices", "export", "upload"):
        command = actions.add_parser(action)
        command.add_argument("--session", required=True, type=Path)
        if action == "capture":
            command.add_argument("--duration", type=float)
        if action == "upload":
            command.add_argument("--service", choices=("wigle", "wardrift", "wdgwars"))
            command.add_argument("--automatic", action="store_true")
    return result


def _module_available(name):
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def _libusb_available():
    try:
        from usb.backend.libusb1 import get_backend
        return get_backend() is not None
    except Exception:
        return False


def dependencies(settings):
    """Report fixed dependency tokens without probing a radio, GPS, or secrets."""
    missing = []
    if settings["backend"] == "glytch":
        bundled = Path(__file__).resolve().parent / "lib" / "usb"
        if not (bundled / "core.py").is_file() or not _module_available("usb.core"):
            missing.append("reinstall pyusb")
        elif not _libusb_available():
            missing.append("required libusb-1.0-0")
    elif not _module_available("serial"):
        missing.append("required python3-pyserial")
    cryptography = _module_available("cryptography")
    aes = cryptography or _module_available("Crypto")
    signatures = cryptography or _module_available("nacl")
    if not aes or (settings["mode"] in {"meshcore", "both"} and not signatures):
        missing.append("optional python3-cryptography")
    for line in missing or ["ready"]:
        print(line)
    return 0


def _meshtastic_running():
    for process in Path("/proc").glob("[0-9]*/comm"):
        try:
            if process.read_text().strip() == "meshtasticd":
                return True
        except OSError:
            continue
    return False


def _usb_present():
    for device in Path("/sys/bus/usb/devices").glob("*"):
        try:
            if ((device / "idVendor").read_text().strip().lower(),
                    (device / "idProduct").read_text().strip().lower()) == ("1a86", "5512"):
                return True
        except OSError:
            continue
    return False


def _collector_busy():
    import fcntl
    from lpp.session import LOCK_PATH
    try:
        with LOCK_PATH.open("rb") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
    except FileNotFoundError:
        pass
    return False


@contextmanager
def _upload_guard():
    import fcntl
    from lpp.session import LOCK_PATH
    with LOCK_PATH.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("Stop capture before uploading") from exc
        yield


def _crypto_checks(mode):
    from lpp.decode import _aes, _verify_ed25519
    warnings = []
    try:
        plaintext = _aes(bytes.fromhex("000102030405060708090a0b0c0d0e0f"),
                         bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a"))
        if plaintext != bytes.fromhex("00112233445566778899aabbccddeeff"):
            warnings.append("AES self-test unavailable or failed; encrypted payloads remain raw")
        else:
            print("AES: known-vector self-test passed")
    except Exception:
        warnings.append("AES self-test failed; encrypted payloads remain raw")
    if mode in {"meshcore", "both"}:
        # RFC 8032 section 7.1, Ed25519 test 1: signature of the empty message.
        public_key = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        signature = bytes.fromhex(
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
            "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        try:
            if _verify_ed25519(public_key, b"", signature) is not True:
                warnings.append("Ed25519 self-test unavailable or failed; MeshCore adverts remain unverified")
            else:
                print("Ed25519: RFC 8032 self-test passed")
        except Exception:
            warnings.append("Ed25519 self-test failed; MeshCore adverts remain unverified")
    return warnings


def doctor(settings):
    """Read-only preflight: do not claim, reset, tune, or transmit through USB."""
    errors = []
    warnings = []
    try:
        profiles = select_profiles(settings["region"], settings["mode"])
        print("Region: %s | %s" % (settings["region"], settings["mode"]))
        print("Receive profiles: %d" % len(profiles))
    except ValueError:
        errors.append("Select a supported region and receive mode first")
    if _meshtastic_running():
        errors.append("MeshtasticD is running; stop its radio use before capture")
    if os.name == "posix" and _collector_busy():
        errors.append("Another capture or upload owns this payload session lock")
    if settings["backend"] == "glytch":
        if not _module_available("usb.core"):
            errors.append("Bundled PyUSB source is missing; reinstall the complete payload directory")
        else:
            try:
                from usb.backend.libusb1 import get_backend
                if get_backend() is None:
                    errors.append("The libusb-1.0 backend is unavailable")
            except Exception:
                errors.append("The libusb-1.0 backend could not be loaded")
        if not _usb_present():
            errors.append("Glytch CH341 USB radio 1a86:5512 was not found")
        else:
            print("Radio: Glytch USB bridge detected; RF operation untested")
    else:
        if not _module_available("serial"):
            errors.append("PySerial is missing (OpenWrt python3-pyserial)")
        device = settings["serial_device"]
        if not device or not Path(device).exists():
            errors.append("Configure an available LoRaPipe serial device")
        else:
            print("Radio: serial device present; LoRaPipe protocol untested")
    warnings.extend(_crypto_checks(settings["mode"]))
    try:
        with socket.create_connection(("127.0.0.1", 2947), timeout=0.4):
            print("GPS: daemon reachable; capture verifies each fix")
    except OSError:
        warnings.append("GPS unavailable: captures will have no receiver position")
    for warning in warnings:
        print("Warning: " + warning)
    for error in errors:
        print("Required: " + error)
    print("Ready for a receive test" if not errors else "Capture checks did not pass")
    return 1 if errors else 0


def _configure(args):
    if args.config_action == "get":
        value = config.get_value(args.key)
        print(str(value).lower() if type(value) is bool else value)
        return 0
    if args.stdin:
        if args.value is not None:
            raise config.ConfigError("Provide a value or standard input, not both")
        value = sys.stdin.read(4098)
        if len(value) > 4097:
            raise config.ConfigError("Configuration input is too long")
        value = value.removesuffix("\n")
    else:
        if args.key in config.SECRET_KEYS:
            raise config.ConfigError("Credentials must be supplied through standard input")
        if args.value is None:
            raise config.ConfigError("A configuration value is required")
        value = args.value
    config.set_value(args.key, config.parse_value(args.key, value))
    print("Setting saved")
    return 0


def _print_status(value):
    # Only known operational fields reach the on-device console.
    for key in ("status", "profile", "received", "saved", "gps", "queue_drops", "write_errors", "errors"):
        if key in value:
            item = value[key]
            if key == "gps" and isinstance(item, dict):
                item = item.get("status", "no_fix")
            if isinstance(item, dict):
                item = json.dumps(item, separators=(",", ":"))
            print("%s: %s" % (key.replace("_", " ").title(), str(item)[:160]))


def _display_text(value, limit=44):
    if not isinstance(value, str):
        return ""
    printable = "".join(character if 32 <= ord(character) <= 126 else " " for character in value)
    printable = " ".join(printable.split())
    return printable[:limit - 3] + "..." if len(printable) > limit else printable


def _source_identity(decoded):
    source = decoded.get("source_id")
    if decoded.get("protocol") == "meshtastic" and isinstance(source, str):
        if re.fullmatch(r"![0-9a-fA-F]{8}", source) and source.lower() not in {"!00000000", "!ffffffff"}:
            return "MT", source.lower(), "claimed"
    if decoded.get("protocol") == "meshcore" and decoded.get("signature_valid") is True:
        if isinstance(source, str) and re.fullmatch(r"[0-9a-fA-F]{64}", source) and source == decoded.get("public_key"):
            return "MC", source[:10].lower() + "..", "signed"
    protocol = {"meshtastic": "MT", "meshcore": "MC"}.get(decoded.get("protocol"), "Unknown")
    return protocol, "unknown", ""


def _observation_lines(timestamp, record, devices=False):
    decoded = record.get("decoded", {})
    if not isinstance(decoded, dict):
        decoded = {}
    protocol, source, identity = _source_identity(decoded)
    if devices and not identity:
        return []
    try:
        when = datetime.fromtimestamp(float(timestamp), timezone.utc).strftime("%m-%d %H:%M:%S")
    except (TypeError, ValueError, OSError, OverflowError):
        when = "time unavailable"

    def measurement(field, prefix):
        value = record.get(field)
        return prefix + ("%g" % value if type(value) in (int, float) and math.isfinite(value) else "?")

    profile = record.get("profile", {})
    profile_id = profile.get("id", "") if isinstance(profile, dict) else ""
    if not isinstance(profile_id, str):
        profile_id = ""
    short_profile = "LF" if profile_id.endswith("LONG_FAST") else "Narrow" if profile_id.endswith("NARROW") else _display_text(profile_id, 10)
    first = "%s %s %s" % (protocol, source, when)
    fields = [measurement("rssi_dbm", "R"), measurement("snr_db", "S")]
    if short_profile:
        fields.append(short_profile)
    if devices:
        fields.append(identity)
    label = decoded.get("name") or decoded.get("short_name")
    detail = _display_text(label, 12)
    text = _display_text(decoded.get("text"), 24)
    state = _display_text(decoded.get("decode_status"), 18)
    if detail:
        fields.append(detail)
    if text:
        fields.append(text)
    elif state:
        fields.append(state)
    return [first, _display_text(" | ".join(fields), 60)]


def recent_records(directory, devices=False):
    """Read a small committed snapshot without creating or modifying a database."""
    path = (Path(directory) / "capture.sqlite3").resolve()
    if not path.is_file():
        return ["No saved observations in this session yet."]
    deadline = time.monotonic() + 0.5
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.2)) as database:
        database.execute("PRAGMA query_only=ON")
        database.execute("PRAGMA trusted_schema=OFF")
        database.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
        if database.execute("PRAGMA user_version").fetchone()[0] != 1:
            raise ValueError("Unsupported capture database")
        if devices:
            rows = database.execute("SELECT last_seen, substr(latest_json,1,32769) FROM devices ORDER BY last_seen DESC LIMIT 8").fetchall()
        else:
            rows = database.execute("SELECT received_at, substr(record_json,1,32769) FROM observations ORDER BY id DESC LIMIT 8").fetchall()
    lines = []
    for timestamp, raw in rows:
        try:
            if not isinstance(raw, str) or len(raw) > 32768:
                continue
            record = json.loads(raw)
            if isinstance(record, dict):
                lines.extend(_observation_lines(timestamp, record, devices))
        except (ValueError, TypeError, OverflowError):
            continue
    return lines or ["No identified device summaries yet." if devices else "No saved observations yet."]


def _print_upload(service, result):
    known_states = {"accepted", "disabled", "no_eligible_data", "auth_failed", "incomplete",
                    "pending", "prepared", "uncertain", "rejected", "failed", "retry", "sending"}
    known_reasons = {"invalid_receipt", "queued_for_processing", "duplicate", "accepted", "check_import_counts",
                     "unrecognized_receipt", "interrupted_post", "retry_limit", "authentication_required",
                     "server_job_failed", "rate_limited", "redirect_refused", "request_rejected",
                     "server_error_after_post", "connection_lost_after_post", "connection_unavailable", "transport_failed"}
    known_counts = {"imported", "captured", "updated", "duplicates", "no_gps", "bad_rows", "merged_samples",
                    "meshcore_imported", "meshcore_already_seen", "meshcore_merged", "meshcore_rejected"}
    state = result.get("state")
    print("%s: %s" % (service, state if state in known_states else "unknown"))
    states = result.get("states", {})
    if states:
        print("Chunks: " + ", ".join("%s=%d" % (key, value) for key, value in states.items()
                                    if key in known_states and type(value) is int and value >= 0))
    for receipt in result.get("receipts", [])[:4]:
        if receipt.get("reason") in known_reasons:
            print("Result: " + receipt["reason"])
        counts = receipt.get("counts", {})
        if counts:
            print("Imported: " + ", ".join("%s=%d" % (key, value) for key, value in counts.items()
                                           if key in known_counts and type(value) is int and value >= 0))


def main(argv=None):
    try:
        os.umask(0o077)
        args = parser().parse_args(argv)
        if args.action == "config":
            return _configure(args)
        settings = config.load()
        if args.action == "dependencies":
            return dependencies(settings)
        if args.action == "doctor":
            return doctor(settings)
        from lpp import session
        if args.action == "session":
            if args.session_action == "new":
                print(session.create_session(args.root))
            else:
                session.attach(args.session, args.kind, args.path)
                print("Capture file attached")
            return 0
        if args.action == "capture":
            if args.duration is not None and (not math.isfinite(args.duration) or not 0 < args.duration <= 86400):
                raise ValueError("Duration must be greater than zero and at most 86400 seconds")
            return session.capture(args.session, settings, duration=args.duration)
        if args.action == "status":
            _print_status(session.status(args.session))
            return 0
        if args.action in {"observations", "devices"}:
            for line in recent_records(args.session, devices=args.action == "devices"):
                print(line)
            return 0
        from lpp import uploads
        if args.action == "export":
            session.finalize(args.session)
            result = uploads.prepare_session(args.session)
            print("Local export prepared; original session retained")
            print("Artifacts: %d" % len(result.get("artifacts", [])))
            return 0
        if args.action == "upload":
            if not args.automatic and not args.service:
                raise ValueError("Select an upload service or use --automatic")
            services = [args.service] if args.service else ["wigle", "wardrift", "wdgwars"]
            services = [service for service in services if settings["uploads"][service]["enabled"]
                        and (not args.automatic or settings["uploads"][service]["auto"])]
            if not services:
                print("No upload services enabled for this action")
                return 0
            failures = 0
            with _upload_guard():
                session.finalize(args.session)
                progress = uploads.advance_uploads(args.session, settings, services,
                                                    automatic=args.automatic, timeout=240)
                for service, result in progress["services"].items():
                    _print_upload(service, result)
                    terminal_failures = {"auth_failed", "rejected", "failed", "uncertain"}
                    if result.get("state") in terminal_failures or any(
                            result.get("states", {}).get(state, 0) for state in terminal_failures):
                        failures += 1
                reason = progress.get("stop_reason")
                if reason in {"deadline", "request_limit"}:
                    print("Processing remains pending; saved jobs can be resumed later")
                elif reason == "blocked":
                    print("Review saved upload states before trying again")
            return 1 if failures else 0
        return 1
    except config.ConfigError as exc:
        print("Configuration: %s" % exc, file=sys.stderr)
        return 2
    except (ValueError, ImportError, OSError):
        print("Operation could not complete; check configuration, dependencies, and session files.", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Operation interrupted", file=sys.stderr)
        return 130
    except Exception:
        # Library or transport exceptions can contain request headers or tokens.
        print("Operation failed; local files have been retained.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
