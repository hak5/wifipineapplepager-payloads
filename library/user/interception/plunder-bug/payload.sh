#!/bin/bash
# Title: Plunder Bug
# Author: Hak5Darren
# Description: Passively record Ethernet traffic with a Hak5 Plunder Bug LAN Tap

PAYLOAD_HOME="${_PAYLOAD_HOME:-${PAYLOAD_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}}"
SPLASH_IMAGE="$PAYLOAD_HOME/plunder_bug.png"
CONFIG_NAME="plunder_bug"
LOOT_DIR="${PB_LOOT_DIR:-/mmc/root/loot/plunder_bug}"
LOOT_FS="${PB_LOOT_FS:-/mmc}"
SYS_NET="${PB_SYS_NET:-/sys/class/net}"
PROC_IPV6="${PB_PROC_IPV6:-/proc/sys/net/ipv6/conf}"
BUG_IDS="0b95:772b"
FLOOR_MB=500
VERIFY_SECONDS="${PB_VERIFY_SECONDS:-5}"
DETECT_SECONDS="${PB_DETECT_SECONDS:-10}"
RING_FILES=5
HEADER_SNAP=128
RUN_DIR="/tmp/plunder_bug.$$"

FILTERS=("All Traffic" "Web" "DNS" "Email" "Cleartext" "File Shares" "DHCP" "Custom Port" "Custom BPF")
SNAPS=("Full" "Headers")
LIMITS=(25 100 250 500 1000)
DURATIONS=("1 min" "5 min" "15 min" "60 min" "Until Stopped")
MODES=("Stop at Limit" "Ring Buffer")

FILTER="All Traffic"
CUSTOM_PORT=80
CUSTOM_BPF=""
SNAP="Full"
LIMIT_MB=100
DURATION="Until Stopped"
MODE="Stop at Limit"

BUG=""
BUG_MAC=""
MUTED=0
ORIG_V6=""
ORIG_FLAGS=""
RESTORE_NETS=()
MUTE_TX_BASE=0
MUTE_STATE="Unknown"
SPINNER_ID=""
TCPDUMP_PID=""
WATCHDOG_PID=""
CAP_LOG=""
LAST_RX=""
LAST_RX_TIME=""

contains() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

is_yes() {
    [ "$1" = "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]
}

confirm() {
    local answer
    answer=$(CONFIRMATION_DIALOG "$1") || return 1
    is_yes "$answer"
}

spin_start() {
    spin_stop
    SPINNER_ID=$(START_SPINNER "$1" 2>/dev/null) || SPINNER_ID=""
}

spin_stop() {
    if [ -n "$SPINNER_ID" ]; then
        STOP_SPINNER "$SPINNER_ID" 2>/dev/null || :
        SPINNER_ID=""
    fi
}

note() {
    LOG "$@"
    if [ -n "$CAP_LOG" ]; then
        printf '%s %s\n' "$(date '+%F %T')" "${*: -1}" >> "$CAP_LOG" 2>/dev/null
    fi
}

wait_back() {
    LOG "Press B to return to the Main Menu"
    WAIT_FOR_BUTTON_PRESS B
}

counter() {
    cat "$SYS_NET/$BUG/statistics/$1" 2>/dev/null || echo 0
}

free_mb() {
    df -Pm "$LOOT_FS" 2>/dev/null | awk 'NR==2 {print $4}'
}

bytes_of() {
    local total=0 f size
    for f in "$@"; do
        [ -f "$f" ] || continue
        size=$(ls -ln "$f" 2>/dev/null | awk '{print $5}')
        total=$((total + ${size:-0}))
    done
    echo "$total"
}

human_mb() {
    awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1000000 }'
}

duration_seconds() {
    case "$1" in
        "1 min") echo 60 ;;
        "5 min") echo 300 ;;
        "15 min") echo 900 ;;
        "60 min") echo 3600 ;;
        *) echo 0 ;;
    esac
}

snap_length() {
    if [ "$SNAP" = "Headers" ]; then
        echo "$HEADER_SNAP"
    else
        echo 0
    fi
}

filter_label() {
    case "$FILTER" in
        "Custom Port") echo "Port $CUSTOM_PORT" ;;
        *) echo "$FILTER" ;;
    esac
}

