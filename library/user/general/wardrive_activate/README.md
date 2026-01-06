# Wardrive Activate

Manually enables wardrive mode on the WiFi Pineapple Pager.

## Overview
This payload is a one-click way to get GPS configured and Wigle logging started
so you can begin wardriving faster. It detects GPS devices on the WiFi Pineapple
Pager, configures the GPS device, restarts `gpsd`, and starts Wigle logging. It
also stores the GPS baud rate for reuse on future runs.

## Requirements
- Hak5 WiFi Pineapple Pager
- USB GPS receiver (ttyACM* or ttyUSB*)

## Installation
1) Copy the `wardrive_activate` folder to `/root/payloads/user/general/`.

## Usage
1) Run the payload from the Pager UI.
2) Select a GPS device if prompted.

To update the saved baud rate, run:
`wardrive_activate/payload.sh --set-baud`

On first run, the payload prompts for a GPS baud rate. 9600 is the most common
default for USB GPS devices.

## Configuration
- The GPS device is configured with `GPS_CONFIGURE` using a saved baud rate.
- Baud is stored with `PAYLOAD_SET_CONFIG` and can be changed on demand.
- `gpsd` is restarted after configuration.

## What It Does
- Detects GPS devices under `/dev/ttyACM*` and `/dev/ttyUSB*`
- Prompts for device selection when multiple devices are present
- Configures the GPS device via `GPS_CONFIGURE`
- Restarts `gpsd` to apply the configuration
- Prompts for baud on first run and persists it for later runs
- Starts Wigle logging

## Uninstall
- Delete `/root/payloads/wardrive_activate/`.

## Troubleshooting
- If no GPS devices are detected, confirm the GPS is plugged in after boot.
- If no location data appears, allow extra time for GPS lock.

## Changelog
- 1.0: Initial manual wardrive payload
