#!/bin/bash
# Name: Set Evil Portal Interface
# Description: Configures Evil Portal to apply to Evil WPA, Open AP, or all interfaces
# Author: PentestPlaybook
# Version: 2.0
# Category: Evil Portal

PORTAL_IP_EVIL="10.0.0.1"
PORTAL_IP_LAN="172.16.52.1"
BRIDGE_IF_EVIL="br-evil"
BRIDGE_IF_LAN="br-lan"

# ====================================================================
# STEP 1: Select target interface
# ====================================================================
# Detect current Evil Portal interface for default selection
DISPLAY_CURRENT=$(grep -o 'iifname "[^"]*"' /etc/init.d/evilportal 2>/dev/null | head -1 | grep -o '"[^"]*"' | tr -d '"')
DISPLAY_IFACE=""
if [ "$DISPLAY_CURRENT" = "br-evil" ]; then
    if uci show wireless.wlan0wpa.network 2>/dev/null | grep -q "evil"; then
        DISPLAY_IFACE="wlan0wpa"
    elif uci show wireless.wlan0open.network 2>/dev/null | grep -q "evil"; then
        DISPLAY_IFACE="wlan0open"
    fi
fi

if [ "$DISPLAY_IFACE" = "wlan0wpa" ]; then
    DEFAULT="Evil WPA (wlan0wpa)"
elif [ "$DISPLAY_IFACE" = "wlan0open" ]; then
    DEFAULT="Open AP (wlan0open)"
else
    DEFAULT="All Interfaces (br-lan)"
fi

CHOICE=$(LIST_PICKER "Select Interface" "Evil WPA (wlan0wpa)" "Open AP (wlan0open)" "All Interfaces (br-lan)" "$DEFAULT")
if [ $? -ne 0 ]; then
    PROMPT "Selection cancelled"
    exit 0
fi

case "$CHOICE" in
    "Evil WPA (wlan0wpa)")
        TARGET_IFACE="wlan0wpa"
        OTHER_IFACE="wlan0open"
        TARGET_MODE="isolated"
        PORTAL_IP="${PORTAL_IP_EVIL}"
        FIREWALL_SRC="evil"
        ;;
    "Open AP (wlan0open)")
        TARGET_IFACE="wlan0open"
        OTHER_IFACE="wlan0wpa"
        TARGET_MODE="isolated"
        PORTAL_IP="${PORTAL_IP_EVIL}"
        FIREWALL_SRC="evil"
        ;;
    "All Interfaces (br-lan)")
        TARGET_IFACE=""
        OTHER_IFACE=""
        TARGET_MODE="lan"
        PORTAL_IP="${PORTAL_IP_LAN}"
        FIREWALL_SRC="lan"
        ;;
    *)
        ERROR_DIALOG "Invalid selection"
        exit 1
        ;;
esac

LOG "Selected mode: ${TARGET_MODE}"
[ -n "$TARGET_IFACE" ] && LOG "Selected interface: ${TARGET_IFACE}"

# ====================================================================
# STEP 2: Detect current state
# ====================================================================
LOG "Step 2: Detecting current state..."

CURRENT_BRIDGE=$(grep -o 'iifname "[^"]*"' /etc/init.d/evilportal 2>/dev/null | head -1 | grep -o '"[^"]*"' | tr -d '"')
CURRENT_IFACE=""

if [ "$CURRENT_BRIDGE" = "br-evil" ]; then
    if uci show wireless.wlan0wpa.network 2>/dev/null | grep -q "evil"; then
        CURRENT_IFACE="wlan0wpa"
    elif uci show wireless.wlan0open.network 2>/dev/null | grep -q "evil"; then
        CURRENT_IFACE="wlan0open"
    fi
fi

LOG "Current bridge: ${CURRENT_BRIDGE}"
LOG "Current interface: ${CURRENT_IFACE:-none}"

