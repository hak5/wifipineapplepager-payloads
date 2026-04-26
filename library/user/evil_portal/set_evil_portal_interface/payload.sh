#!/bin/bash
# Name: Set Evil Portal Interface
# Description: Configures Evil Portal to apply to Evil WPA, Open AP, or all interfaces
# Author: PentestPlaybook
# Version: 2.3
# Category: Evil Portal

PORTAL_IP_EVIL="10.0.0.1"
PORTAL_IP_LAN="172.16.52.1"
BRIDGE_IF_EVIL="br-evil"
BRIDGE_IF_LAN="br-lan"

iface_ready() {
    local iface="$1"
    ip link show "$iface" 2>/dev/null | grep -q "BROADCAST,MULTICAST,UP,LOWER_UP" && \
    ip link show "$iface" 2>/dev/null | grep -q "state UP"
}

wait_for_internet() {
    LOG "Waiting for internet connectivity..."
    ELAPSED=0
    while ! ping -c1 8.8.8.8 &>/dev/null; do
        LOG "Waiting for internet connectivity... (${ELAPSED}s)"
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    LOG "SUCCESS: Internet connectivity confirmed"
}

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
wait_for_internet

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
PENDING_SSID_WPA=$(uci changes wireless | grep "^wireless\.wlan0wpa\.ssid=" | cut -d= -f2- | tr -d "'")
PENDING_KEY_WPA=$(uci changes wireless | grep "^wireless\.wlan0wpa\.key=" | cut -d= -f2- | tr -d "'")
PENDING_SSID_OPEN=$(uci changes wireless | grep "^wireless\.wlan0open\.ssid=" | cut -d= -f2- | tr -d "'")
PENDING_KEY_OPEN=$(uci changes wireless | grep "^wireless\.wlan0open\.key=" | cut -d= -f2- | tr -d "'")
PENDING_SSID_MGMT=$(uci changes wireless | grep "^wireless\.wlan0mgmt\.ssid=" | cut -d= -f2- | tr -d "'")
PENDING_KEY_MGMT=$(uci changes wireless | grep "^wireless\.wlan0mgmt\.key=" | cut -d= -f2- | tr -d "'")

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

    if [ -n "$CURRENT_IFACE" ]; then
        uci set wireless.${CURRENT_IFACE}.network='lan'
        uci commit wireless
        uci del_list network.br_evil.ports="${CURRENT_IFACE}"
        uci add_list network.brlan.ports="${CURRENT_IFACE}"
        uci commit network
    fi

    # Remove evil network and br-evil device
    LOG "Removing br-evil and evil network..."
    uci delete network.evil 2>/dev/null
    uci delete network.br_evil 2>/dev/null
    uci commit network

    # Remove stanzas written directly to disk by echo >> during full conversion
    sed -i "/config device/{N;/name 'br-evil'/,/^$/d}" /etc/config/network
    sed -i "/config interface 'evil'/,/^$/d" /etc/config/network

    # Remove evil DHCP config
    LOG "Removing evil DHCP config..."
    uci delete dhcp.evil 2>/dev/null
    uci commit dhcp

    # Remove stanza written directly to disk by echo >> during full conversion
    sed -i "/config dhcp 'evil'/,/^$/d" /etc/config/dhcp

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

    uci del wireless.${CURRENT_IFACE}.network
    uci set wireless.${CURRENT_IFACE}.network='lan'
    uci set wireless.${TARGET_IFACE}.network='evil'
    uci commit wireless

    uci del_list network.br_evil.ports="${CURRENT_IFACE}"
    uci add_list network.br_evil.ports="${TARGET_IFACE}"
    uci commit network

else
    # STATE: br-lan - full conversion to br-evil
    # NOTE: echo >> is used verbatim from 1.2 where this branch was confirmed
    # working. No uci revert, no uci batch - wireless assignments follow
    # immediately after and are committed normally.
    LOG "Converting from br-lan to br-evil with ${TARGET_IFACE}..."

    echo -e "\nconfig device\n        option name 'br-evil'\n        option type 'bridge'\n\nconfig interface 'evil'\n        option device 'br-evil'\n        option proto 'static'\n        option ipaddr '10.0.0.1'\n        option netmask '255.255.255.0'" >> /etc/config/network

    echo -e "\nconfig dhcp 'evil'\n        option interface 'evil'\n        option start '100'\n        option limit '150'\n        option leasetime '1h'" >> /etc/config/dhcp

    uci del_list network.brlan.ports="${TARGET_IFACE}"
    uci commit network

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
wait_for_internet

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
    LOG "Step 12: Bringing up evil interface..."
    ifup evil
    sleep 5
    wait_for_internet
fi

