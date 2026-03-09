#!/bin/bash
# Title: Device Hunter
# Description: Track any device by signal strength
# Author: RocketGod - https://betaskynet.com and NotPike Helped - https://bad-radio.solutions
# Crew: The Pirates' Plunder - https://discord.gg/thepirates

INPUT=/dev/input/event0

# === CLEANUP ===

cleanup() {
    # Kill ALL monitor processes
    pkill -9 -f "_pineap MONITOR" 2>/dev/null
    pkill -9 -f "hunter_signal" 2>/dev/null
    
    # Remove temp files
    rm -f /tmp/hunter_signal /tmp/hunter_running
    
    # Reset pineap examine lock if any
    _pineap EXAMINE CANCEL 2>/dev/null
    
    # LEDs off
    led_off 2>/dev/null
    
    # Flush input buffer
    dd if=$INPUT of=/dev/null bs=16 count=200 iflag=nonblock 2>/dev/null
    
    # Small delay to let things settle
    sleep 0.2
}

# Cleanup on ANY exit
trap cleanup EXIT INT TERM

# Cleanup on startup - BEFORE anything else
pkill -9 -f "_pineap MONITOR" 2>/dev/null
rm -f /tmp/hunter_signal
_pineap EXAMINE CANCEL 2>/dev/null
sleep 0.3

# === LED CONTROL ===

led_pattern() {
    . /lib/hak5/commands.sh
    HAK5_API_POST "system/led" "$1" >/dev/null 2>&1
}

led_off() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":100,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_signal_1() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_signal_2() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_signal_3() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,true,false],"2":[true,true,false],"3":[true,true,false],"4":[false,false,false]}}]}'
}

led_signal_4() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,false,false],"2":[true,false,false],"3":[true,false,false],"4":[true,false,false]}}]}'
}

# === SOUNDS ===

click_weak()   { RINGTONE "W:d=32,o=4,b=200:c" & }
click_med()    { RINGTONE "M:d=32,o=5,b=200:c" & }
click_strong() { RINGTONE "S:d=32,o=6,b=200:c" & }
click_hot()    { RINGTONE "H:d=32,o=7,b=200:c" & }
play_found()   { RINGTONE "xp" & }
play_start()   { RINGTONE "getkey" & }

# === NON-BLOCKING BUTTON CHECK ===

check_for_A() {
    local data=$(timeout 0.02 dd if=$INPUT bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x "' 2>/dev/null)
    [ -z "$data" ] && return 1
    local type=$(echo "$data" | cut -d' ' -f9-10)
    local value=$(echo "$data" | cut -d' ' -f13)
    local keycode=$(echo "$data" | cut -d' ' -f11-12)
    if [ "$type" = "01 00" ] && [ "$value" = "01" ]; then
        if [ "$keycode" = "31 01" ] || [ "$keycode" = "30 01" ]; then
            return 0
        fi
    fi
    return 1
}

# === TARGET SELECTION ===

declare -a AP_MACS
declare -a AP_SSIDS
declare -a AP_SIGNALS
SELECTED=0
TOTAL_APS=0

scan_targets() {
    LOG "Scanning..."
    local json=$(_pineap RECON APS limit=20 format=json)

    AP_MACS=()
    AP_SSIDS=()
    AP_SIGNALS=()
    
    while read -r mac; do
        AP_MACS+=("$mac")
    done < <(echo "$json" | grep -o '"mac":"[^"]*"' | sed 's/"mac":"//;s/"//')
    
    while read -r ssid; do
        [ -z "$ssid" ] && ssid="[Hidden]"
        AP_SSIDS+=("$ssid")
    done < <(echo "$json" | grep -o '"ssid":"[^"]*"' | head -20 | sed 's/"ssid":"//;s/"//')
    
    while read -r sig; do
        AP_SIGNALS+=("$sig")
    done < <(echo "$json" | grep -o '"signal":-[0-9]*' | head -20 | sed 's/"signal"://')
    
    TOTAL_APS=${#AP_MACS[@]}
    
    if [ $TOTAL_APS -eq 0 ]; then
        LOG "No targets! Start recon."
        exit 1
    fi
    LOG "Found $TOTAL_APS targets"
}
 
show_target() {
    LOG ""
    LOG "[$((SELECTED + 1))/$TOTAL_APS] ${AP_SSIDS[$SELECTED]}"
    LOG "${AP_MACS[$SELECTED]}"
    LOG "${AP_SIGNALS[$SELECTED]}dBm"
    LOG ""
    LOG "UP/DOWN=Scroll A=Hunt"
}

select_target() {
    SELECTED=0
    show_target
    
    while true; do
        local btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP|LEFT)
                SELECTED=$((SELECTED - 1))
                [ $SELECTED -lt 0 ] && SELECTED=$((TOTAL_APS - 1))
                show_target
                ;;
            DOWN|RIGHT)
                SELECTED=$((SELECTED + 1))
                [ $SELECTED -ge $TOTAL_APS ] && SELECTED=0
                show_target
                ;;
            A)
                play_found
                return 0
                ;;
        esac
    done
}

