#!/bin/bash
# Title: KEYSMITH - Default WPA Key Cracker
# Author: sinXne0
# Description: Reads public beacon data, derives the ISP/router default WPA key from the SSID and BSSID, proves the candidate with a real 4-way handshake, then joins the network and shows the plaintext password. Algorithms ported from RouterKeygen.
# Version: 1.0.0
# Category: user/reconnaissance
# Firmware: 2.0.0-stable or newer
# Requires: python3-light, iw, wpa_supplicant (udhcpc recommended)
#
# Authorized testing only. KEYSMITH associates with the selected access
# point using a derived default key. Only point it at networks you own or
# have written permission to test.
#
# LED States
#   Cyan     scanning for APs with a known default-key scheme
#   Amber    deriving candidate keys
#   Blue     testing candidates against the 4-way handshake
#   Green    key verified, associated, lease obtained
#   Red      error / no candidate matched
#   Off      stopped
#
# Loot
#   /root/loot/keysmith/found.txt          one line per attack attempt
#   /root/loot/keysmith/keys_<bssid>.txt   every derived candidate
#
# The tri-band radio (phy1) is the only interface KEYSMITH touches. phy0
# carries the Pager's management uplink and is never scanned or reconfigured.

# === PAYLOAD SDK STUBS (kept so the script also runs standalone) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if ! command -v LOG             >/dev/null 2>&1; then LOG()             { echo "$*"; }; fi
if ! command -v LED             >/dev/null 2>&1; then LED()             { :; }; fi
if ! command -v ERROR_DIALOG    >/dev/null 2>&1; then ERROR_DIALOG()    { echo "ERROR: $*"; }; fi
if ! command -v CONFIRMATION_DIALOG >/dev/null 2>&1; then CONFIRMATION_DIALOG() { echo "${KEYSMITH_CONFIRM:-true}"; }; fi
if ! command -v WAIT_FOR_INPUT  >/dev/null 2>&1; then WAIT_FOR_INPUT()   { read -r _btn; echo "${_btn:-B}"; }; fi

# === SELF-LOCATE ===
PAYLOAD_DIR=""
for candidate in "$SCRIPT_DIR" \
                 "${KEYSMITH_PAYLOAD_DIR:-}" \
                 /root/payloads/user/*/keysmith \
                 /mmc/root/payloads/user/*/keysmith \
                 /root/payloads/user/*/KEYSMITH \
                 /mmc/root/payloads/user/*/KEYSMITH; do
    [ -n "$candidate" ] || continue
    if [ -f "$candidate/keysmith.py" ]; then
        PAYLOAD_DIR="$candidate"
        break
    fi
done

if [ -z "$PAYLOAD_DIR" ]; then
    LED RED 2>/dev/null
    LOG "red" "keysmith.py not found next to payload.sh"
    ERROR_DIALOG "KEYSMITH files missing.\nRedeploy the payload folder."
    exit 1
fi

export LD_LIBRARY_PATH="$PAYLOAD_DIR/lib:${LD_LIBRARY_PATH}"
export PYTHONPATH="$PAYLOAD_DIR:$PAYLOAD_DIR/lib:${PYTHONPATH}"

ENGINE="$PAYLOAD_DIR/keysmith.py"
UIPY="$PAYLOAD_DIR/ks/ui.py"
INSTALL_PKG="$PAYLOAD_DIR/install_pkg.py"
STATE_FILE="${KEYSMITH_STATE:-/tmp/keysmith_state.json}"
CMD_FILE="${KEYSMITH_CMD:-/tmp/keysmith_cmd.jsonl}"
RUNLOG="${KEYSMITH_LOG:-/tmp/keysmith_run.log}"
LOOT_DIR="${KEYSMITH_LOOT:-}"
ENGINE_PID=""
UI_PID=""

confirmed() {
    [ "$1" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || [ "$1" = "true" ]
}

echo "=== KEYSMITH v1.0.0 START ===" > "$RUNLOG" 2>/dev/null
exec 2>>"$RUNLOG"
date >> "$RUNLOG" 2>/dev/null
LED BLUE 2>/dev/null
LOG ""
LOG "green" "KEYSMITH  //  default-key attack"
LOG "cyan"  "starting..."

# === AUTHORIZATION GATE ===
if ! confirmed "$KEYSMITH_USER_CONFIRMED"; then
    _ans="$(CONFIRMATION_DIALOG "KEYSMITH derives factory-default WPA keys and joins the selected network.

Use only on networks you own or are authorised to test." 2>/dev/null)"
    case "$(echo "${_ans:-}" | tr 'A-Z' 'a-z')" in
        true|yes|y|ok|1) : ;;
        *)
            LOG "yellow" "authorization not confirmed - exiting"
            LED WHITE 2>/dev/null
            exit 0
            ;;
    esac
