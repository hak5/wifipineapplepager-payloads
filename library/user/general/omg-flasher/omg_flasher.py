#!/usr/bin/env python3
"""Native serial O.MG flasher for the WiFi Pineapple Pager (Python 3.7+)."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile
import sys
import time
from types import MethodType
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
API = "https://api.github.com/repos/O-MG/O.MG-Firmware"
RAW = "https://raw.githubusercontent.com/O-MG/O.MG-Firmware"
ESPTOOL_VERSION = "4.8.1"
SYNC_RESPONSE_TIMEOUT = 1.0


class CacheMissing(ValueError):
    """No verified firmware is available for the selected channel/capacity."""


MAP = {
    1024: [("esp_init_data_default_v08.bin", 0xfc000),
           ("image.elf-0x00000.bin", 0), ("image.elf-0x10000.bin", 0x10000),
           ("page.mpfs", 0x80000), ("blank.bin", 0x7f000),
           ("blank-settings.bin", 0x7c000), ("blank-wifi.bin", 0x7e000)],
    2048: [("esp_init_data_default_v08.bin", 0x1fc000),
           ("image.elf-0x00000.bin", 0), ("image.elf-0x10000.bin", 0x10000),
           ("page.mpfs", 0x80000), ("blank.bin", 0x7f000),
           ("blank-settings.bin", 0x7c000), ("blank-wifi.bin", 0x7e000)],
}


def log(message):
    print(message, flush=True)


def fetch(url, limit=3 * 1024 * 1024):
    """Bounded, TLS-verified downloads."""
    for attempt in range(3):
        try:
            req = Request(url, headers={"User-Agent": "OMG-Pager-Flasher/1.0",
                                        "Accept": "application/vnd.github+json"})
            with urlopen(req, timeout=30) as response:
                data = response.read(limit + 1)
            if not data or len(data) > limit:
                raise ValueError("Empty or oversized download: " + url)
            return data
        except HTTPError as error:
            if error.code in (403, 429):
                raise URLError("GitHub rate limit/access error; try later. " + url) from error
            if error.code < 500:
                raise
            if attempt == 2:
                raise
        except (URLError, TimeoutError, OSError):
            if attempt == 2:
                raise
        time.sleep(attempt + 1)
    raise RuntimeError("Download failed")


def api(path):
    return json.loads(fetch(API + path))


def select_release(releases, channel):
    prefix = "v3." if channel == "v3" else "v4."
    candidates = [r for r in releases if not r.get("draft", True)
                  and str(r.get("tag_name", "")).startswith(prefix)
                  and (channel != "v3" or not r.get("prerelease", False))]
    if not candidates:
        raise ValueError("No published " + channel + " release found")
    return max(candidates, key=lambda r: (r.get("published_at") or "", r["tag_name"]))


def latest_release(channel):
    # GitHub /latest excludes prereleases, so query the complete release list.
    releases = []
    for page in range(1, 21):
        batch = api("/releases?per_page=100&page=" + str(page))
        if not isinstance(batch, list):
            raise ValueError("Invalid GitHub release response")
        releases.extend(batch)
        if len(batch) < 100:
            return select_release(releases, channel)
    raise ValueError("Release list exceeds pagination limit; cannot guarantee latest")


def boot_patch(data):
    if len(data) < 8 or data[0] != 0xe9:
        raise ValueError("Invalid ESP boot image")
    patched = bytearray(data)
    if patched[2:4] == b"\x03\x30":
        return bytes(patched)
    pos = patched.find(b"\x00\x20")
    if pos < 0:
        raise ValueError("Boot image has no expected WebFlasher patch signature")
    else:
        patched[pos:pos + 2] = b"\x03\x30"
    return bytes(patched)


def initial_config():
    cfg = "INIT;F:keylog=0;"
    cfg += "".join("F:payload%d=0;" % n for n in range(1, 8))
    cfg += "F:bootscript=4;F:hidxfile=16;"
    cfg += "".join("F:payload%d=4;" % n for n in range(1, 51))
    cfg += "F:keylog=100%F;S:flasher=webflasherv2;S:devicename=O.MG;\0"
    return cfg.encode("utf-8").ljust(4096, b"\0")


def validate_segments(segments, size_kb):
    if size_kb not in MAP:
        raise ValueError("Unsupported flash capacity")
    if [(s["name"], s["offset"]) for s in segments] != MAP[size_kb]:
        raise ValueError("Firmware layout differs from official WebFlasher layout")
    occupied = []
    for s in segments:
        length = len(s["data"])
        offset = s["offset"]
        end = offset + ((length + 4095) // 4096) * 4096
        if not length or offset % 4096 or end > size_kb * 1024:
            raise ValueError("Invalid firmware bounds: " + s["name"])
        if s["name"].startswith("blank") and length != 4096:
            raise ValueError("Invalid configuration sector size")
        if any(offset < b and a < end for a, b in occupied):
            raise ValueError("Firmware sectors overlap: " + s["name"])
        occupied.append((offset, end))


def download_firmware(channel, size_kb, directory, release=None, commit=None):
    if size_kb not in MAP:
        raise ValueError("Unsupported flash capacity")
    marker = directory / "manifest.json"
    if marker.exists():
        marker.unlink()
    release = release or latest_release(channel)
    tag = release["tag_name"]
    commit = commit or api("/commits/" + quote(tag, safe=""))["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid firmware commit")
    log("Selected %s (%s)" % (tag, "v4 alpha" if channel == "v4" else "v3 stable"))
    log("Firmware commit: " + commit)
    entries = api("/contents/firmware?ref=" + commit)
    if not isinstance(entries, list):
        raise ValueError("Invalid firmware directory metadata")
    files = {entry["name"]: entry for entry in entries if entry.get("type") == "file"}
    segments = []
    for name, offset in MAP[size_kb]:
        if name.startswith("blank"):
            data = initial_config() if offset == 0x7f000 else bytes(4096)
        else:
            entry = files.get(name)
            if not entry or not 0 < entry.get("size", 0) <= size_kb * 1024:
                raise ValueError("Missing or invalid official firmware file: " + name)
            log("Downloading " + name)
            data = fetch(RAW + "/" + commit + "/firmware/" + quote(name))
            blob = b"blob " + str(len(data)).encode("ascii") + b"\0" + data
            if len(data) != entry["size"] or hashlib.sha1(blob).hexdigest() != entry["sha"]:
                raise ValueError("Git blob checksum mismatch: " + name)
            if offset == 0:
                data = boot_patch(data)
        segments.append({"name": name, "offset": offset, "data": data})
    validate_segments(segments, size_kb)
    directory.mkdir(parents=True, exist_ok=True)
    manifest = {"cache_version": 1, "published_at": release.get("published_at", ""),
                "channel": channel, "tag": tag, "commit": commit,
                "name": release.get("name", tag), "flash_kb": size_kb, "segments": []}
    for s in segments:
        (directory / s["name"]).write_bytes(s["data"])
        manifest["segments"].append({"name": s["name"], "offset": s["offset"],
                                     "size": len(s["data"]),
                                     "sha256": hashlib.sha256(s["data"]).hexdigest()})
    # Write completion marker last; partial downloads cannot be flashed.
    marker.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def load_plan(directory):
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    channel = manifest["channel"]
    if channel not in ("v3", "v4") or not manifest["tag"].startswith(channel + "."):
        raise ValueError("Invalid release/channel in flash plan")
    expected = MAP.get(manifest["flash_kb"])
    if not expected or [(s["name"], s["offset"]) for s in manifest["segments"]] != expected:
        raise ValueError("Invalid flash plan layout")
    segments = []
    for s in manifest["segments"]:
        data = (directory / s["name"]).read_bytes()
        if len(data) != s["size"] or hashlib.sha256(data).hexdigest() != s["sha256"]:
            raise ValueError("Prepared firmware changed or corrupted: " + s["name"])
        segments.append(dict(s, data=data))
    validate_segments(segments, manifest["flash_kb"])
    return manifest, segments


def copy_plan(source, destination, source_label):
    manifest, segments = load_plan(source)
    manifest = dict(manifest)
    for key in ("device", "port"):
        manifest.pop(key, None)
    manifest.update(cache_version=1, source=source_label)
    destination.mkdir(parents=True, exist_ok=True)
    marker = destination / "manifest.json"
    if marker.exists():
        marker.unlink()
    for segment in segments:
        (destination / segment["name"]).write_bytes(segment["data"])
    marker.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def cached_plans(cache_dir, channel, size_kb):
    """Validate every byte before trusting a cached release."""
    branch = cache_dir / channel / str(size_kb)
    markers = list(branch.glob("*/manifest.json"))
    valid = []
    for marker in markers:
        if marker.parent.name.startswith("."):
            continue
        try:
            manifest, _ = load_plan(marker.parent)
            if manifest["channel"] != channel or manifest["flash_kb"] != size_kb:
                continue
            if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("commit", "")):
                continue
            if manifest.get("cache_version") != 1:
                continue
            valid.append((manifest, marker.parent))
        except (OSError, ValueError, KeyError, TypeError):
            print("Ignoring invalid cached firmware: " + str(marker.parent), file=sys.stderr, flush=True)
    return sorted(valid, key=lambda item: (item[0].get("published_at") or "",
                                          item[0]["tag"], item[1].stat().st_mtime), reverse=True)


def prune_cache(cache_dir, channel, size_kb, keep):
    """Retain one complete release for this channel/capacity, after validation."""
    manifest, _ = load_plan(keep)
    if manifest["channel"] != channel or manifest["flash_kb"] != size_kb:
        raise ValueError("Cannot prune cache using a mismatched release")
    branch = (cache_dir / channel / str(size_kb)).resolve()
    if branch != cache_dir.resolve() / channel / str(size_kb):
        raise ValueError("Cache branch resolves outside its expected location")
    keep = keep.resolve()
    if keep.parent != branch:
        raise ValueError("Retained release is outside the cache branch")
    for entry in branch.iterdir():
        if entry == keep or entry.name.startswith("."):
            continue
        # Only remove release directories directly within this cache branch.
        # Never follow links into unrelated paths.
        if entry.is_symlink() or entry.resolve().parent != branch:
            raise ValueError("Unsafe link in firmware cache: " + str(entry))
        if entry.is_dir():
            shutil.rmtree(str(entry))
    log("Cache updated: keeping only " + manifest["tag"] + " for " + channel)


def trim_runs(loot_dir, current_run, keep=5):
    root = loot_dir.resolve()
    current = current_run.resolve()
    if current.parent != root or not current.name.startswith("run-"):
        raise ValueError("Run directory is outside the log directory")
    runs = []
    for path in root.glob("run-*"):
        if path.is_symlink() or path.resolve().parent != root:
            raise ValueError("Unsafe link in run logs: " + str(path))
        if path.is_dir():
            runs.append(path)
    runs.sort(key=lambda path: (path.resolve() == current, path.stat().st_mtime), reverse=True)
    # Prepared bytes are temporary; persistent firmware belongs in cache only.
    for run in runs[:keep]:
        for name, _ in MAP[2048]:
            path = run / name
            if path.exists() or path.is_symlink():
                path.unlink()
    for path in runs[keep:]:
        shutil.rmtree(str(path))


def firmware_plan(channel, size_kb, directory, cache_dir=None, offline=False):
    if cache_dir is None:
        if offline:
            raise ValueError("Offline mode requires --cache-dir")
        return download_firmware(channel, size_kb, directory)
    marker = directory / "manifest.json"
    if marker.exists():
        marker.unlink()
    candidates = cached_plans(cache_dir, channel, size_kb)
    release = commit = None
    if not offline:
        try:
            release = latest_release(channel)
            commit = api("/commits/" + quote(release["tag_name"], safe=""))["sha"]
            if not re.fullmatch(r"[0-9a-f]{40}", commit):
                raise ValueError("Invalid firmware commit")
        except (URLError, TimeoutError, OSError) as error:
            # HTTP 4xx other than rate limits indicate a real metadata error.
            if isinstance(error, HTTPError) and error.code < 500 and error.code not in (403, 429):
                raise
            log("Cannot check latest release: %s. Trying verified offline cache." % error)
            offline = True
    if offline:
        if not candidates:
            raise CacheMissing("No verified cached %s firmware for %d KB. Download online first." % (channel, size_kb))
        manifest, source = candidates[0]
        log("OFFLINE CACHE: %s; latest release could not be checked." % manifest["tag"])
        return copy_plan(source, directory, "offline cache; latest unchecked")
    for manifest, source in candidates:
        if manifest["commit"] == commit and manifest["tag"] == release["tag_name"]:
            log("Latest release confirmed; reusing verified cache: " + manifest["tag"])
            prune_cache(cache_dir, channel, size_kb, source)
            return copy_plan(source, directory, "verified cache; latest checked")
    branch = cache_dir / channel / str(size_kb)
    branch.mkdir(parents=True, exist_ok=True)
    # Publish only complete, checksum-verified entries. Failed refreshes retain
    # earlier cached releases, and temporary folders are excluded from lookup.
    with tempfile.TemporaryDirectory(prefix=".download-", dir=str(branch)) as temporary:
        staging = Path(temporary)
        download_firmware(channel, size_kb, staging, release, commit)
        load_plan(staging)
        completed = branch / (commit + "-" + staging.name[len(".download-"):])
        staging.rename(completed)
    prune_cache(cache_dir, channel, size_kb, completed)
    return copy_plan(completed, directory, "downloaded; latest checked")


def esptool_module():
    import esptool
    if esptool.__version__ != ESPTOOL_VERSION:
        raise ValueError("Install the payload dependencies (esptool " + ESPTOOL_VERSION + ")")
    return esptool


def usb_ports():
    esptool_module()
    from serial.tools.list_ports import comports
    # Match the official flasher's Silicon Labs vendor filter; never select
    # the Pager's internal CH347 or arbitrary GPS/other serial hardware.
    return sorted(p.device for p in comports() if p.vid == 0x10c4)


def hardware_info(esp):
    if esp.CHIP_NAME != "ESP8266":
        raise ValueError("Only O.MG ESP8266/ESP8285 hardware is supported")
    otp = (esp.read_reg(0x3ff0005c) >> 24) & 0xff
    if otp in (0, 1):
        raise ValueError("This O.MG device requires the official Advanced Flasher; "
                         "current WebFlasher does not support its hardware")
    size_kb = 2048 if otp == 4 else 1024  # WebFlasher getFlashID logic.
    if otp != 4:
        raise ValueError("Unrecognized O.MG flash eFuse value: 0x%02x" % otp)
    return {"flash_kb": size_kb, "mac": ":".join("%02x" % n for n in esp.read_mac())}


def pager_sync(esp):
    """Keep esptool's eight-reply handshake with a longer Pager timeout."""
    val, _ = esp.command(esp.ESP_SYNC, b"\x07\x07\x12\x20" + 32 * b"\x55",
                         timeout=SYNC_RESPONSE_TIMEOUT)
    esp.sync_stub_detected = val == 0
    for _ in range(7):
        val, _ = esp.command(timeout=SYNC_RESPONSE_TIMEOUT)
        esp.sync_stub_detected &= val == 0


