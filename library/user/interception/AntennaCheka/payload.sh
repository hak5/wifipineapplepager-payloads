#!/bin/bash
# AntennaCheka v2 – Pager Visual Antenna Benchmark
#Author - Notorious Squirrel

set -u

# ----------------------------
# Hak5-style helpers (like Device Hunter)
# ----------------------------
RINGTONE() { true; }
VIBRATE()  { true; }
HAK5_API_POST() { true; }

# Try to load Hak5 commands (optional)
if [ -f /lib/hak5/commands.sh ]; then
  # shellcheck source=/lib/hak5/commands.sh
  . /lib/hak5/commands.sh 2>/dev/null || true
fi

# Only define LOG/TITLE if Hak5 helpers didn’t
command -v TITLE >/dev/null 2>&1 || TITLE() { echo "=== $* ==="; }
command -v LOG   >/dev/null 2>&1 || LOG()   { echo "[AC] $*"; }

# Basic dependency / interface checker
need_cmd() { command -v "$1" >/dev/null 2>&1; }

check_env() {
    local ok=1

    for c in iw tcpdump awk grep; do
        if ! need_cmd "$c"; then
            LOG "Missing required command: $c"
            ok=0
        fi
    done

    # Check interfaces exist (best-effort; skip on error)
    if ! iw dev "$INBUILT" info >/dev/null 2>&1; then
        LOG "Inbuilt interface '$INBUILT' not found"
        ok=0
    fi
    if ! iw dev "$USB" info >/dev/null 2>&1; then
        LOG "USB interface '$USB' not found"
        ok=0
    fi

    if [ "$ok" -ne 1 ]; then
        LOG "Environment not fully ready (missing commands or interfaces)"
        LOG "Continuing anyway; results may be empty"
    fi
}

# ----------------------------
# PHY auto-detection
# ----------------------------

