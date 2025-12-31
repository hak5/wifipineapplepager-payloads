# Tailscale Payloads for WiFi Pineapple Pager

A complete suite of payloads for managing Tailscale on the WiFi Pineapple Pager.

## Available Payloads

### 1. Tailscale Installer (`tailscale_installer/`)
**Purpose:** Install Tailscale binaries and init script

**Features:**
- Automatically detects and downloads latest Tailscale for mipsle architecture
- Installs binaries to /usr/sbin
- Creates init.d service script
- Creates configuration directories

**When to use:** First-time setup or reinstallation

**Important:** After installation, you MUST run **Tailscale Configure** to complete setup.

---

### 2. Tailscale Configure (`tailscale_configure/`)
**Purpose:** Configure Tailscale after installation

**Features:**
- Configure auto-start preference
- Interactive authentication via URL
- Start Tailscale service
- Connect to Tailscale network

**When to use:**
- Immediately after running Tailscale Installer
- To reconfigure settings

**Note:** Interactive authentication is recommended as it doesn't require typing long keys on the device.

---

### 3. Tailscale Status (`tailscale_status/`)
**Purpose:** Check current Tailscale connection status

**Features:**
- Shows connection state (Connected/Stopped/Needs Login)
- Displays Tailscale IP address
- Shows connected devices
- Logs full status information

**When to use:** Check if Tailscale is running and connected

---

### 4. Tailscale Connect (`tailscale_connect/`)
**Purpose:** Connect to Tailscale network

**Features:**
- Starts tailscaled daemon if needed
- Interactive authentication via URL if needed
- Displays authentication URL when required
- Shows assigned Tailscale IP on success

**When to use:**
- After reboot to reconnect
- After disconnecting
- To re-authenticate

---

### 5. Tailscale Disconnect (`tailscale_disconnect/`)
**Purpose:** Disconnect from Tailscale network

**Features:**
- Gracefully disconnects from network
- Keeps Tailscale installed
- Confirmation dialog to prevent accidents

**When to use:**
- Temporarily disconnect without uninstalling
- Conserve battery/bandwidth
- Switch networks

---

### 6. Tailscale Uninstaller (`tailscale_uninstaller/`)
**Purpose:** Completely remove Tailscale from device

**Features:**
- Stops and disables service
- Removes all binaries
- Deletes configuration and state
- Double confirmation to prevent accidents

**When to use:** Complete removal of Tailscale

---

## Quick Start Guide

### First Time Setup
1. Run **Tailscale Installer**
2. Wait for installation to complete
3. Run **Tailscale Configure**
4. Choose auto-start preference
5. Visit authentication URL on another device
6. Wait for authentication to complete (automatic)
7. Note your Tailscale IP (displayed on screen)
8. Press any button to exit


### Removal
1. Run **Tailscale Uninstaller**
2. Confirm twice
3. All files removed

### Scenario: Device Rebooted
```
1. Run: Tailscale Status (check if auto-start worked)
2. If not connected: Run Tailscale Connect
```

### Scenario: Need to Re-authenticate
```
1. Run: Tailscale Connect
2. Visit URL shown in logs (if authentication required)
3. Approve device
```

### Scenario: Switching Tailscale Accounts
```
1. Run: Tailscale Disconnect
2. Run: Tailscale Connect
3. Authenticate with new account
```

### Scenario: Complete Removal
```
1. Run: Tailscale Disconnect (optional)
2. Run: Tailscale Uninstaller
3. Confirm removal
```

## File Locations

- **Binaries:** `/usr/sbin/tailscale`, `/usr/sbin/tailscaled`
- **Init Script:** `/etc/init.d/tailscaled`
- **Configuration:** `/etc/tailscale/`
- **State:** `/root/.tailscale/`
- **Runtime:** `/var/run/tailscale/`

## Manual Commands (SSH)

Tailscale CLI Reference:
https://tailscale.com/kb/1080/cli

If you prefer SSH access:

```bash
# Check status
tailscale status

# Get IP
tailscale ip -4

# Connect
tailscale up

# Disconnect
tailscale down

# Service control
/etc/init.d/tailscaled start
/etc/init.d/tailscaled stop
/etc/init.d/tailscaled restart
/etc/init.d/tailscaled enable   # Auto-start
/etc/init.d/tailscaled disable  # No auto-start
```

## Troubleshooting

### Payload Not Showing in UI
- Ensure files are in `/root/payloads/user/tailscale/`
- Check that `payload.sh` is executable: `chmod +x payload.sh`
- Verify file is named `payload.sh` or `payload`

### Connection Fails
- Run **Tailscale Status** to check daemon
- Verify internet connectivity
- Check logs for error messages
- Try re-authentication

### Auth URL Not Working
- Ensure URL is complete (check logs)
- Try copying full URL manually
- Try running Tailscale Configure again

### Service Won't Start
- Check if binaries exist: `ls -la /usr/sbin/tailscale*`
- Verify init script: `ls -la /etc/init.d/tailscaled`
- Check logs: `logread | grep tailscale`

## Security Notes

- Configure ACLs in Tailscale admin panel to restrict access
- Regularly review connected devices
- Disable auto-start if device may be captured
- Remove device from Tailscale admin if compromised

## Support

- Tailscale Documentation: https://tailscale.com/kb/
- Tailscale Admin Console: https://login.tailscale.com/admin/

