#!/bin/bash
# Title:       Proxmark3 Controller
# Description: Detect and guide Proxmark3 RDV4 standalone operations —
#              LF/HF card reading, cloning, sniffing, and attacks
# Author:      Samxplogs - https://www.youtube.com/@samxplogs
# Version:     1.0
# Category:    General
# Net Mode:    OFF
#
# LED State Descriptions
# Cyan Solid    - PM3 connected, ready
# Green Blink   - Standalone mode active (waiting for PM3)
# Red Blink     - No PM3 detected / disconnected
# Yellow Solid  - Submenu navigation
#
# D-Pad LED
# Cyan          - Connected, idle
# Green         - Standalone operation in progress
# Yellow        - Submenu active
# Red           - PM3 disconnected
#
# Button Map (Main Menu)
# UP            - LF Operations (125 kHz)
# DOWN          - HF Operations (13.56 MHz)
# LEFT          - Quick Reference
# A             - Device Info
# B             - Exit

INPUT=/dev/input/event0
LOOT_DIR="/root/loot/proxmark"

# ══════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════

poll_button() {
    local data kc type val
    data=$(timeout 0.02 dd if=$INPUT bs=16 count=1 2>/dev/null \
         | hexdump -e '16/1 "%02x "' 2>/dev/null)
    [ -z "$data" ] && return 1
    type=$(echo "$data" | cut -d' ' -f9-10)
    val=$(echo "$data" | cut -d' ' -f13)
    kc=$(echo "$data" | cut -d' ' -f11-12)
    [ "$type" != "01 00" ] && return 1
    [ "$val" != "01" ] && return 1
    case "$kc" in
        "30 01") echo "A"     ;; "31 01") echo "B"     ;;
        "67 00") echo "UP"    ;; "68 00") echo "DOWN"  ;;
        "69 00") echo "LEFT"  ;; "6a 00") echo "RIGHT" ;;
        *)       return 1     ;;
    esac
    return 0
}

log_session() {
    [ -n "$SESSION_LOG" ] && echo "$1" >> "$SESSION_LOG"
}

# ══════════════════════════════════════════════════════════════════
#  DETECT PROXMARK3
# ══════════════════════════════════════════════════════════════════

detect_pm3() {
    PM3_DEV=""
    PM3_VID=""
    PM3_PID=""
    PM3_PROD=""
    PM3_MFR=""
    PM3_SERIAL=""
    PM3_SPEED=""
    PM3_POWER=""
    PM3_USBDIR=""

    for dev in /dev/ttyACM*; do
        [ -c "$dev" ] || continue
        local base sysdev
        base=$(basename "$dev")
        sysdev="/sys/class/tty/${base}/device"

        # Skip internal CH347F (Pager's SPI/GPIO bridge)
        if [ -f "${sysdev}/uevent" ] && grep -q "1a86/55de" "${sysdev}/uevent" 2>/dev/null; then
            continue
        fi

        # Walk up sysfs to find USB device node
        local usbdev=""
        for parent in "${sysdev}/../../.." "${sysdev}/../.."; do
            if [ -f "${parent}/idVendor" ]; then
                usbdev="$parent"
                break
            fi
        done

        if [ -n "$usbdev" ]; then
            PM3_VID=$(cat "${usbdev}/idVendor" 2>/dev/null | tr -d '\n')
            PM3_PID=$(cat "${usbdev}/idProduct" 2>/dev/null | tr -d '\n')
            PM3_PROD=$(cat "${usbdev}/product" 2>/dev/null | tr -d '\n')
            PM3_MFR=$(cat "${usbdev}/manufacturer" 2>/dev/null | tr -d '\n')
            PM3_SERIAL=$(cat "${usbdev}/serial" 2>/dev/null | tr -d '\n')
            PM3_SPEED=$(cat "${usbdev}/speed" 2>/dev/null | tr -d '\n')
            PM3_POWER=$(cat "${usbdev}/bMaxPower" 2>/dev/null | tr -d '\n')
            PM3_USBDIR=$(basename "$(cd "$usbdev" 2>/dev/null && pwd)")
        fi

        PM3_DEV="$dev"
        return 0
    done

    return 1
}

# ══════════════════════════════════════════════════════════════════
#  DEVICE INFO
# ══════════════════════════════════════════════════════════════════

