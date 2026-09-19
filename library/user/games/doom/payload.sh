#!/bin/bash
# Title: DOOM
# Description: The classic 1993 FPS, optimized for Pager
# Author: @lmacken
# Version: 6.0
# Category: Games

PAYLOAD_DIR="/root/payloads/user/games/doom"

cd "$PAYLOAD_DIR" || {
    LOG red "ERROR: $PAYLOAD_DIR not found"
    exit 1
}

# Verify binary exists
[ ! -f "./doomgeneric" ] && {
    LOG red "ERROR: doomgeneric not found"
    exit 1
}
chmod +x ./doomgeneric

# Find any WAD file
WAD_FILE=$(ls "$PAYLOAD_DIR"/*.wad 2>/dev/null | head -1)
[ -z "$WAD_FILE" ] && {
    LOG red "ERROR: No .wad file found"
    exit 1
}

# Display controls (single LOG for faster rendering)
LOG "DOOM

D-pad=Move  Red=Fire  Power=Weapon
Green+Up=Use  Green+L/R=Strafe
Green+Pwr=Save  Red+Pwr=Load
Red+Green=Menu

Press any button to start..."
WAIT_FOR_INPUT >/dev/null 2>&1

# Show spinner while loading
SPINNER_ID=$(START_SPINNER "Loading DOOM...")

# Stop services to free CPU/memory
/etc/init.d/php8-fpm stop 2>/dev/null
/etc/init.d/nginx stop 2>/dev/null
/etc/init.d/bluetoothd stop 2>/dev/null
/etc/init.d/pineapplepager stop 2>/dev/null
/etc/init.d/pineapd stop 2>/dev/null

# Stop spinner before taking over framebuffer
STOP_SPINNER "$SPINNER_ID" 2>/dev/null
sleep 0.5

# Run DOOM
./doomgeneric -iwad "$WAD_FILE" >/tmp/doom.log 2>&1

# Restore services
/etc/init.d/php8-fpm start 2>/dev/null &
/etc/init.d/nginx start 2>/dev/null &
/etc/init.d/bluetoothd start 2>/dev/null &
/etc/init.d/pineapplepager start 2>/dev/null &
/etc/init.d/pineapd start 2>/dev/null &

LOG "DOOM exited. Press any button..."
WAIT_FOR_INPUT >/dev/null 2>&1
