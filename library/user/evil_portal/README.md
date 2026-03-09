# Evil Portal

## Description
A complete Evil Portal implementation for the WiFi Pineapple Pager, including captive portal detection and credential capture.

## Author
PentestPlaybook

## Payloads

| Payload | Description |
|---------|-------------|
| `install_evil_portal` | Installs Evil Portal service and dependencies |
| `enable_evil_portal` | Enables Evil Portal to start on boot |
| `disable_evil_portal` | Disables Evil Portal from starting on boot |
| `start_evil_portal` | Starts the Evil Portal service |
| `stop_evil_portal` | Stops the Evil Portal service |
| `restart_evil_portal` | Restarts the Evil Portal service |
| `default_portal` | Activates the default captive portal theme |

## Requirements
- WiFi Pineapple Pager (OpenWrt 24.10.1)
- Active internet connection (for initial package installation)

## Installation Order
1. Run `install_evil_portal` first

Evil Portal is automatically enabled and started during installation.

### Triggering the Captive Portal
After connecting to the Evil WPA network, the captive portal should appear automatically. If it doesn't:
1. Go to WiFi settings and tap "Sign in to network" or "Sign In"
2. On Android, tap the WiFi network name to see the sign-in option
3. Open any browser and navigate to a non-HTTPS site (e.g., `http://example.com`)
   
### Reverting to Default Portal
To switch back to the default portal, run `default_portal` or `restart_evil_portal`.

## Installation Options

### Isolated Subnet
During installation, you will be prompted to enable an isolated subnet. This option:

- Creates a separate network (10.0.0.0/24) for the Evil WPA access point
- Ensures the captive portal only appears when clients connect to Evil WPA
- Prevents the portal from affecting clients on the management network (172.16.52.0/24)

**Recommended:** Enable isolated subnet if you want the portal to only capture credentials from Evil WPA clients.

## Features
- Automatic captive portal detection for iOS and Android devices
- Credential capture to `/root/logs/credentials.json`
- Client authorization management via nftables

## Quick Reference

### Simulate Captive Portal Authorization
```bash
# Get your client's private IP
cat /tmp/dhcp.leases

# Add your client's private IP to the allow list
echo "x.x.x.x" > /tmp/EVILPORTAL_CLIENTS.txt

# Restart to clear the allow list
/etc/init.d/evilportal restart
```

### View Captured Credentials
```bash
cat /root/logs/credentials.json
```

## Troubleshooting

### Debugging Any Payload
```bash
# Run with verbose output
bash -x payload.sh 2>&1 | tee install.log

# Check system logs
logread | tail -50

# View recent errors
logread | grep -i error | tail -20
```

### Common Issues
- **"No space left on device"** - Free up storage or use external storage
- **"Package not found"** - Run `opkg update` first
- **Network errors** - Verify internet connection is active

### Portal Not Loading After Activation
If a newly activated portal doesn't appear on your device:
1. Connect to `172.16.52.1` on your PC browser to confirm the correct portal is loaded
2. Disconnect and reconnect your test device from the WiFi network
3. Wait longer - some devices cache the previous portal and take time to refresh
4. Try "Forget Network" on your device and reconnect fresh
   
---

## Disclaimer

**FOR EDUCATIONAL AND AUTHORIZED TESTING PURPOSES ONLY**

These payloads are provided for security research, penetration testing, and educational purposes. Users are solely responsible for ensuring compliance with all applicable laws and regulations. Unauthorized access to computer systems is illegal.

**By using these payloads, you agree to:**
- Only use on networks/systems you own or have explicit permission to test
- Comply with all local, state, and federal law
- Take full responsibility for your actions

The authors and contributors are not responsible for misuse or damage caused by these tools.

---

## Credits
- Evil Portal originally developed by newbi3 for WiFi Pineapple Mark VII
- Adapted for WiFi Pineapple Pager by PentestPlaybook

## Resources
- [WiFi Pineapple Docs](https://docs.hak5.org/)
- [OpenWrt Documentation](https://openwrt.org/docs/start)
- [Hak5 Forums](https://forums.hak5.org/)
- [nftables Wiki](https://wiki.nftables.org/)
