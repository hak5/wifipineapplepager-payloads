# Incident Response Scanner - Penetration Testing Payload

*Author:* **curtthecoder**

*Version:* **3.0**
## _Description_

A comprehensive incident response and penetration testing payload for the Pineapple Pager that performs extensive network reconnaissance, forensic collection, and security analysis. This payload includes advanced features specifically designed for professional penetration testing engagements.

**NEW in v3.0**: NSE script support via bundled `share/nmap` directory — nmap now uses the full script library for richer service enumeration, OS fingerprinting, vulnerability detection, SSL/TLS cipher analysis, and printer discovery.

*Also after you run this, there will be a lot of juicy data in the folders. Nothing juicy displays on the pager while it's running. So for demoing purposes, not unless you are in a testing environment, you may want to keep this data to yourself, or share with someone you are running the report for.*

---

## _Deployment_

### Folder Structure (Important)

The payload **must** be placed in the following directory structure on the Pager:

```
/root/payloads/user/incident_response/incident_scanner/
├── payload.sh
├── VERSION
└── share/
    └── nmap/
        └── scripts/       ← NSE scripts live here
```

- The `incident_scanner/` folder must be inside `incident_response/`
- The `share/` folder must be in the **same directory as `payload.sh`**
- The full path to NSE scripts on the Pager must be:
  `/root/payloads/user/incident_response/incident_scanner/share/nmap/scripts`

### Deployment Steps
1. Copy the entire `incident_scanner/` folder into `/root/payloads/user/incident_response/` on your Pager
2. Verify both `payload.sh` and `VERSION` are present
3. Verify `share/nmap/scripts/` exists and contains `.nse` files
4. Run the payload via the Pager interface

---

## _Scan Types_

Choose your scan type based on time available and depth needed:

| Scan Type | Duration   | Best For |
|-----------|------------|----------|
| **QUICK** | ~1-5 min   | Initial recon, time-sensitive situations |
| **NORMAL** | ~10-15 min | Standard penetration tests, most scenarios |
| **DEEP** | ~30+ min   | Full incident response, detailed forensics |

### What Each Scan Includes

#### QUICK Scan (~1-5 min)
Core reconnaissance - fast snapshot of the environment:
- System Information (processes, memory, disk)
- Network Configuration (interfaces, routing, ARP, connections)
- WiFi Scan (nearby networks with basic security info)
- DHCP Leases
- Firewall Rules (nftables/iptables)
- Log Collection

#### NORMAL Scan (~10-15 min)
Everything in QUICK, plus:
- Client Fingerprinting (MAC OUI lookup, nmap OS fingerprinting)
- Rogue Device Detection (rogue DHCP with active probe, duplicate IPs, MAC spoofing)
- Traffic Capture (30 seconds)
- Credential Scanning (FTP, HTTP, Telnet, SMTP, etc.)
- Geolocation (GPS if available, WiFi-based positioning)
- Historical Comparison (detect new networks/clients since last scan)

#### DEEP Scan (~30+ min)
Everything in NORMAL, plus:
- Extended Traffic Capture (120 seconds)
- Service Discovery with NSE scripts (mDNS, NetBIOS, SNMP, UPnP, SMB)
- General Service Enumeration (SSH, HTTP, HTTPS, RDP with banners, SSL certs, cipher analysis)
- Printer Discovery (raw port 9100, IPP 631, LPD 515)
- Vulnerability Scan (nmap vuln category across all live hosts)
- Wireless Recon with monitor mode (channel hopping, probe requests)
- Bluetooth/BLE Scanning
- Full WiFi Security Analysis (handshakes, encryption weaknesses, evil twin detection)
- Recon.db Analysis (historical Pineapple intelligence)

### Selecting a Scan Type

When you run the payload, you'll be prompted to select your scan type:

```
=== INCIDENT RESPONSE SCANNER ===

Select scan type:

1. QUICK  (~1-5 min)  - Fast recon
2. NORMAL (~10-15 min) - Balanced scan
3. DEEP   (~30+ min)  - Full forensics

Select scan type (1-3): [3]
```

Use the number picker to select your preferred scan depth. The default is DEEP (3) if no selection is made.

---

## _Features_

