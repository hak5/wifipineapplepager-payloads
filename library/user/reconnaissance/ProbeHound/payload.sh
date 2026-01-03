#!/bin/bash
# Title: ProbeHound
# Description: Searches for devices broadcasting probe requests for a specified SSID
# Acknowledgements: Some parts of this code (SSID Pool) were adapted from Device_Hunter by RocketGod and NotPike Helped (Crew: The Pirates' Plunder). Also, thanks to dark_pyrro.
# Author: DocVoom
# Version: 1.0

# Global variables
SELECTED=0
TOTAL_SSIDS=0
SSID_ARRAY=()
ALERT_TONE="alert.rtttl"
date=$(date '+%m%d%Y')

# FUNCTIONS
collect_targets() {
    LOG "Collecting SSID Pool"
    readarray -t SSID_ARRAY < <(PINEAPPLE_SSID_POOL_LIST)
    TOTAL_SSIDS=${#SSID_ARRAY[@]}

    if [ $TOTAL_SSIDS -eq 0 ]; then
    	LOG "No targets found"
    	exit 1
    fi
	LOG "Found $TOTAL_SSIDS targets"
}

show_target() {
    LOG ""
    LOG "[$((SELECTED + 1))/$TOTAL_SSIDS] ${SSID_ARRAY[$SELECTED]}"
    LOG ""
    LOG "UP/DOWN=Scroll A=Select B=exit"
}

select_target() {
    SELECTED=0
    show_target
    
    while true; do
        local btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP|LEFT)
                SELECTED=$((SELECTED - 1))
                [ $SELECTED -lt 0 ] && SELECTED=$((TOTAL_SSIDS - 1))
                show_target
                ;;
            DOWN|RIGHT)
                SELECTED=$((SELECTED + 1))
                [ $SELECTED -ge $TOTAL_SSIDS ] && SELECTED=0
                show_target
                ;;
            A)
                return 0
                ;;
            B)
            	exit 0
            	;;
        esac
    done
}

recon() {    
    while true; do
        if $TARGET_SSID==:; then
            LOG "No target selected"
            exit 1    
        fi
        LOG "Starting tcpdump..."
        LOG ""
        tcpdump -i wlan0mon -e -l -s 256  type mgt subtype probe-req 2>/dev/null | while read -r line; do
                if echo "$line" | grep -q "$1"; then
                        DEVICE=$(echo "$line" | grep -Eo '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
                        SIGNAL=$(echo "$line" | grep -Eo '[0-9]+dBm')
                        LOG "*** CLIENT DETECTED! ***"
                        LOG "<$DEVICE> <$SIGNAL> <$1>"
                        LOG ""
                        RINGTONE $ALERT_TONE
                        LOG "Saving to scan log..."
                        echo "$line" | tee -a "logs/${date}-scanlog.txt"
                        exit 0
                fi
            done
        LOG ""
        LOG "A=Continue / B=Exit"
        resp=$(WAIT_FOR_INPUT)
        case $resp in
            A) ;;
            B) 
                LOG ""
                line=()
                break ;;
        esac
    done        
}

# MAIN MENU
while :
do
    LOG "MAIN MENU ================================="
    LOG "[<]  Select from SSID Pool"
    LOG "[>]  Enter SSID"
    LOG "[A]  Begin Scan"
    LOG "[B]  Exit"
    LOG "==========================================="
    LOG ""
    resp=$(WAIT_FOR_INPUT)
    case $resp in
        LEFT) 
            collect_targets
            select_target
            TARGET_SSID="${SSID_ARRAY[$SELECTED]}"
            LOG "Selected target: $TARGET_SSID"
            LOG ""
            ;;
        RIGHT)
            LOG "Enter Target"
            TARGET_SSID=$(TEXT_PICKER "ESSID:" "")
            LOG "Selected target: $TARGET_SSID"
            LOG ""
            ;;
        A)
            recon $TARGET_SSID
            LOG "Scan stopped"
            LOG ""
            ;;
        B)
            LOG "Goodbye"
            exit 0 
            ;;
    esac
done