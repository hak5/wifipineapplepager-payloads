#!/bin/bash
# Title: GPS Checker
# Author: mik
# Description: Checks if GPS data is flowing
# Version: 1.0

id=$(START_SPINNER "Checking...") # Only one word, because of bug in 1.0.4
if timeout 5 gpspipe -r | grep -v '"class":'; then
     STOP_SPINNER ${id}
     LOG green "GPS data is flowing"
else
    STOP_SPINNER ${id}
    LOG yellow "No GPS data
               restarting gpsd
               & checking again"
    sleep 1
    id=$(START_SPINNER "Checking...") # Only one word, because of bug in 1.0.4
    service gpsd restart
    if timeout 5 gpspipe -r | grep -v '"class":'; then
        STOP_SPINNER ${id}
        LOG green "GPS data is flowing"
    else
        STOP_SPINNER ${id}
        LOG red "Could not get GPS working, please check config or hardware."
        exit 1
    fi
fi