### Core Functionality
- **System Information Collection**: Captures system state, processes, memory usage, and disk information
- **Network Configuration**: Documents all network interfaces, routing tables, ARP cache, and active connections
- **Wireless Analysis**: Scans WiFi environment and analyzes connected clients
- **Traffic Capture**: Records network traffic across all interfaces with configurable duration
- **DHCP Analysis**: Collects and analyzes DHCP lease information
- **Firewall Auditing**: Captures nftables/iptables rules with plain-English analysis

### Advanced Features

#### 1. NSE Script Engine (v3.0)
The payload bundles nmap's full NSE script library in `share/nmap/scripts/`, enabling deep protocol analysis without relying on what may or may not be installed system-wide. Idea from brAinphreAk's Loki Payload using the scripts. Great Idea!

**How it works:**
- `nmap_run()` wrapper automatically passes `--datadir /root/payloads/user/incident_response/incident_scanner/share/nmap` to every nmap call
- Falls back to plain `nmap` if the directory isn't present
- Startup log confirms whether NSE scripts are active

**Scripts used per service:**
| Service | Port | NSE Scripts |
|---------|------|-------------|
| mDNS/Bonjour | 5353/UDP | `dns-service-discovery` |
| NetBIOS Name | 137/UDP | `nbstat` |
| NetBIOS Session | 139/TCP | `smb-os-discovery` |
| SNMP | 161/UDP | `snmp-info`, `snmp-sysdescr` |
| SMB | 445/TCP | `smb-security-mode`, `smb-os-discovery`, `smb-vuln-ms17-010` |
| General (NORMAL) | 22,80,443,etc | `banner`, `http-title`, `ssl-cert` |
| General (DEEP) | 22,80,443,etc | + `http-server-header`, `ssl-heartbleed`, `ssl-enum-ciphers`, `smb-security-mode` |

**Output**: Enhanced output in all `services/` files + `services/general_services.txt`

#### 2. WiFi Security Analysis (Pentesting Intelligence)
Comprehensive deep-dive analysis of captured 802.11 frames to extract actionable pentesting intelligence:

**a) Client Probe Request Intelligence**
- Reveals networks clients have previously connected to (home/work/travel networks)
- Tracks device movement patterns and location history
- Identifies corporate network SSIDs for social engineering
- Shows which clients are searching for which networks
- Enables evil twin attack targeting based on client history

**b) Hidden SSID Detection & De-cloaking**
- Detects access points broadcasting with blank/hidden SSIDs
- Attempts to reveal real SSID names via probe responses
- Maps hidden networks to their BSSIDs

**c) WPA/WPA2/WPA3 Handshake Detection**
- Passively detects EAPOL 4-way handshakes
- Identifies complete handshakes ready for offline cracking
- Reports which networks have capturable handshakes
- Provides export commands for hashcat/aircrack-ng
- No deauth required (passive capture)

**d) Encryption Weakness Analysis**
- **CRITICAL**: Identifies WEP networks (trivially crackable)
- **HIGH RISK**: Detects WPS-enabled networks (vulnerable to Reaver/Pixie Dust)
- **HIGH RISK**: Finds TKIP cipher usage (deprecated, vulnerable)
- **SECURE**: Maps WPA2/WPA3 with AES/CCMP
- Provides vulnerability ratings and remediation advice

**e) Rogue AP & Evil Twin Detection**
- Detects multiple BSSIDs using the same SSID
- Identifies potential evil twin attacks in progress
- Maps legitimate enterprise networks with multiple APs
- Compares signal strengths to identify suspicious rogues

**f) Client-to-AP Association Mapping**
- Maps which clients are connecting to which access points
- Tracks client movement between APs
- Identifies high-value targets on corporate networks

**g) Signal Strength & Proximity Analysis**
- Estimates physical distance to APs based on signal strength
- Prioritizes closest/strongest targets for attacks
- Identifies mobile hotspots (varying signal patterns)
- Categorizes by proximity: VERY CLOSE (<5m) to VERY FAR (>50m)

**Output**: `security_analysis/` directory with 7 detailed reports + summary

#### 3. Bluetooth/BLE Device Scanning
Scans for nearby Bluetooth devices that may represent security risks:
- **Classic Bluetooth**: Discovers discoverable Bluetooth devices using `hcitool`
- **Bluetooth Low Energy (BLE)**: Full BLE scan with adapter reset before scanning to clear stuck state; uses line-buffered pipe output to ensure all discovered devices are captured
- **Device Information**: Captures MAC addresses, device names, and class information
- **Graceful Degradation**: Works with or without Bluetooth adapter present

