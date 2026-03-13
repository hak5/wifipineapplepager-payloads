# The Nosey Neighbor

**Passive wireless reconnaissance payload for the Pager**

> No attacks. No deauth. No mimic. Just listening.

The Nosey Neighbor is a comprehensive passive recon toolkit that sniffs the wireless environment around you, discovers access points, collects probed SSIDs, identifies device vendors, geo-tags findings with GPS, captures a traffic snapshot, and compiles everything into a detailed intel report — including an automated intelligence summary that interprets what the data means, because it may look like blah blah if you don't know how to read WiFi stuff.

## Features

| Feature | Description |
|---------|-------------|
| **AP Discovery** | Scans for nearby access points across 2.4 GHz and 5 GHz bands (including DFS channels) |
| **Network Summary** | Groups BSSIDs into logical networks, separating private networks from ISP hotspots with estimated physical device count |
| **Client Detection** | Identifies active client devices with signal strength and vendor identification |
| **Probed SSID Collection** | Captures what networks nearby devices are actively looking for, with signal-based distance estimates. Output file is structured into new-this-session vs previously collected sections |
| **Vendor Identification** | Looks up device manufacturers via `whoismac` with clean formatted output |
| **GPS Geo-Tagging** | Tags each scan with GPS coordinates (requires GPS module) |
| **Traffic Snapshot** | Captures a passive pcap for offline analysis |
| **802.11 Frame Breakdown** | Categorizes captured frames by type (Beacon, Probe, Data, etc.) |
| **Channel Heatmap** | Visualizes channel congestion with a bar chart |
| **Channel Quick Reference** | In-report guide explaining 2.4 GHz and 5 GHz channel bands (U-NII-1 through U-NII-3, DFS) |
| **RSSI Quick Reference** | In-report guide explaining signal strength values and what they mean |
| **Encryption Breakdown** | Shows the security posture of discovered networks |
| **Security Findings** | Flags open and WEP networks automatically |
| **Intelligence Summary** | Automatically interprets scan results — classifies area type (commercial/residential/mixed), identifies dominant infrastructure, proximity, vehicle/phone hotspots, device history, and vendor category breakdown |
| **Auto-Update Check** | Checks GitHub for new versions on launch |
| **Scan Timer** | Shows estimated runtime at start and actual elapsed time in the report |

## How It Works

The payload runs through 8 phases:

1. **GPS Location Tag** — Acquires a GPS fix to geo-tag the scan (validates coordinates to reject junk data)
2. **System Status** — Logs battery, storage, and uptime
3. **Wireless Recon** — Primary scan uses `tcpdump` beacon sniffing on the monitor interface with background channel hopping across all bands (including DFS channels 52-144). Parses channel from both DS Parameter Set (`CH: N`) and radiotap frequency header (`NNNN MHz`) for reliable channel detection. Falls back to `iwinfo scan` and `iw scan` if needed. Sniffs client MACs with signal strength from the monitor interface.
4. **Probed SSID Collection** — Uses PineAP's SSID pool collector to capture probe requests, with `tcpdump` probe-req sniffing for signal strength mapping. Diffs against a pre-scan snapshot to identify SSIDs new to this session.
5. **Vendor Identification** — Looks up MAC address vendors using `whoismac` for both APs and clients
6. **Traffic Snapshot** — Captures a passive pcap via `tcpdump` on the monitor interface
7. **Security Findings** — Analyzes results for open and WEP networks
8. **Intelligence Summary** — Interprets the collected data using a weighted scoring system to classify area type, identify dominant infrastructure, flag notable detections, and profile device types by vendor category

## Startup Sequence

On launch, the payload displays a Curly-style scrolling banner and runs through pre-flight checks:

1. **Banner** — Displays payload name, description, and author
2. **Scan Timer** — Calculates and displays estimated runtime based on your configuration
3. **Version Check** — Fetches the latest version from GitHub and alerts if an update is available

## LED Indicators

| Color | Phase |
|-------|-------|
| Yellow | Startup / Banner |
| Blue | GPS acquisition / System status |
| Cyan | Wireless recon scanning |
| Green | Recon complete / GPS fix acquired |
| Magenta | Probed SSID collection |
| Yellow | Vendor lookups / No GPS fix |
| Red | Traffic capture |
| Green | Payload complete |

