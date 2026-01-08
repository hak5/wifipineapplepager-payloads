# MUNINN - Post-Connect Enumeration

**Named after Odin's memory raven - MUNINN remembers everything about each client that connects**

```
                              .......::.:....
                        ..::------------------::..
                      .:-=======================-::.
                    .:---====================-----::.
                  .:::::::-----=-----=--=---:::::::...
                ....:::::----====-=--====--------:::...
                ...::------::---=========--::::::--::.
                ....:::........:.:::::::..........:::.
                 .....      ........::..      ...   ..
                 . .            ..::....       ...
                              ...::.   ...
                   ..         .::.      ...          .
                  .:..     ......        .....      ....
               ... .:...........      .    .   .....::.
               ........  ..   ...       .....  ..........
                             .....      .....   ...
                              ...... .......
                           ...::.........:::.
                          ....... ....:......
                          ....     .  ....

 ███▄ ▄███▓ █    ██  ███▄    █  ██▓ ███▄    █  ███▄    █
▓██▒▀█▀ ██▒ ██  ▓██▒ ██ ▀█   █ ▓██▒ ██ ▀█   █  ██ ▀█   █
▓██    ▓██░▓██  ▒██░▓██  ▀█ ██▒▒██▒▓██  ▀█ ██▒▓██  ▀█ ██▒
▒██    ▒██ ▓▓█  ░██░▓██▒  ▐▌██▒░██░▓██▒  ▐▌██▒▓██▒  ▐▌██▒
▒██▒   ░██▒▒▒█████▓ ▒██░   ▓██░░██░▒██░   ▓██░▒██░   ▓██░
░ ▒░   ░  ░░▒▓▒ ▒ ▒ ░ ▒░   ▒ ▒ ░▓  ░ ▒░   ▒ ▒ ░ ▒░   ▒ ▒
░  ░      ░░░▒░ ░ ░ ░ ░░   ░ ▒░ ▒ ░░ ░░   ░ ▒░░ ░░   ░ ▒░
░      ░    ░░░ ░ ░    ░   ░ ░  ▒ ░   ░   ░ ░    ░   ░ ░
       ░      ░              ░  ░           ░          ░

                        MUNINN
                     Memory Raven v1.0
```

## What It Does

An **alert payload** that automatically enumerates clients when they connect to your Evil Twin AP. MUNINN resolves the client's IP and performs rapid fingerprinting to gather intelligence.

## Alert Payload

**Important:** MUNINN is an alert payload, not a standard payload. It triggers automatically when the `pineapple_client_connected` event fires.

### Installation

```bash
# Copy to alerts directory (MUST be folder/payload.sh structure)
mkdir -p /root/payloads/alerts/pineapple_client_connected/muninn
cp payload.sh /root/payloads/alerts/pineapple_client_connected/muninn/payload.sh
chmod +x /root/payloads/alerts/pineapple_client_connected/muninn/payload.sh
```

### Environment Variables

MUNINN receives these variables automatically:
- `$_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS` - Client's MAC
- `$_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS` - AP's MAC
- `$_ALERT_CLIENT_CONNECTED_SSID` - Network name client connected to
- `$_ALERT_CLIENT_CONNECTED_SUMMARY` - Connection summary

## Enumeration Modules

### 1. IP Resolution
- Uses `FIND_CLIENT_IP` command
- Falls back to ARP table lookup
- Checks DHCP leases if needed

### 2. MAC Vendor Lookup
- Identifies device manufacturer
- Detects VMs and IoT devices
- Uses OUI database

### 3. Ping/Reachability
- Confirms client is accessible
- Measures latency

### 4. OS Fingerprint
- TTL-based OS detection
- Linux/Unix: TTL ~64
- Windows: TTL ~128
- Network devices: TTL >128

### 5. Port Scan
Quick scan of common ports:
- 21 (FTP), 22 (SSH), 23 (Telnet)
- 80 (HTTP), 443 (HTTPS), 8080 (Alt HTTP)
- 139, 445 (SMB/NetBIOS)
- 3389 (RDP), 5900 (VNC)

### 6. HTTP Fingerprint
- Grabs server headers
- Identifies web server software
- Checks both HTTP and HTTPS

### 7. SMB/NetBIOS
- Detects Windows shares
- NetBIOS name lookup
- SMB version detection

### 8. DNS Fingerprint
- Reverse DNS lookup
- mDNS/Bonjour detection
- Hostname resolution

## Integration with FENRIR Suite

MUNINN complements HUGINN (the thought raven):

```
HUGINN (pre-connect) → passive recon, probe capture
       ↓
[Client Connects to Evil Twin]
       ↓
MUNINN (post-connect) → active enumeration
```

### Full Attack Chain

```
HUGINN → identifies targets (passive)
    ↓
FENRIS → deauths clients
    ↓
SKOLL → karma lures reconnection
    ↓
[CLIENT CONNECTS]
    ↓
MUNINN → auto-triggers, enumerates client
    ↓
LOKI → harvests credentials
```

## Output

Reports saved to `/root/loot/muninn/`:

```
client_AA-BB-CC-DD-EE-FF_20260107_143022.log
```

### Report Format

```
========================================
MUNINN - Client Enumeration Report
========================================

Timestamp: Tue Jan 7 14:30:22 UTC 2026
Client MAC: AA:BB:CC:DD:EE:FF
AP MAC: 00:11:22:33:44:55
SSID: FreeWiFi

========================================

=== MAC VENDOR ===
MAC: AA:BB:CC:DD:EE:FF
OUI: AA-BB-CC
Vendor: Apple, Inc.

=== IP RESOLUTION ===
Client IP: 172.16.42.101

=== PING TEST ===
Status: REACHABLE

=== OS FINGERPRINT ===
TTL: 64
Likely OS: Linux/Unix/macOS

=== PORT SCAN ===
Port 80: OPEN
Port 443: OPEN

=== HTTP FINGERPRINT ===
Port 80: OPEN
HTTP Headers:
Server: Apache/2.4.41

...
```

## LED Indicators

| Color | Status |
|-------|--------|
| Cyan | Alert received |
| Amber | Resolving IP |
| Magenta | Enumerating |
| Green | Complete |
| Red | Error/Failed |

## DuckyScript Commands Used

```bash
# IP Resolution
FIND_CLIENT_IP [mac] {timeout}
# Returns client IP, exit 0 on success

# Alert Variables (automatic)
$_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS
$_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS
$_ALERT_CLIENT_CONNECTED_SSID
$_ALERT_CLIENT_CONNECTED_SUMMARY
```

## Configuration

Timeouts in `payload.sh`:
```bash
TIMEOUT_IP=30      # Seconds to wait for IP
TIMEOUT_ENUM=60    # Seconds for enumeration
```

## Tested Scenarios

- iPhone connecting to "attwifi" Evil Twin
- Android device to "Starbucks WiFi"
- Windows laptop to "NETGEAR"
- Linux device to custom SSID

## Notes

- Some mobile devices disconnect quickly if no internet
- Consider running LOKI portal simultaneously
- Enumeration is noisy - client may notice
- VM detection useful for identifying security researchers

## Relationship to HUGINN

| HUGINN (Thought) | MUNINN (Memory) |
|------------------|-----------------|
| Pre-connect recon | Post-connect enum |
| Passive listening | Active scanning |
| Probe requests | Direct connection |
| WiFi + BLE fusion | IP-based fingerprint |
| Identity correlation | Service discovery |

Together, they provide complete client intelligence.

## Legal Warning

Client enumeration on unauthorized networks is illegal. Only use in controlled environments or with written permission.

## Author

HaleHound

## Version

1.0.0
