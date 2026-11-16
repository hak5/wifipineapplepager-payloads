#!/bin/bash
# Title: MIRRORCAST - Cast & Print Honeypot
# Description: Impersonates AirPlay, DIAL, Chromecast and IPP printers on mDNS/SSDP, logs discovery probes, captures print jobs, and can push media to nearby cast devices.
# Author: sinXne0
# Version: 1.0.0
# Category: user/interception
# Firmware: 2.0.0-stable or newer
# Requires: python3-light (python3-openssl for Chromecast castjack)
#
# MIRRORCAST advertises a fake living-room display and printer on the local
# network, records every device that comes looking, and can castjack real
# Chromecast / AirPlay / DIAL / DLNA devices it finds.
#
# Modes
#   Honeypot  - answer mDNS and SSDP discovery, serve AirPlay / DIAL / IPP,
#               log probes and capture print documents.
#   Scan      - enumerate Chromecast, AirPlay, DIAL, DLNA and printer devices.
#   Castjack  - push a media URL to a discovered device (or every device).
#   Dry run   - show what castjack would send without sending it.
#
# Authorization
#   This payload is for authorized security testing only. Run it only on
#   networks you own or have written permission to test. It is passive
#   discovery plus a local impersonation service; it does not attack Wi-Fi
#   encryption, deauthenticate clients, or modify other devices.
#
# LED States
#   Cyan solid   - discovering / scanning
#   Amber solid  - honeypot listening
#   Red solid    - castjack sending
#   Green solid  - operation complete
#   Red blink    - error
#   White        - idle / cleaned up
#
# Loot
#   /root/loot/mirrorcast/events.jsonl   all events (mDNS, SSDP, HTTP, jobs)
#   /root/loot/mirrorcast/ui.log         human-readable activity log
#   /root/loot/mirrorcast/printjobs/     raw IPP requests and captured documents
#   /root/loot/mirrorcast/scan_*.json    discovery results
#   /root/loot/mirrorcast/castjack_*.log castjack results
#
# Press A (or menu button) while the honeypot runs to stop it cleanly.

# === CONFIGURATION ===
LOOTDIR="${MIRRORCAST_LOOT:-/root/loot/mirrorcast}"
INPUT="${MIRRORCAST_INPUT:-/dev/input/event0}"
DIAL_APP="Browser"
DEFAULT_URL="http://example.com/media.mp4"

# === PATHS ===
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd)"
PAYLOAD_DIR=""
for candidate in "$SCRIPT_DIR" \
                 "/root/payloads/user/interception/mirrorcast" \
                 "/mmc/root/payloads/user/interception/mirrorcast"; do
    if [ -f "$candidate/mirrorcast.py" ]; then
        PAYLOAD_DIR="$candidate"
        break
    fi
done

ENGINE="$PAYLOAD_DIR/mirrorcast.py"
RUNLOG="/tmp/mirrorcast_run.log"
SCANFILE="/tmp/mirrorcast_scan.json"
SCANERR="/tmp/mirrorcast_scan.err"
ENGINE_PID=""

# Discovery results (parallel arrays)
SCAN_KIND=()
SCAN_IP=()
SCAN_PORT=()
SCAN_NAME=()
SCAN_APPURL=()
SCAN_CTRL=()

CAST_LABEL=()
CAST_KIND=()
CAST_IP=()
CAST_PORT=()
CAST_NAME=()
CAST_APPURL=()
CAST_CTRL=()

# === CLEANUP ===
cleanup() {
    if [ -n "$ENGINE_PID" ] && kill -0 "$ENGINE_PID" 2>/dev/null; then
        kill -TERM "$ENGINE_PID" 2>/dev/null
        sleep 1
        kill -KILL "$ENGINE_PID" 2>/dev/null
    fi
    rm -f "$SCANFILE" "$SCANERR" "$RUNLOG"
    LED WHITE 2>/dev/null
}
trap cleanup EXIT INT TERM