show_device_info() {
    LOG ""
    LOG cyan "====== DEVICE ======"
    LOG green "${PM3_VID:-????}:${PM3_PID:-????}"
    [ -n "$PM3_MFR" ]    && LOG "Mfr:    $PM3_MFR"
    [ -n "$PM3_PROD" ]   && LOG "Prod:   $PM3_PROD"
    [ -n "$PM3_SERIAL" ] && LOG "S/N:    $PM3_SERIAL"
    LOG "Port:   $PM3_DEV"
    [ -n "$PM3_SPEED" ]  && LOG "Speed:  ${PM3_SPEED} Mbps"
    [ -n "$PM3_POWER" ]  && LOG "Power:  $PM3_POWER"
    LOG ""

    # Interface enumeration
    if [ -n "$PM3_USBDIR" ]; then
        LOG cyan "=== INTERFACES ====="
        for iface in /sys/bus/usb/devices/${PM3_USBDIR}:*/bInterfaceClass; do
            [ -f "$iface" ] || continue
            local ifdir ifnum icls driver
            ifdir=$(dirname "$iface")
            ifnum=$(basename "$ifdir" | sed 's/.*\.//')
            icls=$(cat "$iface" 2>/dev/null | tr -d '\n')
            driver="(none)"
            [ -L "$ifdir/driver" ] && driver=$(basename "$(readlink "$ifdir/driver")")
            case "$icls" in
                02) LOG yellow "IF $ifnum: CDC Comms [$driver]" ;;
                0a) LOG yellow "IF $ifnum: CDC Data  [$driver]" ;;
                *)  LOG yellow "IF $ifnum: Class $icls [$driver]" ;;
            esac
        done
        LOG ""
    fi

    log_session "$(date +%H:%M:%S) Device info displayed"
}

# ══════════════════════════════════════════════════════════════════
#  STANDALONE MODE GUIDE
# ══════════════════════════════════════════════════════════════════

# Displays step-by-step guide, waits for A (done) or B (cancel)
run_guide() {
    local title="$1" color="$2"
    shift 2

    LOG ""
    LOG "$color" "== $title =="
    LOG ""

    while [ $# -gt 0 ]; do
        LOG "$1"
        shift
    done

    LOG ""
    LOG white "A = done  |  B = cancel"

    LED green blink
    DPADLED green

    log_session "$(date +%H:%M:%S) Started: $title"

    while true; do
        local btn
        btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            A)
                LOG green "[OK] $title"
                log_session "$(date +%H:%M:%S) Completed: $title"
                break
                ;;
            B)
                LOG yellow "[Cancelled]"
                log_session "$(date +%H:%M:%S) Cancelled: $title"
                break
                ;;
        esac
    done

    LED cyan solid
    DPADLED cyan
}

# ══════════════════════════════════════════════════════════════════
#  LF MENU (125 kHz)
# ══════════════════════════════════════════════════════════════════

menu_lf() {
    while true; do
        LOG ""
        LOG yellow "=== LF 125 kHz ==="
        LOG ""
        LOG "UP    Read EM4100"
        LOG "DOWN  Read HID Prox"
        LOG "LEFT  Clone to T5577"
        LOG "RIGHT Brute HID"
        LOG "A     Sniff LF"
        LOG "B     Back"

        LED yellow solid
        DPADLED yellow

        local btn
        btn=$(WAIT_FOR_INPUT)
        log_session "$(date +%H:%M:%S) LF menu: $btn"

        case "$btn" in
            UP)
                run_guide "Read EM4100" yellow \
                    "Standalone: LF_EM4100RSWB" \
                    "" \
                    "1. Hold PM3 button 2s" \
                    "   LED A steady = ready" \
                    "2. Present EM4100 card" \
                    "   to LF antenna (bottom)" \
                    "3. LED A flash = card read" \
                    "" \
                    "Short press = next mode:" \
                    "  LED B = Simulate" \
                    "  LED C = Write to T5577" \
                    "  LED D = Brute UID range" \
                    "" \
                    "Data stored in PM3 flash."
                ;;
            DOWN)
                run_guide "Read HID Prox" yellow \
                    "Standalone: LF_ICEHID" \
                    "" \
                    "1. Hold PM3 button 2s" \
                    "2. Present HID card to" \
                    "   LF antenna (bottom)" \
                    "3. LED flash = card read" \
                    "4. Data saved to flash" \
                    "" \
                    "Format: HID 26-bit" \
                    "Captures: Facility + Card #" \
                    "" \
                    "Retrieve with PM3 client."
                ;;
            LEFT)
                run_guide "Clone LF to T5577" yellow \
                    "Requires a previous read." \
                    "" \
                    "1. READ source card first" \
                    "2. Hold PM3 button to enter" \
                    "   write mode (LED C)" \
                    "3. Present blank T5577" \
                    "4. LED confirms write" \
                    "" \
                    "Supported: EM4100, HID," \
                    "Indala, AWID, IO Prox" \
                    "T5577 is rewritable."
                ;;
            RIGHT)
                run_guide "Brute Force HID" yellow \
                    "Standalone: LF_HIDBRUTE" \
                    "" \
                    "1. Hold PM3 button 2s" \
                    "2. PM3 cycles through UIDs" \
                    "3. Hold LF antenna near" \
                    "   target reader" \
                    "4. Short press = next range" \
                    "" \
                    "WARNING: Very slow." \
                    "Best with known facility" \
                    "code. May take hours."
                ;;
            A)
                run_guide "Sniff LF" yellow \
                    "Place PM3 near LF reader." \
                    "" \
                    "1. Hold PM3 button 2s" \
                    "2. Place between card and" \
                    "   legitimate reader" \
                    "3. Wait for transaction" \
                    "4. LED flash = data captured" \
                    "5. Short press = stop" \
                    "" \
                    "Captures raw LF modulation." \
                    "Retrieve with PM3 client."
                ;;
            B)
                return
                ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════
