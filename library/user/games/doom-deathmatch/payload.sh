#!/bin/bash
# Title: DOOM Deathmatch
# Description: Connect to DOOM server for multiplayer deathmatch!
# Author: @lmacken
# Version: 4.0
# Category: Games

PAYLOAD_DIR="/root/payloads/user/games/doom-deathmatch"
CONFIG_FILE="$PAYLOAD_DIR/server.conf"

# Default settings
DEFAULT_SERVER_IP="64.227.99.100"
DEFAULT_SERVER_PORT="2342"
DEFAULT_MAP="E1M1"
DEFAULT_NOMONSTERS="yes"
DEFAULT_TIMELIMIT="10"
DEFAULT_SKILL="4"
DEFAULT_PLAYER_NAME="Pager"
DEFAULT_CONNECTION_MODE="automatch"  # automatch, browse, or direct

# Note: In automatch/browse modes, the game will automatically discover
# all servers by scanning sequential ports (2342, 2343, 2344, ...)
# until it finds ports that don't respond. This means adding more
# servers on the backend Just Works without client updates!

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
    PLAYER_NAME="$DEFAULT_PLAYER_NAME"
    CONNECTION_MODE="$DEFAULT_CONNECTION_MODE"
fi

# Ensure defaults
[ -z "$MAP" ] && MAP="$DEFAULT_MAP"
[ -z "$NOMONSTERS" ] && NOMONSTERS="$DEFAULT_NOMONSTERS"
[ -z "$TIMELIMIT" ] && TIMELIMIT="$DEFAULT_TIMELIMIT"
[ -z "$SKILL" ] && SKILL="$DEFAULT_SKILL"
[ -z "$PLAYER_NAME" ] && PLAYER_NAME="$DEFAULT_PLAYER_NAME"
[ -z "$CONNECTION_MODE" ] && CONNECTION_MODE="$DEFAULT_CONNECTION_MODE"

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

# Display current mode
mode_display() {
    case "$CONNECTION_MODE" in
        automatch) echo "Auto-Match" ;;
        browse) echo "Server Browser" ;;
        direct) echo "Direct Connect" ;;
        *) echo "Auto-Match" ;;
    esac
}

# Show current settings
LOG "DOOM DEATHMATCH"
LOG ""
LOG "Player: $PLAYER_NAME"
LOG "Mode: $(mode_display)"
if [ "$CONNECTION_MODE" = "direct" ]; then
    LOG "Server: $SERVER_IP:$SERVER_PORT"
fi
LOG "Map: $MAP  Skill: $SKILL  Timer: ${TIMELIMIT}m"
[ "$NOMONSTERS" = "yes" ] && LOG "No Monsters: ON" || LOG "No Monsters: OFF"
LOG ""

# Brief pause so user can read settings
sleep 2

