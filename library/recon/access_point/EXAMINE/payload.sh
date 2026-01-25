#!/bin/bash
# Title:       EXAMINE
# Description: Set the pager to monitor a target AP channel or BSSID. Options for manual entry and reset to default.
# Author:      Septumus
# Version:     1.0

LOG ""
LOG green "A (GREEN) - EXAMINE ALL CHANNELS AND BSSID (DEFAULT)"
LOG ""
LOG blue "UP - EXAMINE TARGET AP CHANNEL"
LOG ""
LOG cyan "RIGHT - EXAMINE CHANNEL OF YOUR CHOICE"
LOG ""
LOG yellow "DOWN - EXAMINE TARGET AP BSSID"
LOG ""
LOG orange "LEFT - EXAMINE BSSID OF YOUR CHOICE"
LOG ""
LOG red "B (RED) - EXIT"
LOG ""

button=$(WAIT_FOR_INPUT)

case ${button} in
    "A")
        PINEAPPLE_EXAMINE_RESET
        LOG "Pager has now been set to scan all channels."
        LOG ""
        LOG ""
        ;;
    "UP")
       channel=$_RECON_SELECTED_AP_CHANNEL
       PROMPT "Cancel time entry to keep your channel selection until you reset it."
	seconds=$(NUMBER_PICKER "Seconds to monitor: " 7)
        LOG "CHANGING TO CHANNEL $channel..."
        LOG ""
        LOG ""
	PINEAPPLE_EXAMINE_CHANNEL $channel $seconds
		if [[ -z "$seconds" ]]; then
		LOG "Now watching only channel $channel until reset."
		else
		LOG "Now watching only channel $channel for $seconds seconds."
	    	fi
        LOG ""
        LOG ""        
        ;;
    "DOWN")
        bssid=$_RECON_SELECTED_AP_BSSID
        PROMPT "Cancel time entry to keep your BSSID selection until you reset it."
	seconds=$(NUMBER_PICKER "Seconds to monitor: " 7)
        LOG "CHANGING TO CHANNEL $_RECON_SELECTED_AP_SSID at $bssid..."
        LOG ""
        LOG ""
	PINEAPPLE_EXAMINE_BSSID $bssid $seconds
		if [[ -z "$seconds" ]]; then
       	LOG "Now watching only $_RECON_SELECTED_AP_SSID at $bssid until reset."
		else
		LOG "Now watching only $_RECON_SELECTED_AP_SSID at $bssid for $seconds seconds."
	    	fi
        LOG ""
        LOG ""        
        ;;
     "RIGHT")
        channel=$(NUMBER_PICKER "Channel to examine: " 7)
        PROMPT "Cancel time entry to keep your channel selection until you reset it."
	seconds=$(NUMBER_PICKER "Seconds to monitor: " 7)
        LOG "CHANGING TO CHANNEL $channel..."
        LOG ""
        LOG ""
	PINEAPPLE_EXAMINE_CHANNEL $channel $seconds
		if [[ -z "$seconds" ]]; then
		LOG "Now watching only channel $channel until reset."
		else
		LOG "Now watching only channel $channel for $seconds seconds."
	    	fi
        LOG ""
        LOG ""        
        ;;
     "LEFT")
        bssid=$(MAC_PICKER "BSSID to examine: " "DE:AD:BE:EF:00:00:07")
        PROMPT "Cancel time entry to keep your BSSID selection until you reset it."
	seconds=$(NUMBER_PICKER "Seconds to monitor: " 7)
        LOG "CHANGING TO BSSID $bssid..."
        LOG ""
        LOG ""
	PINEAPPLE_EXAMINE_BSSID $bssid $seconds
		if [[ -z "$seconds" ]]; then
		LOG "Now watching only BSSID $bssid until reset."
		else
		LOG "Now watching only BSSID $bssid for $seconds seconds."
	    	fi
        LOG ""
        LOG ""        
        ;;
     *) 
        LOG "User chose to exit."
        LOG ""
	LOG ""
        ;;
esac