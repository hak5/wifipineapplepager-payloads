#!/bin/bash
# Title: PagerMesh
# Description: Meshtastic on the Pager - mesh chat, node list and map, Pager GPS position over the mesh, browser web console
# Author: SECT0101
# Version: 1.0.1
# Category: General
#
# Core:
#   - Mesh chat by conversation (7 days kept), direct messages, delete chats
#   - Node list: range / bearing, battery, SNR, hops; details, traceroute, request position, favorites
#   - Mesh nodes and waypoints on the Pager map; pick one and navigate to it
#   - Pager GPS position sent over the mesh (interval or on demand)
#   - Radio settings: name, region, preset, role, channels (QR code), Wi-Fi, MQTT ...
#   - Mesh SIGINT: packet log with RSSI / SNR, traffic stats, pcap / CSV, preset scan
#   - Mesh <-> TAK bridge: mesh nodes as TAK contacts, channel chat <-> TAK All Chat Rooms
#   - Web console in a browser: map, nodes, chat, SIGINT, settings (Settings > Web console)
#
# Radio (chosen on first run: on the Pager or in a web browser; Settings > Radio connection):
#   - Glytch Mesh Mod: meshtasticd on the Pager (below)
#   - Wi-Fi radio: a Meshtastic radio with Wi-Fi on (ESP32: Heltec V3 / V4, T-Beam...), TCP 4403
#   - USB radio: a Meshtastic radio on the Pager's USB-A port (serial API)
#
# Requirements:
#   - For the Glytch Mesh Mod: the Mod (Meshtoad USB radio) on the Pager's USB-A port and
#     Glytch's Meshtastic payload copied to its own folder:
#       /root/payloads/user/general/Meshtastic/payload.sh
#     (github.com/glytchtech/Pager-Mod-Docs, folder Mesh). PagerMesh runs it for you:
#     install (first time, about 5 min, internet), start, and Enable at Boot.
#     PagerMesh never opens the radio itself; only meshtasticd may.
#   - python3-light (asks before installing; installs to main storage, never the SD card)
#   - A USB GPS configured under Settings > GPS, for range / bearing and position sending
#
# PagerMesh talks to the radio's API the same way the Meshtastic phone app does.
# Radio settings (region, name, channels...) can be changed in PagerMesh or the phone app.
#
# LED State Descriptions
#   Magenta Solid  - Setup / checking
#   Cyan Slow      - Connecting to meshtasticd
#   Green Solid    - Connected to the mesh
#   Red Slow       - Disconnected, retrying
#
# Controls (main screen)
#   A      - Menu: Map, Nodes, Chat >, Send position now, SIGINT >, Status, Settings >, Exit
#   UP     - Quick message to the primary channel
#   DOWN   - Type a message to the primary channel
#   RIGHT  - Send position now
#   LEFT   - Status (also shows the web console address)
#   B      - Exit
#
# Files
#   mesh/   mesh service (meshtasticd TCP client, Python standard library)
#   map/    Pager map viewer and screen driver, basemaps (map/sources/*.xml)
#   web/    web console (served by the mesh service) and its page
#   certs/  TAK client certificate for the bridge (client.pem, ca.pem) - never commit these
#   Saved here at run time: tiles/, web/auth
#   Loot: /root/loot/PagerMesh (chat logs, captures)
#
# Everything under Options is a DEFAULT. Values chosen in Settings are saved with
# PAYLOAD_SET_CONFIG and win over these.

# Options
MESH_HOST="127.0.0.1"           # Glytch Mesh Mod: meshtasticd TCP API host (the Pager itself)
MESH_PORT="4403"                # Glytch Mesh Mod: meshtasticd TCP API port
POS_INTERVAL="900"              # seconds between position broadcasts (0 = off). 900 = Meshtastic default
NODE_MAX_AGE="7200"             # seconds before a node drops off the map
CHAT_RINGTONE="bonus"           # ringtone on incoming messages ("" = silent)
QUICK_MESSAGES=("Copy" "WILCO" "Say again" "Standing by" "En route" "On scene" "RTB" "Need assistance" "All clear")
MAP_SOURCE="USGS Topo"          # basemap: any <name> from map/sources/*.xml (ATAK map source format)
MAP_ZOOM="14"
WEB_PORT="8585"                 # web console port (Settings > Web console; off until you turn it on)
GPS_TIME_SYNC="1"               # 1 = set the clock from GPS if it is clearly wrong

#############################################################################
# Internals - no changes needed below this line
#############################################################################

PAYLOAD_VERSION="1.0.1"
CFG_NS="pagermesh"
find_payload_dir() {
    local d
    for d in "${_PAYLOAD_HOME:-}" "${PAYLOAD_HOME:-}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" \
             /root/payloads/user/general/PagerMesh /mmc/root/payloads/user/general/PagerMesh; do
        [ -n "$d" ] && [ -f "$d/mesh/pagermesh.py" ] && { printf '%s' "$d"; return 0; }
    done
    printf '%s' "${_PAYLOAD_HOME:-/root/payloads/user/general/PagerMesh}"
}
PAYLOAD_DIR="$(find_payload_dir)"
MESH_PY="$PAYLOAD_DIR/mesh/pagermesh.py"
MAP_DIR="$PAYLOAD_DIR/map"
WEB_DIR="$PAYLOAD_DIR/web"
WEB_AUTH="$WEB_DIR/auth"
TILE_DIR="$PAYLOAD_DIR/tiles"
LOOT_DIR="/root/loot/PagerMesh"
RUN="/tmp/pagermesh"
SVC_LOG="/tmp/pagermesh-service.log"
QUICK_DEFAULT=("${QUICK_MESSAGES[@]}")

MESH_SERVICE="/etc/init.d/meshtasticd"   # installed by the Glytch Meshtastic payload
MESH_BOOT_LINK="/etc/rc.d/S99meshtasticd"
GLYTCH_PAYLOAD="/root/payloads/user/general/Meshtastic/payload.sh"

trap '' PIPE

#############################################################################
# Helpers
#############################################################################

picker_ok() {
    case "$1" in
        "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR") return 1 ;;
    esac
    return 0
}

cfg_get() {   # cfg_get key default
    local v
    v=$(PAYLOAD_GET_CONFIG "$CFG_NS" "$1" 2>/dev/null)
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}
cfg_set() { PAYLOAD_SET_CONFIG "$CFG_NS" "$1" "$2" >/dev/null 2>&1; }

load_config() {
    C_POS=$(cfg_get pos_interval "$POS_INTERVAL")
    [[ "$C_POS" =~ ^[0-9]+$ ]] || C_POS=$POS_INTERVAL
    [ "$C_POS" -gt 0 ] && [ "$C_POS" -lt 60 ] && C_POS=60
    C_RINGTONE=$(cfg_get ringtone "$CHAT_RINGTONE")
    [ "$C_RINGTONE" = "none" ] && C_RINGTONE=""
    C_MAP_SOURCE=$(cfg_get map_source "$MAP_SOURCE")
    C_WEB=$(cfg_get web 0)
    C_WEB_PORT=$(cfg_get web_port "$WEB_PORT")
    C_WEB_LISTEN=$(cfg_get web_listen all)       # all = every address (default) | pager = Pager management network / USB-C only
    C_CONN=$(cfg_get conn "")                    # mod | wifi | usb ("" = not set up yet)
    C_HOST=$(cfg_get conn_host "")
    C_PORT=$(cfg_get conn_port 4403)
    C_DEV=$(cfg_get conn_dev "")
    C_MANUAL=$(cfg_get manual_pos "")            # lat,lon set on the web console map ("" = none)
    C_DM_ALERT=$(cfg_get dm_alert sound)         # off | sound | popup
    local q; q=$(cfg_get quick_msgs "")
    if [ -n "$q" ]; then IFS='|' read -r -a QUICK_MESSAGES <<< "$q"; else QUICK_MESSAGES=("${QUICK_DEFAULT[@]}"); fi
    return 0
}

