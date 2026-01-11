#!/bin/bash
# Title: mobile2gps
# Description: Use your mobile phone as the Pager's GPS.
# Author: Ryan Pohlner
# Version: 1.2
# Category: General

# Make sure the Go binary is executable
chmod +x ./mobile2gps

LOG ""
LOG green "Press [▲] to START the mobile2gps server"
LOG red "Press [▼] to STOP the mobile2gps server"
LOG cyan "Press [◀] for help"
LOG yellow "Press [▶] for a debug log"
LOG ""

choice=$(WAIT_FOR_INPUT)

if [ "$choice" = "UP" ]; then
  killall mobile2gps
  LOG "Starting..."
  ./mobile2gps &
  LOG "Started!"
  LOG ""
  LOG cyan "1. Connect to the Management AP on your mobile device\n2. Open your mobile device's browser\n3. Go to https://172.16.52.1:1993\n4. Tap Start\n5. Check Settings▶GPS on the Pager"
elif [ "$choice" = "DOWN" ]; then
  LOG "Stopping..."
  killall mobile2gps
  LOG "Stopped!"
elif [ "$choice" = "LEFT" ]; then
  LOG "1. Enable the Pager's Management AP\n2. Connect to the Management AP on your device\n3. Start the mobile2gps server\n4. Open your mobile device's browser\n5. Go to https://172.16.52.1:1993\n6. Tap Start\n7. Check Settings▶GPS on the Pager"
  LOG ""
  LOG "Your device's screen must be on and the mobile2gps page open to send updates.\nEnable Precise Location in your browser's privacy/location settings.\nAccuracy must be within 100m for the GPS messages to be marked valid."
elif [ "$choice" = "RIGHT" ]; then
  LOG "Running 'gpspipe -r' for 3 seconds..."
  timeout 3s gpspipe -r > ./debug.log
  LOG "Done. Log:"
  LOG ""
  LOG "$(cat debug.log)"
  LOG ""
  LOG "If the server and client are working, you should see \$GPRMC messages in the log above."
  LOG "In the third \$GPRMC field, A = Valid, V = Invalid."
else
  LOG "Exiting."
fi
