#!/bin/bash
# Title: Quartermaster
# Author: Valleytech Solutions
# Description: Wi-Fi, Bluetooth and LoRa mesh wardriver with WiGLE logs, uploads, Drive Alerts for Flock, Axon and Meta glasses, Recon, and Biscuit 6 GHz node mode
# Version: 1.1.2
# Category: Reconnaissance
#
# Options: none needed. Upload keys are entered on the Pager or from a phone, never in this file.
# Logs: /root/loot/quartermaster
# Needs: python3, python3-pillow and python3-pyserial from the Pager's package feed. Quartermaster asks before installing them.
# Controls: D-pad moves, green opens, hold green for actions, red goes back, hold red for 2 seconds to leave.

PACKAGES="python3 python3-pillow python3-pyserial"
LAUNCH_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/mmc/usr/bin:/mmc/usr/sbin:/mmc/bin:/mmc/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:/mmc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QUARTERMASTER_HOME="/root/loot/quartermaster"
export PYTHONPYCACHEPREFIX="$QUARTERMASTER_HOME/.python-cache"
LOG_FILE="/tmp/quartermaster.log"
LOCK="/tmp/quartermaster.lock"
BISCUIT_RADIO="/tmp/quartermaster-biscuit-radio"
DISPLAY_SET=0

find_python() {
    PYTHON_BIN=""
    for candidate in /usr/bin/python3 /mmc/usr/bin/python3; do
        [ -x "$candidate" ] || continue
        PYTHON_BIN="$candidate"
        PYVER=$("$candidate" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue
        for lib in "/mmc/usr/lib/python$PYVER" "/mmc/usr/lib/python$PYVER/lib-dynload"; do
            [ -d "$lib" ] && PYTHONPATH="$lib${PYTHONPATH:+:$PYTHONPATH}"
        done
        export PYTHONPATH="$LAUNCH_DIR${PYTHONPATH:+:$PYTHONPATH}"
        return 0
    done
    export PYTHONPATH="$LAUNCH_DIR"
    return 1
}

ready() {
    find_python || return 1
    "$PYTHON_BIN" -B -c 'import PIL.Image, serial, json, mmap, fcntl, ssl, multiprocessing, http.server, gzip, csv, zlib' \
        >/dev/null 2>&1
}

install_packages() {
    response=$(CONFIRMATION_DIALOG "Quartermaster needs Python 3, Pillow and pyserial.\n\nInstall $PACKAGES to the Pager's storage now?\n\nThis needs internet access.")
    [ "$response" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || return 2
    SPINNER=$(START_SPINNER "Installing Python 3, Pillow and pyserial...")
    opkg update >"$LOG_FILE" 2>&1
    opkg -d mmc install $PACKAGES >>"$LOG_FILE" 2>&1
    STOP_SPINNER "$SPINNER"
    ready
}

rtl_sdr_plugged() {
    for node in /sys/bus/usb/devices/*; do
        case "$(cat "$node/idVendor" 2>/dev/null):$(cat "$node/idProduct" 2>/dev/null)" in
            0bda:2838|0bda:2832) return 0 ;;
        esac
    done
    return 1
}

offer_rtl_sdr() {
    rtl_sdr_plugged || return 0
    command -v rtl_adsb >/dev/null 2>&1 && return 0
    [ -f "$QUARTERMASTER_HOME/.no-rtl-sdr" ] && return 0
    response=$(CONFIRMATION_DIALOG "An RTL-SDR stick is plugged in.\n\nInstall rtl-sdr to the Pager's storage so the ADS-B tile can show aircraft?\n\nThis needs internet access.")
    if [ "$response" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        touch "$QUARTERMASTER_HOME/.no-rtl-sdr"
        return 0
    fi
    SPINNER=$(START_SPINNER "Installing rtl-sdr...")
    opkg update >"$LOG_FILE" 2>&1
    opkg -d mmc install rtl-sdr >>"$LOG_FILE" 2>&1
    STOP_SPINNER "$SPINNER"
    command -v rtl_adsb >/dev/null 2>&1 || ERROR_DIALOG "rtl-sdr could not be installed. See $LOG_FILE"
}

cleanup() {
    if [ -n "$QM_PID" ]; then
        kill "$QM_PID" 2>/dev/null
        wait "$QM_PID" 2>/dev/null
    fi
    if [ -f "$BISCUIT_RADIO" ]; then
        uci -q revert pineapd.wlan1mon.hop
        uci -q revert pineapd.wlan1mon.channel
        /etc/init.d/pineapd restart >/dev/null 2>&1
        rm -f "$BISCUIT_RADIO"
    fi
    if [ "$DISPLAY_SET" = 1 ]; then
        UI_RELEASE >/dev/null 2>&1
        DISPLAY_SET=0
    fi
    rm -rf "$LOCK"
}

if ! mkdir "$LOCK" 2>/dev/null; then
    OLD=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
        ERROR_DIALOG "Quartermaster is already running."
        exit 1
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" || { ERROR_DIALOG "Quartermaster could not start."; exit 1; }
fi
echo "$$" >"$LOCK/pid"
trap cleanup EXIT
trap 'exit 0' INT TERM

if ! ready; then
    install_packages
    case $? in
        0) ;;
        2) LOG "Quartermaster needs Python 3, Pillow and pyserial to run."; exit 0 ;;
        *) ERROR_DIALOG "Python 3, Pillow and pyserial could not be installed. See $LOG_FILE"; exit 1 ;;
    esac
fi

mkdir -p "$QUARTERMASTER_HOME"
offer_rtl_sdr
UI_TAKEOVER >/dev/null 2>&1 || { ERROR_DIALOG "Could not take over the Pager screen."; exit 1; }
DISPLAY_SET=1
"$PYTHON_BIN" -m qmpager >"$LOG_FILE" 2>&1 &
QM_PID=$!
wait "$QM_PID"
STATUS=$?
QM_PID=""
cleanup
trap - EXIT
if [ "$STATUS" -ne 0 ]; then
    ERROR_DIALOG "Quartermaster stopped unexpectedly. See $LOG_FILE and $QUARTERMASTER_HOME/errors.log"
    exit "$STATUS"
fi
