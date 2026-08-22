#!/bin/bash
# Title: Bluetooth PineFlipKill - WiFi Pineapple, Flipper, and USB Kill Scanner
# Author: cncartist
# Description: WiFi Pineapple BT / Flipper Zero / USB Kill BT Scanner.  Allows scanning with external USB Bluetooth adapter and GPS coordinate logging.
# Category: reconnaissance
# Version: 1.0
# 
# Acknowledgements: 
# Find Hackers - Author: NULLFaceNoCase - (idea and concept for searching BT devices)
# Incident Response Forensic Collector - Author: curtthecoder - (logging example)

# ---- CONFIG ----
LOOT_BASE="/root/loot/csec/"; LOOT_DIR="${LOOT_BASE}bt-pineflipkill"
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
REPORT_DETECT_FILE="$LOOT_DIR/Report_${TIMESTAMP}.txt"
DATASTREAMBT_FILE="$LOOT_DIR/DataBT_${TIMESTAMP}.txt"
DATASTREAMBT2_FILE="$LOOT_DIR/DataBT2_${TIMESTAMP}.txt"
DATASTREAMBT3_FILE="$LOOT_DIR/DataBT3_${TIMESTAMP}.txt"
DATASTREAMBTTMP_FILE="$LOOT_DIR/DataBTTMP_${TIMESTAMP}.txt"

# ---- DEFAULTS ----
scan_BT_FLIPPERS="false"
scan_BT_USBKILLS="false"
scan_BT_PINEAPPS="false"
gpspos_last=""

# ---- BLE ----
BLE_IFACE="hci0"
#number in seconds
DATA_SCAN_SECONDS=10

# ---- ARRAYS ----
declare -A BT_FLIPPERS
declare -A BT_USBKILLS
declare -A BT_PINEAPPS
declare -A BT_NAMES
declare -A BT_COMPS

# BT
# USBKiller F1:9E:08
# Wifi Pineapple Pager 00:13:37
# (VirtualBox) 08:00:27

