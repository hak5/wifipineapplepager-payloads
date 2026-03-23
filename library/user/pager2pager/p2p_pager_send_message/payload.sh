#!/bin/bash
# Title: P2P - Send Message 
# Description: Send a message to other pagers using the P2P Pager system
# Author: ERR0RW0LF

CONFIRMATION_DIALOG "Do you want to send a message to other pagers using the P2P Pager system?" || exit 0

P2P_CONFIG_DIR="/root/.p2p_pager"

# load network list
NETWORKS_CONF="$P2P_CONFIG_DIR/networks.conf"
if [ -f "$NETWORKS_CONF" ]; then
    source "$NETWORKS_CONF"
else
    LOG "Networks configuration file not found at $NETWORKS_CONF" && exit 1
fi

# give user a list of available networks to choose from counting from 1 to n
LOG "Available Networks:"
i=1
NETWORKS=$(cat "$NETWORKS_CONF")

for network in $NETWORKS; do
    LOG "$i) $network"
    i=$((i + 1))
done

# pick a network using a number
network_choice=$(NUMBER_PICKER "Select a network to send the message on:" 1)
selected_network=$(echo $NETWORKS | awk -v choice=$network_choice '{print $choice}')
LOG "Selected Network: $selected_network"

# get message from user
MESSAGE=$(TEXT_PICKER "Enter the message to send:" "Hi")

python3 /library/user/pager2pager/p2p_pager/p2p_pager_send.py --network "$selected_network" --message "$MESSAGE"
LOG "Message sent to network $selected_network."
