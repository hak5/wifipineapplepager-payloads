# DNS Watchdog Logger

Passive DNS monitor that records queries/responses, flags suspicious domains, and retains a pcap for forensic review.

## Options
| Variable | Default | Description |
| --- | --- | --- |
| `SNIFF_INTERFACE` | `br-lan` | Interface to capture DNS traffic from. |
| `OUTPUT_DIR` | `/root/loot/dns-watchdog` | Destination for logs and pcaps. |
| `CAPTURE_DURATION` | `300` | Seconds to run the monitor. |
| `SUSPICIOUS_DOMAINS` | `example.biz;internal.test;badcorp.com` | Semicolon-separated watchlist of domains (or suffixes). |

## Usage
1. Set `SNIFF_INTERFACE` to an interface carrying client traffic (e.g., `br-lan` or `wlan0`).
2. Populate `SUSPICIOUS_DOMAINS` with domains or suffixes that should trigger alerts.
3. Run the payload; pcaps and logs land in `OUTPUT_DIR`. Watchlist hits append to `dns-alerts.log`, while `dns-queries.log` tracks all observed lookups.