**Use Cases**:
- Identify unauthorized wireless peripherals
- Detect IoT devices with weak security
- Correlate mobile devices for forensic analysis
- Discover Bluetooth-based tracking beacons

**Output**: `bluetooth/bluetooth_devices.txt`

#### 4. Enhanced Client Fingerprinting
- **MAC OUI Lookup**: Identifies device manufacturers from MAC addresses
- **nmap OS Fingerprinting**: Uses `nmap -O --osscan-guess` for accurate TCP/IP stack-based OS detection (replaces basic TTL guessing)
- **DHCP Fingerprinting**: Analyzes hostnames and DHCP parameters for device identification
- **Vendor Intelligence**: Built-in database of common MAC OUI prefixes
- **Fallback**: TTL-based detection if nmap unavailable

**Output**: `analysis/client_fingerprinting.txt`

#### 5. Credential & Sensitive Data Detection
Scans packet captures for cleartext credentials across multiple protocols using `tcpdump`:
- **FTP**: Username and password extraction
- **HTTP Basic Auth**: Base64-decoded credentials
- **HTTP POST Data**: Form submission analysis (login forms, password fields)
- **Telnet**: Authentication data capture
- **SMTP**: Email authentication credentials
- **POP3/IMAP**: Email account credentials
- **SMB/NTLM**: Windows authentication detection
- **Kerberos**: Domain authentication traffic detection
- **LDAP**: Directory service authentication
- **Database Protocols**: Detection of MySQL, PostgreSQL, Redis, VNC traffic

**Output**: `credentials/credential_scan.txt` (restricted permissions: 600)

#### 6. Service Discovery & Enumeration (NSE-enhanced)
All service scans now use `nmap_run()` with targeted NSE scripts for richer output:
- **mDNS/Bonjour**: Discovers AirPlay, Chromecast, printers via `dns-service-discovery`
- **NetBIOS**: Enumerates Windows network names via `nbstat` and `smb-os-discovery`
- **SNMP**: System description and device info via `snmp-info`, `snmp-sysdescr`
- **UPnP**: Universal Plug and Play device discovery
- **SMB/CIFS**: Security mode, OS detection, and EternalBlue check via `smb-vuln-ms17-010`

**Output**: `services/` directory with protocol-specific files

#### 7. General Service Enumeration (NEW in v3.0)
Scans all live hosts for common services with NSE-enhanced output:
- **Ports**: 22 (SSH), 23 (Telnet), 80 (HTTP), 443 (HTTPS), 3389 (RDP), 8080, 8443
- **NORMAL**: Service banners, HTTP page titles, SSL certificate info
- **DEEP**: Adds HTTP server headers, Heartbleed check, SSL cipher enumeration (flags TLS 1.0/1.1, RC4, weak ciphers)

**Output**: `services/general_services.txt`

#### 8. Printer Discovery (NEW in v3.0)
Detects network printers with exposed print ports — a common finding in pen test reports:
- **Port 9100 (JetDirect/Raw)**: Unauthenticated raw print, highest risk — grabs device banner
- **Port 631 (IPP)**: Internet Printing Protocol — identifies device via page title
- **Port 515 (LPD/LPR)**: Legacy line printer daemon
- Affected IPs listed with proof-of-concept command for report inclusion
- Findings automatically fed into severity scoring

**Output**: `services/printer_discovery.txt`

#### 9. Vulnerability Scan (NEW in v3.0, DEEP only)
Runs `nmap --script vuln` across all live hosts on the local network:
- Checks for known CVEs across all discovered services
- Includes EternalBlue (MS17-010), Shellshock, Heartbleed, and more
- Only reports vulnerable hosts — clean hosts produce no output
- Findings automatically classified as CRITICAL in severity scoring

**Output**: `analysis/vuln_scan.txt`

#### 10. Rogue Device Detection
Comprehensive security analysis with intelligent whitelisting:
- **Rogue DHCP Servers**: Log-based detection + active `broadcast-dhcp-discover` probe (v3.0) to catch DHCP servers that haven't appeared in logs yet
- **Multiple Gateways**: Identifies potential rogue routers or MITM attacks
- **Interface Classification**: Documents all network interfaces with context (Pineapple-aware)
- **MAC Spoofing Detection**: Flags suspicious locally-administered MACs with smart whitelisting for Pineapple `13:37` signature MACs
- **MAC Randomization Detection**: Identifies devices using randomized MAC addresses
- **Duplicate IP Detection**: Detects ARP spoofing attacks or IP conflicts
- **Evil Twin AP Detection**: Identifies duplicate SSIDs on different frequencies
- **NAT Configuration Analysis**: Verifies proper routing setup

