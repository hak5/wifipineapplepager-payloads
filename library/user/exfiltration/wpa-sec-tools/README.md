# WPA-SEC Tools

**Author:** Aitema-GmbH
**Version:** 1.3
**Category:** user/exfiltration
**Target:** WiFi Pineapple Pager

## Description

A comprehensive toolkit for interacting with [wpa-sec.stanev.org](https://wpa-sec.stanev.org), the free distributed WPA/WPA2 password cracking service.

This payload provides three main functions:
1. **Bulk Upload** - Upload all captured handshakes at once
2. **Check Results** - View cracked passwords directly on your Pager
3. **Setup** - Configure your WPA-SEC API key

## What is WPA-SEC?

[wpa-sec.stanev.org](https://wpa-sec.stanev.org) is a free community-driven distributed WPA/WPA2 cracking service. When you upload a handshake:

- Thousands of volunteer GPUs work together to crack the password
- Massive wordlists and advanced rule-based attacks are used
- You get notified when passwords are cracked
- The service is completely free

## Features

- **Interactive Menu**: Easy-to-use numbered menu system
- **Bulk Upload**: Scans all loot directories for PCAP files
- **Smart Discovery**: Finds handshakes in standard and archive locations
- **Progress Tracking**: Real-time upload status with success/fail counts
- **Duplicate Detection**: Skips already-uploaded handshakes
- **Password Display**: View cracked passwords on your Pager screen
- **Local Storage**: Saves cracked passwords to file
- **Rate Limiting**: Prevents overwhelming the wpa-sec servers
- **Error Handling**: Comprehensive error messages and retry support

## Prerequisites

### 1. WPA-SEC Account & API Key

1. Visit [https://wpa-sec.stanev.org/?get_key](https://wpa-sec.stanev.org/?get_key)
2. Register for a free account
3. Copy your API key from the profile page

### 2. Internet Connection

The Pineapple needs internet access for uploads and result checking.

### 3. Captured Handshakes

Use the Pineapple's built-in handshake capture functionality to capture WPA/WPA2 handshakes.

## Installation

### Option 1: Copy Files Manually

```bash
# Copy to your Pineapple
scp -r wpa-sec-tools root@172.16.52.1:/root/payloads/user/exfiltration/

# Set permissions
ssh root@172.16.52.1 "chmod 755 /root/payloads/user/exfiltration/wpa-sec-tools/*.sh"
```

### Option 2: Using Payload Manager

1. Copy the `wpa-sec-tools` folder to a USB drive
2. Insert USB into Pineapple
3. Use the file manager to copy to `/root/payloads/user/exfiltration/`

## Configuration

### Method 1: Interactive Setup (Recommended)

1. Run the payload
2. Select option `3` (Setup)
3. Enter your API key when prompted
4. The key is saved to `/root/config/wpa-sec.conf`

### Method 2: Edit Config File

Edit `config.sh` directly:

```bash
export WPA_SEC_KEY="your_32_character_api_key_here"
```

## Usage

### Running the Payload

1. Navigate to: **Payloads → User → Exfiltration → WPA-SEC Tools**
2. Select an action from the menu

### Menu Options

```
==========================================
  WPA-SEC TOOLS
==========================================

wpa-sec.stanev.org integration

API key: a1b2c3d4...

Select action:

1. Bulk Upload Handshakes
2. Check Cracked Passwords
3. Setup / Configure
```

### Option 1: Bulk Upload

Uploads all PCAP files from:
- `/root/loot/handshakes/`
- `/root/loot/dragonblood/`
- `/root/loot/archive/*/handshakes/`

**Process:**
1. Scans all directories for PCAP files
2. Confirms upload count with user
3. Uploads each file with progress indicator
4. Shows summary (success/skipped/failed)

**Example Output:**
```
==========================================
  WPA-SEC BULK UPLOAD
==========================================

Found: 15 PCAP files

[1/15] handshake_001.pcap
  OK
[2/15] handshake_002.pcap
  Skip (already uploaded)
...

==========================================
  UPLOAD COMPLETE
==========================================
Success: 12
Skipped: 2
Failed:  1
```

### Option 2: Check Results

Queries wpa-sec for cracked passwords.

**Example Output:**
```
==========================================
  WPA-SEC RESULTS
==========================================

Fetching cracked passwords...

----------------------------------------
SSID:     MyNetwork
BSSID:    AA:BB:CC:DD:EE:FF
PASSWORD: secretpassword123
----------------------------------------
SSID:     CoffeeShopWiFi
BSSID:    11:22:33:44:55:66
PASSWORD: freewifi2024

Found 2 cracked password(s)!
```

### Option 3: Setup

Interactive configuration wizard:
1. Prompts for API key
2. Tests key validity against wpa-sec API
3. Saves configuration

## Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                       WPA-SEC TOOLS                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌───────────┐     ┌───────────┐     ┌───────────┐             │
│  │  SETUP    │────▶│   BULK    │────▶│   CHECK   │             │
│  │ Configure │     │  UPLOAD   │     │  RESULTS  │             │
│  │  API Key  │     │ All PCAPs │     │ Cracked   │             │
│  └───────────┘     └─────┬─────┘     └─────┬─────┘             │
│                          │                 │                    │
└──────────────────────────│─────────────────│────────────────────┘
                           │                 │
                           ▼                 ▼
              ┌────────────────────────────────────┐
              │        wpa-sec.stanev.org          │
              │   Distributed Cracking Network     │
              │   (Thousands of Volunteer GPUs)    │
              └────────────────────────────────────┘
```

## Output Files

| Path | Description |
|------|-------------|
| `/root/loot/wpa-sec/cracked_passwords.txt` | All cracked passwords |
| `/root/loot/wpa-sec/bulk_upload.log` | Upload history |
| `/root/loot/wpa-sec/failed_uploads_*.txt` | Failed upload queue |
| `/root/config/wpa-sec.conf` | Configuration file |

### Cracked Passwords File Format

```
SSID: NetworkName
BSSID: AA:BB:CC:DD:EE:FF
PASSWORD: thepassword
---
SSID: AnotherNetwork
BSSID: 11:22:33:44:55:66
PASSWORD: anotherpassword
---
```

## LED States

| State | Color | Meaning |
|-------|-------|---------|
| SETUP | Magenta | Ready / Menu |
| ATTACK | Yellow | Operation in progress |
| FINISH | Green | Operation successful |
| FAIL | Red | Error occurred |

## Troubleshooting

### "WPA-SEC not configured"

**Cause:** API key not set.

**Solution:** Run Setup (option 3) and enter your API key.

### "No handshakes found"

**Cause:** No PCAP files in the expected locations.

**Solution:** Capture some handshakes first using the Pineapple's capture functionality.

### Upload Fails

**Cause:** Network issue or wpa-sec server problem.

**Solution:**
1. Check internet connection
2. Try again later
3. Check `/root/loot/wpa-sec/failed_uploads_*.txt` for failed files

### "No cracked passwords yet"

**Cause:** Passwords haven't been cracked yet.

**Solution:** Distributed cracking takes time. Check back in a few hours or days. Complex passwords may never be cracked.

### Menu Not Displaying

**Cause:** DuckyScript UI issue.

**Solution:** Restart the Pager or try running the payload again.

## Security & Legal Notes

- **API Key Security**: Keep your API key private
- **Data Privacy**: Uploaded handshakes are visible to volunteer crackers
- **Legal Use Only**: Only upload handshakes from networks you own or have permission to test
- **No Malicious Use**: This tool is for authorized security testing only

## Technical Details

### Directory Scanning

The bulk upload function scans:
```
/root/loot/handshakes/*.pcap
/root/loot/handshakes/*.pcapng
/root/loot/handshakes/*.cap
/root/loot/dragonblood/*.pcap
/root/loot/dragonblood/captures/*.pcap
/root/loot/archive/*/handshakes/*.pcap
```

### API Endpoints

**Upload:**
```
POST https://wpa-sec.stanev.org
Cookie: key=YOUR_API_KEY
Content-Type: multipart/form-data
```

**Check Results:**
```
GET https://wpa-sec.stanev.org/?api&dl=1
Cookie: key=YOUR_API_KEY

Response format: BSSID_HEX:CLIENT_HEX:SSID:PASSWORD
```

### BusyBox Compatibility

This payload is designed for OpenWrt with BusyBox:
- Uses POSIX-compatible shell syntax
- Avoids GNU-specific options
- Uses `[ ]` tests instead of `[[ ]]`

## Related Payloads

- **wpa-sec-upload** (`alerts/handshake_captured/wpa-sec-upload/`): Automatic upload on handshake capture

## Changelog

### Version 1.3
- Fixed BusyBox grep compatibility
- Improved API response parsing
- Added archive directory scanning
- Enhanced error messages
- Added rate limiting for bulk uploads

### Version 1.2
- Added interactive setup wizard
- Global config file support
- Improved duplicate detection

### Version 1.1
- Added bulk upload progress tracking
- Password file saving

### Version 1.0
- Initial release

## Credits

- [wpa-sec.stanev.org](https://wpa-sec.stanev.org) - Free distributed WPA cracking
- [Hak5](https://hak5.org) - WiFi Pineapple Pager

## License

This payload is released under the [Hak5 License](https://github.com/hak5/wifipineapplepager-payloads/blob/master/LICENSE).
