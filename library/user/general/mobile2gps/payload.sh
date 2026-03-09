#!/bin/bash
# Title: mobile2gps
# Description: Use your mobile phone as the Pager's GPS.
# Author: Ryan Pohlner (@Spectracide on Discord)
# Version: 1.5
# Category: General

# Check if the mobile2gps binary exists
if [ ! -f ./mobile2gps ]; then
  LOG red "ERROR: mobile2gps binary not found!"
  LOG yellow "Please see the README for build instructions."
  LOG ""
  LOG yellow "Would you like to download the latest binary from GitHub?"
  LOG ""
  LOG red "You should exit, review the source code, and build it yourself."
  LOG ""
  LOG cyan "Press [▲] to DOWNLOAD"
  LOG red "Press [▼] to EXIT"
  LOG ""
  
  choice=$(WAIT_FOR_INPUT)
  
  if [ "$choice" = "UP" ]; then
    LOG yellow "Downloading latest binary from GitHub..."
    
    if wget -q -O mobile2gps https://github.com/ryanpohlner/mobile2gps/releases/latest/download/mobile2gps 2>/dev/null; then
      LOG green "Download complete!"
    else
      LOG red "Download failed."
      LOG yellow "Please check the Pager's internet connection or download manually from:"
      LOG cyan "https://github.com/ryanpohlner/mobile2gps/releases"
      exit
    fi
  else
    LOG "Exiting."
    exit
  fi
fi

# Make sure the binary is executable
chmod +x ./mobile2gps

# Main menu loop
while true; do
  LOG ""
  LOG green "Press [▲] to START the mobile2gps server"
  LOG red "Press [▼] to STOP the mobile2gps server"
  LOG cyan "Press [◀] for HELP"
  LOG yellow "Press [▶] to TEST"
  LOG ""

  choice=$(WAIT_FOR_INPUT)

  if [ "$choice" = "UP" ]; then
    if pgrep mobile2gps > /dev/null; then
      LOG red "mobile2gps is already running!"
    else
      LOG yellow "Starting..."
      ./mobile2gps &
      LOG green "Started!"
    fi
  elif [ "$choice" = "DOWN" ]; then
    if pgrep mobile2gps > /dev/null; then
      LOG yellow "Stopping..."
      killall mobile2gps
      LOG green "Stopped!"
    else
      LOG red "mobile2gps is not running!"
    fi
  elif [ "$choice" = "LEFT" ]; then
    LOG cyan "1. Enable the Pager's Management AP"
    LOG cyan "2. Connect to the Management AP on your mobile device"
    LOG cyan "3. Start the mobile2gps server"
    LOG cyan "4. Open your mobile device's browser"
    LOG cyan "5. Go to https://172.16.52.1:1993"
    LOG cyan "6. Tap Start"
    LOG cyan "7. Check Settings→GPS on the Pager or press ▶ at the mobile2gps menu to check your location"
    LOG ""
    LOG "Press any button to continue."
    __button=$(WAIT_FOR_INPUT)
    LOG ""
    LOG cyan "Your mobile device's screen must be on and the mobile2gps page must be open in the browser to send location updates."
    LOG cyan "Enable Precise Location in your browser's privacy/location settings."
    LOG cyan "Accuracy must be <100m for a valid fix."
    LOG cyan "You can close this payload after the server is started."
    LOG ""
    LOG "Press any button to return to the menu."
    __button=$(WAIT_FOR_INPUT)
  elif [ "$choice" = "RIGHT" ]; then
    if pgrep mobile2gps > /dev/null; then
      LOG green "mobile2gps is running."
      coords=$(gpspipe --json -x 3 | tail -n 1 | jq -r '"\(.lat), \(.lon)"')
      if echo "$coords" | grep -q "null"; then
        LOG red "Unable to obtain coordinates from gpspipe.\nClient is not connected or position is not accurate."
      else
        LOG green "Your coordinates are:\n$coords"
      fi
    else
      LOG red "mobile2gps is not running."
    fi
  else
    LOG "Exiting."
    break
  fi
done
