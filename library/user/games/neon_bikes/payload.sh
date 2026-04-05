#!/bin/bash
# Title: Neon Bikes
# Description: Light cycle arena game - race your neon trail against the CPU
# Author: wickedNull
# Version: 1.3
# Category: Games

PAYLOAD_DIR="/root/payloads/user/games/neon_bikes"
LOG_FILE="/tmp/neon_bikes.log"

cd "$PAYLOAD_DIR" || { LOG "ERROR: $PAYLOAD_DIR not found"; exit 1; }

# -- Find pagerctl -------------------------------------------------------------
PAGERCTL_FOUND=false
for dir in "$PAYLOAD_DIR/lib" \
           "/root/payloads/user/utilities/PAGERCTL" \
           "/mmc/root/payloads/user/utilities/PAGERCTL"; do
    if [ -f "$dir/libpagerctl.so" ] && [ -f "$dir/pagerctl.py" ]; then
        PAGERCTL_DIR="$dir"
        PAGERCTL_FOUND=true
        break
    fi
done

if [ "$PAGERCTL_FOUND" = false ]; then
    LOG "libpagerctl.so / pagerctl.py not found!"
    WAIT_FOR_INPUT >/dev/null 2>&1
    exit 1
fi

if [ "$PAGERCTL_DIR" != "$PAYLOAD_DIR/lib" ]; then
    mkdir -p "$PAYLOAD_DIR/lib" 2>/dev/null
    cp "$PAGERCTL_DIR/libpagerctl.so" "$PAYLOAD_DIR/lib/" 2>/dev/null
    cp "$PAGERCTL_DIR/pagerctl.py"    "$PAYLOAD_DIR/lib/" 2>/dev/null
fi

export PATH="/mmc/usr/bin:$PAYLOAD_DIR/bin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:/mmc/lib:$LD_LIBRARY_PATH"
export PYTHONPATH="$PAYLOAD_DIR/lib:$PAYLOAD_DIR:$PYTHONPATH"

PYTHON=$(command -v python3)

LOG ""
LOG "=== NEON BIKES ==="
LOG ""
LOG "D-PAD  Steer"
LOG "GREEN  Start / Restart"
LOG "RED    Quit"
LOG ""
LOG "Press any button to continue..."
WAIT_FOR_INPUT >/dev/null 2>&1

# -- Stop services -------------------------------------------------------------
SPINNER_ID=$(START_SPINNER "Loading Neon Bikes...")
/etc/init.d/php8-fpm      stop 2>/dev/null
/etc/init.d/nginx         stop 2>/dev/null
/etc/init.d/bluetoothd    stop 2>/dev/null
/etc/init.d/pineapplepager stop 2>/dev/null
sleep 0.5
STOP_SPINNER "$SPINNER_ID" 2>/dev/null

# -- Launch --------------------------------------------------------------------
"$PYTHON" "$PAYLOAD_DIR/neon_bikes.py" "$PAYLOAD_DIR/lib" > "$LOG_FILE" 2>&1
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    LOG "Game exited with code $EXIT_CODE"
    LOG "Check /tmp/neon_bikes.log for details"
fi

sleep 0.5

# -- Restore services ----------------------------------------------------------
/etc/init.d/bluetoothd    start 2>/dev/null &
/etc/init.d/nginx         start 2>/dev/null &
/etc/init.d/php8-fpm      start 2>/dev/null &
/etc/init.d/pineapplepager start 2>/dev/null &
