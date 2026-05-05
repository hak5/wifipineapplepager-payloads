# The Nosey Neighbor V2.0

**Passive wireless reconnaissance payload for the Pager**

> No attacks. No deauth. No mimic. Just listening.

The Nosey Neighbor is a comprehensive passive recon toolkit that sniffs the wireless environment around you, discovers access points, collects probed SSIDs, identifies device vendors, geo-tags findings with GPS, captures a traffic snapshot, and compiles everything into a detailed intel report — including an automated intelligence summary that interprets what the data means, because it may look like blah blah if you don't know how to read WiFi stuff.

## Features

| Feature | Description |
|---------|-------------|
| **AP Discovery** | Scans for nearby access points across 2.4 GHz and 5 GHz bands (including DFS channels) |
| **Network Summary** | Groups BSSIDs into logical networks, separating private networks from ISP hotspots with estimated physical device count |
| **Infrastructure Clustering** | Groups BSSIDs by OUI (manufacturer prefix) to reveal the actual number of physical routers/mesh nodes behind the BSSID flood. Shows all SSIDs each device broadcasts — guest networks, ISP hotspots, hidden VAPs — under one entry |
| **Client Detection** | Identifies active client devices with signal strength and vendor identification |
| **Probed SSID Collection** | Captures what networks nearby devices are actively looking for, with signal-based distance estimates. Output file is structured into new-this-session vs previously collected sections |
| **Hidden SSID Correlation** | Attempts to de-cloak hidden networks using two methods: OUI matching (hidden BSSID shares OUI with a named BSSID) and client-probe correlation (a client associated to the hidden AP is probing for a specific SSID) |
| **Vendor Identification** | Looks up device manufacturers via `whoismac` with clean formatted output |
| **GPS Geo-Tagging** | Tags each scan with GPS coordinates (requires GPS module) |
| **Traffic Snapshot** | Captures a passive pcap for offline analysis |
| **Active Session Detection** | Identifies sustained data sessions from the pcap by tracking Block Ack / RTS frame pairs between MAC addresses. Flags known streaming device OUIs (Roku, Fire TV, Apple TV, Chromecast, Samsung TV, Google/Nest, Vantiva). Cross-references AP BSSIDs against the scan to annotate each session with the network name |
| **802.11 Frame Breakdown** | Categorizes captured frames by type (Beacon, Probe, Data, etc.) |
| **Channel Heatmap** | Visualizes channel congestion with a bar chart |
| **Channel Quick Reference** | In-report guide explaining 2.4 GHz and 5 GHz channel bands (U-NII-1 through U-NII-3, DFS) |
| **RSSI Quick Reference** | In-report guide explaining signal strength values and what they mean |
| **Encryption Breakdown** | Shows the security posture of discovered networks |
| **Security Findings** | Flags open and WEP networks automatically |
| **Multi-Run Diff** | Compares each session against the previous run — shows new APs, gone APs, and new clients. Persists session data automatically across runs |
| **Returning Device Detection** | Tracks client devices across sessions in a persistent database. Each run shows returning devices with first-seen date and visit count, plus first-time devices |
| **Intelligence Summary** | Automatically interprets scan results — classifies area type (commercial/residential/mixed), identifies dominant infrastructure, proximity, vehicle/phone hotspots, device history, and vendor category breakdown |
| **BLE Axon Detection** | Scans for Axon body camera Bluetooth LE advertisements using known Axon OUI prefixes before the main recon phase. Alerts immediately with MAC and a vibrate pattern if one is detected nearby — so you know before you start scanning |
| **Auto-Exfil** | When WiFi is available at scan completion, delivers the report to a Discord webhook (full file attachment) and/or a push notification via ntfy.sh. Deploy and walk away |
| **Pre-Scan Menu** | Interactive `LIST_PICKER` menu at launch — toggle features and set recon duration before the scan starts, no file editing required (requires firmware 1.0.8) |
| **Auto-Update Check** | Checks GitHub for new versions on launch |
| **Scan Timer** | Shows estimated runtime at start and actual elapsed time in the report |

## How It Works

The payload runs through the following phases:

1. **Pre-Scan Menu** — Interactive `LIST_PICKER` menu (firmware 1.0.8+) to configure recon duration and toggle features before the scan starts
2. **BLE Axon Detection** — Scans for Axon body camera BLE advertisements using known Axon OUI prefixes. Alerts immediately with MAC address and vibrate pattern if detected. Runs before main recon so you know before you start.
3. **GPS Location Tag** — Acquires a GPS fix to geo-tag the scan (validates coordinates to reject junk data)
4. **System Status** — Logs battery, storage, and uptime
5. **Wireless Recon** — Primary scan uses `tcpdump` beacon sniffing on the monitor interface with background channel hopping across all bands (including DFS channels 52-144). Parses channel from both DS Parameter Set (`CH: N`) and radiotap frequency header (`NNNN MHz`) for reliable channel detection. Falls back to `iwinfo scan` and `iw scan` if needed. Sniffs client MACs with signal strength from the monitor interface.
6. **Infrastructure Clustering** — Groups the raw BSSID list by OUI prefix to reveal physical device clusters. Each entry shows the primary SSID, AP count, bands covered, closest signal, and all additional SSIDs (guest nets, ISP hotspots, hidden VAPs) that same hardware broadcasts.
7. **Multi-Run Diff** — Compares the current AP and client list against the previous session's saved state. Reports new and gone APs by BSSID+SSID, and count of new clients.
8. **Probed SSID Collection** — Uses PineAP's SSID pool collector to capture probe requests, with `tcpdump` probe-req sniffing for signal strength mapping. Diffs against a pre-scan snapshot to identify SSIDs new to this session. Also builds a MAC→probed-SSID map for use by the hidden SSID correlation phase.
9. **Hidden SSID Correlation** — Cross-references hidden BSSIDs against two sources: OUI matches with named BSSIDs from the same scan, and client-probe associations (clients connected to hidden APs that are also probing for named SSIDs). Reports probable SSID with confidence level.
10. **Vendor Identification** — Looks up MAC address vendors using `whoismac` for both APs and clients
11. **Returning Device Detection** — Reads the persistent `known_clients.db` and classifies each discovered client as returning (with first-seen date and visit count) or first-time. Updates the database before moving on.
12. **Traffic Snapshot** — Captures a passive pcap via `tcpdump` on the monitor interface. Analyzes frame types, detects sustained Block Ack / RTS sessions between MAC pairs (active data sessions), flags known streaming device OUIs, and cross-references AP BSSIDs to annotate sessions with network names.
13. **Security Findings** — Analyzes results for open and WEP networks
14. **Intelligence Summary** — Interprets the collected data using a weighted scoring system to classify area type, identify dominant infrastructure, flag notable detections, and profile device types by vendor category
15. **History Save** — Persists current session AP and client lists for the next run's diff
16. **Auto-Exfil** — If WiFi is available and configured, delivers the report to a Discord webhook and/or ntfy.sh push notification

## Startup Sequence

On launch, the payload displays a Curly-style scrolling banner and runs through pre-flight checks:

1. **Banner** — Displays payload name, description, and author
2. **Scan Timer** — Calculates and displays estimated runtime based on your configuration
3. **Version Check** — Fetches the latest version from GitHub and alerts if an update is available
4. **Pre-Scan Menu** — Interactive menu (firmware 1.0.8) to configure the run before it starts. Options: Start Scan, Recon Duration (Quick 15s / Standard 30s / Deep 60s / Marathon 120s), BLE Axon Scan toggle, History/Diff toggle, Hidden SSID Correlation toggle, Auto-Exfil toggle, About, Exit

## LED Indicators

| Color | Phase |
|-------|-------|
| Yellow | Startup / Banner |
| Red | BLE Axon scan (when enabled) |
| Blue | GPS acquisition / System status |
| Cyan | Wireless recon scanning |
| Green | Recon complete / GPS fix acquired |
| Magenta | Probed SSID collection |
| Yellow | Vendor lookups / No GPS fix |
| Red | Traffic capture |
| Green | Payload complete |

## Configuration

On firmware 1.0.8, key settings can be toggled interactively via the pre-scan menu at launch — no file editing required. All settings are also available at the top of `payload.sh` for static configuration:

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
STOP_PROBE_COLLECT=false                 # false = leave probe collection running after scan (default)
                                         # true  = stop probe collection when payload finishes