fi

# === PYTHON ===
PYTHON3_BIN=""
for _p in python3 /mmc/usr/bin/python3 /usr/bin/python3 /usr/local/bin/python3; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then
        PYTHON3_BIN="$_p"; break
    fi
done
if [ -z "$PYTHON3_BIN" ]; then
    LED RED 2>/dev/null
    LOG "red" "python3 not found"
    ERROR_DIALOG "python3 not found\nRun: opkg install python3-light"
    exit 1
fi

_CHECK=$("$PYTHON3_BIN" -c \
    "import os,sys,json,subprocess,re,time,threading,hashlib,argparse; print('OK')" \
    2>&1)
if [ "$_CHECK" != "OK" ]; then
    LED RED 2>/dev/null
    LOG "red" "Python module missing: $_CHECK"
    if [ -f "$INSTALL_PKG" ]; then
        LOG "cyan" "trying bundled package installer"
        "$PYTHON3_BIN" "$INSTALL_PKG" python3-light >>"$RUNLOG" 2>&1 || true
        _CHECK=$("$PYTHON3_BIN" -c \
            "import os,sys,json,subprocess,re,time,threading,hashlib,argparse; print('OK')" \
            2>&1)
    fi
    if [ "$_CHECK" != "OK" ]; then
        ERROR_DIALOG "Python module missing:\n$_CHECK\nRun: opkg install python3-light"
        exit 1
    fi
fi

# === DEPENDENCIES ===
_find_bin() {
    for _c in "$1" "/usr/sbin/$1" "/mmc/usr/sbin/$1" \
              "/usr/bin/$1" "/mmc/usr/bin/$1" "/sbin/$1" "/mmc/sbin/$1"; do
        if [ -x "$_c" ] || command -v "$_c" >/dev/null 2>&1; then
            echo "$_c"; return 0
        fi
    done
    return 1
}

if ! _find_bin iw >/dev/null; then
    LED RED 2>/dev/null
    LOG "red" "missing: iw"
    ERROR_DIALOG "iw is required.\n\nopkg install iw"
    exit 1
fi
if ! _find_bin wpa_supplicant >/dev/null; then
    LOG "yellow" "wpa_supplicant missing - derived-only mode"
    LOG "yellow" "keys will be shown but not verified"
fi
if ! _find_bin udhcpc >/dev/null; then
    LOG "yellow" "udhcpc missing - association will not get an IP"
fi

# === STORAGE ===
if [ -z "$LOOT_DIR" ]; then
    LOOT_DIR="/root/loot/keysmith"
    [ -d /mmc/root/loot ] && LOOT_DIR="/mmc/root/loot/keysmith"
fi
mkdir -p "$LOOT_DIR" 2>/dev/null
chmod 700 "$LOOT_DIR" 2>/dev/null
export KEYSMITH_LOOT="$LOOT_DIR"

# === CLEANUP ===
_CLEANED=""
_cleanup() {
    [ -n "$_CLEANED" ] && return
    _CLEANED=1
    LED WHITE 2>/dev/null
    # Ask the engine to shut down cleanly before signalling it.
    printf '%s\n' '{"cmd":"shutdown"}' >> "$CMD_FILE" 2>/dev/null
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        [ -n "$ENGINE_PID" ] && ! kill -0 "$ENGINE_PID" 2>/dev/null && break
        sleep 0.2
    done
    if [ -n "$ENGINE_PID" ] && kill -0 "$ENGINE_PID" 2>/dev/null; then
        kill -TERM "$ENGINE_PID" 2>/dev/null
    fi
    if [ -n "$UI_PID" ] && kill -0 "$UI_PID" 2>/dev/null; then
        kill -TERM "$UI_PID" 2>/dev/null
    fi
    [ -n "$ENGINE_PID" ] && wait "$ENGINE_PID" 2>/dev/null
    [ -n "$UI_PID" ] && wait "$UI_PID" 2>/dev/null
    # Only our own supplicant, matched by our private config path.
    pkill -f "/tmp/keysmith_live.conf" 2>/dev/null
    pkill -f "/tmp/keysmith_probe.conf" 2>/dev/null
    rm -f /tmp/keysmith_probe.conf /tmp/keysmith_live.conf \
          /tmp/keysmith_wpa.pid /tmp/keysmith_lease \
          "$STATE_FILE" "$CMD_FILE" 2>/dev/null
    rmdir /tmp/keysmith_ctrl 2>/dev/null
    if [ -f "$RUNLOG" ]; then
        cp "$RUNLOG" "$LOOT_DIR/keysmith.log" 2>/dev/null
        chmod 600 "$LOOT_DIR/keysmith.log" 2>/dev/null
    fi
    sync
}
trap '_cleanup; exit 0' INT TERM HUP

