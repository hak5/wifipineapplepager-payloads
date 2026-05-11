#!/bin/bash
# Title: P2P - Send Message 
# Description: Send a message to other pagers using the P2P Pager system
# Author: ERR0RW0LF


if [ "$(CONFIRMATION_DIALOG "Do you want to send a message to other pagers using the P2P Pager system?")" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    LOG "User cancelled sending message." && exit 0
fi


P2P_CONFIG_DIR="/root/.p2p_pager"

# load network list
NETWORKS_CONF="$P2P_CONFIG_DIR/networks.conf"
if [ -f "$NETWORKS_CONF" ]; then
    source "$NETWORKS_CONF"
else
    LOG "Networks configuration file not found at $NETWORKS_CONF" && exit 1
fi

# build network list and let the user choose via LIST_PICKER
mapfile -t networks < "$NETWORKS_CONF"

if [ ${#networks[@]} -eq 0 ]; then
    LOG "No networks configured. Exiting." && exit 1
fi

selected_network=$(LIST_PICKER "Select network" "${networks[@]}" "<- Back" "${networks[0]}")

if [ "$selected_network" = "<- Back" ] || [ -z "$selected_network" ]; then
    LOG "No network selected. Exiting." && exit 0
fi

LOG "Selected Network: $selected_network"

# get message from user
MESSAGE=$(TEXT_PICKER "Enter the message to send:" "Hi" || {
    LOG "Invalid message. Exiting." && exit 1
})


LD_LIBRARY_PATH=/mmc/usr/lib:/mmc/lib /mmc/usr/bin/python3 /mmc/root/payloads/user/pager2pager/p2p_pager/p2p_pager_send.py --network "$selected_network" --message "$MESSAGE"
LOG "Message sent to network $selected_network"
