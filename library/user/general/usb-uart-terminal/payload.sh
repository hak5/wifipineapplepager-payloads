#!/bin/bash
# Title:       USB UART Terminal
# Description:  Read and display serial output from a USB UART adapter
# Author:       Samxplogs - https://www.youtube.com/@samxplogs
# Version:      1.1
# Category:     General
# Net Mode:     OFF
#
# LED State Descriptions
# Cyan Solid    - Serial terminal active
# Red Blink     - No USB serial device found
# Yellow Solid  - Awaiting baud rate selection

INPUT="/dev/input/event0"

# ── Detect USB serial device ────────────────────────────────────────
# Dynamically scan all ttyUSB* and ttyACM* devices
# Skip internal CH347F (VID 1A86 PID 55DE = Pager's SPI/GPIO bridge)
DEVICE=""
for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [ -c "$dev" ] || continue
    base=$(basename "$dev")
    sysdev="/sys/class/tty/${base}/device/uevent"
    # Skip internal CH347F
    if [ -f "$sysdev" ] && grep -q "1a86/55de" "$sysdev" 2>/dev/null; then
        continue
    fi
    DEVICE="$dev"
    break
done

if [ -z "$DEVICE" ]; then
    LED red blink
    LOG red "No external serial device found"
    LOG white "Devices present:"
    for dev in /dev/ttyUSB* /dev/ttyACM*; do
        [ -c "$dev" ] || continue
        base=$(basename "$dev")
        prod=""
        [ -f "/sys/class/tty/${base}/device/uevent" ] && \
            prod=$(grep PRODUCT "/sys/class/tty/${base}/device/uevent" 2>/dev/null)
        LOG white "  $dev ($prod)"
    done
    ERROR_DIALOG "No USB serial device found.\nConnect a USB UART adapter and retry."
    exit 1
fi

LOG green "Detected: $DEVICE"
# Show device info
base=$(basename "$DEVICE")
prod=""
[ -f "/sys/class/tty/${base}/device/uevent" ] && \
    prod=$(grep PRODUCT "/sys/class/tty/${base}/device/uevent" 2>/dev/null | cut -d= -f2)
[ -n "$prod" ] && LOG white "  USB ID: $prod"

# ── Baud rate selection ─────────────────────────────────────────────
LED yellow solid

BAUD_RATES=(9600 19200 38400 57600 115200 230400 460800 921600)
IDX=4  # Default: 115200

LOG ""
LOG "Select baud rate:"
LOG "  UP/DOWN  change"
LOG "  A        confirm"
LOG "  B        cancel"
LOG ""
LOG yellow ">> ${BAUD_RATES[$IDX]} <<"

while true; do
    resp=$(WAIT_FOR_INPUT)
    case "$resp" in
        UP)
            if [ $IDX -lt $((${#BAUD_RATES[@]} - 1)) ]; then
                IDX=$((IDX + 1))
            fi
            LOG yellow ">> ${BAUD_RATES[$IDX]} <<"
            ;;
        DOWN)
            if [ $IDX -gt 0 ]; then
                IDX=$((IDX - 1))
            fi
            LOG yellow ">> ${BAUD_RATES[$IDX]} <<"
            ;;
        A)
            break
            ;;
        B)
            LOG "Cancelled."
            exit 0
            ;;
    esac
done

BAUD=${BAUD_RATES[$IDX]}
LOG green "Baud: $BAUD"

# ── Configure serial port ──────────────────────────────────────────
# raw for proper serial handling, min 0 time 2 → non-blocking reads (0.2s timeout)
stty -F "$DEVICE" "$BAUD" cs8 -cstopb -parenb raw -echo min 0 time 2 2>/dev/null
if [ $? -ne 0 ]; then
    LED red blink
    ERROR_DIALOG "Failed to configure\n$DEVICE @ $BAUD baud"
    exit 1
fi

# ── Open persistent file descriptor ───────────────────────────────
# Keeps the serial port open for the entire session.
# Avoids re-opening on each read (which can reset DTR and lose data).
exec 3< "$DEVICE"

# ── Cleanup handler ────────────────────────────────────────────────
cleanup() {
    exec 3<&- 2>/dev/null
    dd if="$INPUT" of=/dev/null bs=16 count=200 iflag=nonblock 2>/dev/null
    LED off
    LOG cyan "--- Terminal closed ---"
}
trap cleanup EXIT INT TERM

# ── Start terminal ──────────────────────────────────────────────────
LED cyan solid
LOG cyan "--- UART Terminal ---"
LOG cyan "$DEVICE @ $BAUD 8N1"
LOG ""
LOG "  B = exit"
LOG ""

# ── Single-threaded main loop ───────────────────────────────────────
# Reads serial data via persistent fd 3 and polls D-pad in the same loop.
# No background subshell — LOG works reliably from main thread only.

LINEBUF=""

while true; do
    # Poll D-pad for B button (non-blocking, 20ms timeout)
    RAW=$(timeout 0.02 dd if="$INPUT" bs=16 count=1 2>/dev/null \
        | hexdump -e '16/1 "%02x "' 2>/dev/null)
    if [ -n "$RAW" ]; then
        TYPE=$(echo "$RAW" | cut -d' ' -f9)
        CODE=$(echo "$RAW" | cut -d' ' -f11,12)
        VALUE=$(echo "$RAW" | cut -d' ' -f13)
        if [ "$TYPE" = "01" ] && [ "$VALUE" = "01" ] && [ "$CODE" = "31 01" ]; then
            break
        fi
    fi

    # Check device still exists
    if [ ! -c "$DEVICE" ]; then
        LOG red "Device disconnected!"
        break
    fi

    # Read serial data from persistent fd 3 (stty min 0 time 2 → 0.2s timeout)
    chunk=$(dd bs=256 count=1 <&3 2>/dev/null | tr -d '\0')
    if [ -n "$chunk" ]; then
        LINEBUF="${LINEBUF}${chunk}"
        # Process complete lines (CR or LF terminated)
        while true; do
            case "$LINEBUF" in
                *$'\n'*)
                    line="${LINEBUF%%$'\n'*}"
                    LINEBUF="${LINEBUF#*$'\n'}"
                    line="${line%$'\r'}"
                    LOG "$line"
                    ;;
                *$'\r'*)
                    line="${LINEBUF%%$'\r'*}"
                    LINEBUF="${LINEBUF#*$'\r'}"
                    LOG "$line"
                    ;;
                *)
                    break
                    ;;
            esac
        done
        # Flush if buffer gets too long without line endings
        if [ ${#LINEBUF} -ge 80 ]; then
            LOG "$LINEBUF"
            LINEBUF=""
        fi
    fi
done
