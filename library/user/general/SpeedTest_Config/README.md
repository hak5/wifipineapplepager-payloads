# SpeedTest_Config

**Author:** billyjbryant  
**Version:** 1.0

---

## Overview

**SpeedTest_Config** is a configuration payload for the **SpeedTest** payload. It allows you to configure two settings:

- **Loot Generation**: Toggle whether speed test results and network metadata are saved to `/root/loot/speedtest/`
- **Skip Upload Test**: Toggle whether upload speed tests are performed (only ping and download will be tested when enabled)

## What It Does

- Displays current loot generation setting (enabled/disabled)
- Displays current skip upload test setting (enabled/disabled)
- Prompts user to toggle each setting via **CONFIRMATION_DIALOG**
- Updates the configuration using **PAYLOAD_SET_CONFIG**
- Settings persist across firmware upgrades

## Requirements

- **SpeedTest** payload must be installed (configuration is stored under the `speedtest` payload name)
- No network connectivity required

## Usage

1. Copy the `SpeedTest_Config` payload folder to your Pager
2. Run **SpeedTest_Config** from the Payloads Dashboard
3. The payload will:
   - Display current loot generation status
   - Show a confirmation dialog to toggle loot generation
   - Display current skip upload test status
   - Show a confirmation dialog to toggle skip upload test
   - Update the configuration for both settings

## Configuration Options

### Loot Generation

Controls whether speed test results and network metadata are saved to `/root/loot/speedtest/`.

**When Enabled:**

- Confirmation dialog: "Loot generation is enabled. Disable loot file generation?"
- If confirmed: Disables loot generation
- If cancelled: Setting remains enabled

**When Disabled:**

- Confirmation dialog: "Loot generation is disabled. Enable loot file generation?"
- If confirmed: Enables loot generation
- If cancelled: Setting remains disabled

### Skip Upload Test

Controls whether upload speed tests are performed. When enabled, only ping and download speeds are tested.

**When Enabled:**

- Confirmation dialog: "Skip upload test is enabled. Disable skip upload test?"
- If confirmed: Disables skip upload (upload tests will run)
- If cancelled: Setting remains enabled (upload tests skipped)

**When Disabled:**

- Confirmation dialog: "Skip upload test is disabled. Enable skip upload test?"
- If confirmed: Enables skip upload (upload tests will be skipped)
- If cancelled: Setting remains disabled (upload tests will run)

## First Run Configuration

If you haven't configured loot generation yet, the **SpeedTest** payload will prompt you on first run. However, you can use this configuration payload at any time to change either setting.

## Technical Details

### Configuration Storage

- Uses **PAYLOAD_GET_CONFIG** to retrieve current settings
- Uses **PAYLOAD_SET_CONFIG** to update settings
- Payload name: `speedtest`
- Configuration keys:
  - `generate_loot`: `yes` (enabled) or `no` (disabled)
  - `skip_upload`: `yes` (enabled) or `no` (disabled)
- Values: `yes` (enabled) or `no` (disabled)

## Files

- `payload.sh`: Configuration payload script

## Notes

- Configuration persists across reboots and firmware upgrades
- Changes take effect immediately for future **SpeedTest** runs
- No network connectivity required to change settings
- This payload configures both loot generation and upload test behavior; it does not perform speed tests
- Skipping upload tests can help prevent OOM (Out-Of-Memory) issues on resource-constrained devices
