#!/bin/bash
# Title: PWRLVL9000 — Pentesting Web UI
# Author: sinX
# Description: Browser-based pentesting dashboard. Open http://172.16.42.1:9000 in any browser.
# Version: 1.9
# Category: user/interception
# Firmware: 2.0.0-stable or newer

WEBUI_PORT="${WEBUI_PORT:-9000}"
LOG_FILE="/tmp/pwrlvl9000.log"

# Python installed to MMC needs its library path exported (same as PagerBjorn)
export LD_LIBRARY_PATH="/mmc/usr/lib:${LD_LIBRARY_PATH}"
export PATH="/mmc/usr/bin:/usr/bin:${PATH}"

# ------------------------------------------------------------------ #
# Fallback stubs for running outside the Pager
# ------------------------------------------------------------------ #
if ! command -v LOG            >/dev/null 2>&1; then LOG()           { echo "${1:-} ${2:-}"; }; fi
if ! command -v LED            >/dev/null 2>&1; then LED()           { :; }; fi
if ! command -v VIBRATE        >/dev/null 2>&1; then VIBRATE()       { :; }; fi
if ! command -v ERROR_DIALOG   >/dev/null 2>&1; then ERROR_DIALOG()  { echo "ERROR: $*"; }; fi
if ! command -v START_SPINNER  >/dev/null 2>&1; then START_SPINNER() { echo "... $*"; echo $$; }; fi
if ! command -v STOP_SPINNER   >/dev/null 2>&1; then STOP_SPINNER()  { :; }; fi
if ! command -v WAIT_FOR_INPUT >/dev/null 2>&1; then WAIT_FOR_INPUT(){ read -r _btn; echo "${_btn:-B}"; }; fi

# Persistent log — written first so we know the script ran at all
echo "=== PWRLVL9000 v1.9 START ===" > "$LOG_FILE" 2>/dev/null
# Full execution trace to the log for on-device debugging
exec 2>>"$LOG_FILE"
set -x
date >> "$LOG_FILE" 2>/dev/null
echo "Running as: $(basename "${BASH_SOURCE[0]:-$0}") from $(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" >> "$LOG_FILE" 2>/dev/null
# Visible proof-of-life before anything can fail silently
LED BLUE 2>/dev/null
LOG ""
LOG "cyan" "PWRLVL9000 v1.9 starting..."

# ------------------------------------------------------------------ #
# Find python3
# ------------------------------------------------------------------ #
PYTHON3_BIN=""
for _p in python3 /mmc/usr/bin/python3 /usr/bin/python3 /usr/local/bin/python3; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then
        PYTHON3_BIN="$_p"; break
    fi
done

if [ -z "$PYTHON3_BIN" ]; then
    LED RED
    LOG "red" "python3 not found!"
    LOG "red" "Run: opkg install python3-light"
    ERROR_DIALOG "python3 not found\nRun: opkg install python3-light"
    exit 1
fi

echo "Python: $("$PYTHON3_BIN" --version 2>&1)" >> "$LOG_FILE" 2>/dev/null

# ------------------------------------------------------------------ #
# Find server.py — check all likely locations
# ------------------------------------------------------------------ #
PAYLOAD_DIR=""
SERVER_PY=""
for _d in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" \
    "/root/payloads/user/interception/pwrlvl9000" \
    "/mmc/root/payloads/user/interception/pwrlvl9000" \
    "/root/payloads/user/pwrlvl9000" \
    "/mmc/root/payloads/user/pwrlvl9000" \
    /root/payloads/user/*/pwrlvl9000 \
    /mmc/root/payloads/user/*/pwrlvl9000; do
    echo "Checking: $_d/server.py" >> "$LOG_FILE" 2>/dev/null
    if [ -f "$_d/server.py" ]; then
        PAYLOAD_DIR="$_d"
        SERVER_PY="$_d/server.py"
        echo "Found server.py at: $SERVER_PY" >> "$LOG_FILE" 2>/dev/null
        break
    fi
done

if [ -z "$SERVER_PY" ]; then
    echo "ERROR: server.py not found" >> "$LOG_FILE" 2>/dev/null
    LED RED
    LOG "red" "server.py not found!"
    LOG "red" "payload.sh must sit next to server.py"
    ERROR_DIALOG "server.py not found\nRedeploy payload\nLog: $LOG_FILE"
    exit 1
fi

# Now that PAYLOAD_DIR is known, add lib/ to library paths so
# libpagerctl.so can be loaded by pager_display.py
export LD_LIBRARY_PATH="$PAYLOAD_DIR/lib:${LD_LIBRARY_PATH}"
export PYTHONPATH="$PAYLOAD_DIR/lib:${PYTHONPATH}"
echo "PAYLOAD_DIR: $PAYLOAD_DIR" >> "$LOG_FILE" 2>/dev/null

