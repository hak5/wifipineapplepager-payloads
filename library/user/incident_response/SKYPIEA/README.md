# 🛡️ SKYPIEA

> **Wireless Incident Response & Threat Snapshot**
> Incident response payload for the WiFi Pineapple Pager
> Author: FBG0x00 | Version: 1.0 | Category: `incident_response`

---

## What is SKYPIEA?

SKYPIEA answers one question: **what is happening in the air right now?**

When a security incident is suspected — a rogue AP, a deauth attack, an unknown client — you need a fast, complete snapshot of the wireless environment. SKYPIEA does exactly that. In a single run it captures, correlates, and documents the full wireless threat picture, then packages it into a timestamped loot bundle you can review later.

**SKYPIEA never transmits. Never modifies. Only listens and documents.**

---

## Features

- **Environment fingerprint** — system state, memory, storage, routing table, ARP cache, loaded kernel modules
- **Channel activity sweep** — hops 2.4GHz and 5GHz channels, measures frame density per channel, identifies the most active channel
- **Access point survey** — discovers nearby APs with BSSID, SSID, channel, signal strength, and encryption type
- **Rogue AP detection** — automatically flags open networks and hidden SSIDs for review
- **Client discovery** — captures probe requests and association frames, extracts unique client MACs with frame counts
- **Threat assessment** — scores findings across all collected data and produces a `LOW / MEDIUM / HIGH` threat level with a written summary
- **Timestamped loot bundle** — every session saved to `/mmc/root/loot/SKYPIEA/<timestamp>/` with individual files per data category
- **Pager UI** — uses `LOG`, `SPINNER`, `CONFIRMATION_DIALOG`, and `ERROR_DIALOG` throughout for a clean on-device experience

---

## Requirements

- WiFi Pineapple Pager
- Monitor mode interface active (`wlan0mon` or equivalent)
- `tcpdump` (pre-installed on Pager)
- `iw` (pre-installed on Pager)

No additional packages required.

> **Important** The AP scan and channel sweep require the wireless
> Interface to be in **managed mode** temporarily. If PineAP is running,
> it controls the radio and will prevent channel changes, resulting in
> 0 frames captured.
>
> Before running SKYPIEA, switch your interface to managed mode:
> 
> '''
> iw dev wlan0mon set type managed
> '''
>
> After the scan completes, switch back to monitor mode
>
> '''
> iw dev wlan0 set type monitor
> '''
>
> Client discovery works regardless of mode.

---

## Installation

- Download the payload which should then be located in your Downloads DIR.
- cd into your Downloads DIR via Terminal.
- Use "pwd" to view the location to that DIR.
- You should be able to then use Example: /home/user/Downloads/payload.sh to be able to move the payload into the /mmc/root/payloads/user/incident_response/SKYPIEA/ DIR.

```
#!/bin/bash

scp -r /home/user/Downloads/payload.sh root@172.16.52.1:/mmc/root/payloads/user/incident_response/SKYPIEA/
```

Or manually via SSH:

```
#!/bin/bash

mkdir -p /root/payloads/user/incident_response/SKYPIEA/
```

Then copy `payload.sh` into that directory.

---

## Usage

1. On the Pager, open the **Dashboard**
2. Navigate to **Payloads** → **incident_response**
3. Select **SKYPIEA** and run it
4. Confirm the snapshot when prompted
5. SKYPIEA will run through all phases automatically
6. Results are shown live in the payload log on screen
7. Full report is saved to loot when complete

---

## Configuration

Edit these variables at the top of `payload.sh`:

```bash
LOOT_BASE="/mmc/root/loot/SKYPIEA"   # Where to save loot (use /mmc/root/loot/ for SD card)
CAPTURE_DURATION=60                 # Seconds to capture per phase
CHANNEL_HOP_INTERVAL=5              # Seconds per channel during sweep
```

---

## Loot Structure

Each run creates a new timestamped directory:

```
/mmc/root/loot/SKYPIEA/
└── 20260228_143022/
    ├── incident_report.txt    ← Full human-readable report (start here)
    ├── access_points.txt      ← Raw iw scan output
    ├── clients.txt            ← Raw client frame capture
    ├── channel_activity.txt   ← Per-channel frame counts
    └── environment.txt        ← System and network state
```

Review via SSH:

```
#!/bin/bash

cat /mmc/root/loot/SKYPIEA/*/incident_report.txt
```

Or browse files via the **Virtual Pager** browser interface.

---

## Threat Levels

| Level | Meaning |
|---|---|
| LOW | No significant indicators detected |
| MEDIUM | Some open APs or elevated client count |
| HIGH | Multiple open/hidden APs or very high client activity |

Threat scoring is based on: open AP count, hidden SSID count, unique client volume, and total AP density.

---

## Legal

SKYPIEA is a **passive observation and documentation tool only**. It captures wireless frames that are broadcast publicly and does not inject, modify, or transmit any data.

Only use on networks and environments you own or have explicit written authorization to monitor.

---

## Credits

Built for the **WiFi Pineapple Pager** by Hak5.
Author: **FBG0x00**
