#!/bin/bash

# Title: Ringtone_tester
# Description: Perform a ringtone test by playing each ringtone individually
# Author: spywill
# Version: 1.0

resp=$(CONFIRMATION_DIALOG "Title: Ringtone_tester.

Perform a ringtone test by playing
each ringtone individually.

Select the checkmark to continue.")

case "$resp" in
	$DUCKYSCRIPT_USER_CONFIRMED)
		LOG green "Selected yes continue..."
		spinnerid=$(START_SPINNER "Checking files...")
		;;
	$DUCKYSCRIPT_USER_DENIED)
		LOG red "Selected no exiting..."
		exit 1
		;;
	*)
		LOG red "Unknown response: $resp exiting..."
		exit 1
		;;
esac

RINGTONE_DIR="/mmc/root/ringtones"
current=0
found_ringtone=false
ringtone_count=0

# Check if directory exists
if [ ! -d "$RINGTONE_DIR" ]; then
	STOP_SPINNER ${spinnerid}
	LOG red "Error: ringtone directory not found: $RINGTONE_DIR"
	LOG yellow "Download at
	https://github.com/hak5/wifipineapplepager-ringtones/tree/master"
	exit 1
fi

# Check if directory contains valid ringtone files
for file in "$RINGTONE_DIR"/*; do
	[ -f "$file" ] || continue

	# Check RTTTL content (must contain at least two colons)
	if grep -q ':' "$file" && [ "$(grep -o ':' "$file" | wc -l)" -ge 2 ]; then
		found_ringtone=true
		ringtone_count=$((ringtone_count + 1))
	fi
done

# No valid ringtones found
if [ "$found_ringtone" = false ]; then
	STOP_SPINNER ${spinnerid}
	LOG red "Error: no valid ringtone files found in $RINGTONE_DIR"
	LOG red "Expected format like:"
	LOG red "  Achievement:d=16,o=5,b=125:c6,e6,g6,c7,e7,g7"
	exit 1
fi

STOP_SPINNER ${spinnerid}
sleep 1

LOG ""
LOG yellow "Available ringtones: $ringtone_count file(s) in $RINGTONE_DIR"
LOG ""

# Play ringtones one by one
for file in "$RINGTONE_DIR"/*; do
	# Skip if not a regular file
	[ -f "$file" ] || continue

	# Skip non-RTTTL files
	grep -q ':' "$file" || continue

	current=$((current + 1))

	# Get filename only (no path)
	filename="$(basename "$file")"
	ringtone_name="${filename%%:*}"

	# Display the ringtone name
	LOG cyan "Playing: $ringtone_name   [$current/$ringtone_count]"

	# Keep trying until the ringtone API accepts it
	while true; do
		if RINGTONE "$file" 2>/dev/null; then
			break
		fi
		sleep 0.5
	done

	# Wait until playback finishes before moving on
	while RINGTONE status 2>/dev/null | grep -q "playing"; do
		sleep 0.5
	done
done
