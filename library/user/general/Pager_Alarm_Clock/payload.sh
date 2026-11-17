#!/bin/bash

# Title:  Pager Alarm Clock
# Author: spywill
# Description:  A simple alarm clock that runs in the background and displays the time in the format YYYY-MM-DD HH:MM AM/PM
# Version: 1.2

PROMPT "Pager Alarm Clock

Set your alarm, choose and preview your favorite ringtone, and let your Pager wake you up!

Press any button to stop the alarm."

# Ringtone folder and default ringtone
RINGTONE_DIR="/mmc/root/ringtones"
DEFAULT_RINGTONE="$RINGTONE_DIR/Alert1.rtttl"

mkdir -p "$RINGTONE_DIR"

if [ ! -f "$DEFAULT_RINGTONE" ]; then
	printf '%s\n' "Alert1:d=4,o=5,b=285:8d5,8e5,8f5,8e5,8d5" > "$DEFAULT_RINGTONE"
fi

# Select and preview ringtone
while true; do
	RINGTONE_OPTIONS=()

	for ringtone_file in "$RINGTONE_DIR"/*.rtttl; do
		[ -f "$ringtone_file" ] || continue
		RINGTONE_OPTIONS+=("$(basename "$ringtone_file" .rtttl)")
	done

	if [ "${#RINGTONE_OPTIONS[@]}" -eq 0 ]; then
		ERROR_DIALOG "No ringtone files found in $RINGTONE_DIR"
		LOG red "No ringtone files found in $RINGTONE_DIR"
		exit 0
	fi

	selected_ringtone=$(LIST_PICKER "Select ringtone to preview" \
		"${RINGTONE_OPTIONS[@]}") || exit 0

	if [ -z "$selected_ringtone" ]; then
		ERROR_DIALOG "No ringtone selected"
		LOG red "No ringtone selected"
		exit 0
	fi

	RINGTONE_FILE="$RINGTONE_DIR/$selected_ringtone.rtttl"

	if [ ! -s "$RINGTONE_FILE" ]; then
		LOG red "Ringtone file is empty or missing: $selected_ringtone"
		continue
	fi

	RINGTONE_DATA=$(cat "$RINGTONE_FILE")
	LOG yellow "Previewing: $selected_ringtone"
	RINGTONE "$RINGTONE_DATA"

	confirm=$(CONFIRMATION_DIALOG "Use $selected_ringtone as your alarm ringtone?")
	if [ "$confirm" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
		LOG green "Selected ringtone: $selected_ringtone"
		break
	fi
	LOG blue "Choose another ringtone"
done

# Get alarm datetime
current_datetime=$(date +"%Y-%m-%d %I:%M %p")
input_datetime=$(TEXT_PICKER "YYYY-MM-DD HH:MM AM/PM" "$current_datetime") || exit 0

# Normalize input
input_datetime=$(echo "$input_datetime" | tr '[:lower:]' '[:upper:]' | xargs)

# Parse input
alarm_date=$(echo "$input_datetime" | awk '{print $1}')
time_part=$(echo "$input_datetime" | awk '{print $2}')
ampm=$(echo "$input_datetime" | awk '{print $3}')

hour=$(echo "$time_part" | cut -d: -f1)
minute=$(echo "$time_part" | cut -d: -f2)

if [[ -z "$hour" || -z "$minute" || -z "$ampm" || -z "$alarm_date" ]]; then
	ERROR_DIALOG "Invalid format. Use: 2026-01-29 07:30 AM"
	LOG red "Invalid format. Use: 2026-01-29 07:30 AM"
	exit 0
fi

# Convert to 24-hour format
if [[ "$ampm" == "PM" && "$hour" != "12" ]]; then
	hour=$((10#$hour + 12))
elif [[ "$ampm" == "AM" && "$hour" == "12" ]]; then
	hour="00"
fi

# Convert to epoch time
alarm_epoch=$(date -d "$alarm_date $hour:$minute" +%s 2>/dev/null)
if [ -z "$alarm_epoch" ]; then
	ERROR_DIALOG "Invalid date/time"
	LOG red "Invalid date/time"
	exit 0
fi

LOG ""
LOG "Alarm set for $input_datetime
Pager Alarm Clock running in background

press any button to stop ringtone"

# Function to play selected ringtone continuously
play_ringtone() {
	while true; do
		RINGTONE "$RINGTONE_DATA"
		sleep 1
	done
}

# Main wait loop
while true; do
	current_epoch=$(date +%s)

	if (( current_epoch >= alarm_epoch )); then
		PROMPT "current time: $(date +"%Y-%m-%d %I:%M %p")

		press any button to stop ringtone" &

		play_ringtone &
		RING_PID=$!

		# Ensure ringtone stops if script exits
		trap 'kill "$RING_PID" 2>/dev/null; pkill -f "RINGTONE" 2>/dev/null; wait "$RING_PID" 2>/dev/null' EXIT
		# Wait for button press
		WAIT_FOR_BUTTON_PRESS ANY
		# Stop ringtone
		kill -9 "$RING_PID" 2>/dev/null
		pkill -f "RINGTONE" 2>/dev/null
		wait "$RING_PID" 2>/dev/null
		exit 0
	fi
	sleep 2
done &