# ------------------------------------------------------------------ #
# Preflight — only modules guaranteed in python3-base
# ------------------------------------------------------------------ #
_CHECK=$("$PYTHON3_BIN" -c \
    "import os,sys,socket,json,subprocess,re,time,threading,queue,collections; print('OK')" \
    2>&1)

echo "Preflight: $_CHECK" >> "$LOG_FILE" 2>/dev/null

if [ "$_CHECK" != "OK" ]; then
    LED RED
    LOG "red" "Python module missing: $_CHECK"
    LOG "red" "Fix: opkg install python3-light"
    ERROR_DIALOG "Python module missing:\n$_CHECK\nFix: opkg install python3-light"
    exit 1
fi

# ------------------------------------------------------------------ #
# Storage
# ------------------------------------------------------------------ #
LOOT_DIR="/root/loot/pwrlvl9000"
HANDSHAKE_DIR="/root/loot/handshakes"
if [ -d /mmc/root/loot ]; then
    LOOT_DIR="/mmc/root/loot/pwrlvl9000"
    HANDSHAKE_DIR="/mmc/root/loot/handshakes"
fi
mkdir -p "$LOOT_DIR" "$HANDSHAKE_DIR" 2>/dev/null

# ------------------------------------------------------------------ #
# Firewall + cleanup trap
# ------------------------------------------------------------------ #
# Firmware 2.0.0 uses fw4/nftables and accepts LAN-side input by default
# (other web payloads rely on this). Only poke iptables if it exists.
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$WEBUI_PORT" -j ACCEPT 2>/dev/null
fi

SERVER_PID=""
_cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null
    pkill -f "python3.*server.py" 2>/dev/null
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "$WEBUI_PORT" -j ACCEPT 2>/dev/null
    fi
    # Restart pineapplepager in case pager_display.py stopped it
    if ! pgrep -x pineapple >/dev/null 2>&1; then
        /etc/init.d/pineapplepager start 2>/dev/null
    fi
    # Keep a persistent copy of the run log in loot so it survives reboots
    # and is browsable from Manage Data > Files.
    if [ -n "$LOOT_DIR" ] && [ -d "$LOOT_DIR" ] && [ -f "$LOG_FILE" ]; then
        cp "$LOG_FILE" "$LOOT_DIR/last_run.log" 2>/dev/null
    fi
    LOG ""
    LOG "green" "PWRLVL9000 stopped."
    LED WHITE
}
trap _cleanup EXIT INT TERM
# Firmware 2.0.0 can SIGHUP the payload when its process is backgrounded
# after launch — never let that tear down the server.
trap '' HUP 2>/dev/null

# ------------------------------------------------------------------ #
# Launch server in background
# ------------------------------------------------------------------ #
export PAYLOAD_DIR WEBUI_PORT LOOT_DIR HANDSHAKE_DIR

# Kill any stale server from a previous run so the port is free
pkill -f "python3.*server.py" 2>/dev/null; sleep 1

echo "Launching server on port $WEBUI_PORT..." >> "$LOG_FILE" 2>/dev/null
"$PYTHON3_BIN" "$SERVER_PY" >> "$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID" >> "$LOG_FILE" 2>/dev/null

# ------------------------------------------------------------------ #
# Wait for server to come up (up to 10 seconds)
# ------------------------------------------------------------------ #
SPINNER_ID=$(START_SPINNER "Starting PWRLVL9000..." 2>/dev/null)

_ok=0
for _t in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        STOP_SPINNER "$SPINNER_ID" 2>/dev/null
        LED RED
        _err=$(tail -6 "$LOG_FILE" 2>/dev/null)
        ERROR_DIALOG "Server crashed:\n$_err"
        exit 1
    fi
    if wget -q -T 2 -O /dev/null "http://127.0.0.1:${WEBUI_PORT}/" 2>/dev/null; then
        _ok=1; break
    fi
done

STOP_SPINNER "$SPINNER_ID" 2>/dev/null

