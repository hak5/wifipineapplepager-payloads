# Targeted Probe Logger

Watches for probe requests on a monitor interface and highlights roaming clients that match SSID or OUI watchlists.

## Options
| Variable | Default | Description |
| --- | --- | --- |
| `MONITOR_INTERFACE` | `wlan1mon` | Monitor-mode interface to sniff. |
| `CAPTURE_DURATION` | `120` | Seconds to listen for probe requests. |
| `OUTPUT_DIR` | `/root/loot/probe-logger` | Loot output directory for logs and hits. |
| `WATCHLIST_SSIDS` | `CorpWiFi;GuestNet;VOIP-phones` | Semicolon-separated SSIDs to alert on. |
| `WATCHLIST_OUIS` | `00:11:22;AA:BB:CC` | Semicolon-separated OUIs to flag interesting client vendors. |

## Usage
1. Ensure a monitor interface exists (e.g., create with `airmon-ng start wlan1` or the Pineapple UI).
2. Adjust watchlists to match your target SSIDs or vendor OUIs.
3. Run the payload; hits are written to `watchlist-hits-*.log` while all probes are recorded in `probes-*.log`.
