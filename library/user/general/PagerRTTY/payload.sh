#!/bin/bash
# Title:       PagerRTTY
# Author:      SECT0101
# Category:    General
# Description: Sends position and field reports as RTTY (ITA2/Baudot, 45.45 baud,
#              170 Hz shift) through the Pager's buzzer. Hold a radio mic to the
#              Pager, or feed any RTTY decoder. Receiver + Node-RED TAK flow in repo.
#              Phone Phreak menu: 2600 Hz whistle, plus DTMF, blue box, red box and
#              call progress as sound FX (the buzzer cannot play their low tones).
#              Audio is built by rtty.awk / tones.awk and played on the Pager's
#              buzzer sound card (pager-pcm) with aplay. No binaries.
# Version:     1.0.0-beta.2
# License:     GPL-3.0

# The Pager runs payloads from a staging copy, so $0 is not the payload folder.
# Use the launcher's _PAYLOAD_HOME, then the installed location.
PAYLOAD_PATH=""
for d in "${_PAYLOAD_HOME:-}" "${PAYLOAD_HOME:-}" "$(dirname "$(readlink -f "$0")")" \
         /root/payloads/user/general/PagerRTTY; do
    [ -n "$d" ] && [ -f "$d/rtty.awk" ] && { PAYLOAD_PATH="$d"; break; }
done
RTTY_AWK="$PAYLOAD_PATH/rtty.awk"
TONES_AWK="$PAYLOAD_PATH/tones.awk"
CFG="pagerrtty"

# ---------- settings (persisted with PAYLOAD_SET_CONFIG) ----------
get_cfg() { local v; v=$(PAYLOAD_GET_CONFIG "$CFG" "$1" 2>/dev/null); echo "${v:-$2}"; }
CALL=$(get_cfg call "$(cat /proc/sys/kernel/hostname)")
VOL=$(get_cfg volume 80)
LEAD=$(get_cfg lead 1000)
REPEAT=$(get_cfg repeat 1)
BEACON=$(get_cfg beacon 10)

# Volume 1-100 % (older configs may hold a larger value)
[ "$VOL" -ge 1 ] 2>/dev/null || VOL=80
[ "$VOL" -gt 100 ] && VOL=100
amp() { echo $(( VOL * 120 / 100 )); }

# ---------- requirements ----------
if [ -z "$PAYLOAD_PATH" ]; then
    ERROR_DIALOG "rtty.awk not found. Copy the whole PagerRTTY folder to /root/payloads/user/general/"
    exit 1
fi
if [ ! -e /dev/snd/pcmC0D0p ]; then
    ERROR_DIALOG "No buzzer sound card (pager-pcm). Update the Pager firmware."
    exit 1
