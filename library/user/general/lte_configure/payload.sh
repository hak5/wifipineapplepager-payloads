#!/bin/bash
# Title: LTE Configure
# Description: Configure the Hak5 eLiTE Mobile Broadband Adapter
# Author: Hak5Darren
# Version: 1

dependency_check() {
  LOG green "Checking dependencies"
  # Check for uqmi
  if ! which uqmi >/dev/null 2>&1; then
    LOG yellow "uqmi not found, installing..."
	  # Check Internet connectivity
	  if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	    ERROR_DIALOG "Error: Not connected to the Internet"
	    exit 1
	  fi
    LOG "Updating opkg. This may take a moment."
    opkg update
    LOG "Installing uqmi. This may take a moment."
    opkg install uqmi

    if ! which uqmi >/dev/null 2>&1; then
      ERROR_DIALOG "Error: Failed to install uqmi"
      exit 1
    fi

    LOG green "uqmi installed successfully"
  else
  	LOG green "Dependencies installed"
  fi
}

apn_check() {
  local apn

  apn="$(uci -q get network.lte.apn 2>/dev/null)"

  if [ -z "$apn" ]; then
    LOG yellow "APN not configured"
    configure_apn
  else
    LOG green "APN set: $apn"
  fi
}

configure_apn() {

  PROMPT "The Access Point Name (APN) address of your Mobile Network Operator must be configured for LTE access.\n\nPress any key to configure"

  local apn resp id

  # Prompt for APN
  apn=$(TEXT_PICKER "Set carrier APN" "my_apn")
  case $? in
    $DUCKYSCRIPT_CANCELLED)
      LOG red "User cancelled"
      return 1
      ;;
    $DUCKYSCRIPT_REJECTED)
      LOG red "Dialog rejected"
      return 1
      ;;
    $DUCKYSCRIPT_ERROR)
      LOG red "An error occurred"
      return 1
      ;;
  esac

  # Trim whitespace
  apn="$(echo "$apn" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$apn" ]; then
    LOG red "APN cannot be blank"
    return 1
  fi

  LOG cyan "APN set to: $apn"

  # Confirm apply
  resp=$(CONFIRMATION_DIALOG "Apply network settings for APN '$apn'?")
  case $? in
    $DUCKYSCRIPT_REJECTED)
      LOG red "Dialog rejected"
      return 1
      ;;
    $DUCKYSCRIPT_ERROR)
      LOG red "An error occurred"
      return 1
      ;;
  esac

  case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
      LOG green "User selected yes"
      ;;
    $DUCKYSCRIPT_USER_DENIED)
      LOG yellow "User selected no"
      return 0
      ;;
    *)
      LOG red "Unknown response: $resp"
      return 1
      ;;
  esac

  # Apply config
  LOG cyan "Applying network settings..."
  uci set network.lte="interface"
  uci set network.lte.proto="qmi"
  uci set network.lte.device="/dev/cdc-wdm0"
  uci set network.lte.apn="$apn"
  uci set network.lte.auth="none"
  uci set network.lte.pdptype="ipv4"
  uci commit network
  uci add_list firewall.@zone[1].network="lte"
  uci commit firewall

  # Restart network with spinner
  LOG "Restarting network"
  id=$(START_SPINNER "Restarting network")
  /etc/init.d/network restart
  /etc/init.d/firewall restart
  STOP_SPINNER $id
  LOG green "Network Restarted"

  return 0
}

modem_check() {
  # Check USB
  if lsusb | grep -q "ID 2c7c:0125 Quectel EG25-G"; then
    LOG green "Modem found"
  else
    ERROR_DIALOG "Modem not found. Connect the Hak5 eLiTE Mobile Broadband Adapter and try the LTE Configuration payload again."
    exit 0
  fi
}

lte_status() {
  # Check APN
  local apn
  apn="$(uci -q get network.lte.apn 2>/dev/null)"

  if [ -n "$apn" ]; then
    LOG cyan "Configured APN: $apn"
  else
    LOG yellow "Configured APN: (not set)"
  fi

  # Check USB
  if lsusb | grep -q "ID 2c7c:0125 Quectel EG25-G"; then
    LOG green "Modem found: Quectel EG25-G (2c7c:0125)"
  else
    LOG red "Modem not found: Quectel EG25-G (2c7c:0125)"
    return 1
  fi

  # Check LTE Status
  LOG green "LTE Status:"
  ifstatus lte 2>/dev/null \
    | grep -E '"(up|pending|available|autostart|dynamic|uptime|l3_device|proto)"' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed 's/"//g; s/,$//' \
    | while IFS= read -r line; do
        [ -z "$line" ] && continue
        LOG gray "$line"
      done

  # Check Signal
  LOG green "Signal Status:"
  uqmi -d /dev/cdc-wdm0 --get-signal-info 2>/dev/null \
    | grep -v '[{}]' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | while IFS= read -r line; do
        [ -n "$line" ] && LOG cyan "$line"
    done
}

status_check() {
  local resp

  resp=$(CONFIRMATION_DIALOG "Check LTE Signal/Status?")
  case $? in
    $DUCKYSCRIPT_REJECTED)
      LOG red "Dialog rejected"
      return 1
      ;;
    $DUCKYSCRIPT_ERROR)
      LOG red "An error occurred"
      return 1
      ;;
  esac

  case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
      LOG cyan "Checking LTE signal/status"
      lte_status
      ;;
    $DUCKYSCRIPT_USER_DENIED)
      LOG yellow "User cancelled LTE status check"
      ;;
    *)
      LOG red "Unknown response: $resp"
      ;;
  esac
}


dependency_check
apn_check
modem_check
status_check
