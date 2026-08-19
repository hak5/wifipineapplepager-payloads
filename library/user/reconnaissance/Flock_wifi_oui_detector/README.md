# Flock Detector

**Device:** WiFi Pineapple Pager
**Type:** User payload (reconnaissance)
**Version:** 3.0.2
**Author:** Liminal

---

## Overview

Flock Detector is a passive WiFi reconnaissance payload that scores nearby devices against a configurable list of MAC-prefix (OUI) signatures, purpose-built for identifying suspected Flock Safety hardware (ALPR cameras, LTE/WiFi modules, and related infrastructure) from their wireless fingerprint. Matches are scored, not just flagged — signal strength, SSID content, and sustained presence all contribute to a 0–100 confidence score, and only devices crossing a configurable threshold trigger an operator alert (LED, vibration, on-screen `ALERT`). Everything below threshold is still logged, so signatures can be tuned against real-world candidate data instead of guesswork.

As of v3.0.0, this payload no longer opens its own capture. Earlier versions ran an independent `tcpdump` process against `wlan1mon` and reconstructed frame type, SSID, RSSI, frequency, and channel by scraping tcpdump's text output with `sed`/`grep`. That worked, but duplicated capture the Pineapple Recon engine was already doing on the same radio, and was fragile against tcpdump's output formatting. v3.x instead polls Recon's own `recon.db` (SQLite) on an interval and scores whatever changed since the last poll — Recon's capture and parsing is already battle-tested, so this payload only has to read structured rows out of it.

---

## Requirements

- WiFi Pineapple Pager with Recon actively hopping. This payload does not start a Recon session on its own beyond a best-effort `PINEAPPLE_HOPPING_START` attempt at launch — if `recon.db` is empty or stale, start a Recon scan from the Pager UI first.
- `sqlite3` (present on stock firmware; verify with `which sqlite3`)
- Optional: a USB GPS adapter + `gpsd`/`gpspipe` for location-tagged detections. The payload runs without one — GPS fields simply log as `0.000000,0.000000`.
- A `flock_signatures.conf` file alongside `payload.sh` (format below). The payload will refuse to start without at least one valid signature.

---

## Installation

```bash
scp -r flock_detector root@172.16.42.1:/root/payloads/user/reconnaissance/
```

The directory should contain:

```
flock_detector/
  payload.sh               # the detector
  flock_signatures.conf    # your MAC-prefix / score / description list
  README.md                # this file
```

No additional packages are required on stock firmware.

---

## Configuration

### Signature file (`flock_signatures.conf`)

One entry per line:

```
MAC_PREFIX|SCORE|DESCRIPTION
```

```
74:4C:A1|50|Lite-On WCBN3510A suspected Flock module
70:C9:4E|80|Known Flock Falcon
```

- `MAC_PREFIX` is the first three octets (`XX:XX:XX`), case-insensitive.
- `SCORE` is an integer 0–100 — this is the *base* score before bonuses; it does not need to reach `ALERT_THRESHOLD` on its own.
- Blank lines and lines starting with `#` are ignored.
- Duplicate prefixes keep whichever score is higher; the loser is logged as a duplicate at startup, not silently dropped.
- Malformed lines (bad prefix format, non-numeric score, missing description, extra fields) are skipped individually and logged with the offending line number — one bad line does not stop the whole file from loading.

### Key tunables (top of `payload.sh`)

| Variable | Default | Effect |
|---|---|---|
| `ALERT_THRESHOLD` | `50` | Score required to escalate from candidate to confirmed detection / operator alert |
| `POLL_INTERVAL_SECONDS` | `3` | How often `recon.db` is queried for new rows |
| `AP_FRAME_BONUS` | `10` | Added when the observation is infrastructure-side (not a client probe request) |
| `PROBE_REQUEST_BONUS` | `0` | Added when the observation is a client probe request |
| `SSID_FLOCK_BONUS` | `30` | Added if the observed SSID text contains "FLOCK" (case-insensitive) |
| `RSSI_NEAR_THRESHOLD` / `RSSI_NEAR_BONUS` | `-65` / `5` | Bonus for moderate signal strength |
| `RSSI_STRONG_THRESHOLD` / `RSSI_STRONG_BONUS` | `-50` / `15` | Bonus for strong signal strength |
| `REPEAT_SEEN_THRESHOLD` / `REPEAT_SEEN_BONUS` | `3` / `15` | Bonus once an infrastructure-side MAC has appeared in this many poll cycles |
| `ALERT_COOLDOWN` | `120` | Seconds before the same MAC can trigger another LED/tone/`ALERT` |
| `CANDIDATE_LOG_INTERVAL` / `DETECTION_LOG_INTERVAL` | `60` / `30` | Minimum seconds between repeated CSV log rows for the same MAC |
| `GPS_ENABLED` | `1` | Set to `0` to skip gpsd/gpspipe entirely |
| `USE_PINEAPPLE_SET_BANDS` / `RECON_BANDS` | `0` / `"2 5"` | If enabled, restricts Recon's hop to the listed bands via `PINEAPPLE_SET_BANDS` at startup |
| `RECON_STALE_THRESHOLD` | `90` | Seconds since the last Recon capture before startup logs a "data looks stale" warning |

