#!/bin/bash
# Menu Functions for BluePine
# Author: cncartist
# Version: 1.4
# 
# check_dependencies
# check_ringtones
# external_bt_check
# bluetoothd_check
# 
# global_config
# scantime_config
# scantype_config
# infscan_config
# mute_config
# debug_config	
# 
# friendly_config
# privacy_config
# stealth_config
# restore_ableds
# filter_config
# multilocal_config
# randomall_config
# localall_config
# multiall_config
# emptyoui_config
# 
# enter_custom_name
# enter_custom_oui
# 
# main_menu
# sub_menu_detection
# sub_menu_probe
# sub_menu_savedtargoptions
# sub_menu_preferences
# 
# sub_sub_menu_managebt
# sub_sub_menu_extra
# 


# Check for required tools
check_dependencies() {
	if ! command -v hciconfig &> /dev/null; then
		ERROR_DIALOG "hciconfig not installed"
		if [[ "$archCur" == "pager" ]] ; then
			LOG red "Install with: opkg update && opkg install bluez-utils"
		else
			LOG red "Install with: apt update && apt install bluez-utils"
		fi
		exit 1
	fi
	if ! command -v btmon &> /dev/null; then
		ERROR_DIALOG "btmon not installed"
		if [[ "$archCur" == "pager" ]] ; then
			LOG red "Install with: opkg update && opkg install bluez-utils"
		else
			LOG red "Install with: apt update && apt install bluez-utils"
		fi
		exit 1
	fi
	if ! command -v bluetoothctl &> /dev/null; then
		ERROR_DIALOG "bluetoothctl not installed"
		if [[ "$archCur" == "pager" ]] ; then
			LOG red "Install with: opkg update && opkg install bluez-utils"
		else
			LOG red "Install with: apt update && apt install bluez-utils"
		fi
		exit 1
	fi
	
	# ORIGINAL <root> grep -V
	# grep: unrecognized option: V
	# BusyBox v1.36.1 (2025-04-13 16:38:32 UTC) multi-call binary.
	# 
	# NEW <root> grep -V
	# grep (GNU grep) 3.11
	local evtestCheck=0; local grepCheck=0; local jqCheck=0; local ouiCheck=0; local count=0; local limit=3; local substring="BusyBox v"; local substring2='grep (GNU grep)'
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
	if [[ "$archCur" == "pager" ]] ; then
		jqCheck=1
		ouiCheck=1
		# check evtest
		if command -v evtest &> /dev/null; then
			evtestCheck=1
		fi
	else
		evtestCheck=1
		# check jq
		if command -v jq &> /dev/null; then
			jqCheck=1
		fi
		# check oui data
		if [[ -f "/var/lib/ieee-data/oui.txt" ]] ; then
			ouiCheck=1
		fi
	fi
	if [[ "$grepCheck" -eq 0 || "$evtestCheck" -eq 0  || "$jqCheck" -eq 0  || "$ouiCheck" -eq 0 ]]; then
		local dependText=""
		# ask if they want to install now
		# without grep the app will run but, device names will show as "Unknown"
		# without evtest, you cannot stop an infinite scan without losing data from the scan
		if [[ "$grepCheck" -eq 0 ]]; then
			dependText="GNU grep"
		fi
		if [[ "$evtestCheck" -eq 0 ]]; then
			if [[ -n "$dependText" ]]; then
				dependText="${dependText} & evtest"
				# dependText="GNU grep & evtest"
			else
				dependText="evtest"
			fi
		fi
		if [[ "$jqCheck" -eq 0 ]]; then
			if [[ -n "$dependText" ]]; then
				dependText="${dependText} & jq"
			else
				dependText="jq"
			fi
		fi
		if [[ "$ouiCheck" -eq 0 ]]; then
			if [[ -n "$dependText" ]]; then
				dependText="${dependText} & ieee-data"
			else
				dependText="ieee-data"
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
			if [[ "$archCur" == "pager" ]] ; then
				while [[ -f "/var/lock/opkg.lock" ]] && [[ "$count" -lt 3 ]] ; do
					LOG red "Opkg currently locked by a process. Waiting..."
					sleep 5
					count=$((count + 1))
				done
			else
				while [[ "$count" -lt 3 ]] ; do
					if ps aux | grep -i [a]pt > /dev/null; then
						LOG red "Apt currently locked by a process. Waiting..."
						sleep 5
						count=$((count + 1))
					else
						# echo "No update/upgrade running"
						break
					fi
				done
			fi
			# Check Network enabled
			count=1 # Number of packets to send
			timeout=3 # Seconds to wait for a response
			if ping -c $count -w $timeout "8.8.8.8" > /dev/null 2>&1; then
				LOG "Network connection is active..."
				if [[ "$archCur" == "pager" ]] ; then
					LOG "Running 'opkg update'"
				else
					LOG "Running 'apt update'"
				fi
				LOG "Please wait..."
				if [[ "$archCur" == "pager" ]] ; then
					# opkg update && opkg install grep
					if opkg update; then
						LOG green "'opkg update' successful."
						if [[ "$grepCheck" -eq 0 ]]; then
							LOG "Installing GNU grep..."
							LOG "Please wait..."
							opkg install grep
						fi
						if [[ "$evtestCheck" -eq 0 ]]; then
							LOG "Installing evtest..."
							LOG "Please wait..."
							opkg install evtest
						fi
						LOG green "Packages installed!"
					else
						LOG red "'opkg update' failed. Check network..."
					fi
				else
					# apt update && apt install grep
					if apt update; then
						LOG green "'apt update' successful."
						if [[ "$grepCheck" -eq 0 ]]; then
							LOG "Installing GNU grep..."
							LOG "Please wait..."
							apt install grep -y
						fi
						if [[ "$jqCheck" -eq 0 ]]; then
							LOG "Installing jq..."
							LOG "Please wait..."
							apt install jq -y
						fi
						if [[ "$ouiCheck" -eq 0 ]]; then
							LOG "Installing ieee-data..."
							LOG "Please wait..."
							apt install ieee-data -y
							update-ieee-data
						fi
						LOG green "Packages installed!"
					else
						LOG red "'apt update' failed. Check network..."
					fi
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
			if [[ "$archCur" == "pager" ]] ; then
				LOG "opkg update"
				LOG "opkg install grep"
				LOG "opkg install evtest"
			else
				LOG "apt update"
				LOG "apt install grep jq ieee-data"
				LOG "update-ieee-data"
			fi
			LOG blue  "================================================="
			LOG cyan "== Or all in one command ->"
			if [[ "$archCur" == "pager" ]] ; then
				LOG "opkg update && opkg install grep && opkg install evtest"
			else
				LOG "apt update && apt install grep jq ieee-data -y && update-ieee-data"
			fi
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
	local FILES=("Achievement.rtttl" "flutter.rtttl" "glitchHack.rtttl" "ScaleTrill.rtttl" "sideBeam.rtttl" "warning.rtttl")
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
					elif [[ "$FILE_NAME" == "flutter.rtttl" ]]; then
						ringtone_file="Flutter:d=4,o=5,b=565:8d5,8e5,8f5,8g5,8f5,8e5,8d5"
					elif [[ "$FILE_NAME" == "glitchHack.rtttl" ]]; then
						ringtone_file="GlitchHack:d=16,o=5,b=285:c,g,c6,p,b,p,a,p,g,p,4c"
					elif [[ "$FILE_NAME" == "ScaleTrill.rtttl" ]]; then
						ringtone_file="ScaleTrill:o=5,d=32,b=160,b=160:c,d,e,f,g,a,b,c6,b,a,g,f,e,d,c"
					elif [[ "$FILE_NAME" == "sideBeam.rtttl" ]]; then
						ringtone_file="SideBeam:d=16,o=5,b=565:b,f6,f6,b,f6,f6,b,f6,f6"
					elif [[ "$FILE_NAME" == "warning.rtttl" ]]; then
						ringtone_file="Warning:d=4,o=5,b=180:a,8p,a,8p,a,8p,a"
					fi					
					LOG "Copying ${FILE_NAME}..."
					printf "%s\n" "$ringtone_file" > "$DEST_PATH"
					# cp "$SOURCE_PATH" "$DEST_PATH" 2>/dev/null
				fi
			done
			LOG green "Sound Effects / Ringtones Copied!"
		else
			LOG magenta "Skipped Copying Sound Effects / Ringtones..."
			resp=$(CONFIRMATION_DIALOG "Do you want to skip this Ringtone Check from now on?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				LOG "Skipping Ringtone Check from now on..."
				skip_ask_ringtones=1
				PAYLOAD_SET_CONFIG bluepinesuite skip_ask_ringtones "$skip_ask_ringtones"
			fi
		fi
	fi
}

# External Bluetooth Adapter?
external_bt_check() {
	# Bluetooth: Can't init device hci1: Operation not possible due to RF-kill (132)
	# possible to need to turn off bluetooth and back on to allow adapter to be enabled
	if hciconfig | grep -q hci1; then
		resp=$(CONFIRMATION_DIALOG "Do you have USB/External Bluetooth enabled & plugged in?")
	else
		resp='n'
	fi
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		if hciconfig | grep -q hci1; then
			BLE_IFACE="hci1"
			CSR_CHECK=$(hciconfig -a $BLE_IFACE | grep 'Manufacturer: Cambridge Silicon Radio' | awk '{print $1}')
			# LOG red "CSR_CHECK: $CSR_CHECK"
			if [[ -z "$CSR_CHECK" ]]; then
				# try to bring up adapter if possibly down, MFR doesnt show when down
				# LOG red "RUNNING SECONDARY CHECK"
				loop=0
				while true; do
					# LOG red "in loop"
					# hciconfig "$BLE_IFACE" up
					loop=$((loop + 1))
					if ! hciconfig "$BLE_IFACE" up 2>/dev/null; then
						sleep 0.5
						# LOG red "Interface DOWN!: $BLE_IFACE"
						# LOG red "Resetting"
						hciconfig "$BLE_IFACE" reset 2>/dev/null
						sleep 1.5
						# LOG red "Trying to bring back up..."
						hciconfig "$BLE_IFACE" up 2>/dev/null
						sleep 0.5
						if [[ "$loop" -eq 5 ]] ; then
							LOG red   "== ERROR: Interface DOWN after $loop tries!: $BLE_IFACE ==="
							BLE_IFACE="hci0"
							break
						fi
					else
						# LOG green "Interface UP!: $BLE_IFACE"
						break
					fi
				done
				
				CSR_CHECK=$(hciconfig -a $BLE_IFACE | grep 'Manufacturer: Cambridge Silicon Radio' | awk '{print $1}')
				# LOG red "CSR_CHECK: $CSR_CHECK"
			fi
			if [[ -n "$CSR_CHECK" ]]; then
				LOG blue  "================================================="
				LOG green "========== USB Bluetooth (CSR) Found! ==========="
				LOG cyan  "========== Full Functionality Enabled ==========="
				LOG blue  "================================================="
				enable_CSR_func=1
			else
				LOG blue  "================================================="
				LOG red   "======== ERROR! $BLE_IFACE Found, but not CSR! ========"
				LOG red   "========= Functionality may be limited! ========="
				LOG blue  "================================================="
				LOG " "
				if [[ "$archCur" == "pager" ]] ; then
					LOG magenta "Have CSR BT but booted Pager with USB plugged in?"
					LOG cyan "If so, please reboot the Pager without USB BT."
					LOG cyan "Then Plugin USB BT after boot..."
				else
					LOG magenta "Have External Bluetooth but Adapter Down from 'rfkill'?"
					LOG cyan "Check with: 'sudo hciconfig hci1 up'"
					LOG cyan "If so, turn off Bluetooth and back on via desktop taskbar and 'Retest CSR'."
				fi
				LOG " "
				LOG magenta  "Also try unplugging and replugging USB BT, then"
				LOG magenta  "Re-check at Preferences > Bluetooth > Retest CSR"
				LOG blue  "================================================="
				LOG "Press OK to continue..."
				LOG " "
				WAIT_FOR_BUTTON_PRESS A
			fi
		else
			BLE_IFACE="hci0"
			LOG blue "================================================="
			LOG red  "========= ERROR! Device hci1 Not found! ========="
			LOG red  "========== Using $BLE_IFACE / Default Device =========="
			LOG red  "========= Functionality may be limited! ========="
			LOG red  "Try unplugging and replugging USB BT, then"
			LOG red  "Re-check at Preferences > Bluetooth > Retest CSR"
			LOG blue "================================================="
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
		fi
	else
		BLE_IFACE="hci0"
		LOG blue  "========== Using $BLE_IFACE / Default Device =========="
	fi
	if [[ "$BLE_IFACE" == "hci0" ]]; then
		rssitxt_switch="rssitxtsw_hci0"
	else
		rssitxt_switch="rssitxtsw_hci1"
	fi
}

# restart bluetoothd if not running
bluetoothd_check() {
	# service bluetoothd restart
	# service bluetoothd status
	# not running
	# /etc/bluetooth/keys/
	# name coming from lsusb when bluetoothd not running
	local loop=0
	while true; do
		# LOG red "in loop"
		loop=$((loop + 1))
		if service $servicebt_cur status | grep -q "not"; then
			# echo "NOT RUNNING"
			# echo "trying restart..."
			service $servicebt_cur restart
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


global_config() {
	# Confirm Default Settings
	resp=$(CONFIRMATION_DIALOG "Use Default Settings?  If not, the next questions will allow full customization.")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_default="true"
		
		# START = SET HERE - Custom config for quick scans
		DATA_SCAN_SECONDS=7
		scan_btle="true"
		scan_btclassic="true"
		scan_infrepeat=1
		scan_mute="false"
		scan_debug="false"
		skip_ask_1st_scan=0
		filter_multilocal=0
		filter_randomall=0
		filter_localall=0
		filter_multiall=0
		filter_emptyoui=0
		# DONE = SET HERE - Custom config for quick scans
		
		LOG green "Default settings selected..."	
		if [[ "$scan_btclassic" == "true" ]] && [[ "$scan_btle" == "true" ]] ; then
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
		if [[ "$scan_mute" == "true" ]] ; then
			LOG cyan " - Sound Muted"
		else
			LOG cyan " - Sound Enabled"
		fi
		if [[ "$scan_debug" == "true" ]] ; then
			LOG cyan " - DEBUG Mode / extra logging Enabled"
		else
			LOG cyan " - DEBUG Mode / extra logging Disabled"
		fi
		if [[ "$skip_ask_1st_scan" -eq 0 ]] ; then
			LOG cyan " - Ask to Save Results after 1st Scan Enabled"
		else
			LOG cyan " - Ask to Save Results after 1st Scan Disabled"
		fi
		if [[ "$filter_multilocal" -eq 1 || "$filter_randomall" -eq 1 || "$filter_localall" -eq 1 || "$filter_multiall" -eq 1 || "$filter_emptyoui" -eq 1 ]] ; then
			LOG cyan " - Filter(s) Enabled"
		else
			LOG cyan " - Filter(s) Disabled"
		fi
		
		# save config
		PAYLOAD_SET_CONFIG bluepinesuite DATA_SCAN_SECONDS "$DATA_SCAN_SECONDS"
		PAYLOAD_SET_CONFIG bluepinesuite scan_btle "$scan_btle"
		PAYLOAD_SET_CONFIG bluepinesuite scan_btclassic "$scan_btclassic"
		PAYLOAD_SET_CONFIG bluepinesuite scan_infrepeat "$scan_infrepeat"
		PAYLOAD_SET_CONFIG bluepinesuite scan_mute "$scan_mute"
		PAYLOAD_SET_CONFIG bluepinesuite scan_debug "$scan_debug"
		PAYLOAD_SET_CONFIG bluepinesuite skip_ask_1st_scan "$skip_ask_1st_scan"
		PAYLOAD_SET_CONFIG bluepinesuite filter_multilocal "$filter_multilocal"
		PAYLOAD_SET_CONFIG bluepinesuite filter_randomall "$filter_randomall"
		PAYLOAD_SET_CONFIG bluepinesuite filter_localall "$filter_localall"
		PAYLOAD_SET_CONFIG bluepinesuite filter_multiall "$filter_multiall"
		PAYLOAD_SET_CONFIG bluepinesuite filter_emptyoui "$filter_emptyoui"
		
		LOG "Settings saved..."
		LOG green "Configuration complete!"
	else
		LOG magenta "Entering configuration..."
	fi

	sleep 0.5

	# configuration
	if [[ "$scan_default" == "false" ]] ; then
		scantime_config
		sleep 1
		scantype_config
		infscan_config
		LOG " "
		mute_config
		debug_config
		skip_ask_config
		filter_config
		LOG " "
		LOG "Settings saved..."
		LOG green "Configuration complete!"
	fi
	LOG " "
}

scantype_config() {
	# Confirm Bluetooth Classic
	resp=$(CONFIRMATION_DIALOG "Do you want to include Bluetooth Classic in the scan(s)? ")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_btclassic="true"
	else
		scan_btclassic="false"
	fi

	# Confirm Bluetooth LE
	resp=$(CONFIRMATION_DIALOG "Do you want to include Bluetooth LE in the scan(s)?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_btle="true"
	else
		scan_btle="false"
	fi

	# Confirm scans are selected
	if [[ "$scan_btclassic" == "false" ]] && [[ "$scan_btle" == "false" ]] ; then
		LOG red "No scans selected, going with BLE..."
		scan_btle="true"
	fi
	PAYLOAD_SET_CONFIG bluepinesuite scan_btle "$scan_btle"
	PAYLOAD_SET_CONFIG bluepinesuite scan_btclassic "$scan_btclassic"
}
scantime_config() {
	# ASK HOW MANY SECONDS TO SCAN - $DATA_SCAN_SECONDS
	# Longer times = larger file
	DATA_SCAN_SECONDS=$(NUMBER_PICKER "Scan duration (seconds)" $DATA_SCAN_SECONDS)
	case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) DATA_SCAN_SECONDS=$DATA_SCAN_SECONDS ;; esac
	[ $DATA_SCAN_SECONDS -lt 3 ] && DATA_SCAN_SECONDS=3
	[ $DATA_SCAN_SECONDS -gt 20 ] && DATA_SCAN_SECONDS=20
	PAYLOAD_SET_CONFIG bluepinesuite DATA_SCAN_SECONDS "$DATA_SCAN_SECONDS"
}
infscan_config() {
	# Confirm Infinite
	resp=$(CONFIRMATION_DIALOG "Infinite Scan? No clicking to re-scan?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_infrepeat=1
		LOG "Infinite Scan Enabled..."
	else
		scan_infrepeat=0
		LOG "Infinite Scan Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite scan_infrepeat "$scan_infrepeat"
}
mute_config() {
	# Confirm Mute
	resp=$(CONFIRMATION_DIALOG "Mute sounds?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_mute="true"
		LOG "Mute Enabled..."
	else
		scan_mute="false"
		LOG "Mute Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite scan_mute "$scan_mute"
	LOG " "
}
debug_config() {
	resp=$(CONFIRMATION_DIALOG "DEBUG / Save extra logs?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_debug="true"
		LOG "DEBUG Mode Enabled..."
	else
		scan_debug="false"
		LOG "DEBUG Mode Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite scan_debug "$scan_debug"
	LOG " "
}
skip_ask_config() {
	resp=$(CONFIRMATION_DIALOG "Skip Asking to Save Results after 1st Scan?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		skip_ask_1st_scan=1
		LOG "Skip Ask to Save Results after 1st Scan..."
	else
		skip_ask_1st_scan=0
		LOG "Continue Ask to Save Results after 1st Scan..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite skip_ask_1st_scan "$skip_ask_1st_scan"
	LOG " "
}
privacy_config() {
	resp=$(CONFIRMATION_DIALOG "Privacy / Streamer Mode?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_privacy=1
		LOG "Privacy / Streamer Mode Enabled..."
	else
		scan_privacy=0
		LOG "Privacy / Streamer Mode Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite scan_privacy "$scan_privacy"
	LOG " "
}
friendly_config() {
	resp=$(CONFIRMATION_DIALOG "Friendly Mode?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_friendly=1
		LOG "Friendly Mode Enabled..."
	else
		scan_friendly=0
		LOG "Friendly Mode Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite scan_friendly "$scan_friendly"
	settings_check
	LOG " "
}
stealth_config() {
	resp=$(CONFIRMATION_DIALOG "Stealth Mode?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		scan_mute="true"
		scan_stealth=1
		settings_check
		LOG "Stealth Mode Enabled..."
		LOG "Sound Effects Off..."
		if [[ "$archCur" == "pager" ]] ; then
			LOG "LEDS Turned Off..."
			LOG "A + B Button LEDS Turned Off..."
			LOG "Payload LED Actions Disabled..."
		fi
	else
		scan_mute="false"
		scan_stealth=0
		LED MAGENTA
		LOG "Stealth Mode Disabled..."
		LOG "Sound Effects On..."
		if [[ "$archCur" == "pager" ]] ; then
			LOG "LEDS Turned On..."
			btn_a_path="/sys/devices/platform/leds/leds/a-button-led/brightness"
			btn_b_path="/sys/devices/platform/leds/leds/b-button-led/brightness"
			btn_a_state=$(cat "$btn_a_path")
			btn_b_state=$(cat "$btn_b_path")
			if [[ "$btn_a_state" -eq 0 || "$btn_b_state" -eq 0 ]] ; then
				# LOG "Restoring A + B Button LEDS..."
				echo 1 > "$btn_a_path"
				echo 1 > "$btn_b_path"
				LOG "A + B Button LEDS restored..."
			fi
			LOG "Payload LED Actions Enabled..."
		fi
	fi
	PAYLOAD_SET_CONFIG bluepinesuite scan_stealth "$scan_stealth"
	PAYLOAD_SET_CONFIG bluepinesuite scan_mute "$scan_mute"
	LOG " "
}
restore_ableds() {
	if [[ "$archCur" == "pager" ]] ; then
		resp=$(CONFIRMATION_DIALOG "Restore A + B Button LEDS?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			# LOG "Restoring A + B Button LEDS..."
			btn_a_path="/sys/devices/platform/leds/leds/a-button-led/brightness"
			btn_b_path="/sys/devices/platform/leds/leds/b-button-led/brightness"
			btn_a_state=$(cat "$btn_a_path")
			btn_b_state=$(cat "$btn_b_path")
			if [[ "$btn_a_state" -eq 0 || "$btn_b_state" -eq 0 ]] ; then
				# LOG "Restoring A + B Button LEDS..."
				echo 1 > "$btn_a_path"
				echo 1 > "$btn_b_path"
				LOG "A + B Button LEDS restored..."
			else
				LOG "A + B Button LEDS already on..."
			fi
			LOG " "
		fi
	else
		LOG red "Setting only available on Pager currently..."
		LOG " "
	fi
}

# configure filters
filter_config() {
	local filters_disabled=0
	local filterText=""
	
	if [[ "$filter_multilocal" -eq 1 || "$filter_randomall" -eq 1 || "$filter_localall" -eq 1 || "$filter_multiall" -eq 1 || "$filter_emptyoui" -eq 1 ]] ; then
		if [[ "$filter_multilocal" -eq 1 && "$filter_randomall" -eq 1 && "$filter_localall" -eq 1 && "$filter_multiall" -eq 1 && "$filter_emptyoui" -eq 1 ]] ; then
			LOG blue "================================================="
			LOG cyan "Filters Currently Removing MACs with:"
			LOG blue "================================================="
			LOG "First Octet Matching: 01, 02, 03, 05, 07, 09, 0B, 0D, 0F, 11-99 (odd), FF"
			LOG blue "================================================="
			LOG "First Octet Matching (x = Wildcard): x2, x3, x6, x7, xA, xB, xE, xF"
			LOG blue "================================================="
			LOG "OUI Matching: '00:00:00'"
			LOG blue "================================================="
			
			PROMPT "Filters Currently Removing MACs with:
			
			
First Octet Matching: 01, 02, 03, 05, 07, 09, 0B, 0D, 0F, 11-99 (odd), FF
			
First Octet Matching (x = Wildcard):
x2, x3, x6, x7, xA, xB, xE, xF
			
OUI Matching: '00:00:00'"
		else
			LOG blue "================================================="
			LOG cyan "Filters Currently Removing MACs with:"
			LOG blue "================================================="
			filterText="Filters Currently Removing MACs with:
"
			if [[ "$filter_multilocal" -eq 1 && "$filter_multiall" -eq 1 ]] ; then
				LOG "First Octet Matching: 01, 02, 03, 05, 07, 09, 0B, 0D, 0F, 11-99 (odd), FF"
				LOG blue "================================================="
				filterText="${filterText}
				
First Octet Matching: 01, 02, 03, 05, 07, 09, 0B, 0D, 0F, 11-99 (odd), FF"
			else
				if [[ "$filter_multilocal" -eq 1 ]] ; then
					LOG "First Octet Matching: 01, 02"
					LOG blue "================================================="
					filterText="${filterText}
					
First Octet Matching: 01, 02"
				fi
				if [[ "$filter_multiall" -eq 1 ]] ; then
					LOG "First Octet Matching: 01, 03, 05, 07, 09, 0B, 0D, 0F, 11-99 (odd), FF"
					LOG blue "================================================="
					filterText="${filterText}
					
First Octet Matching: 01, 03, 05, 07, 09, 0B, 0D, 0F, 11-99 (odd), FF"
				fi
			fi
			if [[ "$filter_localall" -eq 1 && "$filter_randomall" -eq 1 ]] ; then
				LOG "First Octet Matching (x = Wildcard): x2, x3, x6, x7, xA, xB, xE, xF"
				LOG blue "================================================="
				filterText="${filterText}
				
First Octet Matching (x = Wildcard):
x2, x3, x6, x7, xA, xB, xE, xF"
			else
				if [[ "$filter_localall" -eq 1 ]] ; then
					LOG "First Octet Matching (x = Wildcard): x2, x6, xA, xE"
					LOG blue "================================================="
					filterText="${filterText}
					
First Octet Matching (x = Wildcard):
x2, x6, xA, xE"
				fi
				if [[ "$filter_randomall" -eq 1 ]] ; then
					LOG "First Octet Matching (x = Wildcard): x3, x7, xB, xF"
					LOG blue "================================================="
					filterText="${filterText}
					
First Octet Matching (x = Wildcard):
x3, x7, xB, xF"
				fi
			fi
			if [[ "$filter_emptyoui" -eq 1 ]] ; then
				LOG "OUI Matching: '00:00:00'"
				LOG blue "================================================="
				filterText="${filterText}
				
OUI Matching: '00:00:00'"
			fi
			PROMPT "$filterText"
		fi
		
		resp=$(CONFIRMATION_DIALOG "Filter(s) currently Enabled!
		
Disable All Filters for Device ${text_hunt_UC}er Scan, allowing all ${text_target_UC}s/MACs to be visible again?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			filters_disabled=1
			LOG "Disabling All Filters..."
			filter_multilocal=0
			filter_randomall=0
			filter_localall=0
			filter_multiall=0
			filter_emptyoui=0
			PAYLOAD_SET_CONFIG bluepinesuite filter_multilocal "$filter_multilocal"
			PAYLOAD_SET_CONFIG bluepinesuite filter_randomall "$filter_randomall"
			PAYLOAD_SET_CONFIG bluepinesuite filter_localall "$filter_localall"
			PAYLOAD_SET_CONFIG bluepinesuite filter_multiall "$filter_multiall"
			PAYLOAD_SET_CONFIG bluepinesuite filter_emptyoui "$filter_emptyoui"
		else
			LOG "Skipped Disabling Filters..."
		fi
	fi
	if [[ "$filters_disabled" -eq 0 ]] ; then
		resp=$(CONFIRMATION_DIALOG "Modify Filters for Device ${text_hunt_UC}er Scan?
		
Adding Filters allows faster processing, removes ${text_target_LC}s from results, and helps if you know which MACs you are searching for.
		
WARNING: Filters REMOVE real ${text_target_LC}s from report/display and only applies to non-targeted scans!")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LOG "Modifying Filters..."
			emptyoui_config
			multilocal_config
			multiall_config
			localall_config
			randomall_config
		else
			LOG "Skipped Modifying Filters..."
		fi
	fi
	settings_check
}
multilocal_config() {
	resp=$(CONFIRMATION_DIALOG "Basic Filter:
	
Remove Multicast (01) & Locally Administered (02) MACs?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		filter_multilocal=1
		LOG "Filter Multicast/Locally Admin. Enabled..."
	else
		filter_multilocal=0
		LOG "Filter Multicast/Locally Admin. Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite filter_multilocal "$filter_multilocal"
}
emptyoui_config() {
	resp=$(CONFIRMATION_DIALOG "OUI Filter:
	
Remove Empty OUI (00:00:00) MACs?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		filter_emptyoui=1
		LOG "Filter Empty OUI (00:00:00) Enabled..."
	else
		filter_emptyoui=0
		LOG "Filter Empty OUI (00:00:00) Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite filter_emptyoui "$filter_emptyoui"
}
randomall_config() {
	resp=$(CONFIRMATION_DIALOG "Multi Filter:
	
Remove ALL Random (x3, x7, xB, xF) MACs?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		filter_randomall=1
		LOG "Filter ALL Random Enabled..."
	else
		filter_randomall=0
		LOG "Filter ALL Random Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite filter_randomall "$filter_randomall"
}
localall_config() {
	resp=$(CONFIRMATION_DIALOG "Multi Filter:
	
Remove ALL Locally Administered (x2, x6, xA, xE) MACs?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		filter_localall=1
		LOG "Filter ALL Locally Admin. Enabled..."
	else
		filter_localall=0
		LOG "Filter ALL Locally Admin. Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite filter_localall "$filter_localall"
}
multiall_config() {
	resp=$(CONFIRMATION_DIALOG "Multi Filter:
	
Remove ALL Multicast (01, 03, 05, 07, 09, 0B, 0D, 0F, 11-99 (odd), FF) MACs?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		filter_multiall=1
		LOG "Filter ALL Multicast Enabled..."
	else
		filter_multiall=0
		LOG "Filter ALL Multicast Disabled..."
	fi
	PAYLOAD_SET_CONFIG bluepinesuite filter_multiall "$filter_multiall"
}

enter_custom_oui() {
	# LOG "enter_custom_oui"
	if [[ -n "$custom_oui" ]] ; then
		if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$custom_oui"; custom_oui="HI:DD:EN"; fi
		resp=$(CONFIRMATION_DIALOG "Clear Current Custom OUI - ${custom_oui}?")
		if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; fi
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			custom_oui=""
			PAYLOAD_SET_CONFIG bluepinesuite custom_oui "$custom_oui"
			LOG green "Current Custom OUI Cleared!"
			LOG "Press OK to confirm..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
		fi
		sleep 1
	fi
	resp=$(CONFIRMATION_DIALOG "Enter/Edit Custom OUI?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		if [[ -n "$custom_oui" ]] ; then
			if [[ "$archCur" == "pager" ]] ; then
				custom_oui="${custom_oui}:00:00:00"
			fi
		fi
		NEW_MAC="$custom_oui"
		if [[ -n "$custom_oui" ]] && [[ "$scan_privacy" -eq 1 ]] ; then
			NEW_MAC="$priv_mac_num"
		fi
		if [[ "$archCur" == "pager" ]] ; then
			LOG magenta "Please enter 00:00:00 for end of OUI..."
		fi
		LOG "Press OK to confirm..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		
		while true; do
			# run input
			if [[ "$archCur" != "pager" ]] ; then
				NEW_MAC="${NEW_MAC:0:8}"
			fi
			NEW_MAC=$(MAC_PICKER "Custom OUI" "$NEW_MAC")
			if [[ "$archCur" == "pager" ]] ; then
				NEW_OUI="${NEW_MAC:0:8}"
			else
				NEW_OUI="${NEW_MAC}"
				NEW_MAC="${NEW_MAC}:00:00:00"
			fi
			# Confirm Custom OUI sufficient
			if [[ "$NEW_MAC" =~ $VALID_MAC ]]; then
				resp=$(CONFIRMATION_DIALOG "This Custom OUI OK? ${NEW_OUI}")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					custom_oui="${NEW_OUI}"
					break
				fi
				LOG red "Skip OUI: ${NEW_OUI}, input new..."
			else 
				LOG red "Invalid OUI: ${NEW_OUI}, input new..."
			fi
			sleep 0.5
		done
		PAYLOAD_SET_CONFIG bluepinesuite custom_oui "$custom_oui"
		LOG blue "================================================="
		LOG cyan "Custom OUI chosen: ${custom_oui}"
		LOG blue "================================================="
		LOG green "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
	else 
		LOG "Skip Enter/Edit Custom OUI..."
		LOG " "
	fi
}

enter_custom_name() {
	# LOG "enter_custom_name"
	resp=$(CONFIRMATION_DIALOG "Enter/Edit Custom Name?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		NEW_NAME="$custom_name"
		if [[ -n "$custom_name" ]] && [[ "$scan_privacy" -eq 1 ]] ; then
			NEW_NAME="$priv_name_txt"
		fi
		while true; do
			# run input
			# escape name for single quotes (removes some input if single quotes present)
			NEW_NAME="${NEW_NAME//\'/\'}"
			#NEW_NAME="${variable//pattern/replacement}"
			NEW_NAME=$(TEXT_PICKER "${text_target_UC} name" "$NEW_NAME")
			# LOG cyan "New Name: ${NEW_NAME}"
			resp=$(CONFIRMATION_DIALOG "This Custom Name OK? ${NEW_NAME}")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				custom_name="${NEW_NAME}"
				break
			else
				LOG red "Skip Name: ${NEW_NAME}, input new..."
			fi
			sleep 0.5
		done
		PAYLOAD_SET_CONFIG bluepinesuite custom_name "$custom_name"
		LOG blue "================================================="
		if [[ -n "$custom_name" ]] ; then
			LOG cyan "Custom Name chosen: ${custom_name}"
		else
			LOG cyan "Custom Name was set to blank..."
			LOG cyan "OUI Search only if set..."
		fi
		LOG blue "================================================="
		LOG green "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
	else 
		LOG "Skip Enter/Edit Custom Name..."
		LOG " "
	fi
}




# main menu
main_menu() {
	if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
	declare -A MENU_ITEMS
	MENU_ITEMS[0]="Exit"
	MENU_ITEMS[1]="Scan"
	MENU_ITEMS[2]="Detection"
	MENU_ITEMS[3]="Jammer Detector"
	MENU_ITEMS[4]="View ${text_target_UC}s / Select ${text_target_UC}"
	MENU_ITEMS[5]="Probe ${text_target_UC}"
	MENU_ITEMS[6]="${text_hunt_UC} Custom OUI/Name"
	MENU_ITEMS[7]="Manage Saved ${text_target_UC}s"
	MENU_ITEMS[8]="Preferences"
	MENU_ITEMS[9]="Info"
	local maxarritems=$(( ${#MENU_ITEMS[@]} - 1 ))
	local defaultselnum="$selnum_main"
	local text_pick_str="\"Main Menu\""
	
	if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
	sorted_MENU_ITEMS=( $(for key in "${!MENU_ITEMS[@]}"; do echo "$key"; done | sort) )
	# Record each
	for num in "${!sorted_MENU_ITEMS[@]}"; do
		if [[ "$num" -eq 0 ]]; then
			if [[ -n "$target_mac" ]]; then
			  LOG green "========= Selected ${text_target_UC}: $target_mac ===="
			else
				LOG red "========================= No ${text_target_UC} Selected ===="
			fi
			LOG magenta "================================== Main Menu ===="
		else
			item_txt="${MENU_ITEMS[$num]}"
			LOG "${num}: $item_txt"
			# dynamic list picker creation
			text_pick_str="${text_pick_str} \"${item_txt}\""
		fi
	done
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[0]}\"" # add exit to end slot
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[$defaultselnum]}\"" # add selected to final picker slot
	
	if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
	LOG magenta "================================== Main Menu ===="
	if [[ "$archCur" == "pager" ]] ; then
		LOG "0: Exit BluePine"
		LOG green "Press OK..."
		# LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		# can anyone recommend a better way to do this?
		resp=$(eval "LIST_PICKER $text_pick_str")
	else
		LOG "${#MENU_ITEMS[@]}: Exit BluePine"
		while true; do
			read -e -p "Select an option [1-${#MENU_ITEMS[@]}]: " output
			if [[ "$output" == "${#MENU_ITEMS[@]}" ]] ; then output=0; fi 
			# echo "opt: ${MENU_ITEMS[$output]}"
			case "$output" in
				[1-9]) resp="${MENU_ITEMS[$output]}"; break ;;
				0|10) resp="${MENU_ITEMS[$output]}"; break ;;
				*) echo "Invalid option. Please try again." ;;
			esac
		done
	fi
	case "$resp" in
		"${MENU_ITEMS[1]}") selnum=1 ;;
		"${MENU_ITEMS[2]}") selnum=2 ;;
		"${MENU_ITEMS[3]}") selnum=3 ;;
		"${MENU_ITEMS[4]}") selnum=4 ;;
		"${MENU_ITEMS[5]}") selnum=5 ;;
		"${MENU_ITEMS[6]}") selnum=6 ;;
		"${MENU_ITEMS[7]}") selnum=7 ;;
		"${MENU_ITEMS[8]}") selnum=8 ;;
		"${MENU_ITEMS[9]}") selnum=9 ;;
		"${MENU_ITEMS[0]}") selnum=0 ;;
		*)
		selnum=0 # LOG "Cancel pressed or unknown"
		;;
	esac
	
	if [[ "$selnum" -eq 0 ]]; then
		resp=$(CONFIRMATION_DIALOG "Are you sure you want to quit?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LOG " "
			LOG blue   "░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"
			LOG cyan   "░░░░░░░░░░░░ Thank you for playing! ░░░░░░░░░░░░░░"
			LOG blue   "░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"
			# cleanup
			LOG "Exiting..."
			exit 0
		fi
	else
		# save config
		selnum_main="$selnum"
		PAYLOAD_SET_CONFIG bluepinesuite selnum_main "$selnum_main"
		LOG " "
	fi
	# LOG green "Press OK to continue..."; LOG " "; WAIT_FOR_BUTTON_PRESS A
}


# sub menu detection
sub_menu_detection() {
	if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
	declare -A MENU_ITEMS
	MENU_ITEMS[0]="Return to Main Menu"
	MENU_ITEMS[1]="Detect ALL"
	MENU_ITEMS[2]="Detect ALL - Scanned/Saved ${text_target_UC}s"
	MENU_ITEMS[3]="Detect Custom OUI/Name - Scanned/Saved ${text_target_UC}s"
	MENU_ITEMS[4]="Axon"
	MENU_ITEMS[5]="CC Skimmer"
	MENU_ITEMS[6]="Flipper"
	MENU_ITEMS[7]="Flock Devices"
	MENU_ITEMS[8]="Meshtastic"
	MENU_ITEMS[9]="USB Kill"
	MENU_ITEMS[10]="WiFi Pineapple"
	local maxarritems=$(( ${#MENU_ITEMS[@]} - 1 ))
	local defaultselnum=1
	local text_pick_str="\"Detection\""
	
	sorted_MENU_ITEMS=( $(for key in "${!MENU_ITEMS[@]}"; do echo "$key"; done | sort) )
	# Record each
	for num in "${!sorted_MENU_ITEMS[@]}"; do
		if [[ "$num" -eq 0 ]]; then
			LOG magenta "================================== Detection ===="
		else
			item_txt="${MENU_ITEMS[$num]}"
			LOG "${num}: $item_txt"
			# dynamic list picker creation
			text_pick_str="${text_pick_str} \"${item_txt}\""
		fi
	done
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[0]}\"" # add exit to end slot
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[$defaultselnum]}\"" # add selected to final picker slot
	
	LOG magenta "================================== Detection ===="
	if [[ "$archCur" == "pager" ]] ; then
		LOG "0: Return to Main Menu"
		LOG green "Press OK..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		# can anyone recommend a better way to do this?
		resp=$(eval "LIST_PICKER $text_pick_str")
	else
		LOG "${#MENU_ITEMS[@]}: Return to Main Menu"
		while true; do
			read -e -p "Select an option [1-${#MENU_ITEMS[@]}]: " output
			if [[ "$output" == "${#MENU_ITEMS[@]}" ]] ; then output=0; fi 
			# echo "opt: ${MENU_ITEMS[$output]}"
			case "$output" in
				[1-9]) resp="${MENU_ITEMS[$output]}"; break ;;
				0|10|11) resp="${MENU_ITEMS[$output]}"; break ;;
				*) echo "Invalid option. Please try again." ;;
			esac
		done
	fi
	case "$resp" in
		"${MENU_ITEMS[1]}") selnum=1 ;;
		"${MENU_ITEMS[2]}") selnum=2 ;;
		"${MENU_ITEMS[3]}") selnum=3 ;;
		"${MENU_ITEMS[4]}") selnum=4 ;;
		"${MENU_ITEMS[5]}") selnum=5 ;;
		"${MENU_ITEMS[6]}") selnum=6 ;;
		"${MENU_ITEMS[7]}") selnum=7 ;;
		"${MENU_ITEMS[8]}") selnum=8 ;;
		"${MENU_ITEMS[9]}") selnum=9 ;;
		"${MENU_ITEMS[10]}") selnum=10 ;;
		"${MENU_ITEMS[0]}") selnum=0 ;;
		*)
		selnum=0 # LOG "Cancel pressed or unknown"
		;;
	esac
	# LOG "Option $selnum selected..."
	# LOG green "Press OK to continue..."; LOG " "; WAIT_FOR_BUTTON_PRESS A
}

