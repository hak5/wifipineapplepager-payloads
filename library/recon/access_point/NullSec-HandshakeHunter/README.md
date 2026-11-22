# NullSec HandshakeHunter

Automated WPA/WPA2 handshake capture with deauthentication.

## Description

Scans for WPA/WPA2 networks, automatically targets the strongest signal, and captures handshakes using deauthentication bursts. Saves captures for offline cracking.

## Requirements

**aircrack-ng suite** must be installed on your Pineapple Pager:

```bash
opkg update
opkg install aircrack-ng
```

## Features

- Auto-scan for WPA/WPA2 networks
- Automated target selection
- Deauth bursts to capture handshake
- Saves to `/mmc/nullsec/handshakes/`

## Output

- Captured `.cap` files ready for cracking with hashcat/aircrack-ng
- Named with SSID and timestamp for easy identification

## Author

**bad-antics** - [GitHub](https://github.com/bad-antics)

Part of the [NullSec Pineapple Suite](https://github.com/bad-antics/nullsec-pineapple-suite)

---
*For authorized security testing and educational purposes only.*
