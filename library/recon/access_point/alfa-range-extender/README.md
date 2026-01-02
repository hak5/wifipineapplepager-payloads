# ALFA Range Extender Recon

**Author:** Aitema-GmbH
**Version:** 2.0
**Category:** recon/access_point
**Target:** WiFi Pineapple Pager

## Description

Extends WiFi reconnaissance range using an external ALFA AWUS036ACH adapter with high-gain antenna. This payload configures the adapter for monitor mode and optionally runs automated scanning with airodump-ng.

The ALFA AWUS036ACH provides significantly better range than the Pineapple's built-in radios, making it ideal for extended reconnaissance operations.

## Features

- **Auto Driver Loading**: Automatically loads RTL8812AU kernel module
- **Monitor Mode Setup**: Configures adapter for passive WiFi scanning
- **Band Selection**: Choose between 2.4 GHz (range) or 5 GHz (speed)
- **Automated Scanning**: Optional airodump-ng auto-scan with button stop
- **Manual Mode**: Prepare adapter for custom scanning
- **Loot Saving**: Scan results saved to `/root/loot/alfa-recon/`

## Hardware Requirements

### ALFA AWUS036ACH
- **Chipset**: Realtek RTL8812AU
- **Bands**: Dual-band 2.4 GHz & 5 GHz
- **Antenna**: External high-gain (included)
- **USB**: USB 3.0 (USB 2.0 compatible)

### USB-A Adapter
The Pineapple Pager has USB-C ports. You need a USB-C to USB-A adapter to connect the ALFA.

## Software Requirements

### RTL8812AU Driver

The driver must be installed before using this payload:

```bash
# SSH into Pineapple
ssh root@172.16.52.1

# Update package list
opkg update

# Install driver (try these in order)
opkg install kmod-rtl8812au-ct    # Community driver (recommended)
opkg install kmod-rtl88XXau       # Alternative
opkg install kmod-rtl8812au       # Another alternative
```

### aircrack-ng Suite (Optional)

For automated scanning:

```bash
opkg install aircrack-ng
```

## Installation

### Option 1: SCP Copy

```bash
scp -r alfa-range-extender root@172.16.52.1:/root/payloads/recon/access_point/
ssh root@172.16.52.1 "chmod 755 /root/payloads/recon/access_point/alfa-range-extender/payload.sh"
```

### Option 2: USB Drive

1. Copy `alfa-range-extender` folder to USB drive
2. Insert USB into Pineapple
3. Copy to `/root/payloads/recon/access_point/`

## Usage

### Running the Payload

1. Connect ALFA adapter via USB-A adapter
2. Navigate to: **Payloads → Recon → Access Point → ALFA Range Extender**
3. Follow the on-screen prompts

### Workflow

```
┌─────────────────┐
│  ALFA Detected  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│ Enable Monitor  │────▶│  Select Band    │
│      Mode?      │     │ 5 GHz / 2.4 GHz │
└─────────────────┘     └────────┬────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │  Auto-Scan?     │
                        └────────┬────────┘
                          │           │
                     Yes  ▼           ▼  No
              ┌─────────────────┐  ┌─────────────────┐
              │ airodump-ng     │  │ Manual Mode     │
              │ (Press B stop)  │  │ Ready message   │
              └─────────────────┘  └─────────────────┘
```

### Band Selection

| Band | Pros | Cons |
|------|------|------|
| **5 GHz** | Less interference, faster | Shorter range |
| **2.4 GHz** | Better range, more networks | More crowded |

### Stopping the Scan

When auto-scan is running, press the **B button** on the Pager to stop and save results.

## Output Files

All scan results are saved to `/root/loot/alfa-recon/`:

| File | Description |
|------|-------------|
| `scan_YYYYMMDD_HHMMSS-01.csv` | Network list (CSV format) |
| `scan_YYYYMMDD_HHMMSS-01.kismet.csv` | Kismet XML format |
| `scan_YYYYMMDD_HHMMSS-01.cap` | Packet capture (PCAP) |

### CSV Format

The CSV file contains:
- BSSID, First seen, Last seen
- Channel, Speed, Privacy (encryption)
- ESSID (network name)
- Signal strength (dBm)

## LED States

| State | Color | Meaning |
|-------|-------|---------|
| SETUP | Magenta | Ready/Idle |
| ATTACK | Yellow | Working (loading driver, scanning) |
| FINISH | Green | Success |
| FAIL | Red | Error |

## Troubleshooting

### "ALFA Adapter not found"

**Causes:**
1. USB adapter not connected
2. ALFA not plugged in
3. Driver not installed

**Solutions:**
```bash
# Check USB devices
lsusb | grep -i realtek

# Check if driver loaded
lsmod | grep 8812

# Manually load driver
modprobe 8812au
```

### "Monitor Mode failed"

**Causes:**
1. Driver doesn't support monitor mode
2. Interface busy

**Solutions:**
```bash
# Check interface status
iw dev wlan2 info

# Try manual setup
ip link set wlan2 down
iw dev wlan2 set type monitor
ip link set wlan2 up
```

### "airodump-ng not found"

**Solution:**
```bash
opkg update
opkg install aircrack-ng
```

### Wrong Interface (not wlan2)

If your ALFA appears as a different interface:

1. Check available interfaces:
   ```bash
   ls /sys/class/net/
   ```

2. Edit payload.sh and change:
   ```bash
   ADAPTER_INTERFACE="wlan3"  # or whatever your interface is
   ```

## Security & Legal Notes

- **Authorization Required**: Only scan networks you own or have explicit permission to test
- **Passive Scanning**: Monitor mode is passive but may still be detectable
- **Local Laws**: WiFi scanning legality varies by jurisdiction

## Technical Details

### Interface Configuration

```bash
# Set monitor mode
ip link set wlan2 down
iw dev wlan2 set type monitor
ip link set wlan2 up

# Set 5 GHz channel
iw dev wlan2 set freq 5180  # Channel 36

# Set 2.4 GHz channel
iw dev wlan2 set freq 2437  # Channel 6
```

### airodump-ng Options

```bash
airodump-ng wlan2 \
  --band abg \                    # All bands (a=5GHz, bg=2.4GHz)
  -w /root/loot/alfa-recon/scan \ # Output prefix
  --output-format csv,kismet,pcap # Multiple formats
```

## Changelog

### Version 2.0
- Fixed DuckyScript CONFIRMATION_DIALOG handling
- Removed buggy START_SPINNER/STOP_SPINNER (use LED states)
- Added proper cleanup trap
- Added `shopt -s nullglob`
- English comments and documentation
- Better error handling

### Version 1.0
- Initial release

## Credits

- [Hak5](https://hak5.org) - WiFi Pineapple Pager
- [ALFA Network](https://www.alfa.com.tw/) - AWUS036ACH adapter
- [aircrack-ng](https://www.aircrack-ng.org/) - WiFi security tools

## License

This payload is released under the [Hak5 License](https://github.com/hak5/wifipineapplepager-payloads/blob/master/LICENSE).