# sub menu probe
sub_menu_probe() {
	if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
	declare -A MENU_ITEMS
	MENU_ITEMS[0]="Return to Main Menu"
	MENU_ITEMS[1]="${text_hunt_UC} ${text_target_UC}"
	MENU_ITEMS[2]="Browse Services"
	MENU_ITEMS[3]="Get ${text_target_UC} Info"
	MENU_ITEMS[4]="Get ${text_target_UC} Vendor"
	MENU_ITEMS[5]="Verify ${text_target_UC} Connection"
	if [[ "$view_extl" -eq 1 ]] ; then MENU_ITEMS[6]="External"; fi
	
	local maxarritems=$(( ${#MENU_ITEMS[@]} - 1 ))
	local defaultselnum=1
	local text_pick_str="\"Probe\""
	
	if [[ -n "$target_mac" ]]; then
		if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
		sorted_MENU_ITEMS=( $(for key in "${!MENU_ITEMS[@]}"; do echo "$key"; done | sort) )
		# Record each
	  LOG green "========= Selected ${text_target_UC}: $target_mac ===="
		for num in "${!sorted_MENU_ITEMS[@]}"; do
			if [[ "$num" -eq 0 ]]; then
				LOG magenta "====================================== Probe ===="
			else
				item_txt="${MENU_ITEMS[$num]}"
				LOG "${num}: $item_txt"
				# dynamic list picker creation
				text_pick_str="${text_pick_str} \"${item_txt}\""
			fi
		done
		text_pick_str="${text_pick_str} \"${MENU_ITEMS[0]}\"" # add exit to end slot
		text_pick_str="${text_pick_str} \"${MENU_ITEMS[$defaultselnum]}\"" # add selected to final picker slot
		
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
		LOG magenta "====================================== Probe ===="
		if [[ "$archCur" == "pager" ]] ; then
			LOG "0: Return to Main Menu"
			LOG green "Press OK..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.5
			# can anyone recommend a better way to do this?
			resp=$(eval "LIST_PICKER $text_pick_str")
		else
			LOG "${#MENU_ITEMS[@]}: Return to Main Menu"
			while true; do
				read -e -p "Select an option [1-${#MENU_ITEMS[@]}]: " output
				if [[ "$output" == "${#MENU_ITEMS[@]}" ]] ; then output=0; fi 
				# echo "opt: ${MENU_ITEMS[$output]}"
				case "$output" in
					[1-${#MENU_ITEMS[@]}]) resp="${MENU_ITEMS[$output]}"; break ;;
					0) resp="${MENU_ITEMS[$output]}"; break ;;
					*) echo "Invalid option. Please try again." ;;
				esac
			done
		fi
		case "$resp" in
			"${MENU_ITEMS[1]}") selnum=1 ;;
			"${MENU_ITEMS[2]}") selnum=2 ;;
			"${MENU_ITEMS[3]}") selnum=3 ;;
			"${MENU_ITEMS[4]}") selnum=4 ;;
			"${MENU_ITEMS[5]}") selnum=5 ;;
			"External") selnum=6 ;;
			"${MENU_ITEMS[0]}") selnum=0 ;;
			*)
			selnum=0 # LOG "Cancel pressed or unknown"
			;;
		esac
		# LOG "Option $selnum selected..."
		# LOG green "Press OK to continue..."; LOG " "; WAIT_FOR_BUTTON_PRESS A
	else
		selnum=0
		LOG red "========================= No ${text_target_UC} Selected ===="
		LOG red "Run Scan first to populate ${text_target_LC}s or set ${text_target_LC}."
	fi
}

