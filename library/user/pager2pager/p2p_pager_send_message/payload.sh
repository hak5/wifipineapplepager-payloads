#!/bin/bash
# Title: P2P - Send Message 
# Description: Send a message to other pagers using the P2P Pager system
# Author: ERR0RW0LF

CONFIRMATION_DIALOG "Do you want to send a message to other pagers using the P2P Pager system?" || {
    LOG "User cancelled sending message." 
    exit 0
}


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

LOG " "
LOG "Waiting for user input..."
WAIT_FOR_INPUT

# pick a network using a number
network_choice=$(NUMBER_PICKER "Select a network to send the message on:" 1 || {
    LOG "Invalid network choice. Exiting."
    exit 1
})
selected_network=$(echo $NETWORKS | awk -v choice=$network_choice '{print $choice}')
LOG "Selected Network: $selected_network"

# get message from user
MESSAGE=$(TEXT_PICKER "Enter the message to send:" "Hi" || {
    LOG "Invalid message. Exiting."
    exit 1
})

# Debug output
#LOG "[DEBUG] Current working directory: $(pwd)"
#LOG "[DEBUG] PATH: $PATH"
#LOG "[DEBUG] Python version: $(/mmc/usr/bin/python3 --version 2>&1)"
#LOG "[DEBUG] which python3: $(which python3 2>&1)"
#LOG "[DEBUG] LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
#LOG "[DEBUG] Selected network: $selected_network"
#LOG "[DEBUG] Message: $MESSAGE"
#LOG "[DEBUG] Running: LD_LIBRARY_PATH=/mmc/usr/lib:/mmc/lib /mmc/usr/bin/python3 /mmc/root/payloads/user/pager2pager/p2p_pager/p2p_pager_send.py --network \"$selected_network\" --message \"$MESSAGE\""

LD_LIBRARY_PATH=/mmc/usr/lib:/mmc/lib /mmc/usr/bin/python3 /mmc/root/payloads/user/pager2pager/p2p_pager/p2p_pager_send.py --network "$selected_network" --message "$MESSAGE"
LOG "Message sent to network $selected_network"
