#!/bin/bash
# Title: NetBird VPN
# Description: Install, enroll and control the NetBird WireGuard mesh VPN client on the Pager
# Author: SECT0101
# Version: 1.0
# Category: Remote-Access
#
# Joins the Pager to a NetBird network (NetBird cloud or self-hosted) as a
# client peer, so payloads like PagerTAK can reach servers on that network
# (e.g. a TAK Server that is a NetBird peer) from any internet connection.
#
# Uses the official OpenWrt "netbird" package (opkg). It is installed to
# internal flash when there is room, otherwise to the SD card (/mmc).
#
# The setup key is used once to enroll and is NOT stored by this payload.
# NetBird keeps its own peer identity in its config file after enrollment.
#
# LED State Descriptions
#   Magenta Solid  - Installing / configuring
#   Cyan Slow      - Connecting
#   Green Solid    - Connected
#   Red Slow       - Not connected / error

# Options
MANAGEMENT_URL=""               # blank = NetBird cloud. Self-hosted: https://netbird.example.com:443
PEER_HOSTNAME=""                # blank = Pager hostname
TEST_HOST=""                    # optional host:port to test over the VPN (blank = PagerTAK's TAK Server)

#############################################################################

CFG_NS="netbirdvpn"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/mmc/usr/sbin:/mmc/usr/bin:/mmc/sbin:/mmc/bin:$PATH"
NB_LOG="/tmp/netbird-payload.log"
NB_PIDFILE="/tmp/netbird-payload.pid"

