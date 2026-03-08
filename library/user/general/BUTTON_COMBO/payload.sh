#!/bin/bash

# Title:  Button combo
# Author: spywill
# Description:  Choose any Button combination and run a custom command
# Version: 1.0

# Turn LED cyan to indicate script start
LED C IQUIN

# Show title and instructions to user
PROMPT "Title: Button combo

Choose any Button combination
Example:
A UP UP DOWN

Revised the end of the payload
according to your commands"

# Turn LED off
LED OFF

# Toggle led A and B button
toggle_led () {
	path=$1
	name=$2

	if [ "$(cat "$path")" -eq 1 ]; then
		echo 0 > "$path"
		LOG red "$name off"
	else
		echo 1 > "$path"
		LOG green "$name on"
	fi
}

# Show text picker for button combination selection
userpick=$(TEXT_PICKER "Choose a combination" "A UP UP DOWN")

# Convert selected combination string into array
combo=($userpick)

# Show text picker to enter a custom shell command
user_command=$(TEXT_PICKER "Enter command" 'ip -o -4 addr show | awk '\''{print $2,$4}'\'' | while read i p; do echo "$i IP:$p MAC:$(</sys/class/net/$i/address)"; done')

# Show confirmation dialog before starting combo detection
resp=$(CONFIRMATION_DIALOG "Start Button combination

Selected button combination
${combo[@]}
	
Select the checkmark to continue")

# Turn LED off
LED OFF

# Check user response from confirmation dialog
case "$resp" in
	# If user confirmed
	$DUCKYSCRIPT_USER_CONFIRMED)
		LOG green "User selected yes"
		
		# Check user response from confirmation dialog run in background
		resp=$(CONFIRMATION_DIALOG "Start Button combination in background")
		
		# Check user response from confirmation dialog
		case "$resp" in
			# If user confirmed
			$DUCKYSCRIPT_USER_CONFIRMED)
				LOG green "Running Button combo in background..."
				back_ground="1"
				;;
			# If user denied
			$DUCKYSCRIPT_USER_DENIED)
				LOG green "Starting Button combo..."
				back_ground="0"
				;;
			# If response is unknown
			*)
				LOG red "Unknown response: $resp exiting..."
				exit 1
				;;
		esac
		;;
	# If user denied
	$DUCKYSCRIPT_USER_DENIED)
		LOG red "User selected no exiting..."
		exit
		;;
	# If response is unknown
	*)
		LOG red "Unknown response: $resp exiting..."
		exit 1
		;;
esac

# Start infinite loop waiting for correct button sequence
run_combo() {
	# 10-second countdown
	for ((time=10; time>=1; time--)); do
		LOG "Starting in $time..."
		sleep 1
	done
	
	# disable dispaly and Toggle A and B button LEDS off
	DISABLE_DISPLAY
	sleep 1
	toggle_led "/sys/devices/platform/leds/leds/a-button-led/brightness" "A button"
	toggle_led "/sys/devices/platform/leds/leds/b-button-led/brightness" "B button"

	while true; do
		# Loop through each button in selected combo
		for button in "${combo[@]}"; do
			# Wait for a button press
			pressed=$(WAIT_FOR_INPUT)

			# If pressed button does not match expected button
			if [[ "$pressed" != "$button" ]]; then
				# Turn LED red for incorrect input
				LED R

				# Log failure message
				LOG red "Wrong button! Restarting combo..."

				# Turn LED off
				LED OFF

				# Restart combo from beginning
				continue 2
			fi
		done

		# If full combo entered correctly, turn LED green
		# enable dispaly and Toggle A and B button LEDS on
		LED G
		ENABLE_DISPLAY
		sleep 1
		toggle_led "/sys/devices/platform/leds/leds/a-button-led/brightness" "A button"
		toggle_led "/sys/devices/platform/leds/leds/b-button-led/brightness" "B button"
	
		# Log successful combination message
		LOG yellow "Combo successful!
		${combo[@]}
		The payload ending has been revised per your instructions."

		# Turn LED off
		LED OFF
	
		output=$(eval "$user_command")

		# Execute user-provided command and log output
		LOG blue "USER COMMAND:
		$output"

		# Display command output in prompt window
		PROMPT "USER COMMAND:
		$output"

		# Exit infinite loop
		break
	done
}

# run loop in background or not
if [[ "$back_ground" == "1" ]]; then
	run_combo &
else
	run_combo
fi
