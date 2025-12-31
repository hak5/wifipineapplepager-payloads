# WiFi Pineapple Pager Payloads
A collection of automated DuckyScript payloads for the WiFi Pineapple Pager (OpenWrt 24.10.1).

## 📋 Overview
This repository contains ready-to-use payloads designed specifically for the WiFi Pineapple Pager. Each payload automates complex configurations and installations that would otherwise require extensive manual setup.

## ⚙️ Requirements
- WiFi Pineapple Pager (OpenWrt 24.10.1)
- Active internet connection (for package downloads)
- Root access via SSH

---

## 📥 Installation

### Method 1: Clone and Transfer (Recommended)
````bash
# Clone the Repository
git clone https://github.com/PentestPlaybook/pager-payloads.git

# Transfer the Repository to the Pager
scp -r pager-payloads/evil_portal pager-payloads/pine_ap root@172.16.52.1:/root/payloads/user/
````

### Method 2: Manual Installation
````bash
# Replace <category> and <payload_name> with actual values
ssh root@172.16.52.1
mkdir -p /root/payloads/user/<category>/<payload_name>
vim /root/payloads/user/<category>/<payload_name>/payload.sh
````

---

## 🚀 Getting Started with Evil Portal

### Installation Order
The Evil Portal payloads must be run in a specific order:

1. **Install Evil Portal** - Run first to install the Evil Portal service
2. **WordPress Portal** - Activate your preferred portal theme

### Available Payloads

| Payload | Description |
|---------|-------------|
| `install_evil_portal` | Installs Evil Portal service and dependencies |
| `enable_evil_portal` | Enables Evil Portal to start on boot |
| `disable_evil_portal` | Disables Evil Portal from starting on boot |
| `start_evil_portal` | Starts the Evil Portal service |
| `stop_evil_portal` | Stops the Evil Portal service |
| `restart_evil_portal` | Restarts the Evil Portal service |
| `default_portal` | Activates the default captive portal theme |
| `wordpress_portal` | Activates the WordPress login captive portal theme |

---

## 🎯 Quick Reference

### Simulate Captive Portal Authorization
````bash
# Get your client's private IP
cat /tmp/dhcp.leases

# Add your client's private IP to the evil portal allow list
echo "x.x.x.x" > /tmp/EVILPORTAL_CLIENTS.txt

# Restart evil portal to clear the allow list
/etc/init.d/evilportal restart
````

### View Captured Credentials
````bash
cat /root/logs/credentials.json
````

---

## 🔧 General Troubleshooting

### Debugging Any Payload
````bash
# Run with verbose output
bash -x payload.sh 2>&1 | tee install.log

# Check system logs
logread | tail -50

# View recent errors
logread | grep -i error | tail -20
````

### Common Issues
- **"No space left on device"** - Free up storage or use external storage
- **"Package not found"** - Run `opkg update` first
- **Network errors** - Verify internet connection is active

---

## ⚠️ Disclaimer

**FOR EDUCATIONAL AND AUTHORIZED TESTING PURPOSES ONLY**

These payloads are provided for security research, penetration testing, and educational purposes. Users are solely responsible for ensuring compliance with all applicable laws and regulations. Unauthorized access to computer systems is illegal.

**By using these payloads, you agree to:**
- Only use on networks/systems you own or have explicit permission to test
- Comply with all local, state, and federal laws
- Take full responsibility for your actions

The authors and contributors are not responsible for misuse or damage caused by these tools.

---

## 🤝 Contributing

Contributions are welcome! Help grow this collection of Pager payloads.

### How to Contribute a Payload

1. **Fork the repository**
2. **Create a new directory** for your payload following the structure:
````
   <category>/<payload_name>/
````
3. **Include required files:**
   - `payload.sh` - Your executable script
   - `README.md` - Payload documentation (see template below)
4. **Test thoroughly** on a Pager
5. **Submit a pull request**

### Payload README Template
````markdown
# [Payload Name]

## Description
Brief description of what the payload does.

## Features
- Feature 1
- Feature 2

## Requirements
- List any specific requirements

## Installation
Location: `/root/payloads/user/<category>/<payload_name>/`

## Usage
```bash
bash /root/payloads/user/<category>/<payload_name>/payload.sh
```

## Post-Installation
What to do after installation

## Management Commands
- Start: `command here`
- Stop: `command here`
- Status: `command here`

## Troubleshooting
Common issues and solutions
````

### Payload Guidelines
- ✅ Use clear, descriptive variable names
- ✅ Include comprehensive error handling
- ✅ Add verification/testing steps
- ✅ Use `LOG` for status messages
- ✅ Document all prerequisites
- ✅ Test on fresh Pager installation
- ✅ Include cleanup/uninstall steps if applicable
- ✅ Follow the directory structure: `<category>/<payload_name>/payload.sh`

---

## 📝 License

MIT License - See LICENSE file for details

---

## 🎄 Credits

**Repository Maintainer:** PentestPlaybook

**Payload Contributors:**
- Evil Portal: Adapted from WiFi Pineapple Mark VII module

---

## 📚 Resources

- [WiFi Pineapple Docs](https://docs.hak5.org/)
- [OpenWrt Documentation](https://openwrt.org/docs/start)
- [Hak5 Forums](https://forums.hak5.org/)
- [nftables Wiki](https://wiki.nftables.org/)

---

## 🔗 Related Projects

- [WiFi Pineapple Mark VII Modules](https://github.com/hak5/mk7-modules)
- [Hak5 Cloud C2](https://shop.hak5.org/products/c2)

---

**Made with ❤️ for the Pineapple community**

*Last Updated: December 31, 2025*

