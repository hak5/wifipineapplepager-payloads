#!/bin/bash

# Title:  Process_Killer
# Author: spywill
# Description: Safely terminate unwanted processes by PID number 
# Version: 1.0

PROMPT "Title: Process_Killer

Safely terminate unwanted processes 
by specifying their PID (Process ID)
Use with caution

press any button to continue"

id=$(START_SPINNER "One moment please...")

LOG yellow "----- Top CPU Processes -----"
LOG blue "[PID]   [CPU]   [RAM]   [NAME]"

# Iterate over numeric /proc entries
for pid in /proc/[0-9]*; do
	pidnum=$(basename "$pid")
    
	# Skip if stat file missing
	[ -f "$pid/stat" ] || continue

	# Get process name
	pname=$(awk '{print $2}' "$pid/stat" | tr -d '()')

	# Skip kernel threads
	case "$pname" in
		kworker*|rcu_*|napi/*) continue ;;
	esac

	# Get CPU time (utime + stime)
	read utime stime <<< $(awk '{print $14, $15}' "$pid/stat")
	total=$((utime + stime))
	cpu=$((total / 100))    # approximate %
	[ -z "$cpu" ] && cpu=0

	# Get RAM usage in MB (VmRSS in kB)
	if [ -f "$pid/status" ]; then
		ram=$(awk '/VmRSS/ {printf "%d", $2/1024; exit}' "$pid/status")
		[ -z "$ram" ] && ram=0
	else
		ram=0
	fi
	
	# Store the line in a variable
	line=$(printf "%-7s %-6s %-7s %s" "$pidnum" "$cpu%" "${ram}MB" "$pname")
	echo "$line"
	
done | sort -k2 -nr | head -n 20 | while read -r line; do
	LOG "$line"
done

STOP_SPINNER $id

LOG yellow "Remember the PID number you wish to kill
Press button A to continue"
WAIT_FOR_BUTTON_PRESS A

PID_NUMBER=$(NUMBER_PICKER "Enter PID # to kill" "")
case $PID_NUMBER in
	$DUCKYSCRIPT_CANCELLED)
		LOG red "User cancelled exiting..."
		exit
		;;
	$DUCKYSCRIPT_REJECTED)
		LOG red "Dialog rejected exiting..."
		exit 1
		;;
	$DUCKYSCRIPT_ERROR)
		LOG red "An error occurred exiting..."
		exit 1
		;;
esac

KILL_PID=$(CONFIRMATION_DIALOG "ARE SURE YOU WANT TO KILL

PID-$PID_NUMBER")
case $KILL_PID in
	$DUCKYSCRIPT_USER_CONFIRMED)
		LOG "User selected yes"
		LOG red "KILLING PID-$PID_NUMBER"
		kill "$PID_NUMBER"
		sleep 1
		;;
	$DUCKYSCRIPT_USER_DENIED)
		LOG red "User selected no exiting..."
		exit
		;;
	$DUCKYSCRIPT_REJECTED)
		LOG red "Dialog rejected exiting..."
		exit 1
		;;
	$DUCKYSCRIPT_ERROR)
		LOG red "An error occurred exiting..."
		exit 1
		;;
esac

# Verify if the process was killed, retrying a few times killing the process if it survives
RETRIES=5
SLEEP_INTERVAL=1  # seconds

for ((i=1; i<=RETRIES; i++)); do
	if kill -0 "$PID_NUMBER" 2>/dev/null; then
		LOG yellow "PID-$PID_NUMBER still running, attempting kill $i/$RETRIES..."
		kill -9 "$PID_NUMBER" 2>/dev/null
		sleep $SLEEP_INTERVAL
	else
		LOG green "PID-$PID_NUMBER has been successfully killed."
		break
	fi
done

# Final check if still alive after all retries
if kill -0 "$PID_NUMBER" 2>/dev/null; then
	LOG red "PID-$PID_NUMBER could not be killed after $RETRIES attempts."
fi
