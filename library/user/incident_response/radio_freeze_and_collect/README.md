# Radio Freeze & Collect

Locks down wireless interfaces, captures volatile evidence (routes, ARP cache, sockets, DHCP leases, firewall rules), and produces a compressed bundle for incident response.

## Options
| Variable | Default | Description |
| --- | --- | --- |
| `OUTPUT_DIR` | `/root/loot/ir-freeze` | Destination for logs and the evidence bundle. |
| `PRIMARY_IFACE` | `wlan0` | Primary interface to disable. |
| `SECONDARY_IFACE` | `wlan1` | Secondary interface to disable. |
| `PCAP_DURATION` | `60` | Seconds to collect post-incident traffic. |
| `PCAP_INTERFACE` | `wlan0` | Interface to monitor for the PCAP. |

## Usage
1. Trigger when you need to quickly halt radio activity and preserve state.
2. The payload downs the listed interfaces, captures routing/ARP/process/socket info, saves DHCP leases, firewall rules, and takes an optional pcap.
3. Everything is bundled as `ir-bundle-<timestamp>.tar.gz` in `OUTPUT_DIR` for later analysis.
