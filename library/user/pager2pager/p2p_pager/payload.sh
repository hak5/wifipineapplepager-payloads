#!/bin/bash
# Title: Manage P2P Pager Service
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
decay_time=300
beacon_interval=102
beacon_uptime=30
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
    LOG " "
    LOG "===== P2P Pager Service Management ====="
    LOG ""
    LOG "U) Install / Uninstall / Reinstall P2P Pager Service"
    LOG "D) Start / Stop P2P Pager Service"
    LOG "R) Restart P2P Pager Service"
    LOG "L) Exit"
    LOG " "
    LOG " "
    choice=$(WAIT_FOR_INPUT)

    case $choice in
        UP)
            LOG "You chose to Install / Uninstall P2P Pager Service."
            LOG "U) Install P2P Pager Service"
            LOG "D) Uninstall P2P Pager Service"
            LOG "R) Reinstall P2P Pager Service"
            LOG " "
            sub_choice=$(WAIT_FOR_INPUT)
            case $sub_choice in
                UP)
                    install_pager_service
                    ;;
                DOWN)
                    uninstall_pager_service
                    ;;
                RIGHT)
                    reinstall_pager_service
                    ;;
                *)
                    LOG "Invalid choice. Exiting."
                    ;;
            esac
            ;;
        DOWN)
            LOG "You chose to Start / Stop P2P Pager Service."
            LOG "U) Start P2P Pager Service"
            LOG "D) Stop P2P Pager Service"
            LOG " "
            sub_choice=$(WAIT_FOR_INPUT)
            case $sub_choice in
                UP)
                    start_pager_service
                    ;;
                DOWN)
                    stop_pager_service
                    ;;
                *)
                    LOG "Invalid choice. Exiting."
                    ;;
            esac
            ;;
        RIGHT)
            restart_pager_service
            ;;
        LEFT)
            LOG "Exiting P2P Pager Service Management."
            exit 0
            ;;
        *)
            LOG "Invalid choice. Exiting."
            ;;
    esac
}


while true; do
    main
done