---

## Usage

1. Confirm Recon is actively scanning (start one from the Pager UI on a fresh boot — see Known Limitations).
2. Launch **Flock Detector** from **Payloads → reconnaissance**.
3. A green LED flash and success tone confirm initialization completed and polling has started.
4. Matches below `ALERT_THRESHOLD` are written quietly to the candidate log — no LED, tone, or interruption.
5. A score at or above `ALERT_THRESHOLD` triggers: red LED, warning tone, and an on-screen `ALERT` with MAC, RSSI, channel, score, and GPS coordinates (if available).
6. Stop via the Pager's cancel button. The payload flushes device state and stops any GPS subprocess cleanly on exit.

---

## How It Works

### Ingestion

Every `POLL_INTERVAL_SECONDS`, the payload:

1. Copies `recon.db` to a runtime snapshot (`/tmp/flock_detector/recon_snapshot.db`) rather than querying the live file directly, since Recon holds it open for continuous writes.
2. Runs one query joining `ssid` to `wifi_device`, filtered to rows with `time` newer than the last poll's cursor.
3. Scores every returned row through the same signature/bonus engine described below.
4. Advances the cursor to the newest `time` value actually seen, so nothing is reprocessed and nothing between polls is skipped.

### Scoring model

| Component | Points | Condition |
|---|---|---|
| OUI base score | 0–100 | From `flock_signatures.conf`, matched on the first three octets |
| Frame-origin bonus | `AP_FRAME_BONUS` or `PROBE_REQUEST_BONUS` | Infrastructure-side observation vs. client probe request |
| SSID bonus | `SSID_FLOCK_BONUS` | SSID text contains "FLOCK" |
| RSSI bonus | `RSSI_NEAR_BONUS` / `RSSI_STRONG_BONUS` | Signal strength crosses the near/strong thresholds |
| Repeat bonus | `REPEAT_SEEN_BONUS` | Infrastructure-side MAC seen in ≥ `REPEAT_SEEN_THRESHOLD` poll cycles |

Total is capped at `MAX_SCORE` (100). A device only enters scoring at all if its OUI base score or SSID bonus is nonzero — ordinary unmatched traffic never reaches the scoring engine.

Classification: `≥95` → **HIGH CONFIDENCE**, `≥ALERT_THRESHOLD` → **LIKELY**, otherwise **CANDIDATE** (logged only, no alert).

### Logging and cooldowns

- **Candidate log** (below threshold): at most once per `CANDIDATE_LOG_INTERVAL` per MAC — for tuning signatures against real traffic without flooding the CSV.
- **Detection log** (at/above threshold): at most once per `DETECTION_LOG_INTERVAL` per MAC.
- **Operator alert** (LED/tone/`ALERT`): at most once per `ALERT_COOLDOWN` per MAC, independent of the logging cadence above.
- Per-device state (first seen, last seen, packet count, best RSSI, last SSID) is persisted to `device_state.csv` every 15 seconds and restored on relaunch, so a payload restart doesn't reset a device's history to zero.

### GPS tagging

If `GPS_ENABLED=1` and a GPS device is present, `gpspipe` streams TPV fixes to a cache file that every logged event reads its latitude/longitude from. Without a fix, events log `0.000000,0.000000` rather than failing.

---

## Loot Structure

