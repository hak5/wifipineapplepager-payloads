# Probe History

- Author: DerSeb90
- Version: 1.0

## Description

Exports every probe request SSID the Pager has seen from the native recon
database (`/root/recon/recon.db`) into a loot file, with **when** (timestamp),
**who** (client MAC, signal, band) and – if you were wardriving – **where**.

Location is reconstructed from the Pager's own WiGLE logs
(`/root/loot/wigle/*.csv`): every WiGLE row carries a `FirstSeen` timestamp and
the Pager's GPS position, which together form a GPS track. Each probe is matched
to the nearest track point within `GPS_MATCH_WINDOW` seconds. No extra GPS
polling is needed, and it works retroactively on old recon data as long as the
WiGLE logs from that time still exist.

## Requirements

- `sqlite3` (`opkg update && opkg install sqlite3-cli`)
- Optional: USB GPS + WiGLE logging enabled during recon (for locations)

## Output

`/root/loot/probe_history/probes_<timestamp>.txt`

```
Time                 Client MAC         Sig  Band  SSID                Location
2026-11-16 18:00:05  A1:B2:C3:D4:E5:F6  -60  2.4   "FRITZ!Box 7590"    52.100100,8.100100 +-4m (dt 1s)
2026-11-16 18:06:40  11:22:33:44:55:66  -55  2.4   "FRITZ!Box 7590"    -
```

followed by a top 25 of probed SSIDs by number of distinct clients.

`/root/loot/probe_history/probes_<timestamp>.csv` – same data with `lat`/`lon`
columns, ready for Google My Maps, QGIS, uMap etc.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `INCLUDE_BROADCAST` | `false` | Also list wildcard probes without SSID |
| `GPS_MATCH_WINDOW` | `60` | Max seconds between probe and GPS fix |
| `WIGLE_TIME_OFFSET` | `0` | Seconds added to WiGLE `FirstSeen` to get UTC (only if your WiGLE logs are not UTC) |

## Notes

- recon.db keeps one row per client/SSID pair rather than every single probe
  frame, so you get one timestamp per pair (the time recon.db stored for it),
  not a full frame-by-frame log.
- Modern phones randomize their MAC, so the same person can show up under
  several MACs.
- Works on a snapshot copy of recon.db, the live database is never modified.
