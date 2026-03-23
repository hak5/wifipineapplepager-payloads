#!/bin/bash
# Title: P2P - Manage Pager Networks
# Description: Manage the networks available to the P2P Pager system
# Author: ERR0RW0LF

P2P_CONFIG_DIR="$HOME/.p2p_pager"
NETWORKS_CONF="$P2P_CONFIG_DIR/networks.conf"

main() {
    LOG "P2P Pager Network Management"
    LOG "1) Add Network"
    LOG "2) Remove Network"
    LOG "3) List Networks"
    LOG "4) Exit"
    
    choice=$(NUMBER_PICKER "Select an option:" 1)
    
    case $choice in
        1)
            network_name=$(TEXT_PICKER "Enter the name of the network to add:")
            if [[ -n "$network_name" ]]; then
                echo "$network_name" >> "$NETWORKS_CONF"
                LOG "Network '$network_name' added."
            else
                LOG "No network name entered. Returning to menu."
            fi
            ;;
        2)
            if [ -f "$NETWORKS_CONF" ]; then
                mapfile -t networks < "$NETWORKS_CONF"
                if [ ${#networks[@]} -eq 0 ]; then
                    LOG "No networks to remove. Returning to menu."
                    return
                fi
                
                LOG "Available Networks:"
                for i in "${!networks[@]}"; do
                    LOG "$((i + 1)) ) ${networks[i]}"
                done
                
                remove_choice=$(NUMBER_PICKER "Select a network to remove:" 1)
                if [[ $remove_choice -ge 1 && $remove_choice -le ${#networks[@]} ]]; then
                    sed -i "${remove_choice}d" "$NETWORKS_CONF"
                    LOG "Network '${networks[remove_choice-1]}' removed."
                else
                    LOG "Invalid choice. Returning to menu."
                fi
            else
                LOG "No networks configuration found. Returning to menu."
            fi
            ;;
        3)
            if [ -f "$NETWORKS_CONF" ]; then
                LOG "Configured Networks:"
                cat "$NETWORKS_CONF"
            else
                LOG "No networks configured."
            fi
            ;;
        4)
            LOG "Exiting P2P Pager Network Management."
            exit 0
            ;;
        *)
            LOG "Invalid choice. Please select a valid option."
            ;;
    esac
}

while true; do
    main
done