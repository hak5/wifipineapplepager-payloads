# RF-BUDDY

A passive 2.4 GHz / 5 GHz interference finder for the WiFi Pineapple Pager.
Carry it around the office and watch the readings move: walking toward a
problem makes the score rise, walking away makes it fall. It never transmits.

> **Author:** Henry Hu · **Project home:** https://github.com/ninedter/DEFCON-DEFENSE
> RF-BUDDY and DEFCON-DEFENSE are developed together there; this directory is a
> self-contained copy for the Pager payload library.

## What it measures

The Pager's monitor radio cannot report channel busy time or a noise floor, so
RF-BUDDY measures what it can hear directly:

- **Airtime %** — how much of the channel is taken up by Wi-Fi frames.
- **Retry %** — how many frames are retransmissions. Lots of retries on a channel
  that is not busy usually means radio interference.
- **APs** — networks on the channel, plus 2.4 GHz networks on overlapping channels.
- **Bluetooth** — nearby BLE devices (earbuds, watches, phones), counted with a
  passive scan that never transmits.

## Screens and buttons

**Overview** — one bar per channel (airtime %, coloured by score: green < 40,
amber 40–69, red ≥ 70). The right panel shows the selected channel's score,
airtime, retry %, AP count, frames per second, and the likely cause.

| Button | Action |
|---|---|
| LEFT / RIGHT | select channel |
| UP / DOWN | cycle tabs: 2.4 GHz / 5 GHz / BT |
| A | lock on to the selected channel |
| B | exit |

**Lock-on** — the radio stays on one channel and updates once a second: big
score, trend, peak, a 60-second graph, the strongest transmitters, and the
nearby Bluetooth count. The buzzer tick plays faster as the score rises.

| Button | Action |
|---|---|
| LEFT / RIGHT | move to the neighbouring channel |
| UP | tick on/off |
| A | MARK SPOT — writes a numbered marker to the log |
| B | back to the overview |

**BT tab** — nearby Bluetooth LE devices, browsed in three levels: BRANDS
(Apple, Samsung, Bose, JBL/Harman, Tile, Realtek, ... UNKNOWN collects devices that nothing identifies),
then the TYPES of that brand (Find My, Nearby, AirPlay, ...), then the DEVICES of
that type, strongest first; each device row shows its advertised name, or its
address when it has none. The right panel summarises the highlighted row; at
the device level it shows nine rows: ADDR, ADDR TYPE, MAKER, KIND, NAME,
SIGNAL (`-64 (PK -61)`: now and peak), ADV/S, TX PWR and SEEN (`0S / 04:08:25`:
seconds since the last advert and the time it was first seen). MAKER is the
brand (or the registered maker name when only a bare `ID XXXX` is known); KIND
is the decoded model (for example AIRPODS PRO 2 or WINDOWS LAPTOP) or else the
type; NAME falls back to the beacon summary (IBEACON 100/7, EDDYSTONE UID).
Anything unknown, including a signal or peak with no data, shows `--`. At the
type level a SERVICES line lists the standard Bluetooth services (for example
HEART RATE) advertised by the strongest device.

ADDR TYPE tells how much to trust the address:

- `PUBLIC` — the fixed address burned in by the maker; its first three bytes
  identify the maker.
- `STATIC` — random, but constant until the device reboots.
- `PRIVATE` — random and rotating (privacy address, as phones and earbuds use),
  so the same device shows up under several addresses.
- `NON-RESOLV` — random and short-lived, never resolvable by a paired peer.

### How devices are identified

Passive adverts only, matched offline against a database embedded in the
payload (no network needed). The brand is the first hit of: Bluetooth SIG
company ID (also tried byte-swapped), SIG member service UUID (for example
Tile, Google), keyword in the advertised name, IEEE OUI of a **PUBLIC**
address only (a random address says nothing about the maker), first word of
the name, a brand hinted by a service UUID, an `ID XXXX` placeholder for an unregistered company ID, else
UNKNOWN. The kind is the first hit of: maker-specific decoding (Apple proximity
pairing models, iBeacon, Microsoft CDP device type, Eddystone), name keyword,
standard SIG services, SIG appearance, else OTHER.

