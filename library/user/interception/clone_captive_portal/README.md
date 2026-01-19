# Clone Captive Portal

Automatically scan for WiFi networks, detect captive portals, clone them, and configure an evil twin access point.

## Overview

This payload provides end-to-end automation for captive portal reconnaissance and cloning. It connects to target networks, detects and downloads captive portal pages, modifies them for credential capture, and optionally configures the Pineapple's Open AP as an evil twin.

## Features

- **SSID Scanning** - Scan nearby networks sorted by signal strength
- **Auto-Connection** - Connect to open or WPA-protected networks
- **Portal Detection** - Detect captive portals via standard connectivity check endpoints
- **Recursive Cloning** - Download portal HTML, CSS, JS, and images
- **Credential Capture** - Auto-modify forms to submit to `/captiveportal/`
- **Evil Twin Setup** - Configure Open AP with cloned SSID and optional MAC
- **SSID Pool** - Add target SSID to pool for future use
- **State Restoration** - Save and restore interface and Open AP state on exit

## Usage

1. Run the payload from the Pineapple Pager menu
2. Wait for SSID scan to complete
3. Select target network from the list
4. Enter password if prompted (for WPA networks)
5. Wait for portal detection and cloning
6. Choose deployment options:
   - Configure Open AP as evil twin
   - Clone MAC address for full impersonation
   - Add to SSID Pool
7. Run `goodportal Configure` to serve the cloned portal

## Workflow

| Phase | Description |
|-------|-------------|
| 1 | Scan for SSIDs using wlan1 (up to 20 networks) |
| 2 | User selects target network from numbered list |
| 3 | Connect to network (open or WPA with password) |
| 4 | Detect captive portal via standard detection URLs |
| 5 | Clone portal recursively (HTML, CSS, JS, images) |
| 6 | Create credential capture handler (PHP wrapper) |
| 7 | Configure evil twin (Open AP SSID/MAC, SSID Pool) |

## Output Locations

| Path | Description |
|------|-------------|
| `/www/goodportal/{ssid}_{timestamp}/` | Cloned portal files |
| `/root/loot/captive_portals/` | Backup copy of cloned portals |
| `/root/loot/goodportal/` | Captured credentials (via goodportal) |

## Compatibility

Cloned portals are compatible with:
- **goodportal_configure** payload (recommended)
- **EvilPortals** collection format ([github.com/kleo/evilportals](https://github.com/kleo/evilportals))

## Dependencies

| Package | Purpose | Auto-Install |
|---------|---------|--------------|
| `iw` | WiFi scanning and interface management | No (built-in) |
| `wpa_supplicant` | Network connection | No (built-in) |
| `curl` | Portal detection and fallback cloning | No (built-in) |
| `wget` | Recursive portal cloning | Yes (if missing) |

## Captive Portal Detection

The payload checks these standard connectivity endpoints:

- `http://connectivitycheck.gstatic.com/generate_204` (Google/Android)
- `http://www.gstatic.com/generate_204` (Google)
- `http://clients3.google.com/generate_204` (Google)
- `http://captive.apple.com/hotspot-detect.html` (Apple)
- `http://www.apple.com/library/test/success.html` (Apple)
- `http://detectportal.firefox.com/success.txt` (Firefox)
- `http://www.msftconnecttest.com/connecttest.txt` (Microsoft)

A captive portal is detected when these URLs return a redirect (HTTP 302) or unexpected content.

## Configuration

Edit the following variables in `payload.sh` to customize behavior:

```bash
INTERFACE="wlan1"        # WiFi interface for scanning/connecting
LOOT_DIR="/root/loot/captive_portals"  # Backup location
PORTAL_DIR="/www/goodportal"           # Portal serving directory
TIMEOUT=15               # Connection timeout (seconds)
MAX_SSIDS=20             # Maximum SSIDs to display
```

## Design Principles

- Save and restore interface state on exit (cleanup trap)
- Save and restore Open AP config if modified
- User confirmation before destructive actions
- Auto-install missing dependencies with user consent
- Compatible with goodportal and evilportals ecosystems
- Fallback methods (wget → curl) for portal cloning
- Handle both open and WPA-protected networks

## Educational Use

This payload is intended for educational and authorized security testing purposes only. It demonstrates how captive portals work and how they can be cloned for security research. Always obtain proper authorization before using this tool on any network.

## Red Team Use

For authorized red team engagements:

1. Clone the target's captive portal with this payload
2. Configure evil twin with matching SSID (and optional MAC)
3. Run `goodportal Configure` to serve the cloned portal
4. Captured credentials are saved to `/root/loot/goodportal/`
5. Whitelisted clients bypass the firewall to access the internet

## Changelog

### Version 1.0
- Initial release
- SSID scanning with signal strength sorting
- Open and WPA network connection support
- Captive portal detection via multiple endpoints
- Recursive portal cloning with wget/curl fallback
- Form action modification for credential capture
- PHP credential handler with login overlay fallback
- Interface state save/restore
- Open AP configuration via UCI (persistent)
- MAC cloning option for full evil twin
- SSID Pool integration
- Open AP config backup/restore

## Todo

- [ ] Support for 802.1X/Enterprise network authentication
- [ ] Automatic goodportal_configure integration (start portal after clone)
- [ ] JavaScript-based portal detection for SPAs
- [ ] Option to clone multiple pages (follow links)
- [ ] Certificate cloning for HTTPS portals

## Troubleshooting

### "No networks found"
- Ensure wlan1 is not in use by another process
- Try moving closer to target networks
- Check if interface exists: `iw dev`

### "Failed to connect"
- Network may require password - try again with WPA option
- Network may use 802.1X (not yet supported)
- Check signal strength - may be too weak

### "No captive portal detected"
- Network may not have a captive portal
- Portal may use HTTPS-only (limited support)
- Portal may use JavaScript-based detection

### "Clone failed"
- Portal may block wget user-agent
- Portal may require authentication first
- Check available disk space

## Related Payloads

- **goodportal_configure** - Serve cloned portals and capture credentials
- **goodportal_remove** - Remove captive portal configuration
- **Quick-Clone-Pro** - Clone AP SSID/MAC without portal cloning

## Author

WiFi Pineapple Pager Community

## License

For authorized security testing and educational use only.
