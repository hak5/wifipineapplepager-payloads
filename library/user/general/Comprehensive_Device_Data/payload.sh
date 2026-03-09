#!/bin/bash

# Title: Comprehensive Device Data
# Description: Full system, network, radios, USB, hardware, and connectivity status
# Author: RocketGod - https://betaskynet.com
# Crew: The Pirates' Plunder - https://discord.gg/thepirates

# === CLEANUP ===
trap 'DPADLED off' EXIT INT TERM

# === MAIN ===

LOG "== COMPREHENSIVE DEVICE DATA =="
LOG "by RocketGod"
LOG ""

DPADLED cyan

# --- DEVICE INFO ---
LOG "-- DEVICE INFO --"
device=$(grep "machine" /proc/cpuinfo | cut -d: -f2 | xargs)
LOG "$device"
fw_ver=$(grep "DISTRIB_RELEASE" /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)
LOG "Firmware: $fw_ver"
cpu=$(grep "cpu model" /proc/cpuinfo | cut -d: -f2 | xargs)
LOG "CPU: $cpu"
LOG ""

# --- SYSTEM STATUS ---
LOG "-- SYSTEM STATUS --"
up=$(uptime | sed 's/.*up //' | sed 's/,  load.*//')
LOG "Uptime: $up"
batt=$(cat /sys/class/power_supply/*/capacity 2>/dev/null)
[ -n "$batt" ] && LOG "Battery: ${batt}%" || LOG "Battery: N/A"
mem_total=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')
LOG "Memory: ${mem_avail}MB / ${mem_total}MB free"
LOG ""

# --- STORAGE ---
LOG "-- STORAGE --"
df -h 2>/dev/null | grep -v "tmpfs\|^Filesystem\|^overlay\|^/dev/root" | while read fs size used avail pct mount; do
    LOG "$mount: ${avail} free / ${size}"
done
LOG ""

# --- INTERFACES ---
LOG "-- INTERFACES --"
ip -4 addr | grep inet | while read _ ip _ _ _ iface; do
    [[ "$iface" == "lo" ]] && continue
    [[ "$ip" == "127."* ]] && continue
    LOG "$iface: $ip"
done
LOG ""

# --- GATEWAY ---
gw=$(ip route 2>/dev/null | grep "^default" | awk '{print $3}')
if [ -n "$gw" ]; then
    LOG "Gateway: $gw"
else
    LOG "Gateway: None (offline)"
fi
LOG ""

# --- USB DEVICES ---
LOG "-- USB DEVICES --"
lsusb 2>/dev/null | while read _ _ _ _ id name; do
    [[ "$name" == *"Host Controller"* ]] && continue
    [[ "$name" == *"USB 2.0 Hub"* ]] && continue
    LOG "$name"
done
eth_state=$(cat /sys/class/net/eth0/operstate 2>/dev/null)
[ "$eth_state" = "up" ] && LOG "Ethernet: Connected" || LOG "Ethernet: Disconnected"
LOG ""

# --- WIFI RADIOS ---
LOG "-- WIFI RADIOS --"
LOG "2.4GHz (MT7628):"
for iface in wlan0mgmt wlan0open; do
    essid=$(iwinfo $iface info 2>/dev/null | grep ESSID | sed 's/.*ESSID: //' | tr -d '"')
    if [ -n "$essid" ] && [ "$essid" != "unknown" ]; then
        clients=$(iwinfo $iface assoclist 2>/dev/null | grep -c "dBm" || echo "0")
        LOG "  $essid ($clients clients)"
    fi
done
cli_essid=$(iwinfo wlan0cli info 2>/dev/null | grep ESSID | sed 's/.*ESSID: //' | tr -d '"')
if [ -n "$cli_essid" ] && [ "$cli_essid" != "unknown" ]; then
    LOG "  Client: $cli_essid"
else
    LOG "  Client: Not connected"
fi

LOG "5GHz (MT7921AU):"
if iwinfo wlan1mon info >/dev/null 2>&1; then
    channel=$(iwinfo wlan1mon info 2>/dev/null | grep Channel | sed 's/.*Channel: //' | cut -d' ' -f1)
    LOG "  Monitor Ch $channel"
else
    LOG "  Not detected"
fi
LOG ""

# --- BLUETOOTH ---
LOG "-- BLUETOOTH --"
if hciconfig hci0 >/dev/null 2>&1; then
    bt_status=$(hciconfig hci0 2>/dev/null | grep -o "UP RUNNING" || echo "DOWN")
    bt_addr=$(hciconfig hci0 2>/dev/null | grep "BD Address" | awk '{print $3}')
    if [ "$bt_status" = "UP RUNNING" ]; then
        LOG "BT 5.2: $bt_addr"
        LOG "Status: Active"
        paired=$(bluetoothctl devices 2>/dev/null | wc -l)
        [ "$paired" -gt 0 ] && LOG "Paired: $paired device(s)"
    else
        LOG "Status: Inactive"
    fi
else
    LOG "Not detected"
fi
LOG ""

# --- TCP PORTS ---
LOG "-- TCP PORTS --"
netstat -tlnp 2>/dev/null | grep LISTEN | while read proto _ _ local _ state prog; do
    # Skip IPv6 and localhost
    [[ "$local" == *"::"* ]] && continue
    [[ "$local" == "127.0.0.1:"* ]] && continue
    # Extract port
    port="${local##*:}"
    # Extract program name
    prog_name="${prog#*/}"
    prog_name="${prog_name%% *}"
    LOG ":$port - $prog_name"
