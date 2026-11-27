#!/bin/bash

# Title: Ringtone_tester
# Description: Select a ringtone and play it in a loop until button A is pressed.
# Author: spywill
# Version: 1.1

RINGTONE_DIR="/mmc/root/ringtones"
RINGTONE_LIST="/tmp/ringtone_list_$$"

# Confirm before starting.
PROMPT "Ringtone Tester:
Select a ringtone from a menu and play it continuously in a loop.
Press button A to stop playback and return to the menu."

# Check that the ringtone directory exists.
if [ ! -d "$RINGTONE_DIR" ]; then
	STOP_SPINNER "$spinnerid"
	LOG red "Error: ringtone directory not found."
	LOG yellow "Download ringtones from:"
	LOG yellow "https://github.com/hak5/wifipineapplepager-ringtones/tree/master"
	exit 0
fi

# Build the ringtone list once.
: > "$RINGTONE_LIST"

for file in "$RINGTONE_DIR"/*; do
	[ -f "$file" ] || continue

	# Check for valid RTTTL content.
	[ "$(grep -o ':' "$file" | wc -l)" -ge 2 ] || continue

	filename=$(basename "$file")
	ringtone_name="${filename%%:*}"
	ringtone_name="${ringtone_name%.*}"

	# Save the ringtone name and its file path.
	printf '%s|%s\n' "$ringtone_name" "$file" >> "$RINGTONE_LIST"
done

STOP_SPINNER "$spinnerid"

# Check whether any valid ringtones were found.
if [ ! -s "$RINGTONE_LIST" ]; then
	rm -f "$RINGTONE_LIST"
	LOG red "No valid ringtones found in $RINGTONE_DIR"
	PROMPT "No valid ringtones found."
	exit 0
fi

LOG green "Ringtone list ready."

# Display the menu.
while true; do
	set --

	# Add ringtone names to the menu.
	while IFS='|' read -r ringtone_name ringtone_file; do
		[ -n "$ringtone_name" ] || continue
		set -- "$@" "$ringtone_name"
	done < "$RINGTONE_LIST"

	# Select a ringtone or exit.
	selected=$(LIST_PICKER \
		"SELECT RINGTONE" \
		"$@" \
		"Exit" \
		"Exit"
	) || break

	case "$selected" in
		"Exit"|"")
			LOG yellow "Exiting ringtone tester."
			break
		;;
	esac

	# Find the selected ringtone file.
	selected_file=""

	while IFS='|' read -r ringtone_name ringtone_file; do
		if [ "$ringtone_name" = "$selected" ]; then
			selected_file="$ringtone_file"
			break
		fi
	done < "$RINGTONE_LIST"

	[ -n "$selected_file" ] || continue

	LOG cyan "Playing: $selected"

	# Repeat the selected ringtone in the background.
	(
		while true; do
			RINGTONE "$selected_file" 2>/dev/null

			# Wait for the current ringtone to finish.
			while RINGTONE status 2>/dev/null | grep -q "playing"; do
				sleep 0.2
			done

			# Brief pause before replaying.
			sleep 0.2
		done
	) &
	play_pid=$!

	# Wait for button A.
	WAIT_FOR_BUTTON_PRESS A

	# Stop the playback loop.
	kill -9 "$play_pid" 2>/dev/null
	wait "$play_pid" 2>/dev/null

	# Stop any ringtone still playing.
	RINGTONE stop 2>/dev/null
	LOG yellow "Returning to ringtone menu..."
done

# Clean up the temporary list.
rm -f "$RINGTONE_LIST"
LOG green "Ringtone tester closed."
