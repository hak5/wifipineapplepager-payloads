#!/bin/bash
# Title: WireGuard Sentinel
# Author: D-L3aN
# Description: Establishes a WireGuard VPN tunnel with health monitoring
#              and automatic reconnection. Supports a primary and backup
#              peer endpoint, logs tunnel statistics, and can run as a
#              background guard that restores the tunnel if it drops.
# Category: remote_access
# Net Mode: Client
# Version: 1.0

# LED State Descriptions
# Magenta Solid - Configuring network
# LED OFF - Waiting for user input
# Cyan Blink 1 Time - Configuration successful
# Green Solid - Tunnel active (guarding)
# Red Blink 2 Times - Connection failed
# Amber Blink 5 Times - Tunnel restored

# ============================================================
#  CONFIGURATION
#  Replace placeholders with your WireGuard peer details.
# ============================================================
WG_INTERFACE="wg0"
WG_CONFIG="/etc/wireguard/${WG_INTERFACE}.conf"

# Primary endpoint (required)
WG_PRIMARY_ENDPOINT="vpn.example.com:51820"
WG_PRIMARY_PUBKEY="REPLACE_WITH_PRIMARY_SERVER_PUBLIC_KEY"

# Backup endpoint (optional, leave blank to disable failover)
WG_BACKUP_ENDPOINT=""
WG_BACKUP_PUBKEY=""

# Local interface address (CIDR)
WG_LOCAL_ADDRESS="10.13.13.2/24"

# Health check settings
HEALTH_CHECK_INTERVAL=30
HEALTH_CHECK_TARGET="10.13.13.1"
HEALTH_CHECK_TIMEOUT=5
MAX_FAILURES_BEFORE_RECONNECT=3

# Loot
LOOT_DIR="/root/loot/wireguard_sentinel"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
LOG_FILE="${LOOT_DIR}/session_${TIMESTAMP}.log"

# State
CURRENT_ENDPOINT="$WG_PRIMARY_ENDPOINT"
CURRENT_PUBKEY="$WG_PRIMARY_PUBKEY"
FAILURE_COUNT=0
TUNNEL_UP=0
GUARD_MODE=0

# ============================================================
#  DEPENDENCY CHECK
# ============================================================
check_dependencies() {
  if ! command -v wg &>/dev/null; then
    ERROR_DIALOG "WireGuard not installed.\n\nInstall with:\nopkg update && opkg install wireguard-tools kmod-wireguard"
    LOG red "WireGuard missing"
    exit 1
  fi
  if ! command -v wg-quick &>/dev/null; then
    ERROR_DIALOG "wg-quick not found.\nInstall wireguard-tools."
    exit 1
  fi
  mkdir -p "$LOOT_DIR"
}

# ============================================================
#  LOGGING
# ============================================================
log_event() {
  local msg="$1"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] %s\n' "$ts" "$msg" >> "$LOG_FILE"
}

# ============================================================
#  CONFIG GENERATION
# ============================================================
generate_config() {
  local endpoint="$1"
  local pubkey="$2"

  # Extract host and port
  local host="${endpoint%:*}"
  local port="${endpoint##*:}"

  cat > "$WG_CONFIG" <<EOF
[Interface]
Address = ${WG_LOCAL_ADDRESS}
PrivateKey = $(cat /etc/wireguard/private.key 2>/dev/null || echo "REPLACE_PRIVATE_KEY")
ListenPort = 51820

[Peer]
PublicKey = ${pubkey}
Endpoint = ${host}:${port}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  chmod 600 "$WG_CONFIG"
  log_event "Generated config for endpoint ${endpoint}"
}

# ============================================================
#  TUNNEL CONTROL
# ============================================================
start_tunnel() {
  local endpoint="$1"
  local pubkey="$2"

  generate_config "$endpoint" "$pubkey"

  # Bring down any existing interface
  wg-quick down "$WG_INTERFACE" 2>/dev/null
  sleep 1

  # Bring up the tunnel
  if wg-quick up "$WG_INTERFACE" 2>/dev/null; then
    TUNNEL_UP=1
    log_event "Tunnel UP on ${endpoint}"
    return 0
  else
    TUNNEL_UP=0
    log_event "Tunnel FAILED on ${endpoint}"
    return 1
  fi
}

stop_tunnel() {
  wg-quick down "$WG_INTERFACE" 2>/dev/null
  TUNNEL_UP=0
  log_event "Tunnel DOWN"
}

