#!/bin/bash

# Title: Process_Killer
# Author: spywill
# Description: Safely terminate unwanted processes by selecting them from a menu.
# Version: 1.1

PROMPT "Safely terminate unwanted processes
by selecting them from a process menu.

Use with caution!"

# Temporary files
PROCESS_LIST="/tmp/process_list_$$"
PID_LIST="/tmp/process_pid_$$"

# Cleanup on exit
trap 'rm -f "$PROCESS_LIST" "${PROCESS_LIST}.sorted" "$PID_LIST"' EXIT

# Main menu loop
while true; do
	id=$(START_SPINNER "Scanning processes...")

	LOG yellow "----- Top CPU Processes -----"
	LOG blue "[NAME] [PID]"

	: > "$PROCESS_LIST"
	: > "$PID_LIST"

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

		# Get CPU time
		read utime stime <<EOF
$(awk '{print $14, $15}' "$pid/stat")
EOF

		total=$((utime + stime))
		cpu=$((total / 100))
		[ -z "$cpu" ] && cpu=0

		# Get RAM usage
		if [ -f "$pid/status" ]; then
			ram=$(awk '/VmRSS/ {printf "%d", $2/1024; exit}' "$pid/status")
			[ -z "$ram" ] && ram=0
		else
			ram=0
		fi

		# Store process information
		printf "%-7s %-6s %-7s %s\n" "$pidnum" "$cpu%" "${ram}MB" "$pname" >> "$PROCESS_LIST"
	done

	# Sort by CPU and get top 20
	sort -k2 -nr "$PROCESS_LIST" | head -n 20 > "${PROCESS_LIST}.sorted"

	# Read sorted process list and build menu options
	OPTIONS=()
	while read -r pidnum cpu ram pname; do
		[ -z "$pidnum" ] && continue
		LOG "$pname $pidnum"
		OPTIONS+=("$pname $pidnum")
	done < "${PROCESS_LIST}.sorted"

	STOP_SPINNER "$id"

	# Check for processes
	if [ ${#OPTIONS[@]} -eq 0 ]; then
		LOG red "No processes found."
		sleep 2
		continue
	fi

	LOG yellow "Select a process to kill"
	WAIT_FOR_BUTTON_PRESS A

	# Display process selection menu
	SELECTED_PROCESS=$(LIST_PICKER \
		"Process to Kill" \
		"${OPTIONS[@]}" \
		"Exit" \
		"Exit") || continue

	# Handle selection
	case "$SELECTED_PROCESS" in
		"Exit"|"")
			LOG red "Exiting Process Killer..."
			exit 0
		;;
	esac

	# Extract PID from selection
	PID_NUMBER="${SELECTED_PROCESS##* }"
	PROCESS_NAME="${SELECTED_PROCESS% *}"

	# Verify PID
	if ! [ -d "/proc/$PID_NUMBER" ]; then
		LOG red "Process no longer exists."
		sleep 1
		continue
	fi

	# Confirm killing process
	KILL_PID=$(CONFIRMATION_DIALOG "ARE YOU SURE YOU WANT TO KILL

	Process: $PROCESS_NAME
	PID: $PID_NUMBER") || continue

	case "$KILL_PID" in
		$DUCKYSCRIPT_USER_CONFIRMED)
			LOG "User selected yes"
			LOG red "KILLING $PROCESS_NAME PID-$PID_NUMBER"
			kill "$PID_NUMBER"
			sleep 1
		;;
		$DUCKYSCRIPT_USER_DENIED)
			LOG yellow "User selected no."
			continue
		;;
		*)
			continue
		;;
	esac

	# Verify if process was killed, retrying if necessary
	RETRIES=5
	for ((i=1; i<=RETRIES; i++)); do
		if kill -0 "$PID_NUMBER" 2>/dev/null; then
			LOG yellow "$PROCESS_NAME PID-$PID_NUMBER still running, attempting kill $i/$RETRIES..."
			kill -9 "$PID_NUMBER" 2>/dev/null
			sleep 1
		else
			LOG green "$PROCESS_NAME PID-$PID_NUMBER has been successfully killed."
			break
		fi
	done

	# Final check
	if kill -0 "$PID_NUMBER" 2>/dev/null; then
		LOG red "PID-$PID_NUMBER could not be killed after $RETRIES attempts."
	fi

	# Small delay before refreshing menu
	sleep 1
done