fi
if ! command -v aplay >/dev/null 2>&1; then
    resp=$(CONFIRMATION_DIALOG "PagerRTTY needs aplay (alsa-utils). Install it now? Needs internet.")
    if [ "$resp" = "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]; then
        LOG "Installing alsa-utils..."
        opkg update >/dev/null 2>&1; opkg install alsa-utils >/dev/null 2>&1
    fi
    command -v aplay >/dev/null 2>&1 || { ERROR_DIALOG "aplay missing: run opkg install alsa-utils"; exit 1; }
fi

# Raw 8-bit PCM at 16 kHz to the buzzer sound card
play_pcm() { aplay -q -t raw -f U8 -r 16000 -c 1; }

# ---------- message helpers ----------
# Keep only characters every ITA2/US-TTY decoder agrees on, so the checksum
# matches what is heard.
ita2_clean() { echo "$1" | tr 'a-z' 'A-Z' | tr -cd 'A-Z0-9 ?:(),./-' | tr -s ' '; }

# NMEA-style XOR checksum over the body, 2 hex digits.
cksum8() {
    local s="$1" x=0 i c
    for ((i = 0; i < ${#s}; i++)); do
        printf -v c '%d' "'${s:i:1}"; x=$(( x ^ c ))
    done
    printf '%02X' "$x"
}

# Sets POS to e.g. "37.7749N 122.4194W" or empty when there is no fix.
get_pos() {
    POS=""
    local g lat lon ns ew
    g=$(timeout 5 GPS_GET 2>/dev/null)
    lat=$(echo "$g" | awk '{print $1}'); lon=$(echo "$g" | awk '{print $2}')
    if [ -z "$lat" ] || [ "$g" = "0 0 0 0" ] || awk "BEGIN{exit !($lat==0 && $lon==0)}"; then
        return 1
    fi
    ns=N; ew=E
    awk "BEGIN{exit !($lat<0)}" && ns=S
    awk "BEGIN{exit !($lon<0)}" && ew=W
    POS=$(awk -v a="$lat" -v o="$lon" -v n="$ns" -v e="$ew" \
        'BEGIN{if(a<0)a=-a; if(o<0)o=-o; printf "%07.4f%s %08.4f%s", a, n, o, e}')
}

# send TYPE [TEXT]  ->  DE <CALL> <TYPE> [POS <lat> <lon>] [TXT <text>] <HHMM>Z CK<xx>
send() {
    local type="$1" text body i
    text=$(ita2_clean "$2")
    get_pos
    body="DE $(ita2_clean "$CALL") $type"
    [ -n "$POS" ] && body="$body POS $POS"
    [ -n "$text" ] && body="$body TXT $text"
    body="$body $(date -u +%H%M)Z"
    body="$body CK$(cksum8 "$body")"
    LOG cyan "TX: $body"
    [ -z "$POS" ] && LOG yellow "No GPS fix - sent without position"
    for ((i = 1; i <= REPEAT; i++)); do
        awk -v msg=$'\r\n'"$body"$'\r\n' -v lead="$LEAD" -v amp="$(amp)" -f "$RTTY_AWK" | play_pcm \
            || { ERROR_DIALOG "Playback failed"; return 1; }
        [ "$i" -lt "$REPEAT" ] && sleep 1
    done
    LOG green "Sent ($REPEAT x)"
}

# ---------- reports ----------
ask() { local v; v=$(TEXT_PICKER "$1" "$2") || return 1; echo "$v"; }

salute() {
    local s a l u t e
    s=$(ask "S - Size" "") || return
    a=$(ask "A - Activity" "") || return
    l=$(ask "L - Location (blank = GPS)" "") || return
    u=$(ask "U - Unit/Uniform" "") || return
    t=$(ask "T - Time" "$(date -u +%H%MZ)") || return
    e=$(ask "E - Equipment" "") || return
    send SALUTE "S $s A $a L ${l:-GPS} U $u T $t E $e"
}

sitrep() {
    local st txt
    st=$(LIST_PICKER "SITREP status" "GREEN" "AMBER" "RED" "BLACK" "GREEN") || return
    txt=$(ask "SITREP remarks" "") || return
    send SITREP "$st $txt"
}

freetext() {
    local txt
    txt=$(ask "Message" "") || return
    [ -n "$txt" ] && send MSG "$txt"
}

beacon() {
    local n=0
    LOG cyan "Beacon every $BEACON min. Stop the payload to end."
    while true; do
        n=$((n + 1)); send LOC "" ; LOG "Beacon #$n"
        sleep $((BEACON * 60))
    done
}

test_tone() { send TEST "RYRYRY THE QUICK BROWN FOX 0123456789"; }

# ---------- phone phreak menu ----------
# The Pager's buzzer can't reproduce sound below ~1.5-2 kHz, so everything
# except the 2600 Hz whistle is a sound effect only and won't decode. tones.awk
# uses square waves so the low tones are still audible through their harmonics.
# The sequence is built to a temp file first, then played.
tones() {
    local f=/tmp/pagerrtty-tones.u8
    awk -v seq="$1" -v amp="$(amp)" -f "$TONES_AWK" > "$f" && play_pcm < "$f"
    rm -f "$f"
}

# Blue box MF pairs (Hz): KP, ST, digits
mf() {
    case "$1" in
        K) echo 1100+1700 ;; S) echo 1500+1700 ;;
        1) echo 700+900 ;;   2) echo 700+1100 ;;  3) echo 900+1100 ;;
        4) echo 700+1300 ;;  5) echo 900+1300 ;;  6) echo 1100+1300 ;;
        7) echo 700+1500 ;;  8) echo 900+1500 ;;  9) echo 1100+1500 ;;
        0) echo 1300+1500 ;;
    esac
}

bluebox() {
    local num seq d i
    num=$(TEXT_PICKER "Blue box: digits to send" "5551212") || return
    num=$(echo "$num" | tr -cd '0-9')
    [ -z "$num" ] && return
    # 2600 Hz seize, wink, then KP + digits + ST
    seq="2600:1000,0:1500,$(mf K):100,0:60"
    for ((i = 0; i < ${#num}; i++)); do d=${num:i:1}; seq="$seq,$(mf "$d"):60,0:60"; done
    seq="$seq,$(mf S):100"
    LOG cyan "Blue box: 2600, KP $num ST"
    tones "$seq"
}

redbox() {
    local c seq="" i n=1 on=66
    c=$(LIST_PICKER "Red box coin" "Nickel" "Dime" "Quarter" "Quarter") || return
    case "$c" in Dime) n=2 ;; Quarter) n=5; on=33 ;; esac
    for ((i = 0; i < n; i++)); do seq="$seq${seq:+,}1700+2200:$on,0:$on"; done
    LOG cyan "Red box: $c"
    tones "$seq"
}

dtmf() {
    local num
    num=$(TEXT_PICKER "DTMF digits (0-9 * # A-D)" "") || return
    num=$(echo "$num" | tr 'a-d' 'A-D' | tr -cd '0-9*#A-D')
    [ -z "$num" ] && return
    LOG cyan "DTMF: $num"
    local seq="" i k
    for ((i = 0; i < ${#num}; i++)); do
        case "${num:i:1}" in
            1) k=697+1209 ;; 2) k=697+1336 ;; 3) k=697+1477 ;; A) k=697+1633 ;;
            4) k=770+1209 ;; 5) k=770+1336 ;; 6) k=770+1477 ;; B) k=770+1633 ;;
            7) k=852+1209 ;; 8) k=852+1336 ;; 9) k=852+1477 ;; C) k=852+1633 ;;
            \*) k=941+1209 ;; 0) k=941+1336 ;; \#) k=941+1477 ;; D) k=941+1633 ;;
        esac
        seq="$seq${seq:+,}$k:120,0:120"
    done
    tones "$seq"
}

