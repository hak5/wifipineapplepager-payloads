# C5 Wardriver Pager Node

Development preview for WiFi Pineapple Pager 2.0.0. It scans 6 GHz preferred scanning channels with the Pager's MT7921AU radio and forwards observations to a nearby C5 Wardriver running in unencrypted Core mode.

## Current scope

- 6 GHz PSC scanning only
- Existing C5 ESP-NOW discovery, heartbeat, and text framing
- On-device Core discovery, explicit selection/confirmation, and persistent pairing
- Manual on-device MAC entry as a fallback
- Explicit $W6$ record type so the Core calculates the correct 6 GHz frequency
- Bounded queue and 30-second BSSID deduplication

## Requirements

- C5 Wardriver firmware containing Pager protocol support
- C5 configured as Core with ESP-NOW encryption disabled
- Pair a replying Core from the Pager hardware menu, or enter its base MAC with the on-device MAC picker; the selection is saved persistently and replies/record ACKs from any other radio are rejected
- Pager $wlan1mon$ available in monitor mode
- python3-light installed on the Pager (MMC installations are detected automatically)

This is an early hardware-validation build, not yet ready for upstream submission.
