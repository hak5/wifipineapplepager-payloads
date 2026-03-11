#!/bin/bash
# Title: Hakanoid
# Description: Classic brick breaker arcade game
# Author: brAinphreAk
# Version: 1.0
# Category: Games

PAYLOAD_DIR="/root/payloads/user/games/hakanoid"

cd "$PAYLOAD_DIR" || {
    LOG red "ERROR: $PAYLOAD_DIR not found"
    exit 1
}

# Verify binary exists
[ ! -f "./hakanoid" ] && {
    LOG red "ERROR: hakanoid binary not found"
    exit 1
}
chmod +x ./hakanoid

# Display game info
LOG ""
LOG "=== HAKANOID ==="
LOG ""
LOG "Break all the bricks!"
LOG ""
LOG "Controls:"
LOG "  LEFT/RIGHT - Move paddle"
LOG "  GREEN (A)  - Launch ball"
LOG "  RED (B)    - Pause"
LOG ""
LOG "Press any button to continue..."
WAIT_FOR_INPUT >/dev/null 2>&1

# Show spinner while loading
SPINNER_ID=$(START_SPINNER "Loading Hakanoid...")

# Stop services to free CPU/memory and avoid framebuffer conflicts
/etc/init.d/php8-fpm stop 2>/dev/null
/etc/init.d/nginx stop 2>/dev/null
/etc/init.d/bluetoothd stop 2>/dev/null
/etc/init.d/pineapplepager stop 2>/dev/null
/etc/init.d/pineapd stop 2>/dev/null

# Stop spinner before taking over framebuffer
STOP_SPINNER "$SPINNER_ID" 2>/dev/null
sleep 0.5

# Run the game
./hakanoid >/tmp/hakanoid.log 2>&1

# Restore services
/etc/init.d/php8-fpm start 2>/dev/null &
/etc/init.d/nginx start 2>/dev/null &
/etc/init.d/bluetoothd start 2>/dev/null &
/etc/init.d/pineapplepager start 2>/dev/null &
/etc/init.d/pineapd start 2>/dev/null &

# Payload complete - pager interface will reload
