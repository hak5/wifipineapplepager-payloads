#!/usr/bin

# Title:  ICMP Alert
# Author: spywill
# Description: Alert the wifi pineapple pager of ping or traceroute then Disabling incoming ICMP/UDP for 60 seconds
# Version: 1.0

IFACE=$(ip route | awk '/default/ {print $5}' | head -n1)
ip_address=$(ip -4 addr show "$IFACE" | awk '/inet / {print $2}' | cut -d'/' -f1)

icmp=$(CONFIRMATION_DIALOG "Start ICMP Alert
Listening on $IFACE for ICMP/UDP packets 
(ignoring $ip_address)")

case "$icmp" in
	$DUCKYSCRIPT_USER_CONFIRMED)
cat <<'EOF' > /tmp/ICMP_Alert.sh
#!/usr/bash

# Title: ICMP Alert

IFACE=$(ip route | awk '/default/ {print $5}' | head -n1)
ip_address=$(ip -4 addr show "$IFACE" | awk '/inet / {print $2}' | cut -d'/' -f1)

# Ringtone and time limit
ICMP_RINGTONE="Hak5_The_Planet:d=4,o=5,b=450:c6,c6,g5,c6,p,g5,a#5,c6,p,f5,g5,a#5,c6"
time=60

# TCPDump filter
FILTER="((icmp and icmp[0]=8) or (udp and (dst port 33434 or dst port 33534))) \
and not net 172.16.52.0/24 \
and not src host $ip_address"

# Capture one packet and format output
TCPDUMP_OUTPUT=$(tcpdump -i "$IFACE" -c 1 -n "$FILTER" 2>/dev/null \
| awk '
/ICMP echo request/ {
  print $3 " > " $5 ": ICMP echo request"
}
/UDP/ {
  print $3 " > " $5 ": [udp sum ok] UDP"
}')

# Backup current firewall rules
nft list ruleset > /tmp/nft_backup.rules

# Add temporary firewall rules
nft add chain inet fw4 TEMP_BLOCK { type filter hook input priority 0\; }
nft add rule inet fw4 TEMP_BLOCK icmp type echo-request drop
nft add rule inet fw4 TEMP_BLOCK udp dport {33434-33534} drop

RINGTONE $ICMP_RINGTONE &
ALERT "PAGER HAS BEEN (PING)
Disabling incoming ICMP/UDP for 60 seconds
Backup firewall: /tmp/nft_backup.rules
Attacker IP:
$TCPDUMP_OUTPUT

Press any button to continue"

# 60-second countdown
while [ "$time" -ge 0 ]; do
    LOG "$time"
    sleep 1
    time=$((time-1))
done

# Restore original firewall rules
nft flush ruleset
nft -f /tmp/nft_backup.rules

PROMPT "Firewall rules has been restored
Press the UP button twice to
continue ICMP Alert"

button=$(WAIT_FOR_INPUT)
case "$button" in
	UP)
		PROMPT "Continuing running ICMP Alert
		in background"
		bash /tmp/ICMP_Alert.sh
		;;
	*)
		PROMPT "Exiting ICMP Alert"
		exit
		;;
esac
EOF
		LOG "ICMP Alert starting in 5 sec..."
		sleep 5
		bash /tmp/ICMP_Alert.sh &
		sleep 2
		pgrep -f "bash /tmp/ICMP_Alert.sh" >/dev/null && {
			LOG yellow "ICMP Alert running in background
			(ALERT) will display of an incoming ICMP/UDP"
		} || {
			LOG red "ERROR ICMP ALERT NOT RUNNING"
		}
		;;
	$DUCKYSCRIPT_USER_DENIED)
		LOG "Selected no exiting"
		;;
	*)
		LOG "Unknown response exiting"
		;;
esac