**Output**: `analysis/rogue_device_detection.txt`

#### 11. Geolocation & Physical Security
- **GPS Integration**: Captures GPS coordinates if GPS hardware available
- **WiFi Geolocation**: Documents nearby BSSIDs for triangulation via geolocation APIs
- **Timezone Tracking**: Records system timezone and timestamps
- **Temperature Monitoring**: Logs thermal sensor data if available
- **Signal Strength Mapping**: Maps strongest networks for proximity estimation

**Output**: `analysis/geolocation.txt`

#### 12. Timeline & Historical Analysis
- **Change Detection**: Compares current scan with previous scans
- **New Network Detection**: Identifies newly appeared WiFi networks
- **New Client Detection**: Flags new devices since last scan
- **Trend Analysis**: Shows deltas in network/client counts over time

**Output**: `timeline/scan_metadata.txt`

#### 13. Severity Scoring System
Automated risk assessment with weighted scoring:
- **CRITICAL (100 pts)**: Cleartext credentials, active deauthentication attacks, vulnerabilities detected by nmap vuln scan
- **HIGH (75 pts)**: WEP networks, rogue DHCP servers, duplicate IPs, Evil Twin APs
- **MEDIUM (50 pts)**: Open networks, WPS-enabled networks, suspicious MACs, exposed printer ports (9100)
- **LOW (25 pts)**: Hidden SSIDs, randomized MAC addresses

**Output**: Included in `SUMMARY_REPORT.txt` under "SEVERITY SUMMARY"

#### 14. Pineapple Recon Database Integration
Analyzes the Pager's recon.db for historical intelligence:
- **Device History**: All devices ever seen by the Pager
- **Network Discovery**: All SSIDs and access points discovered
- **Captured Credentials**: Cleartext passwords from Evil Twin attacks
- **NTLM Hashes**: Challenge-response captures for offline cracking
- **WPA Handshakes**: Both passive and Evil Twin captured handshakes
- **Evil Twin Victims**: Devices that connected to rogue APs

**Output**: `analysis/recon_intelligence.txt` + copy of `recon.db`

#### 15. Data Exfiltration & Security
- **AES-256 Encryption**: Optional encryption of final archive
- **Remote Sync**: Automatic upload to remote server via SCP/SFTP/CURL
- **Configurable Methods**: Supports multiple transfer protocols

---

## _Configuration_

Edit the configuration variables at the top of `payload.sh`:

```bash
# ============================================================================
# SCAN TYPE SELECTION
# ============================================================================
# Scan type is selected interactively when you run the payload.
# You'll be prompted to choose: 1=QUICK, 2=NORMAL, 3=DEEP

# Scan Identification
SCAN_LABEL=""                     # Add custom label to folder name (e.g., "office_breach", "client_site_a")
                                  # Leave empty for timestamp-only naming

# ============================================================================
# CAPTURE SETTINGS (can be overridden regardless of scan type)
# ============================================================================
PCAP_SNAPLEN=65535                # Full packet capture
PCAP_COUNT=10000                  # Max packets per interface

# Wireless Reconnaissance Configuration (used when ENABLE_WIRELESS_RECON=true)
CHANNEL_HOP_INTERVAL=0.5          # Seconds per channel
RECON_PHY="auto"                  # Physical device: "auto" or specify "phy0", "phy1", etc.

# Nmap Data Directory (NSE Scripts)
NMAP_DATADIR="/root/payloads/user/incident_response/incident_scanner/share/nmap"

# Recon Database Path
RECON_DB_PATH="/root/recon/recon.db"

# ============================================================================
# ARCHIVE & REMOTE SYNC
# ============================================================================
ENABLE_REMOTE_SYNC=false          # Enable auto-upload
ENCRYPT_ARCHIVE=false             # Enable AES-256 encryption

# Remote Sync (if ENABLE_REMOTE_SYNC=true)
REMOTE_SERVER=""                  # user@server.com
REMOTE_PATH=""                    # /remote/path/
REMOTE_METHOD="scp"               # scp, sftp, or curl

# Encryption (if ENCRYPT_ARCHIVE=true)
ENCRYPTION_PASSWORD=""            # Set password or leave empty for prompt
```

---

## _Automatic Update Check_