# Re-stage all pending SSID/key changes without committing
# Done here to ensure they are not caught by any earlier uci commit wireless
[ -n "$PENDING_SSID_WPA" ] && uci set wireless.wlan0wpa.ssid="$PENDING_SSID_WPA"
[ -n "$PENDING_KEY_WPA" ] && uci set wireless.wlan0wpa.key="$PENDING_KEY_WPA"
[ -n "$PENDING_SSID_OPEN" ] && uci set wireless.wlan0open.ssid="$PENDING_SSID_OPEN"
[ -n "$PENDING_KEY_OPEN" ] && uci set wireless.wlan0open.key="$PENDING_KEY_OPEN"
[ -n "$PENDING_SSID_MGMT" ] && uci set wireless.wlan0mgmt.ssid="$PENDING_SSID_MGMT"
[ -n "$PENDING_KEY_MGMT" ] && uci set wireless.wlan0mgmt.key="$PENDING_KEY_MGMT"

# Reload wifi if any values were restaged so interfaces reflect pending changes
if [ -n "$PENDING_SSID_WPA" ] || [ -n "$PENDING_KEY_WPA" ] || \
   [ -n "$PENDING_SSID_OPEN" ] || [ -n "$PENDING_KEY_OPEN" ] || \
   [ -n "$PENDING_SSID_MGMT" ] || [ -n "$PENDING_KEY_MGMT" ]; then
    wifi reload
fi

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

# ====================================================================
# STEP 14: Wait for interfaces to be fully up (isolated mode only)
# ====================================================================
if [ "$TARGET_MODE" = "isolated" ]; then
    LOG "Step 14: Waiting for interfaces to be fully up..."
    LOG "Waiting 15 seconds before checking..."
    sleep 15

    ELAPSED=0
    MAX_WAIT=30
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        TARGET_OK=0
        OTHER_OK=0
        iface_ready "$TARGET_IFACE" && TARGET_OK=1
        iface_ready "$OTHER_IFACE" && OTHER_OK=1

        if [ $TARGET_OK -eq 1 ] && [ $OTHER_OK -eq 1 ]; then
            log "SUCCESS: Both interfaces fully up"
            log "  ${TARGET_IFACE}: BROADCAST,MULTICAST,UP,LOWER_UP state UP"
            log "  ${OTHER_IFACE}: BROADCAST,MULTICAST,UP,LOWER_UP state UP"

            # Verify TARGET_IFACE is mastered to br-evil
            MASTER=$(ip link show "$TARGET_IFACE" 2>/dev/null | grep -o 'master [^ ]*' | cut -d' ' -f2)
            if [ "$MASTER" = "br-evil" ]; then
                log "SUCCESS: ${TARGET_IFACE} mastered to br-evil"
            else
                log "ERROR: ${TARGET_IFACE} mastered to '${MASTER}' instead of br-evil"
                return 1
            fi

            # Verify broadcasting SSIDs match pending staged values
            if [ -n "$PENDING_SSID_WPA" ]; then
                BROADCASTING_WPA=$(iwinfo wlan0wpa info 2>/dev/null | grep 'ESSID' | cut -d'"' -f2)
                if [ "$BROADCASTING_WPA" = "$PENDING_SSID_WPA" ]; then
                    log "SUCCESS: wlan0wpa broadcasting staged SSID: ${PENDING_SSID_WPA}"
                else
                    log "ERROR: wlan0wpa broadcasting '${BROADCASTING_WPA}' but expected staged SSID '${PENDING_SSID_WPA}'"
                    return 1
                fi
            fi

            if [ -n "$PENDING_SSID_OPEN" ]; then
                BROADCASTING_OPEN=$(iwinfo wlan0open info 2>/dev/null | grep 'ESSID' | cut -d'"' -f2)
                if [ "$BROADCASTING_OPEN" = "$PENDING_SSID_OPEN" ]; then
                    log "SUCCESS: wlan0open broadcasting staged SSID: ${PENDING_SSID_OPEN}"
                else
                    log "ERROR: wlan0open broadcasting '${BROADCASTING_OPEN}' but expected staged SSID '${PENDING_SSID_OPEN}'"
                    return 1
                fi
            fi

            break
        fi

        [ $TARGET_OK -eq 0 ] && LOG "Waiting for ${TARGET_IFACE}... (${ELAPSED}s / ${MAX_WAIT}s)"
        [ $OTHER_OK -eq 0 ] && LOG "Waiting for ${OTHER_IFACE}... (${ELAPSED}s / ${MAX_WAIT}s)"

        sleep 5
        ELAPSED=$((ELAPSED + 5))

        if [ $ELAPSED -ge $MAX_WAIT ]; then
            [ $TARGET_OK -eq 0 ] && LOG "WARNING: ${TARGET_IFACE} did not reach BROADCAST,MULTICAST,UP,LOWER_UP state UP"
            [ $OTHER_OK -eq 0 ] && LOG "WARNING: ${OTHER_IFACE} did not reach BROADCAST,MULTICAST,UP,LOWER_UP state UP"
        fi
    done

    wait_for_internet
fi

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
