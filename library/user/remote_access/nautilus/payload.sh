#!/bin/bash
#
# Title: Nautilus
# Description: Web-based payload launcher with live console output and GitHub integration
# Author: JustSomeTrout (Trout / troot.)
# Version: 1.5.2
# Firmware: Developed for Firmware version 1.0.4
#
# Runs uhttpd with CGI to browse and execute payloads from your browser.
# Now with GitHub integration - run payloads directly from the official repo or PRs!
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$SCRIPT_DIR/www"
PORT=8888
PID_FILE="/tmp/nautilus.pid"
INIT_SCRIPT="/etc/init.d/nautilus"

get_pager_ip() {
    for iface in br-lan eth0 wlan0 usb0; do
        IP=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -1)
        [ -n "$IP" ] && echo "$IP" && return
    done
    echo "172.16.52.1"
}

LOG ""
LOG "cyan" '+======================+'
LOG "cyan" '|╔╗╔╔═╗╦-╦╔╦╗╦╦--╦-╦╔═╗|'
LOG "cyan" '|║║║╠═╣║-║-║-║║--║-║╚═╗|'
LOG "cyan" '|╝╚╝╩-╩╚═╝-╩-╩╩═╝╚═╝╚═╝|'
LOG "cyan" '+======================+'
LOG ""
LOG "v1.5.2"
LOG ""
LOG "yellow" '|   ~ Web Payload Launcher ~    |'
LOG ""

if [ -f "$INIT_SCRIPT" ] && "$INIT_SCRIPT" running 2>/dev/null; then
    LOG "green" "Nautilus service is running"
    PAGER_IP=$(get_pager_ip)
    LOG "green" "http://$PAGER_IP:$PORT"
    LOG ""
    resp=$(CONFIRMATION_DIALOG "Stop service?")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG "yellow" "Stopping service..."
        "$INIT_SCRIPT" stop
        "$INIT_SCRIPT" disable
        rm -f "$INIT_SCRIPT"
        LOG "cyan" "Service stopped"
    fi
    exit 0
fi

resp=$(CONFIRMATION_DIALOG "Run as background service?")

if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    LOG "cyan" "Starting as service..."

    if ! command -v uhttpd >/dev/null 2>&1; then
        LOG "yellow" "uhttpd required (~28KB)"
        resp=$(CONFIRMATION_DIALOG "Install uhttpd?")
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            LOG "cyan" "Installing uhttpd..."
            opkg update >/dev/null 2>&1
            if ! opkg install uhttpd; then
                LOG "red" "Install failed!"
                exit 1
            fi
        else
            LOG "red" "Cannot run without uhttpd"
            exit 1
        fi
    fi

    if ! command -v ttyd >/dev/null 2>&1; then
        LOG "yellow" "ttyd required for shell (~150KB)"
        resp=$(CONFIRMATION_DIALOG "Install ttyd?")
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            LOG "cyan" "Installing ttyd..."
            opkg update >/dev/null 2>&1
            if ! opkg install ttyd; then
                LOG "yellow" "Shell feature disabled"
            else
                /etc/init.d/ttyd disable 2>/dev/null
            fi
        fi
    fi

    [ ! -f "$WEB_DIR/index.html" ] && { LOG "red" "Files not found!"; exit 1; }

    cp "$SCRIPT_DIR/nautilus.init" "$INIT_SCRIPT"
    chmod +x "$INIT_SCRIPT"
    "$INIT_SCRIPT" enable
    "$INIT_SCRIPT" start

    sleep 1
    PAGER_IP=$(get_pager_ip)
    LOG "green" "Service started!"
    LOG "green" "http://$PAGER_IP:$PORT"
    LOG ""
    LOG "cyan" "Runs in background"
    LOG "cyan" "Re-run payload to stop"
    sleep 3
    exit 0
fi

LOG "cyan" "Starting foreground mode..."

if ! command -v uhttpd >/dev/null 2>&1; then
    LOG "yellow" "uhttpd required (~28KB)"
    resp=$(CONFIRMATION_DIALOG "Install uhttpd?")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG "cyan" "Installing uhttpd..."
        opkg update >/dev/null 2>&1
        if ! opkg install uhttpd; then
            LOG "red" "Install failed!"
            exit 1
        fi
    else
        LOG "red" "Cannot run without uhttpd"
        exit 1
    fi
fi

TTYD_STARTED=0
if ! command -v ttyd >/dev/null 2>&1; then
    LOG "yellow" "ttyd required for shell (~150KB)"
    resp=$(CONFIRMATION_DIALOG "Install ttyd?")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG "cyan" "Installing ttyd..."
        opkg update >/dev/null 2>&1
        if ! opkg install ttyd; then
            LOG "red" "ttyd install failed!"
            LOG "yellow" "Shell feature disabled"
        else
            /etc/init.d/ttyd disable 2>/dev/null
            LOG "green" "ttyd installed"
        fi
    else
        LOG "yellow" "Shell feature disabled"
    fi
fi

if command -v ttyd >/dev/null 2>&1; then
    killall ttyd 2>/dev/null
    ttyd -p 7681 /bin/login &
    TTYD_STARTED=1
    LOG "cyan" "Shell available on port 7681"
fi

cleanup() {
    LOG "yellow" "Stopping Nautilus..."
    [ -f "$PID_FILE" ] && kill $(cat "$PID_FILE") 2>/dev/null
    rm -f "$PID_FILE"
    [ -f "/tmp/nautilus_payload.pid" ] && kill $(cat "/tmp/nautilus_payload.pid") 2>/dev/null
    rm -f "/tmp/nautilus_payload.pid"
    [ "$TTYD_STARTED" = "1" ] && killall ttyd 2>/dev/null
    rm -f /tmp/nautilus_wrapper_*.sh
    rm -f /tmp/nautilus_fifo_*
    rm -f /tmp/nautilus_response
    rm -f /tmp/nautilus_output.log
    rm -f /tmp/nautilus_cache.json
    rm -f /tmp/nautilus_auth_session
    LOG "cyan" "Nautilus stopped."
}
trap cleanup EXIT INT TERM

[ ! -f "$WEB_DIR/index.html" ] && { LOG "red" "Files not found!"; exit 1; }
chmod -R 755 "$WEB_DIR" 2>/dev/null
chmod +x "$SCRIPT_DIR/build_cache.sh" 2>/dev/null
"$SCRIPT_DIR/build_cache.sh" >/dev/null 2>&1
[ -f "$PID_FILE" ] && kill $(cat "$PID_FILE") 2>/dev/null
rm -f "$PID_FILE"
uhttpd -f -p "$PORT" -h "$WEB_DIR" -c /cgi-bin -T 60 &
echo $! > "$PID_FILE"
sleep 1

PAGER_IP=$(get_pager_ip)
if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    LOG "green" "http://$PAGER_IP:$PORT"
    LOG ""
    LOG "magenta" "Press B to stop"
    while true; do
        BUTTON=$(WAIT_FOR_INPUT)
        if [ "$BUTTON" = "B" ] || [ "$BUTTON" = "Escape" ]; then
            break
        fi
    done
else
    LOG "red" "Failed to start uhttpd!"
    exit 1
fi
