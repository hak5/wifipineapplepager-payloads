#!/bin/bash
# Title: DOOM
# Description: The classic 1993 FPS on your WiFi Pineapple Pager!
# Author: @lmacken
# Version: 4.0
# Category: Games

PAYLOAD_DIR="/root/payloads/user/games/doom"

cd "$PAYLOAD_DIR" || {
  LOG red "ERROR: $PAYLOAD_DIR not found"
  exit 1
}

# Verify required files exist
[ ! -f "./doomgeneric" ] && {
  LOG red "ERROR: doomgeneric not found"
  exit 1
}
chmod +x ./doomgeneric

# Find any WAD file (doom1.wad, freedoom1.wad, etc.)
WAD_FILE=$(ls "$PAYLOAD_DIR"/*.wad 2>/dev/null | head -1)
[ -z "$WAD_FILE" ] && {
  LOG red "ERROR: No .wad file found"
  exit 1
}

# Display controls help
LOG "DOOM - Single Player"
LOG ""
LOG "D-pad=Move  Red=Fire  Green=Select"
LOG "Green+Up=Use  Green+Down=Map"
LOG "Green+Left/Right=Strafe"
LOG "Red+Green=Quit"
LOG ""
LOG "Press any button to start..."
WAIT_FOR_INPUT >/dev/null 2>&1

# Stop services to free CPU and memory for DOOM
/etc/init.d/php8-fpm stop 2>/dev/null
/etc/init.d/nginx stop 2>/dev/null
/etc/init.d/bluetoothd stop 2>/dev/null
/etc/init.d/pineapplepager stop 2>/dev/null
/etc/init.d/pineapd stop 2>/dev/null

sleep 1

# Run DOOM
"$PAYLOAD_DIR/doomgeneric" -iwad "$WAD_FILE" >/tmp/doom.log 2>&1

# Restore services after DOOM exits
/etc/init.d/php8-fpm start 2>/dev/null &
/etc/init.d/nginx start 2>/dev/null &
/etc/init.d/bluetoothd start 2>/dev/null &
/etc/init.d/pineapplepager start 2>/dev/null &
/etc/init.d/pineapd start 2>/dev/null &

LOG ""
LOG "DOOM exited. Press any button..."
WAIT_FOR_INPUT >/dev/null 2>&1
