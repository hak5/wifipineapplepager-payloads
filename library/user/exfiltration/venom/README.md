# VENOM - WPA-Enterprise Credential Harvester


<img width="1024" height="1536" alt="ChatGPT Image Feb 20, 2026, 09_28_21 AM" src="https://github.com/user-attachments/assets/0e4d98a2-d5d8-495d-8af3-92d1f45f7c6e" />



**Type:** User Payload
**Category:** Exfiltration
**Author:** sinX
**Version:** 1.0

## Description

Deploys a rogue WPA-Enterprise (802.1X) access point that impersonates a target corporate WiFi network. When enterprise clients connect to the rogue AP, Venom captures EAP identities (usernames), cleartext passwords via GTC/PAP inner methods, and MSCHAPv2 challenge/response hashes for offline cracking with hashcat.

This is the first WPA-Enterprise attack payload for the WiFi Pineapple Pager.

## Features

- **Enterprise Network Scanner**: Detects 802.1X/EAP networks in range
- **Rogue AP Deployment**: Clones target SSID with WPA-Enterprise auth
- **Built-in EAP Server**: No external RADIUS server required
- **Auto Certificate Generation**: Self-signed CA + server certs on the fly
- **Multi-Method Capture**: GTC (cleartext), PAP (cleartext), MSCHAPv2 (hashes)
- **Real-Time Monitoring**: Live credential display with counters
- **Hashcat Export**: MSCHAPv2 hashes in hashcat mode 5500 format
- **Optional Deauth**: Force clients off real AP onto rogue AP
- **Engagement Report**: Full structured report with all captured data
- **Haptic/Audio Alerts**: Vibration and sound on each credential capture

## Requirements

- `wpad-openssl` (replaces `wpad-basic` - payload offers auto-install)
- `openssl` (for certificate generation)
- `iw` (for virtual interface creation)
- `tcpdump` (optional - for raw EAP packet capture)

## Installation

1. Copy this directory to `/root/payloads/user/exfiltration/venom/`
2. Ensure the script is executable:
   ```bash
   chmod +x /root/payloads/user/exfiltration/venom/payload.sh
   ```
3. Install dependencies (payload will auto-detect and offer to install):
   ```bash
   opkg update
   opkg remove wpad-basic wpad-basic-wolfssl 2>/dev/null
   opkg install wpad-openssl openssl-util tcpdump
   wifi restart
   ```

## Configuration

Edit the configuration section at the top of `payload.sh`:

```bash
# Loot and temp directories
LOOT_DIR="/root/loot/venom"
TEMP_DIR="/tmp/venom"

# Rogue AP settings
VENOM_IFACE="wlan_venom"      # Virtual interface name
PHY_DEVICE="phy1"              # Radio to use (phy1 = secondary)
DEFAULT_CHANNEL=6              # Default channel if manual entry

# Certificate settings
CERT_CN="radius.corp.local"    # Server cert common name
CERT_ORG="Internal Certificate Authority"
CERT_DAYS=365
```

## Usage

### From Pager Dashboard

1. Navigate to **Payloads** > **User Payloads**
2. Select **Exfiltration** > **VENOM**
3. Press the button to launch
4. Follow the on-screen prompts through all 4 phases

### Attack Flow

```
Phase 0: DEPENDENCIES
  Checks/installs wpad-openssl, openssl, iw

Phase 1: RECON
  Scans for WPA-Enterprise (802.1X) networks
  Select target from list OR enter SSID manually

Phase 2: SETUP
  Generates self-signed CA + server certificates
  Creates virtual WiFi interface (wlan_venom)
  Configures hostapd for WPA-Enterprise
  Confirm deployment

Phase 3: DEPLOY
  Starts rogue AP with max debug logging
  Starts raw packet capture (tcpdump)
  Optional: deauth burst against real AP
  Live monitoring with real-time credential display
  Press button to stop

Phase 4: HARVEST
  Stops all processes, removes interface
  Parses all captured credentials
  Exports MSCHAPv2 hashes in hashcat format
  Generates engagement report
  Saves all loot
```

## What Gets Captured

### EAP Identities (Usernames)
Every client that attempts to authenticate sends its identity (usually `DOMAIN\username` or `user@domain.com`). Captured from ALL connecting clients regardless of inner auth method.

### GTC/PAP Cleartext Passwords
When the inner authentication method negotiates GTC (Generic Token Card) or PAP, the password is sent in cleartext inside the TLS tunnel. Common with:
- Android devices (often accept GTC)
- BYOD devices with loose supplicant configs
- Devices set to "don't verify server certificate"

### MSCHAPv2 Challenge/Response Hashes
Windows clients and well-configured enterprise devices typically negotiate MSCHAPv2 as the inner method. This produces a challenge/response pair that can be cracked offline with hashcat.

## Output