# ====================================================================
# STEP 3: Check if already in desired state
# ====================================================================
if [ "$TARGET_MODE" = "isolated" ]; then
    if [ "$CURRENT_BRIDGE" = "br-evil" ] && [ "$CURRENT_IFACE" = "$TARGET_IFACE" ]; then
        ALERT "Evil Portal is already configured for ${TARGET_IFACE}. No changes needed."
        exit 0
    fi
elif [ "$TARGET_MODE" = "lan" ]; then
    if [ "$CURRENT_BRIDGE" = "br-lan" ]; then
        ALERT "Evil Portal is already configured for all interfaces. No changes needed."
        exit 0
    fi
fi

# ====================================================================
# STEP 4: Verify internet connectivity
# ====================================================================
LOG "Step 4: Verifying internet connectivity..."
if ! ping -c1 8.8.8.8 &>/dev/null; then
    LOG "ERROR: No internet connectivity detected"
    LOG "Enable WiFi Client Mode and try again"
    exit 1
fi
LOG "SUCCESS: Internet connectivity confirmed"

# ====================================================================
# STEP 5: Stop Evil Portal
# ====================================================================
LOG "Step 5: Stopping Evil Portal..."
/etc/init.d/evilportal stop
sleep 3

if pgrep nginx > /dev/null; then
    LOG "ERROR: Failed to stop nginx"
    exit 1
fi
LOG "SUCCESS: Evil Portal stopped"

# ====================================================================
# STEP 6: Remove existing Evil Portal NAT rules
# ====================================================================
LOG "Step 6: Removing existing Evil Portal NAT rules..."
while uci show firewall | grep -q "Evil Portal"; do
    LAST_INDEX=$(uci show firewall | grep "redirect\[" | grep "Evil Portal" | tail -n1 | sed 's/.*redirect\[\([0-9]*\)\].*/\1/')
    if [ -n "$LAST_INDEX" ]; then
        uci delete firewall.@redirect[$LAST_INDEX]
    else
        break
    fi
done
uci commit firewall
LOG "SUCCESS: Existing NAT rules removed"

# ====================================================================
# STEP 7: Update network configuration
# ====================================================================
LOG "Step 7: Updating network configuration..."

