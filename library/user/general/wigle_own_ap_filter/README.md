# WiGLE Own AP Filter

- Author: DerSeb90
- Version: 1.0

## Description

When the Management AP (or Open AP / Evil WPA / PineAP) is enabled while
wardriving, the built-in WiGLE logger records the Pager's **own** access points
over and over – and they would be uploaded to wigle.net with your track.

This payload removes those rows from the WiGLE CSVs in `/root/loot/wigle/`
before you upload them.

## How it matches

- **By MAC:** every MAC of every local interface (`/sys/class/net/*/address`,
  `iw dev`) plus all `macaddr` values in UCI `wireless` (cloned APs).
- **By SSID:** only the Management AP SSID (`wireless.wlan0mgmt.ssid`) and
  anything in `EXTRA_SSIDS`. Open / Evil WPA SSIDs are deliberately *not*
  matched by name since they usually impersonate real networks nearby – those
  are caught by MAC.

## Usage

1. Stop WiGLE logging (the file being written is skipped – anything modified in
   the last `ACTIVE_FILE_AGE` seconds).
2. Run the payload.
3. Upload as usual (`WIGLE_UPLOAD` / WiGLE Toolkit).

Safe to run repeatedly. Originals are kept as `<file>.csv.bak` unless
`KEEP_BACKUP=false`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `KEEP_BACKUP` | `true` | Keep an unfiltered `.csv.bak` copy |
| `ACTIVE_FILE_AGE` | `30` | Skip files modified within this many seconds |
| `EXTRA_SSIDS` | `()` | More SSIDs to drop, e.g. `("MyPhone" "CarWiFi")` |

## Notes

This is a workaround. The proper fix is for the firmware's WiGLE logger to
ignore the Pager's own BSSIDs while logging.
