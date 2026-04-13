#!/bin/bash
# Title: P2P - Manage Configuration
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
    #LOG "P2P Pager Configuration Management"
    #LOG "1) Get current configuration"
    #LOG "2) Reset to default values"
    #LOG "3) Change settings"
    #LOG "0) Exit"
    
    #LOG " "
    #LOG "Waiting for user input..."
    
    #WAIT_FOR_INPUT

    #choice=$(NUMBER_PICKER "Select an option:" 1)
    resp=$(LIST_PICKER "Main Menu" "Get current configuration" "Reset to default values" "Change settings" "Log" "About" "Exit" "Get current configuration")
    
    case $resp in
        "Get current configuration")
            #LOG "Current pager configuration:"
            current_config_menu
            ;;
        "Reset to default values")
            if [ "$(CONFIRMATION_DIALOG "Are you sure you want to reset the pager configuration to default values? This action cannot be undone.")" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                LOG "User cancelled resetting pager configuration." && return
            fi
            reset_pager_config
            ;;
        "Change settings")
            change_settings_menu
            ;;
        "Log")
            LOG red "To get back into the main menu press the A button"
            WAIT_FOR_BUTTON_PRESS "A"
            ;;
        "About")
            # Example of a nested list
            LIST_PICKER "About page" "Project by ERR0RW0LF" "Inspired by:" "@Hak5Darren" "Big thanks to you" "Darren for believing in" "this project and" "supporting it." "Where you can find me:" "Youtube: @3RR0RW0LF" "Discord: err0rw0lf" "<- Back" "<- Back"
            # Selection is ignored, so all list items are essentially "<- Back"
            ;;
        "Exit")
            resp=$(CONFIRMATION_DIALOG "Exit Payload?") || exit 1
            if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                exit 0
            fi
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
    # Build a selectable list of settings for LIST_PICKER
    mapfile -t settings < "$PAGER_CONFIG"
    menu_items=()
    setting_indices=()

    for i in "${!settings[@]}"; do
        if [[ ${settings[i]} =~ ^([a-zA-Z_]+)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            menu_items+=("$name: $value")
            setting_indices+=("$i")
        fi
    done

    if [ ${#menu_items[@]} -eq 0 ]; then
        LOG "No valid settings found. Returning to menu."
        return
    fi

    choice=$(LIST_PICKER "Change Settings" "${menu_items[@]}" "<- Back" "${menu_items[0]}")

    if [ "$choice" = "<- Back" ]; then
        LOG "Returning to main menu."
        exit_config_menu
        return
    fi

    selected_index=-1
    for i in "${!menu_items[@]}"; do
        if [ "${menu_items[i]}" = "$choice" ]; then
            selected_index="${setting_indices[i]}"
            break
        fi
    done

    if [ "$selected_index" -ge 0 ] && [[ ${settings[selected_index]} =~ ^([a-zA-Z_]+)=(.*)$ ]]; then
        name="${BASH_REMATCH[1]}"
        current_value="${BASH_REMATCH[2]}"
        new_value=$(TEXT_PICKER "Enter new value for $name:" "$current_value")
        if [ -n "$new_value" ]; then
            # Ensure a working copy exists before editing
            if [ ! -f "$TEMP_CONFIG" ]; then
                create_tmp_config
            fi
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
        LOG "Invalid setting selection. Returning to menu."
    fi
}

start_pager_service() {
    # Start the pager service in the background
    /etc/init.d/p2p_pager start &
    LOG green "P2P Pager service started."
}


stop_pager_service() {
    LOG "Stopping P2P Pager service..."
    /etc/init.d/p2p_pager stop
    LOG green "P2P Pager service stopped."
}

restart_pager_service() {
    LOG "Restarting P2P Pager service..."
    stop_pager_service
    start_pager_service
    LOG green "P2P Pager service restarted."
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
        LOG "Changes applied to pager configuration."
        LOG "Restarting pager service to apply new configuration..."
        restart_pager_service
        LOG "Pager service restarted with new configuration."
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
    while true; do
        main_menu
    done
}


main
