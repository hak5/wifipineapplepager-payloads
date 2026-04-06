#!/bin/bash
# Title: Demo LIST_PICKER
# Author: Hak5Darren
# Description: A simple demo of the new LIST_PICKER DuckyScript command for convenient payload navigation.

IP_ADDRESS="8.8.8.8"

while true; do
  resp=$(LIST_PICKER "Main Menu" "Ping $IP_ADDRESS" "Configure IP" "About" "Exit" "Ping $IP_ADDRESS")

  case "$resp" in
    "Configure IP")
      IP_ADDRESS=$(IP_PICKER "IP Address?" "$IP_ADDRESS")
      ;;

    "Ping $IP_ADDRESS")
      __spinnerid=$(START_SPINNER "Pinging $IP_ADDRESS")
      if ping -c 1 "$IP_ADDRESS" > /dev/null 2>&1; then
        STOP_SPINNER ${__spinnerid}
        RINGTONE bonus
        PROMPT "Ping Successful"
      else
        STOP_SPINNER ${__spinnerid}
        RINGTONE halt
        PROMPT "Ping Unsuccessful"
      fi
      ;;

    "About")
      # Example of a nested list
      LIST_PICKER "This is a nested list" "Demo by @Hak5Darren" "Pager firmware by:" "@dragorn and @Korben" "<- Back" "<- Back"
      # Selection is ignored, so all list items are essentially "<- Back"
      ;;

    "Exit")
      resp=$(CONFIRMATION_DIALOG "Exit Payload?") || exit 1
      if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        exit 0
      fi
      ;;

    *)
      LOG "[!] Unknown selection: $resp"
      # User pressed 'B' most likely
      ;;
  esac
done
