#!/bin/bash
# Title: Connect_Host_Discovery
# Version: 1.3
# Author: Stuffy24

set -eu

# ----------------------------
# Config
# ----------------------------
WIFI_IF="wlan0cli"
BAND="ANY"
SECURE_MODE_DEFAULT="psk2"
CLIENT_READY_WAIT_SEC="60"
MGMT_SUBNET_PREFIX="172.16.52."

LOOTDIR="/root/loot/recon_connect_clientmode"
mkdir -p "$LOOTDIR"
TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="$LOOTDIR/connect_${TS}.log"

logf() { printf "%s\n" "$1" >> "$LOGFILE"; }
log_both() { LOG "$1"; logf "$1"; }

ui_prompt_ack() {
  PROMPT "${1:-Done. Press any button.}" >/dev/null 2>&1 || true
  WAIT_FOR_BUTTON_PRESS >/dev/null 2>&1 || true
}

ui_error_ack() {
  ERROR_DIALOG "${1:-Error}" "${2:-See log: $LOGFILE}" >/dev/null 2>&1 || true
  WAIT_FOR_BUTTON_PRESS >/dev/null 2>&1 || true
}

# ----------------------------
# Authorization confirmation
# ----------------------------
CONFIRMATION_DIALOG "Authorization Required" \
"This payload is intended for networks you own or have explicit permission to assess.Press CONFIRM to continue." \
|| { ui_prompt_ack "Cancelled."; exit 0; }

# ----------------------------
# Recon-selected AP vars
# ----------------------------
SSID="${_RECON_SELECTED_AP_SSID:-}"
BSSID="${_RECON_SELECTED_AP_BSSID:-}"
CHAN="${_RECON_SELECTED_AP_CHANNEL:-}"
ENC="${_RECON_SELECTED_AP_ENCRYPTION_TYPE:-}"
OUI="${_RECON_SELECTED_AP_OUI:-}"

if [ -z "$SSID" ]; then
  ui_error_ack "No SSID selected" "Select an AP in Recon (Target page) and run again."
  exit 1
fi

{
  echo "=== Recon Connect Subnet Vars @ $TS ==="
  echo "SSID: $SSID"
  echo "BSSID: ${BSSID:-<unknown>}"
  echo "CHAN: ${CHAN:-<unknown>}"
  echo "ENC:  ${ENC:-<unknown>}"
  echo "OUI:  ${OUI:-<unknown>}"
  echo "Log:  $LOGFILE"
  echo
} >> "$LOGFILE"

log_both "Selected AP: SSID=$SSID ENC=${ENC:-?} CHAN=${CHAN:-?}"
log_both "Log: $LOGFILE"

# ----------------------------
# Connect (open vs secured)
# ----------------------------
ENC_LC="$(echo "${ENC:-}" | tr '[:upper:]' '[:lower:]')"
is_open() {
  [ -z "$ENC_LC" ] && return 0
  echo "$ENC_LC" | grep -Eq '^(open|none|noenc|unencrypted|opn)$'
}

MODE=""
PASS=""
if ! is_open; then
  PASS="$(TEXT_PICKER "Password for: $SSID" "")" || exit 0
  MODE="$(TEXT_PICKER "Auth mode (default psk2)" "$SECURE_MODE_DEFAULT")" || exit 0
fi

log_both "Connecting on interface $WIFI_IF..."
set +e
if is_open; then
  WIFI_CONNECT "$WIFI_IF" "$SSID" "open" "" "$BAND" >> "$LOGFILE" 2>&1
else
  WIFI_CONNECT "$WIFI_IF" "$SSID" "$MODE" "$PASS" "$BAND" >> "$LOGFILE" 2>&1
fi
CONNECT_RC=$?
set -e
log_both "WIFI_CONNECT return code: $CONNECT_RC"

# Wait for non-management IPv4/CIDR
READY=0
CIDR=""
for _i in $(seq 1 "$CLIENT_READY_WAIT_SEC"); do
  CIDR="$(ip -4 -o addr show dev "$WIFI_IF" 2>/dev/null | awk '{print $4}' | head -n 1 || true)"
  if [ -n "$CIDR" ] && ! echo "$CIDR" | grep -q "^${MGMT_SUBNET_PREFIX}"; then
    READY=1
    break
  fi
  sleep 1