## Configuration

All settings are at the top of `payload.sh`:

```bash
LOOT_BASE="/root/loot/nosey-neighbor"   # Base loot directory
MON_IFACE=""                             # Auto-detected (leave empty)
SCAN_IFACE=""                            # Auto-detected (leave empty)
RECON_DURATION=30                        # PineAP recon scan duration (seconds)
SSID_COLLECT_DURATION=45                 # SSID probe collection time (seconds)
PROBE_SNIFF_DURATION=30                  # tcpdump probe fallback duration (seconds)
ENABLE_GPS=true                          # Enable/disable GPS tagging
ENABLE_VENDOR_LOOKUP=true                # Enable/disable whoismac lookups
ENABLE_PCAP_SNAPSHOT=true                # Enable/disable traffic capture
PCAP_DURATION=20                         # Pcap capture duration (seconds)
MAX_VENDOR_LOOKUPS=25                    # Max number of MAC vendor lookups
STOP_PROBE_COLLECT=false                 # false = leave probe collection running after scan (default), I personally prefer this option because I keep "Collect Probes" on, but to each his/her/them own!
                                         # true  = stop probe collection when payload finishes
```

**Estimated runtime** is calculated dynamically from these values and displayed at startup (typically ~3 minutes with default settings).

## Report Sections

The generated report includes the following sections:

| Section | Description |
|---------|-------------|
| **GPS** | Coordinates (if available) or skip notice |
| **System Status** | Battery, charging state, storage, uptime |
| **Wireless Landscape** | Total AP and client counts |
| **Access Points** | Full table with BSSID, SSID, Channel, RSSI, and Encryption |
| **Network Summary** | Groups BSSIDs into logical networks — private vs ISP hotspots, AP counts per network, band info, closest signal, estimated physical device count |
| **Channel Heatmap** | Visual bar chart of channel utilization |
| **Channel Quick Reference** | 2.4 GHz (CH 1-11) and 5 GHz band guide (U-NII-1 through U-NII-3, DFS explanation) |
| **RSSI Quick Reference** | Signal strength guide (-30 Excellent to -95 Very Weak) |
| **Encryption Breakdown** | Count of networks by encryption type |
| **Clients** | Client MAC, associated AP, SSID, RSSI, and Vendor name |
| **Probed SSIDs** | New-this-session and previously collected probe requests, with signal strength and distance estimates |
| **Device Vendor Identification** | Full MAC-to-vendor mapping table |
| **Traffic Snapshot** | PCAP file info, packet count, and 802.11 frame type breakdown |
| **Security Findings** | Open and WEP network alerts (with note when open networks are likely ISP hotspots) |
| **Intelligence Summary** | Automated area classification, dominant infrastructure, proximity analysis, notable detections, activity level, device history, security posture, and vendor device profile |
| **Summary** | Final counts with scan duration |

## Intelligence Summary

The Intelligence Summary section automatically interprets scan results using a weighted scoring system rather than simple AP count thresholds. It evaluates:

**Commercial signals:**
- Enterprise SSIDs (3+ BSSIDs, non-ISP) — indicates business or multi-tenant deployment
- Commercial keywords in SSID names (cafe, hotel, gym, school, etc.)
- Guest/visitor/public SSID patterns
- High client-to-AP ratio (>1.0 = busy venue)

**Residential signals:**
- ISP-broadcast hotspot count (Xfinity, AT&T, Spectrum, Cox, etc.) — indicates dense subscriber housing
- Low client-to-AP ratio (people at home, not a busy venue)
- High ISP hotspot fraction of total APs

**Area classifications:**
- `commercial or business area` — commercial score leads by 3+
- `residential area (apartment complex or urban housing)` — residential score leads by 2+ in a dense environment
- `residential neighborhood` — residential score leads by 2+ in a low-density environment
- `mixed residential/commercial area` — scores are close

**Density tiers:** sparse / low-density / medium-density / high-density / very high-density (50+ APs)

**Also detects:**
- Vehicle hotspots (BUICK, CHEVY, FORD, TOYOTA, TESLA, etc.)
- Phone hotspots (iPhone, Android AP, Galaxy Hotspot, Pixel)
- Device vendor categories (Apple, Samsung, Google, Smart TV, Smart home/IoT, IoT dev boards, ISP hardware, Network infrastructure)