# sub menu savedtargoptions
sub_menu_savedtargoptions() {
	if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
	declare -A MENU_ITEMS
	MENU_ITEMS[0]="Return to Main Menu"
	MENU_ITEMS[1]="View Saved ${text_target_UC}s"
	MENU_ITEMS[2]="Save Current ${text_target_UC}"
	MENU_ITEMS[3]="Set ${text_target_UC} MAC"
	MENU_ITEMS[4]="Clear Current ${text_target_UC}"
	MENU_ITEMS[5]="Select from Saved ${text_target_UC}s"
	MENU_ITEMS[6]="Save ALL Scan ${text_target_UC}s"
	MENU_ITEMS[7]="Save / Load Saved ${text_target_UC}s File"
	MENU_ITEMS[8]="Rename / Remove Saved ${text_target_UC}"
	MENU_ITEMS[9]="Remove Saved ${text_target_UC}s by Custom OUI/Name"
	MENU_ITEMS[10]="Clear Saved ${text_target_UC}s"
	local maxarritems=$(( ${#MENU_ITEMS[@]} - 1 ))
	local defaultselnum=1
	local text_pick_str="\"Manage Saved ${text_target_UC}s\""
	
	if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
	sorted_MENU_ITEMS=( $(for key in "${!MENU_ITEMS[@]}"; do echo "$key"; done | sort) )
	# Record each
	for num in "${!sorted_MENU_ITEMS[@]}"; do
		if [[ "$num" -eq 0 ]]; then
			if [[ -n "$target_mac" ]]; then
			  LOG green "========= Selected ${text_target_UC}: $target_mac ===="
			else
				LOG red "========================= No ${text_target_UC} Selected ===="
			fi
			LOG magenta "======================= Manage Saved ${text_target_UC}s ===="
		else
			item_txt="${MENU_ITEMS[$num]}"
			LOG "${num}: $item_txt"
			# dynamic list picker creation
			text_pick_str="${text_pick_str} \"${item_txt}\""
		fi
	done
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[0]}\"" # add exit to end slot
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[$defaultselnum]}\"" # add selected to final picker slot
	
	if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
	LOG magenta "======================= Manage Saved ${text_target_UC}s ===="
	if [[ "$archCur" == "pager" ]] ; then
		LOG "0: Return to Main Menu"
		LOG green "Press OK..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		# can anyone recommend a better way to do this?
		resp=$(eval "LIST_PICKER $text_pick_str")
	else
		LOG "${#MENU_ITEMS[@]}: Return to Main Menu"
		while true; do
			read -e -p "Select an option [1-${#MENU_ITEMS[@]}]: " output
			if [[ "$output" == "${#MENU_ITEMS[@]}" ]] ; then output=0; fi 
			# echo "opt: ${MENU_ITEMS[$output]}"
			case "$output" in
				[1-9]) resp="${MENU_ITEMS[$output]}"; break ;;
				0|10|11) resp="${MENU_ITEMS[$output]}"; break ;;
				*) echo "Invalid option. Please try again." ;;
			esac
		done
	fi
	case "$resp" in
		"${MENU_ITEMS[1]}") selnum=1 ;;
		"${MENU_ITEMS[2]}") selnum=2 ;;
		"${MENU_ITEMS[3]}") selnum=3 ;;
		"${MENU_ITEMS[4]}") selnum=4 ;;
		"${MENU_ITEMS[5]}") selnum=5 ;;
		"${MENU_ITEMS[6]}") selnum=6 ;;
		"${MENU_ITEMS[7]}") selnum=7 ;;
		"${MENU_ITEMS[8]}") selnum=8 ;;
		"${MENU_ITEMS[9]}") selnum=9 ;;
		"${MENU_ITEMS[10]}") selnum=10 ;;
		"${MENU_ITEMS[0]}") selnum=0 ;;
		*)
		selnum=0 # LOG "Cancel pressed or unknown"
		;;
	esac
	# LOG "Option $selnum selected..."
	# LOG green "Press OK to continue..."; LOG " "; WAIT_FOR_BUTTON_PRESS A
}


