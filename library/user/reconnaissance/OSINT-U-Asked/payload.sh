#!/bin/bash
# Title: OSINT-U-Asked
# Author: Hackazillarex
# Description: Lightweight OSINT payload for username recon, driven by a JSON file
# Version: 1.0
# Credits: Sherlock-Project for use of the data.json file

#############################
# Configuration
#############################
LOOTDIR="/root/loot/osint"
SESSION_DIR="$LOOTDIR/session_$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="/root/payloads/user/reconnaissance/OSINT-U-Asked"
SITES_JSON="$SCRIPT_DIR/data.json"
mkdir -p "$SESSION_DIR"

############################
# Pre-Flight Checks
############################

LOG blue "Running pre-flight checks..."

############################
# 1. Check Internet Connectivity
############################

LOG blue "Checking internet connectivity..."

# Check raw connectivity (Cloudflare DNS)
if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    LOG "No internet connectivity detected. Exiting."
    exit 1
fi

# Check DNS resolution
if ! nslookup google.com >/dev/null 2>&1; then
    LOG "DNS resolution failed. Exiting."
    exit 1
fi

LOG green "Internet connectivity confirmed."

############################
# 2. Check for curl
############################

if ! command -v curl >/dev/null 2>&1; then
    LOG "curl is not installed. Installing via opkg..."
    opkg update
    opkg install curl

    if ! command -v curl >/dev/null 2>&1; then
        LOG "Failed to install curl. Exiting."
        exit 1
    fi
else
    LOG green "curl is installed."
fi

############################
# 3. Check for jq
############################

if ! command -v jq >/dev/null 2>&1; then
    LOG "jq is not installed. Installing via opkg..."
    opkg update
    opkg install jq

    if ! command -v jq >/dev/null 2>&1; then
        LOG "Failed to install jq. Exiting."
        exit 1
    fi
else
    LOG green "jq is installed."
fi

LOG green "All pre-flight checks passed."

############################
# Username input
############################

LOG "Launching text picker..."
resp=$(TEXT_PICKER "Enter username to search" "example")

case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Dialog rejected"
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred"
        exit 1
        ;;
esac

USERNAME="$resp"
LOG blue "Username selected: $USERNAME"
LOG blue "Starting OSINT recon..."

############################
# Target Sites and Checks
############################

FOUND_SITES=""
FOUND_URLS=""

for SITE_NAME in $(jq -r 'keys[]' "$SITES_JSON"); do
  NAME=$(echo "$SITE_NAME" | tr -d '"')
  URL=$(jq -r ".$SITE_NAME.url" "$SITES_JSON" | sed "s/{}/$USERNAME/g")
  ERROR_TYPE=$(jq -r ".$SITE_NAME.errorType" "$SITES_JSON")

  LOG blue "Checking $NAME..."

  if [ "$ERROR_TYPE" == "status_code" ]; then
    if curl -s -o /dev/null -w "%{http_code}" "$URL" | grep -q "404\|400\|403"; then
      LOG "$NAME: Not found"
    else
      LOG green "$NAME: FOUND! $URL"
      FOUND_SITES="$FOUND_SITES $NAME "
      FOUND_URLS="$FOUND_URLS $URL "
    fi

  elif [ "$ERROR_TYPE" == "message" ]; then
    ERROR_MSG=$(jq -r ".$SITE_NAME.errorMsg" "$SITES_JSON")
    if curl -s "$URL" | grep -q "$ERROR_MSG"; then
      LOG "$NAME: Not found"
    else
      LOG green "$NAME: FOUND! $URL"
      FOUND_SITES="$FOUND_SITES $NAME "
      FOUND_URLS="$FOUND_URLS $URL "
    fi

  elif [ "$ERROR_TYPE" == "response_url" ]; then
      ERROR_URL=$(jq -r ".$SITE_NAME.errorUrl" "$SITES_JSON")
      ACTUAL_URL=$(curl -s -L -w "%{url_effective}" "$URL" -o /dev/null)
      if [ "$ACTUAL_URL" == "$ERROR_URL" ]; then
          LOG "$NAME: Not found"
      else
          LOG green "$NAME: FOUND! $URL"
          FOUND_SITES="$FOUND_SITES $NAME "
          FOUND_URLS="$FOUND_URLS $URL "
      fi
  else
    LOG "Skipping Site: $ERROR_TYPE"
  fi
done

############################
# Summary
############################

FOUND_LOOT="$SESSION_DIR/found_accounts.txt"

if [ -n "$FOUND_SITES" ]; then
    LOG blue "Recon complete — accounts found on: $FOUND_SITES"
    LOG green "Found URLs:"

    echo "$FOUND_URLS" | tr ' ' '\n' > "$FOUND_LOOT"

    echo "$FOUND_URLS" | tr ' ' '\n' | while read -r url; do
        LOG green "$url"
    done
else
    LOG blue "Recon complete — no accounts found"
    echo "No accounts found for $USERNAME" > "$FOUND_LOOT"
fi

exit 0
