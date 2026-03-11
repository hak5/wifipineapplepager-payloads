# WiFi Pineapple Pager Payloads




![634414950_957256730300717_1882452366422533752_n](https://github.com/user-attachments/assets/4d77f8fa-a037-4301-9d52-e8b96f71160e)


Collection of payloads for the [WiFi Pineapple Pager](https://shop.hak5.org/products/pager) by Hak5.

## Overview

This repository contains custom payloads for automatically and manually cracking WPA/WPA2 handshakes directly on the WiFi Pineapple Pager, plus tools for managing wordlists.

## Payloads

### Alert Payloads

#### Auto Handshake Cracker
**Path:** `library/alerts/handshake_captured/auto_crack/`

Automatically attempts to crack WPA handshakes using aircrack-ng immediately when captured.

**Features:**
- Runs automatically on handshake capture
- Configurable timeout to prevent resource exhaustion
- Logs all successful cracks with timestamps
- Vibration and alert notifications on success

[View Documentation →](library/alerts/handshake_captured/auto_crack/README.md)

---

### User Payloads

#### Interactive Handshake Cracker
**Path:** `library/user/exfiltration/handshake_cracker/`

Manual payload for cracking handshakes with full control and detailed feedback.

**Features:**
- Interactive handshake selection
- Progress tracking with spinner
- Success notifications (visual, audio, haptic)
- Persistent results log

[View Documentation →](library/user/exfiltration/handshake_cracker/README.md)

#### Wordlist Manager
**Path:** `library/user/general/wordlist_manager/`

Utility for downloading and managing password wordlists.

**Features:**
- Auto-download common wordlists from public repos
- Wordlist statistics and organization
- Internet connectivity verification

[View Documentation →](library/user/general/wordlist_manager/README.md)

---

## Quick Start

### 1. Install Dependencies

SSH into your Pager and install required tools:

```bash
opkg update
opkg install aircrack-ng
```

### 2. Clone Repository

```bash
cd /root
git clone https://github.com/sinXne0/pineapple-pager-payloads.git
```

### 3. Install Payloads

```bash
# Copy alert payloads
cp -r pineapple-pager-payloads/library/alerts/handshake_captured/auto_crack /root/payloads/alerts/handshake_captured/

# Copy user payloads
cp -r pineapple-pager-payloads/library/user/exfiltration/handshake_cracker /root/payloads/user/exfiltration/
cp -r pineapple-pager-payloads/library/user/general/wordlist_manager /root/payloads/user/general/

# Make executable
chmod +x /root/payloads/alerts/handshake_captured/auto_crack/payload.sh
chmod +x /root/payloads/user/exfiltration/handshake_cracker/payload.sh
chmod +x /root/payloads/user/general/wordlist_manager/payload.sh
```

### 4. Download Wordlists

Run the Wordlist Manager from your Pager dashboard or manually upload:

```bash
scp rockyou.txt root@172.16.42.1:/root/wordlists/
```

### 5. Start Cracking!

Enable the Auto Handshake Cracker alert or run the Interactive Cracker manually from the dashboard.

---

## Usage

### Automatic Background Cracking

1. Enable "Auto Handshake Cracker" alert payload in Pager settings
2. Configure with small wordlist (1k-10k passwords recommended)
3. Start wireless recon
4. Payloads automatically crack each captured handshake
5. Check `/root/crack_results.log` for passwords

### Manual Interactive Cracking

1. Capture handshakes via recon
2. Run "Interactive Handshake Cracker" from dashboard
3. Follow on-screen prompts
4. Receive instant notification when cracked
5. View results in `/root/cracked_passwords.txt`

---

## Performance Guide

| Wordlist Size | Crack Time | Recommended Use |
|---------------|------------|-----------------|
| 1,000 passwords | 1-2 minutes | Auto-cracker, quick testing |
| 10,000 passwords | 5-15 minutes | Auto-cracker, common passwords |
| 100,000 passwords | 30-90 minutes | Manual cracking only |
| 1,000,000+ passwords | Hours-Days | **Not recommended** - use offline |

**Tip:** The Pager has limited CPU power. For large wordlists, export handshakes and use hashcat on a laptop/desktop with GPU acceleration.

---

## Directory Structure

```
library/
├── alerts/
│   └── handshake_captured/
│       └── auto_crack/
│           ├── payload.sh
│           └── README.md
└── user/
    ├── exfiltration/
    │   └── handshake_cracker/
    │       ├── payload.sh
    │       └── README.md
    └── general/
        └── wordlist_manager/
            ├── payload.sh
            └── README.md
```

---

## Requirements

- WiFi Pineapple Pager (firmware 1.0.0+)
- `aircrack-ng` (install via `opkg install aircrack-ng`)
- At least one wordlist file
- Internet connectivity for Wordlist Manager

---

## Configuration

Each payload includes configuration variables at the top of `payload.sh`:

### Auto Handshake Cracker
```bash
WORDLIST="/root/wordlists/rockyou.txt"      # Path to wordlist
MAX_CRACK_TIME=300                          # Timeout in seconds
ENABLE_LOGGING=true                         # Log results
VIBRATE_ON_SUCCESS=true                     # Vibrate on success
```

### Interactive Handshake Cracker
```bash
WORDLIST_DIR="/root/wordlists"
DEFAULT_WORDLIST="$WORDLIST_DIR/rockyou.txt"
HANDSHAKE_DIR="/root/loot/handshakes"
RESULTS_FILE="/root/cracked_passwords.txt"
```

---

## Troubleshooting

### "aircrack-ng: command not found"
```bash
opkg update
opkg install aircrack-ng
```

### "Wordlist not found"
Run the Wordlist Manager payload or manually upload:
```bash
scp wordlist.txt root@172.16.42.1:/root/wordlists/
```

### "No handshakes found"
- Verify handshakes are in `/root/loot/handshakes/`
- Check file format (must be `.pcap` or `.cap`)
- Ensure handshakes are complete and valid

### Battery draining fast
- Use smaller wordlists
- Reduce `MAX_CRACK_TIME` for auto-cracker
- Connect USB-C power during long crack sessions

---

## Wordlist Recommendations

### Recommended for Pager
- **common-passwords.txt** (1k) - Quick wins
- **rockyou-top10k.txt** (10k) - Best balance
- **wifi-defaults.txt** - Router default passwords

### Sources
- [SecLists](https://github.com/danielmiessler/SecLists)
- [Weakpass](https://weakpass.com/)
- Custom targeted wordlists

---

## Security & Legal Notice

⚠️ **IMPORTANT**: These payloads are designed for **authorized security testing only**.

### Legal Use Cases
✅ Testing your own networks
✅ Authorized penetration testing with written permission
✅ Educational/research in controlled environments
✅ Security assessments with client authorization

### Illegal Use Cases
❌ Testing networks without permission
❌ Accessing neighbor's WiFi
❌ Public WiFi cracking
❌ Any unauthorized network access

**Unauthorized access to computer networks is illegal and punishable by law.**

---

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Follow the [Hak5 payload standards](https://github.com/hak5/wifipineapplepager-payloads)
4. Test thoroughly on actual hardware
5. Submit a pull request

### Contribution Ideas
- Add GPU offload support
- Implement John the Ripper integration
- Add custom rule-based cracking
- Improve handshake selection UI
- Add hashcat integration

---

## Changelog

### Version 1.0 (2026-02-11)
- Initial release
- Auto Handshake Cracker (alert payload)
- Interactive Handshake Cracker (user payload)
- Wordlist Manager (user payload)
- Complete documentation

---

## Credits

- **Author**: [sinX](https://github.com/sinXne0)
- **Platform**: WiFi Pineapple Pager by [Hak5](https://hak5.org)
- **Cracking Engine**: [aircrack-ng](https://www.aircrack-ng.org/)
- **Wordlists**: [SecLists](https://github.com/danielmiessler/SecLists), Weakpass, Community

---

## License

These payloads are provided as-is for authorized security testing purposes only.

Use at your own risk. Author is not responsible for misuse or illegal activities.

---

## Support

- **Issues**: [GitHub Issues](https://github.com/sinXne0/pineapple-pager-payloads/issues)
- **Documentation**: See individual payload README files
- **Hak5 Forums**: [forums.hak5.org](https://forums.hak5.org)

---

**Made with ❤️ for the Hak5 community**