def connect(port, reset, trace=False):
    esptool = esptool_module()
    # Open the port ourselves so every failure path can close it.
    import serial
    serial_port = serial.serial_for_url(port, baudrate=115200, exclusive=True, do_not_open=True)
    try:
        # Avoid asserting both control lines automatically when opening.
        serial_port.dtr = False
        serial_port.rts = False
        serial_port.open()
        # O.MG uses the ESP8266/ESP8285 protocol. Generic autodetection first
        # sends an unsupported newer-ESP32 probe and reconnects unnecessarily.
        loader_options = {"baud": 115200}
        if trace:
            loader_options["trace_enabled"] = True
        esp = esptool.CHIP_DEFS["esp8266"](serial_port, **loader_options)
        # Stock esptool allows only 100ms for the first sync response. Avoid
        # rapid retries flushing delayed/partial replies on the Pager.
        esp.sync = MethodType(pager_sync, esp)
        log("Serial sync response timeout: 1 second (all 8 replies required)")
        if reset == "web_reset":
            log("Resetting programmer using official WebFlasher timing...")
            serial_port.setDTR(False)
            serial_port.setRTS(True)
            time.sleep(2)
            serial_port.setDTR(True)
            serial_port.setRTS(False)
            time.sleep(1)
            serial_port.reset_input_buffer()
            # Preserve the signals above; don't run esptool's shorter reset.
            esp.connect(mode="no_reset", warnings=False)
        else:
            esp.connect(mode=reset)
        magic = esp.read_reg(esp.CHIP_DETECT_MAGIC_REG_ADDR)
        if magic not in esp.CHIP_DETECT_MAGIC_VALUE:
            raise ValueError("Connected chip is not a supported O.MG ESP8266/ESP8285")
        info = hardware_info(esp)
        log("Device %s, %s KB flash" % (info["mac"], info["flash_kb"]))
        return esp, info, serial_port
    except BaseException:
        serial_port.close()
        raise


