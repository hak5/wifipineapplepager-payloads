#!/usr/bin

# Title:  Pager_quack
# Author: spywill
# Description: Send QUACK command to your keycroc from wifi pineapple pager
# Version: 1.1

#trap 'exit 0' INT TERM
quack_file="/mmc/root/payloads/user/remote_access/Pager_quack/Quack.txt"
PASS_FILE="/mmc/root/payloads/user/remote_access/Pager_quack/croc_passwd.txt"
CROC_IP_FILE="/mmc/root/payloads/user/remote_access/Pager_quack/croc_IP.txt"
chmod 777 /mmc/root/payloads/user/remote_access/Pager_quack

PROMPT "Title: Pager_quack
Description: Send QUACK command to your keycroc from wifi pineapple pager

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

# Sending QUACK command over SSH
spinnerid=$(START_SPINNER "Sending QUACK command...")
sshpass -p "$croc_passwd" ssh -o StrictHostKeyChecking=no root@$croc_ip <<EOF || true
$( if [[ -f "$quack" ]]; then
	cat "$quack"
else
	echo "$quack"
fi )
EOF
rc=$?
STOP_SPINNER ${spinnerid}

# Check if the SSH command succeeded
LOG blue "================================================="
if [[ $rc -eq 0 ]]; then
	LOG yellow "Successfully QUACK"
	if [[ -f "$quack" ]]; then
		LOG green "$(cat "$quack")"
	else
		LOG green "$quack"
	fi
else
	LOG red "QUACK failed (ssh exit code $rc)"
fi