done

if [ "$READY" -ne 1 ]; then
  ui_error_ack "Client not ready" "No client IPv4/CIDR on $WIFI_IF after ${CLIENT_READY_WAIT_SEC}s.\nLog: $LOGFILE"
  # Best-effort disconnect before exiting
  WIFI_DISCONNECT "$WIFI_IF" >> "$LOGFILE" 2>&1 || true
  exit 1
fi

# ----------------------------
# Subnet / Network variables
# ----------------------------
IP="${CIDR%/*}"
PREFIX="${CIDR#*/}"

GATEWAY="$(ip -4 route show dev "$WIFI_IF" 2>/dev/null | awk '/^default/ {print $3; exit}' || true)"

NETWORK_CIDR="$(ip -4 route show dev "$WIFI_IF" 2>/dev/null | awk '$1 ~ /\/[0-9]+/ && $0 ~ /proto kernel/ {print $1; exit}' || true)"
[ -z "$NETWORK_CIDR" ] && NETWORK_CIDR="$CIDR"

NETWORK_IP="${NETWORK_CIDR%/*}"
NETWORK_PREFIX="${NETWORK_CIDR#*/}"

A="$(echo "$IP" | cut -d. -f1)"
B="$(echo "$IP" | cut -d. -f2)"
C="$(echo "$IP" | cut -d. -f3)"
BASE24="${A}.${B}.${C}."
HOST_RANGE_24="${BASE24}1-${BASE24}254"

{
  echo "---- Subnet Vars ----"
  echo "WIFI_IF=$WIFI_IF"
  echo "CIDR=$CIDR"
  echo "IP=$IP"
  echo "PREFIX=$PREFIX"
  echo "GATEWAY=${GATEWAY:-<none>}"
  echo "NETWORK_CIDR=$NETWORK_CIDR"
  echo "NETWORK_IP=$NETWORK_IP"
  echo "NETWORK_PREFIX=$NETWORK_PREFIX"
  echo "BASE24=$BASE24"
  echo "HOST_RANGE_24=$HOST_RANGE_24"
  echo
  echo "---- Routing Sanity ----"
  ip -4 addr show dev "$WIFI_IF" 2>&1 || true
  ip -4 route show dev "$WIFI_IF" 2>&1 || true
  echo
} >> "$LOGFILE"

log_both "Connected: $WIFI_IF CIDR=$CIDR GW=${GATEWAY:-<none>} NET=$NETWORK_CIDR"

# ----------------------------
# Host discovery (Nmap)
# ----------------------------
DISCOVERY_OUT="$LOOTDIR/hostdiscovery_${TS}.out"
UP_HOSTS_TXT="$LOOTDIR/hosts_up_${TS}.txt"

if [ "${NETWORK_PREFIX:-}" = "24" ] && [ -n "${BASE24:-}" ]; then
  TARGET_CIDR="${BASE24}0/24"
else
  TARGET_CIDR="$NETWORK_CIDR"
fi

log_both "Running host discovery with nmap against: $TARGET_CIDR"
set +e
nmap -sn -n -S "$IP" --reason "$TARGET_CIDR" -oG "$DISCOVERY_OUT" >> "$LOGFILE" 2>&1
RC=$?
set -e
log_both "Nmap return code: $RC"
log_both "Discovery output: $DISCOVERY_OUT"

grep -E "Status: Up" "$DISCOVERY_OUT" | awk '{print $2}' > "$UP_HOSTS_TXT" 2>>"$LOGFILE" || true
HOST_COUNT="$(wc -l < "$UP_HOSTS_TXT" 2>/dev/null || echo 0)"
log_both "Up hosts list: $UP_HOSTS_TXT"
log_both "Up hosts count: $HOST_COUNT"

# ----------------------------
# Disconnect + finish
# ----------------------------
log_both "Disconnecting $WIFI_IF"
WIFI_DISCONNECT "$WIFI_IF" >> "$LOGFILE" 2>&1 || true

ui_prompt_ack "Complete. ${HOST_COUNT} hosts found. Log saved: ${LOGFILE}"
exit 0
