#!/bin/bash
# Title: Display Image on WiFi Pager  
# Description: Display RGB565 image
# Author: Pixel Addict

FB_DEV="/dev/fb0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_PATH="$SCRIPT_DIR/image.raw"

# Disable console
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null

# Cleanup on exit
trap "echo 1 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null; exit" INT TERM

# Display and keep refreshing
while true; do
    cat "$IMAGE_PATH" > "$FB_DEV"
    sleep 0.5
done
