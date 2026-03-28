#!/bin/bash
# Title: P2P - Manage Pager Configuration
# Description: Manage the configuration settings for the P2P Pager system
# Author: ERR0RW0LF

P2P_CONFIG_DIR="/root/.p2p_pager"
PAGER_CONFIG="$P2P_CONFIG_DIR/pager.conf"
TEMP_CONFIG="/tmp/pager.conf.tmp"

STANDARD_CONFIG="""decay_time=300
beacon_interval=10
beacon_uptime=120
ssid_prefix=P2PAGER
channel=6
max_message_length=50
message_prefix=MSG:
decay_prefix=DECAY:"""

reset_pager_config() {
    LOG "Resetting pager configuration to default values..."
    echo "$STANDARD_CONFIG" > "$PAGER_CONFIG"
    LOG "Pager configuration reset to default values."
}

create_tmp_config() {
    LOG "Creating temporary configuration file..."
    cp "$PAGER_CONFIG" "$TEMP_CONFIG"
    LOG "Temporary configuration file created at $TEMP_CONFIG."
}

# Functionality 
# Configure the different parameters for the pager system
# Reset to default values, or set custom values for each parameter
# Only apply changes when the user confirms, otherwise discard the temporary config file before exiting the configuration menu

# Menu:
# ====== Main menu: ======
# 1. Get current configuration
# 2. Reset to default values
# 3. Change settings
# 0. Exit
#
# Waiting for user input...

main_menu() {
    LOG "P2P Pager Configuration Management"
    LOG "1) Get current configuration"
    LOG "2) Reset to default values"
    LOG "3) Change settings"
    LOG "0) Exit"
    
    LOG " "
    LOG "Waiting for user input..."
    
    WAIT_FOR_INPUT

    choice=$(NUMBER_PICKER "Select an option:" 1)
    
    case $choice in
        1)
            #LOG "Current pager configuration:"
            current_config_menu
            ;;
        2)
            if [ "$(CONFIRMATION_DIALOG "Are you sure you want to reset the pager configuration to default values? This action cannot be undone.")" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                LOG "User cancelled resetting pager configuration." && return
            fi
            reset_pager_config
            ;;
        3)
            change_settings_menu
            ;;
        0)
            exit_config_menu
            ;;
        *)
            LOG "Invalid choice. Please select a valid option."
            ;;
    esac
}

# ====== Current configuration: ======
# Name: value
# 0. Back
#
# Waiting for user input...

current_config_menu() {
    LOG "Current Pager Configuration:"
    while IFS= read -r line; do
        if [[ $line =~ ^([a-zA-Z_]+)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            LOG "$name: $value"
        fi
    done < "$PAGER_CONFIG"
    
    LOG " "
    LOG "0) Back"
    LOG " "
    LOG "Waiting for user input..."
    
    WAIT_FOR_INPUT
}

# ====== Change settings: ======
# 1. name of setting
# 2. name of setting
# ...
# 0. Back
#
# Waiting for user input...

change_settings_menu() {
    LOG "===== Change Pager Configuration Settings: ======"
    # List all settings with numbers, and a 0 for going back to the main menu
    mapfile -t settings < "$PAGER_CONFIG"
    for i in "${!settings[@]}"; do
        if [[ ${settings[i]} =~ ^([a-zA-Z_]+)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            LOG "$((i + 1)) ) $name"
        fi
    done
    LOG "0) Back"
    LOG " "
    LOG "Waiting for user input..."
    WAIT_FOR_INPUT
    choice=$(NUMBER_PICKER "Select a setting to change:" 1)
    if [[ $choice -ge 1 && $choice -le ${#settings[@]} ]]; then
        if [[ ${settings[choice-1]} =~ ^([a-zA-Z_]+)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            current_value="${BASH_REMATCH[2]}"
            new_value=$(TEXT_PICKER "Enter new value for $name:" "$current_value")
            if [ -n "$new_value" ]; then
                # Update the temporary config file with the new value
                sed -i "s/^$name=.*/$name=$new_value/" "$TEMP_CONFIG"
                LOG "Setting '$name' updated to '$new_value' in temporary configuration."
                # Ask user if they want to apply changes or discard them
                if [ "$(CONFIRMATION_DIALOG "Do you want to apply the changes to the pager configuration?")" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                    LOG "User cancelled applying changes. Discarding changes and returning to menu." && rm -f "$TEMP_CONFIG" && return
                fi
                # Move the temporary config file to the actual config file to apply changes
                mv "$TEMP_CONFIG" "$PAGER_CONFIG"
                LOG "Changes applied to pager configuration."
            else
                LOG "No value entered. Returning to menu."
            fi
        else
            LOG "Invalid setting format. Returning to menu."
        fi
    elif [ $choice -eq 0 ]; then
        LOG "Returning to main menu."
    else
        LOG "Invalid choice. Returning to menu."
    fi
}

# ====== Exit: ======
# Changes:
# - setting: old value -> new value
# Are you sure you want to apply these changes?
#
# Waiting for user input...

exit_config_menu() {
    LOG "Exiting pager configuration management."
    # Check if the temporary config file exists, if it does, show the changes and ask the user if they want to apply them
    if [ -f "$TEMP_CONFIG" ]; then
        LOG "Changes:"
        diff "$PAGER_CONFIG" "$TEMP_CONFIG"
        if [ "$(CONFIRMATION_DIALOG "Do you want to apply these changes to the pager configuration?")" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            LOG "User cancelled applying changes. Discarding changes and exiting." && rm -f "$TEMP_CONFIG" && exit 0
        fi
        mv "$TEMP_CONFIG" "$PAGER_CONFIG"
        LOG "Changes applied to pager configuration. Exiting."
    else
        LOG "No changes to apply. Exiting."
    fi
}


main() {
    # Check if pager configuration file exists, if not create it with default values
    if [ ! -f "$PAGER_CONFIG" ]; then
        LOG "Pager configuration file not found. Creating default configuration..."
        echo "$STANDARD_CONFIG" > "$PAGER_CONFIG"
        LOG "Default pager configuration created at $PAGER_CONFIG."
    fi
    
    main_menu
}


