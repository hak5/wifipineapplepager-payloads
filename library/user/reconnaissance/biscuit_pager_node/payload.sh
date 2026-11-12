#!/bin/bash
# Title: Biscuit Pager Node
# Author: Biscuit
# Description: Scans 6 GHz Wi-Fi and feeds what it hears to a Biscuit over ESP-NOW
# Version: 1.0.0
# Category: Reconnaissance

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
DIR=""
for d in "${_PAYLOAD_HOME:-}" "$(cd "$(dirname "$0")" 2>/dev/null && pwd)" \
         /root/payloads/user/*/biscuit_pager_node /mmc/root/payloads/user/*/biscuit_pager_node; do
    [ -f "$d/pager_node.py" ] && { DIR="$d"; break; }
done
STATS=/tmp/biscuit_node_stats.json
RUNLOG=/tmp/biscuit_node.log
BTN=/tmp/biscuit_node_button
IFACE=wlan1mon
MMC_PY=/mmc/usr/lib/python3.11
export PYTHONPATH="$MMC_PY:$MMC_PY/lib-dynload"

python_ok() {
    command -v python3 >/dev/null 2>&1 &&
        python3 -c "import socket, struct, select, json, subprocess, array, signal" >/dev/null 2>&1
}

install_python() {
    local id ok=1
    id=$(START_SPINNER "Installing Python 3")
    opkg update >/tmp/biscuit_opkg.log 2>&1 &&
        { command -v python3 >/dev/null 2>&1 || opkg install python3-base >>/tmp/biscuit_opkg.log 2>&1; } &&
        opkg install -d mmc python3-light >>/tmp/biscuit_opkg.log 2>&1 && ok=0
    STOP_SPINNER "$id"
    return $ok
}

check_dependencies() {
    if [ -z "$DIR" ]; then
        ERROR_DIALOG "Payload files missing. Reinstall biscuit_pager_node."
        exit 1
    fi
    if ! iw dev "$IFACE" info >/dev/null 2>&1; then
        ERROR_DIALOG "No $IFACE. The tri-band radio must be in monitor mode."
        exit 1
    fi
    python_ok && return 0

    local need="python3-light"
    command -v python3 >/dev/null 2>&1 || need="python3-base, python3-light"
    LOG yellow "Missing: $need"

    if ping -c 1 -W 3 downloads.openwrt.org >/dev/null 2>&1; then
        CONFIRMATION_DIALOG "Python 3 is missing. Download it now? (about 4 MB)" || exit 0
        if install_python && python_ok; then
            LOG green "Python 3 installed"
            return 0
        fi
        ERROR_DIALOG "Install failed. See /tmp/biscuit_opkg.log"
        exit 1
    fi
    ERROR_DIALOG "Needs $need. Connect the Pager to Wi-Fi and run again."
    exit 1
}

NODE_PID=""
BTN_PID=""
RADIO_SET=0

# Radio settings go back first: the Pager may kill the payload a few seconds after a button press.
cleanup() {
    if [ "$RADIO_SET" = 1 ]; then
        uci -q revert pineapd.wlan1mon.hop
        uci -q revert pineapd.wlan1mon.channel
    fi
    [ -n "$BTN_PID" ] && kill "$BTN_PID" 2>/dev/null
    if [ -n "$NODE_PID" ]; then
        kill "$NODE_PID" 2>/dev/null
        for _ in 1 2 3 4 5; do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 0.2; done
        kill -9 "$NODE_PID" 2>/dev/null
    fi
    if [ "$RADIO_SET" = 1 ]; then
        setsid /etc/init.d/pineapd restart >/dev/null 2>&1 </dev/null &
    fi
    rm -f "$BTN"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

check_dependencies
PROMPT_IMAGE "$DIR/splash.png"

uci set pineapd.wlan1mon.hop=0
uci set pineapd.wlan1mon.channel=6
RADIO_SET=1
/etc/init.d/pineapd restart >/dev/null 2>&1
sleep 3

rm -f "$STATS" "$BTN"
python3 "$DIR/pager_node.py" --iface "$IFACE" --stats "$STATS" >/dev/null 2>"$RUNLOG" &
NODE_PID=$!

LOG "Scanning 6 GHz"
LOG "Press A to stop"
(WAIT_FOR_BUTTON_PRESS A >"$BTN" 2>/dev/null; echo A >>"$BTN") &
BTN_PID=$!

while kill -0 "$NODE_PID" 2>/dev/null && [ ! -s "$BTN" ]; do
    sleep 2
done

if ! kill -0 "$NODE_PID" 2>/dev/null && [ ! -s "$BTN" ]; then
    ERROR_DIALOG "Node stopped. See $RUNLOG"
fi
cleanup
NODE_PID=""; BTN_PID=""; RADIO_SET=0
trap - EXIT

summary=$(python3 "$DIR/stats.py" summary "$STATS" 2>/dev/null)
while IFS='|' read -r color text; do LOG "$color" "$text"; done <<<"$summary"
PROMPT "$(python3 "$DIR/stats.py" prompt "$STATS" 2>/dev/null)"
exit 0
