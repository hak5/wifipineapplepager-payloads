# Tailscale VPN Installer for WiFi Pineapple Pager

**Author:** JAKONL  
**Version:** 1.0  
**Category:** Remote Access  
**Target:** WiFi Pineapple Pager

## Description

This payload installs and configures Tailscale VPN on the WiFi Pineapple Pager, enabling secure remote access to your device from anywhere in the world. Tailscale creates a secure mesh VPN network using WireGuard, allowing you to access your Pager even when it's behind NAT or firewalls.

Perfect for:
- Remote management during field operations
- Secure access without port forwarding
- Persistent connectivity across network changes
- Multi-device coordination in red team operations

## Features

- ✅ **Automated Installation** - Downloads and installs latest Tailscale for MIPS architecture
- ✅ **Latest Version Detection** - Automatically detects and installs the latest stable release
- ✅ **Interactive Setup** - User-friendly configuration wizard
- ✅ **Interactive Authentication** - Simple URL-based authentication
- ✅ **Auto-Start Option** - Configure service to start at boot
- ✅ **Management Tools** - Easy start/stop/status commands
- ✅ **Complete Uninstaller** - Clean removal when needed
- ✅ **Progress Indicators** - Visual feedback during installation
- ✅ **Error Handling** - Comprehensive error checking and recovery

## TODO
- [ ] Add exit node selection payload

## What is Tailscale?

From the Tailscale website: https://tailscale.com/kb/1151/what-is-tailscale

Tailscale is a zero-config VPN built on WireGuard that:
- Creates a secure mesh network between your devices
- Works through NAT and firewalls without configuration
- Provides each device with a stable IP address (100.x.y.z)
- Encrypts all traffic end-to-end
- Requires no server setup or maintenance

## Prerequisites

### 1. Tailscale Account

Create a free Tailscale account at https://tailscale.com

### 2. Network Connectivity

The Pager must have internet access during installation to download Tailscale binaries.

### 3. Storage Space

Ensure at least 85MB of free storage space:
```bash
df -h
```

## Installation

### Method 1: Interactive Installation (Recommended)

1. Copy the `tailscale_installer` directory to your Pager:
   ```
   /payloads/library/user/remote_access/tailscale_installer/
   ```

2. Run the installer payload via Pager UI

3. Wait for installation to complete

4. Run the configure payload

5. Follow the on-screen prompts:
   - Choose auto-start preference
   - Complete authentication

### Authentication

1. The configure payload starts Tailscale and generates a unique URL
2. The URL is displayed in the payload logs
3. Visit the URL on another device (phone, laptop)
4. Log in to your Tailscale account
5. Approve the Pager device
6. Authentication completes automatically

**Example URL:**
```
https://login.tailscale.com/a/abc123def456
```

## Usage

### Accessing Your Pager

Once Tailscale is running, access your Pager from any device on your Tailscale network:

```bash
# SSH via Tailscale IP
ssh root@100.x.y.z

# Web interface via Tailscale IP
http://100.x.y.z
```

Find your Pager's Tailscale IP:
```bash
tailscale ip -4
```

### Management via Payloads

Use the dedicated Tailscale payloads for common operations:

- **Tailscale Status** - Check connection status and IP
- **Tailscale Connect** - Connect to Tailscale network
- **Tailscale Disconnect** - Disconnect from network
- **Tailscale Uninstaller** - Completely remove Tailscale

All payloads are available in the Pager UI under:
```
User Payloads → tailscale → Tailscale [Operation]
```

### Configuration File

Payload settings are stored in `/etc/tailscale/config`:

```bash
# View configuration
cat /etc/tailscale/config

# Example contents:
# AUTO_START=yes
# CONFIGURED_DATE=2026-01-01 12:30:00
```

### ACL Tags

You can apply tags to your Pager device through the Tailscale admin console after authentication for automatic ACL rules (e.g., `tag:pager`, `tag:redteam`).

## Troubleshooting

### Installation Fails

**Problem:** Download fails  
**Solution:** Check internet connectivity, verify URL is accessible

**Problem:** Extraction fails  
**Solution:** Ensure sufficient disk space, check file integrity

**Problem:** Binary installation fails  
**Solution:** Verify write permissions to `/usr/sbin`

### Authentication Issues

**Problem:** Auth URL not displayed  
**Solution:** Check payload logs for the complete URL

**Problem:** Authentication timeout
**Solution:** Complete authentication within 5 minutes, or restart

### Connection Problems

**Problem:** Cannot connect to Tailscale network  
**Solution:** 
```bash
# Check service status
/etc/init.d/tailscaled status

# Restart service
/etc/init.d/tailscaled restart

# Check logs
logread | grep tailscale
```

**Problem:** Tailscale IP not assigned  
**Solution:**
```bash
# Verify authentication
tailscale status

# Re-authenticate if needed
tailscale up
```

### Service Issues

**Problem:** Service won't start  
**Solution:**
```bash
# Check if already running
ps | grep tailscaled

# Kill existing process
killall tailscaled

# Start fresh
/etc/init.d/tailscaled start
```

**Problem:** Service doesn't start at boot  
**Solution:**
```bash
# Verify auto-start is enabled
/etc/init.d/tailscaled enabled

# Re-enable if needed
/etc/init.d/tailscaled enable
```

## File Locations

```
/usr/sbin/tailscale          # Tailscale CLI binary
/usr/sbin/tailscaled         # Tailscale daemon binary
/etc/init.d/tailscaled        # Init script for service management
/etc/tailscale/config        # Configuration file
/root/.tailscale/            # State directory
/var/run/tailscale/          # Runtime socket directory
```

## Security Considerations

⚠️ **Important Security Notes:**

- **Network Exposure** - Tailscale provides direct access to your Pager from any device on your network
- **ACL Rules** - Configure Tailscale ACLs to restrict access appropriately
- **Exit Nodes** - Be cautious when using Pager as exit node (bandwidth/legal implications)
- **Logging** - Tailscale logs connection metadata (not payload data)

## Uninstallation

### Using Tailscale Uninstaller Payload

Run the **Tailscale Uninstaller** payload from the Pager UI:
```
User Payloads → Remote Access → Tailscale Uninstaller
```

The uninstaller will:
- Confirm the operation (double confirmation)
- Stop and disable the service
- Remove all binaries
- Delete configuration and state files

### Manual Uninstallation (SSH)

```bash
# Stop and disable service
/etc/init.d/tailscaled stop
/etc/init.d/tailscaled disable

# Remove binaries
rm -f /usr/sbin/tailscale
rm -f /usr/sbin/tailscaled

# Remove init script
rm -f /etc/init.d/tailscaled

# Remove configuration and state
rm -rf /etc/tailscale
rm -rf /root/.tailscale
rm -rf /var/run/tailscale
```

## Changelog

### Version 1.0 (2025-12-21)
- Initial release
- Automated installation for MIPS architecture
- Automatic latest version detection
- Interactive authentication
- Auto-start configuration
- Dedicated management payloads (status, connect, disconnect, uninstall)
- Comprehensive error handling and DuckyScript integration

## Resources

- **Tailscale Documentation:** https://tailscale.com/kb/
- **Tailscale Admin Console:** https://login.tailscale.com/admin
- **ACL Configuration:** https://login.tailscale.com/admin/acls

## License

This payload is provided for educational and authorized use only. Users are solely responsible for compliance with all applicable laws and regulations.

## Credits

- **Author:** JAKONL
- **Platform:** WiFi Pineapple Pager by Hak5
- **Tailscale:** https://tailscale.com

