# FlockAudit

**WiFi-based Flock Safety LPR camera detector for the WiFi Pineapple Pager.**

Scans the airspace in monitor mode for Flock Safety camera management APs by OUI and SSID pattern, captures probe requests from devices that have previously connected to them, GPS-tags every find, and exports a KML file for mapping. No internet connection or shared subnet required — works anywhere.

Optionally connects to a discovered camera AP and runs a deep probe: HTTP banner, vendor API (Hikvision ISAPI, Dahua CGI, Axis VAPIX), RTSP check, and default credential test.

- **Author:** sinXne0
- **Category:** Reconnaissance
- **Version:** 4.0

---

## What it does

### Phase 1 — Airspace scan (monitor mode)
Puts the radio in monitor mode and runs `airodump-ng` for a configurable number of seconds. Parses two things from the capture:

- **Beacon frames** — APs whose OUI matches known Flock/camera vendors or whose SSID matches Flock patterns (`Flock_`, `FlockSafety`, `LPR-`, `PlateReader`, `SafetyCam`, `ALPRCam`, etc.)
- **Probe requests** — client devices actively searching for those SSIDs (indicates a device that has previously connected to a Flock camera)

Every find triggers haptic vibration, LED flash, and an on-screen alert.

### Phase 2 — Deep probe (optional)
If deep probe mode is enabled, the Pager connects to each discovered camera AP, gets an IP via DHCP, and probes the gateway address:

- Port scan (`nmap`) on camera-relevant ports (80, 443, 554, 1883, 8080, 8883, 37777, etc.)
- HTTP banner and page title grab
- Hikvision ISAPI `/ISAPI/System/deviceInfo` — returns model/serial/firmware without auth on older firmware
- Dahua CGI `/cgi-bin/magicBox.cgi` — device type and serial number
- Axis VAPIX `/axis-cgi/param.cgi` — product name and serial
- RTSP `DESCRIBE` on port 554 — checks for unauthenticated stream access
- Default credential check — tests 10 common camera default passwords via HTTP Basic auth

### Phase 3 — Output
- Timestamped text report saved to `/root/loot/FlockAudit/`
- KML file with GPS-tagged placemarks for every camera found — open in Google Earth or Maps
- `PINEAPPLE_LOOT_ARCHIVE` called at end for cloud sync

---

## Configuration

On launch the payload asks three questions — no IP addresses or subnets needed:

| Prompt | Default | Notes |
|--------|---------|-------|
| Airspace scan seconds | 30 | Longer = more complete, slower |
| Watch mode | No | Loop continuously — good for driving a route |
| Deep probe | No | Connects to each found AP for full fingerprinting |

---

## Usage

1. Copy to Pager:
```bash
scp -r FlockAudit root@172.16.52.1:/root/payloads/user/reconnaissance/
```

2. Select **FlockAudit** from the Payloads menu
3. Answer the three config prompts
4. Real-time alerts appear as cameras are found
5. Collect report and KML from `/root/loot/FlockAudit/`

---

## Requirements

- `airodump-ng` (aircrack-ng suite) — for airspace scan
- `nmap` — for deep probe port scan (optional)
- `curl` — for HTTP/API probing (optional)
- `nc` — for RTSP probe (optional)
- GPS module connected for KML coordinates

Deep probe features gracefully skip if tools are not installed.

---

## Disclaimer

For authorized security research and assessments only. Ensure compliance with all applicable laws before use.
