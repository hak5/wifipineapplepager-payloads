#!/bin/bash
# Title: GPS Device Picker
# Description: Manually Choose GPS Dev From Predefined List of Likely devices.
# Author: William Stone
# Version: 1.0

# LED setup
LED R

# Use TEXT_PICKER to enter any device (no validation)
DEVICE=$(TEXT_PICKER "Enter device (e.g. ttyACM0)" "ttyACM0") || exit 0

# Add /dev/ prefix if not already present
case $DEVICE in
    /dev/*)
        # Already has /dev/ prefix, use as-is
        ;;
    *)
        # Add /dev/ prefix
        DEVICE="/dev/$DEVICE"
        ;;
esac

LOG "Selected device: $DEVICE"

# Show spinner while checking device
SPINNER "Checking device..." &
SPINNER_PID=$!

# Verify the device exists
if [ -e "$DEVICE" ]; then
    kill $SPINNER_PID 2>/dev/null
    LOG "Device $DEVICE exists and is accessible"
    LED G

    # Save the device selection
    echo "$DEVICE" > /tmp/selected_device.txt
    LOG "Device selection saved to /tmp/selected_device.txt"

    # Present baud rate selection using NUMBER_PICKER
    BAUD=$(NUMBER_PICKER "Baud Rate" "9600") || BAUD="9600"

    # Configure GPS with the selected device and baud rate
    SPINNER "Configuring GPS..." &
    SPINNER_PID=$!

    # Completely stop and kill gpsd to clear all caches
    /etc/init.d/gpsd stop 2>/dev/null
    killall gpsd 2>/dev/null
    sleep 2

    # Configure GPS with new device and baud (this will start gpsd fresh)
    GPS_CONFIGURE "$DEVICE" "$BAUD"
    GPS_RESULT=$?

    # Wait for gpsd to fully initialize with new device
    sleep 2

    kill $SPINNER_PID 2>/dev/null

    if [ $GPS_RESULT -eq 0 ]; then
        LOG "GPS configured successfully: $DEVICE @ $BAUD baud"
        ALERT "GPS configured: $DEVICE @ $BAUD - Showing log for 5 seconds"
        LED G FAST

        # Check GPS data availability
        LOG "Checking for GPS data..."
        LOG "-----------------------------------"

        # Kill any existing gpspipe processes first
        killall gpspipe 2>/dev/null
        sleep 1

        # Capture 5 seconds of GPS data to a temp file
        timeout -k 1 5 gpspipe -r 2>/dev/null > /tmp/gps_test.txt &
        sleep 5
        killall gpspipe 2>/dev/null
        sleep 1

        # Skip first 4 lines (cached data) and check if we got any fresh data
        FRESH_DATA=$(tail -n +5 /tmp/gps_test.txt)

        if [ -n "$FRESH_DATA" ]; then
            # Show next 10 lines after skipping first 4
            echo "$FRESH_DATA" | head -n 10 | while IFS= read -r line; do
                LOG "$line"
            done
            LOG "-----------------------------------"
            LOG "GPS data detected - device is working"
        else
            LOG "-----------------------------------"
            LOG "No GPS data received - check device connection"
        fi

        # Cleanup
        rm -f /tmp/gps_test.txt
    else
        LOG "Warning: GPS_CONFIGURE returned error code $GPS_RESULT"
        ERROR_DIALOG "GPS configuration failed (code: $GPS_RESULT)"
        LED Y SLOW
    fi

else
    kill $SPINNER_PID 2>/dev/null
    ERROR_DIALOG "Device $DEVICE does not exist"
    LED R SLOW
    exit 1
fi

# Success
sleep 2
LED OFF

