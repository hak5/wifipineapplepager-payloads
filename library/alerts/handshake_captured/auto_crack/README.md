# Auto Handshake Cracker

**Type:** Alert Payload
**Category:** Handshake Captured
**Author:** sinX
**Version:** 1.0

## Description

Automatically attempts to crack WPA/WPA2 handshakes immediately after they are captured by the WiFi Pineapple Pager. This payload runs in the background whenever a valid handshake is captured.

## Features

- **Automatic Execution**: Runs immediately when a crackable handshake is captured
- **Configurable Timeout**: Set maximum crack time to avoid excessive resource usage
- **Result Logging**: Saves cracked passwords to a log file with timestamps
- **User Notifications**: Vibration and alert notifications when password is found
- **Smart Detection**: Only attempts to crack valid, crackable handshakes

## Requirements

- `aircrack-ng` installed on the Pager
- At least one wordlist file (rockyou.txt recommended)
- Sufficient storage space for handshake files

## Installation

1. Copy this directory to `/root/payloads/alerts/handshake_captured/auto_crack/`
2. Ensure the script is executable:
   ```bash
   chmod +x /root/payloads/alerts/handshake_captured/auto_crack/payload.sh
   ```
3. Install aircrack-ng if not already installed:
   ```bash
   opkg update
   opkg install aircrack-ng
   ```
4. Upload a wordlist to the Pager (e.g., `/root/wordlists/rockyou.txt`)

## Configuration

Edit the configuration section at the top of `payload.sh`:

```bash
# Wordlist location - adjust to your wordlist path
WORDLIST="/root/wordlists/rockyou.txt"

# Maximum crack time in seconds (0 = unlimited)
MAX_CRACK_TIME=300

# Enable logging to file
ENABLE_LOGGING=true
LOG_FILE="/root/crack_results.log"

# Notify on success/failure
VIBRATE_ON_SUCCESS=true
ALERT_ON_SUCCESS=true
```

## Usage

This is an **alert payload** - it runs automatically when:
1. The Pager captures a WPA/WPA2 handshake
2. The handshake is complete and crackable
3. The payload is enabled in the Pager settings

### Manual Testing

To test without waiting for a real handshake capture:
```bash
cd /root/payloads/alerts/handshake_captured/auto_crack/
# Set environment variables manually
export _ALERT_HANDSHAKE_CRACKABLE="true"
export _ALERT_HANDSHAKE_PCAP_FILE="/path/to/handshake.pcap"
export _ALERT_HANDSHAKE_AP_MAC="AA:BB:CC:DD:EE:FF"
export _ALERT_HANDSHAKE_TYPE="EAPOL"
./payload.sh
```

## Output

Successful cracks are logged to `/root/crack_results.log` in the format:
```
2026-02-11 15:30:45 | MyNetwork | AA:BB:CC:DD:EE:FF | password123
```

## Performance Considerations

- **Limited Resources**: The Pager has limited CPU, so cracking may be slow
- **Timeout Recommended**: Set `MAX_CRACK_TIME` to prevent excessive resource usage
- **Wordlist Size**: Smaller wordlists (10k-100k) work better than full rockyou.txt
- **Battery Impact**: Continuous cracking will drain battery faster

## Troubleshooting

### "Wordlist not found"
- Verify the wordlist path in the configuration
- Check that the file exists: `ls -lh /root/wordlists/rockyou.txt`

### "aircrack-ng: command not found"
- Install aircrack-ng: `opkg update && opkg install aircrack-ng`

### No passwords found
- Try a different/larger wordlist
- Some networks use very strong passwords not in common wordlists
- Consider using a targeted wordlist for specific networks

## Security & Legal Notice

This payload is intended for **authorized security testing only**. Only use against networks you own or have explicit written permission to test. Unauthorized access to computer networks is illegal.

## Related Payloads

- **Interactive Handshake Cracker** (user/exfiltration/handshake_cracker) - Manual cracking with more control
- **Wordlist Manager** (user/general/wordlist_manager) - Download and manage wordlists
