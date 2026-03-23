#!/bin/bash

# Title: Reverse Shell
# Author: spywill
# Description: Start SSH reverse tunnel (ssh/Virtual pager)
# Version: 1.1

PROMPT "Title: Reverse Shell

sshpass is a requirement
Port# example:
SSH: remote port-7000 and local port-22
Virtual pager:
remote port-8080 and local port-1471

press any button to continue"

REMOTE_HOST_PASSWD="/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_passwd.txt"
REMOTE_HOST_NAME="/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_name.txt"
REMOTE_HOST_IP="/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_IP.txt"

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
				ERROR_DIALOG "Error sshpass not in installed exiting..."
				exit
			fi
			;;
		$DUCKYSCRIPT_USER_DENIED)
			LOG "User selected no exiting..."
			exit
			;;
		*)
			LOG "Unknown response: $resp exiting..."
			exit 1
			;;
	esac
fi

# check and save remote host username
if [ -f "$REMOTE_HOST_NAME" ]; then
	LOG "Remote Host username file exists $REMOTE_HOST_NAME"
	host_name=$(cat "$REMOTE_HOST_NAME")
else
	LOG "Remote Host username file missing or empty"
	host_name="root"
fi

LOG "ENTER REMOTE HOST USERNAME"
REMOTE_HOST=$(TEXT_PICKER "Remote host username?" "$host_name")
case $REMOTE_HOST in
	$DUCKYSCRIPT_CANCELLED)
		LOG "User cancelled exiting..."
		exit
		;;
	$DUCKYSCRIPT_REJECTED)
		LOG "Dialog rejected exiting..."
		exit 1
		;;
	$DUCKYSCRIPT_ERROR)
		LOG "An error occurred exiting..."
		exit 1
		;;
esac

echo "$REMOTE_HOST" > $REMOTE_HOST_NAME
LOG "Remote Host username saved to -> $REMOTE_HOST_NAME"

# check and save remote host IP
if [ -f "$REMOTE_HOST_IP" ]; then
	LOG "Remote Host IP file exists $REMOTE_HOST_IP"
	host_ip=$(cat "$REMOTE_HOST_IP")
else
	LOG "Remote Host IP file missing or empty"
	host_ip=""
fi

LOG "ENTER REMOTE HOST IP"
REMOTE_IP=$(IP_PICKER "Enter remote host IP" "$host_ip")
case $REMOTE_IP in
	$DUCKYSCRIPT_CANCELLED)
		LOG "User cancelled exiting..."
		exit
		;;
	$DUCKYSCRIPT_REJECTED)
		LOG "Dialog rejected exiting..."
		exit 1
		;;
	$DUCKYSCRIPT_ERROR)
		LOG "An error occurred exiting..."
		exit 1
		;;
esac

echo "$REMOTE_IP" > $REMOTE_HOST_IP
LOG "Remote Host IP saved to -> $REMOTE_HOST_IP"

# Checking if remote host is reachability
can_reach() {
	host="$1"
	# Check ICMP
	if ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
		return 0
	fi
	# Check SSH port (22)
	nc -z -w 2 "$host" 22 >/dev/null 2>&1
}

if can_reach $REMOTE_IP; then
	LOG yellow "$REMOTE_IP reachable"
else
	LOG red "$REMOTE_IP unreachable exiting..."
	ERROR_DIALOG "$REMOTE_IP unreachable exiting..."
	exit
fi

# check and save remote host password
if [ -f "$REMOTE_HOST_PASSWD" ]; then
	LOG "Remote Host password file exists $REMOTE_HOST_PASSWD"
	host_passwd=$(cat "$REMOTE_HOST_PASSWD")
else
	LOG "Remote Host password file missing or empty"
	host_passwd=""
fi

LOG "ENTER REMOTE HOST PASSWORD"
REMOTE_PASSWD=$(TEXT_PICKER "Remote Host password" "$host_passwd")
case $REMOTE_PASSWD in
	$DUCKYSCRIPT_CANCELLED)
		LOG "User cancelled exiting..."
		exit
		;;
	$DUCKYSCRIPT_REJECTED)
		LOG "Dialog rejected exiting..."
		exit 1
		;;
	$DUCKYSCRIPT_ERROR)
		LOG "An error occurred exiting..."
		exit 1
		;;
esac

