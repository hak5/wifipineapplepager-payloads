#!/bin/bash
# Title: PAGERCTL Demo
# Description: Hardware control toolkit - display, buttons, LEDs, buzzer, vibration
# Author: brAinphreAk
# Version: 1.0
# Category: Utilities

PAYLOAD_DIR="/root/payloads/user/utilities/PAGERCTL"

#
# Setup paths for Python and shared library
# MMC paths needed when python3 installed with opkg -d mmc
#
export PATH="/mmc/usr/bin:$PATH"
export PYTHONPATH="$PAYLOAD_DIR:$PYTHONPATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:$PAYLOAD_DIR:$LD_LIBRARY_PATH"

#
# Check for Python3 + ctypes (REQUIRED)
#
check_python() {
    NEED_PYTHON=false
    NEED_CTYPES=false

    if ! command -v python3 >/dev/null 2>&1; then
        NEED_PYTHON=true
        NEED_CTYPES=true
    elif ! python3 -c "import ctypes" 2>/dev/null; then
        NEED_CTYPES=true
    fi

    if [ "$NEED_PYTHON" = true ] || [ "$NEED_CTYPES" = true ]; then
        LOG ""
        LOG "red" "=== PYTHON3 REQUIRED ==="
        LOG ""
        if [ "$NEED_PYTHON" = true ]; then
            LOG "Python3 is not installed."
        else
            LOG "Python3-ctypes is not installed."
        fi
        LOG ""
        LOG "pagerctl uses Python + libpagerctl.so for"
        LOG "smooth, flicker-free graphics."
        LOG ""
        LOG "green" "GREEN = Install Python3 (requires internet)"
        LOG "red" "RED   = Exit"
        LOG ""

        while true; do
            BUTTON=$(WAIT_FOR_INPUT 2>/dev/null)
            case "$BUTTON" in
                "GREEN"|"A")
                    LOG ""
                    LOG "Updating package lists..."
                    opkg update 2>&1 | while IFS= read -r line; do LOG "  $line"; done
                    LOG ""
                    LOG "Installing Python3 + ctypes to MMC..."
                    opkg -d mmc install python3 python3-ctypes 2>&1 | while IFS= read -r line; do LOG "  $line"; done
                    LOG ""
                    if command -v python3 >/dev/null 2>&1 && python3 -c "import ctypes" 2>/dev/null; then
                        LOG "green" "Python3 installed successfully!"
                        sleep 1
                        return 0
                    else
                        LOG "red" "Failed to install Python3"
                        LOG "Check internet connection."
                        sleep 2
                        return 1
                    fi
                    ;;
                "RED"|"B")
                    LOG "Exiting."
                    exit 0
                    ;;
            esac
        done
    fi
    return 0
}

# ============================================================
# CLEANUP
# ============================================================

cleanup() {
    # Restart pager service if not running
    if ! pgrep -x pineapple >/dev/null; then
        /etc/init.d/pineapplepager start 2>/dev/null
    fi
}

# Ensure pager service restarts on exit
trap cleanup EXIT

# ============================================================
# MAIN
# ============================================================

# Check Python first (required)
check_python || exit 1

# Check if libpagerctl.so exists
if [ ! -f "$PAYLOAD_DIR/libpagerctl.so" ]; then
    LOG ""
    LOG "red" "ERROR: libpagerctl.so not found!"
    LOG ""
    LOG "Build and deploy from your computer:"
    LOG "  cd pagerctl && make remote-build && make deploy"
    LOG ""
    LOG "Press any button to exit..."
    WAIT_FOR_INPUT >/dev/null 2>&1
    exit 1
fi

# Show menu
LOG ""
LOG "green" "=========================================="
LOG "green" "             PAGERCTL"
LOG "green" "    Pager Hardware Control Toolkit"
LOG "green" "=========================================="
LOG ""
LOG "Hardware demo: Display, LEDs, Audio, TTF, Buttons"
LOG ""
LOG "green" "  GREEN = Python Demo"
LOG "  UP    = C Demo"
LOG "red" "  RED   = Exit"
LOG ""

# Wait for selection (single choice, then exit)
BUTTON=$(WAIT_FOR_INPUT 2>/dev/null)
case "$BUTTON" in
    "GREEN"|"A")
        LOG ""
        LOG "Running Python Demo..."
        /etc/init.d/pineapplepager stop 2>/dev/null
        sleep 0.3
        cd "$PAYLOAD_DIR"
        python3 examples/demo.py
        /etc/init.d/pineapplepager start 2>/dev/null
        ;;
    "UP")
        LOG ""
        LOG "Running C Demo..."
        /etc/init.d/pineapplepager stop 2>/dev/null
        sleep 0.3
        cd "$PAYLOAD_DIR"
        ./examples/demo
        /etc/init.d/pineapplepager start 2>/dev/null
        ;;
    "RED"|"B"|*)
        LOG ""
        LOG "Exiting."
        ;;
esac

exit 0
