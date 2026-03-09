#!/bin/bash
# Title:                NotifyMe
# Description:          A small application, letting the user get notified at a defined timestamp
# Author:               0i41E
# Version:              1.0

LOG "Launching NotifyMe..."

#Defining current time, stepping up to the next minute
NOW_EPOCH=$(date +%s)
DEFAULT_EPOCH=$((NOW_EPOCH + 60))
DEFAULT_TIME=$(date -d "@$DEFAULT_EPOCH" "+%Y-%m-%d %H:%M")

# Prompt user for notification time - Format ((YYYY-MM-DD HH:MM)
TARGET_TIME=$(TEXT_PICKER "Notify me at:" "$DEFAULT_TIME")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Invalid input dialog"
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred"
        exit 1
        ;;
esac

#Validate input format
if [[ ! "$TARGET_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}$ ]]; then
    ERROR_LOG "Invalid date format!\nUse: YYYY-MM-DD HH:MM"
    ERROR_DIALOG "Invalid date format!\nUse: YYYY-MM-DD HH:MM"
    exit 1
fi

# Convert input time to epoch
TARGET_EPOCH=$(date -d "$TARGET_TIME" +%s 2>/dev/null)

# Validate date conversion
if [[ -z "$TARGET_EPOCH" ]]; then
    ERROR_LOG "Invalid date or time entered"
    ERROR_DIALOG "Invalid date or time entered"
    exit 1
fi

#Prompt user for alert reason
REASON=$(TEXT_PICKER "Reason for alert:" "NotifyMe :)")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        ERROR_DIALOG "User cancelled"
        exit 1
        ;;
esac

LOG "Notifying user at $TARGET_TIME for $REASON..."

# Loop until target time is reached
while true; do
    CURRENT_EPOCH=$(date +%s)

    if (( CURRENT_EPOCH >= TARGET_EPOCH )); then
        #Example Ringtone from Documentation
        RINGTONE "Desk Phone:d=8,o=5,b=500:c#,f,c#,f,c#,f,c#,f,c#,f,4p.,c#,f,c#,f,c#,f,c#,f,c#,f,1p.,c#,f,c#,f,c#,f,c#,f,c#,f,4p.,c#,f,c#,f,c#,f,c#,f,c#,f"
        PROMPT "$REASON"
        break
    fi

    sleep 20
done