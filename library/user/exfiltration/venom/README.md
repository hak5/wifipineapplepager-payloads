# VENOM - WPA-Enterprise Credential Harvester

- **Author:** sinX
- **Version:** 1.0
- **Category:** Exfiltration
- **Target:** WPA-Enterprise / 802.1X networks
- **Dependencies:** openssl-util, tcpdump (optional)

## Description

Deploys a rogue WPA-Enterprise (802.1X) access point that impersonates a target corporate WiFi network. When enterprise clients attempt to authenticate, Venom captures:

- **EAP Identities** - Usernames from all connecting clients
- **Cleartext Passwords** - Via GTC/PAP inner authentication methods
- **MSCHAPv2 Hashes** - Challenge/response pairs exportable in hashcat mode 5500 format

This payload does **not modify any system packages**. It downloads and extracts a standalone hostapd binary to `/tmp` for the rogue AP, leaving the Pager's stock configuration untouched. Everything is cleaned up on exit.

## Features

- Scans for WPA-Enterprise (802.1X) networks in range
- Scrollable target picker or manual SSID entry
- Auto-generates self-signed CA + server certificates
- Creates virtual WiFi interface on secondary radio (phy1)
- Built-in EAP server (no external RADIUS required)
- Real-time credential monitoring with vibration/sound alerts
- Optional deauthentication burst to force client reconnection
- Exports MSCHAPv2 hashes in hashcat-ready format
- Full engagement report generation
- Complete cleanup on exit (interface, processes, temp files)

## LED States

| LED Color | State |
|-----------|-------|
| Cyan | Scanning for enterprise networks |
| Amber | Generating certificates, creating interface |
| Red | Rogue AP active, capturing credentials |
| Green | Harvesting and parsing results |
| Magenta | Error condition |
| White | Idle / Complete |

## Configuration

```bash
# Loot directory
LOOT_DIR="/root/loot/venom"

# Rogue AP interface settings
VENOM_IFACE="wlan_venom"     # Virtual interface name
PHY_DEVICE="phy1"             # Radio (phy1 = secondary)
DEFAULT_CHANNEL=6              # Default if manual entry

# Certificate CN (placeholder - change as needed)
CERT_CN="radius.corp.local"
CERT_ORG="Internal Certificate Authority"
```

## Usage

1. Launch payload from **Payloads > User > Exfiltration > venom**
2. Confirm start
3. **Phase 0**: Dependencies are checked and installed if needed
4. **Phase 1**: Scans for 802.1X networks. Select a target with UP/DOWN + A, or press B for manual SSID entry
5. **Phase 2**: Certificates are generated and the rogue AP is configured
6. **Phase 3**: Rogue AP goes live. Optional deauth burst against real AP. Live monitoring shows captures in real-time. Press any button to stop
7. **Phase 4**: Results are parsed, hashcat file is exported, engagement report is generated

## Output

Loot is saved to `/root/loot/venom/session_YYYYMMDD_HHMMSS/`:

| File | Contents |
|------|----------|
| `identities.txt` | Captured EAP usernames |
| `cleartext_creds.txt` | GTC/PAP passwords |
| `hashcat_5500.txt` | MSCHAPv2 hashes (hashcat mode 5500) |
| `mschapv2_hashes.txt` | Human-readable MSCHAPv2 data |
| `report.txt` | Full engagement report |
| `hostapd_debug.log` | Raw hostapd debug output |
| `eap_capture.pcap` | Raw EAP packet capture |
| `session.log` | Timestamped session log |

## Cracking MSCHAPv2 Hashes

```bash
# Copy from Pager
scp root@172.16.42.1:/root/loot/venom/session_*/hashcat_5500.txt .

# Crack with hashcat (mode 5500)
hashcat -m 5500 hashcat_5500.txt wordlist.txt
```

## How It Works

1. Creates a virtual WiFi interface on phy1 (secondary radio)
2. Runs a standalone `hostapd` binary (extracted from package, not installed) with built-in EAP server
3. The rogue AP broadcasts the target SSID with WPA-Enterprise authentication
4. Clients that connect attempt EAP authentication against our fake RADIUS
5. The EAP server offers PEAP/TTLS outer tunnel with GTC/MSCHAPv2 inner methods
6. Credentials are captured from hostapd's verbose debug output
7. Optional deauth frames force clients off the real AP (using `PINEAPPLE_DEAUTH_CLIENT`)

## Disclaimer

This payload is provided for **authorized security testing and education only**. WPA-Enterprise credential harvesting captures domain credentials that may provide access to corporate systems. Only use against networks you own or have explicit written authorization to test. Unauthorized interception of network communications is illegal. The author assumes no liability for misuse.
