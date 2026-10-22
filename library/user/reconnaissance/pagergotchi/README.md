![Pagergotchi](screenshots/pagergotchi-header.png)

![Pagergotchi](https://img.shields.io/badge/Hak5-WiFi%20Pineapple%20Pager-green)

A port of [Pwnagotchi](https://github.com/jayofelern/pwnagotchi) for the Hak5 WiFi Pineapple Pager.

## Features

- **Automated WiFi Handshake Capture** - PMKID and 4-way handshake attacks via pineapd
- **Cute ASCII Pet** - Personality-driven face that reacts to activity
- **Native Display** - Fast C library rendering via libpagerctl.so (480x222 RGB565)
- **Non-Blocking Pause Menu** - Two-column settings layout with 2D navigation; attacks continue in background
- **Theme System** - 4 built-in themes (Default, Cyberpunk, Matrix, Synthwave) + custom themes via JSON
- **Brightness Control** - Adjustable screen brightness (20-100% in 10% steps)
- **Auto-Dim** - Configurable idle timeout with adjustable dim level
- **Privacy Mode** - Obfuscates MACs, SSIDs, and GPS on display
- **GPS Support** - Optional GPS logging in WiGLE-compatible format
- **Whitelist & Blacklist** - Fine-grained target control with BSSID support
- **WiGLE Integration** - Export captures for WiGLE database uploads
- **App Handoff** - Seamlessly switch to other payloads (e.g., Bjorn) from the pause menu
- **Self-Contained** - All dependencies bundled, only requires Python3

## Dependencies

**Required:** The PAGERCTL (`/mmc/root/payloads/user/utilities/PAGERCTL/`) utilities payload (`libpagerctl.so` + `pagerctl.py`), available in this repository under `user/utilities/PAGERCTL`.

Compile from source or download precompiled binaries per the instructions in the [pagerctl](https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl) project.

On first launch, `payload.sh` automatically searches for pagerctl in:
1. `lib/` (local copy)
2. `/mmc/root/payloads/user/utilities/PAGERCTL`

If found in the PAGERCTL utilities directory, it is copied into `lib/` automatically. If not found, the payload displays instructions and exits.

**You can also manually copy the files into the payload's `lib/` directory:**
```bash
cp libpagerctl.so lib/
cp pagerctl.py lib/
```

**Python3** with ctypes is also required. The payload offers to auto-install it on first run if missing (requires internet).

## Installation

1. Copy the `pagergotchi` folder into:
   ```
   /root/payloads/user/reconnaissance/
   ```

2. Install the PAGERCTL (`/mmc/root/payloads/user/utilities/PAGERCTL/`) payload (from this repository under `user/utilities/PAGERCTL`). Pagergotchi auto-detects it on launch and copies the files into `lib/`.

3. The payload will appear in the Pager's payload menu under **Reconnaissance > Pagergotchi**.

4. On first run, Python3 will be auto-installed if needed (requires internet).

## Usage

### Payload Launch

When you select Pagergotchi from the payload menu, you'll see the launch screen:

![Payload Launch](screenshots/payload-launch.png)

Press **GREEN** to start or **RED** to exit.

### Startup Menu

![Startup Menu](screenshots/mainmenu.png)

- **Start Pagergotchi** - Begin automated operation
- **Deauth Scope** - Configure whitelist/blacklist
- **Privacy** - Toggle display obfuscation (ON/OFF)
- **WiGLE** - Toggle WiGLE CSV logging (ON/OFF)
- **Log APs** - Toggle AP discovery logging (ON/OFF)
- **Clear History** - Reset attack tracking for all networks

### Main Display

Once started, Pagergotchi shows the main hunting display:

![Startup](screenshots/startup.png)

The display shows channel, AP count, uptime, status messages, personality-driven ASCII face, GPS coordinates (if available), PWND count, and battery status.

| Discovering APs | Client Found |
|-----------------|--------------|
| ![Discover AP](screenshots/discover-ap.png) | ![Client Discovered](screenshots/client-discovered.png) |

| Deauthing | Handshake Captured |
|-----------|-------------------|
| ![Deauthed](screenshots/deauthed.png) | ![Handshake Captured](screenshots/handshake-captured.png) |

### Pause Menu

Press **RED** at any time during operation to open the pause menu. The agent continues capturing handshakes in the background.

![Pause Menu](screenshots/pause-menu.png)

Use UP/DOWN to navigate rows, LEFT/RIGHT to move between columns, and GREEN to cycle values or select actions.

### Themes

| Default | Cyberpunk | Matrix | Synthwave |
|---------|-----------|--------|-----------|
| ![Default](screenshots/themes-default.png) | ![Cyberpunk](screenshots/themes-cyberpunk.png) | ![Matrix](screenshots/themes-matrix.png) | ![Synthwave](screenshots/themes-synthwave.png) |

Custom themes can be added via `data/custom_themes.json`. Copy the included example to get started:
```bash
cp data/custom_themes.example.json data/custom_themes.json
```

### Deauth Scope

Control which networks are targeted with whitelist (never attack) and blacklist (only attack these):

| Deauth Scope | Scan & Add | Whitelist View |
|-------------|------------|----------------|
| ![Deauth Scope](screenshots/deauth-scope.png) | ![Scanning](screenshots/scanning-aps.png) | ![Whitelist](screenshots/whitelist-view.png) |

### Privacy Mode

When enabled, sensitive data is obfuscated on the display:

| Data Type | Example | Obfuscated |
|-----------|---------|------------|
| SSID | `MyNetwork` | `MXXXXXXK` |
| MAC/BSSID | `AA:BB:CC:11:22:33` | `AA:BB:CC:XX:XX:XX` |
| GPS | (any coordinates) | `LAT 38.871 LON -77.055` |

## Configuration

Edit `config.conf` for persistent settings:

```ini
[general]
debug = false

[capture]
interface = wlan1mon

[channels]
# Leave empty for all 2.4/5/6GHz bands, or specify: 1,6,11
channels =

[whitelist]
# Use on-screen menu for easier management with BSSID support
ssids =

[deauth]
enabled = true

[timing]
throttle_d = 0.9
throttle_a = 0.4
```

Runtime settings (theme, brightness, privacy, auto-dim, etc.) are managed through the pause menu and saved to `data/settings.json`.

## Data Storage

| Path | Contents |
|------|----------|
| `data/settings.json` | Runtime settings (auto-created) |
| `data/recovery.json` | Attack history (auto-created) |
| `/root/loot/handshakes/` | Captured .pcap and .22000 files |
| `/root/loot/wigle/` | WiGLE CSV exports |
| `/root/loot/ap_logs/` | AP discovery logs |

## Credits

- **Author**: brAinphreAk
- **Website**: [www.brAinphreAk.net](http://www.brainphreak.net)
- **Support**: [ko-fi.com/brainphreak](https://ko-fi.com/brainphreak)
- **Based on**: [Pwnagotchi](https://github.com/evilsocket/pwnagotchi) by evilsocket
- **Display Library**: [pagerctl](https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl)

## License

This project is based on Pwnagotchi which is licensed under GPL-3.0.

## Disclaimer

This tool is intended for authorized security testing and educational purposes only. Only use on networks you own or have explicit permission to test. Unauthorized access to computer networks is illegal.
