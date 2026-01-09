#!/bin/bash
# Title: DOOM Deathmatch
# Description: Connect to DOOM server for multiplayer deathmatch!
# Author: @lmacken
# Version: 3.0
# Category: Games

PAYLOAD_DIR="/root/payloads/user/games/doom-deathmatch"
CONFIG_FILE="$PAYLOAD_DIR/server.conf"

# Default server (Pineapple DOOM central server)
DEFAULT_SERVER_IP="64.227.99.100"
DEFAULT_SERVER_PORT="2342"
DEFAULT_MAP="E1M1"
DEFAULT_NOMONSTERS="yes"
DEFAULT_TIMELIMIT="10"
DEFAULT_SKILL="4"

# Load saved config or use defaults
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
else
  SERVER_IP="$DEFAULT_SERVER_IP"
  SERVER_PORT="$DEFAULT_SERVER_PORT"
  MAP="$DEFAULT_MAP"
  NOMONSTERS="$DEFAULT_NOMONSTERS"
  TIMELIMIT="$DEFAULT_TIMELIMIT"
  SKILL="$DEFAULT_SKILL"
fi
# Ensure defaults
[ -z "$MAP" ] && MAP="$DEFAULT_MAP"
[ -z "$NOMONSTERS" ] && NOMONSTERS="$DEFAULT_NOMONSTERS"
[ -z "$TIMELIMIT" ] && TIMELIMIT="$DEFAULT_TIMELIMIT"
[ -z "$SKILL" ] && SKILL="$DEFAULT_SKILL"

cd "$PAYLOAD_DIR" || {
  LOG red "ERROR: $PAYLOAD_DIR not found"
  exit 1
}

# Verify required files exist
[ ! -f "./doomgeneric" ] && {
  LOG red "ERROR: doomgeneric not found"
  exit 1
}
chmod +x ./doomgeneric

