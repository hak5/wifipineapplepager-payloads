# PWRLVL9000 — WiFi Pineapple Pager Pentest Console

A full-featured pentesting web UI payload for the **[WiFi Pineapple Pager](https://shop.hak5.org/products/wifi-pineapple-pager)** (M5 series), firmware **2.0.0-stable** or newer.

Runs a Python3 HTTP server on port **9000**, serving a hacker-themed single-page app with 9 tool tabs accessible from any browser on the same network.

> **For authorized penetration testing and security research only.**

### Firmware 2.0.0 notes

- Uses the firmware-managed monitor interfaces (`wlan0mon`, `wlan1mon`, `wlan2mon`) — pick them in the interface dropdowns. The payload never bounces the managed base radios; on older firmware it falls back to the classic `iw` monitor toggle.
- If the bundled `libpagerctl` display is incompatible with the current firmware, the payload automatically falls back to the on-device LOG display — the web console keeps running either way.
- The display debounces the stop button for 3s after launch (2.0.0's rebuilt input stack can deliver stale events from the button press that started the payload, which used to make the payload exit instantly and report "completed"), and any display exit faster than 5 seconds is treated as a failure and falls back instead of stopping the server.
- No firewall rules needed: 2.0.0 accepts LAN-side input by default (the payload only touches `iptables` if the binary exists).

---

## Features

| Tab | Tool | Description |
|-----|------|-------------|
| **WiFi** | airodump-ng / aireplay-ng | Scan APs, capture handshakes, deauth clients |
| **Probe** | airodump-ng (client mode) | Sniff probe requests, track visible devices |
| **Rogue AP** | hostapd + dnsmasq | Evil twin AP + beacon flood (mdk4) |
| **WPS** | wash + reaver/bully | Scan WPS networks, launch pixie dust attack |
| **Web** | Python http.client | HTTP/HTTPS web scanner (headers, forms, paths) |
| **Network** | raw sockets + ARP | Port scanner + ARP table |
| **Capture** | tcpdump + hcxdumptool | Packet capture with BPF filter + PMKID capture |
| **Loot** | aircrack-ng + hcxpcapngtool | View handshakes, crack with wordlist, convert to `.22000` |
| **Shell** | /bin/sh | Root terminal with command history |

**UI extras:** Matrix rain background, glitch header, XP leveling system, animated necromancer sprite, live SSE event stream, toast notifications.

---

## Requirements

### On the Pager (OpenWrt, firmware 2.0.0+)
- Python 3 (`python3-light` — `opkg install python3-light`)
- `aircrack-ng` suite — `airodump-ng`, `aireplay-ng`, `aircrack-ng`
- `hostapd`, `dnsmasq` — for Rogue AP
- `wash`, `reaver` or `bully` — for WPS attacks
- `mdk4` or `mdk3` — for beacon flood
- `tcpdump` — for packet capture
- `hcxdumptool`, `hcxpcapngtool` — optional, for PMKID capture and `.22000` conversion

Tools are discovered automatically via `which` + path search (including `/mmc/usr/sbin/`). Missing tools produce a clean error rather than crashing.

---

## Install

### Copy to Pager

```bash
# From your local machine (category layout used by the payload repo):
scp -r pwrlvl9000/ root@172.16.42.1:/root/payloads/user/interception/

# Or onto the SD card:
scp -r pwrlvl9000/ root@172.16.42.1:/mmc/root/payloads/user/interception/
```

### Activate

Load the payload from the Pager's payload menu. The web console starts on port **9000**.

Open from a connected device:
```
http://172.16.42.1:9000
```

Press **B** (back button) on the Pager to stop the server and return to the main menu.

---

## File Structure

```
pwrlvl9000/
├── payload.sh          # Pager launcher script
├── server.py           # Python3 backend (HTTP + SSE, ~600 lines)
├── pager_display.py    # Direct pager screen control (libpagerctl)
├── lib/
│   ├── pagerctl.py     # Pager hardware API wrapper
│   └── libpagerctl.so  # Native pager control library
└── web/
    ├── index.html      # SPA shell (9 tabs)
    ├── css/
    │   └── pwrlvl.css  # Neon green hacker theme
    └── scripts/
        ├── app.js      # Tab router, SSE client, matrix rain, XP system
        ├── wifi.js     # WiFi scan + attack
        ├── probe.js    # Probe sniffer + client tracker
        ├── rogueap.js  # Evil twin + beacon flood
        ├── wps.js      # WPS scan + pixie dust attack
        ├── webscan.js  # Web scanner
        ├── network.js  # Port scanner + ARP
        ├── capture.js  # Packet capture + PMKID
        ├── loot.js     # Handshake vault + crack + convert
        └── terminal.js # Root shell
```

---

## Architecture

- **Backend**: `http.server.SimpleHTTPRequestHandler` (Bjorn pattern, OpenWrt-compatible)
- **Threading**: `socketserver.ThreadingTCPServer` — each request in its own thread
- **Live updates**: Server-Sent Events (`/events`) push tool output to all connected browsers in real time
- **No external Python deps**: only stdlib (`http.server`, `socketserver`, `subprocess`, `json`, `socket`, `threading`, `queue`, `glob`, `re`)

---

## Legal

This tool is intended for use on networks and devices you own or have explicit written authorization to test. Unauthorized use is illegal. The author assumes no liability for misuse.
