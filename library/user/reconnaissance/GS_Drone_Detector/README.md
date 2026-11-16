# GS Drone Detector — WiFi Pineapple Pager

**Author:** GhostStrats  
**Category:** Reconnaissance  
**Target:** Hak5 WiFi Pineapple Pager  
**Project:** https://github.com/Ghoststrats/GS-Drone-Detector-WiFi-Pineapple-Pager

## What it does

GS Drone Detector is an experimental **passive Wi-Fi name candidate detector**. It monitors Wi-Fi beacon/probe-response information or performs passive managed-mode scans, looking for SSID names containing terms such as DJI, Autel, Parrot, FPV, Skydio, Drone, and Tello. It shows candidate names, a 10-segment signal-strength bar, approximate RSSI in dBm, and one of four cautionary signal-strength labels. **The quiet display uses a built-in Pager spinner while scanning instead of logging "no candidates" every second.** Signal bars are printed at a controlled interval while tracking. It requests Pager ringtone/vibration alerts for newly encountered candidates; repeat reminders are throttled.

**It is not a verified drone detector.** A matching SSID could belong to something other than a drone or could be spoofed, and many drones never expose a matching Wi-Fi name. It does not decode Remote ID, identify aircraft, determine direction, or measure distance. The labels *POSSIBLY NEAR* and *MAY BE CLOSE* only describe received signal strength.

## Requirements

- WiFi Pineapple Pager with working Wi-Fi interface
- `sh`, `iw`, and `awk`
- For monitor-mode sampling: `tcpdump` and `timeout` installed on the Pager
- Optional Pager runtime functions: `LOG`, `RINGTONE`, and `VIBRATE`

No Python, network downloads, account, or firmware flashing required.

## Install on the Pager

1. Stop any running GS Drone Detector instance.
2. Copy `payload.sh` into `/mmc/root/payloads/user/reconnaissance/GS_Drone_Detector/payload.sh` (create the directory if necessary).
3. Set executable permission when necessary: `chmod 755 /mmc/root/payloads/user/reconnaissance/GS_Drone_Detector/payload.sh`.
4. Launch from **Payloads > User > Reconnaissance > GS Drone Detector**.

The appropriate user-payload folder can vary by firmware; check the existing payload directory on your device. The GitHub submission layout is separately `library/user/reconnaissance/GS_Drone_Detector/`.

## Options

Edit the variables at the top of `payload.sh`, or set environment variables when invoking it in a shell:

| Variable | Default | Meaning |
| --- | --- | --- |
| `GS_SCAN_WINDOW` | `1` | Length (seconds) of monitor-mode capture windows, 1–10 |
| `GS_WIFI_IFACE` | auto | Explicit radio interface such as `wlan1mon` |
| `GS_SOUND` | `1` | Request Pager sound alerts (set 0 to disable) |
| `GS_VIBRATE` | `1` | Request Pager vibration (set 0 to disable) |
| `GS_CLOSE_REPEAT` | `25` | Minimum seconds between strong-signal reminders |
| `GS_DEMO` | `0` | Generate synthetic changing signal samples, if set to 1 |
| `GS_MAX_ROUNDS` | `0` | Stop after this many observation loops (0 = unlimited) |
| `GS_SPINNER` | `1` | Show the native Pager spinning scan indicator when available; set to `0` to disable |
| `GS_TRACK_INTERVAL` | `10` | Minimum seconds between signal-bar log updates for a tracked candidate (3 or higher) |

Demo command for shell testing: `GS_DEMO=1 GS_MAX_ROUNDS=8 sh payload.sh`.

## Quiet display (updated)

- The scanner shows **Scanning...** once, with the native Pager loading spinner when the runtime provides `START_SPINNER` and `STOP_SPINNER`.
- Repeated **No candidate Wi-Fi names** and **TRACK HOLD** messages have been removed.
- A new matching signal immediately stops the spinner and shows its name, signal strength and alert.
- Signal strength continues to be sampled, but repeated readouts are limited to once every **10 seconds** by default (`GS_TRACK_INTERVAL`). That limit only affects the log, not the scanning rate.
- If the match is lost, **TRACK LOST** appears once and the spinner resumes.
- If the Pager launch environment lacks the spinner function, the scanner prints its initial status once and remains quiet until there is an event. This fallback is intentional; terminal erase codes may not work in the Pager log UI.

## Limitations and safety

- One-second capture windows **do not mean all channels are swept each second**. The observed channel, beacon timing, and radio availability limit reception. Managed-mode scans take longer.
- The payload does not switch radio channels, disconnect interfaces, or interfere with Wi-Fi traffic.
- Strong RSSI is not reliable evidence of short physical distance. It varies with antennas, obstacles, transmitters, and orientation.
- Pager alerts require the respective functions in the payload launch environment. Sound and vibration have **not been verified on physical Pager hardware** in this rebuilt package.
- Test on supported firmware and a controlled wireless environment before submitting to Hak5.
- Use only where authorized and permitted by applicable law.

## Submission notes

This package contains a **reconstructed implementation based on the documented behavior** of the GS Drone Detector project. It is **not a byte-for-byte snapshot** of the original repository's `payload.sh`. Before an official Hak5 Pull Request, consider replacing this script with the tested original at the project link and verifying the correct category and device behavior.

This is an independent community project and is not an official Hak5 product.
