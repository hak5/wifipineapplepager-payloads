#!/bin/bash

# Title: HCXDUMP
# Author: jader242
# Description: Run hcxdumptool from the pager UI
# Version: 1.0

INTERFACE="wlan1mon"
CHANNELS_2GHZ="2412,2417,2422,2427,2432,2437,2442,2447,2452,2457,2462,2467,2472,2484"
CHANNELS_5GHZ="5180,5200,5220,5240,5260,5280,5300,5320,5500,5520,5540,5560,5580,5600,5620,5640,5660,5680,5700,5720,5745,5765,5785,5805,5825,5845,5865,5885"
OUTPUT_PATH="/root/loot/pcap"
FILE_NAME="capture_${INTERFACE}_$(date +%Y%m%d_%H%M%S).pcapng"
LED_COLOR=$(uci get system.@pager[0].led_color)
STOP_FLAG="/tmp/hcxdumptool_stop"

LOG "Checking dependencies"

if ! command -v hcxdumptool >/dev/null 2>&1; then
	LOG "Dependencies not met!"
	install=$(CONFIRMATION_DIALOG "Install hcxdumptool?")
	
	case $? in
		$DUCKYSCRIPT_REJECTED)
			LOG "Dialog rejected"
			exit 1
			;;
		$DUCKYSCRIPT_ERROR)
			LOG "An error occurred"
			exit 1
			;;
	esac
	
	case "$install" in
		$DUCKYSCRIPT_USER_CONFIRMED)
			LOG "Installing hcxdumptool"
			
			if opkg update && opkg install -d mmc hcxdumptool > /dev/null 2>&1; then
				LOG "hcxdumptool successfully installed!"
			else
				LOG "hcxdumptool failed to install!"
				LOG "Exiting..."
				exit 1
			fi
			;;
		$DUCKYSCRIPT_USER_DENIED)
			LOG "User selected no"
			LOG "Exiting..."
			exit 1
			;;
		*)
			LOG "Unknown response"
			LOG "Exiting..."
			exit 1
			;;
	esac
fi

LOG "Starting hcxdumptool on $INTERFACE"
PINEAPPLE_HOPPING_STOP
mkdir -p "$OUTPUT_PATH"

all=false
resp=$(LIST_PICKER "Pick Band(s)" "2GHZ" "5GHZ" "2+5GHZ" "ALL" "2GHZ")

case "$resp" in
	"2GHZ")
		CHANNELS="$CHANNELS_2GHZ"
		;;
	"5GHZ")
		CHANNELS="$CHANNELS_5GHZ"
		;;
	"2+5GHZ")
		CHANNELS="$CHANNELS_2GHZ,$CHANNELS_5GHZ"
		;;
	"ALL")
		CHANNELS=""
		all=true
		;;
	*)
		LOG "No selection, exiting..."
		PINEAPPLE_HOPPING_START
		exit 1
		;;
esac

if [ "$all" = true ]; then
	hcxdumptool -i "$INTERFACE" -F -w "$OUTPUT_PATH/$FILE_NAME" &
	PID=$!
else
	hcxdumptool -i "$INTERFACE" -f "$CHANNELS" -w "$OUTPUT_PATH/$FILE_NAME" &
	PID=$!
fi

DO_A_BARREL_ROLL
LOG "Initializing..."
sleep 10

if ! kill -0 "$PID" 2>/dev/null; then
    LOG "hcxdumptool failed to start"
    PINEAPPLE_HOPPING_START
    exit 1
fi

# Monitor hcxdumptool
rm -f "$STOP_FLAG" 2>/dev/null
(
	while kill -0 "$PID" 2>/dev/null; do
		sleep 15
	done

	if [ ! -f "$STOP_FLAG" ]; then
		ALERT "hcxdumptool unexpectedly stopped"
		LED FAIL3
	fi
) &
MONITOR_PID=$!

LOG "Running hcxdumptool"
LOG "Press B to stop"
sleep 1
WAIT_FOR_BUTTON_PRESS B

LOG "Stopping..."
touch "$STOP_FLAG"
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
kill "$MONITOR_PID" 2>/dev/null
wait "$MONITOR_PID" 2>/dev/null
LOG "Stopped hcxdumptool"
LOG "Loot saved to $OUTPUT_PATH"
PINEAPPLE_HOPPING_START
LED "$LED_COLOR"
rm -f "$STOP_FLAG" 2>/dev/null
exit 0
