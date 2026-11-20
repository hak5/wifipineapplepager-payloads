#!/bin/bash
# Title: Biscuit Pager Node (GUI)
# Author: GSHD + Hedge
# Description: Scans 6 GHz Wi-Fi and feeds what it hears to a Biscuit over ESP-NOW
# Version: 1.1.0
# Category: Reconnaissance

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/mmc/usr/sbin:/mmc/usr/bin:/mmc/sbin:/mmc/bin:$PATH"
DIR=""
for d in "${_PAYLOAD_HOME:-}" "$(cd "$(dirname "$0")" 2>/dev/null && pwd)" \
         /root/payloads/user/*/biscuit_pager_node_gui /mmc/root/payloads/user/*/biscuit_pager_node_gui; do
    [ -f "$d/pager_node.py" ] && { DIR="$d"; break; }
done
STATS=/tmp/biscuit_node_gui_stats.json
RUNLOG=/tmp/biscuit_node_gui.log
BTN=/tmp/biscuit_node_gui_button
IFACE=wlan1mon
MMC_PY=/mmc/usr/lib/python3.11
export PYTHONPATH="$MMC_PY:$MMC_PY/lib-dynload"
export LD_LIBRARY_PATH="/mmc/usr/lib:/mmc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

python_ok() {
    {
        echo "PATH=$PATH"
        echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
        echo "PYTHONHOME=${PYTHONHOME:-}"
        echo "PYTHONPATH=$PYTHONPATH"
        type -a python3
    } > /tmp/biscuit_python.log 2>&1
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not found" >> /tmp/biscuit_python.log
        return 1
    fi
    python3 -c "import sys; print(sys.executable); print(sys.version); print(sys.path); import socket, struct, select, json, subprocess, array, signal, ctypes" >> /tmp/biscuit_python.log 2>&1
}

install_python() {
    local id ok=1
    id=$(START_SPINNER "Installing Python 3")
    opkg update >/tmp/biscuit_opkg.log 2>&1 &&
        opkg install -d mmc python3-light python3-ctypes >>/tmp/biscuit_opkg.log 2>&1 && ok=0
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
    cp /tmp/biscuit_python.log /tmp/biscuit_python_before_install.log

    local need="python3-light"
    command -v python3 >/dev/null 2>&1 || need="python3-base, python3-light"
    LOG yellow "Missing: $need"

    if ping -c 1 -W 3 downloads.openwrt.org >/dev/null 2>&1; then
        local response
        # The dialog prints 1 for Yes, 0 for No/Cancel. Both exit successfully.
        # Fail closed: no installation or radio changes without explicit Yes.
        response=$(CONFIRMATION_DIALOG "Python check failed. Install dependencies?") || {
            LOG yellow "Dependency prompt failed; quitting"
            exit 1
        }
        case "$response" in
            1) ;;  # Explicit confirmation only.
            *) LOG "Installation cancelled"; exit 0 ;;
        esac
        if install_python && python_ok; then
            LOG green "Python 3 installed"
            return 0
        fi
        ERROR_DIALOG "Python setup failed. See /tmp/biscuit_opkg.log and /tmp/biscuit_python.log"
        exit 1
    fi
    ERROR_DIALOG "Needs $need. Connect the Pager to Wi-Fi and run again."
    exit 1
}

NODE_PID=""
BTN_PID=""
GUI_PID=""
DISPLAY_SET=0
RADIO_SET=0

# Radio settings go back first: the Pager may kill the payload a few seconds after a button press.
cleanup() {
    if [ -n "$GUI_PID" ]; then
        kill "$GUI_PID" 2>/dev/null
        wait "$GUI_PID" 2>/dev/null
        GUI_PID=""
    fi
    if [ "$DISPLAY_SET" = 1 ]; then
        /etc/init.d/pineapplepager start >/dev/null 2>&1
        DISPLAY_SET=0
    fi
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

# pagerctl must be installed with its MIPS shared library. Never take over
# the display until Python can import the wrapper and load its native library.
if ! python3 "$DIR/gui.py" --check >>/tmp/biscuit_python.log 2>&1; then
    response=$(CONFIRMATION_DIALOG "GUI library missing. Download pagerctl from GitHub?") || exit 1
    case "$response" in 1) ;; *) LOG "Setup cancelled"; exit 0 ;; esac
    if ! bash "$DIR/install_pagerctl.sh" >>/tmp/biscuit_pagerctl_install.log 2>&1 ||
       ! python3 "$DIR/gui.py" --check >>/tmp/biscuit_python.log 2>&1; then
        ERROR_DIALOG "pagerctl setup failed. See /tmp/biscuit_pagerctl_install.log and /tmp/biscuit_python.log"
        exit 1
    fi
fi

uci set pineapd.wlan1mon.hop=0
uci set pineapd.wlan1mon.channel=6
RADIO_SET=1
/etc/init.d/pineapd restart >/dev/null 2>&1
sleep 3
rm -f "$STATS"
python3 "$DIR/pager_node.py" --iface "$IFACE" --stats "$STATS" >/dev/null 2>"$RUNLOG" &
NODE_PID=$!
DISPLAY_SET=1
/etc/init.d/pineapplepager stop >/dev/null 2>&1 || exit 1
python3 "$DIR/gui.py" --stats "$STATS" --node-pid "$NODE_PID" 2>/tmp/biscuit_gui.log &
GUI_PID=$!
wait "$GUI_PID"
GUI_RC=$?
GUI_PID=""
cleanup
NODE_PID=""; RADIO_SET=0
trap - EXIT
if [ "$GUI_RC" != 0 ]; then
    ERROR_DIALOG "GUI stopped unexpectedly. See /tmp/biscuit_gui.log"
fi
exit "$GUI_RC"

