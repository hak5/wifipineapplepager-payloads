#!/usr/bin/env bash
# Title: Button LED Control
# Description: Enable or disable A/B button LEDs
# Author: RootJunky
# Version: 1

LED_A="/sys/devices/platform/leds/leds/a-button-led/brightness"
LED_B="/sys/devices/platform/leds/leds/b-button-led/brightness"


LOG
LOG "Button LED Control"
LOG "Turn OFF B & A buttons"
LOG "----------------------"
LOG "0) Disable button LEDs"
LOG "1) Enable button LEDs"
LOG

LOG green "Press the GREEN button once ready"
WAIT_FOR_BUTTON_PRESS A

CHOICE=$(NUMBER_PICKER "Enter a number" 0)

if [[ "$CHOICE" != "0" && "$CHOICE" != "1" ]]; then
  LOG "Invalid choice."
  exit 1
fi

echo "$CHOICE" > "$LED_A" 2>/dev/null
echo "$CHOICE" > "$LED_B" 2>/dev/null

if [[ "$CHOICE" == "0" ]]; then
  LOG "Button LEDs DISABLED."
else
  LOG "Button LEDs ENABLED."
fi