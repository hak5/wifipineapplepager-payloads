#!/bin/bash
#
# Title: WiFi Guppy
# Description: Displays Wi-Fi channel usage and relative busyness
# Author: JustSomeTrout (Trout / troot.)
# Version: 1.0
# Firmware: Developed for Firmware version 1.0.4
#
# The Guppy: A tiny explorer of the RF reef.
# Drifting through channels, counting who lives where.
# Bubbles mean busy waters.
# Silence means calm seas.
#
# Notes:
# - Aggregates AP presence per channel
# - Provides a visual RF congestion snapshot
# - WiFi Guppy shows channel load
#

TMP_FILE="/tmp/wifi_guppy_scan.txt"
CHANNEL_FILE_2G="/tmp/wifi_guppy_2g.txt"
CHANNEL_FILE_5G="/tmp/wifi_guppy_5g.txt"
CHANNEL_FILE_6G="/tmp/wifi_guppy_6g.txt"
CREATED_IFACE=0

cleanup() {
    rm -f "$TMP_FILE" "$CHANNEL_FILE_2G" "$CHANNEL_FILE_5G" "$CHANNEL_FILE_6G"
    [ "$CREATED_IFACE" = "1" ] && iw dev wlan1cli del 2>/dev/null
}
trap cleanup EXIT

title() {
    LOG "cyan" "==========="
    LOG "cyan" "WiFi GUPPY"
    LOG "cyan" "==========="
}

make_bar() {
    local count=$1
    local max=10
    local bar=""
    local i=0
    [ "$count" -gt "$max" ] && count=$max
    while [ $i -lt $count ]; do
        bar="${bar}█"
        i=$((i + 1))
    done
    echo "$bar"
}

title
LOG ""
LOG "green" "Guppy is swimming..."
LOG ""

if ! iw dev wlan1cli info >/dev/null 2>&1; then
    iw phy phy1 interface add wlan1cli type managed 2>/dev/null
    CREATED_IFACE=1
fi
ip link set wlan1cli up 2>/dev/null
sleep 1
iwinfo wlan1cli scan 2>/dev/null > "$TMP_FILE"

if [ ! -s "$TMP_FILE" ]; then
    LOG "red" "No scan data"
    LOG "yellow" "Are interfaces up?"
    exit 1
fi

LOG ""
LOG "green" "Guppy doing math..."
LOG ""

grep -E "Band:.*Channel:" "$TMP_FILE" | while read -r line; do
    BAND=$(echo "$line" | sed 's/.*Band: \([0-9.]*\) GHz.*/\1/')
    CH=$(echo "$line" | sed 's/.*Channel: \([0-9]*\).*/\1/')
    if [ "$BAND" = "2.4" ]; then
        echo "$CH" >> "$CHANNEL_FILE_2G"
    elif [ "$BAND" = "5" ]; then
        echo "$CH" >> "$CHANNEL_FILE_5G"
    elif [ "$BAND" = "6" ]; then
        echo "$CH" >> "$CHANNEL_FILE_6G"
    fi
done

show_band() {
    local band_name=$1
    local band_file=$2

    if [ -s "$band_file" ]; then
        LOG "cyan" "=== $band_name ==="
        sort -n "$band_file" | uniq -c | while read -r COUNT CH; do
            BAR_GRAPH=$(make_bar "$COUNT")
            if [ "$COUNT" -le 3 ]; then
                COLOR="green"
            elif [ "$COUNT" -le 7 ]; then
                COLOR="yellow"
            else
                COLOR="red"
            fi
            if [ "$CH" -lt 10 ]; then
                LOG "$COLOR" "Ch   $CH $BAR_GRAPH ($COUNT)"
            elif [ "$CH" -lt 100 ]; then
                LOG "$COLOR" "Ch  $CH $BAR_GRAPH ($COUNT)"
            else
                LOG "$COLOR" "Ch $CH $BAR_GRAPH ($COUNT)"
            fi
            LOG ""
        done
    fi
}

if [ ! -s "$CHANNEL_FILE_2G" ] && [ ! -s "$CHANNEL_FILE_5G" ] && [ ! -s "$CHANNEL_FILE_6G" ]; then
    LOG "red" "No channels detected"
    LOG "yellow" "Guppy found empty waters"
    exit 1
fi

show_band "2.4 GHz" "$CHANNEL_FILE_2G"
show_band "5 GHz" "$CHANNEL_FILE_5G"
show_band "6 GHz" "$CHANNEL_FILE_6G"

LOG ""
LOG "cyan" "*WiFi Guppy swims away*"
LOG ""