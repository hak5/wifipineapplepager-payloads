# Flock You

A WiFi Pineapple Pager payload for passively detecting Flock Safety surveillance devices via BLE (Bluetooth Low Energy) scanning.

## What It Does

Flock You continuously scans for BLE advertisements from Flock Safety infrastructure — ALPR cameras, Penguin backup batteries, and Pigvision devices. When a device is detected, it logs the MAC address and device name, vibrates the Pager, flashes an LED, and displays a color-coded entry on screen.

The scanner runs continuously until you press the Pager's cancel button. All detections are saved to a timestamped log file in `/root/loot/flock_you/`.

### Detection Targets

| Device | BLE Name Pattern | Log Color |
|--------|-----------------|-----------|
| Flock FS Ext Battery | `FS Ext Battery` | Yellow |
| Flock Penguin | `Penguin-*` | Green |
| Pigvision | `Pigvision` | Magenta |
| Other Flock devices | `*flock*` | Cyan |

## Installation

Copy the payload directory to your Pager via SCP:

```bash
scp -r flock_you root@172.16.52.1:/root/payloads/user/reconnaissance/
```

The directory should contain:
```
flock_you/
  payload.sh        # The scanner payload
  oui_list.txt      # OUI fingerprint database (for future WiFi expansion)
  README.md         # This file
```

No additional packages are required. The Pager's built-in `hcitool` handles BLE scanning.

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
4. Deduplicates against an in-memory list of previously seen MAC+Name pairs
5. Logs new detections to screen (with color) and to a loot file
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
