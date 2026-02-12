#!/bin/bash

# Title: Reverse Shell
# Author: spywill
# Description: Start SSH Reverse Shell
# Version: 1.0

PROMPT "Title: Reverse Shell

sshpass is a requirement

press any button to continue"

REMOTE_HOST_PASSWD="/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_passwd.txt"
REMOTE_HOST_NAME="/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_name.txt"
REMOTE_HOST_IP="/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_IP.txt"
PORT=22

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

# check and save remote host name
if [ -f "$REMOTE_HOST_NAME" ]; then
	LOG "Host name file exists $REMOTE_HOST_NAME"
	host_name=$(cat "$REMOTE_HOST_NAME")
else
	LOG "Host name file missing or empty"
	host_name="root"
fi

REMOTE_HOST=$(TEXT_PICKER "Enter remote host name?" "$host_name")
case $REMOTE_HOST in
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

echo "$REMOTE_HOST" > $REMOTE_HOST_NAME
LOG "Host name saved to $REMOTE_HOST_NAME"

# check and save remote host IP
if [ -f "$REMOTE_HOST_IP" ]; then
	LOG "Host IP file exists $REMOTE_HOST_IP"
	host_ip=$(cat "$REMOTE_HOST_IP")
else
	LOG "Host IP file missing or empty"
	host_ip=""
fi

REMOTE_IP=$(IP_PICKER "Enter remote IP" "$host_ip")
case $REMOTE_IP in
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

echo "$REMOTE_IP" > $REMOTE_HOST_IP
LOG "Remote Host IP saved to $REMOTE_HOST_IP"

# Checking if remote host is reachability
can_reach() {
	host="$1"
	ping -c 1 -W 1 "$host" >/dev/null 2>&1 && return 0
	nc -z -w 2 "$host" "$PORT" >/dev/null 2>&1
}

if can_reach $REMOTE_IP; then
	LOG yellow "$REMOTE_IP reachable"
else
	ALERT "$REMOTE_IP unreachable"
	exit 1
fi

# check and save remote host password
if [ -f "$REMOTE_HOST_PASSWD" ]; then
	LOG "Remote Host password file exists $REMOTE_HOST_PASSWD"
	host_passwd=$(cat "$REMOTE_HOST_PASSWD")
else
	LOG "Host password file missing or empty"
	host_passwd=""
fi

REMOTE_PASSWD=$(TEXT_PICKER "Enter Host password" "$host_passwd")
case $REMOTE_PASSWD in
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

echo "$REMOTE_PASSWD" > $REMOTE_HOST_PASSWD
LOG "Remote Host password saved to $REMOTE_HOST_PASSWD"

# Port number
PORT_NUMBER=$(NUMBER_PICKER "Enter port number" 7000)
case $PORT_NUMBER in
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

# Check if reverse shell is already running option to kill tunnel
if netstat -tn | grep -q "${REMOTE_IP}:${PORT}"; then
	LOG green "SSH reverse tunnel on port $PORT_NUMBER is running."
	LOG yellow "Do you want to kill it? 1-NO 2-YES "
	CHECK_SSH=$(NUMBER_PICKER "Kill SSH 1-NO 2-YES" 1)
	case "$CHECK_SSH" in
		2)
			pid=$(ps w | grep " -R $PORT_NUMBER" | grep -v grep | awk '{print $1}')
			kill -9 $pid
			LOG red "Tunnel killed."
			exit 1
			;;
		1)
			LOG green "Tunnel left running exiting."
			exit 1
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
		*)
			LOG green "Tunnel left running exiting."
			exit 1
			;;
	esac
else
	LOG "No SSH reverse tunnel on port $PORT_NUMBER is running."
	resp=$(CONFIRMATION_DIALOG "Start SSH reverse tunnel
	
	Select the checkmark to continue")
	case "$resp" in
		$DUCKYSCRIPT_USER_CONFIRMED)
			LOG "User selected yes"
			sshpass -p "$REMOTE_PASSWD" \
			ssh -fN \
			-R $PORT_NUMBER:localhost:$PORT \
			-o ExitOnForwardFailure=yes \
			-o ServerAliveInterval=60 \
			-o ServerAliveCountMax=5 \
			-o StrictHostKeyChecking=no \
			$REMOTE_HOST@$REMOTE_IP
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

# Check if reverse shell is running
if pgrep -f "ssh -fN -R ${PORT_NUMBER}" >/dev/null \
	&& netstat -tn | grep -q "${REMOTE_IP}:${PORT}"; then
	LOG green "SSH reverse tunnel healthy"
	LOG "Run this command on remote host"
	LOG yellow "ssh $REMOTE_HOST@localhost -p $PORT_NUMBER"
	PROMPT "REMOTE HOST COMMAND
	
	ssh $REMOTE_HOST@localhost -p $PORT_NUMBER"
else
	LOG red "SSH reverse tunnel broken"
	exit 1
fi
