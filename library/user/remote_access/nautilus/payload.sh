#!/bin/bash
#
# Title: Nautilus
# Description: Web-based payload launcher with live console output and GitHub integration
# Author: JustSomeTrout (Trout / troot.)
# Co-Author: Z3r0L1nk
# Version: 1.8.5
# Firmware: Developed for Firmware version 1.0.6
#
# Runs uhttpd with CGI to browse and execute payloads from your browser.
# Now with GitHub integration - run payloads directly from the official repo or PRs!
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$SCRIPT_DIR/www"
PORT=8888
PID_FILE="/tmp/nautilus.pid"
INIT_SCRIPT="/etc/init.d/nautilus"

# Check if user confirmed (works with old and new firmware)
user_confirmed() {
    [ "$1" = "true" ] || [ "$1" = "$DUCKYSCRIPT_USER_CONFIRMED" ]
}

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
LOG "v1.8.5"
LOG ""
LOG "yellow" '|   ~ Web Payload Launcher ~    |'
LOG ""

if [ -f "$INIT_SCRIPT" ] && "$INIT_SCRIPT" running 2>/dev/null; then
    LOG "green" "Nautilus service is running"
    PAGER_IP=$(get_pager_ip)
    LOG "green" "http://$PAGER_IP:$PORT"
    LOG ""
    resp=$(CONFIRMATION_DIALOG "Stop service?")
    if user_confirmed "$resp"; then
        LOG "yellow" "Stopping service..."
        "$INIT_SCRIPT" stop
        "$INIT_SCRIPT" disable
        rm -f "$INIT_SCRIPT"
        LOG "cyan" "Service stopped"
    fi
    exit 0
fi

AUTO_MODE=$(PAYLOAD_GET_CONFIG nautilus auto_mode 2>/dev/null)
RUN_MODE=$(PAYLOAD_GET_CONFIG nautilus run_mode 2>/dev/null)

if [ "$AUTO_MODE" = "true" ]; then
    if [ "$RUN_MODE" = "background" ]; then
        resp="true"
        LOG "cyan" "Auto-starting background mode..."
    else
        resp=""
        LOG "cyan" "Auto-starting foreground mode..."
    fi
else
    resp=$(CONFIRMATION_DIALOG "Run as background service?")
fi

if user_confirmed "$resp"; then
    LOG "cyan" "Starting as service..."

    if ! command -v uhttpd >/dev/null 2>&1; then
        LOG "yellow" "uhttpd required (~28KB)"
        resp=$(CONFIRMATION_DIALOG "Install uhttpd?")
        if user_confirmed "$resp"; then
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
        resp=$(CONFIRMATION_DIALOG "Install ttyd? (~150KB)")
        if user_confirmed "$resp"; then
            LOG "cyan" "Installing ttyd..."
            opkg update >/dev/null 2>&1
            opkg install ttyd >/dev/null 2>&1
            if command -v ttyd >/dev/null 2>&1; then
                /etc/init.d/ttyd disable 2>/dev/null
                LOG "green" "ttyd installed"
            else
                LOG "yellow" "Shell feature disabled"
            fi
        else
            LOG "yellow" "Shell feature disabled"
        fi
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        resp=$(CONFIRMATION_DIALOG "Install python3? (~1MB, needed for Virtual Pager)")
        if user_confirmed "$resp"; then
            LOG "cyan" "Installing python3..."
            opkg update >/dev/null 2>&1
            opkg install python3-light >/dev/null 2>&1
            if command -v python3 >/dev/null 2>&1; then
                LOG "green" "python3 installed"
            else
                LOG "yellow" "Virtual Pager disabled"
            fi
        else
            LOG "yellow" "Virtual Pager disabled"
        fi
    fi

    [ ! -f "$WEB_DIR/index.html" ] && { LOG "red" "Files not found!"; exit 1; }

    cp "$SCRIPT_DIR/nautilus.init" "$INIT_SCRIPT"
    chmod +x "$INIT_SCRIPT"
    "$INIT_SCRIPT" enable
    "$INIT_SCRIPT" start

    sleep 1
    
    # Start Proxy
    if command -v python3 >/dev/null 2>&1; then
        python3 "$SCRIPT_DIR/proxy.py" >/dev/null 2>&1 &
        echo $! > "/tmp/nautilus_proxy.pid"
        LOG "cyan" "Proxy started on port 8890"
    else
        LOG "red" "Python3 missing - Proxy failed"
    fi
    
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
    if user_confirmed "$resp"; then
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
    resp=$(CONFIRMATION_DIALOG "Install ttyd? (~150KB)")
    if user_confirmed "$resp"; then
        LOG "cyan" "Installing ttyd..."
        opkg update >/dev/null 2>&1
        opkg install ttyd >/dev/null 2>&1
        if command -v ttyd >/dev/null 2>&1; then
            /etc/init.d/ttyd disable 2>/dev/null
            LOG "green" "ttyd installed"
        else
            LOG "yellow" "Shell feature disabled"
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
    [ -f "/tmp/nautilus_proxy.pid" ] && kill $(cat "/tmp/nautilus_proxy.pid") 2>/dev/null
    rm -f "/tmp/nautilus_proxy.pid"
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
uhttpd -f -p "$PORT" -h "$WEB_DIR" -c /cgi-bin -t 300 -T 300 &
echo $! > "$PID_FILE"
echo $! > "$PID_FILE"
sleep 1

# Start Proxy (Foreground Mode)
if command -v python3 >/dev/null 2>&1; then
    python3 "$SCRIPT_DIR/proxy.py" >/dev/null 2>&1 &
    echo $! > "/tmp/nautilus_proxy.pid"
    LOG "cyan" "Proxy started on port 8890"
fi

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
