#!/bin/bash
# Title: Bluetooth Device Hunter
# Author: cncartist
# Description: Bluetooth Device Hunter (Classic + LE combined or separate).  Data builds over time in case name or manufacturer is missed on first scans.  Custom configuration allowed.  Verbose logging / debugging / mute / privacy mode available.  Includes GPS coordinate logging if GPS device enabled.
# Category: reconnaissance
# Version: 1.0
# 
# Acknowledgements: 
# Find Hackers - Author: NULLFaceNoCase - (idea and concept for searching BT devices)
# Incident Response Forensic Collector - Author: curtthecoder - (logging example)
# 
# ================================================
# Includes: 
# ================================================
#  -- Bluetooth Device Hunter (Classic + LE combined or separate).
#  -- -- -- RSSI meter for each found signal, best signal showing at the bottom of the screen.
#  -- -- -- Custom configuration allowed and data builds over time in case name or manufacturer is missed on first scans.
#  -- -- -- Verbose logging / debugging available, GPS coordinate logging if GPS device enabled.
#  -- Privacy / Streamer Mode:
#  -- -- -- (obscures MAC + Targets/Device Names) allows full functionality while obscuring ALL identifying information on screen.
#  -- Debug Mode:
#  -- -- -- Saves full data stream for each Bluetooth scan at multiple points.  Please be aware these files can add up over time and it's best to clear them out or turn off debugging mode if not actively using them for debugging.
# 
# ================================================
#               LED STATUS
# ================================================
#             ------ start ------
# GREEN:            Configuration
# MAGENTA:          IDLE
#             ------ scanning ------
# WHITE:            Resetting adapter
# BLUE SLOW blink:  Scanning Bluetooth Classic
# CYAN SLOW blink:  Scanning Bluetooth LE
# WHITE:            Finished scans
# BLUE:             Cleanup / pre-processing
# GREEN:            Build result file for processing
# YELLOW:           String manipulation of result file
# RED:              Final looping results for display
# MAGENTA:          Finished processing
#             ------ scanning ------
# ================================================
# 
# ================================================
# Notes:
# ================================================
#  -- Device Hunter Scan: 
#  -- -- -- Press back to close out the payload
#  -- -- -- If locating a specific item, sometimes it's best to get multiple scans in close proximity to confirm the strength is accurate.
#  -- -- -- The best way to get used to the sensitivity is to scan for known devices and locate them within close range to see the sensitivity received.
#  -- -- -- There are many factors in Bluetooth sensitivity; walls & windows bounce or weaken signal, desks/objects can weaken signal, orientation of the pager can matter, and signals can look weak until you get closer to the actual source/Bluetooth chip on the target device. 
#  -- -- -- Using an external USB CSR8510 / CSR v4.0 Bluetooth Adapter, you can achieve better sensitivity and range.
#  -- Bluetooth: 
#  -- -- -- If you boot up the pager with USB bluetooth plugged in, it may reverse the hci addressing.
#  -- -- -- -- - Please boot the pager WITHOUT a USB device connected for hci0 to be addressed as the first default device.
#  -- Debug / Logging:
#  -- -- -- Includes GPS coordinate logging if GPS device enabled.
#  -- -- -- -- - When GPS device enabled, Device Hunter Scan will show 'NoGPS' or '+GPS+' depending on GPS status.
#  -- -- -- With debug enabled, log files will add up quickly over time in filesize.
#  -- -- -- -- - Please take care to only debug when needed; it keeps full BT scan LOG files which take significant space.
# 

# ---- CONFIG ----
LOOT_BASE="/root/loot/csec/"; LOOT_DIR="${LOOT_BASE}bt-device-hunter"
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
REPORT_FILE="$LOOT_DIR/${TIMESTAMP}_Report.txt"
DATASTREAMBT_FILE="$LOOT_DIR/${TIMESTAMP}_DataBT.txt"
DATASTREAMBT2_FILE="$LOOT_DIR/${TIMESTAMP}_DataBT2.txt"
DATASTREAMBT3_FILE="$LOOT_DIR/${TIMESTAMP}_DataBT3.txt"
DATASTREAMBTTMP_FILE="$LOOT_DIR/${TIMESTAMP}_DataBTTMP.txt"
DATA_SCAN_SECONDS=7

# ---- BLE ----
BLE_IFACE="hci0"

# ---- ARRAYS ----
declare -A BT_RSSIS
declare -A BT_NAMES
declare -A BT_COMPS

# ---- DEFAULTS ----
scan_default="false"
scan_btle="false"
scan_btclassic="false"
scan_infrepeat=0
scan_mute="false"
scan_debug="false"
cancel_press=0
cancel_app=0
scan_privacy=0
priv_name_txt="-+ Name Hidden +-"
rssitxt_switch="rssitxtsw_hci0"
gpspos_last=""

