#!/bin/bash
# Title: Mobile2GPS
# Description: Use your mobile phone as the Pager's GPS.
# Author: Ryan Pohlner (@Spectracide on Discord)
# Version: 2.0
# Category: General

# GPS_CONFIGURE mode selection requires Pager firmware 2.0.0 or newer.
if ! command -v LIST_PICKER >/dev/null 2>&1 ||
   ! command -v GPS_CONFIGURE >/dev/null 2>&1; then
  ERROR_DIALOG "Mobile2GPS requires Pager firmware 2.0.0 or newer."
  exit 1
fi

# Check if the Mobile2GPS binary exists
if [ ! -f ./Mobile2GPS ]; then
  confirmed=$(CONFIRMATION_DIALOG "Server binary missing.
Download Mobile2GPS from GitHub?") || exit 1
  [ "$confirmed" = "1" ] || exit 0

  spinner=$(START_SPINNER "Downloading Mobile2GPS...")
  curl -k -q -L -o Mobile2GPS https://github.com/ryanpohlner/mobile2gps/releases/latest/download/Mobile2GPS 2>/dev/null
  download_status=$?
  STOP_SPINNER "$spinner"
  if [ "$download_status" -ne 0 ]; then
    rm -f ./Mobile2GPS
    ERROR_DIALOG "Download failed.
Check the Pager's internet connection."
    exit 1
  fi
  LOG green "Download complete."
fi

# Make sure the binary is executable
chmod +x ./Mobile2GPS

phone_setup() {
  PROMPT "Enable the Pager's Management AP.
Connect to the Management AP on your mobile device.
Open https://172.16.52.1:1993 using the device's web browser.
Press the Start button on the page."
}

# Refresh server state when the menu opens. Cancelling leaves the server alone.
while true; do
  if pidof Mobile2GPS > /dev/null; then
    choice=$(LIST_PICKER "Mobile2GPS: running" "GPS status" "How to pair" "Stop server" "Exit (server stays on)" "GPS status") || break
  else
    choice=$(LIST_PICKER "Mobile2GPS: stopped" "Start server" "How to pair" "Exit" "Start server") || break
  fi

  case "$choice" in
    "Start server")
      # The server may have been started elsewhere while the picker was open.
      if ! pidof Mobile2GPS > /dev/null; then
        spinner=$(START_SPINNER "Starting server...")
        ./Mobile2GPS &
        server_pid=$!
        # GPS_CONFIGURE may take a few seconds to switch modes and start gpsd.
        server_ready=0
        for attempt in {1..15}; do
          kill -0 "$server_pid" 2>/dev/null || break
          if curl -k -s -f --connect-timeout 1 --max-time 1 -o /dev/null https://127.0.0.1:1993/; then
            server_ready=1
            break
          fi
          sleep 1
        done
        STOP_SPINNER "$spinner"
        if [ "$server_ready" -ne 1 ]; then
          kill "$server_pid" 2>/dev/null
          ERROR_DIALOG "Server failed to start.
Check the payload log for details."
          exit 1
        fi
        LOG green "Server started."
      fi
      ;;
    "Stop server")
      spinner=$(START_SPINNER "Stopping server...")
      killall Mobile2GPS 2>/dev/null
      # Allow time for shutdown without leaving the spinner open indefinitely.
      for attempt in 1 2 3 4 5 6 7 8; do
        pidof Mobile2GPS > /dev/null || break
        sleep 1
      done
      STOP_SPINNER "$spinner"
      if pidof Mobile2GPS > /dev/null; then
        PROMPT "Server is still running.
Try Stop server again."
      else
        LOG green "Server stopped."
      fi
      ;;
    "GPS status")
      if ! pidof Mobile2GPS > /dev/null; then
        PROMPT "Server is stopped.
Start it before checking GPS."
        continue
      fi
      spinner=$(START_SPINNER "Checking GPS...")
      # Read the Pager's selected GPS source; ignore altitude and speed.
      coords=$(GPS_GET) || coords=""
      coords=$(printf '%s\n' "$coords" | awk 'NF >= 2 && ($1 != 0 || $2 != 0) {print $1 ", " $2}')
      STOP_SPINNER "$spinner"
      if [ -n "$coords" ]; then
        PROMPT "GPS fix received:
$coords"
      else
        PROMPT "No valid GPS fix received.
Check the phone page and location permissions."
      fi
      ;;
    "How to pair")
      phone_setup
      ;;
    *) break ;;
  esac
done
