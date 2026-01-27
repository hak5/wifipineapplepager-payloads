#!/bin/bash
# Title:                Netstat
# Description:          Lists network connections and listening ports using netstat and logs the results
# Author:               tototo31
# Version:              1.0

# Options
LOOTDIR=/root/loot/netstat
DEFAULT_VIEW="all"

# Check if netstat command is available
if ! command -v netstat >/dev/null 2>&1; then
    LOG "ERROR: netstat command not found"
    ERROR_DIALOG "netstat command not found. Cannot list network connections."
    LOG "Exiting - netstat is required but not available"
    exit 1
fi

# Prompt user for view type
LOG "Launching netstat..."
LOG "Select view type:"
LOG "1. All connections (default)"
LOG "2. Listening ports only"
LOG "3. TCP connections only"
LOG "4. UDP connections only"
LOG "5. All with process information"
LOG "6. IPv4 connections only"
LOG "7. IPv6 connections only"
LOG ""
LOG "Press A button to continue..."

WAIT_FOR_BUTTON_PRESS A

view_choice=$(NUMBER_PICKER "Select view type (1-7)" 1)
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Using default view: all connections"
        view_choice=1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred, using default view: all connections"
        view_choice=1
        ;;
esac

# Determine netstat options based on view choice
# -n: show numerical addresses instead of resolving hosts
# -4: show IPv4 only
# -6: show IPv6 only
case $view_choice in
    1)
        view_name="all"
        netstat_opts="-na"
        ;;
    2)
        view_name="listening"
        netstat_opts="-nl"
        ;;
    3)
        view_name="tcp"
        netstat_opts="-nat"
        ;;
    4)
        view_name="udp"
        netstat_opts="-nau"
        ;;
    5)
        view_name="all_with_process"
        netstat_opts="-nap"
        ;;
    6)
        view_name="ipv4"
        netstat_opts="-na4"
        ;;
    7)
        view_name="ipv6"
        netstat_opts="-na6"
        ;;
    *)
        LOG "Invalid choice, using default: all connections"
        view_name="all"
        netstat_opts="-na"
        ;;
esac

# Create loot destination if needed
mkdir -p $LOOTDIR
lootfile=$LOOTDIR/$(date -Is)_netstat_${view_name}

LOG "Listing network connections (view: $view_name)..."
LOG "Results will be saved to: $lootfile\n"

# Run netstat and save to file, also log each line
# Redirect stderr to stdout for process info view (may have permission warnings)
netstat $netstat_opts 2>&1 | tee $lootfile | sed G | tr '\n' '\0' | xargs -0 -n 1 LOG

LOG "\nNetstat listing complete!"

