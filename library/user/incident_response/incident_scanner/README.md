# Incident Response Scanner - Penetration Testing Payload

*Author:* **curtthecoder**

*Version:* **2.0**
## _Description_

A comprehensive incident response and penetration testing payload for the Pineapple Pager that performs extensive network reconnaissance, forensic collection, and security analysis. This payload includes advanced features specifically designed for professional penetration testing engagements.

**NEW in v2.0**: Interactive scan type selection - choose **QUICK**, **NORMAL**, or **DEEP** via on-device prompt to match your time constraints and assessment needs.

*Also after you run this, there will be a lot of juicy data in the folders. Nothing juicy displays on the pager while it's running. So for demoing purposes, not unless you are in a testing enviroment, you may want to keep this data to yourself, or share with someone you are running the report for.*

## _Scan Types_

Choose your scan type based on time available and depth needed:

| Scan Type | Duration   | Best For |
|-----------|------------|----------|
| **QUICK** | ~1-5 min   | Initial recon, time-sensitive situations |
| **NORMAL** | ~10-15 min | Standard penetration tests, most scenarios |
| **DEEP** | ~25+ min   | Full incident response, detailed forensics |

### What Each Scan Includes

#### QUICK Scan (~1-5 min)
Core reconnaissance - fast snapshot of the environment:
- System Information (processes, memory, disk)
- Network Configuration (interfaces, routing, ARP, connections)
- WiFi Scan (nearby networks with basic security info)
- DHCP Leases
- Firewall Rules (iptables)
- Log Collection

#### NORMAL Scan (~10-15 min)
Everything in QUICK, plus:
- Client Fingerprinting (MAC OUI lookup, OS detection)
- Rogue Device Detection (rogue DHCP, duplicate IPs, MAC spoofing)
- Traffic Capture (30 seconds)
- Credential Scanning (FTP, HTTP, Telnet, SMTP, etc.)
- Geolocation (GPS if available, WiFi-based positioning)
- Historical Comparison (detect new networks/clients since last scan)

#### DEEP Scan (~25+ min)
Everything in NORMAL, plus:
- Extended Traffic Capture (120 seconds)
- Service Discovery (mDNS, NetBIOS, SNMP, UPnP, SMB)
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
3. DEEP   (~25+ min)  - Full forensics

