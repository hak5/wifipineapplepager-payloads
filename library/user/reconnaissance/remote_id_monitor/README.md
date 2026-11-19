# Remote ID Radar

Remote ID Radar v0.2.1 is a passive ASTM/OpenDroneID monitor for the Hak5 WiFi Pineapple Pager. It watches the Pager's existing monitor interface and Bluetooth controller without transmitting attack traffic. While monitoring, it temporarily tunes wlan1mon to Remote ID channel 6 and restores the prior channel when stopped.

## Features

- Decodes OpenDroneID over Wi-Fi Beacon vendor information elements.
- Decodes OpenDroneID over Wi-Fi NAN action frames.
- Decodes Bluetooth Service Data UUID `0xFFFA` when raw LE advertisements are available.
- Provides a full-screen 480x222 dashboard with total/active counts and a bounded, dynamically scaled airspace map. Aircraft are cyan, operator positions magenta, GPS-fixed Pager position green, and aircraft history trails red.
- Keeps the map useful without a USB GPS fix by deriving its origin and bounds from aircraft, operator, and history positions. It does not invent a Pager position or zero-distance telemetry.
- Adds a D-pad carousel with aircraft and operator detail pages. Aircraft pages show identity, status, RSSI, transport, channel, location, altitude, speed, heading, and GPS-derived Pager range/bearing when available.
- Uses the Pager's native GPS status to distinguish hardware not detected, searching/no signal, weak signal, and an active fix; with a fix it calculates distance and bearing to the aircraft.
- Merges Wi-Fi and Bluetooth observations that advertise the same UAS ID.
- Saves rate-limited JSONL events, CSV telemetry, and periodically checkpointed GPX waypoints under `/mmc/root/loot/remote_id_monitor` when MMC storage is available, otherwise `/root/loot/remote_id_monitor`.
- Tunes the monitor interface to channel 6 for Wi-Fi Remote ID and restores its prior channel during cleanup without changing persistent PineAP configuration.
- Provides an optional persistent censor mode that masks on-screen identifiers and all position-derived UI output, including coordinates, map geometry, range, and bearing.

## Usage

Install the complete `remote_id_monitor` directory under:

`/root/payloads/user/reconnaissance/remote_id_monitor`

or:

`/mmc/root/payloads/user/reconnaissance/remote_id_monitor`

Launch **Remote ID Radar**, dismiss the title screen, and choose **Start live map**. On the main page, Left/Right selects an aircraft and Down opens it. On detail pages, Left/Right moves through the aircraft/operator carousel and Up returns directly to the map. Press B from any page to stop both the GUI and monitor and exit the payload. Use **Censor mode: ON/OFF** before launch to toggle display masking; the choice persists across payload restarts.

Censor mode affects the Pager UI only. JSONL, CSV, and GPX loot retains complete identifiers and positions for authorized analysis.

## Requirements

- WiFi Pineapple Pager with `wlan1mon` and tcpdump. If Python is missing or incomplete, the payload offers to install OpenWrt `python3-light` to MMC after explicit confirmation. The GUI similarly offers to install `python3-ctypes` plus an exact, hash-verified pagerctl revision. These one-time installs require internet access and MMC storage.
- Optional USB GPS supported by the stock Pager GPS service.
- BLE Remote ID requires the stock `blue5` service with LE scanning enabled. Before starting `btmon`, the payload checks `blue5ctl status`; a stopped daemon, Classic-only mode, disabled LE scanning, or an unreadable status produces a clear degraded-state warning while Wi-Fi monitoring continues. The payload only observes the existing scan and deliberately does not contend for the controller.

The Lato Medium font and its OFL license are bundled. Pagerctl is installed payload-locally from a pinned revision; both runtime files are SHA-256 verified at install and every GUI startup. The payload does not persist GPS configuration or restart GPS, Bluetooth, PineAP, or other stock services.

## Verification boundary

Records are marked lost after 30 seconds without a broadcast, matching ESP32 Marauder's stale-target window; historical records remain available for review. Remote ID is a broadcast protocol. A missing detection does not prove that no drone is present: the aircraft may not broadcast Remote ID, may use an unsupported transport, may be out of range, or may broadcast Wi-Fi Remote ID on a channel other than 6.

## Credits and license

The decoder behavior and test vectors are derived from the Remote ID implementation in [ESP32 Marauder](https://github.com/justcallmekoko/ESP32Marauder), licensed under GPL-3.0. The Python decoder and payload are distributed under GPL-3.0-only.
