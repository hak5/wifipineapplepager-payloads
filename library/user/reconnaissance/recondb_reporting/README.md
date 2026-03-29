# Engagement Report Generator

**Device:** WiFi Pineapple Pager (8th gen PineAP)
**Type:** User payload
**Version:** 3.5
**Author:** Digs

---

## Overview

The Engagement Report Generator produces a formatted plain-text report and a CSV file from the Pager's native recon database at the end of a wireless reconnaissance session. No duplicate recon logic -- it reads directly from `/root/recon/recon.db`, which the PineAP engine maintains continuously in the background.

Each run produces two files in `/root/loot/reports/`:

- `report_TIMESTAMP.txt` -- formatted text report with all sections
- `report_TIMESTAMP.csv` -- AP data in spreadsheet-ready format

---

## Requirements

`sqlite3` must be installed on the device. Check and install if missing:

```bash
which sqlite3
opkg update && opkg install sqlite3-cli
```

---

## Installation

```bash
# Create payload directory
mkdir -p /root/payloads/user/reconnaissance/recon_db_reporting

# Copy payload to device from workstation
scp payload.sh root@172.16.42.1:/root/payloads/user/reconnaissance/recon_db_reporting/payload.sh

# Make executable
ssh root@172.16.42.1 'chmod +x /root/payloads/user/reconnaissance/recon_db_reporting/payload.sh'
```

---

## Before Each Engagement

The payload has three metadata fields hardcoded near the top of the script. Update these before deploying for each engagement via SSH:

```bash
ssh root@172.16.42.1
cd /root/payloads/user/reporting/recon_reports

sed -i 's/^engagement=.*/engagement="Q2 2026 Wireless Assessment"/' payload.sh
sed -i 's/^target_org=.*/target_org="Acme Corp"/' payload.sh
sed -i 's/^operator=.*/operator="Digs"/' payload.sh
```

Or edit directly with vi:

```bash
vi /root/payloads/user/reconnaissance/recon_db_reporting/payload.sh
```

The three lines are near the top right after the preflight block and are clearly labeled.

> **Note:** The `TEXT_PICKER` interactive prompt is not functional in the current firmware version. This note will be updated when Hak5 releases a fix.

---

## Running the Payload

1. Conduct your wireless recon session -- the PineAP engine collects AP, client, and handshake data continuously in the background
2. When ready to generate the report, navigate to **Payloads** on the Pager dashboard
3. Select **reconnaissance** and launch the payload
4. Two spinners appear in sequence -- "Gathering data..." then "Writing report..."
5. On completion: vibration fires and "Report ready" alert appears on screen

Total runtime is typically under 30 seconds for a standard session.

---

## Recommended Workflow

```
1. Update engagement metadata (SSH, 30 seconds)
2. Conduct recon session -- walk or drive the target area
3. If using GPS: enable WiGLE logging under Recon > Settings
4. Run the Engagement Report Generator payload
5. Retrieve output files via SCP or Virtual Pager
```

---

## Report Sections

| Section | Contents |
|---|---|
| Header | Engagement name, target, operator, timestamp, GPS location if available |
| Executive Summary | Counts for all finding categories, encryption breakdown, band coverage |
| 1 -- Recon Sessions | All named recon sessions with start times |
| 2 -- Access Points | Up to 200 APs sorted by signal: BSSID, SSID, band, channel, encryption, signal, packets |
| 3 -- Open Networks | All unencrypted APs flagged as priority findings |
| 4 -- Client Devices | Top 100 clients by signal: MAC, probed SSID, band, first seen |
| 5 -- Handshake Captures | Captured .pcap and .22000 files with Hashcat crack command |
| 6 -- Credentials | Plaintext credentials captured via Evil WPA (hostap_basic table) |
| 7 -- GPS and AP Locations | GPS fix at report time, WiGLE log summary if present |
| 8 -- Rogue AP Detections | Events from the Rogue AP Detector payload if deployed |
| 9 -- Loot Retrieval | Pre-populated SCP commands for all output files |

---

## CSV Output

The CSV file contains AP data with the following columns:

```
BSSID, SSID, Band, Channel, Encryption, Signal, Packets, Hidden, Last_Seen
```

- Up to 500 APs included, sorted by signal strength descending
- Compatible with Excel, Google Sheets, and any standard CSV tool
- SSID fields with commas or quotes are properly escaped by SQLite CSV mode

---

## Data Sources

All data comes from sources the Pager maintains natively -- no duplicate recon logic.

| Report section | Source |
|---|---|
| AP list, client list, sessions | `/root/recon/recon.db` (SQLite) |
| Handshake files | `/root/loot/handshakes/` |
| GPS fix | `GPS_GET` command (requires USB GPS adapter) |
| WiGLE AP locations | `/root/loot/wigle/*.csv` (requires GPS + WiGLE logging enabled) |
| Rogue AP events | `/root/loot/rogue_ap/detections.log` (requires Rogue AP Detector payload) |

### Encryption decoding

The `encryption` field in `recon.db` is a packed bitmask of cipher capability flags from beacon RSN Information Elements. The payload decodes it as follows:

| Label | Condition |
|---|---|
| Open | encryption = 0 or NULL |
| WEP | bit 2 set, bit 8 clear |
| WPA2 | bit 8 set, bits 16 and 64 clear |
| WPA/WPA2 | bits 4 and 8 set, bits 16 and 64 clear |
| WPA2/WPA3 | bits 8 and 16 set, or bits 8 and 64 set |
| WPA3 | bit 16 or 64 set, bit 8 clear |

### ssid.type values

| Value | Meaning |
|---|---|
| 4 | Probe request (client scanning) |
| 5 | Probe response (AP replying) |
| 8 | Beacon (AP advertising) |

The report filters `type=8` for AP enumeration and `type=4` for client enumeration.

---

## Retrieving Output Files

Default Pager IP over USB-C Ethernet: `172.16.42.1`

```bash
# Text report
scp root@172.16.42.1:/root/loot/reports/report_*.txt ./

# CSV
scp root@172.16.42.1:/root/loot/reports/report_*.csv ./

# Full loot directory
scp -r root@172.16.42.1:/root/loot/ ./pager_loot/

# Recon database (for offline analysis)
scp root@172.16.42.1:/root/recon/recon.db ./recon_$(date +%Y%m%d).db

# WiGLE logs
scp root@172.16.42.1:/root/loot/wigle/*.csv ./

# Handshakes
scp -r root@172.16.42.1:/root/loot/handshakes/ ./handshakes/
```

Files can also be downloaded via the Virtual Pager web interface at `http://172.16.42.1`.

---

## GPS Support

GPS data is included automatically when a USB GPS adapter is connected and has a valid fix.

**Supported hardware:** Any USB serial GPS receiver. Tested with g-mouse adapters and the Glytch GPS Mod. Multi-constellation receivers (GPS + GLONASS + Galileo + BeiDou) provide faster locks and better accuracy.

**Setup:**
1. Connect USB GPS to the USB-A port
2. Configure under Settings > GPS -- select serial port and baud rate (typically 9600 or 115200)
3. Wait for GPS fix -- may take 15-30 minutes on a cold start outdoors with a clear sky view

**WiGLE wardriving:**
1. Confirm GPS fix is active
2. Enable WiGLE logging: Recon > Settings > WiGLE
3. Survey the target area on foot or by vehicle
4. The report will include a geographic bounding box and per-AP location table

**Accuracy note:** GPS accuracy varies significantly based on sky visibility. Values over 100m indicate a weak fix and should be treated as approximate. Indoor use is generally not possible with pure GPS hardware.

---

## Offline Database Analysis

The recon database can be copied to a workstation for deeper analysis using any SQLite tool.

```bash
scp root@172.16.42.1:/root/recon/recon.db ./recon.db

# All APs with encryption labels
sqlite3 recon.db "SELECT
  substr(bssid,1,2)||':'||substr(bssid,3,2)||':'||substr(bssid,5,2)||':'||
  substr(bssid,7,2)||':'||substr(bssid,9,2)||':'||substr(bssid,11,2) AS bssid,
  CAST(ssid AS TEXT) AS ssid,
  channel, signal
FROM ssid WHERE type=8 ORDER BY signal DESC;"

# Open networks only
sqlite3 recon.db "SELECT CAST(ssid AS TEXT), channel, signal
FROM ssid WHERE type=8 AND (encryption=0 OR encryption IS NULL)
ORDER BY signal DESC;"

# Client probe history
sqlite3 recon.db "SELECT DISTINCT
  w.mac, CAST(s.ssid AS TEXT) AS probed
FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash
WHERE s.type=4 ORDER BY w.mac;"
```

---

## Known Limitations

**TEXT_PICKER not functional:** Interactive metadata prompts do not work in the current firmware. Engagement name, target org, and operator are hardcoded variables edited via SSH before each run. Monitor Hak5 firmware release notes for updates.

**Client count:** With large wardriving datasets (27,000+ clients observed), the client section is limited to the top 100 by signal strength to keep the report readable. The full count appears in the executive summary.

**WiGLE GPS accuracy:** The first WiGLE observations after enabling GPS logging may have high accuracy values (100m+) while the GPS warms up. These are included but noted in the report.

**Handshake capture:** WPA3 networks and 6 GHz networks do not produce crackable handshakes. Handshake capture is most reliable on 2.4 GHz WPA2 networks with active clients. Lock to a specific channel with `PINEAPPLE_EXAMINE_BSSID` to maximize capture chances.

---

## Related Payloads

This payload is designed to run at the end of a session that may include:

| Payload | Type | Purpose |
|---|---|---|
| Passive WiFi Survey | User | Session-isolated recon with PCAP capture |
| Rogue AP Detector | User (daemon) | Monitors for known SSIDs on unexpected BSSIDs |

---

## References

| Resource | URL |
|---|---|
| Pager docs | https://docs.hak5.org/wifi-pineapple-pager/ |
| Recon database | https://docs.hak5.org/wifi-pineapple-pager/device/recon/ |
| Handshake collection | https://docs.hak5.org/wifi-pineapple-pager/pineapple-functions/handshake-collection/ |
| GPS setup | https://docs.hak5.org/wifi-pineapple-pager/device/gps/ |
| Payload types | https://docs.hak5.org/wifi-pineapple-pager/payloads/introduction-to-payloads/ |
| Payload repository | https://github.com/hak5/wifipineapplepager-payloads |