## Loot Structure

Each run creates a timestamped folder:

```
/root/loot/nosey-neighbor/
├── 2026-02-17_143015/
│   ├── report_143015.txt        # Full recon report
│   ├── probed_ssids_143015.txt  # Probed SSIDs — new this session first, then previously collected
│   ├── vendors_143015.txt       # MAC-to-vendor mappings
│   ├── snapshot_143015.pcap     # Traffic capture
│   ├── gps_143015.txt           # GPS coordinates
│   └── debug_143015.txt         # Debug log
├── 2026-02-17_151200/
│   └── ...
```

The `probed_ssids_TIMESTAMP.txt` file is structured with two sections:

```
# NEW THIS SESSION (5)
HomeNetwork123
OfficeWiFi
...

# PREVIOUSLY COLLECTED (63)
SL DIAMOND SPKR
The Wi-Fi
...
```

## Sample Report Output

```
═══════════════════════════════════════════════════════════════
  THE NOSEY NEIGHBOR — Recon Report
  Date: Mon Feb 17 14:30:15 UTC 2026
═══════════════════════════════════════════════════════════════

── SYSTEM STATUS ──────────────────────────────────────────────
  Battery:  87%
  Charging: false
  Storage:  1.2G free
  Uptime:   14:30:15 up 2:15

── WIRELESS LANDSCAPE ─────────────────────────────────────────
  Access Points Found:  34
  Clients Found:        49

  ┌─ ACCESS POINTS ──────────────────────────────────────────
  │ BSSID              SSID                         CH   RSSI  ENC
  │ 4c:ab:f8:95:0f:65  Verizon_CKY4T3               6    -70   Encrypted
  │ 02:cb:7a:12:ba:07  xfinitywifi                  44   -64   Open
  └──────────────────────────────────────────────────────────

  ┌─ NETWORK SUMMARY ─────────────────────────────────────────
  │
  │  Total BSSIDs:           34
  │  Unique Named Networks:   9
  │  Hidden Networks:        12
  │  ISP Hotspots:            0
  │  Private Networks:        9
  │  Est. Physical Devices:  ~33
  │
  │  PRIVATE NETWORKS
  │  SSID                       APs  BANDS        CLOSEST
  │  Goodwill                    4    2.4 + 5 GHz  -59 dBm
  │  BYODupright                 4    2.4 + 5 GHz  -58 dBm
  │  Goodwill Visitor            4    2.4 + 5 GHz  -59 dBm
  │  BUICK4989                   1    2.4 GHz      -83 dBm
  │
  └──────────────────────────────────────────────────────────

  ┌─ CLIENTS ──────────────────────────────────────────────────────────────────────
  │ CLIENT MAC         AP BSSID           SSID                 RSSI   VENDOR
  │ 2c:64:1f:a7:c3:ef  38:88:71:0e:6e:da  Verizon_FTGN64       -69    Vizio, Inc
  │ 5c:fc:e1:99:b6:e6  a8:40:41:2b:3d:26  monaire-2b3d26       -60    Resideo
  └────────────────────────────────────────────────────────────────────────────────

── PROBED SSIDs (What devices are looking for) ────────────────
  NEW this session:      3
  Total in SSID pool:    66

  ┌─ NEW THIS SESSION ─────────────────────────────────────────
  │   1. HomeNetwork                       [-52dBm] ~3-8m (very close)
  │   2. OfficeWiFi                        [-71dBm] ~15-30m (in range)
  │   3. Starbucks                         [-85dBm] ~30-50m (moderate)
  └──────────────────────────────────────────────────────────

── SECURITY FINDINGS ──────────────────────────────────────────
  No open or WEP networks found. Good neighborhood.

── INTELLIGENCE SUMMARY ──────────────────────────────────────

  AREA OVERVIEW
  34 APs and 49 clients indicate a high-density commercial or business area.
  Dual-band environment: 18 x 2.4 GHz, 16 x 5 GHz BSSIDs.
  12 hidden SSID(s) detected.

  DOMINANT INFRASTRUCTURE
    - "Goodwill" (4 BSSIDs)
    - "BYODupright" (4 BSSIDs)
    - "Goodwill Visitor" (4 BSSIDs)
    - "gwdonation" (4 BSSIDs)
  Multiple enterprise networks -- likely a commercial building or shared site.

  PROXIMITY
  Strongest AP: "BYODupright" at -58 dBm (nearby (~15m)).

  NOTABLE DETECTIONS
  * Vehicle hotspot: "BUICK4989"

  ACTIVITY LEVEL
  49 active clients -- heavy foot traffic.

  DEVICE HISTORY
  63 probed SSIDs reveal nearby devices have previously
  connected to home networks, workplaces, hotels, and hotspots.

  SECURITY POSTURE
  All visible networks use modern encryption. Clean area.

  DEVICE PROFILE (by vendor category)
    Smart TV / AV:      1 device(s)
    Smart home / IoT:   1 device(s)
    IoT dev boards:     1 device(s)

──────────────────────────────────────────────────────────────

═══════════════════════════════════════════════════════════════
  SUMMARY
═══════════════════════════════════════════════════════════════
  Access Points:     34
  Clients:           49
  Probed SSIDs:      3 new / 66 total
  Open Networks:     0
  WEP Networks:      0
  Scan Duration:     5m 46s
  Report:            /root/loot/nosey-neighbor/2026-02-17_143015/report_143015.txt
═══════════════════════════════════════════════════════════════
```