cleanup() {
    killall hcitool 2>/dev/null
	killall btmon 2>/dev/null
	rm "$DATASTREAMBT_FILE" 2>/dev/null
	rm "$DATASTREAMBT2_FILE" 2>/dev/null
	rm "$DATASTREAMBT3_FILE" 2>/dev/null
	rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
    sleep 0.5
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM

# Check for required tools
check_dependencies() {
	if ! command -v hciconfig &> /dev/null; then
		ERROR_DIALOG "hciconfig not installed"
		LOG red "Install with: opkg update && opkg install bluez-utils"
		exit 1
	fi
	if ! command -v btmon &> /dev/null; then
		ERROR_DIALOG "btmon not installed"
		LOG red "Install with: opkg update && opkg install bluez-utils"
		exit 1
	fi
	# ORIGINAL <root> grep -V
	# grep: unrecognized option: V
	# BusyBox v1.36.1 (2025-04-13 16:38:32 UTC) multi-call binary.
	# 
	# NEW <root> grep -V
	# grep (GNU grep) 3.11
	local grepCheck=0; local count=0; local limit=3; local substring="BusyBox v"; local substring2='grep (GNU grep)'
	# check grep
	while IFS= read -r line && [[ "$count" -lt "$limit" ]] ; do
		# if [[ "$line" == *"$substring"* ]]; then
			# LOG "Grep is original version"
		# el
		if [[ "$line" == *"$substring2"* ]]; then
			# LOG "Grep is GNU version"
			grepCheck=1
		fi
		count=$((count + 1))
	done < <(
		grep -V
	)
	if [[ "$grepCheck" -eq 0 ]] ; then
		local dependText=""
		# ask if they want to install now
		# without grep the app will run but, device names will show as "Unknown"
		if [[ "$grepCheck" -eq 0 ]]; then
			dependText="GNU grep"
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
					LOG green "Package installed!"
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
			LOG blue  "================================================="
			LOG cyan "== Or all in one command ->"
			LOG "opkg update && opkg install grep"
			LOG blue  "================================================="
			sleep 1
			exit 1
		fi
	fi
}


# restart bluetoothd if not running
bluetoothd_check() {
	# service bluetoothd restart
	# service bluetoothd status
	# not running
	# /etc/bluetooth/keys/
	# name coming from lsusb when bluetoothd not running
	# nano /etc/hotplug.d/usb/10-tty-naming 
	local loop=0
	while true; do
		# LOG red "in loop"
		loop=$((loop + 1))
		if service bluetoothd status | grep -q "not"; then
			# echo "NOT RUNNING"
			# echo "trying restart..."
			service bluetoothd restart
			sleep 1
			if [[ "$loop" -eq 5 ]] ; then
				# echo "== NOT RUNNING after $loop tries! ==="
				break
			fi
		else
			# echo "RUNNING!"
			break
		fi
	done
}

# Reset Bluetooth adapter to prevent errors/hanging	
reset_bt_adapter() {
	LED WHITE
	killall hcitool 2>/dev/null
	hciconfig "$BLE_IFACE" down
	# sleep 0.2; rmmod btusb; sleep 0.2; modprobe btusb; sleep 0.2
	sleep 0.5
	while true; do
		# hciconfig "$BLE_IFACE" up		
		if ! hciconfig "$BLE_IFACE" up 2>/dev/null; then
			sleep 0.5
			# LOG red "Interface DOWN!: $BLE_IFACE"
			# LOG red "Resetting"
			hciconfig "$BLE_IFACE" reset 2>/dev/null
			sleep 1.5
			# LOG red "Trying to bring back up..."
			hciconfig "$BLE_IFACE" up 2>/dev/null
			sleep 0.5
		else
			# LOG green "Interface UP!: $BLE_IFACE"
			break
		fi
	done
}

flipper_search_bt() {
	# ---- DEFAULTS ----
	local FLIPPER_OUI="0C:FA:22"
	local FLIPPER_NAME="flipper"
	local FLIPPER_NAME2="badusb"
	local USBKILL_OUI="F1:9E:08"
	local USBKILL_NAME="usbkill"
	
	local PINEAPP_OUI="00:13:37"
	local PINEAPP_NAME="pine"
	local PINEAPP_NAME2="bluez"
	local PINEAPP_NAME3="pager"
	
	reset_bt_adapter
	LED CYAN SLOW
	# Enable case-insensitive matching
	shopt -s nocasematch
    while read -r line; do
        mac=${line%% *}
        name=${line#"$mac"}
        name=${name# }
		target_oui="${mac:0:8}"
		
		# Pineapple pager is BT CLASSIC
		# if [[ "$line" == *"$PINEAPP_OUI"* ]] || [[ "$line" == *"$PINEAPP_NAME"* ]] || [[ "$line" == *"$PINEAPP_NAME2"* ]] || [[ "$line" == *"$PINEAPP_NAME3"* ]] ; then
			# Add hits, devices that include string "pine" in name or hardcoded OUI in MAC
			# BT_PINEAPPS[$mac]="${name}${comp}"
			# LOG "WiFi Pineapple found!"
		# fi
		if [[ "$target_oui" == "$FLIPPER_OUI" ]] || [[ "$name" == *"$FLIPPER_NAME"* ]] || [[ "$name" == *"$FLIPPER_NAME2"* ]] ; then
			# Add hits, devices that include string "flipper" in name or hardcoded OUI in MAC
			BT_FLIPPERS[$mac]="$name"
			# LOG "FLIPPER found!"
		fi
		if [[ "$target_oui" == "$USBKILL_OUI" ]] || [[ "$name" == *"$USBKILL_NAME"* ]] ; then
			# Add hits, devices that include string "usbkill" in name or hardcoded OUI in MAC
			BT_USBKILLS[$mac]="$name"
			# LOG "USBKILL found!"
		fi
    done < <(
        timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" lescan |
        grep -iE "^${FLIPPER_OUI}|${FLIPPER_NAME}|${FLIPPER_NAME2}|${USBKILL_OUI}|${USBKILL_NAME}|${PINEAPP_OUI}|${PINEAPP_NAME}|${PINEAPP_NAME2}|${PINEAPP_NAME3}" |
        sort -u
    )
	# Disable case-insensitive matching to restore default behavior
	shopt -u nocasematch
	# timeout --signal=SIGINT 5s hcitool -i hci0 lescan
}

wifipine_search_bt() {
	# ---- DEFAULTS ----
	local PINEAPP_OUI="00:13:37"
	local PINEAPP_NAME="pine"
	local PINEAPP_NAME2="bluez"
	local PINEAPP_NAME3="pager"
		
	local pattern1="Address:"
	local pattern2="Company:"
	local pattern3="Service Data:"
	local pattern4="Name \(complete\):"
	
	reset_bt_adapter
	LED BLUE SLOW
	# LOG red "btmon"
	# (btmon &> "$DATASTREAMBTTMP_FILE") &
	(timeout --signal=SIGINT "$((DATA_SCAN_SECONDS+2))s" btmon &> "$DATASTREAMBTTMP_FILE") &
	sleep 1
	# LOG red "hcitool"
	# (hcitool -i "$BLE_IFACE" lescan) &
	(timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" scan) &
	# LOG red "sleep"
	# sleep $((DATA_SCAN_SECONDS + 1))
	sleep ${DATA_SCAN_SECONDS}
		
	#finish scans
	killall hcitool 2>/dev/null
	killall btmon 2>/dev/null
	
	LED YELLOW
	# LOG magenta "testing here"
		
	if [[ -s "$DATASTREAMBTTMP_FILE" ]]; then
		# process file
		# LOG magenta "START process file"
		LED BLUE
		# add extra lines to file
		printf "\n\n\n\n" >> "$DATASTREAMBTTMP_FILE"
		
		# removing pineapple pager reading itself as an item via hardware info
			# still allows it to detect other interface if enabled
			# test with discoverable pineapple pager to see where it shows up
			# hciconfig -a # show status
			# hciconfig hci0 up piscan # make discoverable
			# hciconfig hci0 up noscan # turn off discoverable
		# remove these lines and two after # sed -i '/PATTERN/,+2d' "$DATASTREAMBTTMP_FILE"
		sed -i '
		/BR\/EDR Address:/ {d}; 
		/Command: Delete Stored Li/ {N;N;d}; 
		/Command: LE Set Random Addr/ {N;N;d}; 
		/Command: LE Set Adverti/ {N;N;d}; 
		/Command: LE Set Scan Res/ {N;N;d}; 
		/Command: Read Stored Li/ {N;N;d}; 
		/Command: Write Local Na/ {N;N;d}; 
		/Command: Write Extended I/ {N;N;d}; 
		/Event: Local Name Chang/ {N;N;d}; 
		/HCI Command: Read BD ADD/ {N;N;N;N;d}; 
		/MGMT Event: Command Compl/ {N;N;N;N;d};
		' "$DATASTREAMBTTMP_FILE"
		
		# -E extended regular expressions
		# -i case insensitive (don't use here)
		# grep -iE "$pattern1|$pattern2|$pattern3|$pattern4" "testlescan.txt" > "testlescanout.txt"
		grep -E "$pattern1|$pattern2|$pattern3|$pattern4" "$DATASTREAMBTTMP_FILE" > "$DATASTREAMBT_FILE"
		# add extra lines to separate addresses
		sed -i 's/Address:/\n\n\nAddress:/' "$DATASTREAMBT_FILE"
		# cp "$DATASTREAMBT_FILE" "$LOOT_DIR/test.txt"
		
		# load addresses only into tmp file
		grep -E "Address:" "$DATASTREAMBT_FILE" | sort -n | uniq > "$DATASTREAMBT2_FILE"
		
		LED GREEN
		# clean up output file via temp file addresses
		while IFS= read -r line; do
			# LOG "$line"
			# mac=$(echo "${line}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
			# if [[ -n "$mac" ]]; then
			if mac=$(echo "${line}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -n 1); then
				# LOG "mac: ${mac}"
				awk -v pattern="Address: $mac" '
					$0 ~ pattern {  # If the current line matches the pattern
						count++
						if (count > 3) {
							delete_lines = 4  # Set a flag to delete 4 lines (the matched line + 3 following)
						}
					}
					delete_lines > 0 {  # If the delete flag is set
						delete_lines--  # Decrement the count for lines to delete
						next            # Skip printing the current line
					}
					{ print }           # Print all other lines
				' "$DATASTREAMBT_FILE" > "$DATASTREAMBT3_FILE"
				mv "$DATASTREAMBT3_FILE" "$DATASTREAMBT_FILE" # To edit the file in place
			fi
		done < "$DATASTREAMBT2_FILE"
		
		rm "$DATASTREAMBTTMP_FILE"
		rm "$DATASTREAMBT2_FILE"
		
		LED YELLOW
		# fix for reading too far ahead and skipping items
		# remove whitespace and tabs
		sed -i -e 's/^[[:space:]]*//' -e '/^[[:space:]]*$/d' "$DATASTREAMBT_FILE"
		# add extra lines to separate addresses
		sed -i 's/Address:/\n\n\nAddress:/' "$DATASTREAMBT_FILE"
		# add extra lines at end of file
		printf "\n\n\n" >> "$DATASTREAMBT_FILE"
		
		# LOG magenta "DONE process file"
	fi
	# sleep 0.5
	
	# check if file is not empty this time around
	if [[ -s "$DATASTREAMBT_FILE" ]]; then
		LED RED
		# LOG "file has contents"			
		while IFS= read -r line; do
			# LOG "$line"
			# LOG red "while IFS"
			
			if echo "$line" | grep -q "Address:"; then
				# Capture the next few lines containing address, and data
				mapfile -n 3 -t info < <(head -n 3)
				
				# Parse MAC Address
				mac=$(echo "${line}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
				# LOG red "macCHECK: ${mac}"
				
				# If mac exists / not empty
				# if [[ -n "$mac" ]] && [[ "$mac" != "00:00:00:00:00:00" ]]; then
				if [[ -n "$mac" ]]; then
					# Parse Name/Data
					# name=$((echo "${info[0]}" | grep -oP '(?<=Name ).*' || echo "Unknown") | cut -d' ' -f2)
					name=$(echo "${info[0]}" | grep -oP '(?<=Name ).*' || echo "Unknown")
					if [[ "$name" == "Unknown" ]] ; then
						name=$(echo "${info[1]}" | grep -oP '(?<=Name ).*' || echo "Unknown")
					fi
					# remove extra starting text for name string
					name="${name#(complete): }"
					# trim var
					name=$(echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
					# set option
					shopt -s extglob
					# remove text from end in paren with leading space
					name="${name% *\(*}"
					# LOG "name: ${name}"
					if [[ -z "$name" ]]; then
						name="Unknown"
					fi
				
					# Parse Hardware Data
					comp=$(echo "${info[0]}" | grep -oP '(?<=Company: ).*' || echo "n/a")
					if [[ "$comp" == "n/a" ]] ; then
						comp=$(echo "${info[1]}" | grep -oP '(?<=Company: ).*' || echo "n/a")
						sdata=$(echo "${info[0]}" | grep -oP '(?<=Service Data: ).*' || echo "n/a")
						if [[ "$sdata" == "n/a" ]] ; then
							sdata=$(echo "${info[1]}" | grep -oP '(?<=Service Data: ).*' || echo "n/a")
						fi
						if [[ "$comp" == "n/a" ]] ; then
							comp="$sdata"
						fi
					fi
					# LOG "comp: ${comp}"
					# trim var
					comp=$(echo "$comp" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
					# LOG "comp1: ${comp}"
					# remove text from end in paren with leading space
					comp="${comp% *\(*}"
					if [[ "$comp" == "not assigned" ]] || [[ "$comp" == "Unknown" ]] || [[ "$comp" == "Device Information" ]] ; then
						comp="n/a"
					fi
					# LOG "comp2: ${comp}"
					
					namecheck="${BT_NAMES[$mac]}"
					# LOG "namecheck: ${namecheck}"
					# if namecheck not empty
					if [[ -n "$namecheck" ]]; then
						# LOG "namecheck"
						# check vs current name
						# if name not equal current name
						if [[ "$namecheck" != "$name" ]] && [[ "$name" != "Unknown" ]]; then
							# then set name string to new text
							BT_NAMES[$mac]="$name"
							# LOG red "override name"
						fi
					else
						if [[ -n "$name" ]]; then
							BT_NAMES[$mac]="$name"
						fi
					fi
				
					compcheck="${BT_COMPS[$mac]}"
					# if compcheck not empty
					if [[ -n "$compcheck" ]]; then
						# LOG "compcheck"
						# check vs current comp
						# if comp not equal current company or service data
						if [[ "$compcheck" != "$comp" ]] && [[ "$comp" != "n/a" ]]; then
							# then set comp string to new text
							BT_COMPS[$mac]="$comp"
						fi
					else
						if [[ -n "$comp" ]]; then
							BT_COMPS[$mac]="$comp"
						fi
					fi
					
					# change option back
					shopt -u extglob
				fi					
			fi				
		done < "$DATASTREAMBT_FILE"
		
		# if BT_NAMES[$mac] is empty, tell user no signals found
		if [ ${#BT_NAMES[@]} -eq 0 ]; then
			LOG "No classic bluetooth signals found..."
			printf "No classic bluetooth signals found...\n" >> "$REPORT_DETECT_FILE"
		fi
		
		# exit after 1 loop for testing
		# LOG "exit for testing"; exit 0
		
		LED MAGENTA
		# Enable case-insensitive matching
		shopt -s nocasematch
		
		# LOG "re-order" # sort
		# A more robust approach using a while loop:
		while IFS= read -r line; do
			# Extract value and key from the line
			key=$(echo "$line" | cut -d' ' -f1)
			value=$(echo "$line" | cut -d' ' -f2-)
			# LOG "reorder ${key}: ${value}"
			
			# Show each BT device found
			mac="$key"
			target_oui="${mac:0:8}"
			name="${BT_NAMES[$mac]}"
			comp="${BT_COMPS[$mac]}"
			if [[ "$comp" == "n/a" ]] ; then
				comp=""
			else
				if [[ -z "$name" ]] || [[ "$name" == "Unknown" ]] ; then
					name="$comp"
					comp=""
				else
					comp="/$comp"
				fi 
			fi
			 
			if [[ "$target_oui" == "$PINEAPP_OUI" ]] || [[ "$name" == *"$PINEAPP_NAME"* ]] || [[ "$name" == *"$PINEAPP_NAME2"* ]] || [[ "$name" == *"$PINEAPP_NAME3"* ]] ; then
				# Add hits, devices that include string "pine" in name or hardcoded OUI in MAC
				BT_PINEAPPS[$mac]="${name}${comp}"
				# LOG "WiFi Pineapple found!"
				# LOG "${mac} - ${name}${comp}"
			fi
			
			# printf "%s - %s%s\n" "${mac}" "${name}" "${comp}" >> "$REPORT_DETECT_FILE"
			
		done < <(
			for key in "${!BT_NAMES[@]}"; do
				echo "$key ${BT_NAMES[$key]}"
			done | sort -n
		)
		# sort -rn for descending, sort -n for ascending
		# LOG "DONE re-order"
		# Disable case-insensitive matching to restore default behavior
		shopt -u nocasematch
				
		# LOG "-- MAC Address -- - Name/Manuf"
		# LOG "------------------------------"
		
	else
		LOG "No classic bluetooth signals found..."
		printf "No classic bluetooth signals found...\n" >> "$REPORT_DETECT_FILE"
	fi

}

# detection scans
scan_detection() {
	/etc/init.d/gpsd reload 2>/dev/null
	/etc/init.d/gpsd restart 2>/dev/null
	
	# ---- DEFAULTS ----
	local detections=0
	
	# Check for BT device with WiFi Pineapple/Flipper/USB Killer characteristics
	# Confirm Scan
	resp=$(CONFIRMATION_DIALOG "Scan for WiFi Pineapple/Flipper/USB Kill Style Bluetooth Devices?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
	
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		REPORT_DETECT_FILE="$LOOT_DIR/Report_${TIMESTAMP}.txt"
		DATASTREAMBT_FILE="$LOOT_DIR/DataBT_${TIMESTAMP}.txt"
		DATASTREAMBT2_FILE="$LOOT_DIR/DataBT2_${TIMESTAMP}.txt"
		DATASTREAMBT3_FILE="$LOOT_DIR/DataBT3_${TIMESTAMP}.txt"
		DATASTREAMBTTMP_FILE="$LOOT_DIR/DataBTTMP_${TIMESTAMP}.txt"
	
		printf "═══════════════════════════════════════════════════════════════\n" > "$REPORT_DETECT_FILE"
		printf "  Bluetooth PineFlipKill Scan - Report\n" >> "$REPORT_DETECT_FILE"
		printf "  WiFi Pineapple/Flipper/USB Kill Device BT Scan\n" >> "$REPORT_DETECT_FILE"
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_DETECT_FILE"
		printf "═══════════════════════════════════════════════════════════════\n\n" >> "$REPORT_DETECT_FILE"
		printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"

		LED MAGENTA
		# LOG cyan "WiFi Pineapple/Flipper/USB Kill Device BT Scan"
		# printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
		
		while true; do
			detections=0
			
			unset BT_FLIPPERS
			unset BT_USBKILLS
			unset BT_PINEAPPS
			# unset BT_NAMES
			# unset BT_COMPS
			
			declare -A BT_FLIPPERS
			declare -A BT_USBKILLS
			declare -A BT_PINEAPPS
			# declare -A BT_NAMES
			# declare -A BT_COMPS
			
			# gps check
			gpspos_cur=$(GPS_GET)
			if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
				gpspos_last="$gpspos_cur" # GPS is valid
				printf "GPS Pos.: %s\n" "${gpspos_last}" >> "$REPORT_DETECT_FILE"
			else
				if [[ -n "$gpspos_last" ]] ; then # gps lost, last known coordinates: gpspos_last
					printf "GPS LOST! %s (Last Known Pos.)\n" "${gpspos_last}" >> "$REPORT_DETECT_FILE"
				fi
			fi
			
			if [[ "$scan_BT_PINEAPPS" == "true" ]] ; then
				LED BLUE SLOW
				LOG cyan "Scanning for WiFi Pineapple BT Signals..."
				LOG cyan "Scanning for ${DATA_SCAN_SECONDS}s..."
				printf "Scanning for WiFi Pineapple BT Signals...\n" >> "$REPORT_DETECT_FILE"
				printf "Scanning for %ss...\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_DETECT_FILE"
				# run function to search wifi pine Classic
				wifipine_search_bt
				LOG " "
				sleep 1
			fi			
			
			if [[ "$scan_BT_FLIPPERS" == "true" ]] || [[ "$scan_BT_USBKILLS" == "true" ]] ; then
				LED CYAN SLOW
				LOG cyan "Scanning for Flipper/USB Kill BT Signals..."
				LOG cyan "Scanning for ${DATA_SCAN_SECONDS}s..."
				printf "Scanning for WiFi Pineapple/Flipper/USB Kill BT Signals...\n" >> "$REPORT_DETECT_FILE"
				printf "Scanning for %ss...\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_DETECT_FILE"
				# run function to search flipper + usb kills LE
				flipper_search_bt
				LOG " "
				sleep 1
			fi
			
			LED MAGENTA
			
			if [[ "$scan_BT_PINEAPPS" == "true" ]] ; then
				if [[ ${#BT_PINEAPPS[@]} -gt 0 ]]; then
					LOG red "-------------------------------------------"
					LED RED SLOW
					# RINGTONE "warning"
					LOG red "WARNING: Found ${#BT_PINEAPPS[@]} potential WiFi Pineapple BT Device(s)"
					printf "\n" >> "$REPORT_DETECT_FILE"
					printf "WARNING: Found %s potential WiFi Pineapple BT Device(s).\n" "${#BT_PINEAPPS[@]}" >> "$REPORT_DETECT_FILE"
					LOG " "
					# Record each WiFi Pineapple device found
					for mac in "${!BT_PINEAPPS[@]}"; do
						name="${BT_PINEAPPS[$mac]}"
						LOG red "Potential WiFi Pineapple:\nBT Name: $name\nBT MAC: $mac"
						printf "Potential WiFi Pineapple:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
						detections=$((detections + 1))
						LOG " "
					done
					LOG red "-------------------------------------------"
				else 
					LED GREEN SLOW
					# RINGTONE "ScaleTrill"
					LOG green "No obvious WiFi Pineapple BT Devices detected."
					LOG " "
					printf "No obvious WiFi Pineapple BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
				fi
				sleep 1
			fi
			
			if [[ "$scan_BT_FLIPPERS" == "true" ]] ; then
					if [[ ${#BT_FLIPPERS[@]} -gt 0 ]]; then
					LOG red "-------------------------------------------"
					LED RED SLOW
					# RINGTONE "warning"
					LOG red "WARNING: Found ${#BT_FLIPPERS[@]} potential Flipper BT Device(s)"
					printf "\n" >> "$REPORT_DETECT_FILE"
					printf "WARNING: Found %s potential Flipper BT Device(s).\n" "${#BT_FLIPPERS[@]}" >> "$REPORT_DETECT_FILE"
					LOG " "
					# Record each BT Flipper device found
					for mac in "${!BT_FLIPPERS[@]}"; do
						name="${BT_FLIPPERS[$mac]}"
						LOG red "Potential Flipper Device:\nBT Name: $name\nBT MAC: $mac"
						printf "Potential Flipper Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
						detections=$((detections + 1))
						if [[ ${#BT_FLIPPERS[@]} -gt 1 ]]; then 
							LOG " "
						fi
					done
					LOG red "-------------------------------------------"
				else 
					LED GREEN SLOW
					# RINGTONE "ScaleTrill"
					LOG green "No obvious Flipper BT Devices detected."
					LOG " "
					printf "No obvious Flipper BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
				fi
				sleep 1
			fi
			
			if [[ "$scan_BT_USBKILLS" == "true" ]] ; then
				if [[ ${#BT_USBKILLS[@]} -gt 0 ]]; then
					LOG red "-------------------------------------------"
					LED RED SLOW
					# RINGTONE "warning"
					LOG red "WARNING: Found ${#BT_USBKILLS[@]} potential USB Kill BT Device(s)"
					printf "\n" >> "$REPORT_DETECT_FILE"
					printf "WARNING: Found %s potential USB Kill BT Device(s).\n" "${#BT_USBKILLS[@]}" >> "$REPORT_DETECT_FILE"
					LOG " "
					# Record each USB Kill device found
					for mac in "${!BT_USBKILLS[@]}"; do
						name="${BT_USBKILLS[$mac]}"
						LOG red "Potential USB Kill Device:\nBT Name: $name\nBT MAC: $mac"
						printf "Potential USB Kill Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
						detections=$((detections + 1))
						LOG " "
					done
					LOG red "-------------------------------------------"
				else 
					LED GREEN SLOW
					# RINGTONE "ScaleTrill"
					LOG green "No obvious USB Kill BT Devices detected."
					LOG " "
					printf "No obvious USB Kill BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
				fi
				sleep 1
			fi
			
			
			printf "═══════════════════════════════════════════════════════════════\n\n" >> "$REPORT_DETECT_FILE"
			printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			
			# LOG blue "-------------------------------------------"
			# LOG " "
			LOG green "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			
			rm "$DATASTREAMBT_FILE" 2>/dev/null
			rm "$DATASTREAMBT2_FILE" 2>/dev/null
			rm "$DATASTREAMBT3_FILE" 2>/dev/null
			rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
			# Confirm Scan
			resp=$(CONFIRMATION_DIALOG "Scan again?")
			if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				#LOG "User CONFIRMED"
				break
			fi
			LOG "Scanning again..."
			printf "Scanning again...\n\n" >> "$REPORT_DETECT_FILE"
		done
		
		# finished
		LED MAGENTA
		LOG green "Scans Completed!"
		printf "Scans Completed!\n" >> "$REPORT_DETECT_FILE"
		if [[ ${detections} -gt 0 ]]; then
			RINGTONE "warning"
			LOG red "$detections malicious suspects found!"
			printf "%s malicious suspects found!\n" "${detections}" >> "$REPORT_DETECT_FILE"
		else 
			RINGTONE "ScaleTrill"
			LOG green "No malicious suspects found!"
			printf "No malicious suspects found!\n" >> "$REPORT_DETECT_FILE"
		fi
		LOG " "
		printf "\n" >> "$REPORT_DETECT_FILE"
		LOG cyan "Results saved to: ${REPORT_DETECT_FILE}"
		printf "Results saved to: %s" "${REPORT_DETECT_FILE}" >> "$REPORT_DETECT_FILE"

	else
		LOG "Skipped Bluetooth Scan."
	fi
}

check_dependencies
bluetoothd_check

LED GREEN
LOG magenta "-----------================-----------"
LOG cyan    "----- Bluetooth PineFlipKill Scan ----"
LOG magenta "-----------================-----------"
LOG cyan    "----- WiFi Pineapple / Flipper BT ----"
LOG cyan    "------------- USB Kill BT ------------"
LOG magenta "-----------================-----------"
LOG cyan    "------------ by cncartist ------------"
LOG magenta "-----------================-----------"
LOG "Bluetooth will scan, then allow re-scan."
LOG " "
LOG "Please note: Scan duration will be used for both Classic + LE, scanning each for the selected duration."
LOG magenta "================================="
LOG green "Press OK when Ready to Start..."
LOG " "
WAIT_FOR_BUTTON_PRESS A

# External Bluetooth Adapter?
resp=$(CONFIRMATION_DIALOG "Do you have USB/External Bluetooth enabled & plugged in?")
if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
	#LOG "User CONFIRMED"
	if hciconfig | grep -q hci1; then
		BLE_IFACE="hci1"
		LOG green "USB Bluetooth found!"
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
	else
		BLE_IFACE="hci0"
		LOG red "Device hci1 not found!"
		LOG red "Using hci0 / default device for scanning."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
	fi
fi

# ASK HOW MANY SECONDS TO SCAN - $DATA_SCAN_SECONDS
# Longer times = larger file
DATA_SCAN_SECONDS=$(NUMBER_PICKER "Scan duration (seconds):" $DATA_SCAN_SECONDS)
case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) DATA_SCAN_SECONDS=$DATA_SCAN_SECONDS ;; esac
[ $DATA_SCAN_SECONDS -lt 3 ] && DATA_SCAN_SECONDS=3
[ $DATA_SCAN_SECONDS -gt 20 ] && DATA_SCAN_SECONDS=20


scan_BT_FLIPPERS="true"
scan_BT_USBKILLS="true"
scan_BT_PINEAPPS="true"

scan_detection

exit 0