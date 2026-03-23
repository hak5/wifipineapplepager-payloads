#!/usr/bin

# Title:  PORT Alert
# Author: spywill
# Description:  Alert the wifi pineapple pager of a Port scan then Disabling all open ports for 60 seconds
# Version: 1.0

IFACE=$(ip route | awk '/default/ {print $5}' | head -n1)
ip_address=$(ip -4 addr show "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)

port_scan=$(CONFIRMATION_DIALOG "Start PORT Alert
Listening on $IFACE for tcpflags packets 
(ignoring $ip_address)

WARNING This will Disable live connection
If Port scan is Detected")

case "$port_scan" in
	$DUCKYSCRIPT_USER_CONFIRMED)
cat <<'EOF' > /tmp/PORT_Alert.sh
#!/usr/bash

# Title: PORT Alert

IFACE=$(ip route | awk '/default/ {print $5}' | head -n1)
ip_address=$(ip -4 addr show "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)
file="/tmp/portscan.pcap"

# Ringtone and time limit
PORT_RINGTONE="Hak5_The_Planet:d=4,o=5,b=450:c6,c6,g5,c6,p,g5,a#5,c6,p,f5,g5,a#5,c6"
time=60

tcpdump -i "$IFACE" \
'tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0 and not src host '"$ip_address"' and not port 22' \
-w "$file" &
tcpdump_pid=$!

while true; do
	if [[ -s "$file" ]]; then
		detected_scans=$(tcpdump -nn -r "$file" \
		'tcp[tcpflags] & tcp-syn != 0' 2>/dev/null | wc -l)
		if [ "$detected_scans" -ge 20 ]; then
			kill -9 "$tcpdump_pid"
			break
		fi
	fi
	sleep 0.5
done

# Backup current firewall rules
nft list ruleset > /tmp/nft_backup.rules

# Add temporary firewall rules
# Allow Loopback + Established, Drop Everything Else
nft flush ruleset
nft add table inet filter
nft add chain inet filter input { \
type filter hook input priority 0 \; policy drop \; }
nft add rule inet filter input iif lo accept
nft add rule inet filter input ct state established,related accept

RINGTONE $PORT_RINGTONE &
ALERT "PAGER DETECTED PORT SCAN
Disabling all open port for 60 seconds
Backup firewall: /tmp/nft_backup.rules
$(tcpdump -nn -r "$file" \
'tcp[tcpflags] & tcp-syn != 0' |
	awk '{
		split($3,s,".");
		split($5,d,".");
		print "Attacker:", s[1]"."s[2]"."s[3]"."s[4], "-> Port:", d[5]
}')

Press any button to continue"

# 60-second countdown
while [ "$time" -ge 0 ]; do
    sleep 1
    time=$((time-1))
done

# Restore original firewall rules
nft flush ruleset
nft -f /tmp/nft_backup.rules

PROMPT "Firewall rules has been restored
Press the UP button twice to
continue PORT Alert"

button=$(WAIT_FOR_INPUT)
case "$button" in
	UP)
		rm -f "$file"
		PROMPT "Continuing running PORT Alert
		in background"
		bash /tmp/PORT_Alert.sh
		;;
	*)
		PROMPT "Exiting PORT Alert"
		rm -f "$file"
		exit
		;;
esac
EOF
		LOG "PORT Alert starting in 5 sec..."
		sleep 5
		bash /tmp/PORT_Alert.sh &
		sleep 2
		pgrep -f "bash /tmp/PORT_Alert.sh" >/dev/null && {
			LOG yellow "PORT Alert running in background
			(ALERT) will display of an incoming PORT SCAN"
		} || {
			LOG red "ERROR PORT ALERT NOT RUNNING"
		}
		;;
	$DUCKYSCRIPT_USER_DENIED)
		LOG "Selected no exiting"
		;;
	*)
		LOG "Unknown response exiting"
		;;
esac