The database ships prebuilt in `ui/btdb/`, so no network access is needed to
build or run RF-BUDDY. To regenerate it from the original sources, use the
`tools/gen_btdb.py` generator in the project repository
(https://github.com/ninedter/DEFCON-DEFENSE); it is a development-only helper
and is intentionally not bundled with the payload.

Data sources: Bluetooth SIG assigned numbers (company identifiers, member and
service UUIDs, appearance values) and the IEEE OUI registry via the Wireshark
`manuf` file. Source URLs and download date are in `ui/btdb/SOURCES.md`.

| Button | Brands | Types | Devices |
|---|---|---|---|
| LEFT / RIGHT | previous / next brand | previous / next type | previous / next device |
| UP / DOWN | cycle tabs: 2.4 GHz / 5 GHz / BT | previous / next type | previous / next device |
| A | open the brand's types | open the type's devices | TRACK the device |
| B | exit | back to brands | back to types |

**BT track** — a walk-around proximity meter for one device: big signal
strength with VERY CLOSE / CLOSE / NEAR / FAR, closer/farther trend, peak, a
60-second graph, and which Wi-Fi channels BLE advertising overlaps. The buzzer
tick speeds up as you get closer.

| Button | Action |
|---|---|
| LEFT / RIGHT | track the previous / next device of the same brand and type |
| UP | tick on/off |
| A | MARK SPOT — writes a numbered marker to the log |
| B | back to the device list |

BT marks go in `marks.csv` as `n,epoch,bt,ADDRESS,RSSI,LABEL` (the channel
column holds the device address, the score column its signal in dBm).

## Likely causes

| Label | Meaning |
|---|---|
| INTERFERENCE | many retries while the channel is not busy — typical of microwaves, wireless cameras, or heavy Bluetooth |
| CONGESTION | Wi-Fi is using most of the channel's airtime |
| CHANNEL OVERLAP | a loud AP on a neighbouring 2.4 GHz channel (e.g. 4 next to 6) |
| BT DENSE | many Bluetooth LE devices nearby — a common cause of earbud static |
| WEAK COVERAGE | your office AP is quiet here (needs `OFFICE_SSID`) |
| CLEAN | nothing notable |

## Setup

Edit the CONFIG block at the top of `payload.sh`:

- `OFFICE_SSID` — your office network name. Enables `WEAK COVERAGE`.
- `TICK_FREQ_HZ` — pitch of the lock-on tick on the Pager buzzer (default 2000).
- `TICK_VOLUME` — loudness of the tick, 0-100 (default 60).
- Thresholds (`RETRY_HIGH_PCT`, `AIRTIME_HIGH_PCT`, …) are documented inline.

Recon keeps running while RF-BUDDY is open; it is locked to one channel at a
time and returns to normal hopping when you exit. The Bluetooth scan is passive.

## Viewer and the stock UI

Open **http://172.16.52.1:1474** for RF-BUDDY's own viewer: a live copy of the
screen with on-page buttons. The viewer has no login, so it listens only on the
Pager's USB management address (`172.16.52.1`), never on a Wi-Fi network the
Pager has joined. Buttons only work from the viewer's own on-page buttons (or
keyboard keys); direct cross-site requests are refused.

While RF-BUDDY runs, the stock Pager menu and the stock Virtual Pager (`:1471`)
are paused; they return when you press B. RF-BUDDY also takes over the power
button (it is on the same input device), so pressing **power** on any screen
exits RF-BUDDY cleanly and hands the button back to the Pager — then use the
Pager's Power Menu → **Shutdown** to turn it off.

### If the Pager menu stays frozen

RF-BUDDY's watchdog resumes the stock menu if RF-BUDDY is killed. If the
RF-BUDDY app itself hangs, holding the power button until the Pager cuts power
is the last resort; expect the unclean-shutdown warning on the next boot.

## Logs

Each run writes `/root/loot/rf_buddy/<date-time>/`:

- `samples.csv` — one row per channel per sweep, one row per second in lock-on
  (`score` is the raw score, so spikes are kept).
- `marks.csv` — your MARK SPOT markers.
- `session.txt` — what the radio supported and the settings used.

Retrieve them with Virtual Pager → **Download Loot** (after RF-BUDDY has exited and the stock Virtual Pager is back).
