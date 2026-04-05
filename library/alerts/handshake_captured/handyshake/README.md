# HandyShake - Enhanced Handshake Capture Alert

**Author:** curtthecoder - github.com/curthayman

**Version:** 1.0

**Category:** Alerts / Handshake Captured

**_(Based on [handshake-ssid](https://github.com/hak5/wifipineapplepager-payloads/pull/22) by RootJunky)_**

## Overview

HandyShake is a comprehensive handshake capture alert payload that provides maximum information and feedback when the Pager captures a WPA/WPA2 handshake or PMKID. It combines visual, tactile, and audio feedback with detailed vendor lookup, GPS logging, duplicate detection, auto-renamed PCAPs, signal strength and channel logging, hash file verification with automatic recovery, and comprehensive statistics tracking. I created this because I was tired of typing "tcpdump -r handshake.pcap" everytime to get the handshake name.

## Features

### 1. Multi-Sensory Feedback
- **Visual (LED):** Color-coded LED indicators based on capture type and quality
  - Green (SUCCESS): Complete & crackable EAPOL handshake
  - Cyan (SOLID): Complete but non-crackable EAPOL
  - Yellow (SLOW): Partial EAPOL handshake
  - Magenta (SOLID): PMKID capture
  - Yellow (FAST): Unknown type
  - White (SOLID): Duplicate capture

- **Tactile (VIBRATE):** Different vibration patterns for each capture type
  - 5 pulses: Complete & crackable EAPOL (maximum celebration)
  - 3 pulses: Complete EAPOL
  - 2 pulses: Partial EAPOL
  - 1 pulse: PMKID
  - Short tap: Duplicate capture, just a little nudge

- **Audio (ALERT_RINGTONE):** Distinct ringtones for different scenarios

### 2. Duplicate Detection
Tracks every AP+Client MAC pair in a capture history file. When a duplicate is detected:
- Alert feedback is reduced to a short tap and white LED (saves battery)
- The capture is tagged `[DUPLICATE]` in the log file
- A `** DUPLICATE CAPTURE **` notice appears in the alert
- The handshake is still logged for completeness

### 3. Comprehensive Information Display
- SSID extraction from summary string (works for partial handshakes) with beacon frame fallback
- Handshake type (EAPOL or PMKID)
- Quality assessment (Complete/Partial/Single Packet)
- Crackability status
- Signal strength (RSSI in dBm) displayed on the alert
- Channel number logged to the log file
- AP MAC address and vendor identification
- Client MAC address and vendor identification
- File paths for PCAP and Hashcat files
- Hash file verification status (OK/MISSING/EMPTY/RECOVERED) logged to the log file
- GPS coordinates (if available), shows "No GPS" when no module is attached
- Running capture counter (e.g. "HANDSHAKE CAPTURED #7"). This is pretty helpful if you are out and about and you keep catching the same damn handskake! This annoyed me so much and I wanted to put this into this alert.

### 4. Auto-Rename PCAPs
Automatically copies captured PCAP files to a descriptive filename format:
```
SSID_AP-MAC_YYYYMMDD_HHMMSS.pcap
```
For example: `MyNetwork_AA-BB-CC-DD-EE-FF_20260215_143022.pcap`
- Original PCAP is preserved
- Renamed copy is referenced in logs
- Special characters in SSIDs are sanitized
- Can be toggled on/off via `ENABLE_AUTO_RENAME`

### 5. Signal Strength and Channel Logging
- **Signal Strength (RSSI):** Extracted from the PCAP radiotap header, displayed in dBm on the alert
- **Channel:** Frequency extracted from PCAP and converted to channel number (2.4GHz channels 1-14, 5GHz channels 36-165), logged to the log file
- Both values show "N/A" if not available in the PCAP

### 6. Hash File Verification and Recovery
Checks the `.22000` hashcat file after each capture:
- **OK:** File exists and contains data
- **MISSING:** File doesn't exist — triggers automatic recovery (see below)
- **EMPTY:** File exists but has zero bytes
- **RECOVERED:** Hash was missing but successfully regenerated from the PCAP via `hcxpcapngtool`

When the hash file is missing, HandyShake automatically attempts to regenerate it from the captured PCAP using `hcxpcapngtool`. This works fully offline, no network required.

### 7. Vendor Lookup
Identifies device manufacturers for both AP and client devices using `whoismac`, which queries the local OUI database at `~/.hcxtools/oui.txt`. Fully offline — no internet connection required.

### 8. GPS Integration
Automatically logs GPS coordinates with each capture for, this is all more Nosey shit you can look back and say "Oh I remember that house, store, etc. I was at!":
- Wardriving documentation
- Geographic mapping of networks
- Location-based analysis
- Displays "No GPS" when no GPS module is attached

### 9. Summary Fallback Parsing
Intelligently parses the handshake summary string when dedicated alert variables aren't populated:
- Detects EAPOL vs PMKID type from summary content
- Determines crackability from summary keywords (e.g., `crackable [B,1,2,4]`)
- Assesses quality from captured EAPOL message numbers
- Ensures accurate type/quality/crackable fields even when firmware doesn't set individual variables

### 10. Detailed Logging
Creates comprehensive logs at `/root/loot/handshakes/handshake_log.txt` with:
- Capture number and timestamp
- Duplicate indicator
- Complete network and device information
- Vendor details
- Signal strength and channel
- File locations with hash file status
- GPS data
- Handshake quality metrics

### 11. Statistics Tracking
Maintains running statistics at `/root/loot/handshakes/statistics.txt`:
- Total handshakes captured
- Breakdown by type (EAPOL vs PMKID)
- Count of crackable captures
- Unique AP+Client pairs vs duplicates
- Most recent capture details (including signal, channel, hash status)
- Auto-updating with each new capture

### 12. System Logging
Integrates with system logs via the `LOG` command for:
- System-wide audit trail
- Integration with other logging tools
- Persistent record keeping

### 13. Device Intelligence
Attempts to identify what type of device the client is based on the vendor name. Shows up in both the alert popup and the log file under `Hint:`. Examples:
- `Espressif Inc.` → `ESP32/ESP8266 IoT device (DIY/smart home)`
- `Texas Instruments` → `IoT/Smart Home device (Texas Instruments chip)`
- `Apple` → `Apple device (iPhone/iPad/MacBook/AirPods)`
- `Samsung` → `Samsung device (Galaxy phone/Smart TV/tablet)`
- `Hon Hai Precision` / `Foxconn` → `Foxconn-built device (Amazon Echo/Fire TV, Nintendo Switch, Sony PlayStation, Vizio TV)`
- `Tonly Technology` → `Tonly Technology device (Bluetooth speaker, soundbar, or TCL audio product)`
- `AltoBeam` → `AltoBeam device (Smart TV, streaming box, or Android TV device)`
- `Tuya` → `Tuya Smart device (smart home appliance - possibly Fireplace)`
- And many more (Amazon, Google, Roku, Sonos, Ring, Nest, TP-Link, Belkin, Wyze, Eufy, Arlo, Bose, Sony, Microsoft, Nintendo, Xiaomi, Huawei, Motorola, Lenovo, Dell, HP, Cisco, Aruba, Ubiquiti, Raspberry Pi)
- If you can think of anything else that I missed! Let me know! @curtthecoder

Only appears in the alert when a match is found. Unknown vendors are silently skipped — no clutter.

### 14. Network Intelligence
Classifies the network type based on AP vendor and SSID keywords:
- **Business/Enterprise** — AP vendor matches enterprise brands (Cisco, Aruba, Meraki, Ruckus, Aerohive, Fortinet, Juniper)
- **Likely Business/Public** — SSID contains keywords like `corp`, `office`, `guest`, `hotel`, `cafe`, `shop`, `restaurant`, `inc`, `llc`, `ltd`
- **Home/Personal (ISP gateway)** — SSID matches common ISP patterns (`Verizon_`, `XFINITY`, `Spectrum`, `ATT`, `Optimum`, `Cox`, `MySpectrumWifi`, `MyFiosGateway`)
- **Home/Personal (consumer router)** — AP vendor matches consumer/ISP router brands (Google, Netgear, Linksys, TP-Link, Asus, Belkin, D-Link, Xfinity, Spectrum, AT&T, Verizon, Comcast, Cox, Eero, Orbi, Synology, Ubiquiti, UniFi, Askey, Sagemcom, Arris, Technicolor, Sercomm)
- **Unknown** — when no match is found

Logged to the log file with each capture.

## Configuration

Edit the configuration section at the top of `payload.sh` to customize behavior:

```bash
# Enable/disable vendor lookup (uses whoismac with local OUI database - no internet needed)
ENABLE_VENDOR_LOOKUP=true

# Enable/disable GPS logging (requires GPS hardware)
ENABLE_GPS_LOGGING=true

# Enable/disable auto-renaming of PCAP files - Why would you want to change this to false, but to each his/her/them own. I pretty much created this payload for this purpose! But I wanted to give people an options, they may have a nother way that they pull the names from the handshakes? 🤷🏾‍♂️
ENABLE_AUTO_RENAME=true

# Customize log file location - Really no reason to change this, but it's a to each their own thing
LOG_FILE="/root/loot/handshakes/handshake_log.txt"

# Capture history for duplicate detection
CAPTURE_HISTORY="/root/loot/handshakes/capture_history.txt"
```

## Alert Message Format

The alert is kept compact to fit the pager screen. All detailed information is written to the log file.

```
Capture #3: YourNetwork
EAPOL (COMPLETE) - CRACKABLE
Signal: -45dBm
AP: AA:BB:CC:DD:EE:FF (Google, Inc.)
Client: 11:22:33:44:55:66 (Espressif Inc.)
Hint: ESP32/ESP8266 IoT device (DIY/smart home)
```

The `Hint:` line only appears when the client vendor is recognized. For duplicate captures, a `[DUP]` tag is appended:
```
Capture #4 [DUP]: YourNetwork
EAPOL (COMPLETE) - CRACKABLE
Signal: -45dBm
AP: AA:BB:CC:DD:EE:FF (Google, Inc.)
Client: 11:22:33:44:55:66 (Espressif Inc.)
Hint: ESP32/ESP8266 IoT device (DIY/smart home)
```

## Handshake Types Explained

### EAPOL (4-Way Handshake)
- **Complete & Crackable:** All 4 frames captured + beacon, ready for offline cracking
- **Complete:** All 4 frames captured but may have issues preventing cracking
- **Partial:** Some frames missing, may still be usable depending on what's captured

### PMKID
- Single packet capture from AP
- Always crackable if present
- Faster to capture, equally valuable for password recovery
- Doesn't require client to be connected

## File Locations

- **Handshake Log:** `/root/loot/handshakes/handshake_log.txt`
- **Statistics:** `/root/loot/handshakes/statistics.txt`
- **Capture History:** `/root/loot/handshakes/capture_history.txt`
- **Debug Log:** `/root/loot/handshakes/debug.txt` (vendor/hint output for troubleshooting, because of the blues it gave me. I don't want anyone else to go through the bullshit I went through, UGGG)
- **PCAPs:** Stored in `/root/loot/handshakes/` (managed by the Pager)
- **Renamed PCAPs:** `SSID_AP-MAC_timestamp.pcap` format in same directory
- **Hashcat Files:** `.22000` format in `/root/loot/handshakes/`

## Dependencies -- All pre-installed on pager

- `tcpdump` - PCAP analysis, SSID extraction, signal strength, and channel detection
- `whoismac` - Offline vendor lookup using local OUI database at `~/.hcxtools/oui.txt`
- `hcxpcapngtool` - Hash file recovery when `.22000` file is missing
- `GPS_GET` - GPS coordinate retrieval (optional)
- Standard Pager commands: `ALERT`, `VIBRATE`, `LED`, `ALERT_RINGTONE`, `LOG`

## Differences from Standard Handshake Alerts

| Feature | Standard Alert | HandyShake |
|---------|---------------|------------|
| Visual Feedback | None | Color-coded LED |
| Tactile Feedback | None | Pattern-based vibration |
| Audio Feedback | Basic | Type-specific ringtones |
| Duplicate Detection | No | Yes (AP+Client tracking) |
| Auto-Rename PCAPs | No | Yes (SSID_MAC_timestamp) |
| Signal Strength | No | Yes (RSSI in dBm) |
| Channel Logging | No | Yes (2.4GHz + 5GHz) |
| Hash File Check | No | Yes (OK/MISSING/EMPTY/RECOVERED) |
| Hash File Recovery | No | Yes (auto-regenerates via hcxpcapngtool) |
| Vendor Lookup | No | Yes (AP + Client, fully offline) |
| Device Intelligence | No | Yes (identifies device type from vendor) |
| Network Intelligence | No | Yes (classifies home/business/enterprise) |
| GPS Logging | No | Yes |
| Capture Counter | No | Yes (running total) |
| Statistics | No | Yes |
| Log File | No | Detailed log |
| Debug Log | No | Yes (vendor/hint troubleshooting) |
| Quality Assessment | Basic | Comprehensive |
| Summary Fallback Parsing | No | Yes |
| SSID Display | Sometimes | Always (summary + beacon fallback) |

## Usage Scenarios

### Wardriving
- GPS coordinates logged with each capture
- Signal strength helps gauge proximity
- Channel logging maps spectrum usage
- Vendor information helps map network types
- Statistics provide session summary
- Duplicate detection reduces noise on repeat passes

### Penetration Testing
- Immediate feedback on capture quality
- Crackability status saves time. Don't have to waste time on something that will take you a WHILE to crack
- Hash file verification catches issues early
- Automatic hash recovery means no lost captures
- Client vendor ID helps identify target devices
- Auto-renamed PCAPs keep loot organized, because it was a pain in the ass to find the .pcap file name of the "AP"

### Security Research
- Comprehensive logs for analysis
- Statistical tracking over time
- Complete metadata preservation
- Signal and channel data for RF analysis

### Training/Education
- Clear feedback helps understand capture types
- Quality indicators teach handshake requirements
- Detailed logs demonstrate capture process
- Capture counter tracks session progress
- Remember always learning!

## Performance Considerations

- **Vendor Lookup:** Direct whoismac pipe, instant local OUI lookup, no network overhead
- **Device/Network Intelligence:** Pure grep-based matching, negligible overhead
- **Hash Recovery:** Only runs when hash file is missing, no overhead on normal captures
- **GPS Logging:** Minimal overhead, disable if GPS not available
- **Auto-Rename:** Minimal overhead (single file copy), disable if disk space is tight
- **Duplicate Detection:** Lightweight grep on history file, negligible impact
- **Signal/Channel:** Extracted during existing tcpdump passes, no extra overhead
- **Hash Verification:** Single file stat check, negligible impact
- **Statistics:** Very lightweight, safe to keep enabled
- **LED/Vibrate:** No performance impact

## Updating the OUI Database

The local OUI database (`~/.hcxtools/oui.txt`) is used by `whoismac` for vendor lookups. If you are seeing frequent "Unknown Vendor" results, the database may be outdated or incomplete. To update it with the latest IEEE OUI list, run the following on the pager while connected to the internet and SSHing into the pager or using the Virtual Pager's terminal:

```bash
cd ~/.hcxtools
rm oui.txt
wget https://standards-oui.ieee.org/oui/oui.txt
```

This replaces the existing database with the full official IEEE OUI registry. All future vendor lookups will use the updated list automatically.

## Troubleshooting

### SSID shows as "UNKNOWN_SSID"
- Network may be hidden (no beacon frames)
- PCAP may not contain beacon data
- This is normal for some captures

### Vendor shows as "Unknown Vendor"
- MAC address OUI not in the local database (`~/.hcxtools/oui.txt`) — update it (see Updating the OUI Database section)
- MAC address may be randomized or spoofed
- `whoismac` not found on the device
- Check `debug.txt` in `/root/loot/handshakes/` to see exactly what vendor and hint values are being resolved at runtime

### Device hint doesn't appear in alert
- Vendor wasn't recognized by the device intelligence classifier
- Vendor shows as "Unknown Vendor" — fix the OUI database first
- Check `debug.txt` for the actual `CLIENT_VENDOR` and `HINT` values being produced

### GPS data shows "No GPS"
- GPS hardware not connected or not enabled
- No GPS fix acquired yet, may have to wait until you get a fix
- `ENABLE_GPS_LOGGING` is set to false

### Signal shows "N/A"
- PCAP may not contain radiotap headers with signal data
- Some capture modes don't include RSSI information

### Channel shows "N/A"
- PCAP may not contain frequency information
- Some capture modes don't include channel data

### Hash file shows "MISSING" or "EMPTY"
- If MISSING, HandyShake will automatically attempt recovery via `hcxpcapngtool`
- If recovery succeeds the status will change to RECOVERED in the log
- If recovery fails, the PCAP may not contain usable handshake material
- EMPTY means the file was generated but no valid hashes were extracted

### No vibration or LED feedback
- Battery may be too low
- Settings may have disabled these features

### Handshake type/quality shows "UNKNOWN"
- The summary fallback parser will attempt to determine type and crackability from the summary string
- If both methods fail, the capture metadata may be incomplete

## Security and Legal Notes

This payload is designed for authorized security testing and research only. Always ensure you have:

- Written permission to test target networks
- Legal authority in your jurisdiction
- Proper documentation of authorized testing scope

Unauthorized interception of wireless communications may be illegal in your jurisdiction. Don't be a skid asshole!

## Version History

### Version 1.0
- Initial release based on handshake-ssid by RootJunky
- Multi-sensory feedback (color-coded LED, vibration patterns)
- Duplicate detection via AP+Client MAC pair tracking
- Auto-rename PCAPs to descriptive filenames (SSID_MAC_timestamp.pcap)
- Signal strength (RSSI) extraction and display on alert
- Channel extraction with MHz-to-channel-number conversion
- Running capture counter
- Hash file verification (OK/MISSING/EMPTY) with automatic recovery via hcxpcapngtool
- Vendor lookup via whoismac (fully offline, using `~/.hcxtools/oui.txt`)
- GPS logging with "No GPS" fallback
- Summary fallback parsing for accurate type/quality detection
- Comprehensive log file and statistics tracking
- Device intelligence — client device type hints in alert and log (ESP32, Apple, Google, Samsung, Amazon, etc.)
- Network intelligence — classifies captures as home/business/enterprise based on AP vendor and SSID
- SSID extraction from summary string for partial handshakes (beacon frame fallback for complete handshakes)
- Debug log (`debug.txt`) for vendor and hint troubleshooting. I created this for me, but I figured I would keep it in there as it might help if someone is having issues. I kinda want to make this a thing with my payloads 🤷🏾‍♂️
- Ash shell compatibility fixes for reliable execution on the pager, this literally gave me the blues as I wasn't up to date with the Ash shell. Ran into hours/days of errors because of a "Space" in my code! Beauty of learning new things and coding!

## Credits

- **Original Concept:** [handshake-ssid by RootJunky](https://github.com/hak5/wifipineapplepager-payloads/pull/22)
- **Enhanced Version:** curtthecoder
- **Platform:** Hak5 WiFi Pineapple Pager
- **Inspiration:** [deduplicate](https://github.com/hak5/wifipineapplepager-payloads/pull/128) by Unit981, [example](https://github.com/hak5/wifipineapplepager-payloads/tree/master/library/alerts/handshake_captured/example) by Hak5Darren and RootJunky

## Support

For issues, suggestions, or contributions:
- Look me up on Discord, Im always on there! Hit me @curtthecoder

## License

This payload is provided as-is for educational and authorized security testing purposes. Like I said before and always, don't be a skid asshole!
