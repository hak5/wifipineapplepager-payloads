#!/bin/bash
# Title: wiglebluetooth
# Description: Log BLE devices to a Wigle-compatible CSV file (requires GPS).
# Author: Evelyn (@evecontextprotocol on Discord)
# Version: 1.0
# Category: Reconnaissance

if [ ! -f "wiglebluetooth" ]; then
    LOG blue "wiglebluetooth binary not found. Would you like to download it now? "
    LOG blue "Press UP to download, or DOWN to skip and exit the script."
    choice=$(WAIT_FOR_INPUT)
    if [ "$choice" == "UP" ]; then
        LOG green "Downloading wiglebluetooth binary..."
        if wget -q -O wiglebluetooth https://github.com/Craftzman7/wigle-bluetooth-pager/releases/latest/download/wiglebluetooth 2>/dev/null; then
            LOG green "wiglebluetooth downloaded successfully."
        else
            ERROR_DIALOG "Failed to download wiglebluetooth. Please check your internet connection and try again."; exit 0
        fi
    else
        LOG yellow "Skipping download. Exiting script."
        exit 0
    fi
fi

chmod +x wiglebluetooth

LOG red "PLEASE ENSURE YOUR GPS IS CONNECTED AND FUNCTIONAL BEFORE STARTING THE PROCESS."
LOG red "THE PROCESS WILL EXIT IF THE GPS IS NOT DETECTED."
    

while true; do
    LOG ""
    LOG green "Press UP to start the wiglebluetooth process"
    LOG red "Press DOWN to stop the wiglebluetooth process"
    LOG blue "Press right to combine the latest wiglebluetooth CSV with the Pineapple's latest CSV."
    LOG yellow "Press LEFT to exit the script"
    LOG ""

    choice=$(WAIT_FOR_INPUT)

    if [ "$choice" == "UP" ]; then
        if pgrep wiglebluetooth > /dev/null; then
            LOG yellow "wiglebluetooth is already running."
        else
            LOG green "Starting wiglebluetooth..."
            ./wiglebluetooth &
            LOG green "wiglebluetooth started. Logging in /root/loot/wigle-bluetooth"
        fi
    elif [ "$choice" == "DOWN" ]; then
        if pgrep wiglebluetooth > /dev/null; then
            LOG red "Stopping wiglebluetooth..."
            killall wiglebluetooth
            LOG red "wiglebluetooth stopped."
        else
            LOG yellow "wiglebluetooth is not running."
        fi
    elif [ "$choice" == "RIGHT" ]; then
        # Use the latest CSV file in /root/loot/wigle-bluetooth and the latest CSV file in /root/loot/wigle
        latest_bluetooth_csv=$(ls -t /root/loot/wigle-bluetooth/*.csv 2>/dev/null | head -n 1)
        latest_wifi_csv=$(ls -t /root/loot/wigle/*.csv 2>/dev/null | head -n 1)
        if [ -z "$latest_bluetooth_csv" ]; then
            LOG yellow "No Bluetooth CSV file found in /root/loot/wigle-bluetooth."
            continue
        fi
        if [ -z "$latest_wifi_csv" ]; then
            LOG yellow "No Wi-Fi CSV file found in /root/loot/wigle."
            continue
        fi
        if pgrep wiglebluetooth > /dev/null; then
            LOG red "Please stop the wiglebluetooth process before combining CSV files."
            continue
        fi
        LOG blue "Disabling wigle mode"
        WIGLE_STOP
        combined_csv="/root/loot/wigle/wigle-combined_$(date +%Y%m%d_%H%M%S).csv"
        # Copy the first two lines (headers) from the Bluetooth CSV to the combined CSV
        head -n 2 "$latest_bluetooth_csv" > "$combined_csv"
        # Append the data from both CSV files to the combined CSV (skipping headers)
        tail -n +3 "$latest_bluetooth_csv" >> "$combined_csv"
        tail -n +3 "$latest_wifi_csv" >> "$combined_csv"
        LOG green "Combined CSV created at $combined_csv"
    elif [ "$choice" == "LEFT" ]; then
        LOG yellow "Exiting the script..."
        exit 0
    else
        LOG red "Invalid input. Please try again."
    fi
done
