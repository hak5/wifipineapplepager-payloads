# Pine AP Configuration

## Description
Configuration payloads for PineAP on the WiFi Pineapple Pager, including filter management, wireless client mode, and Evil WPA setup.

## Author
PentestPlaybook

## Payloads

| Payload | Description |
|---------|-------------|
| `deny_filters` | Sets PineAP SSID and Client filters to deny mode |
| `wireless_client_mode` | Connects wlan0cli to an existing WiFi network for internet access |
| `evil_wpa` | Configures and enables the Evil WPA portal interface (wlan0wpa) |

## Requirements
- WiFi Pineapple Pager (OpenWrt 24.10.1)

## Payload Details

### deny_filters
Sets both SSID and Client filters to deny mode, allowing all clients and SSIDs except those explicitly listed in the filter.

⚠️ **WARNING:** Enabling deny mode allows ANY device to connect to your Pineapple. Only use this in a secure, controlled environment where you have authorization to perform testing. In an uncontrolled environment, unauthorized users could connect to your device.

### wireless_client_mode
Connects the Pineapple to an existing WiFi network for internet access:
- Custom target SSID (prompted during execution)
- Custom WPA passphrase (prompted during execution, minimum 8 characters)
- Configurable encryption type (default: sae-mixed)
- Automatic connection verification and internet connectivity check

**Note:** If `wireless_client_mode` fails on the first attempt, run it again. The second attempt typically succeeds after the initial network configuration is in place.

### evil_wpa
Configures the Evil WPA access point (wlan0wpa) with:
- SSID (prompted during execution)
- WPA2 passphrase (prompted during execution, minimum 8 characters)
- Automatic service restart and verification

## Features
- Interactive prompts using TEXT_PICKER for SSID, passphrase, and encryption type
- Input validation (empty checks, passphrase length requirements)
- Special character handling in SSIDs and passphrases
- Automatic service restarts with status verification
- Connection and internet connectivity checks

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

## Resources
- [WiFi Pineapple Docs](https://docs.hak5.org/)
- [OpenWrt Documentation](https://openwrt.org/docs/start)
- [Hak5 Forums](https://forums.hak5.org/)