# === UI HELPERS ===
confirmed() {
    [ "$1" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || [ "$1" = "true" ]
}

play_start()  { RINGTONE "start:d=4,o=5,b=200:c6,e6,g6" & }
play_capture(){ RINGTONE "cap:d=8,o=6,b=180:g,a,b" & }
play_done()   { RINGTONE "done:d=4,o=5,b=180:c6,e6,g6,c7" & }
play_fail()   { RINGTONE "fail:d=4,o=4,b=120:g,e,c" & }

count_events() {
    local file="$LOOTDIR/events.jsonl"
    if [ ! -f "$file" ]; then
        echo 0
        return
    fi
    wc -l < "$file" 2>/dev/null | tr -d ' '
}

count_events_of() {
    local kind="$1"
    local file="$LOOTDIR/events.jsonl"
    local n=0
    if [ ! -f "$file" ]; then
        echo 0
        return
    fi
    n=$(grep -c "\"kind\": \"$kind\"" "$file" 2>/dev/null) || n=0
    echo "${n:-0}"
}

# === NON-BLOCKING BUTTON CHECK ===
# A/B buttons arrive as BTN_SOUTH / BTN_EAST on the Pager input device.
check_for_stop() {
    local data type value keycode
    data=$(timeout 0.1 dd if="$INPUT" bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x "' 2>/dev/null)
    [ -z "$data" ] && return 1
    type=$(echo "$data" | cut -d' ' -f9-10)
    value=$(echo "$data" | cut -d' ' -f13)
    keycode=$(echo "$data" | cut -d' ' -f11-12)
    if [ "$type" = "01 00" ] && [ "$value" = "01" ]; then
        if [ "$keycode" = "31 01" ] || [ "$keycode" = "30 01" ]; then
            return 0
        fi
    fi
    return 1
}

# === AUTHORIZATION GATE ===
scope_gate() {
    LOG "red" "=========================================="
    LOG "red" "          AUTHORIZED TESTING ONLY"
    LOG "red" "=========================================="
    LOG ""
    LOG "MIRRORCAST advertises fake cast and print"
    LOG "devices on this network and logs every"
    LOG "client that probes them."
    LOG ""
    LOG "Use only on networks you own or have"
    LOG "written permission to test."
    LOG ""
    resp=$(CONFIRMATION_DIALOG "I confirm I have written authorization to test this network.")
    rc=$?
    case $rc in
        "${DUCKYSCRIPT_REJECTED:-__rejected}"|"${DUCKYSCRIPT_ERROR:-__error}")
            return 1
            ;;
    esac
    confirmed "$resp" || return 1
    LOG "green" "Authorization confirmed."
    return 0
}

# === DEPENDENCIES ===
ensure_python() {
    if command -v python3 >/dev/null 2>&1; then
        return 0
    fi

    LOG "yellow" "python3 is not installed."
    resp=$(CONFIRMATION_DIALOG "Install python3-light now? (~3 MB)")
    confirmed "$resp" || return 1

    LOG "cyan" "Updating package lists..."
    opkg update >/dev/null 2>&1
    LOG "cyan" "Installing python3-light..."
    if opkg install python3-light >/tmp/mirrorcast_opkg.log 2>&1; then
        if command -v python3 >/dev/null 2>&1; then
            LOG "green" "python3-light installed."
            return 0
        fi
    fi

    LOG "red" "Install failed. See /tmp/mirrorcast_opkg.log"
    ALERT "python3-light install failed.\n\nRun manually:\nopkg update && opkg install python3-light"
    return 1
}

ssl_available() {
    python3 -c "import ssl; ssl.SSLContext" >/dev/null 2>&1
}

ensure_ssl() {
    if ssl_available; then
        return 0
    fi

    LOG "yellow" "Python ssl is missing."
    LOG "Chromecast castjack needs it;"
    LOG "AirPlay / DIAL / DLNA still work."
    LOG ""
    resp=$(CONFIRMATION_DIALOG "Install python3-openssl now? (~1 MB)")
    confirmed "$resp" || return 1

    opkg update >/dev/null 2>&1
    if opkg install python3-openssl >/tmp/mirrorcast_ssl.log 2>&1 && ssl_available; then
        LOG "green" "python3-openssl installed."
        return 0
    fi

    LOG "yellow" "Could not install python3-openssl."
    LOG "Chromecast targets will report an error."
    return 1
}

# === INTERFACE PICKER ===
pick_interface() {
    local -a labels
    local name ip pick

    while true; do
        labels=()
        while IFS=$'\t' read -r name ip; do
            [ -z "$name" ] && continue
            labels+=("$name ($ip)")
        done < <(python3 "$ENGINE" ifaces 2>/dev/null)

        if [ ${#labels[@]} -eq 0 ]; then
            ALERT "No interface has an IPv4 address.\n\nConfigure or connect an interface, then retry."
            resp=$(CONFIRMATION_DIALOG "Retry interface scan?")
            confirmed "$resp" || return 1
            continue
        fi

        pick=$(LIST_PICKER "Select interface" "${labels[@]}" "Refresh list")
        if [ -z "$pick" ]; then
            return 1
        fi
        if [ "$pick" = "Refresh list" ]; then
            continue
        fi

        IFACE="${pick%% (*}"
        IFACE_IP=$(python3 "$ENGINE" ifaces 2>/dev/null | awk -F'\t' -v n="$IFACE" '$1 == n { print $2; exit }')
        if [ -z "$IFACE_IP" ]; then
            ALERT "Interface $IFACE has no IPv4 address."
            continue
        fi
        return 0
    done
}

# === SCAN HELPERS ===
collect_scan() {
    local seconds="$1"
    local message="$2"
    local spinner rc

    : > "$SCANFILE"
    : > "$SCANERR"
    spinner=$(START_SPINNER "$message")
    python3 "$ENGINE" scan --iface "$IFACE" --loot "$LOOTDIR" \
        --seconds "$seconds" --json > "$SCANFILE" 2> "$SCANERR"
    rc=$?
    STOP_SPINNER "$spinner" >/dev/null 2>&1
    return $rc
}

load_scan_file() {
    local file="$1"
    local kind sip sport sname sapp sctrl

    SCAN_KIND=()
    SCAN_IP=()
    SCAN_PORT=()
    SCAN_NAME=()
    SCAN_APPURL=()
    SCAN_CTRL=()

    while IFS=$'\t' read -r kind sip sport sname sapp sctrl; do
        [ -z "$kind" ] && continue
        SCAN_KIND+=("$kind")
        SCAN_IP+=("$sip")
        SCAN_PORT+=("$sport")
        SCAN_NAME+=("$sname")
        SCAN_APPURL+=("$sapp")
        SCAN_CTRL+=("$sctrl")
    done < <(python3 - "$file" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    data = []

for entry in data:
    kind = str(entry.get("type", "?"))
    ip = str(entry.get("ip", "") or "")
    port = str(entry.get("port", "") or "")
    name = str(entry.get("name") or entry.get("instance") or "")
    name = " ".join(name.split())[:52]
    app = str(entry.get("app_url", "") or "")
    ctrl = str(entry.get("control_url", "") or "")
    print("\t".join([kind, ip, port, name, app, ctrl]))
PYEOF
)
}

show_scan_results() {
    local i=0
    local total=${#SCAN_KIND[@]}

    if [ "$total" -eq 0 ]; then
        LOG "yellow" "No cast or print devices answered."
        return 1
    fi

    LOG "green" "Found $total device(s):"
    while [ $i -lt $total ] && [ $i -lt 12 ]; do
        LOG "  [${SCAN_KIND[$i]}] ${SCAN_IP[$i]}:${SCAN_PORT[$i]} ${SCAN_NAME[$i]}"
        i=$((i + 1))
    done
    if [ $total -gt 12 ]; then
        LOG "  ... $((total - 12)) more in the JSON log"
    fi
    return 0
}

scan_and_report() {
    local seconds="$1"
    local rc

    LED CYAN
    if ! collect_scan "$seconds" "Scanning for cast devices..."; then
        LED RED
        play_fail
        ALERT "Scan failed.\n\n$(head -n 3 "$SCANERR" 2>/dev/null)"
        LOG "red" "Scan error: $(head -n 2 "$SCANERR" 2>/dev/null)"
        return 1
    fi
    load_scan_file "$SCANFILE"
    LED GREEN
    show_scan_results || { LED AMBER; return 1; }
    play_capture
    return 0
}

# === HONEYPOT ===
run_honeypot() {
    local bait name dur_choice duration extra
    local events prints http engine_rc stopped_by_button

    bait=$(LIST_PICKER "Bait device" \
        "Living Room TV (Chromecast)" \
        "Office Printer (IPP)" \
        "Conference Display (DIAL)" \
        "Custom name")
    [ -z "$bait" ] && return

    case "$bait" in
        "Living Room TV"*) name="Living Room TV" ;;
        "Office Printer"*) name="Office Printer" ;;
        "Conference Display"*) name="Conference Display" ;;
        *)
            name=$(TEXT_PICKER "Device name" "Living Room TV")
            [ -z "$name" ] && return
            ;;
    esac

    dur_choice=$(LIST_PICKER "Run time" "15 minutes" "30 minutes" "60 minutes" "Until button stop")
    [ -z "$dur_choice" ] && return
    case "$dur_choice" in
        "15 minutes") duration=900 ;;
        "30 minutes") duration=1800 ;;
        "60 minutes") duration=3600 ;;
        *) duration=0 ;;
    esac

    extra=""
    resp=$(CONFIRMATION_DIALOG "Also bind AirPlay 7000 and IPP 631?\n\nThey are advertised either way. Binding them catches direct connections but may conflict with running services.")
    if confirmed "$resp"; then
        extra="--bind-defaults"
    fi

    mkdir -p "$LOOTDIR"
    LOG ""
    LOG "cyan" "MIRRORCAST honeypot"
    LOG "  Interface: $IFACE ($IFACE_IP)"
    LOG "  Bait name: $name"
    LOG "  Loot: $LOOTDIR"
    LOG ""
    LOG "Answering mDNS + SSDP, serving DIAL,"
    LOG "AirPlay and IPP. Press A to stop."
    LOG ""

    LED AMBER
    play_start
    : > "$RUNLOG"
    ENGINE_PID=""
    python3 "$ENGINE" honeypot --iface "$IFACE" --loot "$LOOTDIR" \
        --name "$name" --duration "$duration" $extra >> "$RUNLOG" 2>&1 &
    ENGINE_PID=$!

    local ticks=0 last=""
    stopped_by_button=0
    while kill -0 "$ENGINE_PID" 2>/dev/null; do
        if check_for_stop; then
            stopped_by_button=1
            LOG "yellow" "Button pressed. Stopping honeypot..."
            kill -TERM "$ENGINE_PID" 2>/dev/null
            local wait_ticks=0
            while kill -0 "$ENGINE_PID" 2>/dev/null && [ $wait_ticks -lt 10 ]; do
                sleep 0.5
                wait_ticks=$((wait_ticks + 1))
            done
            kill -KILL "$ENGINE_PID" 2>/dev/null
            break
        fi

        ticks=$((ticks + 1))
        if [ $((ticks % 6)) -eq 0 ]; then
            last=$(tail -n 1 "$LOOTDIR/ui.log" 2>/dev/null)
            if [ -n "$last" ]; then
                LOG "cyan" "${last:0:88}"
            fi
            events=$(count_events)
            prints=$(count_events_of printjob)
            LOG "  events=$events print_jobs=$prints"
        fi
        sleep 1
    done

    wait "$ENGINE_PID" 2>/dev/null
    engine_rc=$?
    ENGINE_PID=""

    if [ "$stopped_by_button" != "1" ] && [ $engine_rc -ne 0 ]; then
        LED RED
        play_fail
        LOG "red" "Honeypot engine exited (rc=$engine_rc)."
        LOG "red" "$(tail -n 2 "$RUNLOG" 2>/dev/null | head -n 1)"
        ALERT "Honeypot engine failed.\n\n$(tail -n 3 "$RUNLOG" 2>/dev/null)\n\nSee $LOOTDIR/ui.log"
        return
    fi

    LED GREEN
    play_done

    events=$(count_events)
    prints=$(count_events_of printjob)
    http=$(count_events_of http)

    LOG ""
    LOG "green" "Honeypot stopped."
    LOG "  Events: $events"
    LOG "  HTTP requests: $http"
    LOG "  Print jobs: $prints"
    LOG "  Loot: $LOOTDIR"
    ALERT "MIRRORCAST honeypot stopped\n\nEvents: $events\nHTTP requests: $http\nPrint jobs: $prints\n\nLoot:\n$LOOTDIR"
}