filter_expr() {
    case "$FILTER" in
        "Web") echo "tcp port 80 or tcp port 443 or tcp port 8080" ;;
        "DNS") echo "port 53" ;;
        "Email") echo "tcp port 25 or tcp port 110 or tcp port 143 or tcp port 465 or tcp port 587 or tcp port 993 or tcp port 995" ;;
        "Cleartext") echo "tcp port 21 or tcp port 23 or tcp port 25 or tcp port 80 or tcp port 110 or tcp port 143 or tcp port 389" ;;
        "File Shares") echo "tcp port 139 or tcp port 445 or port 2049" ;;
        "DHCP") echo "udp port 67 or udp port 68 or udp port 546 or udp port 547" ;;
        "Custom Port") echo "port $CUSTOM_PORT" ;;
        "Custom BPF") echo "$CUSTOM_BPF" ;;
        *) echo "" ;;
    esac
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_bpf() {
    [ -n "$1" ] || return 1
    tcpdump -i "$BUG" -d "$1" >/dev/null 2>&1
}

save_setting() {
    PAYLOAD_SET_CONFIG "$CONFIG_NAME" "$1" "$2" >/dev/null 2>&1 || LOG "Could not save $1"
}

load_settings() {
    local v
    v=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" filter 2>/dev/null) && contains "$v" "${FILTERS[@]}" && FILTER=$v
    v=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" port 2>/dev/null) && valid_port "$v" && CUSTOM_PORT=$v
    v=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" bpf 2>/dev/null) && CUSTOM_BPF=$v
    v=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" snap 2>/dev/null) && contains "$v" "${SNAPS[@]}" && SNAP=$v
    v=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" limit 2>/dev/null) && contains "$v" "${LIMITS[@]}" && LIMIT_MB=$v
    v=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" duration 2>/dev/null) && contains "$v" "${DURATIONS[@]}" && DURATION=$v
    v=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" mode 2>/dev/null) && contains "$v" "${MODES[@]}" && MODE=$v
    if [ "$FILTER" = "Custom BPF" ] && [ -z "$CUSTOM_BPF" ]; then
        FILTER="All Traffic"
    fi
}

check_tools() {
    local tool missing=()
    for tool in tcpdump ip ifup ifdown ifstatus uci jsonfilter df awk LOG PROMPT PROMPT_IMAGE LIST_PICKER NUMBER_PICKER TEXT_PICKER CONFIRMATION_DIALOG ERROR_DIALOG START_SPINNER STOP_SPINNER WAIT_FOR_INPUT WAIT_FOR_BUTTON_PRESS PAYLOAD_GET_CONFIG PAYLOAD_SET_CONFIG; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        LOG red "Missing: ${missing[*]}"
        ERROR_DIALOG "Missing tools: ${missing[*]}"
        exit 1
    fi
}

find_bug() {
    local dev path id want
    for dev in "$SYS_NET"/*; do
        [ -e "$dev/device" ] || continue
        path=$(readlink -f "$dev/device" 2>/dev/null) || continue
        while [ -n "$path" ] && [ "$path" != "/" ] && [ ! -f "$path/idVendor" ]; do
            path=${path%/*}
        done
        [ -f "$path/idVendor" ] || continue
        id="$(cat "$path/idVendor" 2>/dev/null):$(cat "$path/idProduct" 2>/dev/null)"
        for want in $BUG_IDS; do
            if [ "$id" = "$want" ]; then
                echo "${dev##*/}"
                return 0
            fi
        done
    done
    return 1
}

wait_for_bug() {
    local i found
    spin_start "Searching for Bug"
    for ((i = 0; i < DETECT_SECONDS; i++)); do
        if found=$(find_bug); then
            spin_stop
            echo "$found"
            return 0
        fi
        sleep 1
    done
    spin_stop
    return 1
}

