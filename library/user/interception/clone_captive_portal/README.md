# Clone Captive Portal

Automatically scan for WiFi networks, detect captive portals, clone them, and configure an evil twin access point.

## Overview

This payload provides end-to-end automation for captive portal reconnaissance and cloning. It connects to target networks, detects and downloads captive portal pages, modifies them for credential capture, and optionally configures the Pineapple's Open AP as an evil twin.

## Features

### Core Features
- **SSID Scanning** - Scan nearby networks sorted by signal strength
- **Auto-Connection** - Connect to open or WPA-protected networks
- **Recursive Cloning** - Download portal HTML, CSS, JS, and images (level=2)
- **Credential Capture** - Auto-modify forms to submit to `/captiveportal/`
- **Evil Twin Setup** - Configure Open AP with cloned SSID and optional MAC
- **SSID Pool** - Add target SSID to pool for future use
- **State Restoration** - Save and restore interface and Open AP state on exit

### Enhanced Portal Detection (v1.1+)
- **DNS Hijack Detection** - Detect portals that intercept all DNS queries
- **HTTP Connectivity Check** - Standard method using known endpoints
- **HTTPS Detection** - Detect HTTPS-only portals (with cert bypass)
- **JavaScript Redirect Extraction** - Parse JS redirects from portal pages
- **WISPr XML Parsing** - Support for enterprise hotspot protocols
- **Gateway Direct Access** - Fallback check on network gateway
- **Headless Browser** - Optional JS rendering (requires phantomjs/chromium)

### Advanced Analysis (v1.3)
- **MAC Bypass Detection** - Detect if portal whitelists by MAC address
- **AJAX/API Detection** - Find XHR, fetch, axios API endpoints
- **Form Field Analysis** - Identify password fields, CSRF tokens, hidden fields
- **Cookie Analysis** - Track session cookies and expiration times
- **SSL Certificate Extraction** - Extract CN, issuer, validity from HTTPS portals
- **Template Detection** - Identify Cisco, Aruba, Meraki, UniFi, etc.

### Robustness (v1.2+)
- **Cookie Preservation** - Maintain session across requests
- **User Agent Rotation** - Rotate between iOS, Android, Windows, macOS agents
- **Rate Limit Handling** - Detect HTTP 429 with exponential backoff
- **Auto-Reconnect** - Recover from connection drops during cloning
- **Signal/Band Filtering** - Filter by signal strength and 2.4/5GHz

### Form Handling
- **URL Parameter Preservation** - Keep Coova/ChilliSpot params as hidden fields
- **Form Action Rewriting** - Redirect submissions to credential handler
- **Method Conversion** - Convert GET forms to POST

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
| 1 | Scan for SSIDs using wlan0cli (up to 20 networks) |
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

### Required
| Package | Purpose | Auto-Install |
|---------|---------|--------------|
| `iw` | WiFi scanning and interface management | No (built-in) |
| `wpa_supplicant` | Network connection | No (built-in) |
| `curl` | Portal detection and fallback cloning | No (built-in) |
| `wget` | Recursive portal cloning | Yes (if missing) |

### Optional (Enhanced Features)
| Package | Purpose | Auto-Install |
|---------|---------|--------------|
| `openssl-util` | SSL certificate extraction | Yes (prompted) |
| `grep` | GNU grep for advanced pattern matching | Yes (prompted) |
| `phantomjs` or `chromium` | Headless browser for JS-heavy portals | No (manual) |

## Captive Portal Detection

The payload uses multiple detection methods in sequence:

### Method 1: DNS Hijack Detection
Checks if DNS queries for known domains return unexpected IPs (indicates portal intercepting all DNS).

### Method 2: HTTP Connectivity Check
Tests standard connectivity endpoints:
- `http://connectivitycheck.gstatic.com/generate_204` (Google/Android)
- `http://captive.apple.com/hotspot-detect.html` (Apple)
- `http://detectportal.firefox.com/success.txt` (Firefox)
- `http://www.msftconnecttest.com/connecttest.txt` (Microsoft)

### Method 3: HTTPS Connectivity Check
Tests HTTPS endpoints for HTTPS-only portals:
- `https://www.google.com/generate_204`
- `https://captive.apple.com/hotspot-detect.html`