def write_segment(esp, data, offset, name):
    blocks = esp.flash_begin(len(data), offset)
    block_size = esp.FLASH_WRITE_SIZE
    last_percent = -1
    for seq in range(blocks):
        block = data[seq * block_size:(seq + 1) * block_size].ljust(block_size, b"\xff")
        esp.flash_block(block, seq)
        percent = (seq + 1) * 100 // blocks
        if percent // 10 != last_percent // 10:
            log("%s: %d%%" % (name, percent))
            last_percent = percent
    actual = esp.flash_md5sum(offset, len(data))
    if actual.lower() != hashlib.md5(data).hexdigest():
        raise ValueError("Flash verification failed: " + name)
    log("Verified " + name)


def flash_plan(esp, manifest, segments, pre_erase=False):
    validate_segments(segments, manifest["flash_kb"])
    if not esp.IS_STUB:
        esp = esp.run_stub()
    # Keep writes within each layout sector even for small files. The standard
    # stub's 16KB blocks could otherwise pad over neighboring config sectors.
    esp.FLASH_WRITE_SIZE = 2048
    if pre_erase:
        log("Pre-erasing the WebFlasher range (0x00000..0xf9bff)")
        total = (1022976 + 16383) // 16384
        for chunk, offset in enumerate(range(0, 1022976, 16384), 1):
            length = min(16384, 1022976 - offset)
            write_segment(esp, b"\xff" * length, offset, "pre-erase %d/%d" % (chunk, total))
    for s in segments:
        log("Writing %s at 0x%x (%d bytes)" % (s["name"], s["offset"], len(s["data"])))
        write_segment(esp, s["data"], s["offset"], s["name"])
        time.sleep(1)
    esp.flash_begin(0, 0)
    esp.flash_finish(reboot=False)
    log("SUCCESS: all firmware segments verified. Unplug the programmer and "
        "connect your O.MG device to a normal USB port.")


