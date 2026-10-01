# Wi‑Fi Beacon Bomb

A lightweight Python payload that broadcasts fake 802.11 beacon frames to simulate multiple access points. This README is synchronized with the code in `src/` and `core/` (Bash setup script and Python core script).

> Warning: Use only in controlled environments where you have explicit permission to perform wireless testing.

## What is included

- `core/core.py` — Python 3 script that generates and injects beacon frames using Scapy.
- `src/payload.sh` — Bash setup script that prepares the environment, enables monitor mode, and launches the Python script in the background.

## Requirements

- Python 3
- Scapy (`python3 -m pip install scapy`)
- A wireless adapter that supports monitor mode and packet injection
- Linux-based environment for running packet injection tools (e.g., airmon-ng, iwconfig)
- WiFi Pineapple Pager (optional; can run on any Linux system with proper wireless adapter)

## Quick start

### Direct execution

Run the setup script from the `src` directory:

```bash
bash payload.sh
```

It will:
- Install Python dependencies (pip, Scapy)
- Auto-detect wireless interface if needed
- Enable monitor mode using airmon-ng or iwconfig
- Launch the core beacon bomb script in the background
- Log all output to `/tmp/wifi_bomb.log`

**LED Indicators (WiFi Pineapple Pager):**
- 🟣 Magenta Solid — Configuring environment and dependencies
- 🟠 Amber Blink — Monitor mode activated
- 🟢 Green Solid — Beacon bomb core script launched
- 🔴 Red Blink — Error during setup

## Configuration

### Environment variables (payload.sh & core.py)

- `WIFI_IFACE` — Primary wireless interface (default: `wlan0`)
- `WIFI_MON_IFACE` — Explicit monitor mode interface override (optional; auto-detected if empty)
- `WIFI_BOMB_IFACE` — Monitor mode interface name for core script (default: `wlan0mon`)
- `WIFI_BOMB_TOTAL` — Number of fake APs per cycle (default: `1000`)
- `WIFI_BOMB_INTERVAL` — Seconds between packets (default: `0.005`)
- `WIFI_LOG_FILE` — Log file path (default: `/tmp/wifi_bomb.log`)

### Command-line arguments (core.py)

- `--iface` — Monitor mode interface to use (env: `WIFI_BOMB_IFACE`)
- `--total` — Number of fake APs per cycle (env: `WIFI_BOMB_TOTAL`)
- `--interval` — Seconds between packets (env: `WIFI_BOMB_INTERVAL`)
- `--simulate` — Simulate only; do not transmit packets
- `--verbose` — Print per-packet info to stdout

### Example configurations

```bash
# Use payload script (recommended setup):
bash payload.sh

# Override interface and total APs:
env WIFI_IFACE=wlan1 WIFI_BOMB_TOTAL=2000 bash payload.sh

# Direct core.py execution with 2000 fake APs and 10ms interval:
env WIFI_BOMB_IFACE=wlan0mon WIFI_BOMB_TOTAL=2000 WIFI_BOMB_INTERVAL=0.01 python3 core/core.py

# Simulate without transmitting, with verbose output:
python3 core/core.py --simulate --verbose

# Use custom interface:
python3 core/core.py --iface ath0 --total 500
```

## How it works (implementation notes)

- The script builds 802.11 beacon frames with Scapy:
  - `RadioTap` layer for wireless transmission metadata
  - `Dot11` layer with broadcast address (addr1=`ff:ff:ff:ff:ff:ff`)
  - `Dot11Beacon` with capability flags: `ESS+privacy`
  - `Dot11Elt` elements for SSID, Rates, and DSset (channel info)
- It generates locally administered MAC addresses with:
  - First byte: `0x02` (indicates locally administered)
  - Second byte: `0x00-0x7f` (randomized, limited range)
  - Remaining 4 bytes: fully randomized
- SSID selection: **randomly selected** from the SSID list on each beacon frame (not sequential)
- Packets are sent via Scapy's `sendp(pkt, iface=iface, count=1, verbose=False)` in a tight loop
- The payload script (`payload.sh`) handles:
  - Wireless interface auto-detection (via `iwconfig`)
  - Package installation and dependency management (apt-get + pip)
  - Monitor mode activation via airmon-ng (with fallback to iwconfig)
  - Background process management with `nohup`
  - Comprehensive logging to `/tmp/wifi_bomb.log` and stdout
  - Error handling with graceful degradation
- A KeyboardInterrupt (Ctrl+C) stops the loop and exits cleanly.

## SSID List

The script randomly selects from a list of 22 funny/prank SSID names (22 total):

```
Searching...
Loading_WiFi_99%
Get_Your_Own_WiFi
Connecting_to_FBI_van...
Virus_Infected_AP
Router_Not_Found
Password_is_12345678
Click_Here_For_Free_RAM
Tell_My_WiFi_Love_Her
No_Free_WiFi_Here
Win_XP_Error_404
Searching_for_signal...
cheeky-breeky-iv-WANkey
what_are_you_looking
english_or_spanish
english_or_english
kim_jong_WAN
FBI_network
buy_you_own_rounter_you_thief
gameover_zeus_network
anakin_skyLANker
ankara_LANSSI
```

## Safety and ethics

Use this only on equipment and networks you own or are authorized to test. Broadcasting many fake APs can:
- Disrupt nearby Wi‑Fi clients and infrastructure
- Cause performance degradation on wireless networks
- Interfere with legitimate Wi‑Fi operations
- May violate local telecommunications regulations

**The author is not responsible for misuse.**

## Disclaimer & Usage Notice

> **WARNING:** This tool is designed for educational and authorized testing purposes only.

* **Default Behavior:** The tool ships with safe default operational limits (default: `1000` APs per cycle).
* **User Responsibility:** Modifying execution parameters, signal power, or cycle limits may result in hardware stress, packet flooding, or module overheating depending on your environment.
* **Liability:** The author assumes no responsibility for hardware damage or misuse resulting from parameter adjustments.

## Troubleshooting

### No packets being transmitted
- Verify monitor mode is active: `iwconfig | grep Monitor`
- Check adapter supports packet injection: `aireplay-ng -9 your_interface`
- Try simulation mode first: `python3 core/core.py --simulate --verbose`
- Check logs: `tail -f /tmp/wifi_bomb.log`

### Monitor mode activation fails
- Ensure aircrack-ng suite is installed: `apt-get install aircrack-ng`
- Try manual setup: `sudo airmon-ng check kill && sudo airmon-ng start wlan0`

### Python/Scapy issues
- Verify Scapy is installed: `python3 -m pip list | grep scapy`
- Reinstall if needed: `python3 -m pip install --upgrade scapy`

## License

See the repository LICENSE file.
