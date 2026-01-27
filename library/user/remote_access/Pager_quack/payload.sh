#!/usr/bin

# Title:  Pager_quack
# Author: spywill
# Description: Send QUACK command to your keycroc from wifi pineapple pager
# Version: 1.0

quack_file="/mmc/root/payloads/user/remote_access/Pager_quack/Quack.txt"

PROMPT "Title: Pager_quack
Author: spywill
Description: Send QUACK command to your keycroc from wifi pineapple pager
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

usernum=$(NUMBER_PICKER "1-ENTER QUACK 2-ADD FILE" "1")
case $usernum in
	1)
		quack=$(TEXT_PICKER "Enter Quack command" "QUACK STRING hello world")
		;;
	2)
		if [[ -f "$quack_file" ]]; then
			quack="$quack_file"
			LOG blue "================================================="
			LOG green "You have selected a QUACK file"
			LOG "$(cat $quack_file)"
			sleep 2
		else
			ALERT "NO FILE FOUND $quack_file"
			exit 1
		fi
		;;
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

sshpass -p "$croc_passwd" ssh -o StrictHostKeyChecking=no root@$croc_ip <<EOF
$( if [[ -f "$quack" ]]; then
	cat "$quack"
else
	echo "$quack"
fi )
EOF

LOG blue "================================================="
LOG green "Successfully QUACK"
if [[ -f "$quack" ]]; then
	LOG "$(cat $quack)"
else
	LOG "$quack"
fi
