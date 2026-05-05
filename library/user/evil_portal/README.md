# Evil Portal

## Description
A complete Evil Portal implementation for the WiFi Pineapple Pager, including captive portal detection and credential capture.

## Author
PentestPlaybook

## Payloads

| Payload | Description |
|---------|-------------|
| `install_evil_portal` | Installs Evil Portal service and dependencies |
| `set_evil_portal_interface` | Sets the network interface Evil Portal applies to |
| `interface_manager` | Displays interface status and manages interface activation |
| `enable_evil_portal` | Enables Evil Portal to start on boot |
| `disable_evil_portal` | Disables Evil Portal from starting on boot |
| `start_evil_portal` | Starts the Evil Portal service |
| `stop_evil_portal` | Stops the Evil Portal service |
| `restart_evil_portal` | Restarts the Evil Portal service |
| `switch_evil_portal` | Switches active captive portal at runtime |
| `default_portal` | Activates the default captive portal theme |

## Requirements
- WiFi Pineapple Pager (OpenWrt 24.10.1)
- Active internet connection (for initial package installation)

## Installation Order
1. Run `install_evil_portal` to install Evil Portal service and dependencies
2. Run `set_evil_portal_interface` to configure which interface Evil Portal applies to
3. Run `interface_manager` to confirm interface status and resolve any connectivity issues
4. Run `switch_evil_portal` and select your desired portal to activate it

Evil Portal is automatically enabled and started during installation.

### Triggering the Captive Portal
After connecting to the target network, the captive portal should appear automatically. If it doesn't:
1. Go to WiFi settings and tap "Sign in to network" or "Sign In"
2. On Android, tap the WiFi network name to see the sign-in option
3. Open any browser and navigate to a non-HTTPS site (e.g., `http://example.com`)

### Reverting to Default Portal
To switch back to the default portal, run `default_portal`.

## Interface Configuration

By default, Evil Portal applies to all interfaces on the management network (172.16.52.0/24). Use `set_evil_portal_interface` to configure which interface Evil Portal applies to:

- **Evil WPA (wlan0wpa)** — Captive portal only appears on the Evil WPA network (10.0.0.0/24)
- **Open AP (wlan0open)** — Captive portal only appears on the Open AP network (10.0.0.0/24)
- **All interfaces (br-lan)** — Captive portal appears on all interfaces (172.16.52.0/24)

**Recommended:** Configure Evil Portal to apply to a single interface to avoid affecting clients on the management network.

## Features
- Automatic captive portal detection for iOS and Android devices
- Credential capture to `/root/logs/credentials.json`
- Client authorization management via nftables
- Runtime portal switching without service restart
- Interface status monitoring and activation management

## Quick Reference

### Simulate Captive Portal Authorization
```bash
# Get your client's private IP
cat /tmp/dhcp.leases

# Simulate captive portal authentication for your client's private IP
echo "x.x.x.x" >> /tmp/EVILPORTAL_CLIENTS.txt

# Verify client was added to the firewall allow list
nft list chain inet fw4 dstnat | grep saddr

# Restart evilportal to clear the allow list
/etc/init.d/evilportal restart
```
> **Note:** After successful authentication, reconnect to the access point to restore internet access.

### View Captured Credentials
```bash
cat /root/logs/credentials.json
```

## Troubleshooting

### No internet connectivity after connecting to access point and pager cannot ping a domain
- Ensure that all 3 access points are not enabled simultaneously
- Verify your WiFi Client Mode configuration is correct

### No internet connectivity after connecting to access point and pager can ping a domain
- Verify your PineAP filters are set to **DENY**
- If filters are set to **ALLOW**, ensure connecting device has been added to the allow list

### Not able to connect to an access point
- Verify the AP you are trying to connect to is currently enabled on the Pager
- Use the `interface_manager` payload to confirm which interfaces are currently up

### Portal Not Loading After Activation
If a newly activated portal doesn't appear on your device:
1. Connect to `172.16.52.1` on your PC browser to confirm the correct portal is loaded
2. Disconnect and reconnect your test device from the WiFi network
3. Wait longer - some devices cache the previous portal and take time to refresh
4. Try "Forget Network" on your device and reconnect fresh

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
- **"No space left on device"** — Free up storage or use external storage
- **"Package not found"** — Run `opkg update` first
- **Network errors** — Verify internet connection is active

---

## Disclaimer

**FOR EDUCATIONAL AND AUTHORIZED TESTING PURPOSES ONLY**

These payloads are provided for security research, penetration testing, and educational purposes. Users are solely responsible for ensuring compliance with all applicable laws and regulations. Unauthorized access to computer systems is illegal.

**By using these payloads, you agree to:**
- Only use on networks/systems you own or have explicit permission to test
- Comply with all local, state, and federal laws
- Take full responsibility for your actions

The authors and contributors are not responsible for misuse or damage caused by these tools.

---

## Credits
- Evil Portal originally developed by newbi3 for WiFi Pineapple Mark VII
- Adapted for WiFi Pineapple Pager by PentestPlaybook
- Switch payload & helper concept by 0x4B

## Resources
- [WiFi Pineapple Docs](https://docs.hak5.org/)
- [OpenWrt Documentation](https://openwrt.org/docs/start)
- [Hak5 Forums](https://forums.hak5.org/)
- [nftables Wiki](https://wiki.nftables.org/)
