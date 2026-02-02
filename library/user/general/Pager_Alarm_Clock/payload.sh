#!/usr/bin

# Title:  Pager Alarm Clock
# Author: spywill
# Description:  A simple alarm clock that runs in the background and displays the time in the format YYYY-MM-DD HH:MM AM/PM
# Version: 1.0

LOG ""
LOG yellow "Pager Alarm Clock"
LOG ""

# --- Get alarm datetime ---
current_datetime=$(date +"%Y-%m-%d %I:%M %p")
input_datetime=$(TEXT_PICKER "YYYY-MM-DD HH:MM AM/PM" "$current_datetime")

# Normalize input
input_datetime=$(echo "$input_datetime" | tr '[:lower:]' '[:upper:]')

# Parse input
alarm_date=$(echo "$input_datetime" | awk '{print $1}')
time_part=$(echo "$input_datetime" | awk '{print $2}')
ampm=$(echo "$input_datetime" | awk '{print $3}')

hour=$(echo "$time_part" | cut -d: -f1)
minute=$(echo "$time_part" | cut -d: -f2)

if [[ -z "$hour" || -z "$minute" || -z "$ampm" || -z "$alarm_date" ]]; then
	LOG red "Invalid format. Use: 2026-01-29 07:30 AM"
	exit 1
fi

# Convert to 24-hour format
if [[ "$ampm" == "PM" && "$hour" != "12" ]]; then
	hour=$((10#$hour + 12))
elif [[ "$ampm" == "AM" && "$hour" == "12" ]]; then
	hour="00"
fi

alarm_datetime=$(printf "%s %02d:%02d" "$alarm_date" "$hour" "$minute")

LOG yellow "Alarm set for $input_datetime
Pager Alarm Clock running in background

press any button to stop ringtone"

INPUT="/dev/input/event0"

# Safety check
if [ ! -e "$INPUT" ]; then
	ALERT "Error: $INPUT not found"
	exit 1
fi

# Function to play ringtone continuously
play_ringtone() {
	while true; do
		RINGTONE "Alert1:d=4,o=5,b=285:8d5,8e5,8f5,8e5,8d5"
		sleep 1
	done
}

# Main wait loop
while true; do
	current=$(date +"%Y-%m-%d %H:%M")

	if [[ "$current" == "$alarm_datetime" ]]; then
		PROMPT "Pager Alarm Clock
        
		current time: $(date +"%Y-%m-%d %I:%M %p")
        
		press any button to stop ringtone" &

		play_ringtone &
		RING_PID=$!

		# Ensure ringtone stops if script exits
		trap 'kill $RING_PID 2>/dev/null; pkill -f "RINGTONE" 2>/dev/null' EXIT

		# Wait for button press
		while true; do
			# Read one 16-byte event
			data=$(dd if="$INPUT" bs=16 count=1 2>/dev/null | hexdump -v -e '16/1 "%02x "')

			# Skip if nothing read
			[ -z "$data" ] && continue

			# Extract type and value
			type=$(echo "$data" | awk '{print $9, $10}')
			value=$(echo "$data" | awk '{print $13}')

			if [ "$type" = "01 00" ] && [ "$value" = "01" ]; then
				kill $RING_PID 2>/dev/null
				pkill -f "RINGTONE" 2>/dev/null
				exit 1
			fi
			sleep 0.2
		done
	fi
	sleep 10
done &