The payload includes an automatic version check that compares your local version against the latest on GitHub.

- On startup, checks GitHub for the latest version (3-second timeout)
- If a newer version is available, you'll see an alert with update information
- Fails silently if offline or GitHub is unreachable

**To disable:** Set `ENABLE_UPDATE_CHECK=false` in `payload.sh`

---

## _Output Structure_

```
/root/loot/incident_response/IR_YYYYMMDD_HHMMSS_[label]/
├── SUMMARY_REPORT.txt                  # Executive summary with severity scoring
├── system/
│   ├── scanner_device.txt              # Scanning device info (chain of custody)
│   └── target_environment.txt         # Target network environment
├── network/
│   ├── network_config.txt             # Interfaces and routing
│   ├── connections.txt                # Active connections
│   ├── dns_info.txt                   # DNS configuration
│   ├── dhcp_leases.txt                # DHCP lease information
│   └── firewall_rules.txt             # Firewall rules with plain-English analysis
├── wireless/
│   ├── wireless_info.txt              # Interface information
│   ├── wifi_scan.txt                  # Nearby networks
│   ├── security_analysis.txt          # Vulnerability assessment
│   └── connected_clients.txt          # Connected client details
├── bluetooth/
│   └── bluetooth_devices.txt          # Bluetooth/BLE device scan results
├── pcaps/
│   ├── wireless_recon_*.pcap          # Full wireless capture (monitor mode)
│   ├── probe_requests_*.pcap          # Probe request frames
│   ├── beacons_*.pcap                 # Beacon frames
│   ├── deauth_*.pcap                  # Deauth/disassoc frames
│   └── local_network_*.pcap           # br-lan traffic capture
├── analysis/
│   ├── client_fingerprinting.txt      # OS detection + MAC fingerprinting
│   ├── nearby_access_points.txt       # AP list from beacon analysis
│   ├── probe_requests.txt             # Devices and networks searched for
│   ├── deauth_detection.txt           # Deauth attack detection
│   ├── wireless_recon_summary.txt     # Frame type breakdown
│   ├── rogue_device_detection.txt     # Rogue DHCP, ARP spoofing, evil twin
│   ├── vuln_scan.txt                  # nmap vuln scan results (DEEP only)
│   ├── recon_intelligence.txt         # Pager recon.db analysis
│   ├── recon.db                       # Copy of recon database
│   └── geolocation.txt               # GPS/WiFi location data
├── security_analysis/                 # WiFi pentesting intelligence (DEEP only)
│   ├── 00_SUMMARY.txt
│   ├── 01_client_probe_intelligence.txt
│   ├── 02_hidden_ssid_detection.txt
│   ├── 03_wpa_handshake_detection.txt
│   ├── 04_encryption_analysis.txt
│   ├── 05_rogue_ap_detection.txt
│   ├── 06_client_ap_mapping.txt
│   └── 07_signal_proximity_analysis.txt
├── services/
│   ├── mdns_discovery.txt             # mDNS + dns-service-discovery NSE
│   ├── netbios_enum.txt               # NetBIOS + nbstat/smb-os-discovery NSE
│   ├── snmp_discovery.txt             # SNMP + snmp-info/sysdescr NSE
│   ├── upnp_discovery.txt             # UPnP/SSDP discovery
│   ├── smb_enum.txt                   # SMB + security/OS/EternalBlue NSE
│   ├── general_services.txt           # SSH/HTTP/HTTPS/RDP with banners + SSL (NEW)
│   └── printer_discovery.txt          # Port 9100/631/515 printer detection (NEW)
├── credentials/
│   └── credential_scan.txt            # SENSITIVE - chmod 600
├── timeline/
│   └── scan_metadata.txt
└── logs/
    └── [system logs]
```

---

## _Dependencies_

### Core Requirements (Built-in on Pager)
- bash
- tcpdump
- iw / iwconfig
- ifconfig / ip
- arp
- netstat / ss
- nmap (`/usr/bin/nmap`) — required for all NSE-enhanced scanning
- nftables / iptables

### NSE Scripts (share/nmap)
NSE scripts must be present at:
```
/root/payloads/user/incident_response/incident_scanner/share/nmap/scripts/
```
Since nmap is pre-installed on the Pager, the scripts directory should already be present at that path as part of the payload deployment.