## Installation

1. Copy the entire `nosey-neighbor` folder to your Pager's payload directory, in the reconnaissance folder:
   ```
   /root/payloads/library/user/reconnaissance/nosey-neighbor/
   ```
2. Ensure the folder contains:
   - `payload.sh` — the main payload script
   - `VERSION` — version file for auto-update checks
3. Run it from the pager's payload launcher

## Requirements

- Pager
- Internet connection (optional — for version check and some vendor lookups)
- GPS module (optional, for geo-tagging)

## Technical Notes

### Channel Detection
The payload uses a dual-method approach for detecting AP channels:
1. **DS Parameter Set** — Parses `CH: N` from beacon frames (standard for 2.4 GHz)
2. **Radiotap Frequency** — Falls back to parsing `NNNN MHz` from the radiotap header and converting to channel number (essential for 5 GHz APs that often omit DS Parameter Set)

### Channel Hopping
The monitor interface hops across all standard and DFS channels:
- **2.4 GHz**: Channels 1-11
- **5 GHz U-NII-1**: Channels 36, 40, 44, 48
- **5 GHz U-NII-2 (DFS)**: Channels 52, 56, 60, 64
- **5 GHz U-NII-2C (DFS)**: Channels 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144
- **5 GHz U-NII-3**: Channels 149, 153, 157, 161, 165

### Interface Auto-Detection
The payload automatically detects monitor and managed interfaces using multiple methods:
1. `iw dev` monitor type detection
2. `iwinfo` mode detection
3. Common interface name matching (`wlan0mon`, `wlan1mon`, etc.)
4. `airmon-ng` fallback for creating monitor interfaces

### BusyBox Compatibility
All parsing is written for BusyBox awk/ash compatibility:
- No capture groups in `match()` — uses `index()` + `substr()` instead
- No consecutive empty tab fields — uses `-` placeholders
- Deduplication in awk instead of `sort -u -k1,1` (which doesn't work as expected in BusyBox)

## Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial release — AP discovery, client detection, probed SSID collection, vendor lookup, GPS tagging, pcap capture, frame type analysis, channel heatmap, encryption breakdown, security findings, auto-update check, scan timer with estimated/actual runtime, network summary (groups BSSIDs into logical networks with private/ISP separation), channel quick reference, RSSI quick reference, frequency-based channel detection fallback (radiotap header), expanded channel hopping (DFS channels 52-144), client RSSI extraction, client vendor names in table, cleaned vendor name formatting, intelligence summary with weighted area classification, structured probed SSID output file |

## Author

**curtthecoder** — [github.com/curthayman](https://github.com/curthayman)

## Disclaimer

This tool is intended for authorized security testing and educational purposes only. Always obtain proper authorization before conducting wireless reconnaissance. I am not responsible for misuse of this tool, if you are a skid, don't put that shit on me. You should've been using it in the right manner!
