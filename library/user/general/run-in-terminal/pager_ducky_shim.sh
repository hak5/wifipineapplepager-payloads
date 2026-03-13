#!/bin/bash
# pager_ducky_shim.sh
# Shim to run WiFi Pineapple Pager payloads in terminal

# ---------- UI / LOGGING ----------
LOG() {
  local msg="$*"

  # Remove leading color words used by Pager payloads
  msg=$(echo "$msg" | sed -E 's/^(red|green|blue|yellow|purple|cyan|white|black|orange)[[:space:]]+//I')

  # Preserve newlines if payload uses \n
  echo -e "[*] $msg"
}

ALERT() {
  echo "[ALERT] $*" >&2
}

ERROR_DIALOG() {
  echo "[ERROR] $*" >&2
}

PROMPT() {
  read -p "$* (Press ENTER)"
}

CONFIRMATION_DIALOG() {
    while true; do
        read -p "$* [y/N]: " yn
        case "$yn" in
            [Yy]* )
                echo 0
                return 0
                ;;
            [Nn]*|"" )
                echo 1
                return 1
                ;;
            * )
                echo "Please answer yes (y) or no (n)."
                ;;
        esac
    done
}


# ---------- INPUT ----------
TEXT_PICKER() {
  read -p "$1: " _TEXT_PICKER_RESULT
  echo "$_TEXT_PICKER_RESULT"
}

NUMBER_PICKER() {
  read -p "$1: " _NUMBER_PICKER_RESULT
  echo "$_NUMBER_PICKER_RESULT"
}

IP_PICKER() {
  read -p "$1 (IPv4): " _IP_PICKER_RESULT
  echo "$_IP_PICKER_RESULT"
}

MAC_PICKER() {
  read -p "$1 (MAC): " _MAC_PICKER_RESULT
  echo "$_MAC_PICKER_RESULT"
}

WAIT_FOR_BUTTON_PRESS() {
  read -p "Press ENTER to simulate button [$1]"
}

WAIT_FOR_INPUT() {
  read -p "Press ENTER to continue"
}

# ---------- FEEDBACK ----------
START_SPINNER() {
  echo "[...] Spinner started"
}

STOP_SPINNER() {
  echo "[✓] Spinner stopped"
}

# ---------- SAFETY ----------
export -f LOG ALERT ERROR_DIALOG PROMPT CONFIRMATION_DIALOG
export -f TEXT_PICKER NUMBER_PICKER IP_PICKER MAC_PICKER
export -f WAIT_FOR_BUTTON_PRESS WAIT_FOR_INPUT
export -f START_SPINNER STOP_SPINNER
