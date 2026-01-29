#!/bin/bash
# Title: Tetris
# Description: Tetris with mode selector (Portrait L/R, Landscape)
# Author: brainphreak
# Version: 1.0
# Category: Games

PAYLOAD_DIR="/root/payloads/user/games/tetris"

cd "$PAYLOAD_DIR" || {
    LOG red "ERROR: $PAYLOAD_DIR not found"
    exit 1
}

# Verify binary exists
[ ! -f "./tetris_launcher" ] && {
    LOG red "ERROR: tetris_launcher binary not found"
    exit 1
}
chmod +x ./tetris_launcher ./tetris_portrait_l ./tetris_portrait_r ./tetris_landscape 2>/dev/null

# Display game info
LOG ""
LOG "=== TETRIS ==="
LOG ""
LOG "The classic block-stacking puzzle game!"
LOG ""
LOG "Hold pager sideways to play:"
LOG "  LEFT  - Left-handed controls"
LOG "  RIGHT - Right-handed controls"
LOG ""
LOG "Press any button to continue..."
WAIT_FOR_INPUT >/dev/null 2>&1

# Show spinner while loading
SPINNER_ID=$(START_SPINNER "Loading Tetris...")

# Stop services to free CPU/memory and avoid framebuffer conflicts
/etc/init.d/php8-fpm stop 2>/dev/null
/etc/init.d/nginx stop 2>/dev/null
/etc/init.d/bluetoothd stop 2>/dev/null
/etc/init.d/pineapplepager stop 2>/dev/null
/etc/init.d/pineapd stop 2>/dev/null

# Stop spinner before taking over framebuffer
STOP_SPINNER "$SPINNER_ID" 2>/dev/null
sleep 0.5

# Run the launcher (it will exec the selected game)
./tetris_launcher >/tmp/tetris.log 2>&1

# Restore services
/etc/init.d/php8-fpm start 2>/dev/null &
/etc/init.d/nginx start 2>/dev/null &
/etc/init.d/bluetoothd start 2>/dev/null &
/etc/init.d/pineapplepager start 2>/dev/null &
/etc/init.d/pineapd start 2>/dev/null &

# Payload complete - pager interface will reload
