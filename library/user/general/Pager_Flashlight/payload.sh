#!/bin/bash

# Title: Pager Flashlight
# Description: Full-screen flashlight.
# Author: spywill
# Version: 1.0

WHITE="${_PAYLOAD_HOME}/white.png"
ORANGE="${_PAYLOAD_HOME}/orange.png"
RED="${_PAYLOAD_HOME}/red.png"
BLUE="${_PAYLOAD_HOME}/blue.png"
GREEN="${_PAYLOAD_HOME}/green.png"
YELLOW="${_PAYLOAD_HOME}/yellow.png"
BLACK="${_PAYLOAD_HOME}/black.png"

PROMPT "Select a full-screen light effect.

Flashlight - solid white"

while true; do
	choice=$(LIST_PICKER \
	"Flashlight" \
		"Flashlight" \
		"Red" \
		"Blue" \
		"Orange" \
		"Black" \
		"Green" \
		"Yellow" \
		"Exit" \
		"Exit") || break

	case "$choice" in
		"Flashlight")
			PROMPT_IMAGE "$WHITE"
		;;
		"Red")
			PROMPT_IMAGE "$RED"
		;;
		"Blue")
				PROMPT_IMAGE "$BLUE"
		;;
		"Orange")
				PROMPT_IMAGE "$ORANGE"
		;;
		"Green")
				PROMPT_IMAGE "$GREEN"
		;;
		"Yellow")
				PROMPT_IMAGE "$YELLOW"
		;;
		"Black")
				PROMPT_IMAGE "$BLACK"
		;;
		"Exit"|"")
			break
		;;
	esac
done
