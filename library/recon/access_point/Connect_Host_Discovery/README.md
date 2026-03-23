# Connect_Host_Discovery

**Version:** 1.3  
**Author:** Stuffy24  
**Category:** Recon / Network Enumeration  
**Platform:** Hak5 WiFi Pineapple Pager / OpenWrt-based payloads  
**Technique:** Client Mode Connect + Nmap Host Discovery

---

## Overview

**Recon Connect** connects the Pager to a selected wireless access point in **client mode**, validates network assignment, and performs **lightweight host discovery** on the connected subnet using Nmap (`-sn`).

This version intentionally **removes all UI spinners** to prevent payload lockups and ensure reliable execution on constrained OpenWrt environments.

The payload is designed for:
- **Fast, low-noise host discovery**
- **Permission-based assessments** (your own networks or explicitly authorized targets)
- **Educational, defensive, and lab use**

---

## What This Payload Does

1. **Confirms authorization** before running.
2. **Uses Recon Target selection** to identify the chosen AP.
3. **Connects in client mode** (open or WPA2/WPA-PSK).
4. **Waits for a valid IPv4 address** on the client interface (`wlan0cli`).
5. **Calculates subnet variables** (IP, gateway, network CIDR, /24 helpers).
6. **Runs Nmap host discovery only**:
   ```bash
   nmap -sn -n -S <client_ip> <target_cidr>
