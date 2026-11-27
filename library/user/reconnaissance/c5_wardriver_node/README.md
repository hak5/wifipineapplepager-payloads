# C5 Wardriver Pager Node

Payload for WiFi Pineapple Pager 2.0.0. It scans 6 GHz preferred scanning channels with the Pager's MT7921AU radio and forwards observations to a nearby C5 Wardriver running in unencrypted Core mode.

## Current scope

- 6 GHz PSC scanning only
- Existing C5 ESP-NOW discovery, heartbeat, and text framing
- On-device Core discovery, explicit selection/confirmation, and persistent pairing
- Manual on-device MAC entry as a fallback
- Explicit `W6` record type so the Core calculates the correct 6 GHz frequency
- JCMK live dashboard with Core status, unique-device count, transport health, and a rolling 15-channel PSC activity graph
- Distinct anti-aliased Lato interface typography and the geometric JCMK splash-screen mark
- D-pad Left/Right selects Overview or Telemetry; the red B button stops the payload and releases the native display/radio handoffs
- Bounded queue, queue-level duplicate suppression, 30-second BSSID deduplication, and bounded session device accounting

## Requirements

- C5 Wardriver firmware containing Pager protocol support
- C5 configured as Core with ESP-NOW encryption disabled
- Pair a replying Core from the Pager hardware menu, or enter its base MAC with the on-device MAC picker; the selection is saved persistently and replies/record ACKs from any other radio are rejected
- Pager `wlan1mon` available in monitor mode
- OpenWrt `python3-light` (MMC installations are detected automatically). If it is missing or incomplete, the payload offers to install it to MMC after explicit confirmation; this requires internet access.
- The GUI uses `pagerctl` pinned by commit and file hashes. If that exact runtime or `python3-ctypes` is missing, the payload offers a separate explicit installation prompt before changing the display or radio.
- Lato Medium is bundled under the SIL Open Font License 1.1; its copyright and license text are retained in `fonts/OFL-Lato.txt`.

The payload restores the Pager radio configuration when it exits and rejects replies from unpaired radios.