require_bug() {
    local choice
    while :; do
        if BUG=$(find_bug); then
            BUG_MAC=$(cat "$SYS_NET/$BUG/address" 2>/dev/null)
            LOG green "Bug found: $BUG $BUG_MAC"
            return 0
        fi
        LOG red "No Plunder Bug found"
        PROMPT "Attach a Plunder Bug to the Pager USB port"
        choice=$(LIST_PICKER "No Bug Found" "Retry" "Quit" "Retry") || choice="Quit"
        case "$choice" in
            "Retry")
                if BUG=$(wait_for_bug); then
                    continue
                fi
                ;;
            *)
                LOG "Quit without changes"
                exit 0
                ;;
        esac
    done
}

bug_networks() {
    uci -q show network 2>/dev/null | awk -F= -v d="$BUG" 'BEGIN { q = sprintf("%c", 39) }
        { n = split($1, k, "."); v = $2; gsub(q, "", v)
          if (n == 3 && (k[3] == "device" || k[3] == "ifname") && v == d) print k[2] }'
}

record_state() {
    local net status auto up
    ORIG_V6=$(cat "$PROC_IPV6/$BUG/disable_ipv6" 2>/dev/null)
    ORIG_FLAGS=$(cat "$SYS_NET/$BUG/flags" 2>/dev/null)
    RESTORE_NETS=()
    for net in $(bug_networks); do
        status=$(ifstatus "$net" 2>/dev/null) || continue
        auto=$(printf '%s' "$status" | jsonfilter -e '@.autostart' 2>/dev/null)
        up=$(printf '%s' "$status" | jsonfilter -e '@.up' 2>/dev/null)
        if [ "$auto" = "true" ] || [ "$up" = "true" ]; then
            RESTORE_NETS+=("$net")
        fi
    done
    LOG "Saved state: ipv6_off=${ORIG_V6:-?} flags=${ORIG_FLAGS:-?} nets=${RESTORE_NETS[*]:-none}"
}

quiet_link() {
    echo 1 > "$PROC_IPV6/$BUG/disable_ipv6" 2>/dev/null
    ip link set dev "$BUG" arp off 2>/dev/null
    ip link set dev "$BUG" multicast off 2>/dev/null
}

wait_carrier() {
    local i
    for ((i = 0; i < 8; i++)); do
        [ "$(cat "$SYS_NET/$BUG/carrier" 2>/dev/null)" = "1" ] && return 0
        sleep 1
    done
    return 1
}

apply_mute() {
    local net
    quiet_link
    for net in "${RESTORE_NETS[@]}"; do
        ifdown "$net" >/dev/null 2>&1
    done
    sleep 1
    ip link set dev "$BUG" up 2>/dev/null
    quiet_link
    wait_carrier
}

mute_bug() {
    spin_start "Muting Bug"
    MUTED=1
    apply_mute || LOG "No link on $BUG yet"
    spin_stop
    verify_mute
}

verify_mute() {
    local before after delta
    spin_start "Verifying mute"
    before=$(counter tx_packets)
    sleep "$VERIFY_SECONDS"
    after=$(counter tx_packets)
    spin_stop
    delta=$((after - before))
    MUTE_TX_BASE=$after
    if [ "$delta" -eq 0 ]; then
        MUTE_STATE="Muted"
        LOG green "Muted: TX +0 in ${VERIFY_SECONDS}s"
    else
        MUTE_STATE="Not muted (TX +$delta)"
        LOG red "Not muted: TX +$delta in ${VERIFY_SECONDS}s"
        PROMPT "Warning: Bug still transmitting (TX +$delta)"
    fi
}

mute_label() {
    local delta
    delta=$(( $(counter tx_packets) - MUTE_TX_BASE ))
    if [ "$MUTE_STATE" = "Muted" ] && [ "$delta" -eq 0 ]; then
        echo "Muted (TX +0)"
    elif [ "$MUTE_STATE" = "Muted" ]; then
        echo "Leaking (TX +$delta)"
    else
        echo "$MUTE_STATE"
    fi
}

