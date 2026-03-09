#!/bin/bash
# Title: goodportal Remove
# Description: Cleanup and remove goodportal configuration
# Purpose: Reverse all changes made by goodportal_configure payload
# Author: spencershepard (GRIMM)
# Version: 1.0

BRIDGE_MASTER="br-lan"
PORTAL_IP="172.16.52.1"
PORTAL_ROOT="/www/goodportal"

LOG "Stopping goodportal services..."

# Stop DNS hijacking process - try multiple methods
if [ -f /tmp/goodportal-dns.pid ]; then
    OLD_PID=$(cat /tmp/goodportal-dns.pid)
    if kill -0 $OLD_PID 2>/dev/null; then
        kill -9 $OLD_PID 2>/dev/null
        LOG "  Stopped DNS hijacking (PID: $OLD_PID)"
    fi
    rm -f /tmp/goodportal-dns.pid
fi

# Kill any dnsmasq listening on port 1053 (more aggressive)
DNSMASQ_PIDS=$(netstat -plant 2>/dev/null | grep ':1053' | awk '{print $NF}' | sed 's/\/dnsmasq//g' | grep -E '^[0-9]+$')
if [ -n "$DNSMASQ_PIDS" ]; then
    for pid in $DNSMASQ_PIDS; do
        kill -9 $pid 2>/dev/null
        LOG "  Killed dnsmasq PID: $pid"
    done
fi

# Final check: use pkill as last resort
pkill -9 -f "dnsmasq.*1053" 2>/dev/null

sleep 1

# Stop whitelist monitor process
if [ -f /tmp/goodportal-whitelist.pid ]; then
    OLD_PID=$(cat /tmp/goodportal-whitelist.pid)
    if kill -0 $OLD_PID 2>/dev/null; then
        kill $OLD_PID 2>/dev/null
        LOG "  Stopped whitelist monitor (PID: $OLD_PID)"
    fi
    rm -f /tmp/goodportal-whitelist.pid
fi

# Stop nginx
LOG "Stopping nginx..."
/etc/init.d/nginx stop 2>/dev/null || true
killall nginx 2>/dev/null || true
sleep 1

# Stop PHP-FPM
LOG "Stopping PHP-FPM..."
/etc/init.d/php8-fpm stop 2>/dev/null || /etc/init.d/php-fpm stop 2>/dev/null || true
sleep 1

LOG "Removing firewall redirect rules..."

# Remove GoodPortal firewall rules - delete from highest index to lowest to avoid index shifting
RULES_REMOVED=0

# Loop until no more GoodPortal rules found
while true; do
    # Find the last (highest index) redirect rule containing "GoodPortal" in the name
    LAST_INDEX=""
    LAST_NAME=""
    
    # Get all redirect sections
    for section in $(uci show firewall | grep "@redirect\[" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
        rule_name=$(uci get firewall.$section.name 2>/dev/null)
        if [ -n "$rule_name" ] && echo "$rule_name" | grep -qi "goodportal"; then
            # Extract the numeric index
            idx=$(echo "$section" | sed 's/@redirect\[\([0-9]*\)\].*/\1/')
            if [ -n "$idx" ]; then
                # Keep track of the highest index
                if [ -z "$LAST_INDEX" ] || [ "$idx" -gt "$LAST_INDEX" ]; then
                    LAST_INDEX="$idx"
                    LAST_NAME="$rule_name"
                fi
            fi
        fi
    done
    
    # If no more rules found, break
    if [ -z "$LAST_INDEX" ]; then
        break
    fi
    
    # Delete the highest index rule
    uci delete firewall.@redirect[$LAST_INDEX] 2>/dev/null
    LOG "  Removed rule: $LAST_NAME"
    RULES_REMOVED=$((RULES_REMOVED + 1))
done

if [ "$RULES_REMOVED" -gt 0 ]; then
    uci commit firewall
    LOG "  Removed $RULES_REMOVED firewall rule(s)"
else
    LOG "  No firewall rules found to remove"
fi

LOG "Restoring nginx configuration..."

# Restore original nginx config from backup
if [ -f /etc/nginx/nginx.conf.goodportal.bak ]; then
    mv /etc/nginx/nginx.conf.goodportal.bak /etc/nginx/nginx.conf
    LOG "  Restored nginx.conf from backup"
else
    LOG "  WARNING: Backup nginx.conf not found, skipping restore"
fi

# Re-enable UCI nginx management
uci set nginx.global.uci_enable=true 2>/dev/null || true
uci commit nginx 2>/dev/null || true
LOG "  Re-enabled UCI nginx management"

LOG "Re-enabling IPv6 on br-lan..."
sysctl -w net.ipv6.conf.br-lan.disable_ipv6=0 2>/dev/null || LOG "  IPv6 already enabled or not available"

LOG "Cleaning up temporary files..."

# Remove temporary files
rm -f /tmp/goodportal-dns.pid
rm -f /tmp/goodportal-whitelist.pid
rm -f /tmp/goodportal_whitelist.txt
rm -f /tmp/goodportal_processed.txt
rm -f /tmp/goodportal_credentials.log
rm -f /tmp/goodportal_whitelist_monitor.sh
LOG "  Temporary files removed"

# Ask user if they want to remove portal directory
resp=$(CONFIRMATION_DIALOG "Remove /www/goodportal directory?\n(This will delete all portal files, including custom portals you may have added.) Decline to make future reconfiguration faster.")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "  Keeping /www/goodportal directory"
        ;;
    *)
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            rm -rf "$PORTAL_ROOT"
            LOG "  Removed $PORTAL_ROOT directory"
        else
            LOG "  Keeping /www/goodportal directory"
        fi
        ;;
esac

LOG "Restarting services..."

# Restart firewall to apply rule removals
/etc/init.d/firewall restart
LOG "  Firewall restarted"

# Restart nginx with original config
/etc/init.d/nginx start 2>/dev/null || true
LOG "  Nginx restarted with original config"

LOG "Verifying cleanup..."

# Check if DNS hijacking is stopped
if netstat -plant 2>/dev/null | grep -q ':1053'; then
    LOG "  WARNING: DNS hijacking still active on port 1053"
else
    LOG green "  SUCCESS: DNS hijacking stopped"
fi

# Check if firewall rules are removed
RULE_COUNT=$(uci show firewall | grep -c "GoodPortal" || true)
if [ "$RULE_COUNT" -eq 0 ]; then
    LOG green "  SUCCESS: All firewall rules removed"
else
    LOG red "  ERROR: $RULE_COUNT GoodPortal rules still present"
    exit 1
fi

# Check IPv6 status
IPV6_STATUS=$(sysctl net.ipv6.conf.br-lan.disable_ipv6 2>/dev/null | awk '{print $NF}')
if [ "$IPV6_STATUS" = "0" ]; then
    LOG green "  SUCCESS: IPv6 re-enabled on br-lan"
else
    ERROR_DIALOG "  WARNING: IPv6 may still be disabled on br-lan"
fi

LOG yellow "NOTE: nginx and PHP packages will remain installed. Running the goodportal Configure payload again will be MUCH faster next time!"

exit 0
