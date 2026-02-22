# LED's Timeout

## Overview

Automatically disables the LED when the screen dims or turns off to save battery. The LED turns back on when the screen wakes up.

## Features

- **Battery Saver**: LED turns off when screen is dimmed/off
- **Auto-restore**: LED turns back on when screen wakes
- **Persistent Service**: Runs as a procd service, survives reboots
- **Smart Detection**: Reads `dim_brightness` and `led_color` from UCI config

## Installation

Run the payload and confirm "Install LED's Timeout service?"

The service will:

1. Create `/etc/init.d/leds_timeout`
2. Create `/usr/bin/LEDS_TIMEOUT`
3. Enable and start the service

## Usage

Running the payload again shows status-aware options:

| Status | Options |
|--------|---------|
| Running | Uninstall |
| Stopped | Start or Uninstall |
| Not Installed | Install |

## Configuration

The service reads settings from UCI:

- `system.@pager[0].led_color` - LED color (default: cyan)
- `system.@pager[0].dim_brightness` - Threshold to detect dim (default: 6)

## Uninstall

Run the payload when service is running/stopped and select Uninstall.

This removes:

- `/etc/init.d/leds_timeout`
- `/usr/bin/LEDS_TIMEOUT`
- Restores LED to default color

## Credits

- **Z3r0L1nk**