done
LOG ""

# --- UDP PORTS ---
LOG "-- UDP PORTS --"
netstat -ulnp 2>/dev/null | grep -v "^Active\|^Proto" | while read proto _ _ local _ prog; do
    # Skip IPv6 and localhost
    [[ "$local" == *"::"* ]] && continue
    [[ "$local" == "127.0.0.1:"* ]] && continue
    # Extract port
    port="${local##*:}"
    # Extract program name
    prog_name="${prog#*/}"
    prog_name="${prog_name%% *}"
    LOG ":$port - $prog_name"
done
LOG ""

# --- ACTIVE CONNECTIONS ---
LOG "-- ACTIVE CONNECTIONS --"
conns=$(netstat -tnp 2>/dev/null | grep ESTABLISHED | wc -l)
if [ "$conns" -gt 0 ]; then
    LOG "$conns connection(s):"
    netstat -tnp 2>/dev/null | grep ESTABLISHED | awk '{
        local = $4
        remote = $5
        prog = $7
        
        # Remove ::ffff: prefix if present
        gsub(/::ffff:/, "", local)
        gsub(/::ffff:/, "", remote)
        
        # Extract IP and port (last colon separates them)
        n = split(local, la, ":")
        local_port = la[n]
        
        n = split(remote, ra, ":")
        remote_port = ra[n]
        remote_ip = ra[1]
        for (i=2; i<n; i++) remote_ip = remote_ip ":" ra[i]
        
        # Extract program name
        split(prog, pa, "/")
        prog_name = pa[2]
        gsub(/-.*/, "", prog_name)
        
        print remote_ip " > :" local_port " (" prog_name ")"
    }' | while read line; do
        LOG "$line"
    done
else
    LOG "None"
fi
LOG ""

# --- WIFI CLIENTS ---
LOG "-- WIFI CLIENTS --"
wifi_found=0
for iface in wlan0mgmt wlan0open; do
    essid=$(iwinfo $iface info 2>/dev/null | grep ESSID | sed 's/.*ESSID: //' | tr -d '"')
    clients=$(iwinfo $iface assoclist 2>/dev/null | grep -v "No station")
    if [ -n "$clients" ]; then
        echo "$clients" | while read line; do
            # Format: MAC  signal  inactive  rx  tx
            mac=$(echo "$line" | awk '{print $1}')
            signal=$(echo "$line" | grep -o "\-[0-9]* dBm")
            [ -n "$mac" ] && LOG "$mac $signal" && wifi_found=1
        done
    fi
done
[ "$wifi_found" -eq 0 ] && LOG "None"
LOG ""

# --- DHCP CLIENTS ---
LOG "-- DHCP CLIENTS --"
if [ -f /tmp/dhcp.leases ] && [ -s /tmp/dhcp.leases ]; then
    while read _ mac ip name _; do
        if [ -n "$name" ] && [ "$name" != "*" ]; then
            LOG "$ip - $name"
        else
            LOG "$ip - $mac"
        fi
    done < /tmp/dhcp.leases
else
    LOG "None"
fi
LOG ""

DPADLED green
LOG "==========================="
LOG "A = Exit"

WAIT_FOR_INPUT
DPADLED off