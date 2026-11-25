# PagerRTTY

Sends your position and short field reports as **RTTY** (ITA2/Baudot)
through the Pager's buzzer. Hold a radio's mic to the Pager, or let any RTTY
decoder listen. No network needed.

- **Author:** SECT0101
- **Version:** 1.0.0-beta.2
- **License:** GPL-3.0

## Requirements

- Pager firmware 2.1.0 or newer (adds the buzzer sound card, `pager-pcm`).
  `cat /proc/asound/cards` should list *Pager buzzer*.
- `aplay` from `alsa-utils`. If it's missing, the payload offers to install it
  (needs internet once).

## Decoder settings

Plain RTTY, default settings in fldigi, DroidRTTY or minimodem:

| Setting | Value                                       |
|---------|---------------------------------------------|
| Baud    | 45.45                                       |
| Shift   | 170 Hz                                      |
| Center  | 4000 Hz (mark 3909 Hz, space 4091 Hz)       |

## Menu

| Item            | What it does                                                |
|-----------------|-------------------------------------------------------------|
| Send position   | Callsign + GPS position + time                              |
| SALUTE report   | Prompts S-A-L-U-T-E, sends it with position                 |
| SITREP          | GREEN / AMBER / RED / BLACK + remarks                       |
| Free text       | Any short message                                           |
| Beacon position | Position every N minutes until the payload is stopped       |
| Test tones      | `RYRYRY THE QUICK BROWN FOX 0123456789`                     |
| Phone Phreak    | 2600 Hz whistle (real), plus DTMF, blue box, red box and call progress as sound FX |
| Settings        | Callsign (default: hostname), volume, lead-in, repeat, beacon interval |

Messages look like this (demo values):

```
DE SECT-PAGER SITREP POS 37.7749N 122.4194W TXT AMBER ROAD BLOCKED 1430Z CK0D
```

`CK` is a checksum so a receiver can drop garbled copies.

**Phone Phreak sound FX:** the buzzer can't play tones below about 1.5-2 kHz,
so DTMF, blue box, red box and call progress play (as square waves, so they're
audible) but won't decode. The 2600 Hz whistle is the real thing.

## How it works

No binaries. `rtty.awk` builds the RTTY audio (raw 8-bit, 16 kHz) with BusyBox
`awk` and the payload streams it to the buzzer's sound card with `aplay`.
`tones.awk` makes the Phone Phreak sounds the same way.

## More

An optional receiver (minimodem on a Raspberry Pi) and a Node-RED flow that
puts these messages on a TAK Server as markers and GeoChat are in the
SECT0101/PagerRTTY repository on GitHub. They are not part of this payload library.

## Radio use

This payload only makes sound. Whoever keys a transmitter with it is responsible
for that radio service's rules. Messages are plain text, not encrypted.