# === TRACKING ===

make_bar() {
    local sig=$1
    local strength=$(( (sig + 90) / 3 ))
    [ $strength -lt 1 ] && strength=1
    [ $strength -gt 20 ] && strength=20
    printf '%0*d' $strength 0 | tr '0' '#'
    printf '%0*d' $((20 - strength)) 0 | tr '0' '-'
}

track_target() {
    if [ $MODE_STATE -eq 0 ]; then # Manual Mode
        local mac=$MAC_ADDRESS

        LOG ""
        LOG "HUNTING: $mac"
        LOG "A = Stop"
        LOG ""
    else                           # Scan Mode
        local mac="${AP_MACS[$SELECTED]}"
        local ssid="${AP_SSIDS[$SELECTED]}"
        
        LOG ""
        LOG "HUNTING: $ssid"
        LOG "A = Stop"
        LOG ""
    fi
        
    # Make sure no old monitor is running
    pkill -9 -f "_pineap MONITOR" 2>/dev/null
    sleep 0.2
    
    rm -f /tmp/hunter_signal

    # 'any' reports signal from any packets including client devices
    _pineap MONITOR "$mac" any rate=200 timeout=3600 > /tmp/hunter_signal 2>&1 &

    local monitor_pid=$!
    
    # Verify it started
    sleep 0.5
    if ! kill -0 $monitor_pid 2>/dev/null; then
        LOG "Monitor failed to start!"
        return
    fi
    
    local click_counter=0
    
    while kill -0 $monitor_pid 2>/dev/null; do
        if check_for_A; then
            kill -9 $monitor_pid 2>/dev/null
            wait $monitor_pid 2>/dev/null
            LOG "Stopped."
            return
        fi
        
        local sig=$(tail -1 /tmp/hunter_signal 2>/dev/null)
        
        if [ -n "$sig" ] && [[ "$sig" =~ ^-[0-9]+$ ]]; then
            local bar=$(make_bar $sig)
            
            local level=1
            [ $sig -ge -75 ] && level=2
            [ $sig -ge -55 ] && level=3
            [ $sig -ge -35 ] && level=4
            
            case $level in
                1) led_signal_1 ;;
                2) led_signal_2 ;;
                3) led_signal_3 ;;
                4) led_signal_4; VIBRATE 20 ;;
            esac
            
            click_counter=$((click_counter + 1))
            local click_rate=$((5 - level))
            [ $click_rate -lt 1 ] && click_rate=1
            if [ $((click_counter % click_rate)) -eq 0 ]; then
                case $level in
                    1) click_weak ;;
                    2) click_med ;;
                    3) click_strong ;;
                    4) click_hot ;;
                esac
            fi
            
            LOG "${sig}dBm [${bar}]"
        fi
        
        sleep 0.1
    done
}

# === MENU LOGIC ===

MODE_STATE=0 #0 is Manual 1 is Scan
TOTAL_OPTIONS=2
MAC_ADDRESS=0

menu_text() {
    LOG ""
    if [ $MODE_STATE -eq 0 ]; then  # Manual Mode
        LOG ""
        LOG "+------------+"
        LOG "|Manual Mode?|"
        LOG "+------------+"
        LOG "Scan Mode?"
        LOG ""
    else                            # Scan Mode
        LOG ""
        LOG "Manual Mode?"
        LOG "+----------+"
        LOG "|Scan Mode?|"
        LOG "+----------+"
        LOG ""
    fi
    LOG ""
    LOG "UP/DOWN=Scroll A=Select"
}

# Redudent but I just copyed and paist the same logic from above. Maybe we can have more options in the future? :D
menu_options() {
    local OPTION=0
    menu_text
    
    while true; do
        local btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP|LEFT)
                OPTION=$((OPTION - 1))
                [ $OPTION -lt 0 ] && OPTION=$((TOTAL_OPTIONS - 1))
                ((MODE_STATE ^=1)) #Flip Flop
                menu_text
                ;;
            DOWN|RIGHT)
                OPTION=$((OPTION + 1))
                [ $OPTION -ge $TOTAL_APS ] && OPTION=0
                ((MODE_STATE ^=1)) #Flip Flop
                menu_text
                ;;
            A)
                play_found
                return 0
                ;;
        esac
    done
}

mac_address() {
    MAC_ADDRESS=$(MAC_PICKER "Target MAC?" "DE:AD:BE:EF:CA:FE")
    case $? in
        $DUCKYSCRIPT_CANCELLED)
            LOG "User cancelled"
            exit 1
            ;;
        $DUCKYSCRIPT_REJECTED)
            LOG "Dialog rejected"
            exit 1
            ;;
        $DUCKYSCRIPT_ERROR)
            LOG "An error occurred"
            exit 1
            ;;
    esac
}

# === MAIN ===

LOG "DEVICE HUNTER"
LOG "by RocketGod"
LOG ""

play_start
menu_options

if [ $MODE_STATE -eq 0 ]; then  # Manual Mode
    mac_address
else                            # Scan Mode
    scan_targets
    select_target
fi

track_target

LOG "Done!"
