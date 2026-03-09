# Custom NMAP Scan (WiFi Pineapple Payload) - **Version 1.0**

## Author
0xmupa - https://0xmupa.github.io/

---

## Description

This payload provides an interactive Nmap scanning workflow for the WiFi Pineapple Pager.  
It allows the user to select predefined Zenmap-style scan profiles or define fully custom Nmap flags, followed by flexible target selection.

---

## Features

- Zenmap-style predefined scan profiles
- Custom scan mode with manual Nmap flags
- Target selection options:
  - Manual IP or subnet input
  - Automatically detected connected subnet
- Real-time Nmap output streamed to the Pager log
- Automatic loot storage in multiple formats
- Simple and intuitive dialog flow

---

## Included Scan Profiles

- Quick Scan  
- Quick Scan Plus  
- Intense Scan  
- Intense Scan (No Ping)  
- Ping Scan  
- TCP SYN Scan  
- UDP Scan (Top Ports)  
- Full Port Scan  
- Custom Scan (Manual Flags)

---

## Workflow

1. Select the scan type from a list of predefined profiles or choose the custom scan option. Enter custom Nmap flags if custom scan is selected.
2. Select the target type:
   - Manual IP or subnet
   - Connected subnet
4. The scan starts immediately after the selections are completed.
5. Scan output is streamed live to the Pager log and results are saved into /root/loot/nmapcust/{date}.

---

## Output & Loot

Scan results are saved under: /root/loot/nmapcust/{date}