### Enhanced Features (Optional)
- **sqlite3**: Recon database analysis (usually built-in)
- **hcitool/bluetoothctl**: Bluetooth/BLE device scanning
- **openssl**: Archive encryption
- **scp/sftp/curl**: Remote sync capabilities
- **jq**: GPS data parsing
- **strings**: Enhanced credential extraction (usually built-in)

---

## _Usage_

### Basic Usage
1. Copy the entire `incident_scanner/` folder into `/root/payloads/user/incident_response/` on your Pager
2. Verify `share/nmap/scripts/` is present alongside `payload.sh`
3. Run the payload via the Pager interface
4. Select your scan type when prompted

### Advanced Configuration Examples

#### Example 1: Labeled Site Survey
```bash
SCAN_LABEL="site_survey"
# When prompted, select 1 for QUICK scan
```

#### Example 2: Encrypted Archive
```bash
ENCRYPT_ARCHIVE=true
ENCRYPTION_PASSWORD="YourStrongPassword123!"
```

#### Example 3: Full Incident Response with Remote Exfiltration
```bash
SCAN_LABEL="ir_investigation"
ENABLE_REMOTE_SYNC=true
REMOTE_SERVER="user@c2-server.com"
REMOTE_PATH="/var/loot/pager"
REMOTE_METHOD="scp"
ENCRYPT_ARCHIVE=true
```

#### Example 4: Multiple Daily Engagements
```bash
SCAN_LABEL="office_breach"        # Creates: IR_20260118_143052_office_breach
SCAN_LABEL="Client Site A"        # Creates: IR_20260118_150322_client_site_a
SCAN_LABEL="after-hours-scan"     # Creates: IR_20260118_203015_after_hours_scan
```

---

## _Security Considerations_

### Legal & Ethical
- **Authorization Required**: Only use on networks you own or have explicit written permission to test
- **Data Sensitivity**: Credential scans may capture highly sensitive information
- **Compliance**: Ensure compliance with local laws and regulations (CFAA, GDPR, etc.)
- **Scope Limitation**: Configure features appropriate to your engagement scope

### Operational Security
- **Encrypted Archives**: Always encrypt archives when capturing credentials
- **Secure Transport**: Use encrypted channels (SCP/SFTP) for remote sync
- **Restricted Permissions**: Credential files are automatically chmod 600

---

## _Penetration Testing Workflow_

### Pre-Engagement
1. Configure payload for engagement scope
2. Set appropriate capture duration
3. Configure encryption and exfiltration if needed
4. Test on authorized network first

### During Engagement
1. Open Pager at target location and run the payload
2. Select scan type based on time available
3. Monitor progress via Pager interface

### Post-Engagement Analysis
1. Review `SUMMARY_REPORT.txt` for quick overview and severity scoring
2. Check `analysis/vuln_scan.txt` for CVEs and vulnerabilities (DEEP)
3. Check `services/printer_discovery.txt` for exposed print ports
4. Check `services/general_services.txt` for service inventory and SSL weaknesses
5. Analyze `wireless/security_analysis.txt` for vulnerable networks
6. Check `credentials/credential_scan.txt` for exposed credentials
7. Review `bluetooth/bluetooth_devices.txt` for nearby Bluetooth devices
8. Examine remaining `services/*` files for attack surface mapping
9. Deep-dive PCAPs with Wireshark for detailed analysis

### Reporting
1. Use `SUMMARY_REPORT.txt` for executive summary
2. Reference the **Severity Summary** for risk metrics
3. Use printer findings from `services/printer_discovery.txt` — includes proof-of-concept command
4. Include SSL cipher findings from `services/general_services.txt` for TLS hardening recommendations
5. Sanitize sensitive data before client delivery

---

## _Severity Scoring Reference_

| Severity | Points | Trigger Conditions |
|----------|--------|--------------------|
| CRITICAL | 100 | Cleartext credentials, active deauth attacks, nmap vuln findings |
| HIGH | 75 | WEP networks, rogue DHCP, duplicate IPs, Evil Twin APs |
| MEDIUM | 50 | Open networks, WPS-enabled, suspicious MACs, exposed printer port 9100 |
| LOW | 25 | Hidden SSIDs, randomized MACs |

**Overall Risk Levels**:
- **CRITICAL** (200+ pts): Immediate action required
- **HIGH** (100-199 pts): Significant issues found
- **MEDIUM** (50-99 pts): Issues require attention
- **LOW** (1-49 pts): Minor issues detected
- **CLEAN** (0 pts): No significant issues