# Save any pending SSID/key changes across all interfaces before any wireless commits
# uci changes wireless output format: "wireless.wlan0wpa.ssid='value'" - extract value after =
PENDING_SSID_WPA=$(uci changes wireless | grep "^wireless\.wlan0wpa\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
PENDING_KEY_WPA=$(uci changes wireless | grep "^wireless\.wlan0wpa\.key=" | cut -d= -f2- | tr -d "'" | tail -1)
PENDING_SSID_OPEN=$(uci changes wireless | grep "^wireless\.wlan0open\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
PENDING_KEY_OPEN=$(uci changes wireless | grep "^wireless\.wlan0open\.key=" | cut -d= -f2- | tr -d "'" | tail -1)
PENDING_SSID_MGMT=$(uci changes wireless | grep "^wireless\.wlan0mgmt\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
PENDING_KEY_MGMT=$(uci changes wireless | grep "^wireless\.wlan0mgmt\.key=" | cut -d= -f2- | tr -d "'" | tail -1)

LOG "Pending SSID WPA: ${PENDING_SSID_WPA:-none}"
LOG "Pending KEY WPA: ${PENDING_KEY_WPA:+set}"
LOG "Pending SSID OPEN: ${PENDING_SSID_OPEN:-none}"
LOG "Pending KEY OPEN: ${PENDING_KEY_OPEN:+set}"
LOG "Pending SSID MGMT: ${PENDING_SSID_MGMT:-none}"
LOG "Pending KEY MGMT: ${PENDING_KEY_MGMT:+set}"

# Revert all pending SSID/key changes from the buffer
[ -n "$PENDING_SSID_WPA" ] && uci revert wireless.wlan0wpa.ssid
[ -n "$PENDING_KEY_WPA" ] && uci revert wireless.wlan0wpa.key
[ -n "$PENDING_SSID_OPEN" ] && uci revert wireless.wlan0open.ssid
[ -n "$PENDING_KEY_OPEN" ] && uci revert wireless.wlan0open.key
[ -n "$PENDING_SSID_MGMT" ] && uci revert wireless.wlan0mgmt.ssid
[ -n "$PENDING_KEY_MGMT" ] && uci revert wireless.wlan0mgmt.key

if [ "$TARGET_MODE" = "lan" ]; then
    # STATE: Convert back to br-lan
    LOG "Converting back to br-lan (all interfaces)..."

# Move current interface back to br-lan ports and remove from br-evil
    if [ -n "$CURRENT_IFACE" ]; then
        uci del_list network.br_evil.ports="${CURRENT_IFACE}"
        uci add_list network.brlan.ports="${CURRENT_IFACE}"
        uci commit network
        uci set wireless.${CURRENT_IFACE}.network='lan'
        uci commit wireless
    fi

    # Remove evil network and br-evil device
    LOG "Removing br-evil and evil network..."
    uci delete network.evil 2>/dev/null
    uci delete network.br_evil 2>/dev/null
    uci commit network

    # Remove evil DHCP config
    LOG "Removing evil DHCP config..."
    uci delete dhcp.evil 2>/dev/null
    uci commit dhcp

    # Remove evil firewall zone
    LOG "Removing evil firewall zone..."
    while uci show firewall | grep -q "name='evil'"; do
        LAST_ZONE=$(uci show firewall | grep "name='evil'" | sed 's/firewall\.\@zone\[\([0-9]*\)\].*/\1/')
        if [ -n "$LAST_ZONE" ]; then
            uci delete firewall.@zone[$LAST_ZONE]
        else
            break
        fi
    done

    # Remove evil forwarding rule
    LOG "Removing evil forwarding rule..."
    while uci show firewall | grep -q "src='evil'"; do
        LAST_FWD=$(uci show firewall | grep "src='evil'" | sed 's/firewall\.\@forwarding\[\([0-9]*\)\].*/\1/')
        if [ -n "$LAST_FWD" ]; then
            uci delete firewall.@forwarding[$LAST_FWD]
        else
            break
        fi
    done
    uci commit firewall

    # Update init script back to br-lan and 172.16.52.1
    LOG "Updating init script..."
    sed -i 's|iifname "br-evil"|iifname "br-lan"|g' /etc/init.d/evilportal
    sed -i 's|dnat ip to 10.0.0.1:|dnat ip to 172.16.52.1:|g' /etc/init.d/evilportal
    sed -i 's|dnat ip to 10.0.0.1|dnat ip to 172.16.52.1|g' /etc/init.d/evilportal
    sed -i "s|firewall.@redirect\[-1\].src='evil'|firewall.@redirect[-1].src='lan'|g" /etc/init.d/evilportal
    sed -i "s|firewall.@redirect\[-1\].dest_ip='10.0.0.1'|firewall.@redirect[-1].dest_ip='172.16.52.1'|g" /etc/init.d/evilportal

elif [ "$CURRENT_BRIDGE" = "br-evil" ] && [ -n "$CURRENT_IFACE" ]; then
    # STATE: br-evil exists with wrong interface - swap interfaces
    LOG "Swapping ${CURRENT_IFACE} for ${TARGET_IFACE} on br-evil..."

    # Move TARGET_IFACE from br-lan to br-evil and CURRENT_IFACE back to br-lan
    uci del_list network.brlan.ports="${TARGET_IFACE}"
    uci del_list network.br_evil.ports="${CURRENT_IFACE}"
    uci add_list network.brlan.ports="${CURRENT_IFACE}"
    uci add_list network.br_evil.ports="${TARGET_IFACE}"
    uci commit network

    # Reassign wireless network assignments
    uci del wireless.${CURRENT_IFACE}.network
    uci set wireless.${CURRENT_IFACE}.network='lan'
    uci set wireless.${TARGET_IFACE}.network='evil'
    uci commit wireless

else
    # STATE: br-lan - full conversion to br-evil
    LOG "Converting from br-lan to br-evil with ${TARGET_IFACE}..."

    # Create br-evil bridge and evil network interface via UCI batch (no file append)
    uci batch << UCIEOF
set network.br_evil=device
set network.br_evil.name='br-evil'
set network.br_evil.type='bridge'
set network.evil=interface
set network.evil.device='br-evil'
set network.evil.proto='static'
set network.evil.ipaddr='10.0.0.1'
set network.evil.netmask='255.255.255.0'
UCIEOF

    # Configure DHCP for evil network via UCI batch
    uci batch << UCIEOF
set dhcp.evil=dhcp
set dhcp.evil.interface='evil'
set dhcp.evil.start='100'
set dhcp.evil.limit='150'
set dhcp.evil.leasetime='1h'
UCIEOF
    uci commit dhcp

    # Remove target interface from br-lan and add to br-evil
    uci del_list network.brlan.ports="${TARGET_IFACE}"
    uci add_list network.br_evil.ports="${TARGET_IFACE}"
    uci commit network

    # Assign target interface to evil network and explicitly assign other interface to lan
    uci set wireless.${TARGET_IFACE}.network='evil'
    uci set wireless.${OTHER_IFACE}.network='lan'
    uci commit wireless

    # Create evil firewall zone and forwarding rule
    uci add firewall zone
    uci set firewall.@zone[-1].name='evil'
    uci set firewall.@zone[-1].network='evil'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='evil'
    uci set firewall.@forwarding[-1].dest='wan'
    uci commit firewall

    # Update init script
    sed -i 's|iifname "br-lan"|iifname "br-evil"|g' /etc/init.d/evilportal
    sed -i 's|dnat ip to 172.16.52.1:|dnat ip to 10.0.0.1:|g' /etc/init.d/evilportal
    sed -i 's|dnat ip to 172.16.52.1|dnat ip to 10.0.0.1|g' /etc/init.d/evilportal
    sed -i "s|firewall.@redirect\[-1\].src='lan'|firewall.@redirect[-1].src='evil'|g" /etc/init.d/evilportal
    sed -i "s|firewall.@redirect\[-1\].dest_ip='172.16.52.1'|firewall.@redirect[-1].dest_ip='10.0.0.1'|g" /etc/init.d/evilportal
fi

LOG "SUCCESS: Network configuration updated"

# ====================================================================
# STEP 8: Add new Evil Portal NAT rules
# ====================================================================
LOG "Step 8: Adding new Evil Portal NAT rules..."
uci add firewall redirect
uci set firewall.@redirect[-1].name='Evil Portal HTTPS'
uci set firewall.@redirect[-1].src="${FIREWALL_SRC}"
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='443'
uci set firewall.@redirect[-1].dest_ip="${PORTAL_IP}"
uci set firewall.@redirect[-1].dest_port='80'
uci set firewall.@redirect[-1].target='DNAT'

uci add firewall redirect
uci set firewall.@redirect[-1].name='Evil Portal HTTP'
uci set firewall.@redirect[-1].src="${FIREWALL_SRC}"
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='80'
uci set firewall.@redirect[-1].dest_ip="${PORTAL_IP}"
uci set firewall.@redirect[-1].dest_port='80'
uci set firewall.@redirect[-1].target='DNAT'

uci add firewall redirect
uci set firewall.@redirect[-1].name='Evil Portal DNS TCP'
uci set firewall.@redirect[-1].src="${FIREWALL_SRC}"
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='53'
uci set firewall.@redirect[-1].dest_ip="${PORTAL_IP}"
uci set firewall.@redirect[-1].dest_port='5353'
uci set firewall.@redirect[-1].target='DNAT'

uci add firewall redirect
uci set firewall.@redirect[-1].name='Evil Portal DNS UDP'
uci set firewall.@redirect[-1].src="${FIREWALL_SRC}"
uci set firewall.@redirect[-1].proto='udp'
uci set firewall.@redirect[-1].src_dport='53'
uci set firewall.@redirect[-1].dest_ip="${PORTAL_IP}"
uci set firewall.@redirect[-1].dest_port='5353'
uci set firewall.@redirect[-1].target='DNAT'

uci commit firewall
LOG "SUCCESS: New NAT rules added"

# ====================================================================
# STEP 9: Apply network changes
# ====================================================================
LOG "Step 9: Applying network changes..."
/etc/init.d/network restart
sleep 10
wifi
LOG "Waiting for network connectivity..."
until ping -c1 8.8.8.8 &>/dev/null; do sleep 2; done
LOG "SUCCESS: Network connectivity restored"

# ====================================================================
# STEP 10: Restart firewall
# ====================================================================
LOG "Step 10: Restarting firewall..."
/etc/init.d/firewall restart
LOG "SUCCESS: Firewall restarted"

# ====================================================================
# STEP 11: Start Evil Portal
# ====================================================================
LOG "Step 11: Starting Evil Portal..."
/etc/init.d/evilportal start
sleep 5

if ! pgrep nginx > /dev/null; then
    LOG "ERROR: nginx failed to start"
    exit 1
fi

if ! pgrep -f "evilportal-whitelist-daemon" > /dev/null; then
    LOG "WARNING: Whitelist daemon not running"
fi

if ! pgrep -f "dnsmasq.*5353" > /dev/null; then
    LOG "WARNING: DNS spoof daemon not running"
fi

LOG "SUCCESS: Evil Portal started"

# ====================================================================
# STEP 12: Bring up target interface (isolated mode only)
# ====================================================================
if [ "$TARGET_MODE" = "isolated" ]; then
    LOG "Step 12: Bringing up ${TARGET_IFACE}..."
    uci set wireless.${TARGET_IFACE}.disabled='0'
    uci commit wireless
    wifi reload
    LOG "Waiting for ${TARGET_IFACE} to come up..."
    WAIT_COUNT=0
    until ip link show ${TARGET_IFACE} 2>/dev/null | grep -q "UP"; do
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 1))
        if [ $WAIT_COUNT -ge 15 ]; then
            LOG "ERROR: ${TARGET_IFACE} failed to come up after 30 seconds"
            exit 1
        fi
    done
    sleep 5
    LOG "Step 12: Restarting network to assign br-evil IP..."
    /etc/init.d/network restart
    sleep 10
    LOG "Waiting for network connectivity..."
    until ping -c1 8.8.8.8 &>/dev/null; do sleep 2; done
    LOG "SUCCESS: Network connectivity restored"
fi

# Re-stage all pending SSID/key changes without committing
# Done here to ensure they are not caught by any earlier uci commit wireless
[ -n "$PENDING_SSID_WPA" ] && uci set wireless.wlan0wpa.ssid="$PENDING_SSID_WPA"
[ -n "$PENDING_KEY_WPA" ] && uci set wireless.wlan0wpa.key="$PENDING_KEY_WPA"
[ -n "$PENDING_SSID_OPEN" ] && uci set wireless.wlan0open.ssid="$PENDING_SSID_OPEN"
[ -n "$PENDING_KEY_OPEN" ] && uci set wireless.wlan0open.key="$PENDING_KEY_OPEN"
[ -n "$PENDING_SSID_MGMT" ] && uci set wireless.wlan0mgmt.ssid="$PENDING_SSID_MGMT"
[ -n "$PENDING_KEY_MGMT" ] && uci set wireless.wlan0mgmt.key="$PENDING_KEY_MGMT"

# Note: pending SSID/key changes are restaged but not applied until next wifi reload or reboot

# ====================================================================
# STEP 13: Verify
# ====================================================================
LOG "Step 13: Verifying configuration..."

LOG "Verifying NAT rules..."
if nft list ruleset 2>/dev/null | grep -q "dnat ip to ${PORTAL_IP}"; then
    LOG "SUCCESS: NAT rules configured"
else
    LOG "ERROR: NAT rules not found"
    exit 1
fi

if [ "$TARGET_MODE" = "isolated" ]; then
    LOG "Verifying interface network assignment..."
    if uci show wireless.${TARGET_IFACE}.network 2>/dev/null | grep -q "evil"; then
        LOG "SUCCESS: ${TARGET_IFACE} assigned to evil network"
    else
        LOG "ERROR: ${TARGET_IFACE} not assigned to evil network"
        exit 1
    fi

    LOG "Verifying OTHER_IFACE network assignment..."
    if uci show wireless.${OTHER_IFACE}.network 2>/dev/null | grep -q "lan"; then
        LOG "SUCCESS: ${OTHER_IFACE} assigned to lan network"
    else
        LOG "ERROR: ${OTHER_IFACE} not assigned to lan network"
        exit 1
    fi

    LOG "Verifying br-evil exists..."
    if uci show network | grep -q "name='br-evil'"; then
        LOG "SUCCESS: br-evil bridge exists"
    else
        LOG "ERROR: br-evil bridge not found"
        exit 1
    fi

    LOG "Verifying DHCP pool..."
    if uci show dhcp.evil &>/dev/null; then
        LOG "SUCCESS: DHCP pool configured"
    else
        LOG "ERROR: DHCP pool not configured"
        exit 1
    fi
    LOG "Verifying br-evil ports..."
    if uci show network | grep "name='br-evil'" -A5 2>/dev/null || \
       cat /etc/config/network | grep -A5 "br-evil" | grep -q "ports '${TARGET_IFACE}'"; then
        LOG "SUCCESS: ${TARGET_IFACE} is port on br-evil"
    else
        LOG "WARNING: ${TARGET_IFACE} may not be a port on br-evil"
    fi
elif [ "$TARGET_MODE" = "lan" ]; then
    LOG "Verifying br-evil is removed..."
    if uci show network | grep -q "name='br-evil'"; then
        LOG "ERROR: br-evil still exists"
        exit 1
    else
        LOG "SUCCESS: br-evil removed"
    fi

    LOG "Verifying init script..."
    if grep -q "br-lan" /etc/init.d/evilportal && grep -q "172.16.52.1" /etc/init.d/evilportal; then
        LOG "SUCCESS: Init script updated correctly"
    else
        LOG "ERROR: Init script not updated correctly"
        exit 1
    fi
fi

LOG "Verifying internet connectivity..."
VERIFY_TIME=$(date +%s)
until ping -c1 8.8.8.8 &>/dev/null; do
    sleep 2
    if [ $(( $(date +%s) - VERIFY_TIME )) -ge 60 ]; then
        LOG "ERROR: Internet connectivity lost"
        exit 1
    fi
done
LOG "SUCCESS: Internet connectivity confirmed"

# ====================================================================
# Complete
# ====================================================================
LOG "=================================================="
LOG "Interface Configuration Complete!"
LOG "=================================================="
LOG "Portal IP: ${PORTAL_IP}"
if [ "$TARGET_MODE" = "isolated" ]; then
    LOG "Bridge Interface: ${BRIDGE_IF_EVIL}"
    LOG "Target Interface: ${TARGET_IFACE}"
    LOG "Evil Portal now applies to ${TARGET_IFACE} only"
else
    LOG "Bridge Interface: ${BRIDGE_IF_LAN}"
    LOG "Evil Portal now applies to all interfaces"
fi
LOG "Management network (172.16.52.0/24) is unaffected"
LOG "=================================================="

exit 0