Select scan type (1-3): [3]
```

Use the number picker to select your preferred scan depth. The default is DEEP (3) if no selection is made.

## _Features_

### Core Functionality
- **System Information Collection**: Captures system state, processes, memory usage, and disk information
- **Network Configuration**: Documents all network interfaces, routing tables, ARP cache, and active connections
- **Wireless Analysis**: Scans WiFi environment and analyzes connected clients
- **Traffic Capture**: Records network traffic across all interfaces with configurable duration
- **DHCP Analysis**: Collects and analyzes DHCP lease information
- **Firewall Auditing**: Captures iptables rules across all tables

### Advanced Features

#### 1. WiFi Security Analysis (Pentesting Intelligence)
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
- **SECURE**: Identifies WPA2-Enterprise (802.1X)
- Provides vulnerability ratings and remediation advice

**e) Rogue AP & Evil Twin Detection**
- Detects multiple BSSIDs using the same SSID
- Identifies potential evil twin attacks in progress
- Maps legitimate enterprise networks with multiple APs
- Compares signal strengths to identify suspicious rogues
- Detects Karma/Honeypot attacks

**f) Client-to-AP Association Mapping**
- Maps which clients are connecting to which access points
- Tracks client movement between APs
- Identifies high-value targets on corporate networks
- Shows active association events with timestamps

**g) Signal Strength & Proximity Analysis**
- Estimates physical distance to APs based on signal strength
- Prioritizes closest/strongest targets for attacks
- Identifies mobile hotspots (varying signal patterns)
- Estimates attacker proximity if rogue AP detected
- Categorizes by proximity: VERY CLOSE (<5m) to VERY FAR (>50m)

**Pentesting Use Cases**:
- Evil twin attack preparation (target specific client histories)
- WPA handshake capture for offline password auditing
- Identify weak encryption for quick wins
- Rogue AP detection and analysis
- Physical security assessment (proximity to targets)
- Client device tracking and profiling

**Output**: `security_analysis/` directory with 7 detailed reports + summary

#### 2. Bluetooth/BLE Device Scanning
Scans for nearby Bluetooth devices that may represent security risks:
- **Classic Bluetooth**: Discovers discoverable Bluetooth devices using `hcitool`
- **Bluetooth Low Energy (BLE)**: Scans for BLE devices and beacons
- **Device Information**: Captures MAC addresses, device names, and class information
- **Graceful Degradation**: Works with or without Bluetooth adapter present

**Use Cases**:
- Identify unauthorized wireless peripherals
- Detect IoT devices with weak security
- Correlate mobile devices for forensic analysis
- Discover Bluetooth-based tracking beacons

**Output**: `bluetooth/bluetooth_devices.txt`

#### 3. Enhanced Client Fingerprinting
- **MAC OUI Lookup**: Identifies device manufacturers from MAC addresses
- **OS Detection**: Fingerprints operating systems via TTL analysis
- **DHCP Fingerprinting**: Analyzes hostnames and DHCP parameters for device identification
- **Vendor Intelligence**: Built-in database of common MAC OUI prefixes
- **Active Host Discovery**: Ping sweeps to map live devices

**Output**: `analysis/client_fingerprinting.txt`

#### 4. Credential & Sensitive Data Detection
Scans packet captures for cleartext credentials across multiple protocols using `tcpdump`:
- **FTP**: Username and password extraction
- **HTTP Basic Auth**: Base64-decoded credentials
- **HTTP POST Data**: Form submission analysis (login forms, password fields)
- **Telnet**: Authentication data capture
- **SMTP**: Email authentication credentials
- **POP3/IMAP**: Email account credentials
- **SMB/NTLM**: Windows authentication detection (hashes require specialized tools)
- **Kerberos**: Domain authentication traffic detection
- **LDAP**: Directory service authentication
- **Database Protocols**: Detection of MySQL, PostgreSQL, Redis, VNC traffic

**Note**: This feature uses `tcpdump` with ASCII output parsing and regex patterns. While not as sophisticated as `tshark`'s protocol dissection, it successfully detects cleartext credentials in common protocols without requiring additional packages, which is my goal. Use all tools on the pager.

**Smart Detection**: Automatically skips monitor mode wireless captures that lack IP-layer traffic, focusing only on pcaps that could contain credentials.

**Output**: `credentials/credential_scan.txt` (restricted permissions: 600)

#### 5. Service Discovery & Enumeration
- **mDNS/Bonjour**: Discovers AirPlay, Chromecast, printers, and other advertised services
- **NetBIOS**: Enumerates Windows network names and workgroups
- **SNMP**: Tests common community strings for SNMP-enabled devices
- **UPnP**: Discovers Universal Plug and Play devices and services
- **SMB/CIFS**: Enumerates Windows shares and SMB hosts

**Output**: `services/` directory with protocol-specific files

#### 6. Rogue Device Detection
Comprehensive security analysis with intelligent whitelisting:
- **Rogue DHCP Servers**: Detects unauthorized DHCP servers that could redirect traffic
- **Multiple Gateways**: Identifies potential rogue routers or MITM attacks
- **Interface Classification**: Documents all network interfaces with context (Pineapple-aware)
- **MAC Spoofing Detection**: Flags suspicious locally-administered MACs
  - **Smart Whitelisting**: Automatically recognizes WiFi Pineapple's `13:37` signature MACs as normal
  - Filters out false positives from Pineapple virtual interfaces
- **MAC Randomization Detection**: Identifies devices using randomized MAC addresses
  - Detects locally administered bit pattern (2nd hex char: 2, 6, A, E)
  - Flags potential reconnaissance tools or privacy-conscious devices
  - Reports associated IPs and hostnames
- **Duplicate IP Detection**: Detects ARP spoofing attacks or IP conflicts
- **Evil Twin AP Detection**: Identifies duplicate SSIDs on different frequencies
- **NAT Configuration Analysis**: Verifies proper routing setup with detailed rule breakdown
  - Counts MASQUERADE, SNAT, and DNAT rules separately
  - Identifies misconfigurations

**Features**:
- Color-coded output: `[NORMAL]`, `[INFO]`, `[!] WARNING`, `[!] CRITICAL`
- Contextual explanations for each check
- Action-required flags for genuine threats
- Summary section with all checks performed

**Output**: `analysis/rogue_device_detection.txt`

#### 7. Geolocation & Physical Security
- **GPS Integration**: Captures GPS coordinates if GPS hardware available
- **WiFi Geolocation**: Documents nearby BSSIDs for triangulation via geolocation APIs
- **Timezone Tracking**: Records system timezone and timestamps
- **Temperature Monitoring**: Logs thermal sensor data if available
- **Power Status**: Captures battery/power supply information
- **Signal Strength Mapping**: Maps strongest networks for proximity estimation

**Output**: `analysis/geolocation.txt`

#### 8. Timeline & Historical Analysis
- **Change Detection**: Compares current scan with previous scans
- **New Network Detection**: Identifies newly appeared WiFi networks
- **New Client Detection**: Flags new devices since last scan
- **Persistent Device Tracking**: Tracks devices across multiple scans
- **Trend Analysis**: Shows deltas in network/client counts over time

**Output**: `timeline/scan_metadata.txt`

#### 9. Severity Scoring System
Automated risk assessment with weighted scoring:
- **CRITICAL (100 pts)**: Cleartext credentials, active deauthentication attacks
- **HIGH (75 pts)**: WEP networks, rogue DHCP servers, duplicate IPs, Evil Twin APs
- **MEDIUM (50 pts)**: Open networks, WPS-enabled networks, suspicious MACs
- **LOW (25 pts)**: Hidden SSIDs, randomized MAC addresses

**Features**:
- Automatic severity classification throughout the scan
- Overall risk level calculation (CRITICAL/HIGH/MEDIUM/LOW/CLEAN)
- Detailed score breakdown in summary report
- Itemized findings list by severity level

**Output**: Included in `SUMMARY_REPORT.txt` under "SEVERITY SUMMARY"

#### 10. Pineapple Recon Database Integration
Analyzes the Pagers's recon.db for historical intelligence:
- **Device History**: All devices ever seen by the Pager
- **Network Discovery**: All SSIDs and access points discovered
- **Captured Credentials**: Cleartext passwords from Evil Twin attacks
- **NTLM Hashes**: Challenge-response captures for offline cracking
- **WPA Handshakes**: Both passive and Evil Twin captured handshakes
- **Evil Twin Victims**: Devices that connected to rogue APs
- **Hidden Networks**: Networks broadcasting without SSID
- **Probe Requests**: What networks devices are searching for

**Intelligence Value**:
- Cross-reference current scan with historical data
- Identify returning devices across multiple engagements
- Extract actionable credentials and handshakes
- Track Evil Twin attack effectiveness

**Output**: `analysis/recon_intelligence.txt` + copy of `recon.db`

#### 11. Data Exfiltration & Security
- **AES-256 Encryption**: Optional encryption of final archive
- **Remote Sync**: Automatic upload to remote server via SCP/SFTP/CURL
- **Configurable Methods**: Supports multiple transfer protocols
- **Secure Deletion**: Option to remove unencrypted data post-encryption

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
                                  # Result: IR_YYYYMMDD_HHMMSS_label

# ============================================================================
# CAPTURE SETTINGS (can be overridden regardless of scan type)
# ============================================================================
PCAP_SNAPLEN=65535                # Full packet capture
PCAP_COUNT=10000                  # Max packets per interface

# Wireless Reconnaissance Configuration (used when ENABLE_WIRELESS_RECON=true)
CHANNEL_HOP_INTERVAL=0.5          # Seconds per channel
RECON_PHY="auto"                  # Physical device: "auto" or specify "phy0", "phy1", etc.

# Recon Database Path
RECON_DB_PATH="/root/recon/recon.db"  # Also checks /mmc/root/recon/recon.db

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

# Update Check (enabled by default)
ENABLE_UPDATE_CHECK=true          # Set to false to disable version checking
```