All loot is saved to `/root/loot/venom/session_YYYYMMDD_HHMMSS/`:

```
session_20260220_143022/
  session.log           # Real-time session log
  duration.txt          # Attack duration
  identities.txt        # EAP usernames (one per line)
  cleartext_creds.txt   # GTC/PAP passwords
  mschapv2_hashes.txt   # Human-readable MSCHAPv2 data
  hashcat_5500.txt      # Hashcat mode 5500 format
  report.txt            # Full engagement report
  hostapd_debug.log     # Raw hostapd debug output
  eap_capture.pcap      # Raw packet capture (if tcpdump available)
```

## Cracking MSCHAPv2 Hashes

Export the hashcat file from the Pager:
```bash
scp root@172.16.42.1:/root/loot/venom/session_*/hashcat_5500.txt .
```

Crack with hashcat (mode 5500 = NetNTLMv1 / MSCHAPv2):
```bash
hashcat -m 5500 hashcat_5500.txt wordlist.txt
```

Or with rules:
```bash
hashcat -m 5500 hashcat_5500.txt wordlist.txt -r rules/best64.rule
```

## How It Works

1. **Rogue AP**: Creates a virtual WiFi interface on the secondary radio (phy1) and runs `hostapd` with its built-in EAP server. The AP uses the same SSID as the target enterprise network.

2. **Certificate Trick**: Generates self-signed certificates on the fly. Many enterprise clients are configured to "not verify server certificate" or users click "Accept" when prompted, allowing the connection to our rogue AP.

3. **EAP Server**: hostapd's built-in EAP server handles PEAP and TTLS outer tunnels. Inside the tunnel, it offers GTC (cleartext), PAP (cleartext), and MSCHAPv2 (hash) as inner methods.

4. **Credential Capture**: With maximum debug logging enabled, hostapd writes EAP identities, GTC/PAP passwords, and MSCHAPv2 challenge/response data to its log output. Venom parses this in real-time.

5. **Deauth Assist**: Optionally sends deauthentication frames to the real AP using `PINEAPPLE_DEAUTH_CLIENT`, forcing clients to disconnect and reconnect - potentially to our rogue AP.

## LED Indicators

| Color | Phase |
|-------|-------|
| Cyan | Recon - scanning for networks |
| Amber | Setup - generating certs, creating interface |
| Red | Deploy - rogue AP active, capturing |
| Green | Harvest - parsing results |
| Magenta | Error |
| White | Idle / Complete |

## Troubleshooting

### "hostapd failed to start"
- Check the hostapd debug log: `cat /tmp/venom/hostapd.log`
- Ensure `wpad-openssl` is installed (not `wpad-basic`)
- Verify the virtual interface was created: `iw dev`
- Check if another hostapd is using the interface

### "Failed to create virtual interface"
- The radio may have too many virtual interfaces already
- Try: `iw dev` to see existing interfaces
- Remove unused interfaces: `iw dev <name> del`
- Try a different PHY_DEVICE (edit config to use `phy0`)

### "wpad-basic detected"
- Venom requires `wpad-openssl` for EAP server support
- Allow the payload to auto-replace it, or manually:
  ```bash
  opkg remove wpad-basic && opkg install wpad-openssl
  wifi restart
  ```

### No credentials captured
- Verify clients are connecting (check hostapd_debug.log for association messages)
- Use deauth to force clients off the real AP
- Some clients refuse to connect without valid certificates
- Corporate environments with certificate pinning will block this attack
- Try targeting BYOD/personal devices instead

### Certificate warnings on client devices
- This is expected - the rogue AP uses self-signed certificates
- Many users will click "Accept" or "Connect Anyway"
- Android devices are generally more permissive than iOS/Windows

## Target Selection Tips

- **Best targets**: Networks where "Don't validate server certificate" is common
- **Android devices**: Most likely to connect and send GTC cleartext
- **BYOD networks**: Often have weaker supplicant configurations
- **Guest enterprise WiFi**: Sometimes uses simpler EAP methods
- **Least effective against**: Networks with certificate pinning, strict GPO supplicant policies

## Security & Legal Notice

This payload is intended for **authorized penetration testing and security assessments only**. WPA-Enterprise credential harvesting is a sensitive attack that captures domain credentials.

- Only use against networks you own or have explicit written authorization to test
- Captured credentials may provide access to corporate systems beyond WiFi
- Follow responsible disclosure practices
- Comply with all applicable local and international laws
- Unauthorized interception of network communications is illegal

## Related Payloads

- **FENRIS** (user/interception) - Deauthentication attacks to assist credential capture
- **Interactive Handshake Cracker** (user/exfiltration) - Crack WPA-PSK handshakes
- **Wordlist Manager** (user/general) - Download wordlists for hash cracking
- **Evil Portal** (user/evil_portal) - Captive portal credential harvesting