restore_bug() {
    local net
    [ "$MUTED" = "1" ] || return 0
    if [ -d "$SYS_NET/$BUG" ]; then
        if [ -n "$ORIG_FLAGS" ]; then
            (( ORIG_FLAGS & 0x80 )) || ip link set dev "$BUG" arp on 2>/dev/null
            (( ORIG_FLAGS & 0x1000 )) && ip link set dev "$BUG" multicast on 2>/dev/null
        fi
        [ -n "$ORIG_V6" ] && echo "$ORIG_V6" > "$PROC_IPV6/$BUG/disable_ipv6" 2>/dev/null
    fi
    for net in "${RESTORE_NETS[@]}"; do
        ifup "$net" >/dev/null 2>&1
    done
    MUTED=0
    LOG "Network restored on ${BUG:-Bug}"
}

stop_capture_processes() {
    if [ -n "$WATCHDOG_PID" ]; then
        kill "$WATCHDOG_PID" 2>/dev/null
        wait "$WATCHDOG_PID" 2>/dev/null
        WATCHDOG_PID=""
    fi
    if [ -n "$TCPDUMP_PID" ]; then
        kill -TERM "$TCPDUMP_PID" 2>/dev/null
        wait "$TCPDUMP_PID" 2>/dev/null
        TCPDUMP_PID=""
    fi
}

cleanup() {
    spin_stop
    stop_capture_processes
    if [ -n "$CAP_LOG" ]; then
        printf 'Stopped: %s\nReason: Payload exited\n' "$(date '+%F %T')" >> "$CAP_LOG" 2>/dev/null
        CAP_LOG=""
    fi
    restore_bug
    rm -rf "$RUN_DIR" 2>/dev/null
}

show_status() {
    local now rx rate link speed
    now=$(date +%s)
    rx=$(counter rx_packets)
    rate="n/a"
    if [ -n "$LAST_RX" ] && [ "$now" -gt "$LAST_RX_TIME" ]; then
        rate="$(( (rx - LAST_RX) / (now - LAST_RX_TIME) ))/s"
    fi
    LAST_RX=$rx
    LAST_RX_TIME=$now
    link="down"
    if [ "$(cat "$SYS_NET/$BUG/carrier" 2>/dev/null)" = "1" ]; then
        speed=$(cat "$SYS_NET/$BUG/speed" 2>/dev/null)
        link="up ${speed:-?} Mb"
    fi
    LOG "Bug: $BUG $BUG_MAC"
    LOG "Link: $link"
    LOG "Mute: $(mute_label)"
    LOG "RX: $rx pkts ($rate)"
    LOG "Free: $(free_mb) MB on $LOOT_FS"
    LOG "Captures: $LOOT_DIR"
}

reserve_base() {
    local ts base
    mkdir -p "$LOOT_DIR" || return 1
    while :; do
        ts=$(date +%Y%m%d-%H%M%S)
        base="$LOOT_DIR/bug-$ts"
        if ! compgen -G "$base.*" >/dev/null; then
            echo "$base"
            return 0
        fi
        sleep 1
    done
}

capture_files() {
    compgen -G "$1.pcap*" | sort
}

watchdog() {
    local limit_bytes=$1 dur=$2 start=$3 pcap_base=$4
    local now size free tx last_tx tick=0 reason=""
    last_tx=$(counter tx_packets)
    while kill -0 "$TCPDUMP_PID" 2>/dev/null; do
        sleep 1
        tick=$((tick + 1))
        now=$(date +%s)
        if [ ! -d "$SYS_NET/$BUG" ]; then
            reason="Bug removed"
        elif [ "$dur" -gt 0 ] && [ $((now - start)) -ge "$dur" ]; then
            reason="Duration reached"
        elif [ "$MODE" = "Stop at Limit" ]; then
            if [ -e "$pcap_base.pcap1" ]; then
                reason="Size limit reached"
            else
                size=$(bytes_of "$pcap_base.pcap")
                [ "$size" -ge "$limit_bytes" ] && reason="Size limit reached"
            fi
        fi
        if [ -z "$reason" ]; then
            free=$(free_mb)
            [ -n "$free" ] && [ "$free" -lt "$FLOOR_MB" ] && reason="Storage floor reached"
        fi
        if [ -n "$reason" ]; then
            echo "$reason" > "$RUN_DIR/stop_reason"
            kill -TERM "$TCPDUMP_PID" 2>/dev/null
            note yellow "Capture stopped: $reason"
            LOG "Press any button"
            VIBRATE alert >/dev/null 2>&1 &
            return 0
        fi
        if [ $((tick % 5)) -eq 0 ]; then
            tx=$(counter tx_packets)
            if [ "$tx" -gt "$last_tx" ]; then
                note red "Bug transmitted (TX +$((tx - last_tx))), re-muting"
                echo "$tx" >> "$RUN_DIR/remutes"
                apply_mute >/dev/null 2>&1
                tx=$(counter tx_packets)
            fi
            last_tx=$tx
        fi
    done
}

