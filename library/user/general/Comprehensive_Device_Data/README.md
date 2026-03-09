# Comprehensive Device Data  
### HAK5 WiFi Pineapple Pager Payload

**Author:** RocketGod  
**RocketGod's Links:** https://betaskynet.com  
**Crew:** The Pirates’ Plunder – https://discord.gg/thepirates  

---

## Overview

**Comprehensive Device Data** is a WiFi Pineapple Pager payload designed to give you a full device overview.

This payload enumerates system health, network state, radios, connected clients, active services, and live connections—directly from the Pineapple itself.

## What It Collects

### 🧠 Device & System
- Hardware model
- Firmware version
- CPU identification
- Uptime
- Battery status (if present)
- Memory usage (available vs total)

### 💾 Storage
- Mounted storage devices
- Available vs total space per mount

### 🌐 Networking
- Active IPv4 interfaces
- Assigned IP addresses
- Default gateway detection
- Ethernet link status

### 🔌 USB
- Connected USB devices

### 📶 WiFi Radios
- 2.4 GHz APs and client mode
- Associated SSIDs
- Connected client counts
- 5 GHz monitor detection and channel info

### 🟦 Bluetooth
- Adapter presence
- Status (active / inactive)
- MAC address
- Paired device count

### 🔓 Ports & Services
- Listening TCP ports
- Listening UDP ports
- Service name correlation

### 🔗 Live Connections
- Active established TCP connections
- Remote IP → local port mapping
- Associated process names

### 📱 Clients
- WiFi-associated clients with signal strength
- DHCP leases (hostname or MAC fallback)

---

## Interface Behavior

- **DPAD LED**
  - Cyan: Running
  - Green: Completed
  - Off: Exit / Cleanup

- **Controls**
  - `A` → Exit payload cleanly