# ---- REGEX ----
VALID_MAC="([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"

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

# Check for ringtones, optional install/copy
check_ringtones() {
	# Define source and destination directories
	local DEST_DIR="/lib/pager/ringtones"
	# Define the list of six files in an array
	local FILES=("Achievement.rtttl" "glitchHack.rtttl" "sideBeam.rtttl")
	local count=0; local DEST_PATH=""; local ringtone_file=""
	# Loop through the files array
	for FILE_NAME in "${FILES[@]}"; do
		DEST_PATH="$DEST_DIR/$FILE_NAME"
		# Check if the file exists in the destination directory
		if [ ! -f "$DEST_PATH" ]; then
			# LOG "File $FILE_NAME is missing in $DEST_DIR. Copying..."
			count=$((count + 1))
		fi
	done
	if [[ "$count" -gt 0 ]] ; then
		LOG "Sound Effects / Ringtones missing..."
		resp=$(CONFIRMATION_DIALOG "ALERT! 

									$count Sound Effects / Ringtones are missing from your ringtone dir.
		
									Copy them to your pagers ringtone dir for an optimal experience?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LOG "Copying Sound Effects / Ringtones..."
			for FILE_NAME in "${FILES[@]}"; do
				DEST_PATH="$DEST_DIR/$FILE_NAME"
				# Check if the file exists in the destination directory
				if [ ! -f "$DEST_PATH" ]; then
					# Copy the file
					# LOG "File $FILE_NAME is missing in $DEST_DIR. Copying..."
					if [[ "$FILE_NAME" == "Achievement.rtttl" ]]; then
						ringtone_file="Achievement:d=16,o=5,b=125:c6,e6,g6,c7,e7,g7"
					elif [[ "$FILE_NAME" == "glitchHack.rtttl" ]]; then
						ringtone_file="GlitchHack:d=16,o=5,b=285:c,g,c6,p,b,p,a,p,g,p,4c"
					elif [[ "$FILE_NAME" == "sideBeam.rtttl" ]]; then
						ringtone_file="SideBeam:d=16,o=5,b=565:b,f6,f6,b,f6,f6,b,f6,f6"
					fi					
					LOG "Copying ${FILE_NAME}..."
					printf "%s\n" "$ringtone_file" > "$DEST_PATH"
					# cp "$SOURCE_PATH" "$DEST_PATH" 2>/dev/null
				fi
			done
			LOG green "Sound Effects / Ringtones Copied!"
		else
			LOG magenta "Skipped Copying Sound Effects / Ringtones..."
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

# switch text based on device
# rssi scale works, but with built in BT (hci0) we want better visual feedback
# an extra * to adjust for less sensitivity on built in BT (hci0)
rssitxtsw_hci0() {
	case "$rssi" in
		1[0-2][0-9]|130)   # Matches 100-130
			rssitxt="_______${rssi}"
			# LOG "MATCH ${rssi} ${mac}"
			;;
		9[1-9])   # Matches 91-99
			rssitxt="*_______${rssi}"
			# LOG "MATCH ${rssi} ${mac}"
			;;
		90|[8][6-9])       # Matches 86-90
			rssitxt="**______${rssi}"
			;;
		[8][0-5])       # Matches 80-85
			rssitxt="${rssi}*_______"
			;;
		[7][4-9])       # Matches 74-79
			rssitxt="${rssi}**______"
			;;
		[7][0-3]|[6][8-9])       # Matches 68-73
			rssitxt="${rssi}***_____"
			;;
		[6][2-7])       # Matches 62-67
			rssitxt="${rssi}****____"
			;;
		[6][0-1]|[5][6-9])       # Matches 56-61
			rssitxt="${rssi}*****___"
			;;
		[5][0-5])       # Matches 50-55
			rssitxt="${rssi}******__"
			;;
		[4][4-9])       # Matches 44-49
			rssitxt="${rssi}*******_"
			;;
		[4][0-3]|[3][8-9])       # Matches 38-43
			rssitxt="${rssi}********"
			;;
		[12][0-9]|3[0-7]) # Matches 37-10
			rssitxt="${rssi}********"
			;;
		[1-9]) # Matches 9-1
			rssitxt="${rssi}*********"
			;;
		*)
			rssitxt="__________"
			# LOG "Invalid input ${rssi} ${mac}"
			;;
	esac
}
# switch text based on device
# with a usb adapter we acheive 5-10dBm better on average
rssitxtsw_hci1() {
	case "$rssi" in
		1[0-2][0-9]|130)   # Matches 100-130
			rssitxt="_______${rssi}"
			# LOG "MATCH ${rssi} ${mac}"
			;;
		9[1-9])   # Matches 91-99
			rssitxt="________${rssi}"
			# LOG "MATCH ${rssi} ${mac}"
			;;
		90|[8][6-9])       # Matches 86-90
			rssitxt="*_______${rssi}"
			;;
		[8][0-5])       # Matches 80-85
			rssitxt="**______${rssi}"
			;;
		[7][4-9])       # Matches 74-79
			rssitxt="${rssi}*_______"
			;;
		[7][0-3]|[6][8-9])       # Matches 68-73
			rssitxt="${rssi}**______"
			;;
		[6][2-7])       # Matches 62-67
			rssitxt="${rssi}***_____"
			;;
		[6][0-1]|[5][6-9])       # Matches 56-61
			rssitxt="${rssi}****____"
			;;
		[5][0-5])       # Matches 50-55
			rssitxt="${rssi}*****___"
			;;
		[4][4-9])       # Matches 44-49
			rssitxt="${rssi}******__"
			;;
		[4][0-3]|[3][8-9])       # Matches 38-43
			rssitxt="${rssi}*******_"
			;;
		[12][0-9]|3[0-7]) # Matches 37-10
			rssitxt="${rssi}********"
			;;
		[1-9]) # Matches 9-1
			rssitxt="${rssi}*********"
			;;
		*)
			rssitxt="__________"
			# LOG "Invalid input ${rssi} ${mac}"
			;;
	esac
}