capture_status() {
    local now size
    now=$(date +%s)
    size=$(bytes_of $(capture_files "$1"))
    LOG "Elapsed: $((now - $2))s  Size: $(human_mb "$size")"
    LOG "RX: +$(( $(counter rx_packets) - $3 )) pkts  Mute: $(mute_label)"
    LOG "Free: $(free_mb) MB"
}

start_capture() {
    local free avail limit expr base pcap dur snaplen chunk files rx0 tx0 start btn reason size trimmed f
    local args=()
    free=$(free_mb)
    if [ -z "$free" ]; then
        ERROR_DIALOG "Cannot read free space on $LOOT_FS"
        return 1
    fi
    avail=$((free - FLOOR_MB))
    if [ "$avail" -lt 10 ]; then
        ERROR_DIALOG "Only $free MB free; keeping $FLOOR_MB MB reserve"
        return 1
    fi
    limit=$LIMIT_MB
    if [ "$limit" -gt "$avail" ]; then
        limit=$avail
        LOG yellow "Limit capped to $limit MB by free space"
    fi
    expr=$(filter_expr)
    if [ -n "$expr" ] && ! valid_bpf "$expr"; then
        ERROR_DIALOG "Filter rejected by tcpdump: $(filter_label)"
        return 1
    fi
    if [ ! -d "$SYS_NET/$BUG" ]; then
        ERROR_DIALOG "Bug not attached"
        return 1
    fi
    confirm "Record $(filter_label) on $BUG, $SNAP, $limit MB, $DURATION. Start?" || return 0

    base=$(reserve_base) || { ERROR_DIALOG "Cannot create $LOOT_DIR"; return 1; }
    pcap="$base.pcap"
    CAP_LOG="$base.log"
    dur=$(duration_seconds "$DURATION")
    snaplen=$(snap_length)
    args=(-i "$BUG" -Q in -U -n -s "$snaplen")
    if [ "$MODE" = "Ring Buffer" ]; then
        chunk=$((limit / RING_FILES))
        [ "$chunk" -lt 1 ] && chunk=1
        files=$((limit / chunk))
        [ "$files" -lt 1 ] && files=1
        args+=(-C "$chunk" -W "$files")
    else
        args+=(-C "$limit")
    fi
    args+=(-w "$pcap")
    [ -n "$expr" ] && args+=("$expr")

    rm -f "$RUN_DIR/stop_reason" "$RUN_DIR/remutes"
    {
        echo "Plunder Bug capture"
        echo "Interface: $BUG"
        echo "Bug MAC: $BUG_MAC"
        echo "Mute: $(mute_label)"
        echo "Filter: $(filter_label)"
        echo "Expression: ${expr:-none}"
        echo "Snap: $SNAP ($snaplen)"
        echo "Limit: $limit MB"
        echo "Duration: $DURATION"
        echo "Mode: $MODE"
        echo "Free at start: $free MB"
        echo "Command: tcpdump ${args[*]}"
    } > "$CAP_LOG"
    rx0=$(counter rx_packets)
    tx0=$(counter tx_packets)
    start=$(date +%s)
    note "Capture started"

    tcpdump "${args[@]}" 2>>"$CAP_LOG" &
    TCPDUMP_PID=$!
    sleep 1
    if ! kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        wait "$TCPDUMP_PID" 2>/dev/null
        TCPDUMP_PID=""
        LOG red "tcpdump failed; see $CAP_LOG"
        ERROR_DIALOG "tcpdump failed to start"
        CAP_LOG=""
        return 1
    fi
    watchdog "$((limit * 1000000))" "$dur" "$start" "$base" &
    WATCHDOG_PID=$!

    LOG green "Recording ${base##*/}"
    LOG "A: Status  B: Stop"
    while kill -0 "$TCPDUMP_PID" 2>/dev/null; do
        btn=$(WAIT_FOR_INPUT 2>/dev/null) || { sleep 1; continue; }
        kill -0 "$TCPDUMP_PID" 2>/dev/null || break
        case "$btn" in
            A) capture_status "$base" "$start" "$rx0" ;;
            B)
                if confirm "Stop capture?"; then
                    echo "Stopped by user" > "$RUN_DIR/stop_reason"
                    break
                fi
                LOG "A: Status  B: Stop"
                ;;
            *) LOG "A: Status  B: Stop" ;;
        esac
    done

    stop_capture_processes
    reason=$(cat "$RUN_DIR/stop_reason" 2>/dev/null)
    reason=${reason:-tcpdump exited}
    trimmed=""
    if [ "$MODE" = "Stop at Limit" ]; then
        for f in $(capture_files "$base"); do
            [ "$f" = "$pcap" ] && continue
            rm -f -- "$f" && trimmed="$trimmed ${f##*/}"
        done
    fi
    size=$(bytes_of $(capture_files "$base"))
    {
        [ -n "$trimmed" ] && echo "Trimmed past limit:$trimmed"
        echo "Stopped: $(date '+%F %T')"
        echo "Reason: $reason"
        echo "Elapsed: $(( $(date +%s) - start ))s"
        echo "Files: $(capture_files "$base" | awk -F/ '{print $NF}' | tr '\n' ' ')"
        echo "Size: $(human_mb "$size")"
        echo "Bug RX delta: $(( $(counter rx_packets) - rx0 )) packets"
        echo "Bug TX delta: $(( $(counter tx_packets) - tx0 )) packets"
        if [ -f "$RUN_DIR/remutes" ]; then
            echo "Re-mutes: $(awk 'END { print NR }' "$RUN_DIR/remutes")"
        else
            echo "Re-mutes: 0"
        fi
    } >> "$CAP_LOG"
    LOG "Stopped: $reason"
    LOG "Saved ${base##*/}: $(human_mb "$size")"
    grep -E "packets (captured|dropped by kernel)" "$CAP_LOG" | while read -r line; do LOG "$line"; done
    LOG "Log: $CAP_LOG"
    CAP_LOG=""
    PROMPT "Saved ${base##*/} ($(human_mb "$size"))"
}

