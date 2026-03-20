#!/bin/bash

# Title: Morse code
# Author: spywill
# Description:  Morse code player in Bash using RTTTL-style
# Version: 1.0

PROMPT "Title: Morse code

User-entered text as Morse code
with sound (RINGTONE) while blinking
an LED in sync; waits for button
input to continue or exit."

# Morse dictionary
morse_char() {
	case "$1" in
		A) echo ".-" ;;
		B) echo "-..." ;;
		C) echo "-.-." ;;
		D) echo "-.." ;;
		E) echo "." ;;
		F) echo "..-." ;;
		G) echo "--." ;;
		H) echo "...." ;;
		I) echo ".." ;;
		J) echo ".---" ;;
		K) echo "-.-" ;;
		L) echo ".-.." ;;
		M) echo "--" ;;
		N) echo "-." ;;
		O) echo "---" ;;
		P) echo ".--." ;;
		Q) echo "--.-" ;;
		R) echo ".-." ;;
		S) echo "..." ;;
		T) echo "-" ;;
		U) echo "..-" ;;
		V) echo "...-" ;;
		W) echo ".--" ;;
		X) echo "-..-" ;;
		Y) echo "-.--" ;;
		Z) echo "--.." ;;
		0) echo "-----" ;;
		1) echo ".----" ;;
		2) echo "..---" ;;
		3) echo "...--" ;;
		4) echo "....-" ;;
		5) echo "....." ;;
		6) echo "-...." ;;
		7) echo "--..." ;;
		8) echo "---.." ;;
		9) echo "----." ;;
		*) echo "" ;;
	esac
}

# Beep function
morse_to_rtttl() {
	text=${1^^}   # FIXED uppercase
	result=""

	for (( i=0; i<${#text}; i++ )); do
		char="${text:$i:1}"

		if [[ "$char" == " " ]]; then
			result+="p,p,p,"
			continue
		fi

		code=$(morse_char "$char")
		[[ -z "$code" ]] && continue

		for (( j=0; j<${#code}; j++ )); do
			symbol="${code:$j:1}"

			if [[ "$symbol" == "." ]]; then
				result+="16c,"
			elif [[ "$symbol" == "-" ]]; then
				result+="4c,"
			fi
		done

		result+="p,"
	done
	# safety fallback
	[[ -z "$result" ]] && result="8c"
	echo -n "Morse_code:d=4,o=5,b=285:${result%,}"
}

# LED blinking in sync with the Morse
play_led_morse() {
	text=${1^^}
	UNIT=0.1       # base time unit in seconds

	# pre-calculate durations
	DOT=$UNIT           # dot duration = 0.1s
	DASH=0.3            # dash duration = 3 × DOT
	LETTER_GAP=0.3      # gap between letters = 3 × DOT
	WORD_GAP=0.7        # gap between words = 7 × DOT

	for (( i=0; i<${#text}; i++ )); do
		char="${text:$i:1}"
		if [[ "$char" == " " ]]; then
			LED OFF
			sleep $WORD_GAP
			continue
		fi

		code=$(morse_char "$char")
		[[ -z "$code" ]] && continue

		for (( j=0; j<${#code}; j++ )); do
			symbol="${code:$j:1}"

			if [[ "$symbol" == "." ]]; then
				LED G
				sleep $DOT
				LED OFF
			elif [[ "$symbol" == "-" ]]; then
				LED R
				sleep $DASH
				LED OFF
			fi
			sleep $DOT  # gap between symbols
		done
		sleep $LETTER_GAP  # gap between letters
	done
	LED OFF
}

# Main loop
while true; do
	msg=$(TEXT_PICKER "Enter Morse code text:" "Hak5 pager")

	RTTTL=$(morse_to_rtttl "$msg")

	LOG yellow "$msg"
	LOG blue "Playing: $RTTTL"

	play_led_morse "$msg" &
	RINGTONE "$RTTTL"

	LOG green "Press A to exit, any other button to continue..."
	button=$(WAIT_FOR_INPUT)

	if [[ "$button" == "A" ]]; then
		LOG red "Exiting..."
		break
	fi
done