# === DISCOVERY ===
run_scan() {
    local seconds

    seconds=$(NUMBER_PICKER "Scan seconds (5-120)" "20")
    case $? in
        "${DUCKYSCRIPT_CANCELLED:-__cancelled}"|"${DUCKYSCRIPT_REJECTED:-__rejected}"|"${DUCKYSCRIPT_ERROR:-__error}")
            return
            ;;
    esac
    case "$seconds" in
        ''|*[!0-9]*) seconds=20 ;;
    esac
    [ "$seconds" -lt 5 ] && seconds=5
    [ "$seconds" -gt 120 ] && seconds=120

    mkdir -p "$LOOTDIR"
    LOG ""
    LOG "cyan" "Scanning $IFACE ($IFACE_IP) for $seconds seconds..."
    scan_and_report "$seconds"
    LOG ""
    LOG "Results saved under $LOOTDIR"
}

# === CASTJACK ===
build_cast_targets() {
    local i=0
    local n=0
    local label

    CAST_LABEL=()
    CAST_KIND=()
    CAST_IP=()
    CAST_PORT=()
    CAST_NAME=()
    CAST_APPURL=()
    CAST_CTRL=()

    while [ $i -lt ${#SCAN_KIND[@]} ]; do
        case "${SCAN_KIND[$i]}" in
            chromecast|airplay|dial|dlna)
                n=$((n + 1))
                label="$n. [${SCAN_KIND[$i]}] ${SCAN_IP[$i]}:${SCAN_PORT[$i]} ${SCAN_NAME[$i]}"
                CAST_LABEL+=("$label")
                CAST_KIND+=("${SCAN_KIND[$i]}")
                CAST_IP+=("${SCAN_IP[$i]}")
                CAST_PORT+=("${SCAN_PORT[$i]}")
                CAST_NAME+=("${SCAN_NAME[$i]}")
                CAST_APPURL+=("${SCAN_APPURL[$i]}")
                CAST_CTRL+=("${SCAN_CTRL[$i]}")
                ;;
        esac
        i=$((i + 1))
        [ $n -ge 18 ] && break
    done
    return $n
}

push_one() {
    local index="$1"
    local dry="$2"
    local -a push_args

    push_args=(push --iface "$IFACE" --loot "$LOOTDIR" --url "$URL"
        --target "${CAST_IP[$index]}" --type "${CAST_KIND[$index]}"
        --port "${CAST_PORT[$index]}" --name "${CAST_NAME[$index]}"
        --app "$DIAL_APP")
    [ -n "${CAST_APPURL[$index]}" ] && push_args+=(--app-url "${CAST_APPURL[$index]}")
    [ -n "${CAST_CTRL[$index]}" ] && push_args+=(--control-url "${CAST_CTRL[$index]}")
    [ "$dry" = "1" ] && push_args+=(--dry-run)

    LOG "cyan" "-> ${CAST_KIND[$index]} ${CAST_IP[$index]}:${CAST_PORT[$index]}"
    timeout 40 python3 "$ENGINE" "${push_args[@]}" >> "$RUNLOG" 2>&1
    return $?
}

run_castjack() {
    local dry="$1"
    local seconds pick resp num total ok rc i
    local -a choices

    URL=$(TEXT_PICKER "Media URL to push" "$DEFAULT_URL")
    [ -z "$URL" ] && return
    case "$URL" in
        http://*|https://*) ;;
        *)
            ALERT "The URL must start with http:// or https://"
            return
            ;;
    esac

    seconds=$(NUMBER_PICKER "Discovery seconds (5-60)" "15")
    case $? in
        "${DUCKYSCRIPT_CANCELLED:-__cancelled}"|"${DUCKYSCRIPT_REJECTED:-__rejected}"|"${DUCKYSCRIPT_ERROR:-__error}")
            return
            ;;
    esac
    case "$seconds" in
        ''|*[!0-9]*) seconds=15 ;;
    esac
    [ "$seconds" -lt 5 ] && seconds=5
    [ "$seconds" -gt 60 ] && seconds=60

    mkdir -p "$LOOTDIR"
    LED CYAN
    if ! collect_scan "$seconds" "Finding cast targets..."; then
        LED RED
        play_fail
        ALERT "Discovery failed.\n\n$(head -n 3 "$SCANERR" 2>/dev/null)"
        return
    fi
    load_scan_file "$SCANFILE"

    build_cast_targets
    total=$?
    if [ "$total" -eq 0 ]; then
        LED AMBER
        ALERT "No Chromecast, AirPlay, DIAL or DLNA devices found."
        LOG "yellow" "No castjack-capable targets."
        return
    fi

    choices=("${CAST_LABEL[@]}" "All $total target(s)" "Rescan" "Cancel")
    pick=$(LIST_PICKER "Push to target" "${choices[@]}")
    [ -z "$pick" ] && return

    if [ "$pick" = "Cancel" ]; then
        return
    fi
    if [ "$pick" = "Rescan" ]; then
        run_castjack "$dry"
        return
    fi

    if [ "$pick" = "All $total target(s)" ]; then
        if [ "$dry" != "1" ]; then
            resp=$(CONFIRMATION_DIALOG "Push this URL to all $total cast devices?\n\n$URL")
            confirmed "$resp" || return
            for i in "${CAST_KIND[@]}"; do
                if [ "$i" = "chromecast" ]; then
                    ensure_ssl
                    break
                fi
            done
        fi
        : > "$RUNLOG"
        LED RED
        ok=0
        i=0
        while [ $i -lt $total ]; do
            push_one "$i" "$dry"
            rc=$?
            [ $rc -eq 0 ] && ok=$((ok + 1))
            i=$((i + 1))
        done
    else
        num="${pick%%.*}"
        case "$num" in
            ''|*[!0-9]*) return ;;
        esac
        num=$((num - 1))
        if [ "$num" -lt 0 ] || [ "$num" -ge "$total" ]; then
            return
        fi

        if [ "$dry" != "1" ]; then
            resp=$(CONFIRMATION_DIALOG "Push this URL to ${CAST_LABEL[$num]}?\n\n$URL\n\nThis changes what the device is playing.")
            confirmed "$resp" || return
            if [ "${CAST_KIND[$num]}" = "chromecast" ]; then
                ensure_ssl
            fi
        fi
        : > "$RUNLOG"
        LED RED
        push_one "$num" "$dry"
        if [ $? -eq 0 ]; then ok=1; else ok=0; fi
        total=1
    fi

    LED GREEN
    play_done
    LOG ""
    if [ "$dry" = "1" ]; then
        LOG "green" "Dry run complete. $ok of $total reachable."
    else
        LOG "green" "Castjack complete. $ok of $total succeeded."
    fi
    while IFS= read -r line; do
        [ -n "$line" ] && LOG "  $line"
    done < "$RUNLOG"
    LOG "  Loot: $LOOTDIR"

    if [ "$dry" = "1" ]; then
        ALERT "MIRRORCAST dry run\n\nReachable: $ok of $total\n\nNo media was sent.\nLoot: $LOOTDIR"
    else
        ALERT "MIRRORCAST castjack\n\nSucceeded: $ok of $total\n\nLoot:\n$LOOTDIR"
    fi
}