---

## _Troubleshooting_

### NSE Scripts Not Running
- Verify `share/nmap/scripts/` exists at the correct path
- Check startup LOG — it will confirm whether NSE scripts are active or not
- The payload falls back to plain nmap if scripts aren't found — scans still run, just without script output

### BLE Scan Shows No Devices
- Adapter is automatically reset (down/up) before BLE scan in v3.0 — if still empty, check `hciconfig` manually
- BLE devices must be actively advertising to be detected
- Classic Bluetooth and BLE are separate scans — a device may show in one but not the other

### Channel Display Shows "?"
- Fixed in v3.0 — channel hopper writes current channel to a temp file that the progress display reads directly

### Printer Discovery Finds Nothing
- Only runs in DEEP scan mode
- Port 9100 must be open and reachable — many enterprise printers have this exposed by default

### Vuln Scan Is Slow
- The nmap vuln category runs many scripts across all ports on all live hosts — 120 second timeout applies
- If no vulnerabilities exist the output file will only show the scan header, which is the correct clean result

### Deep Packet Analysis Shows "[Skip]" Messages
- Normal behavior for monitor mode captures (raw 802.11 frames have no IP layer)
- IP-based credential analysis only works on `local_network_*.pcap`

### Remote Sync Fails
- Verify network connectivity to remote server
- Check SSH key authentication is configured
- Test manual SCP/SFTP first

---

## _Performance Notes_

| Scan Type | Typical Duration | Archive Size |
|-----------|-----------------|--------------|
| QUICK | 1-5 minutes | 10-50 MB |
| NORMAL | 10-15 minutes | 50-150 MB |
| DEEP | 30+ minutes | 100-500 MB |

### Feature Timing Breakdown
- Service discovery adds ~3-5 minutes (NSE scripts add depth vs. speed)
- Vulnerability scan adds ~2 minutes (DEEP only)
- Bluetooth scanning adds ~45 seconds (classic 15s + BLE 30s)
- Traffic capture: 0s (QUICK) / 30s (NORMAL) / 120s (DEEP)
- Printer discovery adds ~30 seconds (DEEP only)

---

## _Credits_

- **Author**: curtthecoder
- **Version**: 3.0
- **Tools**: nmap (NSE), tcpdump, iw, hcitool, various network utilities
- **Printer detection**: Inspired by Paper-Pusher (github.com/OSINTI4L/Paper-Pusher)

---

## _Changelog_

### v3.0
- **NEW**: NSE script engine — `nmap_run()` wrapper uses bundled `share/nmap` for all nmap calls
- **NEW**: General service enumeration (`services/general_services.txt`) — SSH/HTTP/HTTPS/RDP with banners, SSL certs, and cipher analysis
- **NEW**: Printer discovery (`services/printer_discovery.txt`) — detects exposed port 9100/631/515 with severity scoring
- **NEW**: Vulnerability scan (`analysis/vuln_scan.txt`) — `nmap --script vuln` across all live hosts (DEEP only)
- **IMPROVED**: All service discovery scans enhanced with targeted NSE scripts (dns-service-discovery, nbstat, smb-os-discovery, snmp-info, smb-vuln-ms17-010, etc.)
- **IMPROVED**: OS fingerprinting replaced TTL-based guessing with `nmap -O --osscan-guess` (much more accurate)
- **IMPROVED**: Rogue DHCP detection now includes active `broadcast-dhcp-discover` probe in addition to log parsing
- **IMPROVED**: BLE scan — adapter reset before scan clears stuck LE state; pipe buffering fix ensures devices are captured
- **IMPROVED**: Channel display during capture — reads from temp file written by hopper (no more "?" display)
- **IMPROVED**: DEEP scan adds `ssl-enum-ciphers` for TLS weakness detection on discovered HTTPS services

### v2.0
- **NEW**: Interactive Scan Type Selection (QUICK / NORMAL / DEEP)
- Features automatically enabled/disabled based on scan type
- Updated output to show scan type in reports and summaries

### v1.0
- Initial release with full feature set

---

## _License_

Use responsibly and only with proper authorization. I am not responsible for misuse or damage caused by this tool.

## _Support_

For issues, feature requests, or questions:
- Review this README thoroughly
- Check Hak5's Discord — I'm always in there
- Verify NSE scripts are present in `share/nmap/scripts/`
- Check the startup LOG for NSE script status

---

**HAPPY PENTESTING!**
