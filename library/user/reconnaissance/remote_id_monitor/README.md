# Remote ID Radar

Remote ID Radar is a passive ASTM/OpenDroneID monitor for the Hak5 WiFi Pineapple Pager. It watches the Pager's existing monitor interface and Bluetooth controller without transmitting attack traffic. While monitoring, it temporarily tunes wlan1mon to Remote ID channel 6 and restores the prior channel when stopped.

## Features

- Decodes OpenDroneID over Wi-Fi Beacon vendor information elements.
- Decodes OpenDroneID over Wi-Fi NAN action frames.
- Decodes Bluetooth Service Data UUID `0xFFFA` when raw LE advertisements are available.
- Displays UAS ID, device type, operating state, RSSI, channel, altitude, drone position, operator ID, and operator position when broadcast.
- Uses an attached GPS to calculate distance and bearing to the aircraft.
- Merges Wi-Fi and Bluetooth observations that advertise the same UAS ID.
- Saves rate-limited JSONL events, CSV telemetry, and periodically checkpointed GPX waypoints under `/mmc/root/loot/remote_id_monitor` when MMC storage is available, otherwise `/root/loot/remote_id_monitor`.
- Tunes the monitor interface to channel 6 for Wi-Fi Remote ID and restores its prior channel during cleanup without changing persistent PineAP configuration.
- Provides an optional persistent censor mode that follows Marauder's masking rules for on-screen UAS IDs, operator IDs, and MAC-address fallbacks.

## Usage

Install the complete `remote_id_monitor` directory under:

`/root/payloads/user/reconnaissance/remote_id_monitor`

or:

`/mmc/root/payloads/user/reconnaissance/remote_id_monitor`

Launch **Remote ID Radar**, dismiss the title screen, and choose **Start live monitor**. Press **A** to stop. Use **Censor mode: ON/OFF** in the payload menu to toggle identifier masking; the choice persists across payload restarts. Recent detections remain available from the payload menu until the Pager reboots or another session replaces the state file.

Censor mode affects the Pager UI only. JSONL, CSV, and GPX loot retains complete identifiers for authorized analysis.

## Requirements

- WiFi Pineapple Pager with `wlan1mon`, Python 3, and tcpdump.
- Optional USB GPS supported by the stock Pager GPS service.
- The stock `blue5` service must be running for BLE Remote ID. The payload observes its existing scan through `btmon` and deliberately does not contend for the controller. Wi-Fi monitoring remains available if that service is unavailable.

No downloaded or staged code is required.

## Verification boundary

Records are marked lost after 15 seconds without a broadcast; historical records remain available for review. Remote ID is a broadcast protocol. A missing detection does not prove that no drone is present: the aircraft may not broadcast Remote ID, may use an unsupported transport, may be out of range, or may broadcast Wi-Fi Remote ID on a channel other than 6.

## Credits and license

The decoder behavior and test vectors are derived from the Remote ID implementation in [ESP32 Marauder](https://github.com/justcallmekoko/ESP32Marauder), licensed under GPL-3.0. The Python decoder and payload are distributed under GPL-3.0-only.
