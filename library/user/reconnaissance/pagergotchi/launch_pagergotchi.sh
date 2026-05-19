#!/bin/bash
# Title: Pagergotchi
# Direct Pagergotchi launcher — no pineapplepager needed
# Used for handoff from Bjorn (or any payload) to Pagergotchi
#
# Bjorn can call this with: /bin/sh /root/payloads/user/reconnaissance/pagergotchi/launch_pagergotchi.sh
# Exit code 42 from Pagergotchi means "switch to Bjorn"

PAYLOAD_DIR="/root/payloads/user/reconnaissance/pagergotchi"

if [ ! -d "$PAYLOAD_DIR/pwnagotchi_port" ]; then
    echo "Pagergotchi not found at $PAYLOAD_DIR"
    exit 1
fi

# Pagergotchi environment
export PATH="/mmc/usr/bin:$PAYLOAD_DIR/bin:$PATH"
export PYTHONPATH="$PAYLOAD_DIR/lib:$PAYLOAD_DIR:$PYTHONPATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:$PAYLOAD_DIR/lib:$LD_LIBRARY_PATH"

# Setup pineapd for handshake capture (if not already running)
if ! pgrep -x pineapd >/dev/null 2>&1; then
    /usr/sbin/pineapd \
        --recon=true \
        --reconpath /root/recon/ \
        --reconname pager \
        --handshakepath /root/loot/handshakes/ \
        --handshakes=true \
        --partialhandshakes=true \
        --interface wlan1mon \
        --band wlan1mon:2,5 \
        --type wlan1mon:max \
        --hop wlan1mon:fast \
        --primary wlan1mon \
        --inject wlan1mon &
    sleep 2
fi

cd "$PAYLOAD_DIR"
python3 run_pagergotchi.py
