#!/bin/bash

# Title: Translator
# Description: Translate text into 39 languages with reverse translation.
# Author: spywill
# Version: 1.1

# Available languages
LANG_CODES=(
	es fr de it pt ru ar tr vi pl nl id ur fa
	ja zh-CN zh-TW ko el hi he th sv da fi no
	cs ro hu uk bn ta ms tl sw bg hr sk sr
)

LANG_NAMES=(
	"Spanish" "French" "German" "Italian" "Portuguese"
	"Russian" "Arabic" "Turkish" "Vietnamese" "Polish"
	"Dutch" "Indonesian" "Urdu" "Persian"
	"Japanese" "Chinese (Simplified)" "Chinese (Traditional)"
	"Korean" "Greek" "Hindi" "Hebrew" "Thai" "Swedish"
	"Danish" "Finnish" "Norwegian" "Czech" "Romanian"
	"Hungarian" "Ukrainian" "Bengali" "Tamil" "Malay"
	"Filipino" "Swahili" "Bulgarian" "Croatian"
	"Slovak" "Serbian"
)

# Check internet connection
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	ERROR_DIALOG "Internet connection required."
	exit 0
fi

# Check jq
if ! command -v jq >/dev/null 2>&1; then
	ERROR_DIALOG "jq is required to process translations."
	exit 0
fi

# Translation function with fallback support
translate() {
	local text="$1"
	local target="$2"
	local response
	local result

	# First Google Translate endpoint
	response=$(curl -fsS --get \
		--connect-timeout 5 \
		--max-time 15 \
		-A "Mozilla/5.0" \
		--data-urlencode "client=gtx" \
		--data-urlencode "sl=auto" \
		--data-urlencode "tl=$target" \
		--data-urlencode "dt=t" \
		--data-urlencode "q=$text" \
		"https://translate.googleapis.com/translate_a/single" 2>/dev/null)

	# Extract translation
	if [ -n "$response" ]; then
		result=$(printf '%s' "$response" | jq -er \
			'[.[0][][0] // empty] | join("") | select(length > 0)' 2>/dev/null)
	fi

	# Second endpoint if first fails
	if [ -z "$result" ]; then
		response=$(curl -fsS --get \
			--connect-timeout 5 \
			--max-time 15 \
			-A "Mozilla/5.0" \
			--data-urlencode "client=dict-chrome-ex" \
			--data-urlencode "sl=auto" \
			--data-urlencode "tl=$target" \
			--data-urlencode "q=$text" \
			"https://clients5.google.com/translate_a/t" 2>/dev/null)

		# Extract fallback response
		if [ -n "$response" ]; then
			result=$(printf '%s' "$response" | jq -er \
				'if (.[0][0] | type) == "string" then .[0][0] else empty end' 2>/dev/null)
		fi
	fi

	# Return translation
	if [ -n "$result" ]; then
		printf '%s\n' "$result"
		return 0
	fi
	return 1
}

# Main menu loop
while true; do
	LANGUAGE=$(LIST_PICKER "Choose a language" \
		"${LANG_NAMES[@]}" \
		"All Languages" \
		"Reverse Translation" \
		"Exit" \
		"Exit") || exit 0

	# Exit
	if [ -z "$LANGUAGE" ] || [ "$LANGUAGE" = "Exit" ]; then
		LOG yellow "Translator closed."
		exit 0
	fi

	# Reverse translation
	if [ "$LANGUAGE" = "Reverse Translation" ]; then
		if [ -z "$LAST_TRANSLATION" ] || [ -z "$LAST_LANGUAGE" ]; then
			LOG red "No previous translation available."
			PROMPT "Translate something first before using Reverse Translation."
			continue
		fi

		LOG yellow "Reversing $LAST_LANGUAGE to English..."
		REVERSED=$(translate "$LAST_TRANSLATION" "en")

		if [ $? -ne 0 ] || [ -z "$REVERSED" ]; then
			LOG red "Reverse translation failed."
			continue
		fi

		PROMPT "Reverse Translation

		Original English:
		$LAST_INPUT

		$LAST_LANGUAGE:
		$LAST_TRANSLATION

		Back to English:
		$REVERSED"

		LOG ""
		LOG yellow "Original English:"
		LOG blue "$LAST_INPUT"
		LOG ""
		LOG yellow "$LAST_LANGUAGE:"
		LOG blue "$LAST_TRANSLATION"
		LOG ""
		LOG yellow "Reverse Translation (English):"
		LOG green "$REVERSED"

		WAIT_FOR_BUTTON_PRESS A
		continue
	fi

	# Enter text to translate
	INPUT=$(TEXT_PICKER "Enter text to translate" "Hello, how are you today?") || exit 0

	if [ -z "$INPUT" ]; then
		LOG red "No text entered."
		continue
	fi

	# Translate into all languages
	if [ "$LANGUAGE" = "All Languages" ]; then
		spinnerid=$(START_SPINNER "Translating all languages...")
		LOG yellow "Translating into all languages..."
		LOG ""

		for i in "${!LANG_CODES[@]}"; do
			TARGET="${LANG_CODES[$i]}"
			LANG_NAME="${LANG_NAMES[$i]}"

			LOG yellow "$LANG_NAME"
			TRANSLATED=$(translate "$INPUT" "$TARGET")

			if [ $? -eq 0 ] && [ -n "$TRANSLATED" ]; then
				LOG blue "$TRANSLATED"
				LAST_INPUT="$INPUT"
				LAST_TRANSLATION="$TRANSLATED"
				LAST_LANGUAGE="$LANG_NAME"
			else
				STOP_SPINNER ${spinnerid}
				LOG red "Translation failed."
			fi
			LOG ""
		done
		STOP_SPINNER ${spinnerid}

		PROMPT "All language translations completed.
		You can now select Reverse Translation."

		WAIT_FOR_BUTTON_PRESS A
		continue
	fi

	# Find selected language code
	TARGET=""

	for i in "${!LANG_NAMES[@]}"; do
		if [ "$LANGUAGE" = "${LANG_NAMES[$i]}" ]; then
			TARGET="${LANG_CODES[$i]}"
			break
		fi
	done

	if [ -z "$TARGET" ]; then
		LOG red "Invalid language selection."
		continue
	fi

	# Translate
	LOG ""
	LOG yellow "Translating into $LANGUAGE..."

	TRANSLATED=$(translate "$INPUT" "$TARGET")

	if [ $? -ne 0 ] || [ -z "$TRANSLATED" ]; then
		LOG red "Translation failed."
		LOG yellow "Check your internet connection."
		continue
	fi

	# Save last successful translation
	LAST_INPUT="$INPUT"
	LAST_TRANSLATION="$TRANSLATED"
	LAST_LANGUAGE="$LANGUAGE"

	# Display result
	PROMPT "$LANGUAGE:

	$TRANSLATED"
	LOG ""
	LOG yellow "$LANGUAGE:"
	LOG blue "$TRANSLATED"

	WAIT_FOR_BUTTON_PRESS A
done