### Method 4: Gateway Direct Access
Checks the network gateway directly for portal content.

### Method 5: Headless Browser (Optional)
If enabled, uses phantomjs/chromium to render JavaScript-heavy portals.

### Detection Triggers
- HTTP 301/302/307 redirects
- Unexpected content in response
- WISPr XML response
- JavaScript redirects (`window.location`, meta refresh)
- Portal keywords in content

## Configuration

Edit the following variables in `payload.sh` to customize behavior:

```bash
INTERFACE="wlan0cli"        # WiFi interface for scanning/connecting
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

### Version 1.3
- **Advanced Portal Analysis**
  - MAC-based bypass detection (detects if portal whitelists by MAC)
  - AJAX/API endpoint detection (finds XHR, fetch, axios calls)
  - Form field analysis (password fields, CSRF tokens, hidden fields)
  - Cookie expiration analysis (session planning)
  - SSL certificate extraction (CN, issuer, validity)
- **Reliability**
  - Auto-reconnect if connection drops during cloning
  - Session timeout detection and handling
  - Response time tracking for rate-limit tuning
  - wpa_supplicant driver fallback (nl80211 → wext → auto)
- **Portal Processing**
  - HTML sanitization (removes Google Analytics, Facebook Pixel, etc.)
  - Portal archive export (`.tar.gz` for backup/transfer)
  - Goodportal integration (auto-deploy to `/www/portals`)
- **User Experience**
  - Configuration persistence (save/load settings)
  - Extended analysis report files saved with clone
  - Optional dependency installation prompt
- **Compatibility**
  - BusyBox grep support (replaced grep -P with sed/awk)
  - OpenSSL availability check with graceful degradation
  - Fixed date command for BusyBox (seconds instead of nanoseconds)

### Version 1.2
- **Robustness Improvements**
  - Cookie preservation across requests (session handling)
  - User agent rotation (iOS, Android, Windows, macOS, iPad)
  - Rate limit detection (HTTP 429) with automatic backoff
  - Multi-language portal keywords (EN, ES, FR, DE)
- **Portal Analysis**
  - Template detection (Cisco, Aruba, Meraki, UniFi, Ruckus, FortiGate, MikroTik, etc.)
  - Portal screenshot capture (when headless browser enabled)
  - Asset inlining (CSS/images as base64 for offline use)
  - Portal verification (checks for broken references)
- **Scan Filtering**
  - Signal strength filter (hide weak networks < -85 dBm)
  - Band selection (2.4GHz only, 5GHz only, or all)
- **Logging**
  - Detailed log file saved to `/root/loot/captive_portals/clone_*.log`

### Version 1.1
- **Enhanced Portal Detection**
  - DNS hijack detection (intercepts all DNS)
  - HTTPS connectivity check (HTTPS-only portals)
  - JavaScript redirect extraction (window.location, meta refresh)
  - WISPr XML parsing (enterprise hotspots)
  - Optional headless browser support (phantomjs/chromium)
- **Improved Cloning**
  - Multi-page recursive cloning (level=2)
  - URL parameter preservation (Coova/ChilliSpot support)
- **User Experience**
  - Graceful exit options after failures
  - Headless browser prompt (optional)
  - Better error messages with detection method info

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

## Output Files

Each cloned portal includes analysis reports:

| File | Description |
|------|-------------|
| `portal_info.txt` | Clone metadata (SSID, BSSID, URL, timestamp) |
| `ssl_cert_info.txt` | SSL certificate details (HTTPS portals) |
| `api_endpoints.txt` | Detected AJAX/API endpoints |
| `form_analysis.txt` | Form field analysis (password, CSRF, hidden) |
| `cookie_analysis.txt` | Cookie expiration and session info |
| `screenshot.png` | Portal screenshot (if headless enabled) |
| `{name}.tar.gz` | Portable archive of entire portal |

## Todo

- [ ] Support for 802.1X/Enterprise network authentication
- [x] ~~Automatic goodportal_configure integration~~ (v1.3)
- [ ] Certificate cloning for HTTPS portals
- [ ] Social OAuth flow interception
- [ ] Captive portal bypass techniques (MAC spoofing automation)
- [ ] Multi-portal comparison (diff between clones)

## Troubleshooting

### "No networks found"
- Ensure wlan0cli is not in use by another process
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
