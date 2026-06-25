#!/bin/bash
# Title: Handshake Cleaner
# Author: cncartist
# Description: Clears/Deletes Handshakes matching SSID, helpful to clean out unwanted SSIDs.
# Category: general
# Version: 1.0
# 
# Acknowledgements: 
# Interactive Handshake Cracker - Author: sinX - (code concepts)
# 

# ---- CONFIG ----
HANDSHAKE_DIR="/root/loot/handshakes"
TRASHBIN_DIR="/root/loot/csec/handshakes_trash"
mkdir -p "$TRASHBIN_DIR"

# ---- ARRAYS ----
declare -A SSID_NAMES
declare -A SSID_UNIQS

# Check for required tools
check_dependencies() {
	# ORIGINAL <root> grep -V
	# grep: unrecognized option: V
	# BusyBox v1.36.1 (2025-04-13 16:38:32 UTC) multi-call binary.
	# 
	# NEW <root> grep -V
	# grep (GNU grep) 3.11
	local aircrackCheck=0; local grepCheck=0; local count=0; local limit=3; local substring="BusyBox v"; local substring2='grep (GNU grep)'
	# check aircrack-ng
	if command -v aircrack-ng &> /dev/null; then
		aircrackCheck=1
	fi
	# check grep
	while IFS= read -r line && [[ "$count" -lt "$limit" ]] ; do
		if [[ "$line" == *"$substring2"* ]]; then
			# LOG "Grep is GNU version"
			grepCheck=1
		fi
		count=$((count + 1))
	done < <(
		grep -V
	)
	if [[ "$grepCheck" -eq 0 || "$aircrackCheck" -eq 0 ]]; then
		local dependText=""
		# ask if they want to install now
		if [[ "$grepCheck" -eq 0 ]]; then
			dependText="GNU grep"
		fi
		if [[ "$aircrackCheck" -eq 0 ]]; then
			if [[ -n "$dependText" ]]; then
				dependText="${dependText} & aircrack-ng"
				# dependText="GNU grep & aircrack-ng"
			else
				dependText="aircrack-ng"
			fi
		fi
		resp=$(CONFIRMATION_DIALOG "Dependency not met!
		
		Required: $dependText
		
		Install automatically now?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LOG blue  "================================================="
			LOG "Starting package install..."
			sleep 1
			count=0
			while [[ -f "/var/lock/opkg.lock" ]] && [[ "$count" -lt 3 ]] ; do
				LOG red "Opkg currently locked by a process. Waiting..."
				sleep 5
				count=$((count + 1))
			done
			# Check WiFi Client Mode enabled
			count=1 # Number of packets to send
			timeout=3 # Seconds to wait for a response
			if ping -c $count -w $timeout "8.8.8.8" > /dev/null 2>&1; then
				LOG "Network connection is active..."
				LOG "Running 'opkg update'"
				LOG "Please wait..."
				# opkg update && opkg install grep
				if opkg update; then
					LOG green "'opkg update' successful."
					if [[ "$grepCheck" -eq 0 ]]; then
						LOG "Installing GNU grep..."
						LOG "Please wait..."
						opkg install grep
					fi
					if [[ "$aircrackCheck" -eq 0 ]]; then
						LOG "Installing aircrack-ng..."
						LOG "Please wait..."
						opkg install aircrack-ng
					fi
					LOG green "Packages installed!"
				else
					LOG red "'opkg update' failed. Check network..."
				fi
			else
				LOG red "Network connection is down..."
			fi
			LOG blue  "================================================="
		else
			ERROR_DIALOG "Dependency not met:
			
			Required: $dependText not installed!"
			LOG red   "===================================== CRITICAL =="
			LOG red   "== Dependency not met: $dependText"
			LOG red   "===================================== CRITICAL =="
			LOG cyan "== Install with ->"
			LOG "opkg update"
			LOG "opkg install grep"
			LOG "opkg install aircrack-ng"
			LOG blue  "================================================="
			LOG cyan "== Or all in one command ->"
			LOG "opkg update && opkg install grep && opkg install aircrack-ng"
			LOG blue  "================================================="
			sleep 1
			exit 1
		fi
	fi
}
check_dependencies

cleanup() {
    killall -9 'aircrack-ng' 2>/dev/null
    sleep 0.5
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM


function select_ssid_delete() {

	while true; do
		#reset vars
		unset SSID_NAMES
		unset SSID_UNIQS
		declare -A SSID_NAMES
		declare -A SSID_UNIQS
		
		# Find all trash files
		local trashfiles=($(find "$TRASHBIN_DIR" -name "*.pcap" -o -name "*.cap" -o -name "*.22000" 2>/dev/null))
		LOG "Checking trash bin..."
		if [ ${#trashfiles[@]} -gt 0 ]; then
			LED BLUE SLOW
			LOG cyan "${#trashfiles[@]} Handshake files found in trash bin..."
			LOG " "
			resp=$(CONFIRMATION_DIALOG "${#trashfiles[@]} Handshake files found in trash bin, do you want to permanently delete them?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				sleep 1
				resp=$(CONFIRMATION_DIALOG "FINAL: ${#trashfiles[@]} Handshake files found in trash bin, ARE YOU SURE you want to permanently delete them?")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					LOG red "Permanenty deleting trashed Handshakes..."
					LOG " "
					rm -f "$TRASHBIN_DIR"/*
					sleep 1
					LED MAGENTA
					LOG green "Permanenty deleted ${#trashfiles[@]} Handshake files..."
					LOG " "
					LOG "Press OK to continue..."
					LOG " "
					WAIT_FOR_BUTTON_PRESS A
				else
					LOG "Skipped emptying trash bin..."
					LOG " "
				fi
			else
				LOG "Skipped emptying trash bin..."
				LOG " "
			fi
			# return 1
		else
			LOG "Trash bin empty, continuing..."
			LOG " "
		fi
		
		# Find all handshake files
		local files=($(find "$HANDSHAKE_DIR" -name "*.pcap" -o -name "*.cap" 2>/dev/null))
		if [ ${#files[@]} -eq 0 ]; then
			ERROR_DIALOG "No Handshake files found in $HANDSHAKE_DIR"
			exit 0
		fi
		
		LED RED SLOW
		LOG magenta "Building SSID list, please wait..."
		LOG magenta "This may take some time..."
		LOG " "
		
		# file="/root/loot/handshakes/handshake.pcap"
		# aircrack-ng "${file}"
		# aircrack installed in mmc, but threw error for .so file and reinstalled on root
		# bash: /mmc/usr/bin/aircrack-ng: No such file or directory
		# ln -s /usr/bin/aircrack-ng /mmc/usr/bin/aircrack-ng
		
		
		# original, doesn't capture spaces
		# aircrack-ng "${file}" 2>/dev/null | grep -P "(?<=\().*(?=\))" | awk '{print $3}' | head -1
		# updated, captures spaces
		# aircrack-ng "${file}" 2>/dev/null | grep -P "(?<=\().*(?=\))" | awk -F '  ' '{print $4}' | head -1
		local count=1
		local SSIDCUR=" "
		local SSIDSEL=" "
		local LIST_STR=""
		for d in "${files[@]}"; do
			# LOG "file: ${d}"
			SSIDCUR=$(aircrack-ng "${d}" 2>/dev/null | grep -P "(?<=\().*(?=\))" | awk -F '  ' '{print $4}' | head -1)
			# LOG "SSIDCUR: $SSIDCUR"
			if [[ -n "$SSIDCUR" ]] ; then
				LIST_STR="${LIST_STR}${count}: SSID: ${SSIDCUR}
		"
				SSID_NAMES["$SSIDCUR"]="$(basename ${d})"
				count=$((count + 1))
			fi
		done
		local countunique=${#SSID_NAMES[@]}
		LOG "Found $countunique Unique SSID's:"
		
		count=1
		# SORT THE DISPLAY!!!
		# LOG "re-order" # sort
		# A more robust approach using a while loop:
		while IFS= read -r line; do
			# Extract value and key from the line
			name="$line"
			LOG cyan "${count}: $name"
			SSID_UNIQS[$count]="$name"
			count=$((count + 1))
		done < <(
			for key in "${!SSID_NAMES[@]}"; do
				echo "$key"
			done | sort -f
		)
		LED MAGENTA
		RINGTONE "hack_stealth"
		LOG " "
		LOG " ^ Scroll UP to see Handshake SSID list ^ "
		LOG " "
		LOG "Press OK to select SSID to remove Handshakes..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 1
		
		resp=$(CONFIRMATION_DIALOG "Select a SSID to Clear/Delete Handshakes?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LED YELLOW
			local filenumsel=0
			local boolcheckval="false"
			local loopcount=0
			#LOG "BEFORE WHILE boolcheckval: $boolcheckval"
			while [ "$boolcheckval" != "true" ]; do
				#LOG "boolcheckval: $boolcheckval"
				if [ "$boolcheckval" != "true" ]; then
					
					if [ "$loopcount" -gt 0 ]; then
						LOG " ^ Scroll UP for SSID list, or Press OK when ready"
						WAIT_FOR_BUTTON_PRESS A
					fi
					loopcount=$((loopcount + 1))
					filenumsel=$(NUMBER_PICKER "Select a SSID number:" "1")
					
					sleep 1
					if [ "$filenumsel" -gt 0 ]; then
						#CHECK IF FILE IS VALID
						if [ "$filenumsel" -le "$countunique" ]; then
							#LOG "Index '$filenumsel' is set."						
							SSIDSEL=${SSID_UNIQS[$filenumsel]}						
							resp=$(CONFIRMATION_DIALOG "Confirm SSID: ${SSIDSEL} ?")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								#LOG "Confirmed"
								boolcheckval="true"
							fi				
						else
							LOG red "SSID number '$filenumsel' does not exist, try again."
						fi
					fi
					sleep 1
					#LOG "boolcheckval FIN: $boolcheckval"
				fi
			done
			# Confirm change
			resp=$(CONFIRMATION_DIALOG "FINAL: Are you sure you want to remove ALL handshakes for SSID: ${SSIDSEL} ?")
			sleep 1
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				#LOG "User CONFIRMED"
				LED CYAN SLOW
				local SSIDCHECK=" "
				local filecheck=" "
				local filename_with_ext=" "
				local filename=" "
				SSIDCHECK="$SSIDSEL"
				LOG green "Removing Handshake(s) for SSID: ${SSIDCHECK}"
				LOG " "
				count=0
				for d in "${files[@]}"; do
					SSIDCUR=$(aircrack-ng "${d}" 2>/dev/null | grep -P "(?<=\().*(?=\))" | awk -F '  ' '{print $4}' | head -1)
					if [[ "$SSIDCUR" == "$SSIDCHECK" ]]; then
						filename_with_ext="$(basename ${d})"
						filename="${filename_with_ext%.*}"
						# delete .22000 & .pcap & .cap of same name selected
						filecheck="${HANDSHAKE_DIR}/${filename}.22000"
						if [ -f "$filecheck" ]; then
							LOG magenta "Trashing .22000: ${filecheck}"
							# rm "$filecheck"
							mv "$filecheck" "${TRASHBIN_DIR}/$(basename ${filecheck})"
							count=$((count + 1))
						fi
						filecheck="${HANDSHAKE_DIR}/${filename}.pcap"
						if [ -f "$filecheck" ]; then
							LOG magenta "Trashing .pcap: ${filecheck}"
							# rm "$filecheck"
							mv "$filecheck" "${TRASHBIN_DIR}/$(basename ${filecheck})"
							count=$((count + 1))
						fi
						filecheck="${HANDSHAKE_DIR}/${filename}.cap"
						if [ -f "$filecheck" ]; then
							LOG magenta "Trashing .cap: ${filecheck}"
							# rm "$filecheck"
							mv "$filecheck" "${TRASHBIN_DIR}/$(basename ${filecheck})"
							count=$((count + 1))
						fi
						LOG " "
					fi
				done
				LED GREEN
				RINGTONE "hack_stealth"
				LOG green "$count Handshake Files Removed for SSID: ${SSIDCHECK}"
				LOG "Press OK to continue..."
				LOG " "
				WAIT_FOR_BUTTON_PRESS A
			else
				LOG "Skipped removing Handshake files for SSID: ${SSIDCUR}"
				LOG " "
			fi
			# run again?
			resp=$(CONFIRMATION_DIALOG "Do you want to remove more or check/empty the trash bin?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				LOG cyan "Running tool again..."
				LOG " "
			else
				LOG green "Finished!"
				LOG " "
				break
			fi
		else
			LOG "Skipped Clear/Delete Handshakes..."
			LOG " "
			break
		fi
	done
}

LED MAGENTA
LOG magenta "-----------================-----------"
LOG cyan    "========= Handshake Cleaner =========="
LOG magenta "-----------================-----------"
LOG "Removes handshakes matching SSID"
LOG magenta "-----------================-----------"
LOG "Trash bin holds removed data"
LOG magenta "-----------================-----------"
LOG cyan    "------------ by cncartist ------------"
LOG magenta "-----------================-----------"

LOG green "Press OK to start..."
LOG " "
WAIT_FOR_BUTTON_PRESS A
sleep 0.25

select_ssid_delete

exit 0