# sub menu preferences
sub_menu_preferences() {
	if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
	declare -A MENU_ITEMS
	MENU_ITEMS[0]="Return to Main Menu"
	MENU_ITEMS[1]="Global Settings Config"
	MENU_ITEMS[2]="Manage Bluetooth"
	MENU_ITEMS[3]="Sound"
	MENU_ITEMS[4]="Debug Mode"
	MENU_ITEMS[5]="Stealth Mode / Disable LEDS"
	MENU_ITEMS[6]="Device ${text_hunt_UC}er Scan Filter Config"
	MENU_ITEMS[7]="Clear History / Data / Settings"
	MENU_ITEMS[8]="Extra"
	
	local maxarritems=$(( ${#MENU_ITEMS[@]} - 1 ))
	local defaultselnum=1
	local text_pick_str="\"Preferences\""
	
	sorted_MENU_ITEMS=( $(for key in "${!MENU_ITEMS[@]}"; do echo "$key"; done | sort) )
	# Record each
	for num in "${!sorted_MENU_ITEMS[@]}"; do
		if [[ "$num" -eq 0 ]]; then
			LOG magenta "================================ Preferences ===="
		else
			item_txt="${MENU_ITEMS[$num]}"
			LOG "${num}: $item_txt"
			# dynamic list picker creation
			text_pick_str="${text_pick_str} \"${item_txt}\""
		fi
	done
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[0]}\"" # add exit to end slot
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[$defaultselnum]}\"" # add selected to final picker slot
	
	LOG magenta "================================ Preferences ===="
	if [[ "$archCur" == "pager" ]] ; then
		LOG "0: Return to Main Menu"
		LOG green "Press OK..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		# can anyone recommend a better way to do this?
		resp=$(eval "LIST_PICKER $text_pick_str")
	else
		LOG "${#MENU_ITEMS[@]}: Return to Main Menu"
		while true; do
			read -e -p "Select an option [1-${#MENU_ITEMS[@]}]: " output
			if [[ "$output" == "${#MENU_ITEMS[@]}" ]] ; then output=0; fi 
			# echo "opt: ${MENU_ITEMS[$output]}"
			case "$output" in
				[1-${#MENU_ITEMS[@]}]) resp="${MENU_ITEMS[$output]}"; break ;;
				0) resp="${MENU_ITEMS[$output]}"; break ;;
				*) echo "Invalid option. Please try again." ;;
			esac
		done
	fi
	case "$resp" in
		"${MENU_ITEMS[1]}") selnum=1 ;;
		"${MENU_ITEMS[2]}") selnum=2 ;;
		"${MENU_ITEMS[3]}") selnum=3 ;;
		"${MENU_ITEMS[4]}") selnum=4 ;;
		"${MENU_ITEMS[5]}") selnum=5 ;;
		"${MENU_ITEMS[6]}") selnum=6 ;;
		"${MENU_ITEMS[7]}") selnum=7 ;;
		"${MENU_ITEMS[8]}") selnum=8 ;;
		"${MENU_ITEMS[0]}") selnum=0 ;;
		*)
		selnum=0 # LOG "Cancel pressed or unknown"
		;;
	esac
	# LOG "Option $selnum selected..."
	# LOG green "Press OK to continue..."; LOG " "; WAIT_FOR_BUTTON_PRESS A
}