# --- v2.0: Advanced Intelligence ---
ENABLE_HISTORY=true               # Track runs over time (multi-run diff + returning device detection)
ENABLE_HIDDEN_CORRELATE=true      # Attempt to de-cloak hidden SSIDs via probe + OUI correlation
ENABLE_EXFIL=false                # Auto-send report via webhook when WiFi is available
EXFIL_WEBHOOK=""                  # Discord webhook URL (leave empty to skip)
EXFIL_NTFY_TOPIC=""               # ntfy.sh topic name for summary push (leave empty to skip)
EXFIL_SUMMARY_ONLY=false          # true = push summary stats only, false = attach full report file

# --- BLE Axon Detection ---
ENABLE_BLE_AXON_SCAN=true         # Scan for Axon body camera BLE advertisements before main recon
BLE_AXON_ATTEMPTS=3               # Number of 5-second scan attempts before giving up

# --- Update check ---
ENABLE_UPDATE_CHECK=true          # Fetch VERSION from GitHub on launch; alert if newer
```

**Estimated runtime** is calculated dynamically from these values and displayed at startup (typically ~3 minutes with default settings).

### Setting Up Auto-Exfil

**Discord:** Create a webhook in your Discord channel (Edit Channel → Integrations → Webhooks → New Webhook → Copy Webhook URL), then set:
```bash
ENABLE_EXFIL=true
EXFIL_WEBHOOK="https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN"
```
With `EXFIL_SUMMARY_ONLY=false` (default), the full report is uploaded as a file attachment. Set to `true` for a one-line stat ping instead.

**ntfy.sh:** A topic is just a URL path — you make up the name and anyone who knows it can subscribe. Pick something non-obvious (add random characters) since topics are public by default.

1. Install the ntfy app on your phone (iOS/Android)
2. Tap **Subscribe to topic** and enter your topic name (e.g. `nosey-recon-abc123`)
3. No account required — that's all the setup needed on the phone side
4. Set in the payload:
```bash
ENABLE_EXFIL=true
EXFIL_NTFY_TOPIC="nosey-recon-abc123"
```

When the scan completes and WiFi is available, your phone gets a push notification with a one-line summary:
```
Nosey Neighbor: 34 APs | 49 clients | 3 new probed SSIDs | Scan: 5m 46s | [!] 2 OPEN
```

> **Note:** If you want to keep notifications private, you can self-host ntfy and point it at your own server instead of `ntfy.sh`.

Both can be configured together — the report goes to Discord and a summary ping goes to ntfy.sh.

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
| **Infrastructure Clusters** | BSSIDs grouped by OUI — reveals physical device count and shows all SSIDs each router/mesh node is broadcasting |
| **Changes Since Last Run** | Diff against previous session — new APs, gone APs, new clients. Includes an in-report explanation of what NEW and GONE mean, what causes each, and how to interpret APs that bounce between the two across runs |
| **Probed SSIDs** | New-this-session and previously collected probe requests, with signal strength and distance estimates |
| **Hidden SSID Correlation** | Probable SSIDs for hidden networks, with confidence level and method (OUI match or client probe) |
| **Device Vendor Identification** | Full MAC-to-vendor mapping table |
| **Clients** | Client MAC, associated AP, SSID, RSSI, and Vendor name |
| **Device History** | Returning devices (first-seen date, visit count) and first-time devices |
| **Traffic Snapshot** | PCAP file info, packet count, 802.11 frame type breakdown, and active session detection (sustained Block Ack/RTS MAC pairs with streaming device flags and AP network name annotation) |
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

Each run creates a timestamped folder. Persistent state files live in the base loot directory and are shared across all sessions:

```
/root/loot/nosey-neighbor/
├── last_ap_list.txt          # BSSIDs from last run (for multi-run diff)
├── last_client_list.txt      # Client MACs from last run (for multi-run diff)
├── last_run_info.txt         # Timestamp and AP count from last run
├── known_clients.db          # Persistent client tracking database (grows over time)
├── 2026-02-17_143015/
│   ├── report_143015.txt        # Full recon report
│   ├── probed_ssids_143015.txt  # Probed SSIDs — new this session first, then previously collected
│   ├── vendors_143015.txt       # MAC-to-vendor mappings
│   ├── snapshot_143015.pcap     # Traffic capture
│   ├── gps_143015.txt           # GPS coordinates
│   └── debug_143015.txt         # Debug log, just in case something is strange or you have questions
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