# === ABOUT ===
show_about() {
    LOG ""
    LOG "cyan" "MIRRORCAST v1.0.0"
    LOG ""
    LOG "A cast and print discovery honeypot."
    LOG ""
    LOG "Honeypot impersonates:"
    LOG "  - Chromecast (_googlecast)"
    LOG "  - AirPlay / RAOP"
    LOG "  - DIAL (smart TVs, speakers)"
    LOG "  - IPP printers (print capture)"
    LOG ""
    LOG "Every probe is logged, including"
    LOG "mDNS names, SSDP user agents, HTTP"
    LOG "headers, and IPP print documents."
    LOG ""
    LOG "Castjack discovers real devices and"
    LOG "pushes one media URL to Chromecast,"
    LOG "AirPlay, DIAL or DLNA renderers."
    LOG ""
    LOG "Loot: $LOOTDIR"
    LOG ""
    LOG "red" "AUTHORIZED TESTING ONLY"
    LOG ""
    WAIT_FOR_INPUT
}

# === MAIN ===
LED WHITE 2>/dev/null
LOG ""
LOG "cyan" "=============================================="
LOG "cyan" "  MIRRORCAST - Cast & Print Honeypot v1.0.0"
LOG "cyan" "=============================================="
LOG ""

if ! scope_gate; then
    LOG "yellow" "Authorization not confirmed. Exiting."
    LED WHITE 2>/dev/null
    exit 1