# sub sub menu managebt
sub_sub_menu_managebt() {
	if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
	declare -A MENU_ITEMS
	MENU_ITEMS[0]="Return to Preferences"
	MENU_ITEMS[1]="Change Bluetooth Name"
	MENU_ITEMS[2]="Change Bluetooth MAC / Alias"
	MENU_ITEMS[3]="Change Bluetooth Status / Discovery Setting"
	MENU_ITEMS[4]="Retest USB Bluetooth for CSR"
	
	local maxarritems=$(( ${#MENU_ITEMS[@]} - 1 ))
	local defaultselnum=1
	local text_pick_str="\"Manage Bluetooth\""
	
	sorted_MENU_ITEMS=( $(for key in "${!MENU_ITEMS[@]}"; do echo "$key"; done | sort) )
	# Record each
	for num in "${!sorted_MENU_ITEMS[@]}"; do
		if [[ "$num" -eq 0 ]]; then
			LOG magenta "=========================== Manage Bluetooth ===="
		else
			item_txt="${MENU_ITEMS[$num]}"
			LOG "${num}: $item_txt"
			# dynamic list picker creation
			text_pick_str="${text_pick_str} \"${item_txt}\""
		fi
	done
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[0]}\"" # add exit to end slot
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[$defaultselnum]}\"" # add selected to final picker slot
	
	LOG magenta "=========================== Manage Bluetooth ===="
	if [[ "$archCur" == "pager" ]] ; then
		LOG "0: Return to Preferences"
		LOG green "Press OK..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		# can anyone recommend a better way to do this?
		resp=$(eval "LIST_PICKER $text_pick_str")
	else
		LOG "${#MENU_ITEMS[@]}: Return to Preferences"
		while true; do
			read -e -p "Select an option [1-${#MENU_ITEMS[@]}]: " output
			if [[ "$output" == "${#MENU_ITEMS[@]}" ]] ; then output=0; fi 
			# echo "opt: ${MENU_ITEMS[$output]}"
			case "$output" in
				[1-${#MENU_ITEMS[@]}]) resp="${MENU_ITEMS[$output]}"; break ;;
				0) resp="${MENU_ITEMS[$output]}"; break ;;
				*) echo "Invalid option. Please try again." ;;
			esac
		done
	fi
	case "$resp" in
		"${MENU_ITEMS[1]}") selnum=1 ;;
		"${MENU_ITEMS[2]}") selnum=2 ;;
		"${MENU_ITEMS[3]}") selnum=3 ;;
		"${MENU_ITEMS[4]}") selnum=4 ;;
		"${MENU_ITEMS[0]}") selnum=0 ;;
		*)
		selnum=0 # LOG "Cancel pressed or unknown"
		;;
	esac
	# LOG "Option $selnum selected..."
	# LOG green "Press OK to continue..."; LOG " "; WAIT_FOR_BUTTON_PRESS A
}