callprog() {
    local c
    c=$(LIST_PICKER "Call progress" "Dial tone" "Ringback" "Busy" "Reorder" "Dial tone") || return
    case "$c" in
        "Dial tone") tones "350+440:3000" ;;
        Ringback)    tones "440+480:2000,0:4000,440+480:2000" ;;
        Busy)        tones "480+620:500,0:500,480+620:500,0:500,480+620:500,0:500,480+620:500" ;;
        Reorder)     tones "480+620:250,0:250,480+620:250,0:250,480+620:250,0:250,480+620:250,0:250" ;;
    esac
}

phreak() {
    local c
    while true; do
        c=$(LIST_PICKER "Phone Phreak" \
            "2600 Hz whistle" "DTMF (sound FX)" "Blue box (sound FX)" "Red box (sound FX)" \
            "Call progress (sound FX)" "Back" "2600 Hz whistle") || return
        case "$c" in
            "2600 Hz whistle")   LOG cyan "Cap'n Crunch: 2600 Hz"; tones "2600:1000" ;;
            "DTMF (sound FX)")   dtmf ;;
            "Blue box (sound FX)") bluebox ;;
            "Red box (sound FX)")  redbox ;;
            "Call progress (sound FX)") callprog ;;
            *) return ;;
        esac
    done
}

# ---------- settings menu ----------
settings() {
    local c v
    while true; do
        c=$(LIST_PICKER "Settings" \
            "Callsign: $CALL" "Volume: ${VOL}%" "Lead-in: ${LEAD} ms" \
            "Repeat: ${REPEAT}x" "Beacon: ${BEACON} min" "Back" "Back") || return
        case "$c" in
            Callsign*) v=$(TEXT_PICKER "Callsign (blank = hostname)" "$CALL") || continue
                       v=$(ita2_clean "$v"); [ -z "$v" ] && v=$(cat /proc/sys/kernel/hostname)
                       CALL="$v"; PAYLOAD_SET_CONFIG "$CFG" call "$CALL" ;;
            Volume*)   v=$(NUMBER_PICKER "Volume % (1-100)" "$VOL") || continue
                       [ "$v" -ge 1 ] 2>/dev/null || v=1; [ "$v" -gt 100 ] && v=100
                       VOL="$v"; PAYLOAD_SET_CONFIG "$CFG" volume "$VOL" ;;
            Lead-in*)  v=$(NUMBER_PICKER "Lead-in tone ms (VOX: 1500+)" "$LEAD") || continue
                       LEAD="$v"; PAYLOAD_SET_CONFIG "$CFG" lead "$LEAD" ;;
            Repeat*)   v=$(NUMBER_PICKER "Send each message N times" "$REPEAT") || continue
                       [ "$v" -ge 1 ] 2>/dev/null || v=1
                       REPEAT="$v"; PAYLOAD_SET_CONFIG "$CFG" repeat "$REPEAT" ;;
            Beacon*)   v=$(NUMBER_PICKER "Beacon interval (minutes)" "$BEACON") || continue
                       [ "$v" -ge 1 ] 2>/dev/null || v=1
                       BEACON="$v"; PAYLOAD_SET_CONFIG "$CFG" beacon "$BEACON" ;;
            *) return ;;
        esac
    done
}

# ---------- main menu ----------
LOG "PagerRTTY - $CALL"
LOG "Decoder: RTTY 45.45 baud, 170 Hz shift, center 4000 Hz"
while true; do
    choice=$(LIST_PICKER "PagerRTTY" \
        "Send position" "SALUTE report" "SITREP" "Free text" \
        "Beacon position" "Test tones" "Phone Phreak" "Settings" "Exit" "Send position") || exit 0
    case "$choice" in
        "Send position")   send LOC "" ;;
        "SALUTE report")   salute ;;
        "SITREP")          sitrep ;;
        "Free text")       freetext ;;
        "Beacon position") beacon ;;
        "Test tones")      test_tone ;;
        "Phone Phreak")    phreak ;;
        "Settings")        settings ;;
        *) exit 0 ;;
    esac
done
