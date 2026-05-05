#!/bin/bash
# Title: P2P - Manage Service
# Description: This script installs the P2P Pager service and manages its state (start, stop, restart, enable, disable).
# Author: ERR0RW0LF
# Inspiration: Darren Kitchen

# Important locations for services
SERVICE_LOCATION="/etc/init.d/p2p_pager"
BIN_LOCATION="/usr/bin/p2p_pager"
START_SCRIPT_LOCATION="/usr/bin/start_p2p_pager.sh"


P2P_CONFIG_DIR="/root/.p2p_pager"


start_pager_service() {
    # Start the pager service in the background
    /etc/init.d/p2p_pager start &
    LOG green "P2P Pager service started."
}

enable_pager_service() {
    # Enable the pager service to start on boot
    /etc/init.d/p2p_pager enable &
    LOG green "P2P Pager service enabled to start on boot."
}


configure_networks() {
    # Configure necessary network settings
    LOG green "Configuring network settings for P2P Pager..."
    NETWORK_CONFIG_FILE="$P2P_CONFIG_DIR/networks.conf"
    if [ ! -f "$NETWORK_CONFIG_FILE" ]; then
        touch "$NETWORK_CONFIG_FILE"
    fi
    
}

restart_pager_service() {
    LOG "Restarting P2P Pager service..."
    stop_pager_service
    start_pager_service
    LOG green "P2P Pager service restarted."
}

stop_pager_service() {
    LOG "Stopping P2P Pager service..."
    /etc/init.d/p2p_pager stop
    LOG green "P2P Pager service stopped."
}

disable_pager_service() {
    LOG "Disabling P2P Pager service from starting on boot..."
    /etc/init.d/p2p_pager disable
    LOG green "P2P Pager service disabled from starting on boot."
}



install_pager_service() {
    LOG "Installing P2P Pager service..."

    # Install python if not installed
    if ! command -v python3 &> /dev/null; then
        LOG "Python3 not found, installing..."
        resp=$(CONFIRMATION_DIALOG "Python3 is required for the P2P Pager service. Do you want to install it?") || exit 1
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            LOG "Updating package lists and installing Python3..."
            opkg update
            opkg install python3
        fi
    fi

    # Copy service file to init.d
    LOG "Copying service files..."
    cp init_p2p_pager "$SERVICE_LOCATION"
    chmod +x "$SERVICE_LOCATION"
    LOG green "Service file copied to $SERVICE_LOCATION."

    # Copy pager python script to bin location
    LOG "Copying pager script..."
    cp p2p_pager.py "$BIN_LOCATION"
    chmod +x "$BIN_LOCATION"
    LOG green "Pager script copied to $BIN_LOCATION."

    # Copy start script
    LOG "Copying start script..."
    cp start_p2p_pager.sh "$START_SCRIPT_LOCATION"
    chmod +x "$START_SCRIPT_LOCATION"
    LOG green "Start script copied to $START_SCRIPT_LOCATION."

    # Add Network file if needed
    # cp network_file_location /etc/config/networks
    mkdir -p "$P2P_CONFIG_DIR"
    touch "$P2P_CONFIG_DIR/networks.conf"
    touch "$P2P_CONFIG_DIR/pager.conf"

    # If pager.conf is empty, add default values
    if [ ! -s "$P2P_CONFIG_DIR/pager.conf" ]; then
        LOG "Creating default pager configuration..."
        echo """
decay_time=180
beacon_interval=102
beacon_uptime=60
ssid_prefix=P2PAGER
channel=6
max_message_length=50
message_prefix=MSG:
decay_prefix=DECAY:
""" > "$P2P_CONFIG_DIR/pager.conf"
        LOG "Default pager configuration created at $P2P_CONFIG_DIR/pager.conf"
    fi
    


    # Default network
    #echo """
    #open_net_aifouhjnuqi2r89hnugd
    #""" > "$P2P_CONFIG_DIR/networks.conf"


    start_pager_service
    enable_pager_service
    configure_networks
    LOG green "P2P Pager service installation complete."
}

uninstall_pager_service() {
    

    LOG "Uninstalling P2P Pager service..."
    # Stop the pager service
    stop_pager_service

    # Remove from startup
    disable_pager_service

    # Remove service file
    rm -f "$SERVICE_LOCATION"


    # Add any additional cleanup commands here
    LOG green "P2P Pager service uninstallation complete."
}

reinstall_pager_service() {
    LOG yellow "Reinstalling P2P Pager service..."
    LOG " "
    uninstall_pager_service
    install_pager_service
    LOG " "
    LOG green "P2P Pager service reinstallation complete."
}


# Menu
main() {
    resp=$(LIST_PICKER "Main Menu" "Install" "Uninstall" "Reinstall" "Start" "Stop" "Restart" "Log" "About" "Exit" "Install")

    case "$resp" in
        "Install")
            install_pager_service
            ;;
        "Uninstall")
            uninstall_pager_service
            ;;
        "Reinstall")
            reinstall_pager_service
            ;;
        "Start")
            start_pager_service
            ;;
        "Stop")
            stop_pager_service
            ;;
        "Restart")
            restart_pager_service
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
    esac

}


while true; do
    main
done