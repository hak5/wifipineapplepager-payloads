# Flock You

A WiFi Pineapple Pager payload for passively detecting Flock Safety surveillance devices via BLE (Bluetooth Low Energy) scanning.

## What It Does

Flock You continuously scans for BLE advertisements from Flock Safety infrastructure — ALPR cameras, Penguin backup batteries, and Pigvision devices. When a device is detected, it logs the MAC address, the signal(s) that matched, a label, and **GPS coordinates**, vibrates the Pager, flashes an LED, and displays a color-coded entry on screen.

The scanner runs continuously until you press the Pager's cancel button. All detections are saved to a timestamped log file in `/root/loot/flock_you/`.

### Wardrive mode + diagnostic log (v9.18+)

BLE range is short (~10–30 m). Driving past a pole camera you're in range for only a few seconds, so v9.18 is tuned for drive-bys:

- **Near-continuous scanning.** The adapter is brought up **once** at startup (not reset every cycle) and there is **no inter-cycle sleep**, raising the scan duty cycle from ~67% to ~90%. Scan windows are a short 8 s so a brief fly-by is more likely to land inside an active scan. If the adapter captures nothing for two cycles it self-resets.
- **All-advert diagnostic log.** Every advert seen — not just Flock matches — is recorded to `flock_alladv_<ts>.csv` as `time,mac,manuf_id,rssi,name`. Drive past a *known* camera and this log shows exactly what it broadcasts (manufacturer ID + signal strength). It's the definitive way to tell a detection gap from a camera that simply emits no usable BLE. Detections also now carry `RSSI` (signal strength → proximity).

> **BLE vs WiFi for cameras.** A Falcon *camera* uploads over a cellular (Sierra Wireless LTE) modem, not WiFi; the confirmed *BLE* emitters are the Penguin battery and Pigvision. When mapping while driving the WiFi path (`wardrive_activate` → WiGLE, then `loot/flock_hits.sh` OUI matching) is the better bet of the two — but see Field results below: a deployed camera may emit neither WiFi nor BLE, so run both and don't assume a silent result means "no camera."

> **Confirming a camera's real signature.** To capture what a *known* Flock camera actually broadcasts (SSID/OUI/BLE) and add it to `oui_list.txt`, follow the stationary baseline-subtraction procedure in [`GROUND_TRUTH_CAPTURE.md`](GROUND_TRUTH_CAPTURE.md). A drive-by is the worst case for this — park in range instead.

### Field results and v9.19 fixes

**Detection is not yet reproduced.** An earlier note here claimed a Falcon was caught by its **OUI** (with **zero XUNTONG `0x09C8` across 1,477 devices**). Repeated attempts since have failed to reproduce it: two drive-bys and one stationary ~6-minute capture parked within ~30 m of a *confirmed* Flock camera on a solid GPS fix, plus several weeks of routine driving — **no Flock advertising observed on any channel** in that time (zero OUI matches, zero `0x09C8`, no `Flock-`/`Falcon`/`Solar`/`Cam` SSID, zero BLE detections). The scanner was demonstrably working (it logged consumer APs down to −79 dBm and 800+ BLE devices at the camera site), so the likeliest reading is that the cameras emitted nothing to catch.

**Working hypothesis: operating Falcons are cellular-only.** The Falcon V2 carries a Sierra Wireless LTE modem and phones home over cellular; its Lite-On WiFi and BLE appear to be used only during on-site install/maintenance, not steady-state. If so, the 5 `FLOCK_VERIFIED` OUIs below — sourced from WiGLE crowd data — likely captured cameras *mid-install*, and passive on-device detection has a hard ceiling for deployed units.