# device hunter function
device_hunter() {
	/etc/init.d/gpsd reload 2>/dev/null
	/etc/init.d/gpsd restart 2>/dev/null
	
	local scannumber=0
	local founditems=0
	local pattern1="Address:"
	local pattern2="Company:"
	local pattern3="Service Data:"
	local pattern4="RSSI:"
	local pattern5="Name \(complete\):"
	local gps_disptxt=""

	printf "═══════════════════════════════════════════════════════════════\n" > "$REPORT_FILE"
	printf "  Bluetooth Device Hunter Scan\n" >> "$REPORT_FILE"
	printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_FILE"
	printf "═══════════════════════════════════════════════════════════════\n\n" >> "$REPORT_FILE"
	printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"
	
	LED MAGENTA
	if [[ "$scan_mute" == "false" ]] ; then
		RINGTONE "glitchHack"
	fi
	if [[ "$scan_debug" == "true" ]] ; then
		LOG magenta "DEBUG mode / extra logging ACTIVATED"
		LOG " "
	fi
	if [[ "$scan_btclassic" == "true" && "$scan_btle" == "true" ]] ; then
		LOG green "Scanning Classic + LE Bluetooth for ${DATA_SCAN_SECONDS}s each."
		printf "Scanning Classic + LE Bluetooth for %s seconds each.\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_FILE"
	else 
		if [[ "$scan_btclassic" == "true" ]] ; then
			LOG green "Scanning Classic Bluetooth for ${DATA_SCAN_SECONDS}s."
			printf "Scanning Classic Bluetooth for %s seconds.\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_FILE"
		fi
		if [[ "$scan_btle" == "true" ]] ; then
			LOG green "Scanning LE Bluetooth for ${DATA_SCAN_SECONDS}s."
			printf "Scanning LE Bluetooth for %s seconds.\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_FILE"
		fi
	fi
	LOG " "
	LOG "Scanning... Press BACK to stop."
	
	# first check to set header
	gpspos_cur=$(GPS_GET)
	if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
		gpspos_last="$gpspos_cur"; gps_disptxt=' +GPS+' # GPS is valid
	else
		if [[ -n "$gpspos_last" ]] ; then
			gps_disptxt=' NoGPS' # gps lost, last known coordinates: gpspos_last
		fi
	fi
	
	LOG blue "-------------------------------------------"
	LOG cyan "|- Signal -| -- MAC Address -- - Name/Manuf${gps_disptxt}"
	LOG blue "-------------------------------------------"
	
	while true; do
		scannumber=$((scannumber + 1))
		reset_bt_adapter
		
		unset BT_RSSIS
		# unset BT_NAMES
		# unset BT_COMPS
		
		rm "$DATASTREAMBTTMP_FILE"
		rm "$DATASTREAMBT_FILE"
		rm "$DATASTREAMBT2_FILE"
		
		declare -A BT_RSSIS
		# declare -A BT_NAMES
		# declare -A BT_COMPS
		founditems=0

				
		printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
		printf "%s - EVENT: Start scan #%s\n" "$(date +"%Y-%m-%d_%H%M%S")" "${scannumber}" >> "$REPORT_FILE"
		
		# set on each run
		gps_disptxt=""; gpspos_cur=$(GPS_GET)
		if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
			# GPS is valid
			gpspos_last="$gpspos_cur"; gps_disptxt=' +GPS+'
			printf "GPS Pos.: %s\n" "${gpspos_last}" >> "$REPORT_FILE"
		else
			if [[ -n "$gpspos_last" ]] ; then
				# gps lost, last known coordinates: gpspos_last
				gps_disptxt=' NoGPS'
				printf "GPS LOST! %s (Last Known Pos.)\n" "${gpspos_last}" >> "$REPORT_FILE"
			fi
		fi
		
		# LOG red "btmon"
		# (btmon &> "$DATASTREAMBTTMP_FILE") &
		(timeout --signal=SIGINT "$((DATA_SCAN_SECONDS*2+7))s" btmon &> "$DATASTREAMBTTMP_FILE") &
		sleep 1
		
		if [[ "$scan_btclassic" == "true" ]] ; then
			LED BLUE SLOW
			# LOG red "hcitool"
			# (hcitool -i "$BLE_IFACE" lescan) &
			(timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" scan --length=$DATA_SCAN_SECONDS) &
			# LOG red "sleep"
			sleep ${DATA_SCAN_SECONDS}
			if [[ "$scan_btle" == "true" ]] ; then
				reset_bt_adapter
			fi
		fi
		if [[ "$scan_btle" == "true" ]] ; then
			LED CYAN SLOW
			#run le scan second	
			(timeout --signal=SIGINT "$((DATA_SCAN_SECONDS*75/100))s" hcitool -i "$BLE_IFACE" lescan) &
			sleep $((DATA_SCAN_SECONDS*75/100))
		fi
		
		#finish scans
		killall hcitool 2>/dev/null
		killall btmon 2>/dev/null
		
		LED WHITE
		# LOG magenta "testing here"
		
		if [[ -s "$DATASTREAMBTTMP_FILE" ]]; then
			printf "%s - EVENT: Start processing\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_FILE"
			printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
			printf "|- Signal -| -- MAC Address -- - Name/Manuf\n" >> "$REPORT_FILE"
			printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
			# process file
			# LOG magenta "START process file"
			
			# add extra lines to file
			printf "\n\n\n\n" >> "$DATASTREAMBTTMP_FILE"
			
			LED BLUE
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
			# grep -iE "$pattern1|$pattern2|$pattern3|$pattern4|$pattern5" "testlescan.txt" > "testlescanout.txt"
			grep -E "$pattern1|$pattern2|$pattern3|$pattern4|$pattern5" "$DATASTREAMBTTMP_FILE" > "$DATASTREAMBT_FILE"
			# add extra lines to separate addresses
			sed -i 's/Address:/\n\n\nAddress:/' "$DATASTREAMBT_FILE"
			
			if [[ "$scan_debug" == "true" ]] ; then
				cp "$DATASTREAMBT_FILE" "$LOOT_DIR/${TIMESTAMP}_scan_${scannumber}.txt"
			fi
			
			# load addresses only into tmp file
			grep -E "Address:" "$DATASTREAMBT_FILE" | sort -n | uniq > "$DATASTREAMBT2_FILE"
			
			LED GREEN
			# clean up output file via temp file addresses
			# LOG "mac is empty, run full filter"
			while IFS= read -r line; do
				# LOG "$line"
				# mac=$(echo "${line}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
				# if [[ -n "$mac" ]]; then
				if mac=$(echo "${line}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}'); then
					# LOG "mac: ${mac}"
					# keeping enough groups to get "sweet spot" of data collection
					# too many to keep makes file to process too large
					# too little means likely missed data
					
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
			
			
			if [[ "$scan_debug" == "true" ]] ; then
				cp "$DATASTREAMBTTMP_FILE" "$LOOT_DIR/${TIMESTAMP}_scan_${scannumber}_TMP.txt"
				cp "$DATASTREAMBT2_FILE" "$LOOT_DIR/${TIMESTAMP}_scan_${scannumber}_ADDR.txt"
			fi
			rm "$DATASTREAMBTTMP_FILE"
			rm "$DATASTREAMBT2_FILE"
			
			LED YELLOW			
			
			# fix for reading too far ahead and skipping items # remove whitespace and tabs
			sed -i -e 's/^[[:space:]]*//' -e '/^[[:space:]]*$/d' "$DATASTREAMBT_FILE"
		
			# string shortening for device display # fix mfr/company names
			sed -i '
			s/Acuity Brands Lighting, Inc/Acuity/; 
			s/Afero, Inc./Afero/; 
			s/Airoha Technology Corp./Airoha/; 
			s/Amazon.com Services, Inc.\./Amazon/; 
			s/Amazon.com Services, Inc./Amazon/; 
			s/Amazon.com Services, LLC (formerly Amazon Fulfillment Service)/Amazon/; 
			s/AMICCOM Electronics Corporation/AMICCOM/; 
			s/Android Bluedroid/Bluedroid/; 
			s/Apple, Inc./Apple/; 
			s/Aruba Networks/Aruba HP/; 
			s/Audio-Technica Corporation/Audio-Technica/; 
			s/August Home, Inc/August Home/; 
			s/Automotive Data Solutions Inc/Automotive Data Solutions/; 
			s/Bestechnic(Shanghai),Ltd/Bestechnic/; 
			s/Bluetrum Technology Co.,Ltd/Bluetrum/; 
			s/Bose Corporation/Bose/; 
			s/Broadcom Corporation/Broadcom/; 	
			s/Canon Inc./Canon/; 	
			s/CUBE TECHNOLOGIES/CUBE TECH/; 
			s/Ericsson Technology Licensing/Ericsson/; 
			s/Etekcity Corporation/Etekcity/; 
			s/Facebook, Inc./Facebook/; 
			s/Fugoo, Inc./Fugoo/; 
			s/Garmin International, Inc./Garmin/; 
			s/GD Midea Air-Conditioning Equipment Co., Ltd./Midea AC/; 
			s/GoPro, Inc./GoPro/; 
			s/Guangzhou FiiO Electronics Technology Co.,Ltd/FiiO/; 
			s/Hangzhou Tuya Information  Technology Co., Ltd/Tuya Smart/; 
			s/Harman International Industries, Inc./Harman/; 
			s/Harman International/Harman/; 
			s/Hatch Baby, Inc./Hatch Baby/; 
			s/Hewlett-Packard Company/HP/; 
			s/HP Inc./HP/; 
			s/Honeywell International Inc./Honeywell/; 
			s/HUAWEI Technologies Co., Ltd./HUAWEI/; 
			s/Hubbell Lighting, Inc./Hubbell/; 
			s/IBM Corp./IBM/; 
			s/Icon Health and Fitness/iFIT/; 
			s/InvisionHeart Inc./InvisionHeart/; 
			s/iRobot Corporation/iRobot/; 
			s/Keiser Corporation/Keiser/; 
			s/KiteSpring Inc./KiteSpring/; 
			s/Klipsch Group, Inc./Klipsch/; 
			s/Leviton Mfg. Co., Inc./Leviton/; 
			s/LG Electronics/LG/; 
			s/\[LG\] webOS TV/LG webOSTV/; 
			s/Lippert Components, INC/Lippert/; 
			s/LumiGeek LLC/LumiGeek/; 
			s/Nerbio Medical Software Platforms Inc/Nerbio/; 
			s/Nest Labs Inc/Nest/; 
			s/Nikon Corporation/Nikon/; 
			s/Nintendo Co., Ltd./Nintendo/; 
			s/Nippon Seiki Co., Ltd./Nippon Seiki/; 
			s/Nokia Mobile Phones/Nokia/; 
			s/Nordic Semiconductor ASA/Nordic/; 
			s/Oculus VR, LLC/Oculus/; 
			s/OnePlus Electronics (Shenzhen) Co., Ltd./OnePlus/; 
			s/Onset Computer Corporation/Onset/; 
			s/Otodata Wireless Network Inc./Otodata/; 
			s/Phillips Connect Technologies LLC/Phillips/; 
			s/Razer Inc./Razer/; 
			s/Resmed Ltd/Resmed/; 
			s/Revvo Technologies, Inc./Revvo/; 
			s/Rivian Automotive, LLC/Rivian/; 
			s/SALTO SYSTEMS S.L./SALTO/; 
			s/Samsung Electronics Co. Ltd./Samsung/; 
			s/Samsung Electronics Co., Ltd./Samsung/; 
			s/\[TV\] Samsung 6 Series/TV Series6/;
			s/\[TV\] Samsung 7 Series/TV Series7/;
			s/\[TV\] Samsung 8 Series/TV Series8/; 
			s/Schrader Electronics/Schrader/; 
			s/Seiko Epson Corporation/Epson/; 
			s/Seibert Williams Glass, LLC/SW Glass/; 
			s/SGL Italia S.r.l./SGL Italia/; 
			s/Signify Netherlands B.V. (formerly Philips Lighting B.V.)/Signify/; 
			s/SimpliSafe, Inc./SimpliSafe/; 
			s/Skullcandy, Inc./Skullcandy/; 
			s/Sonos Inc/Sonos/; 
			s/Sony Corporation/Sony/; 
			s/Spectrum Brands, Inc./Spectrum/; 
			s/Surefire, LLC/Surefire/; 
			s/Swirl Networks, Inc./Swirl Networks/; 
			s/SZ DJI TECHNOLOGY CO.,LTD/DJI/; 
			s/TASER International, Inc./TASER/; 
			s/Telink Semiconductor Co. Ltd/Telink/; 
			s/Texas Instruments Inc./TI/; 
			s/The Chamberlain Group, Inc./Chamberlain/; 
			s/Tile, Inc./Tile/; 
			s/TomTom International BV/TomTom/; 
			s/Toshiba Corp./Toshiba/; 
			s/Trimble Navigation Ltd./Trimble/; 
			s/Ubiquitous Computing Technology Corporation/Ubiquitous/; 
			s/Valve Corporation/Valve/; 
			s/Victron Energy BV/Victron/; 
			s/Vizio, Inc./Vizio/; 
			s/Wyze Labs, Inc/Wyze/; 
			s/Yandex Services AG/Yandex/; 
			s/Qingdao Yeelink Information Technology Co., Ltd./Yeelink/; 
			s/Zhuhai Jieli technology Co.,Ltd/Zhuhai/; 
			' "$DATASTREAMBT_FILE"
			
			# 
			# 
			# add extra lines to separate addresses
			sed -i 's/Address:/\n\n\nAddress:/' "$DATASTREAMBT_FILE"
			# add extra lines at end of file
			printf "\n\n\n" >> "$DATASTREAMBT_FILE"
			
			# LOG magenta "DONE process file"
		fi
		# sleep 0.5
			
		# check if file is not empty this time around
		if [[ -s "$DATASTREAMBT_FILE" ]]; then
			# LOG "file has contents"
			LED RED
			while IFS= read -r line; do
				# LOG "$line"
				# LOG red "while IFS"
				
				if echo "$line" | grep -q "Address:"; then
					# Capture the next few lines containing address, rssi, and data
					mapfile -n 3 -t info < <(head -n 3)
					
					# Parse MAC Address
					mac=$(echo "${line}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
					# LOG red "macCHECK: ${mac}"
					
					# If mac exists / not empty
					# if [[ -n "$mac" ]] && [[ "$mac" != "00:00:00:00:00:00" ]]; then
					if [[ -n "$mac" ]]; then
						# Parse Name/Data
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
						# trim var
						name=$(echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
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
						# trim var
						comp=$(echo "$comp" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
						if [[ -z "$comp" || "$comp" == "not assigned" || "$comp" == "Unknown" || "$comp" == "Device Information" ]] ; then
							comp="n/a"
						fi
						
						namecheck="${BT_NAMES[$mac]}"
						# LOG "namecheck: ${namecheck}"
						# if namecheck not empty
						if [[ -n "$namecheck" ]]; then
							# LOG "namecheck"
							# check vs current name
							# if name not equal current name
							if [[ "$namecheck" != "$name" && "$name" != "Unknown" ]]; then
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
							if [[ "$compcheck" != "$comp" && "$comp" != "n/a" ]]; then
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
						
						rssicheck="${BT_RSSIS[$mac]}"
						if [[ -z "$rssicheck" ]]; then
							rssicheck=1000
						fi
						# Parse RSSI
						rssi=$(echo "${info[1]}" | grep -oE 'RSSI: -?[0-9]+' | cut -d' ' -f2)
						# If rssi empty
						if [[ -z "$rssi" ]]; then
							rssi=$(echo "${info[0]}" | grep -oE 'RSSI: -?[0-9]+' | cut -d' ' -f2)
							if [[ -z "$rssi" ]]; then
								rssi=$(echo "${info[2]}" | grep -oE 'RSSI: -?[0-9]+' | cut -d' ' -f2)
							fi
						fi
						if [[ "$rssi" ]]; then
							# Remove the shortest matching pattern '-' from the front of the variable, absolute value
							rssi=${rssi#-}
							if [[ "$rssi" -eq 0 ]]; then
								rssi=999
							fi
						else
							rssi=999
						fi
						# rssi=19
						# LOG "MAC: ${mac} - rssi: ${rssi} - comp: ${comp} - sdata: ${sdata} - name: ${name}"
						# Update rssi only if RSSI is better (keep best signal)					
						# ONLY if current is better than old value
						if [[ "$rssicheck" -gt "$rssi" ]]; then
							BT_RSSIS[$mac]="$rssi"
						fi
						
					fi					
				fi				
			done < "$DATASTREAMBT_FILE"
			
			# if BT_RSSIS[$mac] is empty, tell user no signals found
			if [[ "${#BT_RSSIS[@]}" -eq 0 ]] ; then
				if [[ "$scan_btclassic" == "true" && "$scan_btle" == "true" ]] ; then
					LOG "No Classic or LE Bluetooth signals found..."
					printf "No Classic or LE Bluetooth signals found...\n" >> "$REPORT_FILE"
				else 
					if [[ "$scan_btclassic" == "true" ]] ; then
						LOG "No Classic Bluetooth signals found..."
						printf "No Classic Bluetooth signals found...\n" >> "$REPORT_FILE"
					fi
					if [[ "$scan_btle" == "true" ]] ; then
						LOG "No LE Bluetooth signals found..."
						printf "No LE Bluetooth signals found...\n" >> "$REPORT_FILE"
					fi
				fi
			fi
			
			# exit after 1 loop for testing
			# LOG "exit for testing"; exit 0
			
			LED MAGENTA
			
			# LOG "re-order" # sort rssis in descending order
			# A more robust approach using a while loop:
			while IFS= read -r line; do
				# Extract value and key from the line
				value=$(echo "$line" | cut -d' ' -f1)
				key=$(echo "$line" | cut -d' ' -f2-)
				# LOG "reorder ${key}: ${value}"
				
				# Show each BT device found
				mac="$key"
				rssitxt=""
				founditems=$((founditems + 1))
				rssi="${BT_RSSIS[$mac]}"
				name="${BT_NAMES[$mac]}"
				comp="${BT_COMPS[$mac]}"
				if [[ "$comp" == "n/a" ]] ; then
					comp=""
				else
					if [[ "$name" == "Unknown" ]] ; then
						name="$comp"
						comp=""
					else
						comp="/$comp"
					fi
				fi
				# LOG "${rssi} ${mac} ${name}"
				# run RSSI switcher
				$rssitxt_switch
				printf "|%s| %s - %s%s | RSSI: %s\n" "${rssitxt}" "${mac}" "${name}" "${comp}" "${rssi}" >> "$REPORT_FILE"
				if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; comp=""; fi
				# edit name for length over pager screen
				name="${name}${comp}"; length=${#name}; if [[ "$length" -gt 17 ]] ; then name="${name:0:15}.."; fi
				LOG "|${rssitxt}| ${mac} - ${name}"
				# LOG magenta "|__________| ░░:░░:░░:░░:░░:░░ - REALLY LONG LONG NAME"
			done < <(
				for key in "${!BT_RSSIS[@]}"; do
					echo "${BT_RSSIS[$key]} $key"
				done | sort -rn
			)
			# sort -rn for descending, sort -n for ascending
			# LOG "DONE re-order"
			
		else
			if [[ "$scan_btclassic" == "true" && "$scan_btle" == "true" ]] ; then
				LOG "No Classic or LE Bluetooth signals found..."
				printf "No Classic or LE Bluetooth signals found...\n" >> "$REPORT_FILE"
			else 
				if [[ "$scan_btclassic" == "true" ]] ; then
					LOG "No Classic Bluetooth signals found..."
					printf "No Classic Bluetooth signals found...\n" >> "$REPORT_FILE"
				fi
				if [[ "$scan_btle" == "true" ]] ; then
					LOG "No LE Bluetooth signals found..."
					printf "No LE Bluetooth signals found...\n" >> "$REPORT_FILE"
				fi
			fi
		fi
		
		if [[ "$scan_mute" == "false" ]] ; then
			if [[ "$founditems" -gt 0 ]]; then
				RINGTONE "Achievement" # (short)
			else
				RINGTONE "sideBeam" # (short)
			fi
		fi
		
		LOG blue   "------------ ${founditems} signals found -------------"
		printf "%s bluetooth signals found\n" "${founditems}" >> "$REPORT_FILE"
		printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
		# LOG blue "-------------------------------------------"
		LOG cyan   "|- Signal -| -- MAC Address -- - Name/Manuf${gps_disptxt}"
		
		printf "%s - EVENT: Finish scan\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_FILE"
			
		if [[ "$scan_infrepeat" -eq 0 ]] ; then
			LOG blue   "----------------- Press OK to scan again..."
			# LOG "scan_infrepeat: $scan_infrepeat"
			WAIT_FOR_BUTTON_PRESS A
		else
			LOG blue   "------------------------- Scanning again..."
			sleep 0.25
		fi
		# LOG blue "------------ xx signals found -------------"
		# LOG blue "-------------------------------------------"
		# LOG green "Press OK to scan again..."
		# exit after 1 loop for testing
		# LOG "exit for testing"; exit 0
	done
	killall hcitool 2>/dev/null
	killall btmon 2>/dev/null
}

LED GREEN

LOG blue      "|||||||||||||||||||||||||||||||||||||||||||||||"
LOG blue      "¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨"
LOG cyan      "¨ ██████╗ ████████╗ ¨ Bluetooth Device Hunter ¨"
LOG cyan      "¨ ██╔══██╗╚══██╔══╝ ¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨"
LOG cyan      "¨ ██████╔╝ ¨ ██║ ¨¨¨¨¨¨¨¨ Classic + LE ¨¨¨¨¨¨¨¨"
LOG cyan      "¨ ██╔══██╗ ¨ ██║ ¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨"
LOG cyan      "¨ ██████╔╝ ¨ ██║ ¨¨¨ Signal Strength Tracker ¨¨"
LOG cyan      "¨ ╚═════╝ ¨¨ ╚═╝ ¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨"
LOG cyan      "||||||||||||||||||||||||| by cncartist ||||||||"
LOG blue      "¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨¨"

check_dependencies
check_ringtones
bluetoothd_check

LOG "Bluetooth will scan, show names, manufacturers, and strengths; then allow re-scan."
LOG " "
LOG "Classic + LE can be scanned together or separately."
LOG " "
LOG magenta "PLEASE NOTE: Scan duration will be used for both Classic + LE, scanning each for the selected duration."
LOG " "
LOG magenta "After scanning, data is processed for display & signal strength calculations. More devices found = longer processing time."
LOG blue "================================================="
LOG green "Press OK when Ready to Start..."
LOG " "
WAIT_FOR_BUTTON_PRESS A

# External Bluetooth Adapter?
resp=$(CONFIRMATION_DIALOG "Do you have USB/External Bluetooth enabled & plugged in?")
if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
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
	if [[ "$BLE_IFACE" == "hci0" ]]; then
		rssitxt_switch="rssitxtsw_hci0"
	else
		rssitxt_switch="rssitxtsw_hci1"
	fi
fi


# Confirm Default Scan Settings
resp=$(CONFIRMATION_DIALOG "Use Default Settings?  If not, the next questions will allow scan customization.")
if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
	scan_default="true"
	
	# START = SET HERE - Custom config for quick scans
	DATA_SCAN_SECONDS=7
	scan_btle="true"
	scan_btclassic="true"
	scan_infrepeat=1
	scan_mute="false"
	scan_debug="false"
	scan_privacy=0
	# DONE = SET HERE - Custom config for quick scans
	
	LOG green "Default settings selected..."	
	if [[ "$scan_btclassic" == "true" && "$scan_btle" == "true" ]] ; then
		LOG cyan "Scanning Classic + LE Bluetooth for ${DATA_SCAN_SECONDS}s each"
	else 
		if [[ "$scan_btclassic" == "true" ]] ; then
			LOG cyan "Scanning Classic Bluetooth for ${DATA_SCAN_SECONDS}s"
		fi
		if [[ "$scan_btle" == "true" ]] ; then
			LOG cyan "Scanning LE Bluetooth for ${DATA_SCAN_SECONDS}s"
		fi
	fi
	if [[ "$scan_infrepeat" -eq 1 ]] ; then
		LOG cyan " - Infinite Scan Enabled"
	else
		LOG cyan " - Infinite Scan Disabled"
	fi
	if [ "$scan_mute" = "true" ]; then
		LOG cyan " - Sound Muted"
	else
		LOG cyan " - Sound Enabled"
	fi
	if [[ "$scan_debug" == "true" ]] ; then
		LOG cyan " - DEBUG Mode / extra logging Enabled"
	else
		LOG cyan " - DEBUG Mode / extra logging Disabled"
	fi
	if [[ "$scan_privacy" -eq 1 ]] ; then
		LOG cyan " - Privacy Mode Enabled"
	else
		LOG cyan " - Privacy Mode Disabled"
	fi
	LOG " "
	LOG "Press OK to continue..."
	LOG " "
	WAIT_FOR_BUTTON_PRESS A
else
	LOG magenta "Entering configuration..."
	LOG " "
fi

sleep 0.5

# configuration
if [[ "$scan_default" == "false" ]] ; then
	# ASK HOW MANY SECONDS TO SCAN - $DATA_SCAN_SECONDS
	# Longer times = larger file
	DATA_SCAN_SECONDS=$(NUMBER_PICKER "Scan duration (seconds):" $DATA_SCAN_SECONDS)
	case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) DATA_SCAN_SECONDS=$DATA_SCAN_SECONDS ;; esac
	[ $DATA_SCAN_SECONDS -lt 3 ] && DATA_SCAN_SECONDS=3
	[ $DATA_SCAN_SECONDS -gt 20 ] && DATA_SCAN_SECONDS=20

	sleep 1

	# Confirm Bluetooth Classic
	resp=$(CONFIRMATION_DIALOG "Do you want to include Bluetooth Classic in the scan? ")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_btclassic="true"
	fi

	# Confirm Bluetooth LE
	resp=$(CONFIRMATION_DIALOG "Do you want to include Bluetooth LE in the scan?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_btle="true"
	fi

	# Confirm scans are selected
	if [[ "$scan_btclassic" == "false" ]] && [[ "$scan_btle" == "false" ]] ; then
		LOG red "No scans selected, exiting..."
		LOG " "
		sleep 1
		exit 0
	fi

	# Confirm Infinite
	resp=$(CONFIRMATION_DIALOG "Infinite Scan? No clicking to re-scan?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_infrepeat=1
	fi

	# Confirm Mute
	resp=$(CONFIRMATION_DIALOG "Mute sounds?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_mute="true"
	fi

	# Confirm DEBUG
	resp=$(CONFIRMATION_DIALOG "DEBUG / Save extra logs?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_debug="true"
	fi
	
	# Confirm Privacy
	resp=$(CONFIRMATION_DIALOG "Privacy / Streamer Mode?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_privacy=1
	fi
fi

# Confirm Scan
resp=$(CONFIRMATION_DIALOG "Start scan for Bluetooth?")
if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
	device_hunter
else
	LOG "Skipped Bluetooth Scan."
fi

exit 0