# ------------------------------------------------------------------ #
# Read XP/level for fallback display
# ------------------------------------------------------------------ #
_LEVEL_NUM=1
_LEVEL_TITLE="APPRENTICE"
_LEVEL_XP=0
_XP_NEXT=100
_XP_FILE="$LOOT_DIR/xp.json"
if [ -f "$_XP_FILE" ]; then
    _xp_info=$("$PYTHON3_BIN" -c "
import json, sys
try:
    d=json.load(open('$_XP_FILE'))
    xp=d.get('xp',0)
    lvls=[(0,1,'APPRENTICE'),(100,2,'ACOLYTE'),(300,3,'CONJURER'),
          (700,4,'WARLOCK'),(1500,5,'NECROMANCER'),(3000,6,'LICH'),
          (6000,7,'DREADLORD'),(12000,8,'ARCHLICH'),(25000,9000,'PWRLVL9000')]
    level,title,xp_next=1,'APPRENTICE',100
    for t,l,n in lvls:
        if xp>=t:level,title=l,n
        else:xp_next=t;break
    else:xp_next=0
    print(level);print(title);print(xp);print(xp_next)
except:
    print('1');print('APPRENTICE');print('0');print('100')
" 2>/dev/null)
    _LEVEL_NUM=$(echo "$_xp_info" | sed -n '1p')
    _LEVEL_TITLE=$(echo "$_xp_info" | sed -n '2p')
    _LEVEL_XP=$(echo "$_xp_info" | sed -n '3p')
    _XP_NEXT=$(echo "$_xp_info" | sed -n '4p')
fi

# ------------------------------------------------------------------ #
# Display screen — pagerctl if available, else LOG fallback
# ------------------------------------------------------------------ #
LED GREEN
VIBRATE

LOG "green" "Server UP."
LOG "cyan"  "Web UI: http://172.16.42.1:${WEBUI_PORT}"
LOG ""

echo "Server UP. Starting display..." >> "$LOG_FILE" 2>/dev/null

# Check whether we can use pagerctl for direct screen control
# pagerctl owns the screen by stopping pineapplepager; on 2.0.0 that path is
# not reliable, so the graphical display is opt-in. The web console (the
# actual tool) runs identically either way. Enable with PWRLVL_PAGERCTL=1.
_HAS_PAGERCTL=false
if [ "${PWRLVL_PAGERCTL:-0}" = "1" ] && \
   [ -f "$PAYLOAD_DIR/lib/pagerctl.py" ] && \
   [ -f "$PAYLOAD_DIR/lib/libpagerctl.so" ] && \
   [ -f "$PAYLOAD_DIR/pager_display.py" ] && \
   "$PYTHON3_BIN" -c "import ctypes" 2>/dev/null; then
    _HAS_PAGERCTL=true
fi

if [ "$_HAS_PAGERCTL" = "true" ]; then
    # ── pagerctl path: full graphical display ──────────────────────────
    echo "Using pagerctl display." >> "$LOG_FILE" 2>/dev/null
    # Run pager_display.py in the foreground — it blocks until B is pressed.
    # It stops pineapplepager, owns the screen, and restarts pineapplepager on exit.
    _disp_start=$(date +%s 2>/dev/null || echo 0)
    "$PYTHON3_BIN" "$PAYLOAD_DIR/pager_display.py" >> "$LOG_FILE" 2>&1
    _disp_rc=$?
    _disp_end=$(date +%s 2>/dev/null || echo 99)
    _disp_elapsed=$((_disp_end - _disp_start))
    echo "pager_display rc=$_disp_rc after ${_disp_elapsed}s" >> "$LOG_FILE" 2>/dev/null
    # A real stop takes a human a few seconds. Any faster exit — whatever the
    # return code — means the display bailed (phantom input, pagerctl drift),
    # so fall back to the LOG display instead of tearing down the server.
    if [ $_disp_rc -ne 0 ] || [ $_disp_elapsed -lt 5 ]; then
        echo "display exit too fast/rc=$_disp_rc — LOG fallback" >> "$LOG_FILE" 2>/dev/null
        _HAS_PAGERCTL=false
    fi
fi

if [ "$_HAS_PAGERCTL" != "true" ]; then
    # ── Fallback: LOG-based display + WAIT_FOR_INPUT loop ─────────────
    echo "Using LOG fallback display." >> "$LOG_FILE" 2>/dev/null

    LOG ""
    LOG "magenta" "=============================================="
    LOG "magenta" "   P W R L V L 9 0 0 0"
    LOG "cyan"    "          b y   d a r k s e c l a b z"
    LOG "magenta" "=============================================="
    LOG ""
    LOG "yellow" "LVL ${_LEVEL_NUM} ${_LEVEL_TITLE}"
    LOG "white"  "XP: ${_LEVEL_XP} / ${_XP_NEXT}"
    LOG ""
    LOG "cyan"   "172.16.42.1:${WEBUI_PORT}"
    LOG "red"    "[ B ] Stop"
    LOG ""

    # Wait for B/RED/Escape (nautilus pattern — known good on 2.0.0).
    while true; do
        BUTTON=$(WAIT_FOR_INPUT)
        case "$BUTTON" in
            "B"|"RED"|"Escape") break ;;
        esac
        # Exit early if server process has died
        if ! pgrep -f "python3.*server.py" >/dev/null 2>&1; then
            break
        fi
    done
fi

# Cleanup handled by EXIT trap
exit 0
