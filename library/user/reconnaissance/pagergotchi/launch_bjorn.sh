#!/bin/bash
# Title: Bjorn
# Requires: /root/payloads/user/reconnaissance/pager_bjorn
# Direct Bjorn launcher — skips ducky-script menu, no pineapplepager needed
# Used for handoff from pagergotchi (or any payload) to Bjorn

BJORN_DIR="/root/payloads/user/reconnaissance/pager_bjorn"

if [ ! -d "$BJORN_DIR" ]; then
    echo "Bjorn not found at $BJORN_DIR"
    exit 1
fi

# Bjorn environment
export PATH="/mmc/usr/bin:$PATH"
export PYTHONPATH="$BJORN_DIR/lib:$BJORN_DIR:$PYTHONPATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:$BJORN_DIR/lib:$BJORN_DIR:$LD_LIBRARY_PATH"
export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1

# Auto-detect network interface (first non-loopback with an IP)
SELECTED_INTERFACE=""
SELECTED_IP=""
while IFS= read -r line; do
    if [[ "$line" =~ ^[0-9]+:\ ([^:]+): ]]; then
        CURRENT_IFACE="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ inet\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        IP="${BASH_REMATCH[1]}"
        if [[ "$IP" != "127.0.0.1" && -n "$CURRENT_IFACE" ]]; then
            if [ -z "$SELECTED_INTERFACE" ]; then
                SELECTED_INTERFACE="$CURRENT_IFACE"
                SELECTED_IP="$IP"
            fi
        fi
    fi
done < <(ip addr 2>/dev/null)

export BJORN_INTERFACE="${SELECTED_INTERFACE:-br-lan}"
export BJORN_IP="${SELECTED_IP:-172.16.52.1}"

cd "$BJORN_DIR"
python3 Bjorn.py 2>/tmp/bjorn_launch.log