# Find any WAD file
WAD_FILE=$(ls "$PAYLOAD_DIR"/*.wad 2>/dev/null | head -1)
[ -z "$WAD_FILE" ] && {
  LOG red "ERROR: No .wad file found"
  exit 1
}

# Show current settings and offer to configure
LOG "DOOM DEATHMATCH"
LOG ""
LOG "Server: $SERVER_IP:$SERVER_PORT"
LOG "Map: $MAP  Skill: $SKILL  Timer: ${TIMELIMIT}m"
[ "$NOMONSTERS" = "yes" ] && LOG "No Monsters: ON" || LOG "No Monsters: OFF"
LOG ""

# Brief pause so user can read settings
sleep 2

resp=$(CONFIRMATION_DIALOG "Change settings?")
if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
  # Get new IP
  new_ip=$(IP_PICKER "Server IP" "$SERVER_IP")
  case $? in
  $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
    LOG "Cancelled"
    exit 1
    ;;
  esac

  # Get new port
  new_port=$(NUMBER_PICKER "Server Port" "$SERVER_PORT")
  case $? in
  $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
    LOG "Cancelled"
    exit 1
    ;;
  esac

  # Get map (E1M1-E1M9 for shareware)
  new_map=$(TEXT_PICKER "Map (E1M1-E1M9)" "$MAP")
  case $? in
  $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
    LOG "Cancelled"
    exit 1
    ;;
  esac

  # No monsters toggle
  monsters_resp=$(CONFIRMATION_DIALOG "No Monsters?")
  if [ "$monsters_resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    new_nomonsters="yes"
  else
    new_nomonsters="no"
  fi

  # Time limit
  new_timelimit=$(NUMBER_PICKER "Time Limit (min)" "$TIMELIMIT")
  case $? in
  $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
    LOG "Cancelled"
    exit 1
    ;;
  esac

  # Skill level
  new_skill=$(NUMBER_PICKER "Skill (1-5)" "$SKILL")
  case $? in
  $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
    LOG "Cancelled"
    exit 1
    ;;
  esac

  SERVER_IP="$new_ip"
  SERVER_PORT="$new_port"
  MAP="$new_map"
  NOMONSTERS="$new_nomonsters"
  TIMELIMIT="$new_timelimit"
  SKILL="$new_skill"

  # Save config
  echo "SERVER_IP=\"$SERVER_IP\"" >"$CONFIG_FILE"
  echo "SERVER_PORT=\"$SERVER_PORT\"" >>"$CONFIG_FILE"
  echo "MAP=\"$MAP\"" >>"$CONFIG_FILE"
  echo "NOMONSTERS=\"$NOMONSTERS\"" >>"$CONFIG_FILE"
  echo "TIMELIMIT=\"$TIMELIMIT\"" >>"$CONFIG_FILE"
  echo "SKILL=\"$SKILL\"" >>"$CONFIG_FILE"

  LOG "Settings saved!"
fi

# Test server connectivity before launching
LOG ""
LOG "Testing $SERVER_IP..."

# First check if host is reachable (ping test)
if ! ping -c 1 -W 3 "$SERVER_IP" >/dev/null 2>&1; then
  LOG red "ERROR: Cannot reach $SERVER_IP"
  LOG red "Server may be offline or"
  LOG red "check your WiFi connection"
  LOG ""
  LOG "Press any button..."
  WAIT_FOR_INPUT >/dev/null 2>&1
  exit 1
fi

# Try UDP connectivity test (send empty packet, expect any response)
# Using shell /dev/udp if available, otherwise skip
if (echo -n "" >/dev/udp/"$SERVER_IP"/"$SERVER_PORT") 2>/dev/null; then
  LOG green "Server reachable!"
else
  # /dev/udp might not be available, just warn
  LOG yellow "Host reachable (UDP untested)"
fi

# Display controls
LOG ""
LOG "Controls:"
LOG "D-pad=Move  Red=Fire"
LOG "Green+Up=Use  Green+L/R=Strafe"
LOG "Red+Green=Quit"
LOG ""
LOG "Press any button to connect..."
WAIT_FOR_INPUT >/dev/null 2>&1

# Stop services to free CPU and memory for DOOM
/etc/init.d/php8-fpm stop 2>/dev/null
/etc/init.d/nginx stop 2>/dev/null
/etc/init.d/bluetoothd stop 2>/dev/null
/etc/init.d/pineapplepager stop 2>/dev/null
/etc/init.d/pineapd stop 2>/dev/null

# Free cached memory
echo 3 >/proc/sys/vm/drop_caches 2>/dev/null

# Parse map format (E1M4 -> episode=1 map=4)
EPISODE=$(echo "$MAP" | sed -n 's/^E\([0-9]\)M[0-9]$/\1/p')
MAP_NUM=$(echo "$MAP" | sed -n 's/^E[0-9]M\([0-9]\)$/\1/p')

# Default to E1M1 if parsing fails
[ -z "$EPISODE" ] && EPISODE=1
[ -z "$MAP_NUM" ] && MAP_NUM=1

# Build extra args
EXTRA_ARGS=""
[ "$NOMONSTERS" = "yes" ] && EXTRA_ARGS="$EXTRA_ARGS -nomonsters"
[ "$TIMELIMIT" -gt 0 ] 2>/dev/null && EXTRA_ARGS="$EXTRA_ARGS -timer $TIMELIMIT"
[ "$SKILL" -ge 1 ] && [ "$SKILL" -le 5 ] 2>/dev/null && EXTRA_ARGS="$EXTRA_ARGS -skill $SKILL"

# Run DOOM with high priority for smoother gameplay
"$PAYLOAD_DIR/doomgeneric" -iwad "$WAD_FILE" -connect "$SERVER_IP:$SERVER_PORT" -warp "$EPISODE" "$MAP_NUM" $EXTRA_ARGS >/tmp/doom.log 2>&1

# Restore services after DOOM exits
/etc/init.d/php8-fpm start 2>/dev/null &
/etc/init.d/nginx start 2>/dev/null &
/etc/init.d/bluetoothd start 2>/dev/null &
/etc/init.d/pineapplepager start 2>/dev/null &
/etc/init.d/pineapd start 2>/dev/null &

LOG ""
LOG "DOOM exited. Press any button..."
WAIT_FOR_INPUT >/dev/null 2>&1