detect_phys() {
    INTERNAL_MON=""
    USB_MON=""
    INTERNAL_PHY=""
    USB_PHY=""

    # Enumerate monitor interfaces
    for iface in $(iw dev | awk '$1=="Interface"{print $2}'); do
        type=$(iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}')
        phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')

        [ "$type" != "monitor" ] && continue

        case "$iface" in
            wlan0*|wlan1*)
                # Pager internal radios
                if [ -z "$INTERNAL_MON" ]; then
                    INTERNAL_MON="$iface"
                    INTERNAL_PHY="$phy"
                fi
                ;;
            *)
                # Anything else is USB
                if [ -z "$USB_MON" ]; then
                    USB_MON="$iface"
                    USB_PHY="$phy"
                fi
                ;;
        esac
    done

    # Try to create USB monitor if missing
    if [ -z "$USB_MON" ]; then
        for phy_path in /sys/class/ieee80211/*; do
            p=$(basename "$phy_path")

            # Skip internal PHYs
            [ "$p" = "$INTERNAL_PHY" ] && continue

            IFACE="wlan_usb_mon"
            iw phy "$p" interface add "$IFACE" type monitor 2>/dev/null || continue
            ip link set "$IFACE" up 2>/dev/null || continue

            USB_MON="$IFACE"
            USB_PHY="$p"
            break
        done
    fi

    # Final validation
    if [ -z "$INTERNAL_MON" ] || [ -z "$USB_MON" ]; then
        LOG "Failed to auto-detect antennas"
        LOG "Internal: ${INTERNAL_MON:-none}"
        LOG "USB: ${USB_MON:-none}"
        exit 1
    fi

    LOG "Internal antenna: $INTERNAL_MON ($INTERNAL_PHY)"
    LOG "USB antenna:      $USB_MON ($USB_PHY)"
}



# ----------------------------
# Config
# ----------------------------
CHANNEL=8
CHANNELS=(8 10 36)
PKTS=50
RUNS=3
BEST="nodata"

# Use /root/loot on Pager (root), but a local loot dir when running as a normal user
if [ "$(id -u)" -eq 0 ]; then
    LOOT="/root/loot/antennacheka"
else
    LOOT="$PWD/loot"
fi
TMP="/tmp/antennacheka"

mkdir -p "$LOOT" "$TMP"

# ----------------------------
# Capture RSSI + packet count
# ----------------------------
capture() {
    IFACE="$1"
    OUT="$2"

    iw dev "$IFACE" set channel "$CHANNEL" 2>/dev/null
    sleep 1

    tcpdump -i "$IFACE" -e -c "$PKTS" 2>/dev/null > "$OUT"

    # Count frames that include an RSSI field like "-54dBm signal"
    PACKETS=$(grep -c "dBm signal" "$OUT" 2>/dev/null || echo 0)

    # Extract numeric RSSI values from fields like "-54dBm" and average them
    RSSI=$(grep "dBm signal" "$OUT" | \
           grep -oE ' -[0-9]+dBm' | sed 's/ //g; s/dBm//' | \
           awk '{s+=$1;c++} END {if(c>0) print s/c; else print "nodata"}')

    # Fallback: if we saw packets but somehow didn't match "dBm signal",
    # try any "-XXdBm" token so we still get a usable RSSI.
    if [ "$RSSI" = "nodata" ] && [ "$PACKETS" -gt 0 ]; then
        RSSI=$(grep -oE ' -[0-9]+dBm' "$OUT" | sed 's/ //g; s/dBm//' | \
               awk '{s+=$1;c++} END {if(c>0) print s/c; else print "nodata"}')
    fi

    echo "$RSSI,$PACKETS"
}

# ----------------------------
# Run benchmark
# ----------------------------
run_test() {
    clear 2>/dev/null || printf '\n'
    TITLE "AntennaCheka"
    LOG "Channel: $CHANNEL"
    LOG "Runs: $RUNS"
    LOG ""

    IN_TOTAL=0
    USB_TOTAL=0
    IN_COUNT=0
    USB_COUNT=0
    IN_PKT_TOTAL=0
    USB_PKT_TOTAL=0

    for i in $(seq 1 $RUNS); do
        LOG "Run $i / $RUNS"

        for ch in "${CHANNELS[@]}"; do
            CHANNEL="$ch"
            LOG " Inbuilt antenna on channel $CHANNEL..."
            IN=$(capture "$INBUILT" "$TMP/in_${i}_ch${CHANNEL}.cap")
            IN_RSSI=$(echo "$IN" | cut -d, -f1)
            IN_PKT=$(echo "$IN" | cut -d, -f2)
            IN_PKT=${IN_PKT:-0}

            LOG "  Packets (inbuilt, ch $CHANNEL): $IN_PKT"

            IN_PKT_TOTAL=$((IN_PKT_TOTAL + IN_PKT))

            if [ "$IN_RSSI" != "nodata" ]; then
                IN_TOTAL=$(awk -v total="$IN_TOTAL" -v rssi="$IN_RSSI" 'BEGIN{print total + rssi}')
                IN_COUNT=$((IN_COUNT+1))
            fi

            LOG " USB antenna on channel $CHANNEL..."
            USBR=$(capture "$USB" "$TMP/usb_${i}_ch${CHANNEL}.cap")
            USB_RSSI=$(echo "$USBR" | cut -d, -f1)
            USB_PKT=$(echo "$USBR" | cut -d, -f2)
            USB_PKT=${USB_PKT:-0}

            LOG "  Packets (USB, ch $CHANNEL): $USB_PKT"

            USB_PKT_TOTAL=$((USB_PKT_TOTAL + USB_PKT))

            if [ "$USB_RSSI" != "nodata" ]; then
                USB_TOTAL=$(awk -v total="$USB_TOTAL" -v rssi="$USB_RSSI" 'BEGIN{print total + rssi}')
                USB_COUNT=$((USB_COUNT+1))
            fi

            sleep 1
        done
    done

    LOG ""
    LOG "Final Results:"

    if [ $IN_COUNT -gt 0 ]; then
        IN_AVG=$(awk -v total="$IN_TOTAL" -v count="$IN_COUNT" 'BEGIN{print total / count}')
        LOG " Inbuilt avg RSSI: $IN_AVG dBm"
    else
        IN_AVG="nodata"
        LOG " Inbuilt avg RSSI: no data"
    fi

    if [ $USB_COUNT -gt 0 ]; then
        USB_AVG=$(awk -v total="$USB_TOTAL" -v count="$USB_COUNT" 'BEGIN{print total / count}')
        LOG " USB avg RSSI:     $USB_AVG dBm"
    else
        USB_AVG="nodata"
        LOG " USB avg RSSI: no data"
    fi

    # Decide BEST antenna
LOG ""

    if [[ "$IN_AVG" != "nodata" && "$USB_AVG" != "nodata" ]]; then
        DIFF=$(awk "BEGIN{print $USB_AVG - $IN_AVG}")

        if awk "BEGIN{exit !($DIFF > 0)}"; then
        BEST="USB"
     else
         BEST="Inbuilt"
     fi

        LOG " Best antenna: $BEST"
        LOG " RSSI difference: ${DIFF} dB"

    elif [[ "$IN_AVG" != "nodata" ]]; then
        BEST="Inbuilt"
        LOG " Best antenna: Inbuilt (USB returned no usable data)"

    elif [[ "$USB_AVG" != "nodata" ]]; then
        BEST="USB"
        LOG " Best antenna: USB (Inbuilt returned no usable data)"

    else
        BEST="nodata"
        LOG " No usable RSSI data captured from either antenna"
    fi

    LOG ""
    LOG " Inbuilt total packets: $IN_PKT_TOTAL"
    LOG " USB total packets:     $USB_PKT_TOTAL"
    LOG " Best antenna: $BEST"

    # ----------------------------
    # Save loot
    # ----------------------------
    TS=$(date +"%Y%m%d_%H%M%S")
    {
        echo "Channel: $CHANNEL"
        echo "Runs: $RUNS"
        echo "Inbuilt avg: $IN_AVG"
        echo "USB avg: $USB_AVG"
        [ "$BEST" != "nodata" ] && echo "Best: $BEST" || echo "Best: none"
    } > "$LOOT/result_$TS.txt"

    LOG ""
    LOG "Results saved to loot: $LOOT/result_$TS.txt"
    sleep 10
}

# ----------------------------
# Entry point
# ----------------------------
INTERNAL_MON=""
USB_MON=""
INTERNAL_PHY=""
USB_PHY=""

detect_phys

INBUILT="$INTERNAL_MON"
USB="$USB_MON"

check_env

TITLE "AntennaCheka"
run_test
exit 0