```
/root/loot/flock_detector/
  detections_YYYY-MM-DD.csv    # confirmed (>= ALERT_THRESHOLD) detections
  candidates_YYYY-MM-DD.csv    # below-threshold candidates, for signature tuning
  device_state.csv             # persistent per-MAC tracking, survives restarts
  recon_poll_TIMESTAMP.log     # sqlite3 stderr -- only written on query errors
```

### CSV columns

**`detections_*.csv`**: `Timestamp, FrameType, MAC, BSSID, SSID, RSSI, Frequency, Channel, Score, Latitude, Longitude, Description, NativePackets`

**`candidates_*.csv`**: `Timestamp, FrameType, MAC, BSSID, SSID, RSSI, Frequency, Channel, Score, Threshold, Observations, BestRSSI, Latitude, Longitude, Description, Reasons, NativePackets`

`NativePackets` is Recon's own `wifi_device.packets` counter — informational only, not fed into scoring. `Observations` counts poll cycles this MAC has scored in, not raw frames (see Known Limitations).

---

## Data Sources

All data comes from `recon.db`, which the Pineapple Recon engine maintains natively — no duplicate capture logic.

| Table | Columns used |
|---|---|
| `wifi_device` | `hash` (join key), `mac`, `packets` |
| `ssid` | `hash`, `wifi_device` (FK), `type`, `bssid`, `ssid`, `hidden`, `time`, `signal`, `freq`, `channel` |

`recon.db` path is resolved from `/root/recon/recon.db` or `/mmc/root/recon/recon.db` (whichever exists first — on units with an SD card these are typically the same underlying file).

**MAC/BSSID storage format:** confirmed on-device, `wifi_device.mac` and `ssid.bssid` are stored as raw 12-character hex with **no colons and no separators** (e.g. `B87BD4D7A0B1`, not `B8:7B:D4:D7:A0:B1`). This payload's polling query reconstructs standard colon-separated form via SQL before any bash code sees it. Any payload reading this table directly and comparing against colon-separated MACs will silently match nothing — this cost real debugging time during development and is documented here so it doesn't repeat.

**`ssid.type` handling:** `4` is confirmed to represent a client-originated probe request. This payload treats every other value as infrastructure-side evidence (beacon, probe-response, or any other row type this schema may use) rather than allowlisting a fixed set of integers — some third-party documentation of this schema references a distinct `type=5` for probe-response that was not independently confirmed on this firmware, so the safer general rule is used instead of a narrow allowlist.

---

## Known Limitations

- **No association/reassociation/deauth scoring.** The v2.x tcpdump-based version distinguished and scored association/reassociation frames; `recon.db`'s `ssid` table does not retain that distinction, so there is no equivalent in v3.x. This was a deliberate tradeoff for a simpler, more robust ingestion path.
- **`Observations`/repeat bonus is counted in poll cycles, not raw frames.** At the default 5-second interval, `REPEAT_SEEN_THRESHOLD=3` means "still present after ~15 seconds of polling." If you significantly change `POLL_INTERVAL_SECONDS`, revisit this threshold.
- **Requires Recon to already be hopping.** The payload makes a best-effort `PINEAPPLE_HOPPING_START` call at startup if it detects a stale/empty database, but this is not guaranteed to succeed on every firmware version — start a Recon scan manually from the Pager UI if detections aren't appearing and the startup log shows a stale-data warning.
- **MAC randomization defeats OUI matching.** A client device presenting a randomized MAC will not match a signature keyed to its factory address, regardless of capture method.
- **Requires `sqlite3`.** The payload checks for it at startup and fails initialization with a clear message if it's missing, rather than failing silently later.

---

## Credits

- **Liminal** — payload author, detection design, OUI/signature research

---

## Disclaimer

This tool is for authorized security research and passive monitoring in environments you own or have explicit permission to assess. Ensure compliance with all applicable local and international laws. The authors claim no responsibility for unauthorized or unlawful use.

---

## References

| Resource | URL |
|---|---|
| WiFi Pineapple Pager docs | https://documentation.hak5.org/wifi-pineapple-pager |
| Recon engine overview | https://docs.hak5.org/wifi-pineapple-pager/pineapple-functions/recon/ |
| SET_BANDS command reference | https://documentation.hak5.org/wifi-pineapple-pager/wifi-pineapple-commands/set_bands.md |
| Payload types overview | https://documentation.hak5.org/wifi-pineapple-pager/payloads-1/introduction-to-payloads |
| Payload repository | https://github.com/hak5/wifipineapplepager-payloads |
