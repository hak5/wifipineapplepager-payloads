#!/bin/bash
# Title: Friendly handshake deleter
# Author: jader242
# Description: Deletes unwanted handshakes from a target MAC
# Version: 1.0

MAC=$(TEXT_PICKER "MAC Address" "")

case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
esac

if [ -z "$MAC" ]; then
        LOG "Empty MAC string"
        exit 1
fi

UPPER_MAC=${MAC^^}
FILES=(/root/loot/handshakes/*$UPPER_MAC*)
COUNT=${#FILES[@]}

CONFIRM=$(CONFIRMATION_DIALOG "$COUNT handshakes will be deleted containing the string $UPPER_MAC, continue?")

case "$CONFIRM" in
        $DUCKYSCRIPT_USER_CONFIRMED)
                rm -f /root/loot/handshakes/*$UPPER_MAC*
                LOG "Removed $COUNT handshakes containing the string $UPPER_MAC. Friendly fire will not be tolerated."
                ;;
        $DUCKYSCRIPT_USER_DENIED)
                LOG "User selected no"
                exit 1
                ;;
esac