echo "$REMOTE_PASSWD" > $REMOTE_HOST_PASSWD
LOG "Remote Host password saved to -> $REMOTE_HOST_PASSWD"

# Remote Port number
LOG "ENTER REMOTE PORT#
Port# example:
SSH: remote port-7000 and local port-22
Virtual pager:
remote port-8080 and local port-1471"
REMOTE_PORT=$(NUMBER_PICKER "Remote port 7000-8080" 8080)
case $REMOTE_PORT in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled exiting..."
        exit
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Dialog rejected exiting..."
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred exiting..."
        exit 1
        ;;
esac

# Local Port number
LOG "ENTER REMOTE LOCAL PORT#
Port# example:
SSH: remote port-7000 and local port-22
Virtual pager:
remote port-8080 and local port-1471"
LOCAL_PORT=$(NUMBER_PICKER "Local port 22-1471" 1471)
case $LOCAL_PORT in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled exiting..."
        exit
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Dialog rejected exiting..."
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred exiting..."
        exit 1
        ;;
esac

# Check if reverse shell is already running option to kill tunnel
if pgrep -f "ssh -fN -R ${REMOTE_PORT}:localhost:${LOCAL_PORT}" >/dev/null; then
	LOG green "SSH reverse tunnel on port $REMOTE_PORT is running."
	LOG yellow "Do you want to kill it? 1-NO 2-YES "
	CHECK_SSH=$(NUMBER_PICKER "Kill SSH 1-NO 2-YES" 1)
	case "$CHECK_SSH" in
		2)
			pid=$(pgrep -f "ssh.*-R ${REMOTE_PORT}:")
			if [ -n "$pid" ]; then
				kill -9 "$pid"
				sleep 1
				LOG red "Tunnel killed exiting..."
				ERROR_DIALOG "Tunnel killed exiting..."
				exit
			else
				LOG yellow "No tunnel process found."
			fi
			;;
		1)
			LOG green "Tunnel left running exiting..."
			exit
			;;
		$DUCKYSCRIPT_CANCELLED)
			LOG "User cancelled exiting..."
			exit
			;;
		$DUCKYSCRIPT_REJECTED)
			LOG "Dialog rejected exiting..."
			exit 1
			;;
		$DUCKYSCRIPT_ERROR)
			LOG "An error occurred exiting..."
			exit 1
			;;
		*)
			LOG green "Tunnel left running exiting..."
			exit
			;;
	esac
else
	LOG "No SSH reverse tunnel on port $REMOTE_PORT is running."
	resp=$(CONFIRMATION_DIALOG "Start SSH reverse tunnel
	
	Select the checkmark to continue")
	case "$resp" in
		$DUCKYSCRIPT_USER_CONFIRMED)
			LOG "User selected yes"
			sshpass -p "$REMOTE_PASSWD" \
			ssh -fN \
			-R $REMOTE_PORT:localhost:$LOCAL_PORT \
			-o ExitOnForwardFailure=yes \
			-o ServerAliveInterval=60 \
			-o ServerAliveCountMax=5 \
			-o StrictHostKeyChecking=no \
			$REMOTE_HOST@$REMOTE_IP
			;;
		$DUCKYSCRIPT_USER_DENIED)
			LOG "User selected no exiting..."
			exit
			;;
		*)
			LOG "Unknown response: $resp exiting..."
			exit 1
			;;
	esac
fi

# Check if reverse shell is running
if pgrep -f "ssh -fN -R ${REMOTE_PORT}:localhost:${LOCAL_PORT}" >/dev/null; then
	LOG green "SSH reverse tunnel healthy"

	if [ "$REMOTE_PORT" = "7000" ] && [ "$LOCAL_PORT" = "22" ]; then
		LOG blue "Run this command on remote host"
		LOG yellow "ssh root@localhost -p $REMOTE_PORT"
		PROMPT "REMOTE HOST COMMAND

ssh root@localhost -p $REMOTE_PORT"

	elif [ "$REMOTE_PORT" = "8080" ] && [ "$LOCAL_PORT" = "1471" ]; then
		LOG blue "Open this URL on remote host"
		LOG yellow "http://localhost:8080"
		PROMPT "REMOTE HOST URL

http://localhost:8080"
	else
		LOG green "Tunnel active on custom ports"
	fi
else
	LOG red "SSH reverse tunnel broken exiting..."
	ERROR_DIALOG "SSH reverse tunnel broken exiting..."
	exit
fi
