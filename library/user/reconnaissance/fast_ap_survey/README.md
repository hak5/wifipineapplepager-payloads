# Fast AP Survey

Quick, passive WiFi survey that captures nearby access points, summarizes by channel, and stores both raw and CSV outputs in `/root/loot/fast-ap-survey`.

## Options
| Variable | Default | Description |
| --- | --- | --- |
| `SCAN_INTERFACE` | `wlan1` | Interface used for scanning. |
| `SCAN_DURATION` | `25` | Seconds to run `iw scan`. |
| `OUTPUT_DIR` | `/root/loot/fast-ap-survey` | Loot destination for logs and CSV. |
| `MIN_SIGNAL_DBM` | `-90` | Filter to ignore extremely weak beacons. |

## Notes
- Uses only `iw`, so it runs fully offline.
- Review both the `.log` (raw scan output) and `.csv` (parsed) for quick channel planning and AP targeting.