picker_ok() {
    case "$1" in "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR") return 1 ;; esac
    return 0
}
confirm() { [ "$(CONFIRMATION_DIALOG "$1")" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; }
cfg_get() {
    local v; v=$(PAYLOAD_GET_CONFIG "$CFG_NS" "$1" 2>/dev/null)
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}
cfg_set() { PAYLOAD_SET_CONFIG "$CFG_NS" "$1" "$2" >/dev/null 2>&1; }

nb_bin() { command -v netbird 2>/dev/null; }

# netbird config: /etc/netbird/config.json on OpenWrt 24.10 (package default)
NB_CONFIG="/etc/netbird/config.json"

start_daemon() {
    local nb; nb=$(nb_bin) || return 1
    "$nb" status >/dev/null 2>&1 && return 0
    if [ -x /etc/init.d/netbird ]; then
        /etc/init.d/netbird start >/dev/null 2>&1
    else
        # SD-card install has no usable init script: run the daemon ourselves
        mkdir -p "$(dirname "$NB_CONFIG")"
        "$nb" service run --config "$NB_CONFIG" --log-file /tmp/netbird.log >/dev/null 2>&1 &
        echo $! > "$NB_PIDFILE"
    fi
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        "$nb" status >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

stop_daemon() {
    if [ -x /etc/init.d/netbird ]; then
        /etc/init.d/netbird stop >/dev/null 2>&1
    elif [ -f "$NB_PIDFILE" ]; then
        kill "$(cat "$NB_PIDFILE")" 2>/dev/null; rm -f "$NB_PIDFILE"
    fi
}

# Parse `netbird status` into NB_MGMT NB_SIGNAL NB_IP NB_PEERS
read_status() {
    local out
    NB_MGMT="?"; NB_SIGNAL="?"; NB_IP="-"; NB_PEERS="-"
    out=$("$(nb_bin)" status 2>&1) || { NB_MGMT="daemon not running"; return 1; }
    NB_MGMT=$(sed -n 's/^Management:[[:space:]]*//p' <<< "$out" | head -n1)
    NB_SIGNAL=$(sed -n 's/^Signal:[[:space:]]*//p' <<< "$out" | head -n1)
    NB_IP=$(sed -n 's/^NetBird IP:[[:space:]]*//p' <<< "$out" | head -n1)
    NB_PEERS=$(sed -n 's/^Peers count:[[:space:]]*//p' <<< "$out" | head -n1)
    [ -n "$NB_MGMT" ] || NB_MGMT="?"
    [[ $NB_MGMT == Connected* ]]
}

show_status() {
    local up=0
    read_status && up=1
    LOG white "---- NetBird ----"
    LOG white "Management: ${NB_MGMT}"
    LOG white "Signal:     ${NB_SIGNAL:-?}"
    LOG white "NetBird IP: ${NB_IP:--}"
    LOG white "Peers:      ${NB_PEERS:--}"
    if [ "$up" = 1 ]; then LED GREEN; else LED RED SLOW; fi
}

#############################################################################
# install
#############################################################################

free_kb() { df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

install_netbird() {
    local id dest="" root_free mmc_free
    confirm "NetBird is not installed. Install the OpenWrt netbird package now? (internet required)" || return 1
    LED MAGENTA
    id=$(START_SPINNER "Updating")
    opkg update >> "$NB_LOG" 2>&1
    STOP_SPINNER "$id"
    if ! opkg info netbird 2>/dev/null | grep -q '^Package: netbird'; then
        ERROR_DIALOG "No netbird package in this firmware's package feed."
        return 1
    fi
    root_free=$(free_kb /overlay); [ -z "$root_free" ] && root_free=$(free_kb /)
    mmc_free=$(free_kb /mmc)
    # The Go binary is large; prefer internal flash only with comfortable room
    if [ "${root_free:-0}" -gt 40000 ]; then
        dest=""
    elif [ "${mmc_free:-0}" -gt 40000 ] && grep -q '^dest mmc' /etc/opkg.conf 2>/dev/null; then
        dest="mmc"
    else
        ERROR_DIALOG "Not enough free space for NetBird (needs ~40 MB on flash or SD card)."
        return 1
    fi
    id=$(START_SPINNER "Installing NetBird")
    if [ -n "$dest" ]; then
        opkg -d "$dest" install netbird >> "$NB_LOG" 2>&1
    else
        opkg install netbird >> "$NB_LOG" 2>&1
    fi
    STOP_SPINNER "$id"
    if ! nb_bin >/dev/null; then
        ERROR_DIALOG "NetBird install failed. See $NB_LOG"
        return 1
    fi
    if [ -x /etc/init.d/netbird ]; then
        /etc/init.d/netbird enable >/dev/null 2>&1
        cfg_set boot 1
    fi
    LOG green "NetBird installed ${dest:+to SD card}"
    return 0
}

#############################################################################
# actions
#############################################################################

enroll() {
    local url key host args nb out
    nb=$(nb_bin) || return
    url=$(TEXT_PICKER "Management URL (blank=NetBird cloud)" "$(cfg_get mgmt_url "$MANAGEMENT_URL")")
    picker_ok $? || return
    key=$(TEXT_PICKER "Setup key" "")
    picker_ok $? || return
    [ -z "$key" ] && { LOG red "Setup key required"; return; }
    host=$(TEXT_PICKER "Peer name" "$(cfg_get hostname "${PEER_HOSTNAME:-$(uci -q get system.@system[0].hostname 2>/dev/null || hostname)}")")
    picker_ok $? || return
    cfg_set mgmt_url "$url"; cfg_set hostname "$host"
    start_daemon || { ERROR_DIALOG "NetBird daemon did not start. See /tmp/netbird.log"; return; }
    args=(up --setup-key "$key")
    [ -n "$url" ] && args+=(--management-url "$url")
    [ -n "$host" ] && args+=(--hostname "$host")
    LED CYAN SLOW
    local id; id=$(START_SPINNER "Enrolling")
    out=$(timeout 60 "$nb" "${args[@]}" 2>&1)
    STOP_SPINNER "$id"
    key=""   # drop the key from memory; NetBird keeps its own identity now
    echo "$(date '+%F %T') enroll: ${out//$'\n'/ | }" >> "$NB_LOG"
    if read_status; then
        LOG green "Enrolled - NetBird IP ${NB_IP}"
        cfg_set enrolled 1
        LED GREEN
    else
        LOG red "Enroll failed: $(tail -n1 <<< "$out" | cut -c1-80)"
        LED RED SLOW
    fi
}

connect() {
    local nb id url
    nb=$(nb_bin) || return
    [ "$(cfg_get enrolled 0)" = 1 ] || { LOG yellow "Not enrolled yet - use Enroll"; return; }
    start_daemon || { ERROR_DIALOG "NetBird daemon did not start. See /tmp/netbird.log"; return; }
    LED CYAN SLOW
    id=$(START_SPINNER "Connecting")
    url=$(cfg_get mgmt_url "$MANAGEMENT_URL")
    if [ -n "$url" ]; then timeout 45 "$nb" up --management-url "$url" >> "$NB_LOG" 2>&1
    else timeout 45 "$nb" up >> "$NB_LOG" 2>&1; fi
    STOP_SPINNER "$id"
    show_status
}

disconnect() {
    local nb; nb=$(nb_bin) || return
    "$nb" down >> "$NB_LOG" 2>&1
    LOG yellow "NetBird disconnected"
    LED RED SLOW
}

test_tak() {
    local target host port t0 ms
    target=${TEST_HOST}
    if [ -z "$target" ]; then
        host=$(PAYLOAD_GET_CONFIG pagertak host 2>/dev/null); port=$(PAYLOAD_GET_CONFIG pagertak port 2>/dev/null)
        [ -n "$host" ] && target="$host:${port:-8089}"
    fi
    target=$(TEXT_PICKER "Test host:port" "${target:-tak.example.com:8089}")
    picker_ok $? || return
    host=${target%:*}; port=${target##*:}
    [[ $port =~ ^[0-9]+$ ]] || { LOG red "Use host:port"; return; }
    t0=$(date +%s)
    if timeout 8 bash -c ': <>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null; then
        ms=$(( ($(date +%s) - t0) ))
        LOG green "Reachable: $host:$port (${ms}s)"
        local ip=""
        if [[ $host =~ ^[0-9.]+$ ]]; then ip=$host
        else ip=$(nslookup "$host" 2>/dev/null | awk '/^Address/ && $NF !~ /#/ {a=$NF} END {print a}'); fi
        if [ -n "$ip" ]; then
            if ip route get "$ip" 2>/dev/null | grep -q "dev wt0"; then LOG green "Route: via NetBird (wt0)"
            else LOG white "Route: direct (not via NetBird)"; fi
        fi
    else
        LOG red "NOT reachable: $host:$port"
    fi
}

toggle_boot() {
    if [ ! -x /etc/init.d/netbird ]; then
        LOG yellow "Start on boot needs the internal-flash install (SD install runs only while this payload starts it)"
        return
    fi
    if /etc/init.d/netbird enabled 2>/dev/null; then
        /etc/init.d/netbird disable; cfg_set boot 0; LOG yellow "NetBird will NOT start on boot"
    else
        /etc/init.d/netbird enable; cfg_set boot 1; LOG green "NetBird starts on boot"
    fi
}

uninstall_netbird() {
    confirm "Remove NetBird and its peer identity from this Pager?" || return
    disconnect >/dev/null 2>&1; stop_daemon
    opkg remove netbird >> "$NB_LOG" 2>&1
    rm -f "$NB_CONFIG"
    for k in enrolled mgmt_url hostname boot; do PAYLOAD_DEL_CONFIG "$CFG_NS" "$k" >/dev/null 2>&1; done
    LOG yellow "NetBird removed. Delete the peer in your NetBird dashboard too."
}

#############################################################################
# main
#############################################################################

if ! nb_bin >/dev/null; then
    install_netbird || { LED FAIL; exit 1; }
fi
start_daemon >/dev/null 2>&1
show_status

while :; do
    boot="Start on boot: $( [ -x /etc/init.d/netbird ] && /etc/init.d/netbird enabled 2>/dev/null && echo ON || echo OFF)"
    r=$(LIST_PICKER "NetBird VPN" "Status" "Connect" "Disconnect" "Enroll (setup key)" "Test TAK server" \
        "$boot" "Uninstall" "Exit" "Status")
    picker_ok $? || break
    case "$r" in
        "Status")             show_status ;;
        "Connect")            connect ;;
        "Disconnect")         disconnect ;;
        "Enroll (setup key)") enroll ;;
        "Test TAK server")    test_tak ;;
        "Start on boot"*)     toggle_boot ;;
        "Uninstall")          uninstall_netbird ;;
        *)                    break ;;
    esac
done
LOG white "NetBird keeps running in the background. Use Disconnect to stop it."
exit 0
