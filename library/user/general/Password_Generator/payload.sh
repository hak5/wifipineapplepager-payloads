#!/bin/bash

# Title:  Password Generator
# Author: spywill
# Description:  Generate a random password
# Version: 1.0

PROMPT "Title: Password Generator

Generate a random password
Enter name and length of password
save to payload folder (ALL_PASSWORDS)

press any button to continue"

# Base folder and subfolder
BASE_FOLDER="/mmc/root/payloads/user/general/Password_Generator"
SAVE_FOLDER="$BASE_FOLDER/ALL_PASSWORDS"
mkdir -p "$SAVE_FOLDER"

# Ask if user wants to view all saved passwords
TXT_FILES=("$SAVE_FOLDER"/*.txt)
if [ -e "${TXT_FILES[0]}" ]; then
	CHECK=$(CONFIRMATION_DIALOG "View all saved passwords?")
	case "$CHECK" in
		"$DUCKYSCRIPT_USER_CONFIRMED")
			for file in "$SAVE_FOLDER"/*.txt; do
				LOG blue "----- $(basename "$file") -----"
				LOG yellow "$(cat "$file")"
				LOG ""
			done
			LOG "Press A button to continue."
			WAIT_FOR_BUTTON_PRESS A
			;;
		"$DUCKYSCRIPT_USER_DENIED")
			LOG "Continuing..."
			;;
		*)
			LOG red "Unknown response for $CHECK"
			exit
			;;
	esac
else
	LOG red "No saved passwords in $SAVE_FOLDER"
fi

# Get password name and length
PASSWORD_NAME=$(TEXT_PICKER "Name your password" "My_PC")
LENGTH=$(NUMBER_PICKER "Length of password" "16")

# Ensure minimum length
(( LENGTH < 4 )) && LENGTH=4

# Character sets
UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
LOWER='abcdefghijklmnopqrstuvwxyz'
NUM='0123456789'
SPECIAL='!"#$%&'\''()*+,-./:;<=>?@[\]^_`{|}~'
ALL="$UPPER$LOWER$NUM$SPECIAL"

# Function to pick a random character from a set
pick() { echo -n "${1:$((RANDOM % ${#1})):1}"; }

# Pick one character from each type
PASSWORD="$(pick "$UPPER")$(pick "$LOWER")$(pick "$NUM")$(pick "$SPECIAL")"

# Add remaining characters
for ((i=4;i<LENGTH;i++)); do
	PASSWORD+=$(pick "$ALL")
done

# Shuffle using pure Bash
chars=()
for ((i=0;i<${#PASSWORD};i++)); do
	chars+=("${PASSWORD:i:1}")
done

# Shuffle password characters securely using Fisher-Yates
for ((i=${#chars[@]}-1;i>0;i--)); do
	j=$((RANDOM%(i+1)))
	t=${chars[i]}
	chars[i]=${chars[j]}
	chars[j]=$t
done

PASSWORD=$(printf "%s" "${chars[@]}")

# Sanitize filename
SAFE_NAME=$(echo "$PASSWORD_NAME" | tr '/\\?%*:|"<> ' '_')
SAVE_PATH="$SAVE_FOLDER/$SAFE_NAME.txt"

# Save password
printf "%s\n%s\n" "$SAFE_NAME" "$PASSWORD" > "$SAVE_PATH"

# Display password
PROMPT "Generated password: $SAFE_NAME

$PASSWORD"

LOG blue "Generated password for: $SAFE_NAME"
LOG green "Password: $PASSWORD"
LOG yellow "Password saved to:
$SAVE_PATH"
