#!/bin/bash
# Title:                FirewallSwitcher
# Description:          Toggles the firewall on and off for SSH/Virtual Pager access in Client Mode
# Note:                 Firewall automatically re-enables on reboot
# Author:               r3dfish
# Version:              1.0

# Options
SWITCHER_STATUS="Disable"

# Check to see if the firewall is running
LOG "Checking if Firewall is enabled"
if nft list tables | grep fw4; then
	LOG "Firewall is running!"
else
	LOG "Firewall is not running."
	SWITCHER_STATUS="Enable"
fi

LOG "Launching switcher dialog..."

resp=$(CONFIRMATION_DIALOG $SWITCHER_STATUS " Firewall?")
case $? in
    $DUCKYSCRIPT_REJECTED)
        LOG "Dialog rejected"
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred"
        exit 1
        ;;
esac

case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        LOG "User selected yes"
	if [[ $SWITCHER_STATUS == "Enable" ]]; then
		fw4 start
	else
		fw4 stop
	fi
        ;;
    $DUCKYSCRIPT_USER_DENIED)
        LOG "User selected no"
	LOG "No action taken"
        ;;
    *)
        LOG "Unknown response: $resp"
        ;;
esac

if nft list tables | grep fw4; then
	LOG "Firewall is running!"
else
	LOG "Firewall is not running."
fi