# Ask to change settings
resp=$(CONFIRMATION_DIALOG "Change settings?")
if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    
    # Connection mode selection
    mode_choice=$(NUMBER_PICKER "1=Auto 2=Browse 3=IP" "1")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            exit 1
            ;;
    esac
    
    case "$mode_choice" in
        1) CONNECTION_MODE="automatch" ;;
        2) CONNECTION_MODE="browse" ;;
        3) CONNECTION_MODE="direct" ;;
        *) CONNECTION_MODE="automatch" ;;
    esac
    
    # Get player name
    new_name=$(TEXT_PICKER "Player Name" "$PLAYER_NAME")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            exit 1
            ;;
    esac
    PLAYER_NAME="$new_name"
    
    # Only ask for IP/port in direct mode
    if [ "$CONNECTION_MODE" = "direct" ]; then
        new_ip=$(IP_PICKER "Server IP" "$SERVER_IP")
        case $? in
            $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                LOG "Cancelled"
                exit 1
                ;;
        esac
        
        new_port=$(NUMBER_PICKER "Server Port" "$SERVER_PORT")
        case $? in
            $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                LOG "Cancelled"
                exit 1
                ;;
        esac
        
        SERVER_IP="$new_ip"
        SERVER_PORT="$new_port"
    fi
    
    # Get map (E1M1-E1M9 for shareware)
    new_map=$(TEXT_PICKER "Map (E1M1-E1M9)" "$MAP")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            exit 1
            ;;
    esac
    MAP="$new_map"
    
    # No monsters toggle
    monsters_resp=$(CONFIRMATION_DIALOG "No Monsters?")
    if [ "$monsters_resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        NOMONSTERS="yes"
    else
        NOMONSTERS="no"
    fi
    
    # Time limit
    new_timelimit=$(NUMBER_PICKER "Time Limit (min)" "$TIMELIMIT")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            exit 1
            ;;
    esac
    TIMELIMIT="$new_timelimit"
    
    # Skill level
    new_skill=$(NUMBER_PICKER "Skill (1-5)" "$SKILL")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            exit 1
            ;;
    esac
    SKILL="$new_skill"
    
    # Save config
    cat > "$CONFIG_FILE" <<EOF
PLAYER_NAME="$PLAYER_NAME"
SERVER_IP="$SERVER_IP"
SERVER_PORT="$SERVER_PORT"
MAP="$MAP"
NOMONSTERS="$NOMONSTERS"
TIMELIMIT="$TIMELIMIT"
SKILL="$SKILL"
CONNECTION_MODE="$CONNECTION_MODE"
EOF
    
    LOG "Settings saved!"
fi

# Connectivity check for direct mode only
if [ "$CONNECTION_MODE" = "direct" ]; then
    LOG ""
    LOG "Testing $SERVER_IP..."
    
    if ! ping -c 1 -W 3 "$SERVER_IP" >/dev/null 2>&1; then
        LOG red "ERROR: Cannot reach $SERVER_IP"
        LOG red "Server may be offline or"
        LOG red "check your WiFi connection"
        LOG ""
        LOG "Press any button..."
        WAIT_FOR_INPUT >/dev/null 2>&1
        exit 1
    fi
    
    if (echo -n "" > /dev/udp/"$SERVER_IP"/"$SERVER_PORT") 2>/dev/null; then
        LOG green "Server reachable!"
    else
        LOG yellow "Host reachable (UDP untested)"
    fi
fi

# Display controls
LOG ""
LOG "Controls:"
LOG "D-pad=Move  Red=Fire"
LOG "Green+Up=Use  Green+L/R=Strafe"
LOG "Red+Green=Quit"
LOG ""

case "$CONNECTION_MODE" in
    automatch)
        LOG "Auto-matching to best server..."
        ;;
    browse)
        LOG "Opening server browser..."
        ;;
    direct)
        LOG "Connecting to $SERVER_IP:$SERVER_PORT..."
        ;;
esac

LOG ""
LOG "Press any button to start..."
WAIT_FOR_INPUT >/dev/null 2>&1

# Stop services to free CPU and memory for DOOM
/etc/init.d/php8-fpm stop 2>/dev/null
/etc/init.d/nginx stop 2>/dev/null
/etc/init.d/bluetoothd stop 2>/dev/null
/etc/init.d/pineapplepager stop 2>/dev/null
/etc/init.d/pineapd stop 2>/dev/null

sleep 1

# Parse map format (E1M4 -> episode=1 map=4)
EPISODE=$(echo "$MAP" | sed -n 's/^E\([0-9]\)M[0-9]$/\1/p')
MAP_NUM=$(echo "$MAP" | sed -n 's/^E[0-9]M\([0-9]\)$/\1/p')

# Default to E1M1 if parsing fails
[ -z "$EPISODE" ] && EPISODE=1
[ -z "$MAP_NUM" ] && MAP_NUM=1

# Build base args
BASE_ARGS="-iwad $WAD_FILE -name $PLAYER_NAME -warp $EPISODE $MAP_NUM -deathmatch"
[ "$NOMONSTERS" = "yes" ] && BASE_ARGS="$BASE_ARGS -nomonsters"
[ "$TIMELIMIT" -gt 0 ] 2>/dev/null && BASE_ARGS="$BASE_ARGS -timer $TIMELIMIT"
[ "$SKILL" -ge 1 ] && [ "$SKILL" -le 5 ] 2>/dev/null && BASE_ARGS="$BASE_ARGS -skill $SKILL"

# Build connection args based on mode
case "$CONNECTION_MODE" in
    automatch)
        CONN_ARGS="-automatch"
        ;;
    browse)
        CONN_ARGS="-browse"
        ;;
    direct)
        CONN_ARGS="-connect $SERVER_IP:$SERVER_PORT"
        ;;
    *)
        CONN_ARGS="-automatch"
        ;;
esac

# Run DOOM
"$PAYLOAD_DIR/doomgeneric" $BASE_ARGS $CONN_ARGS >/tmp/doom.log 2>&1

# Restore services after DOOM exits
/etc/init.d/php8-fpm start 2>/dev/null &
/etc/init.d/nginx start 2>/dev/null &
/etc/init.d/bluetoothd start 2>/dev/null &
/etc/init.d/pineapplepager start 2>/dev/null &
/etc/init.d/pineapd start 2>/dev/null &

LOG ""
LOG "DOOM exited. Press any button..."
WAIT_FOR_INPUT >/dev/null 2>&1
