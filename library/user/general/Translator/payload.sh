#!/bin/bash

# Title: Translator
# Author: spywill
# Description:  Translate English to "Spanish" "French" "German" "Italian" "Portuguese" "Russian" "Arabic"
#               "Turkish" "Vietnamese" "Polish" "Dutch" "Indonesian" "Urdu" "Persian"
# Version: 1.0

# Check internet connection
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	LOG green "Online"
	LOG ""
else
	LOG red "Offline internet connection is required exiting"
	exit
fi

PROMPT "Title: Translator

Type something in English
Hello, how are you today?

Here it is in French
Bonjour, comment allez-vous aujourd’hui? 
"

# URL encoder
urlencode() {
	local string="$1"
	local encoded=""
	local i c

	for (( i=0; i<${#string}; i++ )); do
		c="${string:$i:1}"
		case "$c" in
			[a-zA-Z0-9.~_-]) encoded+="$c" ;;
			' ') encoded+="%20" ;;
			*) printf -v hex '%%%02X' "'$c"
				encoded+="$hex" ;;
		esac
	done
	echo "$encoded"
}

# Translate function
translate() {
	local text="$1"
	local target="$2"

	local text_enc
	text_enc=$(urlencode "$text")

	local response
	response=$(curl -s --connect-timeout 5 --max-time 8 "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$target&dt=t&q=$text_enc")

	# safer extraction
	echo "$response" | sed -E 's/\[\[\["([^"]*).*/\1/'
}

# Enter text to be translated
INPUT=$(TEXT_PICKER "Enter text to translate" "Hello how are you today")

# Languages
LANG_CODES=(es fr de it pt ru ar tr vi pl nl id ur fa)

LANG_NAMES=("Spanish" "French" "German" "Italian" "Portuguese" "Russian" "Arabic" \
"Turkish" "Vietnamese" "Polish" "Dutch" "Indonesian" "Urdu" "Persian")

LANGS="es:Spanish fr:French de:German it:Italian pt:Portuguese ru:Russian ar:Arabic \
tr:Turkish vi:Vietnamese pl:Polish nl:Dutch id:Indonesian ur:Urdu fa:Persian"

# Build menu
menu=""
for i in "${!LANG_CODES[@]}"; do
	index=$((i+1))
	menu+="[$index] ${LANG_NAMES[$i]} (${LANG_CODES[$i]})"$'\n'
done

PROMPT "Available languages:
$menu"

# Select a number to translate to selected language
choice=$(NUMBER_PICKER "Choose a number (0 = all)" "0")

# If user picks 0 → translate to all languages
if [ "$choice" = "0" ]; then
	for pair in $LANGS; do
		code=$(echo "$pair" | cut -d':' -f1)
		name=$(echo "$pair" | cut -d':' -f2)
		TRANSLATED=$(translate "$INPUT" "$code")
		LOG yellow "$name:"
		LOG blue "$TRANSLATED"
		LOG ""
	done
	exit
fi

# Otherwise handle single selection
if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#LANG_CODES[@]} ]; then
	TARGET="${LANG_CODES[$((choice-1))]}"
	LANG_NAME="${LANG_NAMES[$((choice-1))]}"

	TRANSLATED=$(translate "$INPUT" "$TARGET")

	PROMPT "$LANG_NAME:
	
	$TRANSLATED"

	LOG yellow "$LANG_NAME:"
	LOG blue "$TRANSLATED"
else
	LOG red "Invalid selection."
fi