def session(args):
    """Keep one port open from connection through on-device confirmation."""
    ready = args.directory / "ready"
    decision = args.directory / "decision.json"
    args.directory.mkdir(parents=True, exist_ok=True)
    cache_request = args.directory / "cache-request.json"
    cache_decision = args.directory / "cache-decision.json"
    for marker in (ready, decision, args.directory / "manifest.json", cache_request, cache_decision):
        if marker.exists():
            marker.unlink()
    if args.channel == "v4" and not args.elite_confirmed:
        raise ValueError("v4 requires an Elite device confirmation")
    esp, info, serial_port = connect(args.port, args.reset)
    phase = "RAM stub upload"
    try:
        esp = esp.run_stub()
        phase = "firmware download and validation"
        try:
            manifest = firmware_plan(args.channel, info["flash_kb"], args.directory,
                                     getattr(args, "cache_dir", None), getattr(args, "offline", False))
        except CacheMissing:
            if not getattr(args, "offline", False):
                raise
            log("No verified cached %s firmware. Waiting for download or exit choice." % args.channel)
            cache_request.write_text(json.dumps(dict(channel=args.channel, flash_kb=info["flash_kb"])), encoding="utf-8")
            deadline = time.monotonic() + 900
            while not cache_decision.exists():
                if time.monotonic() >= deadline:
                    raise ValueError("Cache choice timed out; no firmware written")
                time.sleep(0.25)
            choice = json.loads(cache_decision.read_text(encoding="utf-8"))
            if choice.get("action") == "cancel":
                log("Cancelled; no firmware written.")
                return
            if choice.get("action") != "download":
                raise ValueError("Invalid cache choice")
            manifest = firmware_plan(args.channel, info["flash_kb"], args.directory,
                                     args.cache_dir, offline=False)
        manifest.update(device=info, port=args.port)
        (args.directory / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        log("READY: files validated; serial connection remains open. Waiting for confirmation.")
        ready.write_text("ready\n", encoding="ascii")
        phase = "user confirmation"
        deadline = time.monotonic() + 900
        while not decision.exists():
            if time.monotonic() >= deadline:
                raise ValueError("Confirmation timed out after 15 minutes; no firmware written")
            time.sleep(0.25)
        approval = json.loads(decision.read_text(encoding="utf-8"))
        if approval.get("action") == "cancel":
            log("Cancelled before flash writes.")
            return
        if approval.get("action") != "flash" or type(approval.get("pre_erase", False)) is not bool:
            raise ValueError("Invalid flash confirmation")
        manifest, segments = load_plan(args.directory)
        if hardware_info(esp) != info:
            raise ValueError("Device changed during confirmation; refusing to flash")
        phase = "firmware writing or verification"
        flash_plan(esp, manifest, segments, approval.get("pre_erase", False))
    except Exception as error:
        suffix = "; no firmware writes started" if phase != "firmware writing or verification" else ""
        raise ValueError("Failure during %s%s: %s" % (phase, suffix, error)) from error
    finally:
        serial_port.close()
        log("Serial connection closed.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ports", help="List Silicon Labs USB programmer ports")
    p = sub.add_parser("trim-runs", help="Retain the five latest run logs and remove temporary firmware")
    p.add_argument("--loot-dir", type=Path, required=True)
    p.add_argument("--current-run", type=Path, required=True)
    p = sub.add_parser("cache-info", help="Show verified cached tag without serial or network access")
    p.add_argument("--cache-dir", type=Path, required=True)
    p.add_argument("--channel", choices=("v3", "v4"), required=True)
    p.add_argument("--flash-kb", type=int, choices=(1024, 2048), default=2048)
    probe = sub.add_parser("probe", help="Diagnose serial connection only; no firmware or stub writes")
    probe.add_argument("--port", required=True)
    probe.add_argument("--reset", choices=("web_reset", "default_reset", "no_reset"), default="web_reset")
    probe.add_argument("--trace", action="store_true", help="Record serial packets for diagnosis")
    for command in ("prepare", "flash", "session"):
        p = sub.add_parser(command)
        p.add_argument("--directory", type=Path, required=True)
        p.add_argument("--port", required=True)
        p.add_argument("--reset", choices=("web_reset", "default_reset", "no_reset"), default="web_reset")
        if command in ("prepare", "session"):
            p.add_argument("--channel", choices=("v3", "v4"), required=True)
            p.add_argument("--cache-dir", type=Path)
            p.add_argument("--offline", action="store_true")
            if command == "session":
                p.add_argument("--elite-confirmed", action="store_true")
        else:
            p.add_argument("--yes", action="store_true", help="Confirm firmware/config replacement")
            p.add_argument("--elite-confirmed", action="store_true")
            p.add_argument("--pre-erase", action="store_true")
    p = sub.add_parser("download", help="Download/validate only; never opens serial")
    p.add_argument("--channel", choices=("v3", "v4"), required=True)
    p.add_argument("--flash-kb", type=int, choices=(1024, 2048), default=2048)
    p.add_argument("--directory", type=Path, required=True)
    p.add_argument("--cache-dir", type=Path)
    p.add_argument("--offline", action="store_true")
    p = sub.add_parser("summary")
    p.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "trim-runs":
        trim_runs(args.loot_dir, args.current_run)
    elif args.command == "cache-info":
        cached = cached_plans(args.cache_dir, args.channel, args.flash_kb)
        log(cached[0][0]["tag"] if cached else "none")
    elif args.command == "probe":
        _, _, serial_port = connect(args.port, args.reset, trace=args.trace)
        try:
            log("PROBE SUCCESS: serial sync and hardware identification passed; no firmware or stub written.")
        finally:
            serial_port.close()
            log("Serial connection closed.")
    elif args.command == "session":
        session(args)
    elif args.command == "ports":
        for port in usb_ports():
            log(port)
    elif args.command == "download":
        firmware_plan(args.channel, args.flash_kb, args.directory, args.cache_dir, args.offline)
    elif args.command == "summary":
        manifest, _ = load_plan(args.directory)
        log("%s | %d KB | %s | %s" % (manifest["tag"], manifest["flash_kb"],
            manifest.get("device", {}).get("mac", "download only"), manifest.get("source", "prepared firmware")))
    elif args.command == "prepare":
        marker = args.directory / "manifest.json"
        if marker.exists():
            marker.unlink()
        esp, info, serial_port = connect(args.port, args.reset)
        serial_port.close()
        manifest = firmware_plan(args.channel, info["flash_kb"], args.directory, args.cache_dir, args.offline)
        manifest["device"] = info
        manifest["port"] = args.port
        marker.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        log("READY: downloads and checks completed; no flash writes performed.")
    elif args.command == "flash":
        manifest, segments = load_plan(args.directory)
        if not args.yes:
            raise ValueError("Flashing replaces configuration and payload slots; --yes is required")
        if manifest["channel"] == "v4" and not args.elite_confirmed:
            raise ValueError("v4 requires an Elite device; --elite-confirmed is required")
        if manifest.get("port") != args.port or "device" not in manifest:
            raise ValueError("Run prepare with this programmer port before flashing")
        esp, info, serial_port = connect(args.port, args.reset)
        try:
            if info != manifest["device"] or info["flash_kb"] != manifest["flash_kb"]:
                raise ValueError("Device changed since preparation; refusing to flash")
            flash_plan(esp, manifest, segments, args.pre_erase)
        finally:
            serial_port.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Interrupted. If flashing had started, reconnect and run the payload again.")
        sys.exit(130)
    except Exception as error:
        log("ERROR: " + str(error))
        sys.exit(1)