capture_bases() {
    compgen -G "$LOOT_DIR/bug-*.pcap*" | sed 's/\.pcap[0-9]*$//' | sort -ru
}

capture_details() {
    local base=$1 size
    size=$(bytes_of $(capture_files "$base"))
    LOG "${base##*/}: $(human_mb "$size")"
    if [ -f "$base.log" ]; then
        grep -E "^(Filter|Snap|Mode|Started|Stopped|Reason|Elapsed|Size|Re-mutes):| packets (captured|dropped)" "$base.log" | while read -r line; do LOG "$line"; done
    fi
    wait_back
}

captures_menu() {
    local bases=() labels=() page=0 per=6 i base choice action total start label
    while :; do
        bases=()
        while IFS= read -r base; do
            [ -n "$base" ] && bases+=("$base")
        done < <(capture_bases)
        total=${#bases[@]}
        if [ "$total" -eq 0 ]; then
            PROMPT "No captures in $LOOT_DIR"
            return 0
        fi
        [ $((page * per)) -ge "$total" ] && page=0
        start=$((page * per))
        labels=()
        for ((i = start; i < start + per && i < total; i++)); do
            base=${bases[$i]}
            labels+=("${base##*/} $(human_mb "$(bytes_of $(capture_files "$base"))")")
        done
        [ "$total" -gt "$per" ] && labels+=("More")
        choice=$(LIST_PICKER "Captures ($total)" "${labels[@]}" "${labels[0]}") || return 0
        if [ "$choice" = "More" ]; then
            page=$((page + 1))
            continue
        fi
        base=""
        for ((i = start; i < start + per && i < total; i++)); do
            label="${bases[$i]##*/} $(human_mb "$(bytes_of $(capture_files "${bases[$i]}"))")"
            if [ "$label" = "$choice" ]; then
                base=${bases[$i]}
                break
            fi
        done
        [ -n "$base" ] || continue
        action=$(LIST_PICKER "${base##*/}" "Details" "Delete" "Details") || continue
        case "$action" in
            "Details") capture_details "$base" ;;
            "Delete")
                if confirm "Delete ${base##*/}?"; then
                    rm -f -- $(capture_files "$base") "$base.log"
                    LOG "Deleted ${base##*/}"
                fi
                ;;
        esac
    done
}