The `known_clients.db` file accumulates every unique client MAC ever seen, with first-seen date, last-seen date, and visit count. It is updated in-place at the end of each run.

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
  │ aa:bb:cc:11:22:33  ExampleNetwork               6    -70   Encrypted
  │ dd:ee:ff:44:55:66  xfinitywifi                  44   -64   Open
  └──────────────────────────────────────────────────────────

  ┌─ INFRASTRUCTURE CLUSTERS ────────────────────────────────
  │  OUI       PRIMARY SSID               APs  BANDS          CLOSEST
  │  ────────  ────────────────────────  ────  ─────────────  ───────
  │  aa:bb:cc  MyHomeNetwork                6  2.4 + 5 GHz    -44 dBm
  │  dd:ee:ff  NETGEAR_5G                   6  2.4 + 5 GHz    -58 dBm
  │           ↳ (hidden)
  │           ↳ xfinitywifi
  │           ↳ Xfinity Mobile
  └──────────────────────────────────────────────────────────

  ┌─ CHANGES SINCE LAST RUN ─────────────────────────────────
  │  Last run: Mon Feb 17 08:12:00 UTC 2026
  │
  │  NEW APs (+2):
  │    + 11:22:33:44:55:66  LinksysXYZ
  │    + 77:88:99:aa:bb:cc  ASUS_Router
  │
  │  GONE APs (-1):
  │    - dd:ee:ff:00:11:22  TechCorp_Guest
  └──────────────────────────────────────────────────────────

── PROBED SSIDs (What devices are looking for) ────────────────
  NEW this session:      3
  Total in SSID pool:    66

  ┌─ NEW THIS SESSION ─────────────────────────────────────────
  │   1. HomeNetwork                       [-52dBm] ~3-8m (very close)
  │   2. OfficeWiFi                        [-71dBm] ~15-30m (in range)
  │   3. Starbucks                         [-85dBm] ~30-50m (moderate)
  └──────────────────────────────────────────────────────────

  ┌─ HIDDEN SSID CORRELATION ─────────────────────────────────
  │  HIDDEN BSSID        PROBABLE SSID             CONF    METHOD
  │  ──────────────────  ────────────────────────  ──────  ──────────────
  │  ff:ee:dd:cc:bb:aa   HomeNetwork_2G            MED     OUI match
  │  11:00:ff:ee:dd:cc   NETGEAR_5G                HIGH    client probe
  └──────────────────────────────────────────────────────────

  ┌─ DEVICE HISTORY ─────────────────────────────────────────
  │  RETURNING DEVICES (3 seen in previous sessions):
  │  MAC                 VENDOR                  FIRST SEEN      VISITS
  │  aa:bb:cc:dd:ee:01   Google, Inc.            2026-02-10 09:15  5 visits
  │  aa:bb:cc:dd:ee:02   Vantiva USA LLC         2026-02-12 14:30  3 visits
  │
  │  FIRST-TIME DEVICES (2):
  │  aa:bb:cc:dd:ee:03   Amazon Technologies     MyHomeNetwork
  └──────────────────────────────────────────────────────────

── SECURITY FINDINGS ──────────────────────────────────────────
  No open or WEP networks found. Good neighborhood.

