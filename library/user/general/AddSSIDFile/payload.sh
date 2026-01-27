#!/bin/bash
# Title: Add SSID File
# Description: Adds SSIDs in a designated file to the SSID Pool. List must be located in /root/loot/pools/.
# Author: Skinny
# Version: 1.0.6

POOLPATH="/root/loot/pools"

# Searches for the latest modified pool and puts filename in as default filename to upload
DEFAULTFILE=$(ls -t "$POOLPATH"/ 2>/dev/null | head -n 1)
FILENAME="$(TEXT_PICKER "Name of the Pool file." "$DEFAULTFILE")"

FULLPATH="$POOLPATH/$FILENAME"

# Checks to see if file to upload is present
if [ ! -f "$FULLPATH" ]; then
  LOG "File not found: $FILENAME"
  exit 1
fi

LOG " "
LOG "File Found. Uploading Pool"

# Add SSID File to the Pool
PINEAPPLE_SSID_POOL_ADD_FILE $FULLPATH