# === CONFIRM TARGET ===
LOG "cyan" "loot : $LOOT_DIR"
LOG "cyan" "state: $STATE_FILE"

# === START ENGINE ===
rm -f "$STATE_FILE" "$CMD_FILE" 2>/dev/null
touch "$CMD_FILE" 2>/dev/null
: > "$RUNLOG" 2>/dev/null
"$PYTHON3_BIN" "$ENGINE" run >>"$RUNLOG" 2>&1 &
ENGINE_PID=$!
LOG "cyan" "engine pid $ENGINE_PID"
sleep 1.2

if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
    LED RED 2>/dev/null
    _err=$("$PYTHON3_BIN" -c "import json;d=json.load(open('$STATE_FILE'));print(d.get('error') or d.get('message') or '?')" 2>/dev/null)
    LOG "red" "engine exited: ${_err:-unknown}"
    ERROR_DIALOG "KEYSMITH engine failed to start.\n${_err}\n\nLog: $LOOT_DIR/keysmith.log"
    _cleanup
    exit 1
fi

# === UI ===
_HAS_UI="false"
if [ "$KEYSMITH_PAGERCTL" != "0" ] && \
   "$PYTHON3_BIN" -c "import ctypes,os,sys;sys.path.insert(0,'$PAYLOAD_DIR/lib');import pagerctl" 2>/dev/null; then
    _HAS_UI="true"
fi

if [ "$_HAS_UI" = "true" ]; then
    "$PYTHON3_BIN" "$UIPY" >>"$RUNLOG" 2>&1 &
    UI_PID=$!
    LOG "cyan" "ui pid $UI_PID"
    # The UI exits when the user quits; do not outlive a dead engine.
    while kill -0 "$UI_PID" 2>/dev/null; do
        if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
            LOG "red" "engine exited while ui was running"
            break
        fi
        sleep 0.5
    done
else
    LOG "yellow" "pagerctl unavailable - LOG fallback display"
    while kill -0 "$ENGINE_PID" 2>/dev/null; do
        _phase=$("$PYTHON3_BIN" -c "import json;print(json.load(open('$STATE_FILE')).get('phase','?'))" 2>/dev/null)
        _msg=$("$PYTHON3_BIN" -c "import json;print(json.load(open('$STATE_FILE')).get('message',''))" 2>/dev/null)
        LOG "magenta" "=============================================="
        LOG "magenta" "            K E Y S M I T H"
        LOG "magenta" "=============================================="
        LOG "white"   "phase : ${_phase:-?}"
        LOG "white"   "status: ${_msg:-}"
        LOG "cyan"    "cmd   : echo '{\"cmd\":\"plan\",\"ap\":0}' >> $CMD_FILE"
        LOG "red"     "[ B ] Stop"
        BUTTON=$(WAIT_FOR_INPUT)
        case "$BUTTON" in
            "B"|"RED"|"Escape") break ;;
        esac
    done
fi

# If the UI exited on its own (engine finished and user pressed B), give the
# engine a moment, then shut it down if it is still around.
for _i in 1 2 3 4 5; do
    kill -0 "$ENGINE_PID" 2>/dev/null || break
    sleep 0.2
done

_cleanup

if [ -s "$LOOT_DIR/found.txt" ]; then
    LOG ""
    LOG "green" "results:"
    tail -n 5 "$LOOT_DIR/found.txt" | while IFS= read -r _line; do
        LOG "white" "$_line"
    done
fi
LOG ""
LOG "cyan" "loot: $LOOT_DIR"
LOG "green" "done."
exit 0