#  HF MENU (13.56 MHz)
# ══════════════════════════════════════════════════════════════════

menu_hf() {
    while true; do
        LOG ""
        LOG cyan "=== HF 13.56 MHz ==="
        LOG ""
        LOG "UP    Read MIFARE Classic"
        LOG "DOWN  Sniff ISO14443A"
        LOG "LEFT  Attack MIFARE (keys)"
        LOG "RIGHT Read iCLASS"
        LOG "A     Clone MIFARE"
        LOG "B     Back"

        LED yellow solid
        DPADLED yellow

        local btn
        btn=$(WAIT_FOR_INPUT)
        log_session "$(date +%H:%M:%S) HF menu: $btn"

        case "$btn" in
            UP)
                run_guide "Read MIFARE Classic" cyan \
                    "Standalone: HF_CRAFTBYTE" \
                    "" \
                    "1. Hold PM3 button 2s" \
                    "   LEDs cycle = ready" \
                    "2. Present MIFARE card" \
                    "   to HF antenna (top)" \
                    "3. LED A solid = UID read" \
                    "4. Auto-tries default keys" \
                    "   on all sectors" \
                    "" \
                    "Supports: 1K and 4K cards" \
                    "Keys: FFFFFFFFFFFF," \
                    "A0A1A2A3A4A5, defaults"
                ;;
            DOWN)
                run_guide "Sniff ISO14443A" cyan \
                    "Standalone: HF_14ASNIFF" \
                    "" \
                    "1. Hold PM3 button 2s" \
                    "2. Place PM3 between card" \
                    "   and legitimate reader" \
                    "3. Wait for transaction" \
                    "   LEDs flash = capturing" \
                    "4. Short press = stop" \
                    "" \
                    "Captures: UID, ATQA, SAK" \
                    "and full APDU exchange." \
                    "Retrieve with PM3 client."
                ;;
            LEFT)
                run_guide "Attack MIFARE Keys" cyan \
                    "Standalone: HF_COLIN" \
                    "" \
                    "1. Hold PM3 button 2s" \
                    "2. Present MIFARE card" \
                    "3. PM3 runs attacks:" \
                    "   - Dictionary (default keys)" \
                    "   - Darkside attack" \
                    "   - Nested attack" \
                    "4. LEDs show progress:" \
                    "   A=read B=attack" \
                    "   C=found D=dump" \
                    "" \
                    "Full dump saved to flash." \
                    "May take 1-5 minutes."
                ;;
            RIGHT)
                run_guide "Read iCLASS" cyan \
                    "Standalone: HF_ICECLASS" \
                    "" \
                    "1. Hold PM3 button 2s" \
                    "2. Present iCLASS card" \
                    "3. PM3 tries known keys" \
                    "   and default credentials" \
                    "4. LED = read success" \
                    "" \
                    "Supports: Standard iCLASS" \
                    "SE/SEOS needs more work." \
                    "Dump saved to flash."
                ;;
            A)
                run_guide "Clone MIFARE" cyan \
                    "Requires: Magic Gen1a card" \
                    "and a previous key attack." \
                    "" \
                    "1. First run Attack to get" \
                    "   sector keys + full dump" \
                    "2. Hold PM3 button 2s" \
                    "3. Enter write/clone mode" \
                    "4. Present Magic Gen1a card" \
                    "5. PM3 writes all sectors" \
                    "" \
                    "Gen1a = UID-writable card" \
                    "Gen2/CUID also supported."
                ;;
            B)
                return
                ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════
#  QUICK REFERENCE
# ══════════════════════════════════════════════════════════════════

