#!/bin/bash
# Title: P2P - Manage Networks
# Description: Manage the networks available to the P2P Pager system
# Author: ERR0RW0LF

P2P_CONFIG_DIR="/root/.p2p_pager"
NETWORKS_CONF="$P2P_CONFIG_DIR/networks.conf"

main() {
    resp=$(LIST_PICKER "Network Management" "Add Network" "Remove Network" "List Networks" "Exit" "Add Network")

    case $resp in
        "Add Network")
            network_name=$(TEXT_PICKER "Enter the name of the network to add:" "")
            if [[ -n "$network_name" ]]; then
                echo "$network_name" >> "$NETWORKS_CONF"
                LOG "Network '$network_name' added."
            else
                LOG "No network name entered. Returning to menu."
            fi
            ;;
        "Remove Network")
            if [ -f "$NETWORKS_CONF" ]; then
                mapfile -t networks < "$NETWORKS_CONF"
                if [ ${#networks[@]} -eq 0 ]; then
                    LOG "No networks to remove. Returning to menu."
                    return
                fi
                
                selected_network=$(LIST_PICKER "Select a network to remove:" "${networks[@]}" "<- Back" "${networks[0]}")
                
                if [ "$selected_network" = "<- Back" ] || [ -z "$selected_network" ]; then
                    LOG "No network selected. Returning to menu."
                    return
                fi
                
                sed -i "/^${selected_network}$/d" "$NETWORKS_CONF"
                LOG "Network '$selected_network' removed."
            else
                LOG "No networks configuration found. Returning to menu."
            fi
            ;;
        "List Networks")
            if [ -f "$NETWORKS_CONF" ]; then
                LOG "Configured Networks:"
                networks=()
                while IFS= read -r line; do
                    networks+=("$line")
                done < "$NETWORKS_CONF"
                for network in "${networks[@]}"; do
                    LOG " - $network"
                done
            else
                LOG "No networks configured."
            fi
            LOG red "To get back into the main menu press the A button"
            WAIT_FOR_BUTTON_PRESS "A"
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

while true; do
    main
done