# sub sub menu extra
sub_sub_menu_extra() {
	if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
	declare -A MENU_ITEMS
	MENU_ITEMS[0]="Return to Preferences"
	MENU_ITEMS[1]="Privacy / Streamer Mode"
	MENU_ITEMS[2]="Friendly Mode"
	MENU_ITEMS[3]="Skip Asking to Save Results after 1st Scan"
	MENU_ITEMS[4]="Restore A + B LEDS"
	MENU_ITEMS[5]="Backup / Restore Config & History"
	
	local maxarritems=$(( ${#MENU_ITEMS[@]} - 1 ))
	local defaultselnum=1
	local text_pick_str="\"Extra\""
	
	sorted_MENU_ITEMS=( $(for key in "${!MENU_ITEMS[@]}"; do echo "$key"; done | sort) )
	# Record each
	for num in "${!sorted_MENU_ITEMS[@]}"; do
		if [[ "$num" -eq 0 ]]; then
			LOG magenta "====================================== Extra ===="
		else
			item_txt="${MENU_ITEMS[$num]}"
			LOG "${num}: $item_txt"
			# dynamic list picker creation
			text_pick_str="${text_pick_str} \"${item_txt}\""
		fi
	done
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[0]}\"" # add exit to end slot
	text_pick_str="${text_pick_str} \"${MENU_ITEMS[$defaultselnum]}\"" # add selected to final picker slot
	
	LOG magenta "====================================== Extra ===="
	if [[ "$archCur" == "pager" ]] ; then
		LOG "0: Return to Preferences"
		LOG green "Press OK..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		# can anyone recommend a better way to do this?
		resp=$(eval "LIST_PICKER $text_pick_str")
	else
		LOG "${#MENU_ITEMS[@]}: Return to Preferences"
		while true; do
			read -e -p "Select an option [1-${#MENU_ITEMS[@]}]: " output
			if [[ "$output" == "${#MENU_ITEMS[@]}" ]] ; then output=0; fi 
			# echo "opt: ${MENU_ITEMS[$output]}"
			case "$output" in
				[1-${#MENU_ITEMS[@]}]) resp="${MENU_ITEMS[$output]}"; break ;;
				0) resp="${MENU_ITEMS[$output]}"; break ;;
				*) echo "Invalid option. Please try again." ;;
			esac
		done
	fi
	case "$resp" in
		"${MENU_ITEMS[1]}") selnum=1 ;;
		"${MENU_ITEMS[2]}") selnum=2 ;;
		"${MENU_ITEMS[3]}") selnum=3 ;;
		"${MENU_ITEMS[4]}") selnum=4 ;;
		"${MENU_ITEMS[5]}") selnum=5 ;;
		"${MENU_ITEMS[0]}") selnum=0 ;;
		*)
		selnum=0 # LOG "Cancel pressed or unknown"
		;;
	esac
	# LOG "Option $selnum selected..."
	# LOG green "Press OK to continue..."; LOG " "; WAIT_FOR_BUTTON_PRESS A
}