**Note**: Feature toggles like `ENABLE_CREDENTIAL_SCAN`, `ENABLE_SERVICE_DISCOVERY`, etc. are automatically set based on your `SCAN_TYPE` selection. You can override individual settings after the scan type configuration block if needed.

## _Automatic Update Check_

The payload includes an automatic version check feature that compares your local version against the latest version available on GitHub.

**How it works:**
- On startup, the payload checks GitHub for the latest version (3-second timeout)
- If a newer version is available, you'll see an alert with update information
- If you're running the latest version, you'll see a confirmation message
- If offline or GitHub is unreachable, the check fails silently and the payload continues

**Requirements:**
- The payload requires a `VERSION` file in the same directory as `payload.sh`
- This file contains only the version number (e.g., `1.0`)
- Both files must be present for the version check to work

**To disable:**
Set `ENABLE_UPDATE_CHECK=false` in the configuration section of `payload.sh`

**Example output when update available:**
```
════════════════════════════════════════════════════════
  🆕 UPDATE AVAILABLE!
  Current: v2.0 → Latest: v2.1
  Update at: github.com/hak5/wifipineapplepager-payloads
════════════════════════════════════════════════════════
```

**Example output when up-to-date:**
```
[*] Checking for updates...
    [OK] Running latest version (v2.0)
```