json_num() {  # json_num "<json line>" key
    local re="\"$2\":(-?[0-9.]+)"
    [[ $1 =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
}

valid_coord() {
    [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 1
    [[ $1 =~ ^-?0+(\.0+)?$ ]] && return 1
    return 0
}

# Same python lookup as PagerTAK (python3-light may also live on /mmc)
configure_python() {
    PYTHON_BIN=""
    local c v
    for c in /usr/bin/python3 /mmc/usr/bin/python3; do
        [ -x "$c" ] || continue
        [ "$c" = /mmc/usr/bin/python3 ] && export LD_LIBRARY_PATH="/mmc/usr/lib:/mmc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        v=$("$c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue
        PYTHON_BIN=$c
        [ -d "/mmc/usr/lib/python$v" ] && export PYTHONPATH="/mmc/usr/lib/python$v:/mmc/usr/lib/python$v/lib-dynload${PYTHONPATH:+:$PYTHONPATH}"
        return 0
    done
    return 1
}

install_python() {
    local r id log="/tmp/pagermesh-python-install.log"
    r=$(CONFIRMATION_DIALOG "PagerMesh needs python3-light (about 5 MB, internet). Install now?")
    [ "$r" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || return 1
    id=$(START_SPINNER "Installing python3-light")
    # main storage only: packages on the SD card (/mmc) block the Glytch Meshtastic installer
    { opkg update; opkg install python3-light; } > "$log" 2>&1
    STOP_SPINNER "$id"
    configure_python && return 0
    ERROR_DIALOG "python3-light install failed. See $log"
    return 1
}

#############################################################################
# Glytch Meshtastic payload (install / start / boot)
# PagerMesh runs Glytch's own payload so its checks and safety steps still apply.
#############################################################################

mesh_installed() { [ -x "$MESH_SERVICE" ]; }
mesh_running() { [ -n "$(pidof meshtasticd 2>/dev/null)" ]; }
boot_on() { [ -L "$MESH_BOOT_LINK" ] || [ -e "$MESH_BOOT_LINK" ]; }
api_listening() {
    netstat -lnt 2>/dev/null | awk -v p=":$MESH_PORT" '$1 ~ /^tcp/ && $4 ~ p"$" && $6 == "LISTEN" {ok=1} END {exit !ok}'
}
wait_api() {  # wait_api seconds
    local i
    for ((i = 0; i < $1; i++)); do api_listening && return 0; sleep 1; done
    api_listening
}

glytch() {  # glytch --install|--start|--boot-on|--boot-off
    [ -f "$GLYTCH_PAYLOAD" ] || return 1
    bash "$GLYTCH_PAYLOAD" "$1"
}

no_glytch_payload() {
    LED RED
    ERROR_DIALOG "Glytch Meshtastic payload not found. Copy its payload.sh to:
/root/payloads/user/general/Meshtastic/"
    exit 1
}

# Glytch's installer refuses to run while any package is installed on an extra
# opkg destination (for example the SD card, /mmc). Check first and say which.
extra_packages() {
    local d
    while read -r d; do
        [ -n "$d" ] && [ -s "${d%/}/usr/lib/opkg/status" ] &&
            awk -v d="$d" '/^Package:/ {print $2 " (" d ")"}' "${d%/}/usr/lib/opkg/status"
    done < <(awk '$1=="dest" && $3!="/" {print $3}' /etc/opkg.conf /etc/opkg/*.conf 2>/dev/null)
    return 0
}

install_mesh() {
    local r extra
    [ -f "$GLYTCH_PAYLOAD" ] || no_glytch_payload
    extra=$(extra_packages)
    if [ -n "$extra" ]; then
        LED RED
        LOG red "Packages outside main storage:"
        while read -r r; do LOG red "  $r"; done <<< "$extra"
        ERROR_DIALOG "The Meshtastic installer will not run while packages are installed on the SD card. Remove them first (opkg remove <name>), then run PagerMesh again."
        exit 1
    fi
    r=$(CONFIRMATION_DIALOG "Meshtastic is not installed. Install it now? (about 5 min, needs internet - do not interrupt)")
    [ "$r" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || exit 0
    LOG cyan "Running the Glytch Meshtastic installer..."
    glytch --install
    mesh_installed
}

start_mesh() {
    local r
    r=$(CONFIRMATION_DIALOG "Meshtastic is stopped. Start it now?")
    [ "$r" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || exit 0
    LOG cyan "Starting Meshtastic..."
    if [ -f "$GLYTCH_PAYLOAD" ]; then
        glytch --start
    else
        "$MESH_SERVICE" start >/dev/null 2>&1    # fallback: the mod's own init script
    fi
    wait_api 30
    mesh_running && api_listening
}

offer_boot() {  # ask once; the answer is remembered
    local r
    boot_on && return 0
    [ -f "$GLYTCH_PAYLOAD" ] || return 0
    [ "$(cfg_get boot_asked 0)" = "1" ] && return 0
    cfg_set boot_asked 1
    r=$(CONFIRMATION_DIALOG "Start Meshtastic every time the Pager boots? (recommended)")
    [ "$r" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || return 0
    glytch --boot-on
}

# Glytch Mesh Mod: make sure meshtasticd is installed and running on the Pager
mesh_prepare() {
    if ! mesh_installed; then
        if ! install_mesh; then
            LED RED
            ERROR_DIALOG "Meshtastic install did not finish. Run the Meshtastic payload to see why."
            exit 1
        fi
        LOG green "Meshtastic installed"
    fi

    if ! mesh_running; then
        if ! start_mesh; then
            LED RED
            ERROR_DIALOG "meshtasticd did not start. Run the Meshtastic payload (START) to see why."
            exit 1
        fi
    fi
    LOG green "meshtasticd is running"
    offer_boot

    if ! wait_api 20; then
        LED RED
        ERROR_DIALOG "meshtasticd is running but port $MESH_PORT is not open yet. Wait a moment and try again."
        exit 1
    fi
}

#############################################################################
# GPS (same reader as PagerTAK): writes $RUN/gps for the mesh service and map
#   fix lat lon hae ce speed track sats epoch
#############################################################################

gps_loop() {
    local have_pipe=0 raw lat lon alt acc out tpv sky spd trk sats hae t
    command -v gpspipe >/dev/null 2>&1 && have_pipe=1
    while [ ! -f "$RUN/stop" ]; do
        raw=$(timeout 5 GPS_GET 2>/dev/null)
        read -r lat lon alt acc _ <<< "$raw"
        spd="-"; trk="-"; sats="-"; hae=${alt:--}
        if [ "$have_pipe" = 1 ]; then
            out=$(timeout 3 gpspipe -w -n 12 2>/dev/null)
            tpv=$(printf '%s\n' "$out" | grep -m1 '"class":"TPV"')
            sky=$(printf '%s\n' "$out" | grep -m1 '"class":"SKY"')
            t=$(json_num "$tpv" speed); [ -n "$t" ] && spd=$t
            t=$(json_num "$tpv" track); [ -n "$t" ] && trk=$t
            t=$(json_num "$tpv" altHAE); [ -n "$t" ] && hae=$t
            t=$(json_num "$sky" uSat)
            if [ -n "$t" ]; then sats=$t
            elif [ -n "$sky" ]; then sats=$(printf '%s' "$sky" | grep -o '"used":true' | wc -l)
            fi
            if [ "$GPS_TIME_SYNC" = 1 ] && [ ! -f "$RUN/timesynced" ] && [ "$(date -u +%Y)" -lt 2025 ]; then
                local re='"time":"([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})'
                if [[ $tpv =~ $re ]]; then
                    date -u -s "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" >/dev/null 2>&1 && : > "$RUN/timesynced"
                fi
            fi
        fi
        if valid_coord "$lat" && valid_coord "$lon"; then
            [[ $acc =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ ! $acc =~ ^0+(\.0+)?$ ]] || acc="-"
            printf '1 %s %s %s %s %s %s %s %s\n' "$lat" "$lon" "${hae:--}" "$acc" "$spd" "$trk" "$sats" "$(date +%s)" > "$RUN/gps.tmp"
            printf '%s %s %s %s\n' "$lat" "$lon" "${hae:--}" "$acc" > "$RUN/lastfix"
        else
            printf '0 - - - - - - %s %s\n' "$sats" "$(date +%s)" > "$RUN/gps.tmp"
        fi
        mv "$RUN/gps.tmp" "$RUN/gps"
        sleep 4
    done
}

read_gps() {  # sets G_LAT G_LON G_SATS ; returns 1 without a fix
    local f lat lon sats
    G_LAT=""; G_LON=""; G_SATS="-"
    [ -f "$RUN/gps" ] || return 1
    read -r f lat lon _ _ _ _ sats _ < "$RUN/gps"
    G_SATS=${sats:--}
    [ "$f" = 1 ] || return 1
    G_LAT=$lat; G_LON=$lon
}

#############################################################################
# Mesh service (mesh/pagermesh.py) and web console
#############################################################################

# Pager USB / management address (always listed first)
web_lan_ip() {
    local ip
    ip=$(uci -q get network.lan.ipaddr 2>/dev/null); ip=${ip%%/*}
    printf '%s' "${ip:-172.16.52.1}"
}

# "iface address" for every IPv4 address (ip if present, else busybox ifconfig)
web_addrs() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show 2>/dev/null | awk '{split($4, a, "/"); print $2, a[1]}'
    else
        ifconfig 2>/dev/null | awk '/^[^ \t]/ {i=$1} /inet addr:/ {sub("addr:", "", $2); print i, $2}'
    fi
}

web_bind() { if [ "$C_WEB_LISTEN" = all ]; then printf '0.0.0.0'; else web_lan_ip; fi; }

# every address a browser can use (management network first)
web_urls() {
    local lan a
    lan=$(web_lan_ip)
    printf 'http://%s:%s\n' "$lan" "$C_WEB_PORT"
    [ "$C_WEB_LISTEN" = all ] || return 0
    web_addrs | awk -v lan="$lan" '$1 != "lo" && $2 != lan {print $2}' | while read -r a; do
        printf 'http://%s:%s\n' "$a" "$C_WEB_PORT"
    done
}
log_web_urls() { local u; while read -r u; do LOG white "Web: $u"; done < <(web_urls); }

svc_running() { kill -0 "$(cat "$RUN/svc.pid" 2>/dev/null)" 2>/dev/null; }

gps_dev() { uci -q get gpsd.core.device 2>/dev/null; }

conn_label() {
    case "$C_CONN" in
        mod)  printf 'Glytch Mesh Mod' ;;
        wifi) printf 'Wi-Fi radio %s:%s' "$C_HOST" "$C_PORT" ;;
        usb)  printf 'USB radio %s' "$C_DEV" ;;
        *)    printf 'not set up' ;;
    esac
}

conn_args() {  # the service's connection arguments for the saved setting
    case "$C_CONN" in
        wifi) printf '%s\n' --conn wifi --host "$C_HOST" --port "$C_PORT" ;;
        usb)  printf '%s\n' --conn usb --dev "$C_DEV" ;;
        *)    printf '%s\n' --conn mod --host "$MESH_HOST" --port "$MESH_PORT" ;;
    esac
}

svc_start() {  # svc_start [setup]   setup = web console only, to choose the connection
    local args q
    write_app_cfg
    q=$(IFS='|'; printf '%s' "${QUICK_MESSAGES[*]}")
    printf '%s\n' "$C_POS" > "$RUN/pos_interval"
    mapfile -t args < <(conn_args)
    args+=(--run "$RUN" --loot "$LOOT_DIR" --gps-dev "$(gps_dev)"
          --max-age "$NODE_MAX_AGE" --pos-interval "$C_POS" --map-dir "$MAP_DIR" --tiles "$TILE_DIR"
          --map-source "$C_MAP_SOURCE" --quick "$q")
    [ "$1" = setup ] && args+=(--setup)
    if { [ "$C_WEB" = 1 ] || [ "$1" = setup ]; } && [ -s "$WEB_AUTH" ]; then
        args+=(--web-port "$C_WEB_PORT" --bind "$(web_bind)" --auth "$WEB_AUTH" --web-dir "$WEB_DIR")
    fi
    PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$MESH_PY" "${args[@]}" > "$SVC_LOG" 2>&1 &
    echo $! > "$RUN/svc.pid"
}

svc_stop() {  # stops the service and waits until it is gone (it frees the web port)
    local p i
    p=$(cat "$RUN/svc.pid" 2>/dev/null)
    rm -f "$RUN/svc.pid"
    [ -n "$p" ] || return 0
    kill "$p" 2>/dev/null
    for ((i = 0; i < 20; i++)); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.25; done
    kill -9 "$p" 2>/dev/null
    sleep 0.5
}

svc_restart() { svc_stop; svc_start; }

# after starting with the web console on: did it listen? (the service writes $RUN/web)
web_check() {
    local i r
    for ((i = 0; i < 12; i++)); do
        [ -s "$RUN/web" ] && break
        sleep 0.5
    done
    read -r r < "$RUN/web" 2>/dev/null
    if [ "$r" = ok ]; then LOG green "Web console on"; log_web_urls; return 0; fi
    [ -s "$WEB_AUTH" ] || { LOG red "Web console has no password: Settings > Web console > Set password"; return 1; }
    LOG red "Web console did not start - see $SVC_LOG"
    return 1
}

# mesh_cmd "line1" "line2" ... -> hands one command to the service, waits for its answer
mesh_cmd() {
    local id f i res
    id="$(date +%s%N 2>/dev/null || date +%s)-$RANDOM"
    f="$RUN/outbox/$id"
    printf '%s\n' "$@" > "$f.tmp" && mv "$f.tmp" "$f.cmd"
    for ((i = 0; i < 20; i++)); do
        if [ -s "$f.res" ]; then
            res=$(head -n1 "$f.res"); rm -f "$f.res"
            MESH_MSG=${res#*|}
            [ "${res%%|*}" = ok ]; return
        fi
        sleep 0.25
    done
    MESH_MSG="mesh service did not answer"
    return 1
}

status_read() {  # sets S_LINK S_ID S_NAME S_REGION S_NODES S_ERR S_LASTPOS
    S_LINK=""; S_ID=""; S_NAME=""; S_REGION=""; S_NODES=0; S_ERR=""; S_LASTPOS=0
    [ -f "$RUN/status" ] && IFS='|' read -r S_LINK S_ID S_NAME S_REGION S_NODES S_ERR S_LASTPOS < "$RUN/status"
    S_NODES=${S_NODES:-0}; S_LASTPOS=${S_LASTPOS:-0}
}

unread_count() { local n=0; [ -s "$RUN/unread" ] && read -r n < "$RUN/unread"; echo "${n:-0}"; }

#############################################################################
# Radio connection setup (on the Pager or in a web browser)
#############################################################################

save_conn() {  # save_conn type host port dev
    cfg_set conn "$1"; cfg_set conn_host "$2"; cfg_set conn_port "${3:-4403}"; cfg_set conn_dev "$4"
    load_config
    LOG green "Radio: $(conn_label)"
}

# apply a setting saved in the web console ($RUN/setup_req: key=value lines)
# SETUP_LIVE=1 afterwards when the running service already switched to it (no restart needed)
apply_setup_req() {
    local k v conn="" host="" port="4403" dev=""
    SETUP_LIVE=0
    [ -s "$RUN/setup_req" ] || return 1
    while IFS='=' read -r k v; do
        case "$k" in conn) conn=$v ;; host) host=$v ;; port) port=$v ;; dev) dev=$v ;; live) SETUP_LIVE=$v ;; esac
    done < "$RUN/setup_req"
    rm -f "$RUN/setup_req"
    case "$conn" in mod|wifi|usb) ;; *) return 1 ;; esac
    [[ "$port" =~ ^[0-9]+$ ]] || port=4403
    save_conn "$conn" "$host" "$port" "$dev"
}

# web console Save during normal use: store it; restart the service only if it did not switch itself
check_setup_req() {
    check_cfg_req
    [ -s "$RUN/setup_req" ] || return 0
    apply_setup_req || return 0
    if [ "$SETUP_LIVE" = 1 ]; then
        [ "$C_CONN" = mod ] && ! { mesh_installed && mesh_running; } &&
            LOG yellow "meshtasticd is not running - exit and run PagerMesh again to set it up"
    else
        reconnect
    fi
}

# PagerMesh settings the mesh service uses too (RUN/config, key=value)
APP_KEYS=(manual_pos hide_age dm_alert tak_on tak_proto tak_host tak_port tak_pos tak_chat tak_chan pos_chan)
write_app_cfg() {
    local k v out=""
    for k in "${APP_KEYS[@]}"; do
        v=$(cfg_get "$k" "")
        [ -n "$v" ] && out+="$k=$v"$'\n'
    done
    printf '%s' "$out" > "$RUN/config.tmp" && mv "$RUN/config.tmp" "$RUN/config"
}

# settings changed in the web console ($RUN/cfg_req): keep them in the Pager config
check_cfg_req() {
    local k v
    [ -s "$RUN/cfg_req" ] || return 0
    mv "$RUN/cfg_req" "$RUN/cfg_req.work" 2>/dev/null || return 0
    while IFS='=' read -r k v; do
        case " ${APP_KEYS[*]} " in *" $k "*) cfg_set "$k" "$v" ;; esac
    done < "$RUN/cfg_req.work"
    rm -f "$RUN/cfg_req.work"
    load_config
}

# a PagerMesh setting changed on the Pager: keep it and tell the running service
app_set() {  # app_set key value [key value ...]
    local lines=()
    while [ $# -ge 2 ]; do cfg_set "$1" "$2"; lines+=("$1=$2"); shift 2; done
    load_config
    mesh_cmd cfg "${lines[@]}" >/dev/null
}

usb_ports() { ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null; }

test_conn() {  # test_conn args... -> 0 when the radio answered; message in TEST_MSG
    local id
    id=$(START_SPINNER "Testing connection")
    TEST_MSG=$("$PYTHON_BIN" -B "$MESH_PY" --check "$@" 2>&1 | tail -n1)
    STOP_SPINNER "$id"
    [[ $TEST_MSG == OK* ]]
}

setup_on_pager() {
    local r host port dev ports=() g labels=() i
    case "$C_CONN" in wifi) r="Wi-Fi radio" ;; usb) r="USB radio" ;; *) r="Glytch Mesh Mod" ;; esac
    r=$(LIST_PICKER "Radio connection" "Glytch Mesh Mod" "Wi-Fi radio" "USB radio" "Cancel" "$r"); picker_ok $? || return 1
    case "$r" in
        "Glytch Mesh Mod")
            save_conn mod "" 4403 ""; return 0 ;;
        "Wi-Fi radio")
            host=$(TEXT_PICKER "Radio IP address" "$C_HOST"); picker_ok $? || return 1
            host=${host// /}
            [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || { ERROR_DIALOG "Enter the radio's IP address (on its screen or in the Meshtastic app)."; return 1; }
            port=$(TEXT_PICKER "Port" "${C_PORT:-4403}"); picker_ok $? || return 1
            [[ $port =~ ^[0-9]+$ ]] || port=4403
            if test_conn --conn wifi --host "$host" --port "$port"; then LOG green "${TEST_MSG#OK }"
            else
                LOG red "$TEST_MSG"
                [ "$(CONFIRMATION_DIALOG "No answer from $host:$port. Save it anyway?")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || return 1
            fi
            save_conn wifi "$host" "$port" "" ;;
        "USB radio")
            mapfile -t ports < <(usb_ports)
            g=$(gps_dev)
            for i in "${ports[@]}"; do [ "$(readlink -f "$i")" != "$(readlink -f "${g:-/none}")" ] && labels+=("$i"); done
            if [ ${#labels[@]} -eq 0 ]; then
                ERROR_DIALOG "No USB radio found (/dev/ttyUSB* or /dev/ttyACM*). Plug it in and try again."
                return 1
            fi
            dev=$(LIST_PICKER "USB radio" "${labels[@]}" "${labels[0]}"); picker_ok $? || return 1
            if test_conn --conn usb --dev "$dev"; then LOG green "${TEST_MSG#OK }"
            else
                LOG red "$TEST_MSG"
                [ "$(CONFIRMATION_DIALOG "No answer on $dev. Save it anyway?")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || return 1
            fi
            save_conn usb "" 4403 "$dev" ;;
        *) return 1 ;;
    esac
}

# Web console in setup mode until a connection is saved there (B cancels)
# Where is the browser? Sets web_listen (pager | all)
pick_web_listen() {
    local r d
    [ "$C_WEB_LISTEN" = all ] && d="Same Wi-Fi as the Pager" || d="Pager Wi-Fi / USB-C"
    r=$(LIST_PICKER "Browser connects via" "Pager Wi-Fi / USB-C" "Same Wi-Fi as the Pager" "$d"); picker_ok $? || return 1
    if [ "$r" = "Same Wi-Fi as the Pager" ]; then cfg_set web_listen all; else cfg_set web_listen pager; fi
    load_config
}

setup_in_browser() {
    local b
    pick_web_listen || return 1
    [ -s "$WEB_AUTH" ] || set_web_password || return 1
    svc_stop; rm -f "$RUN/web" "$RUN/setup_req"
    svc_start setup
    web_check || return 1
    LOG white "Open the address in a browser,"
    LOG white "sign in, choose the radio, Test, Save."
    LOG white "B = cancel"
    while :; do
        b=$(WAIT_FOR_INPUT 1)
        if [ -s "$RUN/setup_req" ]; then
            apply_setup_req; svc_stop
            cfg_set web 1; load_config             # set up in the browser: keep the web console on
            return 0
        fi
        [ "$b" = B ] && { svc_stop; return 1; }
    done
}

first_run_setup() {
    local r
    while [ -z "$C_CONN" ]; do
        r=$(LIST_PICKER "PagerMesh setup" "On the Pager" "In a web browser" "Exit" "On the Pager"); picker_ok $? || return 1
        case "$r" in
            "On the Pager")     setup_on_pager ;;
            "In a web browser") setup_in_browser ;;
            *) return 1 ;;
        esac
    done
}

#############################################################################
# Text helpers for the node list
#############################################################################

DIRS=(N NE E SE S SW W NW)
fmt_range() {
    local m=$1
    [ -z "$m" ] && { printf -- '-'; return; }
    if [ "$m" -ge 1000 ]; then printf '%d.%dkm' $((m / 1000)) $(((m % 1000) / 100)); else printf '%dm' "$m"; fi
}
fmt_dir() { [ -z "$1" ] && return; printf ' %s' "${DIRS[$(( ($1 + 22) / 45 % 8 ))]}"; }
fmt_age() {
    local s=$1
    [ -z "$s" ] && { printf -- '-'; return; }
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"
    elif [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
    elif [ "$s" -lt 86400 ]; then printf '%dh' $((s / 3600))
    else printf '%dd' $((s / 86400)); fi
}
fmt_batt() {
    [ -z "$1" ] && { printf -- '-'; return; }
    [ "$1" -gt 100 ] && { printf 'PWR'; return; }
    printf '%s%%' "$1"
}

#############################################################################
# Chat
#############################################################################

pick_quick() {  # pick_quick [title]
    local r
    r=$(LIST_PICKER "${1:-Quick message}" "${QUICK_MESSAGES[@]}" "${QUICK_MESSAGES[0]}")
    picker_ok $? || return 1
    [ -n "$r" ] || return 1
    printf '%s' "$r"
}

type_msg() {  # type_msg [title]
    local r
    r=$(TEXT_PICKER "${1:-Message}" "")
    picker_ok $? || return 1
    [ -n "$r" ] || return 1
    printf '%s' "$r"
}

send_text() {  # send_text "msg" [dest=all|!nodeid] [channel]
    if mesh_cmd text "${2:-all}" "${3:-0}" "$1"; then
        LOG green "Sent: $1"
    else
        LOG red "Not sent: $MESH_MSG"
    fi
}

# Channel picker: sets CH_IDX CH_NAME (only asks when there is more than one channel)
pick_channel() {   # optional "private": only channels with their own key
    local names=() idx=() line i n k r
    while IFS='|' read -r i n k; do
        [ -n "$i" ] || continue
        [ "$1" = private ] && [ "$k" != private ] && continue
        idx+=("$i"); names+=("$i: $n")
    done < "$RUN/channels" 2>/dev/null
    if [ "$1" = private ] && [ ${#names[@]} -eq 0 ]; then
        ERROR_DIALOG "No channel with its own key. Channel 0 is public on most meshes. Make a private one: Radio > Channels > new random key."
        return 1
    fi
    CH_IDX=0; CH_NAME="Primary"
    [ ${#names[@]} -eq 0 ] && return 0
    if [ ${#names[@]} -eq 1 ]; then CH_IDX=${idx[0]}; CH_NAME=${names[0]#*: }; return 0; fi
    r=$(LIST_PICKER "Channel" "${names[@]}" "${names[0]}"); picker_ok $? || return 1
    for line in "${!names[@]}"; do
        [ "${names[$line]}" = "$r" ] && { CH_IDX=${idx[$line]}; CH_NAME=${r#*: }; }
    done
    return 0
}

# Node picker: sets PICK_ID PICK_NAME ; optional title
pick_node() {
    local labels=() ids=() names=() id short long range bearing batt age i r
    while IFS='|' read -r id short long range bearing batt _ _ age _; do
        [ -z "$id" ] && continue
        [ "$id" = "$S_ID" ] && continue
        ids+=("$id"); names+=("${long:-${short:-$id}}")
        labels+=("${short:-${id: -4}} $(fmt_range "$range")$(fmt_dir "$bearing") $(fmt_batt "$batt") $(fmt_age "$age")")
    done < "$RUN/nodes" 2>/dev/null
    if [ ${#ids[@]} -eq 0 ]; then
        PROMPT "No mesh nodes heard yet."
        return 1
    fi
    r=$(LIST_PICKER "${1:-Nodes}" "${labels[@]}" "< Back" "${labels[0]}"); picker_ok $? || return 1
    for i in "${!labels[@]}"; do
        if [ "${labels[$i]}" = "$r" ]; then PICK_ID=${ids[$i]}; PICK_NAME=${names[$i]}; return 0; fi
    done
    return 1
}

direct_message() {  # direct_message [!nodeid name]
    local mode msg
    status_read
    if [ -z "$1" ]; then pick_node "Message to" || return; else PICK_ID=$1; PICK_NAME=$2; fi
    mode=$(LIST_PICKER "To $PICK_NAME" "Quick message" "Type message" "Quick message"); picker_ok $? || return
    case "$mode" in
        "Quick message") msg=$(pick_quick "To $PICK_NAME") || return ;;
        *)               msg=$(type_msg "To $PICK_NAME") || return ;;
    esac
    send_text "$msg" "$PICK_ID" 0
}

channel_message() {  # channel_message quick|type
    local msg
    pick_channel || return
    if [ "$1" = quick ]; then msg=$(pick_quick "To $CH_NAME") || return
    else msg=$(type_msg "To $CH_NAME") || return; fi
    send_text "$msg" all "$CH_IDX"
}

# Conversations: one per DM contact (dm:!nodeid) and one per channel (ch:<index>), newest first
conv_list() {
    local convs=() titles=() labels=() c t u i r
    while IFS='|' read -r c t u _ _; do
        [ -z "$c" ] && continue
        convs+=("$c"); titles+=("$t")
        if [ "${u:-0}" -gt 0 ]; then labels+=("$t ($u new)"); else labels+=("$t"); fi
        [ ${#convs[@]} -ge 25 ] && break
    done < "$RUN/convs" 2>/dev/null
    if [ ${#convs[@]} -eq 0 ]; then
        PROMPT "No chats in the last 7 days."
        return 1
    fi
    r=$(LIST_PICKER "Conversations" "${labels[@]}" "< Back" "${labels[0]}"); picker_ok $? || return 1
    for i in "${!labels[@]}"; do
        [ "${labels[$i]}" = "$r" ] && { conv_view "${convs[$i]}" "${titles[$i]}"; return 0; }
    done
    return 1
}

conv_reply() {  # conv_reply conv title quick|type
    local msg
    if [ "$3" = quick ]; then msg=$(pick_quick "To $2") || return; else msg=$(type_msg "To $2") || return; fi
    case "$1" in
        dm:*) send_text "$msg" "${1#dm:}" 0 ;;
        ch:*) send_text "$msg" all "${1#ch:}" ;;
    esac
}

conv_view() {  # conv_view conv title
    local conv=$1 title=$2 mids=() labels=() lines=() mid t dir who st txt i r line
    while :; do
        mesh_cmd "thread $conv" || { LOG red "Chat not loaded: $MESH_MSG"; return; }
        mesh_cmd "read $conv" >/dev/null
        INBOX_SEEN=$(wc -l < "$RUN/inbox" 2>/dev/null || echo 0)
        mids=(); labels=(); lines=()
        while IFS='|' read -r mid t dir who st txt; do
            [ -z "$mid" ] && continue
            line="$(date -d "@$t" +%H:%M 2>/dev/null) $who: $txt"
            [ "$dir" = out ] && [ "$st" = delivered ] && line+=" (delivered)"
            [ "$dir" = out ] && [ "$st" = failed ] && line+=" (failed)"
            lines+=("$dir|$line")
            mids=("$mid" "${mids[@]}"); labels=("${line:0:44}" "${labels[@]}")   # newest first
        done < "$RUN/thread"
        LOG white "---- $title ----"
        if [ ${#lines[@]} -eq 0 ]; then LOG white "No messages yet"; fi
        i=$(( ${#lines[@]} > 12 ? ${#lines[@]} - 12 : 0 ))
        for line in "${lines[@]:i}"; do
            if [ "${line%%|*}" = out ]; then LOG white "${line#*|}"; else LOG cyan "${line#*|}"; fi
        done
        [ ${#labels[@]} -gt 15 ] && { mids=("${mids[@]:0:15}"); labels=("${labels[@]:0:15}"); }
        r=$(LIST_PICKER "$title" "Reply (type)" "Reply (quick)" "${labels[@]}" "Delete conversation" "< Back" "Reply (type)")
        picker_ok $? || return
        case "$r" in
            "Reply (type)")  conv_reply "$conv" "$title" type; continue ;;
            "Reply (quick)") conv_reply "$conv" "$title" quick; continue ;;
            "Delete conversation")
                [ "$(CONFIRMATION_DIALOG "Delete the conversation $title? This also deletes it from the chat logs.")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || continue
                if mesh_cmd "del conv $conv"; then LOG green "Deleted: $title ($MESH_MSG)"; else LOG red "Not deleted: $MESH_MSG"; fi
                return ;;
            "< Back"|"") return ;;
        esac
        for i in "${!labels[@]}"; do
            [ "${labels[$i]}" = "$r" ] || continue
            [ "$(LIST_PICKER "${r:0:30}" "Delete message" "< Back" "< Back")" = "Delete message" ] || break
            if mesh_cmd "del msg ${mids[$i]}"; then LOG green "Message deleted"; else LOG red "Not deleted: $MESH_MSG"; fi
            break
        done
    done
}

delete_all_chats() {
    [ "$(CONFIRMATION_DIALOG "Delete ALL chats? This also deletes the chat logs in $LOOT_DIR.")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || return
    if mesh_cmd "del all"; then LOG green "All chats deleted ($MESH_MSG)"; else LOG yellow "$MESH_MSG"; fi
    INBOX_SEEN=$(wc -l < "$RUN/inbox" 2>/dev/null || echo 0)
}

# New messages since last check -> Pager log + sound
INBOX_SEEN=0
check_inbox() {
    local n t label from txt
    [ -s "$RUN/inbox" ] || return 0
    n=$(wc -l < "$RUN/inbox")
    [ "$n" -gt "$INBOX_SEEN" ] || return 0
    local dm="" dmfrom="" dmtxt=""
    while IFS='|' read -r t label from txt; do
        LOG cyan "[$label] $from: $txt"
        [ "$label" = DM ] && { dm=1; dmfrom=$from; dmtxt=$txt; }
    done < <(tail -n "$((n - INBOX_SEEN))" "$RUN/inbox")
    INBOX_SEEN=$n
    if [ -n "$dm" ] && [ "$C_DM_ALERT" != off ]; then     # direct message: its own alert
        LED MAGENTA FAST
        RINGTONE alert >/dev/null 2>&1 &
        [ "$C_DM_ALERT" = popup ] && ALERT "DM from $dmfrom
${dmtxt:0:120}" >/dev/null 2>&1 &
        (sleep 4; if [ "$S_LINK" = connected ]; then LED GREEN; else LED RED SLOW; fi) >/dev/null 2>&1 &
        return 0
    fi
    [ -n "$C_RINGTONE" ] && RINGTONE "$C_RINGTONE" >/dev/null 2>&1 &
}

menu_chat() {
    local r convs n last="Conversations"
    while :; do
        convs="Conversations"; n=$(unread_count); [ "$n" -gt 0 ] && convs="Conversations ($n new)"
        [[ $last == Conversations* ]] && last=$convs
        r=$(LIST_PICKER "Chat" "$convs" "Message channel" "Quick message channel" "Direct message" "Delete all chats" "< Back" "$last")
        picker_ok $? || return
        last=$r
        case "$r" in
            Conversations*)          conv_list ;;
            "Message channel")       channel_message type ;;
            "Quick message channel") channel_message quick ;;
            "Direct message")        direct_message ;;
            "Delete all chats")      delete_all_chats ;;
            *) return ;;
        esac
    done
}

#############################################################################
# Map, nodes, status
#############################################################################

map_ready() {
    configure_python || return 1
    "$PYTHON_BIN" -B "$MAP_DIR/pagermesh_map.py" --self-check >/dev/null 2>&1
}

map_view() {  # map_view [extra map args...]
    local rc
    map_ready || { ERROR_DIALOG "The map could not start (python3-light / map files)."; return; }
    rm -f "$RUN/map_source"
    if ! UI_TAKEOVER >/dev/null 2>&1; then
        ERROR_DIALOG "Could not take over the display (UI_TAKEOVER). Update the Pager firmware."
        return
    fi
    PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$MAP_DIR/pagermesh_map.py" --run "$RUN" --tiles "$TILE_DIR" \
        --sources "$MAP_DIR/sources" --source "$C_MAP_SOURCE" --zoom "$MAP_ZOOM" \
        --callsign "${S_NAME:-PAGER}" --max-age "$NODE_MAX_AGE" ${C_MANUAL:+--manual "$C_MANUAL"} "$@" 2> /tmp/pagermesh-map.log
    rc=$?
    UI_RELEASE >/dev/null 2>&1
    [ "$rc" -ne 0 ] && LOG red "Map exited ($rc) - see /tmp/pagermesh-map.log"
    if [ -s "$RUN/map_source" ]; then cfg_set map_source "$(head -n1 "$RUN/map_source")"; load_config; fi
}

nodes_view() {
    local act lat lon f fav items=()
    status_read
    pick_node "Nodes (range from you)" || return
    while :; do
        f="$RUN/tracks.d/${PICK_ID/!/n}"
        items=()
        [ -s "$f" ] && items+=("Navigate to" "Show on map")
        fav="Add to favorites"
        mesh_cmd "node $PICK_ID" >/dev/null && grep -q "  Favorite" "$RUN/node" && fav="Remove from favorites"
        items+=("Direct message" "Details" "Traceroute" "Request position" "$fav" "< Back")
        act=$(LIST_PICKER "$PICK_NAME" "${items[@]}" "${items[0]}")
        picker_ok $? || return
        case "$act" in
            "Navigate to")    map_view --nav "${PICK_ID/!/n}" ;;
            "Show on map")    IFS='|' read -r lat lon _ < "$f"; map_view --center "$lat,$lon" ;;
            "Direct message") direct_message "$PICK_ID" "$PICK_NAME" ;;
            "Details")        node_details ;;
            "Traceroute")     node_traceroute ;;
            "Request position")
                if mesh_cmd "reqpos $PICK_ID"; then LOG green "$MESH_MSG"; else LOG red "$MESH_MSG"; fi ;;
            "Add to favorites"|"Remove from favorites")
                if mesh_cmd "fav $PICK_ID $([ "$act" = "Add to favorites" ] && echo 1 || echo 0)"; then LOG green "$MESH_MSG"
                else LOG red "$MESH_MSG"; fi ;;
            *) return ;;
        esac
    done
}

node_details() {
    local line
    mesh_cmd "node $PICK_ID" || { LOG red "$MESH_MSG"; return; }
    LOG white "---- $PICK_NAME ----"
    while IFS= read -r line; do LOG white "$line"; done < "$RUN/node"
}

node_traceroute() {
    local i id
    mesh_cmd "trace $PICK_ID" || { LOG red "$MESH_MSG"; return; }
    LOG white "$MESH_MSG"
    id=$(START_SPINNER "Traceroute to $PICK_NAME")
    for ((i = 0; i < 60; i++)); do
        sleep 1
        mesh_cmd "trace_result $PICK_ID" && [ "$MESH_MSG" != "waiting..." ] && break
    done
    STOP_SPINNER "$id"
    if [ "$MESH_MSG" = "waiting..." ] || [ "$MESH_MSG" = "no answer" ]; then LOG yellow "Traceroute: no answer yet"
    else LOG green "Route: $MESH_MSG"; fi
}

send_position() {
    if mesh_cmd pos; then LOG green "Position sent over the mesh"; else LOG yellow "Position not sent: $MESH_MSG"; fi
}

show_status() {
    status_read
    LOG white "---- PagerMesh $PAYLOAD_VERSION ----"
    LOG white "Node: ${S_NAME:-?} ${S_ID}"
    LOG white "Radio: $(conn_label)"
    case "$S_LINK" in
        connected) LOG green "Mesh: connected  Region: ${S_REGION:-?}" ;;
        *)         LOG yellow "Mesh: ${S_LINK:-starting}${S_ERR:+ ($S_ERR)}" ;;
    esac
    [ "$S_REGION" = UNSET ] && LOG red "Region not set - Settings > Radio settings > Region"
    LOG white "Nodes heard: $S_NODES   Unread: $(unread_count)"
    if read_gps; then LOG green "GPS: $G_LAT, $G_LON  sats $G_SATS"; else LOG yellow "GPS: no fix"; fi
    if [ "$C_POS" -gt 0 ]; then LOG white "Position: every $((C_POS / 60)) min"; else LOG white "Position: manual only"; fi
    [ "$S_LASTPOS" -gt 0 ] && LOG white "Last position sent: $(date -d "@$S_LASTPOS" +%H:%M 2>/dev/null)"
    if [ "$C_WEB" = 1 ]; then log_web_urls; fi
}

#############################################################################
# Settings
#############################################################################

settings_position() {
    local r v pc pn kind every
    while :; do
        pc=$(cfg_get pos_chan ""); pn="nobody (off)"
        if [ -n "$pc" ]; then
            pn=$(awk -F'|' -v i="$pc" '$1 == i {print $2 " (" ($3 == "private" ? "own key" : "public") ")"}' "$RUN/channels" 2>/dev/null)
            [ -n "$pn" ] || pn="channel $pc"
        fi
        if [ "$C_POS" -gt 0 ]; then every="Every $((C_POS / 60)) min"; else every="Manual only"; fi
        r=$(LIST_PICKER "Send position" "Share on: $pn" "How often: $every" "< Back" "Share on: $pn"); picker_ok $? || return
        case "$r" in
            "Share on"*)
                v=$(LIST_PICKER "Share position on" "Nobody (off)" "Pick a channel" "Pick a channel"); picker_ok $? || continue
                if [ "$v" = "Nobody (off)" ]; then app_set pos_chan ""; LOG yellow "Position sharing off"; continue; fi
                pick_channel || continue
                kind=$(awk -F'|' -v i="$CH_IDX" '$1 == i {print $3}' "$RUN/channels" 2>/dev/null)
                if [ "$kind" != private ]; then
                    v=$(LIST_PICKER "$CH_NAME is public" "Share on it anyway" "Cancel" "Cancel"); picker_ok $? || continue
                    [ "$v" = "Share on it anyway" ] || continue
                fi
                app_set pos_chan "$CH_IDX"; LOG green "Position shared on: $CH_NAME" ;;
            "How often"*)
                v=$(LIST_PICKER "Send position" "Every 5 min" "Every 15 min" "Every 30 min" "Every 60 min" "Manual only" "$every"); picker_ok $? || continue
                case "$v" in
                    "Every 5 min") v=300 ;; "Every 15 min") v=900 ;; "Every 30 min") v=1800 ;; "Every 60 min") v=3600 ;; *) v=0 ;;
                esac
                cfg_set pos_interval "$v"; load_config
                printf '%s\n' "$C_POS" > "$RUN/pos_interval"
                LOG green "Position interval saved" ;;
            *) return ;;
        esac
    done
}

set_web_password() {
    local pw line
    pw=$(TEXT_PICKER "Web password (8+ chars)" ""); picker_ok $? || return 1
    [ ${#pw} -ge 8 ] || { ERROR_DIALOG "Password must be at least 8 characters."; return 1; }
    line=$(printf '%s\n' "$pw" | "$PYTHON_BIN" -B "$MESH_PY" --hash-password --web-dir "$WEB_DIR" 2>/dev/null)
    [ -n "$line" ] || { ERROR_DIALOG "Could not save the password."; return 1; }
    ( umask 077; printf '%s\n' "$line" > "$WEB_AUTH.tmp" ) && mv "$WEB_AUTH.tmp" "$WEB_AUTH"
    LOG green "Web password saved"
}

settings_web() {
    local r
    r=$(LIST_PICKER "Web console" "$([ "$C_WEB" = 1 ] && echo "Turn OFF" || echo "Turn ON")" "Listen on" "Set password" "Show address" "< Back" "Show address"); picker_ok $? || return
    case "$r" in
        "Turn ON")
            [ -s "$WEB_AUTH" ] || set_web_password || return
            cfg_set web 1; load_config; rm -f "$RUN/web"; svc_restart; web_check ;;
        "Turn OFF")     cfg_set web 0; load_config; svc_restart; LOG "Web console off" ;;
        "Set password") set_web_password && [ "$C_WEB" = 1 ] && { rm -f "$RUN/web"; svc_restart; web_check; } ;;
        "Listen on")
            pick_web_listen || return
            if [ "$C_WEB_LISTEN" = all ]; then LOG yellow "Web console: all networks (anyone on them can reach the sign-in page)"
            else LOG green "Web console: Pager Wi-Fi / USB-C only"; fi
            [ "$C_WEB" = 1 ] && { rm -f "$RUN/web"; svc_restart; web_check; } ;;
        "Show address") if [ "$C_WEB" = 1 ]; then log_web_urls; else LOG "Web console is off"; fi ;;
    esac
}

settings_sound() {
    local r; r=$(LIST_PICKER "Message sound" bonus success alert warning none "${C_RINGTONE:-none}"); picker_ok $? || return
    cfg_set ringtone "$r"; load_config
}

settings_boot() {
    local r
    [ -f "$GLYTCH_PAYLOAD" ] || { ERROR_DIALOG "Glytch Meshtastic payload not found."; return; }
    r=$(LIST_PICKER "Meshtastic at boot ($(boot_on && echo ON || echo OFF))" "Turn ON" "Turn OFF" "< Back" "< Back"); picker_ok $? || return
    case "$r" in
        "Turn ON")  glytch --boot-on ;;
        "Turn OFF") glytch --boot-off ;;
    esac
}

settings_conn() {
    local r old=$C_CONN$C_HOST$C_PORT$C_DEV
    LOG white "Radio: $(conn_label)"
    r=$(LIST_PICKER "Radio connection" "Change on the Pager" "Change in a web browser" "< Back" "< Back"); picker_ok $? || return
    case "$r" in
        "Change on the Pager") setup_on_pager || return ;;
        "Change in a web browser")
            if [ "$C_WEB" != 1 ]; then
                [ "$(CONFIRMATION_DIALOG "This turns the web console on. Continue?")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || return
                [ -s "$WEB_AUTH" ] || set_web_password || return
                cfg_set web 1; load_config; rm -f "$RUN/web"; svc_restart; web_check || return
            fi
            log_web_urls; LOG white "Open the address > Settings"
            return ;;
        *) return ;;
    esac
    [ "$old" = "$C_CONN$C_HOST$C_PORT$C_DEV" ] && return
    reconnect
}

# after the connection changed: make sure the Mod's meshtasticd runs, restart the service
reconnect() {
    if [ "$C_CONN" = mod ] && ! { mesh_installed && mesh_running; }; then
        LOG yellow "meshtasticd is not running - exit and run PagerMesh again to set it up"
    fi
    svc_restart
}

# ---- settings of the radio itself (owner name, region, preset, role...) through the mesh service
declare -A RV
radio_load() {
    local k v
    mesh_cmd radio || { ERROR_DIALOG "Radio settings not available: $MESH_MSG"; return 1; }
    RV=()
    while IFS='=' read -r k v; do [ -n "$k" ] && RV[$k]=$v; done < "$RUN/radio"
}

# pick_choice key title -> sets PICK_NUM PICK_LABEL from RUN/choices (key|num|name)
pick_choice() {
    local k n name names=() nums=() cur="" i r
    while IFS='|' read -r k n name; do
        [ "$k" = "$1" ] || continue
        names+=("$name"); nums+=("$n")
        [ "$n" = "${RV[$1]}" ] && cur=$name
    done < "$RUN/choices"
    [ ${#names[@]} -gt 0 ] || return 1
    r=$(LIST_PICKER "$2" "${names[@]}" "${cur:-${names[0]}}"); picker_ok $? || return 1
    for i in "${!names[@]}"; do
        [ "${names[$i]}" = "$r" ] && { PICK_NUM=${nums[$i]}; PICK_LABEL=$r; return 0; }
    done
    return 1
}

choice_name() {  # choice_name key num
    local k n name
    while IFS='|' read -r k n name; do [ "$k" = "$1" ] && [ "$n" = "$2" ] && { printf '%s' "$name"; return; }; done < "$RUN/choices"
    printf '%s' "$2"
}

radio_set() {  # radio_set key=value ...
    if mesh_cmd set "$@"; then LOG green "$MESH_MSG"; else LOG red "Not saved: $MESH_MSG"; fi
}

settings_radio() {
    local r name reg pre role hop pos long short v
    radio_load || return
    while :; do
        name="Name: ${RV[owner.long]} (${RV[owner.short]})"
        reg="Region: $(choice_name lora.region "${RV[lora.region]}")"
        pre="Preset: $(choice_name lora.modem_preset "${RV[lora.modem_preset]}")"
        role="Role: $(choice_name device.role "${RV[device.role]}")"
        hop="Hop limit: ${RV[lora.hop_limit]}"
        pos="Radio position: every ${RV[position.position_broadcast_secs]:-0} s"
        r=$(LIST_PICKER "Radio settings" "$name" "$reg" "$pre" "$role" "$hop" "$pos" "Channel QR code" "Restart radio" "< Back" "$name")
        picker_ok $? || return
        case "$r" in
            Name:*)
                long=$(TEXT_PICKER "Long name (max 39)" "${RV[owner.long]}"); picker_ok $? || continue
                short=$(TEXT_PICKER "Short name (max 4)" "${RV[owner.short]}"); picker_ok $? || continue
                if mesh_cmd owner "long=$long" "short=$short"; then LOG green "$MESH_MSG"; else LOG red "Not saved: $MESH_MSG"; fi ;;
            Region:*)
                pick_choice lora.region "Region" || continue
                [ "$(CONFIRMATION_DIALOG "Set the region to $PICK_LABEL? Use only the region where you are - the wrong one can be illegal. The radio restarts.")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || continue
                radio_set "lora.region=$PICK_NUM" ;;
            Preset:*)
                pick_choice lora.modem_preset "Modem preset" || continue
                [ "$(CONFIRMATION_DIALOG "Set the preset to $PICK_LABEL? Only radios on the same preset hear each other. The radio restarts.")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || continue
                radio_set "lora.modem_preset=$PICK_NUM" ;;
            Role:*)
                pick_choice device.role "Role" || continue
                [ "$(CONFIRMATION_DIALOG "Set the role to $PICK_LABEL? The radio restarts.")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || continue
                radio_set "device.role=$PICK_NUM" ;;
            "Hop limit"*)
                v=$(LIST_PICKER "Hop limit" 1 2 3 4 5 6 7 "${RV[lora.hop_limit]:-3}"); picker_ok $? || continue
                radio_set "lora.hop_limit=$v" ;;
            "Radio position"*)
                v=$(LIST_PICKER "Radio position broadcast" "Off" "5 min" "15 min" "30 min" "60 min" "15 min"); picker_ok $? || continue
                case "$v" in Off) v=0 ;; "5 min") v=300 ;; "15 min") v=900 ;; "30 min") v=1800 ;; *) v=3600 ;; esac
                radio_set "position.position_broadcast_secs=$v" ;;
            "Channel QR code")
                [ "$(CONFIRMATION_DIALOG "Show the channel QR code? It holds your channel keys.")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || continue
                mesh_cmd share || { LOG red "$MESH_MSG"; continue; }
                configure_python || continue
                if UI_TAKEOVER >/dev/null 2>&1; then
                    "$PYTHON_BIN" -B "$MAP_DIR/pagermesh_qr.py" --file "$RUN/share" 2>> /tmp/pagermesh-map.log
                    UI_RELEASE >/dev/null 2>&1
                fi
                rm -f "$RUN/share" ;;
            "Restart radio")
                [ "$(CONFIRMATION_DIALOG "Restart the radio?")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || continue
                if mesh_cmd reboot; then LOG green "$MESH_MSG"; else LOG red "$MESH_MSG"; fi ;;
            *) return ;;
        esac
        sleep 1
        radio_load || return
    done
}

# ---- mesh <-> TAK bridge
settings_tak() {
    local r on host port proto pos chat chan v certs
    while :; do
        on=$(cfg_get tak_on 0); host=$(cfg_get tak_host ""); proto=$(cfg_get tak_proto tcp)
        port=$(cfg_get tak_port ""); pos=$(cfg_get tak_pos 1); chat=$(cfg_get tak_chat 1); chan=$(cfg_get tak_chan "")
        [ -z "$port" ] && case "$proto" in tls) port=8089 ;; *) port=8087 ;; esac
        mesh_cmd bridge >/dev/null
        r=$(LIST_PICKER "Mesh <-> TAK" "Bridge: $([ "$on" = 1 ] && echo ON || echo OFF)" \
            "Server: ${host:-not set}:$port ${proto^^}" "Mesh nodes to TAK: $([ "$pos" = 1 ] && echo ON || echo OFF)" \
            "Chat both ways: $([ "$chat" = 1 ] && echo ON || echo OFF)" "Mesh channel: ${chan:-none (chat paused)}" "Status" "< Back" "Status")
        picker_ok $? || return
        case "$r" in
            Bridge:*)
                if [ "$on" = 1 ]; then app_set tak_on 0; LOG yellow "TAK bridge off"
                else
                    [ -n "$host" ] || { ERROR_DIALOG "Set the TAK server first."; continue; }
                    app_set tak_on 1; LOG green "TAK bridge on"
                fi ;;
            Server:*)
                v=$(LIST_PICKER "TAK protocol" "TLS 8089 (certificate)" "TCP 8087" "UDP (send only)" "TCP 8087"); picker_ok $? || continue
                case "$v" in TLS*) proto=tls; port=8089 ;; TCP*) proto=tcp; port=8087 ;; *) proto=udp; port=8087 ;; esac
                host=$(TEXT_PICKER "TAK server address" "$host"); picker_ok $? || continue
                host=${host// /}
                [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || { ERROR_DIALOG "Enter an IP address or host name."; continue; }
                port=$(TEXT_PICKER "Port" "$port"); picker_ok $? || continue
                [[ $port =~ ^[0-9]+$ ]] || port=8087
                if [ "$proto" = tls ]; then
                    certs=""
                    for v in "$PAYLOAD_DIR/certs" "$PAYLOAD_DIR/../PagerTAK/certs"; do [ -s "$v/client.pem" ] && certs=$v; done
                    if [ -z "$certs" ]; then ERROR_DIALOG "TLS needs client.pem (and ca.pem) in $PAYLOAD_DIR/certs - or PagerTAK's certs. See the README."
                    elif ! command -v openssl >/dev/null 2>&1; then ERROR_DIALOG "TLS needs openssl: opkg install openssl-util"; fi
                fi
                app_set tak_proto "$proto" tak_host "$host" tak_port "$port"
                LOG green "TAK server: $host:$port ${proto^^}" ;;
            "Mesh nodes"*) app_set tak_pos "$([ "$pos" = 1 ] && echo 0 || echo 1)" ;;
            "Chat both"*)  app_set tak_chat "$([ "$chat" = 1 ] && echo 0 || echo 1)" ;;
            "Mesh channel"*)
                pick_channel private || continue
                app_set tak_chan "$CH_IDX"; LOG green "Bridged channel: $CH_NAME" ;;
            Status) mesh_cmd bridge; LOG white "TAK bridge: $MESH_MSG" ;;
            *) return ;;
        esac
    done
}

settings_alerts() {
    local r
    r=$(LIST_PICKER "Direct message alert" "Sound + light" "Sound + light + popup" "Off (like other messages)" \
        "$(case "$C_DM_ALERT" in popup) echo "Sound + light + popup" ;; off) echo "Off (like other messages)" ;; *) echo "Sound + light" ;; esac)")
    picker_ok $? || return
    case "$r" in *popup) app_set dm_alert popup ;; Off*) app_set dm_alert off ;; *) app_set dm_alert sound ;; esac
    LOG green "DM alert: $r"
}

settings_hide() {
    local r v
    r=$(LIST_PICKER "Hide nodes not heard for" "Show all" "1 hour" "2 hours" "6 hours" "24 hours" "Show all"); picker_ok $? || return
    case "$r" in "1 hour") v=3600 ;; "2 hours") v=7200 ;; "6 hours") v=21600 ;; "24 hours") v=86400 ;; *) v=0 ;; esac
    app_set hide_age "$v"; LOG green "Node list: ${r,,}"
}

# ---- mesh SIGINT
menu_sigint() {
    local r line
    while :; do
        r=$(LIST_PICKER "Mesh SIGINT" "Traffic stats" "Last packets" "Save capture to loot" "Preset scan" "Stop preset scan" "< Back" "Traffic stats")
        picker_ok $? || return
        case "$r" in
            "Traffic stats")
                mesh_cmd sigint || { LOG red "$MESH_MSG"; continue; }
                LOG white "---- mesh traffic ----"
                while IFS= read -r line; do LOG white "$line"; done < "$RUN/sigint" ;;
            "Last packets")
                LOG white "---- last packets ----"
                while IFS= read -r line; do LOG white "${line:0:78}"; done < <(tail -n 12 "$RUN/packets.log" 2>/dev/null) ;;
            "Save capture to loot")
                if mesh_cmd export; then LOG green "Saved $LOOT_DIR/$MESH_MSG"; else LOG red "$MESH_MSG"; fi ;;
            "Preset scan")
                [ "$(CONFIRMATION_DIALOG "Scan the modem presets? The radio switches preset every minute (it restarts each time) and goes back to its own settings at the end. You are off your mesh while it runs.")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || continue
                if mesh_cmd "scan 60"; then LOG green "$MESH_MSG - see Traffic stats"; else LOG red "$MESH_MSG"; fi ;;
            "Stop preset scan")
                if mesh_cmd "scan stop"; then LOG yellow "$MESH_MSG"; else LOG white "$MESH_MSG"; fi ;;
            *) return ;;
        esac
    done
}

settings_menu() {
    local r
    while :; do
        check_setup_req
        r=$(LIST_PICKER "Settings" "Radio connection" "Radio settings" "Send position" "TAK bridge" "DM alert" "Hide old nodes" \
            "Web console" "Message sound" "Meshtastic at boot" "< Back" "Radio connection"); picker_ok $? || return
        case "$r" in
            "Radio connection")   settings_conn ;;
            "Radio settings")     settings_radio ;;
            "Send position")      settings_position ;;
            "TAK bridge")         settings_tak ;;
            "DM alert")           settings_alerts ;;
            "Hide old nodes")     settings_hide ;;
            "Web console")        settings_web ;;
            "Message sound")      settings_sound ;;
            "Meshtastic at boot") settings_boot ;;
            *) return ;;
        esac
    done
}

exit_question() {
    if [ "$C_CONN" = mod ]; then printf 'Exit PagerMesh? Meshtastic keeps running for the phone app.'
    else printf 'Exit PagerMesh?'; fi
}

main_menu() {
    local r chat n last="${MENU_LAST:-Nodes}"
    while :; do
        check_setup_req
        chat="Chat >"; n=$(unread_count); [ "$n" -gt 0 ] && chat="Chat > ($n new)"
        [ "$last" = "Chat >" ] && last=$chat
        r=$(LIST_PICKER "PagerMesh" "Map" "Nodes" "$chat" "Send position now" "SIGINT >" "Status" "Settings >" "Exit PagerMesh" "< Back" "$last")
        picker_ok $? || return 0
        last=$r; [[ $r == "Chat >"* ]] && last="Chat >"; MENU_LAST=$last
        case "$r" in
            "Map")               status_read; map_view ;;
            "Nodes")             nodes_view ;;
            "Chat >"*)           menu_chat ;;
            "Send position now") send_position ;;
            "SIGINT >")          menu_sigint ;;
            "Status")            show_status ;;
            "Settings >")        settings_menu ;;
            "Exit PagerMesh")
                [ "$(CONFIRMATION_DIALOG "$(exit_question)")" = "$DUCKYSCRIPT_USER_CONFIRMED" ] && return 10 ;;
            *) return 0 ;;
        esac
    done
}

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
    [ -s "$RUN/setup_req" ] && apply_setup_req     # a radio saved in the web console is never lost
    check_cfg_req
    : > "$RUN/stop" 2>/dev/null
    svc_stop
    [ -n "$GPS_PID" ] && kill "$GPS_PID" 2>/dev/null
    sleep 1
    rm -rf "$RUN"
    LED OFF
}

#############################################################################
# Main
#############################################################################

LED MAGENTA
LOG cyan "PagerMesh $PAYLOAD_VERSION"
load_config

if ! configure_python; then install_python || exit 1; fi
# a mesh service left over from an earlier run (crash, power loss, old version)
# would hold the web console port and the radio's single API connection
if pgrep -f "mesh/pagermesh.py" >/dev/null 2>&1; then
    LOG yellow "Stopping a PagerMesh service left from an earlier run"
    pkill -f "mesh/pagermesh.py" 2>/dev/null
    sleep 2
    pkill -9 -f "mesh/pagermesh.py" 2>/dev/null
fi
rm -rf "$RUN"; mkdir -p "$RUN/outbox" "$RUN/tracks.d" "$LOOT_DIR"
trap cleanup EXIT

if [ -z "$C_CONN" ]; then
    first_run_setup || { LOG red "Setup cancelled"; exit 0; }
fi

[ "$C_CONN" = mod ] && mesh_prepare

# web console on, but its password file is gone (for example the folder was replaced)
if [ "$C_WEB" = 1 ] && [ ! -s "$WEB_AUTH" ]; then
    LOG yellow "Web console is on but has no password (folder replaced?)"
    set_web_password || { cfg_set web 0; load_config; LOG yellow "Web console turned off"; }
fi

gps_loop &
GPS_PID=$!
svc_start

LED CYAN SLOW
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1; status_read; [ "$S_LINK" = connected ] && break
done
if [ "$S_LINK" = connected ]; then
    LED GREEN
    LOG green "Mesh: ${S_NAME:-$S_ID}  nodes: $S_NODES"
    [ "$S_REGION" = UNSET ] && LOG red "Region not set - Settings > Radio settings > Region"
else
    LED RED SLOW
    LOG yellow "Not connected yet${S_ERR:+: $S_ERR} - retrying in the background"
fi
[ "$C_WEB" = 1 ] && web_check
LOG white "A=Menu  UP=Quick msg  DOWN=Type msg"
LOG white "RIGHT=Send pos  LEFT=Status  B=Exit"

led_state=$S_LINK
while :; do
    BUTTON=$(WAIT_FOR_INPUT 1)
    check_inbox
    status_read
    if [ "$S_LINK" != "$led_state" ]; then
        case "$S_LINK" in
            connected)    LED GREEN ;;
            connecting)   LED CYAN SLOW ;;
            *)            LED RED SLOW ;;
        esac
        [ -n "$led_state" ] && [ "$S_LINK" = disconnected ] && LOG yellow "Mesh link lost${S_ERR:+: $S_ERR}"
        [ -n "$led_state" ] && [ "$S_LINK" = connected ] && LOG green "Mesh link back"
        led_state=$S_LINK
    fi
    check_setup_req                            # connection saved in the web console
    svc_running || { LOG yellow "Mesh service stopped - restarting (see $SVC_LOG)"; svc_start; }
    [ -z "$BUTTON" ] && continue
    case "$BUTTON" in
        A)     main_menu; [ $? -eq 10 ] && { LOG red "Exiting PagerMesh..."; break; } ;;
        UP)    msg=$(pick_quick "Quick msg to Primary") && send_text "$msg" all 0 ;;
        DOWN)  msg=$(type_msg "Message to Primary") && send_text "$msg" all 0 ;;
        RIGHT) send_position ;;
        LEFT)  show_status ;;
        B)
            if [ "$(CONFIRMATION_DIALOG "$(exit_question)")" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                LOG red "Exiting PagerMesh..."
                break
            fi ;;
    esac
done

exit 0