pick_filter() {
    local choice port bpf
    choice=$(LIST_PICKER "Filter" "${FILTERS[@]}" "$FILTER") || return 0
    case "$choice" in
        "Custom Port")
            port=$(NUMBER_PICKER "Port (1-65535)" "$CUSTOM_PORT") || return 0
            if ! valid_port "$port"; then
                PROMPT "Invalid port: $port"
                return 0
            fi
            CUSTOM_PORT=$port
            save_setting port "$CUSTOM_PORT"
            ;;
        "Custom BPF")
            bpf=$(TEXT_PICKER "BPF filter" "${CUSTOM_BPF:-tcp port 80}") || return 0
            if ! valid_bpf "$bpf"; then
                PROMPT "tcpdump rejected filter"
                return 0
            fi
            CUSTOM_BPF=$bpf
            save_setting bpf "$CUSTOM_BPF"
            ;;
    esac
    FILTER=$choice
    save_setting filter "$FILTER"
}

pick_snap() {
    local choice
    choice=$(LIST_PICKER "Snap Length" "${SNAPS[@]}" "$SNAP") || return 0
    SNAP=$choice
    save_setting snap "$SNAP"
}

pick_limit() {
    local choice opts=() n
    for n in "${LIMITS[@]}"; do
        opts+=("$n MB")
    done
    choice=$(LIST_PICKER "Size Limit" "${opts[@]}" "$LIMIT_MB MB") || return 0
    choice=${choice% MB}
    contains "$choice" "${LIMITS[@]}" || return 0
    LIMIT_MB=$choice
    save_setting limit "$LIMIT_MB"
}

pick_duration() {
    local choice
    choice=$(LIST_PICKER "Duration" "${DURATIONS[@]}" "$DURATION") || return 0
    DURATION=$choice
    save_setting duration "$DURATION"
}

pick_mode() {
    local choice
    choice=$(LIST_PICKER "Mode" "${MODES[@]}" "$MODE") || return 0
    MODE=$choice
    save_setting mode "$MODE"
}

quit_payload() {
    confirm "Quit Plunder Bug?" || return 0
    exit 0
}

main_menu() {
    local choice
    while :; do
        choice=$(LIST_PICKER "Plunder Bug" \
            "Start Capture" \
            "Status" \
            "Filter: $(filter_label)" \
            "Snap: $SNAP" \
            "Limit: $LIMIT_MB MB" \
            "Duration: $DURATION" \
            "Mode: $MODE" \
            "Captures" \
            "Payload Log" \
            "Help" \
            "Quit" \
            "Start Capture") || choice="Quit"
        case "$choice" in
            "Start Capture") start_capture ;;
            "Status") show_status; wait_back ;;
            "Filter: "*) pick_filter ;;
            "Snap: "*) pick_snap ;;
            "Limit: "*) pick_limit ;;
            "Duration: "*) pick_duration ;;
            "Mode: "*) pick_mode ;;
            "Captures") captures_menu ;;
            "Payload Log") wait_back ;;
            "Help")
                PROMPT_QR "https://hak5.org/products/bug" \
                    "This payload is designed to be used with the Hak5 Plunder Bug LAN Tap.\n\nLearn more at Hak5.org/products/bug"
                ;;
            "Quit") quit_payload ;;
        esac
    done
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$(id -u)" != "0" ]; then
    ERROR_DIALOG "Plunder Bug must run as root"
    exit 1
fi
mkdir -p "$RUN_DIR"
check_tools
if [ -f "$SPLASH_IMAGE" ]; then
    PROMPT_IMAGE "$SPLASH_IMAGE" || :
fi
load_settings
require_bug
record_state
mute_bug
main_menu