## _Output Structure_

```
/root/loot/incident_response/IR_YYYYMMDD_HHMMSS_[label]/
(Note: _[label] suffix is optional, added only when SCAN_LABEL is configured)
├── SUMMARY_REPORT.txt           # Executive summary with severity scoring
├── system/
│   └── system_info.txt          # System state and processes
├── network/
│   ├── network_config.txt       # Network interfaces and routing
│   ├── connections.txt          # Active connections
│   ├── dns_info.txt            # DNS configuration
│   ├── dhcp_leases.txt         # DHCP lease information
│   └── firewall_rules.txt      # iptables rules
├── wireless/
│   ├── wireless_info.txt       # Interface information
│   ├── wifi_scan.txt           # Nearby networks
│   ├── security_analysis.txt   # Vulnerability assessment
│   └── connected_clients.txt   # Connected client details
├── bluetooth/
│   └── bluetooth_devices.txt   # Bluetooth/BLE device scan results
├── pcaps/
│   ├── management_*.pcap       # Management interface capture
│   ├── wlan0_*.pcap           # WLAN captures
│   └── wlan1_*.pcap
├── analysis/
│   ├── client_fingerprinting.txt
│   ├── nearby_access_points.txt
│   ├── probe_requests.txt
│   ├── deauth_detection.txt
│   ├── wireless_recon_summary.txt
│   ├── rogue_device_detection.txt
│   ├── recon_intelligence.txt  # Pager recon.db analysis
│   ├── recon.db                # Copy of recon database for offline analysis
│   └── geolocation.txt
├── security_analysis/           # WiFi pentesting intelligence
│   ├── 00_SUMMARY.txt          # Executive summary of findings
│   ├── 01_client_probe_intelligence.txt
│   ├── 02_hidden_ssid_detection.txt
│   ├── 03_wpa_handshake_detection.txt
│   ├── 04_encryption_analysis.txt
│   ├── 05_rogue_ap_detection.txt
│   ├── 06_client_ap_mapping.txt
│   └── 07_signal_proximity_analysis.txt
├── services/
│   ├── mdns_discovery.txt
│   ├── netbios_enum.txt
│   ├── snmp_discovery.txt
│   ├── upnp_discovery.txt
│   └── smb_enum.txt
├── credentials/
│   └── credential_scan.txt     # SENSITIVE - chmod 600
├── timeline/
│   └── scan_metadata.txt
└── logs/
    └── [system logs]
```

## _Dependencies_

### Core Requirements (Built-in)
- bash
- tcpdump
- iw / iwconfig
- ifconfig / ip
- arp
- netstat / ss
- iptables

### Enhanced Features (Optional)

These tools are **not required** - the payload runs fine without them. However, installing any of these will unlock additional reconnaissance capabilities and collect more data. If a tool is missing, the payload simply skips that feature and continues.

- **sqlite3**: Recon database analysis (usually built-in)
- **hcitool/bluetoothctl**: Bluetooth device scanning
- **avahi-browse**: mDNS/Bonjour service discovery
- **nbtscan/nmblookup**: NetBIOS enumeration
- **onesixtyone/snmpwalk**: SNMP discovery
- **upnpc**: UPnP discovery
- **smbclient**: SMB share enumeration
- **fping**: Enhanced OS fingerprinting
- **openssl**: Archive encryption
- **scp/sftp/curl**: Remote sync capabilities
- **jq**: GPS data parsing
- **strings**: Enhanced credential extraction (usually built-in)

**Note**: Deep packet analysis and credential scanning use `tcpdump` (built-in) instead of `tshark`, making the payload more lightweight.

## _Usage_

### Basic Usage
1. Copy the entire `/incident_response/incident_scanner/` folder to your Pager
   - **Important**: Both `payload.sh` and `VERSION` files are required for update checking
2. Adjust configuration variables in `payload.sh` as needed
3. Run the payload via the Pager

### Advanced Configuration Examples

**Note**: Scan type is selected interactively when you run the payload. The examples below show additional configuration options you can set in `payload.sh`.

#### Example 1: Labeled Site Survey
```bash
# When prompted, select 1 for QUICK scan
SCAN_LABEL="site_survey"
```

