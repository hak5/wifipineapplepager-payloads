# Jelly Sentinel

**Category:** Reconnaissance  
**Platform:** WiFi Pineapple Pager  
**Author:** Hacka-Gotchi  
**Version:** 1.1  
**License:** For authorized security testing only

---

## Description

Jelly Sentinel is a comprehensive authorized network security assessment payload for the WiFi Pineapple Pager. It performs a multi-phase audit of home and SMB networks, producing a scored loot report with prioritized findings, device inventory, and delta comparison against previous scans.

---

## Features

- **9-phase assessment** covering WiFi audit, device discovery, fingerprinting, risk checks, Bluetooth scan, and passive traffic analysis
- **CVSS-weighted risk scoring** (0–100) with confidence-adjusted severity
- **Vendor-specific router credential testing** — validates actual authentication, not just HTTP status codes
- **OUI-based device classification** — identifies routers, cameras, NAS, printers, IoT, smart TVs, VoIP, and mobile devices
- **CVE banner matching** — detects vulnerable software versions from HTTP server headers
- **SSL certificate inspection** — flags self-signed and expired certificates
- **Bluetooth enumeration** — discovers nearby discoverable BT devices
- **DNS rebinding detection** — tests real external domains, not synthetic hostnames
- **Delta tracking** — compares findings and devices against previous scan sessions
- **Executive summary** — top issues, risk level, and finding counts at a glance
- **CSV export** — machine-readable findings output

---

## Output Files

| File | Contents |
|------|----------|
| `report.txt` | Full report with executive summary, findings, and device inventory |
| `executive_summary.txt` | Standalone summary for quick review |
| `findings.txt` | Raw pipe-delimited findings |
| `findings.csv` | CSV findings export |
| `fingerprint.txt` | Device fingerprint database |
| `devices.txt` | Raw device list with vendor |
| `wifi.txt` | AP scan results and probe SSIDs |
| `bluetooth.txt` | Bluetooth devices discovered |
| `ssl_certs.txt` | SSL certificate details |
| `dns_queries.txt` | DNS queries observed during traffic capture |
| `top_talkers.txt` | Top IP pairs by traffic volume |
| `traffic.pcap` | Raw packet capture |
| `ipv6.txt` | IPv6 neighbor table |

---

## Scan Modes

| Mode | Description |
|------|-------------|
| `1` QUICK | Fast sweep, reduced port list, 30s traffic capture |
| `2` FULL | Complete assessment, full port list, 60s traffic capture (default) |
| `3` STEALTH | Slow timing, no WiFi scan, no traffic capture |

---

## Requirements

- WiFi Pineapple Pager with client mode interface (`wlan0cli`) configured and connected to target network
- `nmap` (included in Pager firmware)
- `tcpdump` (included in Pager firmware)
- `whoismac` with OUI database at `~/.hcxtools/oui.txt`

### Installing the OUI database

Download `oui.txt` from `https://standards-oui.ieee.org/oui/oui.txt` and place it at `/root/.hcxtools/oui.txt` on the Pager. Without this file vendor lookup will return blank but the payload will still run.

---

## Usage

1. Connect the Pager to the target network via client mode
2. Deploy `payload.sh` to `/root/payloads/user/reconnaissance/Jelly_Sentinel/`
3. Run from the Pager payload UI or via SSH:
   ```sh
   bash /root/payloads/user/reconnaissance/Jelly_Sentinel/payload.sh
   ```
4. Enter tester name, target name, scan mode, and confirm authorization
5. Retrieve loot from `/root/loot/jelly_sentinel/<timestamp>/`

---

## Known Limitations

- Traffic capture (Phase 6) requires `WIFI_PCAP_START` Pager SDK support
- GPS coordinates require Pager GPS module
- Connected SSID/BSSID display requires `iwgetid` to report correctly on `wlan0cli`
- Banner CVE matching is heuristic — treat medium/low confidence matches as leads, not confirmed vulnerabilities

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md)
