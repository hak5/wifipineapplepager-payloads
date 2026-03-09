#!/bin/bash
# Title: goodportal Clear Whitelist
# Description: Clear all whitelisted MAC addresses
# Author: spencershepard (GRIMM)
# Version: 1.0

LOG "Clearing goodportal whitelist..."

# Clear whitelist and processed files
rm -f /tmp/goodportal_whitelist.txt
rm -f /tmp/goodportal_processed.txt

LOG "  Cleared whitelist files"

# Restart firewall to remove all temporary nftables rules
LOG "  Restarting firewall to clear temporary bypass rules..."
/etc/init.d/firewall restart

LOG "SUCCESS: Whitelist cleared!"
LOG "  All clients will be redirected to captive portal again"

exit 0