#### Example 2: Encrypted Archive
```bash
# When prompted, select your desired scan type
ENCRYPT_ARCHIVE=true
ENCRYPTION_PASSWORD="YourStrongPassword123!"
```

#### Example 3: Full Incident Response with Covert Exfiltration
```bash
# When prompted, select 3 for DEEP scan
SCAN_LABEL="ir_investigation"
ENABLE_REMOTE_SYNC=true
REMOTE_SERVER="user@c2-server.com"
REMOTE_PATH="/var/loot/pager"
REMOTE_METHOD="scp"
ENCRYPT_ARCHIVE=true
```

#### Example 4: Labeled Scans for Multiple Daily Engagements
```bash
# Easily identify scans when performing multiple assessments per day
SCAN_LABEL="office_breach"        # Creates: IR_20260118_143052_office_breach
# or
SCAN_LABEL="Client Site A"        # Creates: IR_20260118_150322_client_site_a
# or
SCAN_LABEL="after-hours-scan"     # Creates: IR_20260118_203015_after_hours_scan
```

**Note**: Labels are automatically sanitized (lowercase, special chars replaced with underscores).

## _Security Considerations_

### Legal & Ethical
- **Authorization Required**: Only use on networks you own or have explicit written permission to test
- **Data Sensitivity**: Credential scans may capture highly sensitive information
- **Compliance**: Ensure compliance with local laws and regulations (CFAA, GDPR, etc.)
- **Scope Limitation**: Configure features appropriate to your engagement scope

### Operational Security
- **Encrypted Archives**: Always encrypt archives when capturing credentials
- **Secure Transport**: Use encrypted channels (SCP/SFTP) for remote sync
- **Password Security**: Use strong encryption passwords and secure storage
- **Log Sanitization**: Review and sanitize logs before sharing reports
- **Restricted Permissions**: Credential files are automatically chmod 600

### Data Handling
- The `credentials/` directory contains extremely sensitive data
- Archive files may be large (hundreds of MB with long captures)
- Consider automatic deletion of uncompressed data after archiving
- Secure deletion recommended for decommissioned storage media

## _Penetration Testing Workflow_

### Pre-Engagement
1. Configure payload for engagement scope
2. Set appropriate capture duration
3. Configure encryption and exfiltration
4. Test on authorized network first

### During Engagement
1. Open Pager at target location and run the payload
2. Monitor via Pager's interface
3. Verify archive creation and sync, if you setup the sync feature

### Post-Engagement Analysis
1. Review `SUMMARY_REPORT.txt` for quick overview and severity scoring
2. Check the **Severity Summary** section for overall risk assessment
3. Analyze `wireless/security_analysis.txt` for vulnerable networks
4. Check `credentials/credential_scan.txt` for exposed credentials
5. Review `bluetooth/bluetooth_devices.txt` for nearby Bluetooth devices
6. Examine `services/*` for attack surface mapping
7. Review `analysis/client_fingerprinting.txt` for target intelligence
8. Deep-dive PCAPs with Wireshark for detailed analysis
9. Compare with baseline using `timeline/scan_metadata.txt`

### Reporting
1. Use `SUMMARY_REPORT.txt` for executive summary
2. Reference the **Severity Summary** for risk metrics
3. Extract vulnerability counts for metrics
4. Include screenshots of key findings
5. Sanitize sensitive data before client delivery
6. Provide remediation recommendations

## _Severity Scoring Reference_

The payload automatically calculates a risk score based on findings:

| Severity | Points | Trigger Conditions |
|----------|--------|-------------------|
| CRITICAL | 100 | Cleartext credentials detected, active deauth attacks |
| HIGH | 75 | WEP networks, rogue DHCP, duplicate IPs, Evil Twin APs |
| MEDIUM | 50 | Open networks, WPS-enabled, suspicious MAC addresses |
| LOW | 25 | Hidden SSIDs, randomized MACs |

**Overall Risk Levels**:
- **CRITICAL** (200+ pts): Immediate action required
- **HIGH** (100-199 pts): Significant issues found
- **MEDIUM** (50-99 pts): Issues require attention
- **LOW** (1-49 pts): Minor issues detected
- **CLEAN** (0 pts): No significant issues

## _Key Findings Interpretation_

### Critical Findings
- **Cleartext Credentials**: Immediate credential compromise risk - passwords exposed in network traffic
- **Deauthentication Attacks**: Active WiFi attacks detected - possible Evil Twin or deauthing in progress

