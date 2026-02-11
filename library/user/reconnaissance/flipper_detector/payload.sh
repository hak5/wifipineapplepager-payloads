#!/bin/bash
# Title: Flipper Detector
# Device: WiFi Pineapple Pager

FLIPPER_OUI="80:E1:26"
SEEN=""

TITLE "FLIPPER HUNTER"
LOG "Initializing BLE..."

hciconfig hci0 up 2>/dev/null
(echo "scan on"; cat) | bluetoothctl >/dev/null 2>&1 &

LED B 50
RINGTONE alert
LOG "Scanning for Flippers..."
sleep 2

while true; do
    TITLE "HUNTING..."

    for mac in $(bluetoothctl devices 2>/dev/null | grep "$FLIPPER_OUI" | awk '{print $2}'); do
        if ! echo "$SEEN" | grep -q "$mac"; then
            SEEN="$SEEN $mac"
            name=$(bluetoothctl devices 2>/dev/null | grep "$mac" | cut -d' ' -f3-)
            LED R 255
            RINGTONE warning
            LOG "FLIPPER: $mac"
            LOG "Name: $name"
            ALERT_RINGTONE "FLIPPER DETECTED" "$mac - $name"
            LED OFF
        fi
    done

    LED B 20
    sleep 2
    LED OFF
done
