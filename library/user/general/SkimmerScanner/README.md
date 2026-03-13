# Skimmer Scanner

**Skimmer Scanner** is a security tool for the WiFi Pineapple Pager that continuously monitors for suspicious Bluetooth devices commonly used in credit card skimmers. It provides real-time alerts when potentially malicious devices are detected nearby.

---

## Overview

Credit card skimmers often use cheap Bluetooth modules (like HC-05, HC-06, BT04) to wirelessly transmit stolen card data. This payload scans for these devices and alerts you when suspicious Bluetooth signatures are detected, helping you identify potential skimmers at ATMs, gas pumps, and payment terminals.

---

## Features

* **Continuous Monitoring:** Scans for both Classic Bluetooth and BLE devices in real-time
* **Multi-Factor Detection:** Identifies skimmers based on:
  - Device names (HC-05, BT04, JDY modules, etc.)
  - Vendor/Manufacturer patterns (cheap Chinese modules)
  - Unnamed or suspicious devices
  - Random MAC addresses
  - Custom signature database
* **Risk Assessment:** Calculates risk level (LOW/MEDIUM/HIGH) based on multiple indicators
* **Visual & Haptic Alerts:**
  - **HIGH RISK:** Red LED + 3 vibration pulses
  - **MEDIUM RISK:** Orange LED + 1 vibration pulse
  - **LOW RISK:** Yellow LED + 1 vibration pulse
* **Detailed Logging:** Records all detections with timestamps and reasoning
* **Customizable Signatures:** User-editable signature database for new patterns

---

## How It Works

### Detection Logic

The scanner evaluates each discovered Bluetooth device against multiple criteria:

1. **Signature Matching:** Checks against known skimmer patterns in `skimmer_signatures.txt` (+2 points per match)
2. **Name Analysis:** Identifies common skimmer module names (HC-05, BT04, JDY-XX, etc.) (+3 points)
3. **Vendor Lookup:** Uses OUI database to identify suspicious manufacturers (+2 points)
4. **Unnamed Devices:** Devices with non-random MACs broadcasting without names (+2 points)

**Note on BLE Privacy:** Modern devices (iPhones, Android phones, smartwatches) use random MAC addresses for privacy. These are NOT flagged as suspicious since they're a legitimate privacy feature.

Each match increases the risk score. When the score reaches 3 or higher, an alert is triggered.

### Risk Levels

- **HIGH (≥5 points):** Very likely a skimmer - multiple strong indicators (e.g., "HC-05" name + suspicious vendor)
- **MEDIUM (3-4 points):** Suspicious device - investigate further (e.g., known skimmer name OR signature match)
- Devices with <3 points are not alerted to reduce false positives from legitimate BLE devices

---

## Usage

### Interactive Mode (`payload.sh`)

1. Navigate to the payload on your Pineapple Pager
2. Launch **Skimmer Scanner**
3. Press **OK** at the startup prompt
4. The device will continuously scan and alert on suspicious devices
5. Check ATMs, gas pumps, or payment terminals when alerted
6. Press the button to stop scanning

### When You Get an Alert

1. **Note the location** - this is likely where a skimmer is installed
2. **Check the risk level** displayed on screen
3. **Visually inspect** the payment terminal for physical tampering
4. **Report to authorities** if a skimmer is confirmed
5. **Review the log file** for detailed information

---

## Configuration

### Custom Signatures

Edit `skimmer_signatures.txt` in the payload directory to add your own patterns:

```bash
# Add MAC prefix of a known skimmer
00:11:22

# Add specific device name
MySkimmerDevice

# Add vendor pattern
SuspiciousVendorCo
```

Patterns are matched case-insensitively against:
- Device MAC address
- Device name
- Vendor/Manufacturer

### Log File Location

Detections are logged to:
```
/root/payloads/user/general/skimmer_scanner/skimmer_detections.log
```

### Log Format

```
[2026-01-12 15:30:45] HIGH RISK - MAC: 00:14:03:XX:XX:XX | Name: HC-05 | Vendor: Unknown
  Reasons: Known skimmer module name; No device name or MAC as name; Suspicious vendor (common in DIY modules);
```

---

## Common Skimmer Devices

This payload detects the following commonly-used skimmer hardware:

