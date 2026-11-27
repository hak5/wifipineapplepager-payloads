#!/bin/sh
# Title: GBC Emulator
# Description: Browser-based GBC emulator with pager screen mirroring
# Author: custom
# Version: 3.0
# Category: Games

PAYLOAD_DIR="/root/payloads/user/games/zelda_gbc"

cleanup() {
    if ! pgrep -x pineapple >/dev/null 2>&1; then
        /etc/init.d/pineapplepager start 2>/dev/null
    fi
}
trap cleanup EXIT

LOG "GBC Emulator"
LOG ""
LOG "Play GBC games in your browser."
LOG "The pager screen shows the game."
LOG ""
LOG "Press GREEN to start"
LOG "Press RED to cancel"

while true; do
    BUTTON=$(WAIT_FOR_INPUT 2>/dev/null)
    case "$BUTTON" in
        "GREEN"|"A") break ;;
        "RED"|"B")   exit 0 ;;
    esac
done

SPINNER_ID=$(START_SPINNER "Starting server...")
/etc/init.d/pineapplepager stop 2>/dev/null
sleep 0.5
STOP_SPINNER "$SPINNER_ID"

export PATH="/mmc/usr/bin:$PATH"
export PYTHONPATH="$PAYLOAD_DIR:$PYTHONPATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:$PAYLOAD_DIR:$LD_LIBRARY_PATH"

cd "$PAYLOAD_DIR"
python3 "$PAYLOAD_DIR/server.py"
