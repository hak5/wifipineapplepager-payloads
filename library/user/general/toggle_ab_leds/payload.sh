#!/bin/bash
# Title: TOGGLE A/B LEDS
# Description: Toggle A and B button LEDS
# Author: jader242
# Version: 1.0

btn_a_path="/sys/devices/platform/leds/leds/a-button-led/brightness"
btn_b_path="/sys/devices/platform/leds/leds/b-button-led/brightness"

btn_a_state=$(cat "$btn_a_path")
btn_b_state=$(cat "$btn_b_path")

if [ "$btn_a_state" -eq 1 ]; then
	echo 0 > "$btn_a_path"
	LOG green "A button off"
else
	echo 1 > "$btn_a_path"
	LOG green "A button on"
fi

if [ "$btn_b_state" -eq 1 ] ; then
	echo 0 > "$btn_b_path"
	LOG green "B button off"
else
	echo 1 > "$btn_b_path"
	LOG green "B button on"
fi

exit 0