### Bluetooth Serial Modules
- **HC-05 / HC-06** - Most common in DIY skimmers
- **BT04 / BT05** - Similar to HC series
- **JDY-08 / JDY-09 / JDY-10** - Newer Chinese modules
- **JDY-16 / JDY-17** - BLE versions
- **MLT-BT** - Industrial Bluetooth module
- **SPP-C** - Serial Port Profile module
- **linvor** - Generic Bluetooth serial adapter

### Characteristics
- Usually have generic or no device names
- Often show "Unknown" or Chinese manufacturer in OUI lookup
- Typically use BLE (Bluetooth Low Energy) for battery efficiency
- May use random MAC addresses to avoid detection

---

## Real-World Usage Tips

### Best Practices

1. **Scan Before Using ATMs/Pumps:** Run a quick scan before inserting your card
2. **Check Gas Stations:** Pump skimmers are extremely common
3. **Monitor Public Areas:** Airports, tourist spots, and high-traffic areas
4. **Physical Inspection:** Always combine scanning with visual inspection
5. **Update Signatures:** Add new patterns as skimmer technology evolves

### False Positives

The scanner has been tuned to minimize false positives from legitimate devices but it is still being field tested:

- **Random MAC addresses** (iPhones, Android phones, smartwatches) are NOT flagged - these use BLE privacy features
- **Unnamed random MAC devices** are ignored - this is normal BLE privacy behavior
- **"Unknown" vendors** on random MACs are expected and not flagged

Devices that MAY still trigger alerts:
- **DIY Bluetooth projects** using HC-05/BT modules (these are also used in skimmers)
- **Industrial sensors** with suspicious vendor names
- **Older Bluetooth devices** without proper names

**Use context!** A Bluetooth device detected AT a card reader is much more suspicious than one in a parking lot.

---

## Technical Details

### Scanning Methods

The payload uses two scanning techniques simultaneously:

1. **BLE Scanning:** `hcitool lescan` for low-energy devices (most modern skimmers)
2. **Classic Bluetooth:** `hcitool scan` for older skimmer hardware

### Scan Cycle

- **Adapter Reset:** Every scan cycle to prevent hangs
- **Scan Duration:** 8 seconds BLE + 5 seconds Classic
- **Cooldown:** 3 seconds between cycles
- **Re-check Interval:** 5 minutes per device (prevents alert spam)

### Dependencies

Required tools (pre-installed on Pineapple Pager):
- `hciconfig` - Bluetooth adapter control
- `hcitool` - Bluetooth scanning
- `bluetoothctl` - BLE device info
- OUI database at `/lib/hak5/oui.txt`

---

## Troubleshooting

### No Devices Detected

- Ensure Bluetooth is enabled: `hciconfig hci0 up`
- Check if Bluetooth adapter exists: `hciconfig`
- Verify no other BT processes are running: `killall bluetoothctl hcitool`

### Too Many False Positives

- Edit `skimmer_signatures.txt` to remove overly broad patterns
- Increase minimum risk threshold in payload (line 150)
- Add known-good devices to an ignore list (custom modification)

### Scanner Stops or Hangs

- The payload automatically resets the adapter each cycle
- Kill and restart if needed: kill the payload process and relaunch

---

## Contributing

Found a new skimmer signature? Contribute to the signature database!

1. Document the device details (MAC, name, vendor)
2. Add the pattern to `skimmer_signatures.txt`
3. Test detection accuracy
4. Submit via pull request

---

## Legal & Ethical Notice

This tool is designed for:
- **Personal security awareness**
- **Authorized security testing**
- **Helping identify and report skimmers to authorities**

**DO NOT:**
- Interfere with payment systems
- Access or modify skimmer devices
- Use this for any illegal activity

Always report suspected skimmers to:
- Local law enforcement
- The business/property owner
- Payment card companies (Visa, Mastercard, etc.)

---

## Credits

- **Author:** Gekitsuu
- **Based on:** blue_clues (Bluetooth reconnaissance) & BT_Pager_Warden (monitoring)
- **Platform:** WiFi Pineapple Pager
- **License:** Same as parent repository

---

## Version History

- **v1.0** - Initial release with multi-factor detection and risk assessment