### High-Risk Findings
- **WEP Networks**: Easily crackable in minutes (aircrack-ng)
- **Rogue DHCP Servers**: Possible man-in-the-middle attack infrastructure
- **Duplicate IPs/ARP Spoofing**: Active network manipulation detected
- **Evil Twin APs**: Duplicate SSIDs may indicate phishing infrastructure

### Medium-Risk Findings
- **Open Networks**: No encryption, all traffic visible
- **WPS Enabled**: Vulnerable to Reaver/PixieWPS attacks
- **Suspicious MACs**: Possible MAC spoofing or unauthorized devices

### Low-Risk Findings
- **Hidden Networks**: Security through obscurity (still attackable)
- **Randomized MACs**: May indicate privacy tools, mobile devices, or reconnaissance

### Intelligence Gathering
- **Client Fingerprinting**: Device inventory and OS distribution
- **Bluetooth Devices**: Wireless peripheral mapping
- **Service Discovery**: Attack surface mapping
- **DNS Queries**: Data exfiltration detection, user behavior
- **Top Talkers**: Network architecture understanding

## _Troubleshooting_

### Common Issues

**Bluetooth scan shows "not available"**
- No Bluetooth adapter present (expected on the pager)
- Bluetooth adapter may need to be enabled: `hciconfig hci0 up`
- BLE scanning requires root privileges

**Deep packet analysis shows "[Skip]" messages**
- This is normal behavior for monitor mode wireless captures (beacons, probe requests, deauth frames)
- These captures contain raw 802.11 frames without IP-layer data
- IP-based analysis (HTTP/DNS/credentials) only works on `local_network_*.pcap` files
- Wireless analysis is handled separately in the wireless reconnaissance section
- If you need IP-layer analysis, ensure clients are actively connected and generating traffic

**Deep packet analysis not working at all**
- Ensure `tcpdump` is installed (should be built-in)
- Check that pcap files were created successfully
- Verify sufficient storage space

**Large archive sizes**
- Reduce `PCAP_TIME` (default 60s may be excessive)
- Lower `PCAP_COUNT` to limit packet count
- Enable archive encryption and delete uncompressed data

**No credentials detected**
- Increase `PCAP_TIME` to capture more traffic
- Ensure clients are active during capture
- Modern networks use encryption (expected result)

**Remote sync fails**
- Verify network connectivity to remote server
- Check SSH key authentication is configured
- Test manual SCP/SFTP first
- Review firewall rules

**GPS not detected**
- GPS hardware may not be present
- Check `gpsd` installation and configuration
- WiFi geolocation still available as fallback

## _Performance Notes_

### Scan Type Duration
| Scan Type | Typical Duration | Archive Size |
|-----------|------------------|--------------|
| QUICK | 1-5 minutes      | 10-50 MB |
| NORMAL | 10-15 minutes    | 50-150 MB |
| DEEP | 25+ minutes      | 100-500 MB |

### Feature Timing Breakdown
- Service discovery adds ~20-40 seconds
- Bluetooth scanning adds ~30 seconds (if adapter present)
- Historical comparison is near-instant (<5s)
- Credential scanning adds ~10-20 seconds per pcap file
- Traffic capture: 0s (QUICK) / 30s (NORMAL) / 120s (DEEP)
- Using `tcpdump` instead of `tshark` significantly reduces CPU/memory usage

### Storage Considerations
- Archive size varies with traffic volume and capture duration
- DEEP scans with high network activity may exceed 500MB
- Consider available storage before running extended scans

## _Credits_

- **Author**: curtthecoder
- **Version**: 2.0
- **Tools**: tcpdump, iw, hcitool, various network utilities

## _Changelog_

### v2.0
- **NEW**: Interactive Scan Type Selection via on-device prompt
  - Uses PROMPT and NUMBER_PICKER for runtime selection
  - 1 = QUICK (~1-5 min): Fast reconnaissance for time-sensitive situations
  - 2 = NORMAL (~10-15 min): Balanced scan for standard penetration tests
  - 3 = DEEP (~25+ min): Full forensic collection (original behavior)
- Features are automatically enabled/disabled based on scan type
- Updated output to show scan type in reports and summaries

### v1.0
- Initial release with full feature set

## _License_

Use responsibly and only with proper authorization. I am not responsible for misuse or damage caused by this tool.

## _Support_

For issues, feature requests, or questions:
- Review this README thoroughly
- Check Hak5's Discord, Im always in there
- Verify all dependencies are installed
- Test with verbose logging enabled

---

**HAPPY PENTESTING!**