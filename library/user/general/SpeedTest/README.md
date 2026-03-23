# SpeedTest

**Author:** billyjbryant  
**Version:** 1.0

---

## Overview

**SpeedTest** is a WiFi Pineapple Pager payload that performs internet speed tests using speedtest.net servers. It measures ping, download, and upload speeds while collecting comprehensive network intelligence. Results are displayed via **ALERT** with geolocation information, and optionally saved to loot files.

## Features

### 🚀 Speed Testing

- Measures ping latency (ms)
- Tests download speed (Mbit/s)
- Tests upload speed (Mbit/s) - can be disabled via configuration
- Uses speedtest.net servers via `speedtest-cli`
- Memory-optimized with `--no-pre-allocate` flag to prevent OOM kills on resource-constrained devices
- Upload test can be permanently disabled via **SpeedTest_Config** to prevent OOM issues

### 📊 Network Intelligence

- **SSID**: Captures the connected WiFi network name
- **Local IP**: Detects valid network IP (excludes loopback and management network)
- **Public IP**: Retrieves public IP address via ip-api.com
- **Geolocation**: Extracts city, country, and coordinates from IP geolocation
- **ISP Information**: Captures Internet Service Provider details

### 💾 Optional Loot Generation

- User-configurable loot file generation (prompted on first run)
- Saves comprehensive test results and network metadata to `/root/loot/speedtest/`
- Files include timestamp, speed test results, and all network intelligence
- Setting persists across firmware upgrades using **CONFIG**

## Requirements

- WiFi Pineapple Pager
- Client mode enabled and connected to a network with a valid internet connection

## Installation

1. Copy the `SpeedTest` & `SpeedTest_Config` payload folders to your Pager's `/root/payloads/user/general` directory
2. The payload automatically downloads `speedtest-cli` on first run if not present
3. No additional dependencies required (single-file Python script installation)

## Usage

1. Ensure the Pager is connected to a network via client mode
2. Run the **SpeedTest** payload from the Payloads Dashboard
3. On first run, you'll be prompted to enable/disable loot file generation
4. The payload will:
   - Validate network connectivity
   - Check for `speedtest-cli` and install if needed
   - Collect network information (SSID, IPs, geolocation)
   - Run the speed test with progress indicators
   - Display results in an **ALERT** dialog
   - Optionally save results to `/root/loot/speedtest/` if enabled

## Configuration

Settings can be configured using the **SpeedTest_Config** payload:

- Run **SpeedTest_Config** from the Payloads Dashboard
- Toggle loot generation on or off
- Toggle skip upload test on or off (when enabled, only ping and download are tested)
- Settings persist across reboots and firmware upgrades

Alternatively, the first run of **SpeedTest** will prompt you to configure this setting.

## Output Format

### On-Screen Display

- Real-time progress via spinner during test execution
- **ALERT** dialog with formatted results:

  ```txt
  Speed Test Results
  (speedtest.net)
  
  Location: [City, Country] or [Coordinates]
  
  Ping: [X] ms
  Download: [X] Mbit/s
  Upload: [X] Mbit/s
  ```

### Loot Files (if enabled)

Saved to `/root/loot/speedtest/YYYYMMDD_HHMMSS_speedtest.txt`:

- Timestamp
- Speed test results (ping, download, upload)
- SSID
- Local IP address
- Public IP address
- Geolocation (city, country, coordinates)
- ISP information

## Technical Details

### Memory Optimization

- Uses `--no-pre-allocate` flag with `speedtest-cli` to prevent Out-Of-Memory (OOM) kills
- Handles process termination gracefully with fallback to download-only test if upload tests fail

### Network Detection

- Validates IP addresses, excluding:
  - Loopback (127.0.0.1)
  - Pineapple management network (172.16.52.0/24)

### Error Handling

- Network connectivity validation before test execution
- Python and `speedtest-cli` availability checks
- Graceful handling of OOM kills and process termination
- **ERROR_DIALOG** for critical failures requiring user attention

## Notes

- Speed tests require active internet connectivity
- Test duration varies based on network speed (typically 30-60 seconds)
- Upload test may be skipped automatically if memory constraints are detected
- Loot files are only generated if the user has enabled this feature
- Configuration persists across firmware upgrades via the **Payload Config**