fi

if [ -z "$PAYLOAD_DIR" ] || [ ! -f "$ENGINE" ]; then
    LED RED 2>/dev/null
    ALERT "mirrorcast.py not found.\n\nExpected next to payload.sh or in /root/payloads/user/interception/mirrorcast"
    exit 1
fi

if ! ensure_python; then
    LED RED 2>/dev/null
    exit 1
fi

if ! pick_interface; then
    LOG "yellow" "No interface selected. Exiting."
    LED WHITE 2>/dev/null
    exit 1
fi

LOG "green" "Interface: $IFACE ($IFACE_IP)"
mkdir -p "$LOOTDIR"

while true; do
    choice=$(LIST_PICKER "MIRRORCAST" \
        "Honeypot - capture probes" \
        "Scan - find cast devices" \
        "Castjack - push media" \
        "Castjack - dry run" \
        "About / safety" \
        "Exit")

    if [ -z "$choice" ]; then
        break
    fi

    case "$choice" in
        "Honeypot"*)
            run_honeypot
            ;;
        "Scan"*)
            run_scan
            ;;
        "Castjack - push"*)
            run_castjack 0
            ;;
        "Castjack - dry"*)
            run_castjack 1
            ;;
        "About"*)
            show_about
            ;;
        "Exit")
            break
            ;;
        *)
            LOG "yellow" "Unknown selection: $choice"
            ;;
    esac
    LED WHITE 2>/dev/null
done

LOG ""
LOG "green" "MIRRORCAST exiting."
LED WHITE 2>/dev/null
exit 0