show_reference() {
    LOG ""
    LOG cyan "=== QUICK REF ======"
    LOG ""
    LOG yellow "LF 125 kHz cards:"
    LOG "  EM4100  - basic access"
    LOG "  HID     - corporate access"
    LOG "  Indala  - older systems"
    LOG "  T5577   - writable blank"
    LOG "  AWID    - parking/access"
    LOG ""
    LOG cyan "HF 13.56 MHz cards:"
    LOG "  MIFARE Classic - transport"
    LOG "  MIFARE Ultra   - NFC tags"
    LOG "  DESFire        - modern/secure"
    LOG "  iCLASS         - HID corporate"
    LOG "  ISO15693       - inventory"
    LOG ""
    LOG green "PM3 RDV4 button:"
    LOG "  Hold 2s  = enter standalone"
    LOG "  Short    = cycle sub-mode"
    LOG "  Hold 2s  = exit standalone"
    LOG ""
    LOG green "Antennas:"
    LOG "  Bottom = LF (125 kHz)"
    LOG "  Top    = HF (13.56 MHz)"
    LOG ""
    LOG white "Press any button..."
    WAIT_FOR_INPUT > /dev/null
}

# ══════════════════════════════════════════════════════════════════
#  CHECK PM3 CONNECTION
# ══════════════════════════════════════════════════════════════════

check_pm3() {
    [ -c "$PM3_DEV" ] && return 0

    LED red blink
    DPADLED red
    LOG ""
    LOG red "!! PM3 disconnected !!"
    LOG red "Reconnect or B to exit."

    log_session "$(date +%H:%M:%S) PM3 disconnected"

    while [ ! -c "$PM3_DEV" ]; do
        sleep 1
        local btn
        btn=$(poll_button) || btn=""
        [ "$btn" = "B" ] && exit 0
    done

    LED cyan solid
    DPADLED cyan
    LOG green "PM3 reconnected."
    log_session "$(date +%H:%M:%S) PM3 reconnected"
}

# ══════════════════════════════════════════════════════════════════
#  CLEANUP
# ══════════════════════════════════════════════════════════════════

cleanup() {
    dd if=$INPUT of=/dev/null bs=16 count=200 iflag=nonblock 2>/dev/null

    if [ -n "$SESSION_LOG" ]; then
        echo "#" >> "$SESSION_LOG"
        echo "# Ended: $(date)" >> "$SESSION_LOG"
        LOG ""
        LOG cyan "Session: $SESSION_LOG"
    fi

    DPADLED off
    LED off
}
trap cleanup EXIT INT TERM

# ══════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════

LED cyan blink
LOG cyan "=== Proxmark3 Controller ==="
LOG cyan "       RDV4 Edition"
LOG ""
LOG "Detecting Proxmark3..."

if ! detect_pm3; then
    LED red blink
    LOG red "No Proxmark3 detected."
    LOG ""
    LOG white "Expected: /dev/ttyACM*"
    LOG white "Check USB connection."

    for dev in /dev/ttyACM* /dev/ttyUSB*; do
        [ -c "$dev" ] || continue
        LOG white "  Found: $dev"
    done

    ERROR_DIALOG "No Proxmark3 found.\nConnect PM3 RDV4 and retry."
    exit 1
fi

# ── Session log ────────────────────────────────────────────────
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SESSION_LOG="${LOOT_DIR}/pm3_session_${TIMESTAMP}.log"
{
    echo "# Proxmark3 Session Log"
    echo "# Device: ${PM3_PROD:-unknown} (${PM3_VID:-????}:${PM3_PID:-????})"
    echo "# Port:   $PM3_DEV"
    echo "# Started: $(date)"
    echo "#"
} > "$SESSION_LOG"

# ── Connected ──────────────────────────────────────────────────
LED cyan solid
DPADLED cyan

LOG green "PM3 Detected!"
LOG "  ${PM3_VID:-????}:${PM3_PID:-????}"
[ -n "$PM3_PROD" ] && LOG "  $PM3_PROD"
LOG "  Port: $PM3_DEV"
LOG ""

log_session "$(date +%H:%M:%S) PM3 connected on $PM3_DEV"

# ══════════════════════════════════════════════════════════════════
#  MAIN MENU LOOP
# ══════════════════════════════════════════════════════════════════

while true; do
    check_pm3

    LOG ""
    LOG cyan "==== MAIN MENU ====="
    LOG ""
    LOG "UP    LF (125 kHz)"
    LOG "DOWN  HF (13.56 MHz)"
    LOG "LEFT  Quick Reference"
    LOG "A     Device Info"
    LOG "B     Exit"

    DPADLED cyan

    btn=$(WAIT_FOR_INPUT)
    log_session "$(date +%H:%M:%S) Menu: $btn"

    case "$btn" in
        UP)
            menu_lf
            ;;
        DOWN)
            menu_hf
            ;;
        LEFT)
            show_reference
            ;;
        A)
            show_device_info
            LOG white "Press any button..."
            WAIT_FOR_INPUT > /dev/null
            ;;
        B)
            break
            ;;
    esac
done