Another possibility, not exclusive of the first: with recent public scrutiny over privacy and unauthorized use, deployed units may have had WiFi/BLE **deliberately disabled** to reduce their RF detectability. Either way the practical result is the same — a deployed Falcon may broadcast nothing to catch. Crowd-sourced mapping ([deflock.me](https://deflock.me)) is the more reliable locator until a camera is caught actually beaconing. The `0x09C8`-vs-OUI point still stands: if anything catches a Falcon it's the OUI, not the manufacturer ID. To try to reproduce a real detection, see [`GROUND_TRUTH_CAPTURE.md`](GROUND_TRUTH_CAPTURE.md).

The 1,477-device drive also exposed three defects, fixed in v9.19:

| Symptom | Cause | Fix |
|---|---|---|
| Log flooded with `Set scan parameters failed: I/O error` (786 in one run) | Killing `lescan` leaves LE scanning enabled, so the next cycle can't set scan params | Explicit `LE Set Scan Enable=0` between cycles (fast — keeps the duty cycle) |
| Alert buzzed ~30 min after the sighting | Per-device dedup grepped a growing seen-file — O(n²), **measured 79 s per cycle** at 1,477 devices | Single awk pass (**~0 ms**); Flock hits processed *before* the bulk diagnostic write |
| Detection timestamps stale by minutes | Timestamp computed once per cycle | Timestamp taken at the moment of detection |

**Two platform traps worth knowing** (both cost real debugging time):

- The Pager UI runs a payload from a **copy at `/tmp/payload-<id>.sh`** — so `pkill -f '<name>/payload.sh'` never matches a UI-launched instance, and a payload left running from an earlier session is easy to miss. It will hold the BT adapter and skew any test.
- This payload deliberately has **no EXIT/TERM trap**. Background subshells (`hcidump ... &`) inherit an EXIT trap and would delete the live dedup state every cycle; and a TERM trap makes the payload *survive* being killed (bash resumes the loop after a trapped signal), leaving immortal instances fighting over the adapter. Temp files are per-instance (`$$`) and cleaned at startup instead.

### Detection: three signals (v9.17+)

Earlier versions matched only the BLE **device name**. Most real Flock adverts carry *no name* (they broadcast a MAC + manufacturer data), so name-only detection missed them. v9.17 checks three signals and alerts if **any** fire:

| Signal | What it matches | How | Color |
|--------|-----------------|-----|-------|
| **MANUF** | XUNTONG manufacturer ID `0x09C8` in the BLE advertising data — the strongest Flock tell | `hcidump --raw`, byte signature `FF C8 09` | Magenta |
| **OUI** | MAC prefix in `oui_list.txt` (Lite-On chipset + verified Flock/Falcon/Battery prefixes) | `hcidump --raw` MAC + prefix lookup | Yellow |
| **NAME** | BLE name substring: `FS Ext Battery`, `Penguin`, `Pigvision`, `Flock` | `hcitool lescan` (v9.16 behavior) | Cyan |

Each cycle runs `hcidump --raw` and `hcitool lescan` in parallel, then merges hits by MAC (combining tags when more than one signal fires). Note: OUI matching only works on devices advertising a fixed public MAC — randomized BLE addresses won't match an OUI, but the manufacturer-ID signal still catches them.

### GPS Tagging (v9.16+)

Each detection is tagged with a live GPS fix pulled from `gpsd` (via `gpspipe -w` + `jq`, the same method used by `gps-checker`). One fix is read per scan cycle and applied to every detection in that cycle — position doesn't change meaningfully within a ~12 second scan window.

- With a 2D/3D fix, the detection line ends with `lat,lon` and the CSV row is populated.
- With no fix (no receiver, or no satellite lock yet), the detection is tagged `NO_GPS` and the CSV lat/lon columns are left empty — the scanner keeps running normally.

Two files are written per run in `/root/loot/flock_you/`:

| File | Format |
|------|--------|
| `flock_hcitool_<timestamp>.txt` | Human-readable log: `DECT: HH:MM:SS \| MAC \| SIGNALS \| label \| RSSI:xx \| lat,lon` |
| `flock_gps_<timestamp>.csv` | `time,mac,name_or_label,signals,rssi,lat,lon` — Flock hits, ready for mapping |
| `flock_alladv_<timestamp>.csv` | `time,mac,manuf_id,rssi,name` — **every** advert seen (diagnostic, v9.18+) |

For a GPS-tagged drive, start `wardrive_activate` (or `gps-checker`) first so `gpsd` is configured and has a fix before you run Flock You.

## Installation

Copy the payload directory to your Pager via SCP:

```bash
scp -r flock_you root@172.16.52.1:/root/payloads/user/reconnaissance/
```

The directory should contain:
```
flock_you/
  payload.sh          # The scanner payload
  oui_list.txt        # OUI fingerprint database (used for OUI-signal matching)
  README.md           # This file
  flock_lab_sim.py    # ESP32 lab simulator — NOT run on the Pager (see below)
  LAB_SIMULATOR.md    # Setup guide for the lab simulator
  GROUND_TRUTH_CAPTURE.md  # Procedure to capture a known camera's real signature
```

No additional packages are required. The Pager's built-in `hcitool` and `hcidump` handle BLE scanning. `flock_lab_sim.py` and `LAB_SIMULATOR.md` are inert on the Pager — copying them along does no harm, but only `payload.sh` runs.

> **Keep this a flat folder.** The Pager's payload scanner treats any directory
> *containing a subdirectory* as a *category* rather than a payload, which hides it
> from the on-device list. Do **not** create subfolders inside `Flock_Detect/` —
> keep everything as flat files. The companion ESP32 lab simulator
> (`flock_lab_sim.py` + `LAB_SIMULATOR.md`) runs on separate Arduino hardware, not
> the Pager; it lives here as flat files, alongside the payload, for exactly this
> reason (a nested `flock-lab-sim/` folder would hide the payload). See
> `LAB_SIMULATOR.md` to flash and run it.

## Usage

1. Navigate to **Payloads** on the Pager dashboard
2. Select **Flock You** from the reconnaissance category
3. The scan starts immediately with a color key legend on screen
4. Detections appear in real time with color coding, vibration, and LED flash
5. Press the **cancel button** to stop — the Pager will ask to confirm

## How It Works

Each scan cycle:

1. Resets the BLE adapter (`hci0`) to ensure a clean state
2. Runs `hcitool lescan --duplicates` for ~12 seconds
3. Greps the results for known Flock device name patterns
4. Reads one GPS fix from `gpsd` for the cycle (or `NO_GPS` if unavailable)
5. Deduplicates against an in-memory list of previously seen MAC+Name pairs
6. Logs new detections to screen (with color), to the `.txt` loot file, and to the `.csv`
6. Fires haptic vibration and LED flash on detection
7. Waits 3 seconds, then repeats

## The Story Behind This Project

This payload started as a conversation about building an OUI-based surveillance device detector for the WiFi Pineapple Pager — inspired by the OUISpy concept of fingerprinting devices by their MAC address prefixes.

### The Hard Part: Learning the Pager

The WiFi Pineapple Pager is a new device with limited documentation for payload development. The journey from idea to working code involved solving a chain of platform-specific problems:

**Silent crashes (v1–v3):** Early versions used bash features that the Pager's environment couldn't handle — associative arrays (`declare -A`), Perl-compatible regex (`grep -P`), massive inline string variables, and multi-assignment `local` declarations. The payload would crash instantly with no error output, making debugging blind.

**File path resolution (v4):** The `oui_list.txt` companion file couldn't be found because `$(dirname "$0")` didn't resolve as expected in the Pager's payload execution context. This was eventually solved with fallback path detection, though later testing with other working payloads (Blue Clues) confirmed `dirname "$0"` does work — the earlier failures were caused by the crashes masking the real problem.

**Wrong interface name (v4–v4.1):** WiFi scanning targeted `wlan1`, which doesn't exist. The Pager's PineAP engine pre-creates `wlan1mon` in monitor mode. This was discovered by SSH-ing into the device and running `iw dev`.

**Exit loop confusion (OUI-SPY variants):** Multiple attempts at building a stop mechanism — signal traps, stop files, button press racing, confirmation dialogs between cycles — were all unnecessary. The Pager UI has a built-in cancel button that prompts "Stop payload?" and kills the process. The earlier payloads couldn't be stopped because they were crashing, not because they lacked an exit mechanism.

**The breakthrough:** A working reference payload (Blue Clues by Brandon Starkweather) showed the correct patterns — `PROMPT` for info screens, `NUMBER_PICKER` for config, direct sysfs GPIO/LED control, `hcitool inq` for classic Bluetooth, and timed or continuous loops with `exit 0`. Applying these patterns to the Flock detection logic produced the working v9.15.

### What We Learned About Pager Payloads

For anyone else writing Pager payloads, these lessons were hard-won:

- Payloads are bash scripts with DuckyScript commands (`LOG`, `PROMPT`, `NUMBER_PICKER`, etc.) available as executables in PATH
- `LOG color "message"` works — colors include yellow, green, magenta, cyan
- `while true` is the correct pattern for continuous scans — the Pager cancel button handles termination
- Direct hardware access works: `/sys/class/gpio/vibrator/value` for haptics, `/sys/class/leds/` for LEDs
- The Pager has a built-in OUI database at `/lib/hak5/oui.txt`
- BLE interface is `hci0`, WiFi monitor interface is `wlan1mon` (not `wlan1`)
- Always end with `exit 0` or the Pager reports an error
- Keep it simple — complex bash features and subshell tricks are unreliable

## OUI List

The included `oui_list.txt` contains 69 MAC prefix entries for WiFi-based detection (for future expansion beyond BLE):

- **5 Flock Verified** — Camera OUIs confirmed from WiGLE wardriving data
- **5 Flock Battery** — Penguin battery OUIs from WiGLE BLE data
- **55 Lite-On Technology** — Flock Falcon V2 uses the WCBN3510A WiFi chipset
- **3 Sierra Wireless** — Flock LTE modem
- **2 Lantronix** — Flock system-on-module

These were compiled from real-world field data in the colonelpanichacks/flock-you datasets and cross-referenced with FCC filings and hardware teardown research.

## Data Sources

| Source | Contribution |
|--------|-------------|
| [colonelpanichacks/flock-you](https://github.com/colonelpanichacks/flock-you) | WiGLE wardriving datasets, BLE device captures, Pigvision location data |
| [deflock.me](https://deflock.me) | Crowdsourced ALPR camera location database |
| [GainSec](https://github.com/gainsec) | ShotSpotter Raven BLE service UUID configurations |
| Ryan O'Horo | FCC filing research, Falcon V2 hardware teardown (Lite-On WCBN3510A, Sierra RC76B, Lantronix Open-Q 624A) |
| Will Greenberg (@wgreenberg) | BLE manufacturer ID research (XUNTONG Company ID 0x09C8 for Flock Penguin batteries) |
| Brandon Starkweather | Blue Clues reference payload — provided the working Pager payload patterns |

## Contributors

- **colonelpanichacks** — Project creator, Flock research datasets, field testing
- **Claude (Anthropic)** — Payload development, OUI database compilation, Pager documentation research
- **Grok (xAI)** — Early payload prototyping, OUI-SPY detector variants
- **Brandon Starkweather** — Blue Clues payload (reference implementation that unlocked the correct Pager patterns)

## Disclaimer

This tool is for authorized security research and educational purposes only in controlled lab environments. Passive BLE monitoring in your own environment only. Ensure compliance with all applicable local and international laws. The authors claim no responsibility for unauthorized or unlawful use.

## License

Community payload for the [Hak5 WiFi Pineapple Pager Payload Repository](https://github.com/hak5/wifipineapplepager-payloads).
