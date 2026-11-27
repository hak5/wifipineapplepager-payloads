#!/bin/bash

# Title: Password Generator
# Author: spywill
# Description: Generate and manage random passwords
# Version: 1.1

# Base folder and subfolder.
BASE_FOLDER="/mmc/root/payloads/user/general/Password_Generator"
SAVE_FOLDER="$BASE_FOLDER/ALL_PASSWORDS"
mkdir -p "$SAVE_FOLDER"

# Generate a password using the existing code.
Generate_Password() {
	# Get password name and length.
	PASSWORD_NAME=$(TEXT_PICKER "Name your password" "My_PC") || return
	LENGTH=$(NUMBER_PICKER "Length of password" "16") || return

	# Ensure minimum length.
	(( LENGTH < 4 )) && LENGTH=4

	# Character sets.
	UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
	LOWER='abcdefghijklmnopqrstuvwxyz'
	NUM='0123456789'
	SPECIAL='!"#$%&'\''()*+,-./:;<=>?@[\]^_`{|}~'
	ALL="$UPPER$LOWER$NUM$SPECIAL"

	# Function to pick a random character from a set.
	pick() { echo -n "${1:$((RANDOM % ${#1})):1}"; }

	# Pick one character from each type.
	PASSWORD="$(pick "$UPPER")$(pick "$LOWER")$(pick "$NUM")$(pick "$SPECIAL")"

	# Add remaining characters.
	for ((i=4; i<LENGTH; i++)); do
		PASSWORD+=$(pick "$ALL")
	done

	# Shuffle using pure Bash.
	chars=()
	for ((i=0; i<${#PASSWORD}; i++)); do
		chars+=("${PASSWORD:i:1}")
	done

	# Shuffle password characters using Fisher-Yates.
	for ((i=${#chars[@]}-1; i>0; i--)); do
		j=$((RANDOM%(i+1)))
		t=${chars[i]}
		chars[i]=${chars[j]}
		chars[j]=$t
	done

	PASSWORD=$(printf "%s" "${chars[@]}")

	# Sanitize filename.
	SAFE_NAME=$(echo "$PASSWORD_NAME" | tr '/\\?%*:|"<> ' '_')
	[ -n "$SAFE_NAME" ] || SAFE_NAME="My_PC"
	SAVE_PATH="$SAVE_FOLDER/$SAFE_NAME.txt"

	# Save password.
	printf "%s\n%s\n" "$SAFE_NAME" "$PASSWORD" > "$SAVE_PATH"

	# Display password.
	PROMPT "Generated password: $SAFE_NAME
	$PASSWORD"
	LOG blue "Generated password for: $SAFE_NAME"
	LOG green "Password: $PASSWORD"
	LOG yellow "Password saved to:
	$SAVE_PATH"
}

# Build a list of saved password files.
Build_Password_List() {
	PASSWORD_FILES=()

	for file in "$SAVE_FOLDER"/*.txt; do
		[ -f "$file" ] || continue
		PASSWORD_FILES+=("$(basename "$file")")
	done
}

# View a saved password.
View_Password() {
	Build_Password_List

	if [ "${#PASSWORD_FILES[@]}" -eq 0 ]; then
		LOG red "No passwords found in $SAVE_FOLDER"
		PROMPT "No saved passwords found."
		return
	fi

	LOG cyan "[PAGER] Select a password to view..."

	view_resp=$(LIST_PICKER \
		"VIEW PASSWORD" \
		"${PASSWORD_FILES[@]}" \
		"Cancel" \
		"Cancel"
	) || return

	[ "$view_resp" = "Cancel" ] && return

	if [ -f "$SAVE_FOLDER/$view_resp" ]; then
		LOG ""
		LOG blue "----- $view_resp -----"
		LOG yellow "$(cat "$SAVE_FOLDER/$view_resp")"
		LOG ""
		LOG "Press A button to continue."
		WAIT_FOR_BUTTON_PRESS A
	fi
}

# Remove a saved password.
Remove_Password() {
	Build_Password_List

	if [ "${#PASSWORD_FILES[@]}" -eq 0 ]; then
		LOG red "No passwords found in $SAVE_FOLDER"
		PROMPT "No saved passwords found."
		return
	fi

	LOG cyan "[PAGER] Select a password to remove..."

	remove_resp=$(LIST_PICKER \
		"REMOVE PASSWORD" \
		"${PASSWORD_FILES[@]}" \
		"Cancel" \
		"Cancel"
	) || return

	[ "$remove_resp" = "Cancel" ] && return

	if [ -f "$SAVE_FOLDER/$remove_resp" ]; then
		CHECK=$(CONFIRMATION_DIALOG "Remove password: $remove_resp?")

		case "$CHECK" in
			"$DUCKYSCRIPT_USER_CONFIRMED")
				if rm -f "$SAVE_FOLDER/$remove_resp"; then
					LOG green "Removed password: $remove_resp"
					PROMPT "Password removed: $remove_resp"
				else
					LOG red "Failed to remove: $remove_resp"
					PROMPT "Failed to remove password."
				fi
			;;
			"$DUCKYSCRIPT_USER_DENIED")
				LOG yellow "Password removal cancelled."
			;;
			*)
				LOG red "Unknown response for $CHECK"
			;;
		esac
	fi
}

# Create and save a custom password.
Create_Password() {
	default_pass=""
	created_passwd=$(TEXT_PICKER "Create your own password" "$default_pass") || return

	if [ -z "$created_passwd" ]; then
		LOG red "Password cannot be empty."
		PROMPT "Password cannot be empty."
		return
	fi

	created_name=$(TEXT_PICKER "Name your password" "My_PC") || return
	SAFE_NAME=$(echo "$created_name" | tr '/\\?%*:|"<> ' '_')
	[ -n "$SAFE_NAME" ] || SAFE_NAME="My_PC"
	SAVE_PATH="$SAVE_FOLDER/$SAFE_NAME.txt"

	printf "%s\n%s\n" "$SAFE_NAME" "$created_passwd" > "$SAVE_PATH"

	LOG green "Custom password saved: $SAFE_NAME"
	PROMPT "Password saved: $SAFE_NAME"
}

# Build the main password menu.
while true; do
	resp=$(LIST_PICKER \
		"PASSWORD MENU" \
		"Generate_Password" \
		"View_Password" \
		"Remove_Password" \
		"Create_Password" \
		"Exit" \
		"Exit"
	) || exit 0

	case "$resp" in
		"Generate_Password")
			Generate_Password
		;;
		"View_Password")
			View_Password
		;;
		"Remove_Password")
			Remove_Password
		;;
		"Create_Password")
			Create_Password
		;;
		"Exit")
			exit 0
		;;
	esac
done