── INTELLIGENCE SUMMARY ──────────────────────────────────────

  AREA OVERVIEW
  34 APs and 49 clients indicate a high-density commercial or business area.
  Dual-band environment: 18 x 2.4 GHz, 16 x 5 GHz BSSIDs.
  12 hidden SSID(s) detected.

  DOMINANT INFRASTRUCTURE
    - "CoffeeShop_WiFi" (4 BSSIDs)
    - "CorpOffice_BYOD" (4 BSSIDs)
    - "CoffeeShop_Guest" (4 BSSIDs)
  Multiple enterprise networks -- likely a commercial building or shared site.

  PROXIMITY
  Strongest AP: "CorpOffice_BYOD" at -58 dBm (nearby (~15m)).

  NOTABLE DETECTIONS
  * Vehicle hotspot: "FORD_HOTSPOT"

  ACTIVITY LEVEL
  49 active clients -- heavy foot traffic.

  SECURITY POSTURE
  All visible networks use modern encryption. Clean area.

  DEVICE PROFILE (by vendor category)
    Smart TV / AV:      1 device(s)
    Smart home / IoT:   1 device(s)

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
- Internet connection (optional — for version check, vendor lookups, and auto-exfil)
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

### Infrastructure Clustering
BSSIDs are grouped by OUI (the first 3 bytes / 8 characters of the MAC address), which identifies the hardware manufacturer. Since routers, gateways, and mesh nodes always assign all their virtual BSSIDs from the same OUI block, this reliably groups them back into physical devices. A single Comcast gateway, for example, will appear as 4-8 separate BSSIDs across channels and SSIDs (private network, guest network, xfinitywifi hotspot, Xfinity Mobile) — the cluster view collapses all of these under one entry.

### Hidden SSID Correlation
Two methods are used in parallel:
- **OUI match (MED confidence)** — if a hidden BSSID shares its OUI with a named BSSID in the same scan, it is almost certainly part of the same physical device and likely carries the same or a related SSID
- **Client probe (HIGH confidence)** — if a client is actively associated to a hidden AP and is also sending probe requests for a named SSID, the association strongly suggests that hidden AP is broadcasting that SSID

### Multi-Run Diff & Persistent State
At the end of each run, the payload saves `last_ap_list.txt` (BSSID + SSID, sorted) and `last_client_list.txt` (client MACs, sorted) to the base loot directory. On the next run, these files are compared against the current scan using awk to produce the new/gone AP lists. The `known_clients.db` file is a growing flat-file database (`MAC \t FIRST_SEEN \t LAST_SEEN \t VISIT_COUNT`) updated in-place each run.

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

| Version | Changes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2.0 | Infrastructure clustering (groups BSSIDs by OUI to reveal physical device count), multi-run diff (new/gone APs and clients vs previous session), hidden SSID correlation (OUI match + client probe methods with confidence levels), returning device detection with persistent `known_clients.db` tracking first-seen date and visit count, auto-exfil via Discord webhook (full report file) and ntfy.sh push notifications, MAC→probe-SSID map built during probe collection phase, in-report explanations for Infrastructure Clusters and Changes Since Last Run sections (explains what NEW/GONE APs mean, common causes, and how to interpret edge-of-range bouncing), BLE Axon body camera detection (scans for known Axon OUI prefixes via `hcitool lescan` before main recon — alerts with MAC address and vibrate pattern if detected, e.g. `[!!!] AXON BODY CAMERA DETECTED — 00:25:DF:95:BA:F8`), interactive pre-scan menu via `LIST_PICKER` (firmware 1.0.8+) for configuring recon duration and toggling features without editing the script |
| 1.0 | Initial release — AP discovery, client detection, probed SSID collection, vendor lookup, GPS tagging, pcap capture, frame type analysis, channel heatmap, encryption breakdown, security findings, auto-update check, scan timer with estimated/actual runtime, network summary (groups BSSIDs into logical networks with private/ISP separation), channel quick reference, RSSI quick reference, frequency-based channel detection fallback (radiotap header), expanded channel hopping (DFS channels 52-144), client RSSI extraction, client vendor names in table, cleaned vendor name formatting, intelligence summary with weighted area classification, structured probed SSID output file. Won a [Payload 🏆 Award!](https://payloadhub.com/blogs/payloads/the-nosey-neighbor) in February 2026                                                                                                                                                                                                                                                                                                                          |

## Author

**curtthecoder** — [github.com/curthayman](https://github.com/curthayman)

## Disclaimer

This tool is intended for authorized security testing and educational purposes only. Always obtain proper authorization before conducting wireless reconnaissance. I am not responsible for misuse of this tool, if you are a skid, don't put that shit on me. You should've been using it in the right manner!