# ============================================================
#  HEALTH CHECK
# ============================================================
health_check() {
  if [[ "$TUNNEL_UP" -eq 0 ]]; then
    return 1
  fi

  if ping -c 1 -W "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_TARGET" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# ============================================================
#  FAILOVER
# ============================================================
try_failover() {
  if [[ -z "$WG_BACKUP_ENDPOINT" || -z "$WG_BACKUP_PUBKEY" ]]; then
    log_event "No backup endpoint configured"
    return 1
  fi

  log_event "Attempting failover to backup endpoint"
  LOG amber "Failing over to backup peer..."

  if start_tunnel "$WG_BACKUP_ENDPOINT" "$WG_BACKUP_PUBKEY"; then
    CURRENT_ENDPOINT="$WG_BACKUP_ENDPOINT"
    CURRENT_PUBKEY="$WG_BACKUP_PUBKEY"
    FAILURE_COUNT=0
    log_event "Failover successful"
    return 0
  fi

  log_event "Failover failed"
  return 1
}

# ============================================================
#  GUARD MODE
# ============================================================
guard_loop() {
  GUARD_MODE=1
  LOG green "Sentinel guard active — monitoring tunnel"
  log_event "Guard mode started"

  while [[ "$GUARD_MODE" -eq 1 ]]; do
    sleep "$HEALTH_CHECK_INTERVAL"

    # Check if user wants to exit (button B)
    # Note: button check requires a non-blocking method; we use a file flag
    if [[ -f /tmp/wireguard_sentinel_stop ]]; then
      rm -f /tmp/wireguard_sentinel_stop
      GUARD_MODE=0
      log_event "Guard mode stopped by user"
      break
    fi

    if health_check; then
      FAILURE_COUNT=0
      continue
    fi

    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    log_event "Health check failed (${FAILURE_COUNT}/${MAX_FAILURES_BEFORE_RECONNECT})"

    if [[ "$FAILURE_COUNT" -ge "$MAX_FAILURES_BEFORE_RECONNECT" ]]; then
      LOG amber "Tunnel dropped — attempting recovery"
      LED AMBER FAST
      log_event "Attempting reconnect"

      # Try current endpoint first
      if start_tunnel "$CURRENT_ENDPOINT" "$CURRENT_PUBKEY"; then
        FAILURE_COUNT=0
        LED GREEN SOLID
        RINGTONE "ScaleTrill"
        continue
      fi

      # Try failover
      if try_failover; then
        LED GREEN SOLID
        RINGTONE "ScaleTrill"
        continue
      fi

      # Nothing worked
      LED RED SLOW
      RINGTONE "warning"
      log_event "Recovery failed — tunnel down"
    fi
  done

  log_event "Guard mode ended"
}

# ============================================================
#  MAIN
# ============================================================
check_dependencies

# Header
LED MAGENTA
LOG magenta "═══════════════════════════════════════"
LOG cyan    "  WireGuard Sentinel"
LOG magenta "═══════════════════════════════════════"
LOG " "

# Initialize log
{
  printf "═══ WireGuard Sentinel Session ═══\n"
  printf "Started: %s\n" "$TIMESTAMP"
  printf "Primary: %s\n" "$WG_PRIMARY_ENDPOINT"
  [[ -n "$WG_BACKUP_ENDPOINT" ]] && printf "Backup:  %s\n" "$WG_BACKUP_ENDPOINT"
  printf "\n"
} >> "$LOG_FILE"

# Check for private key
if [[ ! -f /etc/wireguard/private.key ]]; then
  resp=$(CONFIRMATION_DIALOG "No WireGuard private key found.\n\nGenerate one now?")
  if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    chmod 600 /etc/wireguard/private.key
    LOG green "Generated key pair"
    LOG cyan "Your public key (add to server peer config):"
    LOG "$(cat /etc/wireguard/public.key)"
    PROMPT "Copy the public key above.\n\nPress any button when done."
  else
    LOG red "Private key required. Exiting."
    exit 1
  fi
fi

# Confirm endpoint
LOG cyan "Primary endpoint: $WG_PRIMARY_ENDPOINT"
resp=$(CONFIRMATION_DIALOG "Connect to primary endpoint?")
if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
  LOG yellow "Cancelled"
  exit 0
fi

# Start tunnel
spinner=$(START_SPINNER "Establishing tunnel...")
if start_tunnel "$WG_PRIMARY_ENDPOINT" "$WG_PRIMARY_PUBKEY"; then
  STOP_SPINNER "$spinner"
  LED GREEN SOLID
  RINGTONE "ScaleTrill"
  LOG green "Tunnel established"
  LOG cyan "Local IP: $(ip -4 addr show "$WG_INTERFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+')"
else
  STOP_SPINNER "$spinner"
  LED RED SLOW
  RINGTONE "warning"
  LOG red "Tunnel failed to establish"

  # Offer failover
  if [[ -n "$WG_BACKUP_ENDPOINT" ]]; then
    resp=$(CONFIRMATION_DIALOG "Try backup endpoint?")
    if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
      if try_failover; then
        LED GREEN SOLID
        LOG green "Connected via backup"
      else
        LED RED SLOW
        LOG red "Backup failed too"
        exit 1
      fi
    else
      exit 1
    fi
  else
    exit 1
  fi
fi

# Offer guard mode
resp=$(CONFIRMATION_DIALOG "Start Sentinel guard?\n\nMonitors tunnel and auto-reconnects if it drops.")
if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
  LOG cyan "Press button B to stop guard mode"
  # Background a watcher for button B
  (
    while true; do
      # WAIT_FOR_BUTTON_PRESS is blocking; we use a timeout approach
      # This is a simplified pattern — adjust for your firmware
      sleep 1
    done
  ) &
  guard_loop
else
  LOG yellow "Tunnel active without guard."
  LOG cyan "Disconnect with: wg-quick down $WG_INTERFACE"
fi

log_event "Session ended"
LOG green "WireGuard Sentinel finished"
LOG "Loot: $LOG_FILE"

exit 0
