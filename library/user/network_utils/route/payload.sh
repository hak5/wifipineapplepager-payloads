#!/bin/bash
# Title:                Route
# Description:          Lists routing table information and logs the results
# Author:               tototo31
# Version:              1.0

# Options
LOOTDIR=/root/loot/route
DEFAULT_VIEW="all"

# === UTILITIES ===

setup() {
    LED SETUP
    # Check for ip command (preferred, modern)
    if ! command -v ip >/dev/null 2>&1; then
        LOG "Installing iproute2..."
        opkg update
        opkg install iproute2
        if ! command -v ip >/dev/null 2>&1; then
            # Fall back to checking for route command
            if ! command -v route >/dev/null 2>&1; then
                LOG "Installing net-tools..."
                opkg install net-tools
                if ! command -v route >/dev/null 2>&1; then
                    LED FAIL
                    LOG "ERROR: Failed to install route utilities"
                    ERROR_DIALOG "Route utilities installation failed. Cannot list routing information."
                    LOG "Exiting - route utilities are required but could not be installed"
                    exit 1
                fi
            fi
        fi
    fi
}

# === MAIN ===

# Setup and check dependencies
setup

# Determine which command to use (prefer ip over route)
if command -v ip >/dev/null 2>&1; then
    USE_IP_CMD=true
else
    USE_IP_CMD=false
fi

# Prompt user for view type
LOG "Launching route..."
LOG "Select view type:"
LOG "1. All routes (default)"
LOG "2. IPv4 routes only"
LOG "3. IPv6 routes only"
LOG "4. Default route only"
LOG "5. Routes for specific interface"
LOG ""
LOG "Press A button to continue..."

WAIT_FOR_BUTTON_PRESS A

view_choice=$(NUMBER_PICKER "Select view type (1-5)" 1)
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Using default view: all routes"
        view_choice=1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred, using default view: all routes"
        view_choice=1
        ;;
esac

# Determine route options based on view choice
case $view_choice in
    1)
        view_name="all"
        if [ "$USE_IP_CMD" = true ]; then
            route_cmd="ip route show"
        else
            route_cmd="route -n"
        fi
        ;;
    2)
        view_name="ipv4"
        if [ "$USE_IP_CMD" = true ]; then
            route_cmd="ip -4 route show"
        else
            route_cmd="route -n -4"
        fi
        ;;
    3)
        view_name="ipv6"
        if [ "$USE_IP_CMD" = true ]; then
            route_cmd="ip -6 route show"
        else
            route_cmd="route -n -6"
        fi
        ;;
    4)
        view_name="default"
        if [ "$USE_IP_CMD" = true ]; then
            route_cmd="ip route show default"
        else
            route_cmd="route -n | grep '^0.0.0.0'"
        fi
        ;;
    5)
        # Get list of interfaces
        if [ "$USE_IP_CMD" = true ]; then
            interfaces=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
        elif command -v ifconfig >/dev/null 2>&1; then
            interfaces=$(ifconfig -a | grep -E '^[a-z]' | awk '{print $1}' | sed 's/:$//')
        else
            # Fallback to /proc/net/dev (always available on Linux)
            interfaces=$(cat /proc/net/dev | grep -E '^[[:space:]]*[a-z]' | awk -F':' '{print $1}' | tr -d ' ')
        fi
        
        if [ -z "$interfaces" ]; then
            LOG "ERROR: No network interfaces found"
            ERROR_DIALOG "No network interfaces found. Cannot filter by interface."
            exit 1
        fi
        
        # Store interfaces in array for indexing
        interface_array=()
        interface_count=0
        while IFS= read -r iface; do
            if [ -n "$iface" ]; then
                interface_array+=("$iface")
                interface_count=$((interface_count + 1))
            fi
        done <<< "$interfaces"
        
        # Create interface selection dialog
        LOG "Select interface:"
        for i in $(seq 1 $interface_count); do
            idx=$((i - 1))
            LOG "$i. ${interface_array[$idx]}"
        done
        LOG ""
        LOG "Press A button to continue..."
        
        WAIT_FOR_BUTTON_PRESS A
        
        interface_choice=$(NUMBER_PICKER "Select interface (1-$interface_count)" 1)
        case $? in
            $DUCKYSCRIPT_CANCELLED)
                LOG "User cancelled"
                exit 1
                ;;
            $DUCKYSCRIPT_REJECTED)
                LOG "Using default: first interface"
                interface_choice=1
                ;;
            $DUCKYSCRIPT_ERROR)
                LOG "An error occurred, using default: first interface"
                interface_choice=1
                ;;
        esac
        
        # Validate choice and get interface name
        if [ "$interface_choice" -lt 1 ] || [ "$interface_choice" -gt "$interface_count" ]; then
            LOG "Invalid choice, using first interface"
            interface_choice=1
        fi
        
        idx=$((interface_choice - 1))
        interface="${interface_array[$idx]}"
        
        view_name="interface_${interface}"
        if [ "$USE_IP_CMD" = true ]; then
            route_cmd="ip route show dev $interface"
        else
            route_cmd="route -n | grep $interface"
        fi
        ;;
    *)
        LOG "Invalid choice, using default: all routes"
        view_name="all"
        if [ "$USE_IP_CMD" = true ]; then
            route_cmd="ip route show"
        else
            route_cmd="route -n"
        fi
        ;;
esac

# Create loot destination if needed
mkdir -p $LOOTDIR
lootfile=$LOOTDIR/$(date -Is)_route_${view_name}

LOG "Listing routing table (view: $view_name)..."
LOG "Results will be saved to: $lootfile\n"

# Run route command and capture output
LED ATTACK
route_output=$(eval "$route_cmd" 2>&1)

# Save output to file
echo "$route_output" > $lootfile

# Check if output is empty (trim whitespace)
route_output_trimmed=$(echo "$route_output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$route_output_trimmed" ]; then
    LOG "No route information found for this view."
    LOG "The routing table may be empty or the filter returned no results."
    ALERT "No route information available"
else
    # Display the route output
    echo "$route_output" | sed G | tr '\n' '\0' | xargs -0 -n 1 LOG
fi

LOG "\nRoute listing complete!"

