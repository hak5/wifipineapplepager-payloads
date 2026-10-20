#!/bin/bash
# Title: PROMPT_QR Example
# Author: Hak5Darren
# Description: Example usage of the PROMPT_QR DuckyScript command
# Version: 1.0

LOG "Launching text picker..."
resp=$(TEXT_PICKER "QR code data?" "https://example.com")
case $? in
    0)
        ;;
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
    *)
        LOG "Unexpected text picker status"
        exit 1
        ;;
esac

LOG "Launching message picker..."
message=$(TEXT_PICKER "QR code message?" "Scan this QR code")
case $? in
    0)
        ;;
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
    *)
        LOG "Unexpected text picker status"
        exit 1
        ;;
esac

LOG "Displaying QR code..."
PROMPT_QR "$resp" "$message"
LOG "Complete!"
