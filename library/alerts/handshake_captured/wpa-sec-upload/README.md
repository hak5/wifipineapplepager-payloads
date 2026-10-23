# WPA-SEC Auto Upload

**Author:** Aitema-GmbH
**Version:** 1.3
**Category:** alerts/handshake_captured
**Target:** WiFi Pineapple Pager

## Description

Automatically uploads captured WPA/WPA2 handshakes to [wpa-sec.stanev.org](https://wpa-sec.stanev.org) for distributed password cracking.

**wpa-sec.stanev.org** is a free community-driven distributed WPA/WPA2 cracking service. When you upload a handshake, thousands of volunteer GPUs work together to crack the password using massive wordlists and rule-based attacks.

This payload triggers automatically whenever the Pineapple Pager captures a handshake, enabling a seamless capture-to-crack workflow.

## Features

- **Automatic Upload**: Triggers on every handshake capture
- **PCAP Format**: Uploads raw PCAP files (preferred by wpa-sec)
- **Visual Feedback**: LED states and optional vibration/alerts
- **Local Backup**: Saves copies to `/root/loot/wpa-sec/`
- **Upload History**: Tracks all uploads with timestamps
- **Retry Queue**: Failed uploads are queued for later retry
- **Duplicate Detection**: Skips already-submitted handshakes

## Prerequisites

### 1. WPA-SEC Account & API Key

1. Visit [https://wpa-sec.stanev.org/?get_key](https://wpa-sec.stanev.org/?get_key)
2. Register for a free account
3. Copy your API key from the profile page
4. The key is a 32-character hexadecimal string (e.g., `a1b2c3d4e5f6...`)

### 2. Internet Connection

The Pineapple Pager needs internet access to upload handshakes. Options:
- Connect via USB to a host with internet sharing
- Connect to a WiFi network with internet access
- Use mobile hotspot tethering

## Installation

### Option 1: Copy Files Manually

1. Copy all files to your Pineapple:
   ```bash
   scp -r wpa-sec-upload root@172.16.52.1:/root/payloads/alerts/handshake_captured/
   ```

2. Set permissions:
   ```bash
   ssh root@172.16.52.1 "chmod 755 /root/payloads/alerts/handshake_captured/wpa-sec-upload/*.sh"
   ```

### Option 2: Using USB Drive

1. Copy the `wpa-sec-upload` folder to a USB drive
2. Insert USB into Pineapple
3. Copy files via the Pineapple's file manager

## Configuration

Edit `config.sh` and replace the placeholder with your API key:

```bash
# Your WPA-SEC API Key (REQUIRED)
export WPA_SEC_KEY="YOUR_API_KEY_HERE"  # <-- Replace this!
```

### Optional Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `AUTO_UPLOAD` | `true` | Enable/disable automatic uploads |
| `VIBRATE_ON_SUCCESS` | `true` | Vibrate Pager on successful upload |
| `SHOW_ALERT` | `true` | Show notification on upload |
| `CONNECT_TIMEOUT` | `30` | Connection timeout (seconds) |
| `MAX_TIME` | `120` | Max upload time (seconds) |

## Usage

### Automatic Mode (Default)

1. Configure your API key in `config.sh`
2. Go hunting for handshakes!
3. When a handshake is captured:
   - LED turns **yellow** (uploading)
   - LED turns **green** (success) or **red** (failure)
   - Optional vibration and alert notification
4. Check cracked passwords at [wpa-sec.stanev.org/?my_nets](https://wpa-sec.stanev.org/?my_nets)

### Workflow Diagram

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Pineapple     │     │   This Payload  │     │   wpa-sec.org   │
│   Captures      │────▶│   Auto-Uploads  │────▶│   Distributed   │
│   Handshake     │     │   PCAP File     │     │   Cracking      │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                        ┌─────────────────┐              │
                        │   PASSWORD      │◀─────────────┘
                        │   CRACKED!      │
                        └─────────────────┘
```

## Output

### Files Created

| Path | Description |
|------|-------------|
| `/root/loot/wpa-sec/` | Backup copies of uploaded PCAPs |
| `/root/loot/wpa-sec/upload.log` | Upload history and debug log |
| `/root/loot/wpa-sec/history.csv` | CSV tracking all uploads |
| `/root/loot/wpa-sec/pending_uploads.txt` | Queue of failed uploads |

### Log Format

```
[2024-01-15 14:32:01] ==========================================
[2024-01-15 14:32:01] HANDSHAKE CAPTURED - WPA-SEC UPLOAD
[2024-01-15 14:32:01] ==========================================
[2024-01-15 14:32:01] Type: eapol
[2024-01-15 14:32:01] AP: AA:BB:CC:DD:EE:FF
[2024-01-15 14:32:01] Client: 11:22:33:44:55:66
[2024-01-15 14:32:01] Uploading: /root/loot/handshakes/capture.pcap
[2024-01-15 14:32:03] SUCCESS: Uploaded capture.pcap
```

## LED States

| State | Color | Meaning |
|-------|-------|---------|
| ATTACK | Yellow | Upload in progress |
| FINISH | Green | Upload successful |
| FAIL | Red | Upload failed |

## Checking Results

### Via Web Interface

1. Go to [wpa-sec.stanev.org/?my_nets](https://wpa-sec.stanev.org/?my_nets)
2. Login with your account
3. View cracked passwords

### Via Companion Payload

Use the **wpa-sec-tools** payload (in `user/exfiltration/`) to:
- Bulk upload existing handshakes
- Check for cracked passwords directly on the Pager

## Troubleshooting

### "No API key configured"

**Cause:** The `config.sh` file is missing or API key not set.

**Solution:**
1. Edit `config.sh`
2. Replace `YOUR_API_KEY_HERE` with your actual key
3. Get your key at [wpa-sec.stanev.org/?get_key](https://wpa-sec.stanev.org/?get_key)

### Upload Fails Silently

**Cause:** No internet connection.

**Solution:**
1. Verify internet: `ping -c 1 wpa-sec.stanev.org`
2. Check connection method (USB, WiFi, tethering)
3. Review log: `cat /root/loot/wpa-sec/upload.log`

### "Already submitted" Messages

**Cause:** You've already uploaded this handshake.

**Solution:** This is normal! wpa-sec de-duplicates uploads. Check your results at [wpa-sec.stanev.org/?my_nets](https://wpa-sec.stanev.org/?my_nets)

### PCAP Not Uploading

**Cause:** File format issue.

**Solution:** wpa-sec only accepts `.pcap`, `.pcapng`, and `.cap` files. The `.22000` hashcat format is NOT accepted.

## Security & Legal Notes

- **API Key Security**: Your API key links uploads to your account. Keep it private.
- **Data Privacy**: Uploaded handshakes are processed by volunteer crackers. The SSIDs and BSSIDs are visible to the network.
- **Legal Use Only**: Only capture handshakes from networks you own or have explicit permission to test.
- **Responsible Disclosure**: If you discover a vulnerability during authorized testing, follow responsible disclosure practices.

## Technical Details

### API Endpoint

```
POST https://wpa-sec.stanev.org
Cookie: key=YOUR_API_KEY
Content-Type: multipart/form-data
Body: file=@handshake.pcap
```

### Response Parsing

wpa-sec returns hcxpcapngtool analysis output. Success indicators:
- `processed cap files`
- `written to 22000`
- `EAPOL pairs written`
- `PMKID.*written`

### BusyBox Compatibility

This payload is tested on OpenWrt with BusyBox. It avoids:
- GNU-specific grep options (`-P`, `--version`)
- Bash-specific syntax where possible
- Non-portable shell features

## Related Payloads

- **wpa-sec-tools** (`user/exfiltration/wpa-sec-tools/`): Bulk upload and check cracked passwords

## Changelog

### Version 1.3
- Fixed BusyBox grep compatibility for OpenWrt
- Improved response parsing for wpa-sec API
- Skip `.22000` files (wpa-sec only accepts PCAP)
- Added upload history CSV tracking

### Version 1.2
- Added global config file support (`/root/config/wpa-sec.conf`)
- Improved error handling and logging

### Version 1.1
- Added duplicate detection
- Added retry queue for failed uploads

### Version 1.0
- Initial release

## Credits

- [wpa-sec.stanev.org](https://wpa-sec.stanev.org) - Free distributed WPA cracking service
- [Hak5](https://hak5.org) - WiFi Pineapple Pager
- [hcxtools](https://github.com/ZerBea/hcxtools) - Handshake conversion tools

## License

This payload is released under the [Hak5 License](https://github.com/hak5/wifipineapplepager-payloads/blob/master/LICENSE).
