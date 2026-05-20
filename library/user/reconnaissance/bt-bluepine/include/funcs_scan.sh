#!/bin/bash
# Scan Functions for BluePine
# Author: cncartist
# Version: 1.4
# 
# reset_bt_adapter
# rssitxtsw_hci0
# rssitxtsw_hci1
# reset_gpsd
# 
# device_hunter
# detect_bt_classic
# detect_bt_le
# scan_detection
# 
# check_bt_axoncams
# check_bt_ccskimmr
# check_bt_flockcam
# check_bt_flippers
# check_bt_meshtast
# check_bt_usbkills
# check_bt_pineapps
# check_bt_customou
# 
# warn_bt_pineapps
# warn_bt_axoncams
# warn_bt_ccskimmr
# warn_bt_flippers
# warn_bt_flockcam
# warn_bt_meshtast
# warn_bt_usbkills
# warn_bt_customou
# 
# scan_detect_from_scanned
# detect_jammers
#

# Reset Bluetooth adapter to prevent errors/hanging	
reset_bt_adapter() {
	# devicecurrnt="hci0"
	local devicecurrnt="$1"
	if [[ -z "$1" ]]; then
		devicecurrnt="$BLE_IFACE"
	fi
	if [[ "$scan_stealth" -eq 0 ]]; then LED WHITE; fi
	killall hcitool 2>/dev/null
	hciconfig "$devicecurrnt" down 2>/dev/null
	# sleep 0.2; rmmod btusb; sleep 0.2; modprobe btusb; sleep 0.2
	sleep 0.5
	while true; do
		# hciconfig "$devicecurrnt" up
		if ! hciconfig "$devicecurrnt" up 2>/dev/null; then
			sleep 0.5
			# LOG red "Interface DOWN!: $devicecurrnt"
			# LOG red "Resetting"
			hciconfig "$devicecurrnt" reset 2>/dev/null
			sleep 1.5
			# LOG red "Trying to bring back up..."
			hciconfig "$devicecurrnt" up 2>/dev/null
			sleep 0.5
		else
			# LOG green "Interface UP!: $devicecurrnt"
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


# Reset GPSD in case stale data persists
reset_gpsd() {
	# only reset for pager currently
	if [[ "$archCur" == "pager" ]] ; then
		/etc/init.d/gpsd reload 2>/dev/null
		/etc/init.d/gpsd restart 2>/dev/null
	fi
}


# device hunter function
device_hunter() {
	reset_gpsd
	sleep 1 # give time for GPS_GET to catchup
	
	resp=$(CONFIRMATION_DIALOG "Modify current scan settings?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
		scantime_config
		scantype_config
		infscan_config
		filter_config
	else
		sleep 1 # give time for GPS_GET to catchup
	fi
	
	resp=$(CONFIRMATION_DIALOG "Confirm scan for ${text_target_LC}(s)?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then	
		local scannumber=0
		local founditems=0
		local select_target_seen=0
		local select_target_pres=0
		local check_bttype_seen=0
		local checkouionly=0
		local custom_hit=0
		hold_scan_btle="$scan_btle"
		hold_scan_btclassic="$scan_btclassic"
		local pattern1="Address:"
		local pattern2="Company:"
		local pattern3="Service Data:"
		local pattern4="RSSI:"
		local pattern5="Name \(complete\):"
		local SEARCH_STRING=""
		local gps_disptxt=""
		local gps_same_count=0
		local show_header_extra=0
		local filters_enabled=0
		local filterCount=0
		local filterText=""
		local totalmin=0
		local runtime=0
		local totalruntime=0
		local totalruntime_display=""
		local origtargcount="${#BT_TARGETS[@]}"
		local newtargcount=0
		local newfoundcount=0
		local scancomplete=0
		
		# set on each total run
		cancel_app=0
		gpspos_last=""

		rm "$DATASTREAMBT_FILE" 2>/dev/null
		rm "$DATASTREAMBT2_FILE" 2>/dev/null
		rm "$DATASTREAMBT3_FILE" 2>/dev/null
		rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
		
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		REPORT_FILE="$LOOT_SCAN/Report_${TIMESTAMP}.txt"
		DATASTREAMBT_FILE="$LOOT_SCAN/${TIMESTAMP}_DataBT.txt"
		DATASTREAMBT2_FILE="$LOOT_SCAN/${TIMESTAMP}_DataBT2.txt"
		DATASTREAMBT3_FILE="$LOOT_SCAN/${TIMESTAMP}_DataBT3.txt"
		DATASTREAMBTTMP_FILE="$LOOT_SCAN/${TIMESTAMP}_DataBTTMP.txt"
		
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_FILE"
		printf "  Bluetooth Device %ser Scan\n" "${text_hunt_UC}" >> "$REPORT_FILE"
		
		LOG blue "================================================="
		LOG cyan "========= Bluetooth Device ${text_hunt_UC}er Scan =========="
		
		if [[ "$filter_multilocal" -eq 1 || "$filter_randomall" -eq 1 || "$filter_localall" -eq 1 || "$filter_multiall" -eq 1 || "$filter_emptyoui" -eq 1 ]] && [[ "$scan_custom" -eq 0 && "$scan_targeted" == "false" ]] ; then
			filters_enabled=1
			if [[ "$filter_multilocal" -eq 1 && "$filter_randomall" -eq 1 && "$filter_localall" -eq 1 && "$filter_multiall" -eq 1 && "$filter_emptyoui" -eq 1 ]] ; then
				filterCount=1
				filterText="ALL Filters Enabled"
			else
				if [[ "$filter_emptyoui" -eq 1 ]] ; then
					filterCount=$((filterCount + 1))
					if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, NoOUI"; else filterText="NoOUI"; fi
				fi
				if [[ "$filter_multilocal" -eq 1 ]] ; then
					filterCount=$((filterCount + 1))
					if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, Basic"; else filterText="Basic"; fi
				fi
				if [[ "$filter_multiall" -eq 1 ]] ; then
					filterCount=$((filterCount + 1))
					if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, ALL Mcast"; else filterText="ALL Mcast"; fi
				fi
				if [[ "$filter_localall" -eq 1 ]] ; then
					filterCount=$((filterCount + 1))
					if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, ALL Loc"; else filterText="ALL Loc"; fi
				fi
				if [[ "$filter_randomall" -eq 1 ]] ; then
					filterCount=$((filterCount + 1))
					if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, ALL Rand"; else filterText="ALL Rand"; fi
				fi
			fi
		fi

		if [[ "$scan_custom" -eq 1 ]] ; then
			printf "  %s Custom OUI/Name - Report\n" "${text_hunt_UC}" >> "$REPORT_FILE"
			if [[ -n "$custom_oui" ]] ; then
				printf "  Custom OUI: %s - Report\n" "${custom_oui}" >> "$REPORT_FILE"
				if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$custom_oui"; custom_oui="${custom_oui:0:2}:░░:░░"; fi
				LOG cyan "========= Selected ${text_target_UC} OUI: ${custom_oui} ========="
				if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; fi
			else
				LOG cyan "============ Custom OUI not set... =============="
			fi
			if [[ -n "$custom_name" ]] ; then
				printf "  Custom Name: %s - Report\n" "${custom_name}" >> "$REPORT_FILE"
				if [[ "$scan_privacy" -eq 1 ]] ; then priv_name_save="$custom_name"; custom_name="$priv_name_txt"; fi
				length=${#custom_name}
				custom_name_display="$custom_name"
				if [[ "$length" -lt 25 ]] ; then
					max_value=$((25-length))
					custom_name_display+=" "
					for (( i = 0; i < max_value; i++ ))
					do
						custom_name_display+="="
					done
				fi
				LOG cyan   "========= ${text_target_UC} Name: ${custom_name_display}"
				# LOG cyan "========= target Name: ===== ===== ===== ===== ===== ====="
				# LOG cyan "============ Custom Name not set... ============="
				if [[ "$scan_privacy" -eq 1 ]] ; then custom_name="$priv_name_save"; fi
			else
				LOG cyan "============ Custom Name not set... ============="
			fi
		else
			if [[ -n "$target_mac" && "$scan_targeted" == "true" ]] ; then
				if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
				# LOG cyan "========= Selected target: 00:░░:░░:░░:░░:░░ ===="	
				LOG cyan "====== Selected ${text_target_UC}: $target_mac ======="	
				if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
				printf "  Selected %s: %s\n" "${text_target_UC}" "${target_mac}" >> "$REPORT_FILE"
			fi
		fi
		
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_FILE"
		printf "═════════════════════════════════════════════════\n\n" >> "$REPORT_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_FILE"
		LOG blue "================================================="
		sleep 2 # give time for GPS_GET to catchup
		
		if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		if [[ "$scan_mute" == "false" ]] ; then
			RINGTONE "glitchHack"
		fi
		if [[ "$scan_debug" == "true" ]] ; then
			LOG magenta "DEBUG Mode / Extra Logging ACTIVATED"
		fi
		if [[ "$filterCount" -gt 0 && "$scan_custom" -eq 0 && "$scan_targeted" == "false" ]] ; then 
			LOG blue "======================================= NOTICE =="
			LOG "Filters WILL REMOVE Real ${text_target_UC}s from Results"
			LOG red "Filter(s) ON: ${filterText}"
			LOG blue "======================================= NOTICE =="
			printf "Filter(s) ON: %s\n" "${filterText}" >> "$REPORT_FILE"
		elif [[ "$filterCount" -eq 0 && "$scan_custom" -eq 0 && "$scan_targeted" == "false" ]]; then
			LOG cyan "No Filters Enabled, All ${text_target_UC}s Shown"
		fi
		
		if [[ "$scan_btclassic" == "true" && "$scan_btle" == "true" ]] ; then
			LOG cyan "Scanning Classic + LE Bluetooth for ${DATA_SCAN_SECONDS}s each"
			printf "Scanning Classic + LE Bluetooth for %s seconds each.\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_FILE"
		else 
			if [[ "$scan_btclassic" == "true" ]] ; then
				LOG cyan "Scanning Classic Bluetooth for ${DATA_SCAN_SECONDS}s"
				printf "Scanning Classic Bluetooth for %s seconds.\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_FILE"
			fi
			if [[ "$scan_btle" == "true" ]] ; then
				LOG cyan "Scanning LE Bluetooth for ${DATA_SCAN_SECONDS}s"
				printf "Scanning LE Bluetooth for %s seconds.\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_FILE"
			fi
		fi
		sleep 1 # give time for GPS_GET to catchup
		if [[ "$scan_infrepeat" -eq 1 ]] ; then
			if [[ "$archCur" == "pager" ]] ; then
				LOG "Scanning... Press OK to pause/stop..."
			else
				LOG magenta "Press CTRL+C / CANCEL to pause/stop..."
			fi
		else
			LOG "Scanning... Please wait..."
		fi
		sleep 1 # give time for GPS_GET to catchup
		
		# first check to set header
		gpspos_cur=$(GPS_GET)
		if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
			gpspos_last="$gpspos_cur"; gps_disptxt=' +GPS+' # GPS is valid
		fi
		
		# start key check collection
		if [[ "$scan_infrepeat" -eq 1 ]] ; then start_evtest; fi
		
		
		while true; do
			scancomplete=0
			
			start=$SECONDS
			scannumber=$((scannumber + 1))
			reset_bt_adapter
			
			unset BT_RSSIS
			# unset BT_NAMES
			# unset BT_COMPS
			
			rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
			rm "$DATASTREAMBT_FILE" 2>/dev/null
			rm "$DATASTREAMBT2_FILE" 2>/dev/null
			
			declare -A BT_RSSIS
			# declare -A BT_NAMES
			# declare -A BT_COMPS
			founditems=0
			show_header_extra=0
			select_target_pres=0

			if [[ "$scan_infrepeat" -eq 1 ]] ; then check_cancel; if [[ "$cancel_app" -eq 1 ]]; then break; fi fi
			
			printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
			printf "%s - EVENT: Start scan #%s\n" "$(date +"%Y-%m-%d_%H%M%S")" "${scannumber}" >> "$REPORT_FILE"
			
			# LOG red "btmon"
			# (btmon &> "$DATASTREAMBTTMP_FILE") &
			(timeout --signal=SIGINT "$((DATA_SCAN_SECONDS*2+7))s" btmon &> "$DATASTREAMBTTMP_FILE") &
			sleep 1
			
			# set on each run
			gps_disptxt=""; gpspos_cur=$(GPS_GET)
			if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
				# LOG red "have GPS!" # gpspos_cur="1 2 3 4"
				if [[ "$gpspos_last" == "$gpspos_cur" ]] ; then
					gps_same_count=$((gps_same_count + 1))
				else
					gps_same_count=0
				fi
				gpspos_last="$gpspos_cur"; gps_disptxt=' +GPS+' # GPS is valid
				printf "GPS Pos.: %s\n" "${gpspos_last}" >> "$REPORT_FILE"
			else
				# LOG red "NO GPS!"
				if [[ -n "$gpspos_last" ]] ; then
					gps_disptxt=' NoGPS' # gps lost, last known coordinates: gpspos_last
					printf "GPS LOST! %s (Last Known Pos.)\n" "${gpspos_last}" >> "$REPORT_FILE"
				fi
			fi
			
			if [[ "$scannumber" -eq 1 ]] ; then
				LOG blue "-------------------------------------------"
				LOG cyan "|- Signal -| -- MAC Address -- - Name/Manuf${gps_disptxt}"
				LOG blue "-------------------------------------------"
			fi
			
			if [[ "$scan_btclassic" == "true" ]] ; then
				if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE SLOW; fi
				# LOG red "hcitool"
				# (timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" scan) &
				# (timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" scan --length=$DATA_SCAN_SECONDS) &
				((timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" scan --length=$DATA_SCAN_SECONDS) &) > /dev/null 2>&1
				# LOG red "sleep"
				sleep ${DATA_SCAN_SECONDS}
				if [[ "$scan_btle" == "true" ]] ; then
					reset_bt_adapter
				fi
			fi
			
			if [[ "$scan_btle" == "true" ]] ; then
				if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN SLOW; fi
				#run le scan second	
				# (timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" lescan) &
				((timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" lescan) &) > /dev/null 2>&1
				sleep ${DATA_SCAN_SECONDS}
			fi
			
			#finish scans
			killall hcitool 2>/dev/null
			killall btmon 2>/dev/null
			
			if [[ "$scan_stealth" -eq 0 ]] ; then LED WHITE; fi
			# LOG magenta "testing here"
			
			if [[ "$scan_infrepeat" -eq 1 ]] ; then check_cancel; if [[ "$cancel_app" -eq 1 ]]; then break; fi fi
			
			# check if file is not empty this time around
			if [[ -s "$DATASTREAMBTTMP_FILE" ]]; then
				# first check target mac for bt classic or BLE
				# if targeted search and found channel, show response and reprint header after text
				if [[ "$scan_custom" -eq 0 && -n "$target_mac" && "$scan_targeted" == "true" && "$check_bttype_seen" -eq 0 ]] ; then 
					# Use grep -B to get the pattern match and 5 lines of context before it
					# -m to get 3 results if avail
					# Then pipe this output to another grep to check for the second string
					LOG red "CHECKING FOR SIGNAL TYPE LE...."
					SEARCH_STRING="HCI Event: LE Meta Event" # check for BLE Signal
					if grep -m 5 -B 5 "$target_mac" "$DATASTREAMBTTMP_FILE" | grep -q "$SEARCH_STRING"; then
						# echo "String '$SEARCH_STRING' found within 5 lines of pattern '$target_mac'."
						scan_btle="true"
						scan_btclassic="false"
						check_bttype_seen=1
						if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
						LOG green "${text_target_UC}: ${target_mac} found on BLE!"
						if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
						LOG "Scanning BLE only for faster scan..."
						printf "%s: %s found on BLE!\n" "${text_target_UC}" "${target_mac}" >> "$REPORT_FILE"
						printf "Scanning BLE only for faster scan...\n" >> "$REPORT_FILE"
						LOG blue   "-------------------------------------------"
						LOG cyan   "|- Signal -| -- MAC Address -- - Name/Manuf${gps_disptxt}"
						LOG blue   "-------------------------------------------"
					fi
					if [[ "$check_bttype_seen" -eq 0 ]] ; then 
						LOG red "CHECKING FOR SIGNAL TYPE CLASSIC...."
						SEARCH_STRING="HCI Event: Extended Inquiry Result" # check for BT Classic Signal
						if grep -m 5 -B 5 "$target_mac" "$DATASTREAMBTTMP_FILE" | grep -q "$SEARCH_STRING"; then
							check_bttype_seen=1
						fi
						SEARCH_STRING="HCI Event: Inquiry Result" # check for BT Classic Signal
						if grep -m 5 -B 5 "$target_mac" "$DATASTREAMBTTMP_FILE" | grep -q "$SEARCH_STRING"; then
							check_bttype_seen=1
						fi
						if [[ "$check_bttype_seen" -eq 1 ]] ; then 
							scan_btle="false"
							scan_btclassic="true"
							if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
							LOG green "${text_target_UC}: ${target_mac} found on Classic BT!"
							if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
							LOG "Scanning Classic BT only for faster scan..."
							printf "%s: %s found on Classic BT!\n" "${text_target_UC}" "${target_mac}" >> "$REPORT_FILE"
							printf "Scanning Classic BT only for faster scan...\n" >> "$REPORT_FILE"
							LOG blue   "-------------------------------------------"
							LOG cyan   "|- Signal -| -- MAC Address -- - Name/Manuf${gps_disptxt}"
							LOG blue   "-------------------------------------------"
						fi
					fi
				fi
				
				printf "%s - EVENT: Start processing\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_FILE"
				printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
				printf "|- Signal -| -- MAC Address -- - Name/Manuf\n" >> "$REPORT_FILE"
				printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
				# process file
				# LOG magenta "START process file"
				
				# add extra lines to file
				printf "\n\n\n\n" >> "$DATASTREAMBTTMP_FILE"
				
				if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE; fi
				# correct pineapple pager reading its own address/device via hardware info
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
					cp "$DATASTREAMBT_FILE" "$LOOT_SCAN/${TIMESTAMP}_scan_${scannumber}.txt"
				fi
				
				# load addresses only into tmp file
				grep -E "Address:" "$DATASTREAMBT_FILE" | sort -n | uniq > "$DATASTREAMBT2_FILE"
				
				if [[ "$scan_infrepeat" -eq 1 ]] ; then check_cancel; if [[ "$cancel_app" -eq 1 ]]; then break; fi fi
				
				if [[ "$scan_stealth" -eq 0 ]] ; then LED GREEN; fi
			
				# allow single OUI search
				if [[ "$scan_custom" -eq 1 && -n "$custom_oui" && -z "$custom_name" ]] ; then
					checkouionly=1
				fi
				
				# run filters
				if [[ "$filters_enabled" -eq 1 ]] ; then
					# remove empty oui MACs if user chooses, only if non custom/target scan
					if [[ "$filter_emptyoui" -eq 1 ]] ; then 
						# add extra lines at end of file
						printf "\n\n\n" >> "$DATASTREAMBT_FILE"
						# remove empty
						sed -i '/Address: 00:00:00/ {d};' "$DATASTREAMBT2_FILE"
						sed -i '/Address: 00:00:00/ {N;N;N;d};' "$DATASTREAMBT_FILE"
					fi
					
					# Multicast (Group) 01
					# Locally Administered (Unicast) 02
					# remove basic multicast & locally administered if user chooses, only if non custom/target scan
					if [[ "$filter_multilocal" -eq 1 ]] ; then 
						# add extra lines at end of file
						printf "\n\n\n" >> "$DATASTREAMBT_FILE"
						# remove basic
						sed -i '/Address: 01/ {d}; /Address: 02/ {d};' "$DATASTREAMBT2_FILE"
						sed -i '/Address: 01/ {N;N;N;d}; /Address: 02/ {N;N;N;d};' "$DATASTREAMBT_FILE"
					fi
					
					# ALL Multicast (Local Multi) 01, 03, 05, 07, 09, 0B, 0D, 0F, 11 (and any other odd number), FF (Broadcast address)
					# remove ALL known multicast MACs if user chooses, only if non custom/target scan
					if [[ "$filter_multiall" -eq 1 ]] ; then 
						# add extra lines at end of file
						printf "\n\n\n" >> "$DATASTREAMBT_FILE"
						# remove multicast
						sed -i '/Address: 01/ {d}; /Address: 03/ {d}; /Address: 05/ {d}; /Address: 07/ {d}; /Address: 09/ {d}; /Address: 0B/ {d}; /Address: 0b/ {d}; /Address: 0D/ {d}; /Address: 0d/ {d}; /Address: 0F/ {d}; /Address: 0f/ {d}; /Address: FF/ {d}; /Address: ff/ {d};' "$DATASTREAMBT2_FILE"
						sed -i '/Address: 01/ {N;N;N;d}; /Address: 03/ {N;N;N;d}; /Address: 05/ {N;N;N;d}; /Address: 07/ {N;N;N;d}; /Address: 09/ {N;N;N;d}; /Address: 0B/ {N;N;N;d}; /Address: 0b/ {N;N;N;d}; /Address: 0D/ {N;N;N;d}; /Address: 0d/ {N;N;N;d}; /Address: 0F/ {N;N;N;d}; /Address: 0f/ {N;N;N;d}; /Address: FF/ {N;N;N;d}; /Address: ff/ {N;N;N;d};' "$DATASTREAMBT_FILE"
						# remove 11 (and any other odd number)
						sed -i -E '/Address: ([1-9][13579])/ {d};' "$DATASTREAMBT2_FILE"
						sed -i -E '/Address: ([1-9][13579])/ {N;N;N;d};' "$DATASTREAMBT_FILE"
					fi
					
					# ALL Locally Administered (Unicast) x2, x6, xA, xE
					# remove ALL known locally administered MACs if user chooses, only if non custom/target scan
					if [[ "$filter_localall" -eq 1 ]] ; then 
						# add extra lines at end of file
						printf "\n\n\n" >> "$DATASTREAMBT_FILE"
						# remove local admin MACs (x2, x6, xA, xE...)
						sed -i -E '/Address: .[26AaEe]/ {d};' "$DATASTREAMBT2_FILE"
						sed -i -E '/Address: .[26AaEe]/ {N;N;N;d};' "$DATASTREAMBT_FILE"
					fi
					
					# ALL Random (Local Multi) x3, x7, xB, xF
					# remove ALL known randomized MACs if user chooses, only if non custom/target scan
					if [[ "$filter_randomall" -eq 1 ]] ; then 
						# add extra lines at end of file
						printf "\n\n\n" >> "$DATASTREAMBT_FILE"
						# remove randomized MACs (x3, x7, xB, xF...)
						sed -i -E '/Address: .[37BbFf]/ {d};' "$DATASTREAMBT2_FILE"
						sed -i -E '/Address: .[37BbFf]/ {N;N;N;d};' "$DATASTREAMBT_FILE"
					fi
				fi
				
				# clean file blank lines with awk, input > output
				awk '/^[[:space:]]*$/ {blank++; if (blank<=3) print; next} {print; blank=0}' "$DATASTREAMBT_FILE" > "outputtmp.txt"
				mv "outputtmp.txt" "$DATASTREAMBT_FILE"
				# if [[ "$scan_debug" == "true" ]] ; then
				# 	cp "$DATASTREAMBT_FILE" "$LOOT_SCAN/${TIMESTAMP}_scan_${scannumber}_FILT.txt"
				# fi
				
				# clean up output file via temp file addresses
				# check if target_mac is set and filter file for only 1 mac address
				if [[ "$checkouionly" -eq 1 ]] || [[ -n "$target_mac" && "$scan_targeted" == "true" ]] ; then
					if [[ "$scan_custom" -eq 1 ]] ; then
						priv_mac_save="$target_mac"
						target_mac="$custom_oui"
					fi
					# LOG "mac is set, run single filter"
					awk -v pattern="Address: $target_mac" '
						$0 ~ pattern {
							if (count < 3) {
								print $0;
								# Read and print the next 3 lines
								for (i = 1; i <= 3; i++) {
									if ((getline line) > 0) {
										print line;
									} else {
										break; # Stop if end of file reached prematurely
									}
								}
								count++;
							}
						}
						count >= 3 { exit } # Exit after finding 3 sets
					' "$DATASTREAMBT_FILE" > "$DATASTREAMBT3_FILE"
					mv "$DATASTREAMBT3_FILE" "$DATASTREAMBT_FILE" # To edit the file in place
					# restore target mac
					if [[ "$scan_custom" -eq 1 ]] ; then
						target_mac="$priv_mac_save"
					fi
				else
					# LOG "mac is empty or needs name filtering as well, run full filter"
					while IFS= read -r line; do
						# LOG "$line"
						# mac=$(echo "${line}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
						# if [[ -n "$mac" ]]; then
						if mac=$(echo "${line}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}'); then
							# LOG "mac: ${mac}"
							# keeping enough groups to get "sweet spot" of data collection
							# too many to keep makes file to process too large
							# too little means likely missed data
							if [[ "$scan_infrepeat" -eq 1 ]] ; then check_cancel; if [[ "$cancel_app" -eq 1 ]]; then break; fi fi
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
				fi
				
				
				if [[ "$scan_debug" == "true" ]] ; then
					cp "$DATASTREAMBTTMP_FILE" "$LOOT_SCAN/${TIMESTAMP}_scan_${scannumber}_TMP.txt"
					cp "$DATASTREAMBT2_FILE" "$LOOT_SCAN/${TIMESTAMP}_scan_${scannumber}_ADDR.txt"
				fi
				rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
				rm "$DATASTREAMBT2_FILE" 2>/dev/null
				
				if [[ "$scan_stealth" -eq 0 ]] ; then LED YELLOW; fi
				
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
				# try these
				# [TV] Samsung 8 Series
				# s/\[TV\] Samsung 8 Series/TV Series8/; 
				# [LG] webOS TV
				# s/\[LG\] webOS TV/LGwebOSTV/; 
				# 
				# echo "Amazon.com Services, Inc. (0xfe00)" > "amazon.txt"
				# sed -i 's/Amazon.com Services, Inc../Amazon/; ' "amazon.txt"
				# cat "amazon.txt"
				# 
				# echo "Amazon.com Services, Inc. (0xfe00)" > "amazon.txt"
				# sed -i 's/Amazon.com Services, Inc.\./Amazon/; ' "amazon.txt"
				# cat "amazon.txt"
				# 
				# bulb - Leedarson IoT Technology Inc. "$target_oui" == "1C:D6:BD:"
				
				# add extra lines to separate addresses
				sed -i 's/Address:/\n\n\nAddress:/' "$DATASTREAMBT_FILE"
				# add extra lines at end of file
				printf "\n\n\n" >> "$DATASTREAMBT_FILE"
				
				# LOG magenta "DONE process file"
			fi
			# sleep 0.5
			
			if [[ "$scan_infrepeat" -eq 1 ]] ; then check_cancel; if [[ "$cancel_app" -eq 1 ]]; then break; fi fi
				
			# check if file is not empty this time around
			if [[ -s "$DATASTREAMBT_FILE" ]]; then
				# LOG "file has contents"
				if [[ "$scan_stealth" -eq 0 ]] ; then LED RED; fi
				# Enable case-insensitive matching
				shopt -s nocasematch
				
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
							custom_hit=0
							target_oui="${mac:0:8}"
							
							# if custom oui set without name set and not matching oui, skip rest
							if [[ "$checkouionly" -eq 1 && "$target_oui" != "$custom_oui" ]] ; then
								continue
							fi
							
							# Parse Name/Data
							# name=$((echo "${info[0]}" | grep -oP '(?<=Name ).*' || echo "Unknown") | cut -d' ' -f2)
							name=$(echo "${info[0]}" | grep -oP '(?<=Name ).*' || echo "Unknown")
							# echo "Name= $name"
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
							# LOG "comp2: ${comp}"
							
							# custom hit check
							if [[ "$scan_custom" -eq 1 ]] ; then
								if [[ -n "$custom_oui" && "$target_oui" == "$custom_oui" ]] ; then
									custom_hit=1
								fi
								if [[ -n "$custom_name" ]] && [[ "$name" == *"$custom_name"* || "$comp" == *"$custom_name"* ]] ; then
									custom_hit=1
								fi
								# no custom hit found, exit rest of calc for this address before saving
								if [[ "$custom_hit" -eq 0 ]] ; then
									continue
								fi
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
									BT_TARGETS[$mac]="$name"
									# LOG red "override name"
								fi
							else
								if [[ -n "$name" ]]; then
									BT_NAMES[$mac]="$name"
									BT_TARGETS[$mac]="$name"
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
							# ONLY if current is better than old value
							if [[ "$rssicheck" -gt "$rssi" ]]; then
								BT_RSSIS[$mac]="$rssi"
								if [[ "$scan_infrepeat" -eq 1 ]] ; then check_cancel; if [[ "$cancel_app" -eq 1 ]]; then break; fi fi
							fi
						fi					
					fi				
				done < "$DATASTREAMBT_FILE"
				
				# if BT_RSSIS[$mac] is empty, tell user no signals found, or no matches
				if [[ "${#BT_RSSIS[@]}" -eq 0 ]] ; then
					if [[ "$scan_custom" -eq 1 ]] ; then
						if [[ -n "$custom_oui" ]] ; then
							if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$custom_oui"; custom_oui="${custom_oui:0:2}:░░:░░"; fi
							LOG "No signals matching ${custom_oui} found..."
							if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; fi
							printf "No signals matching %s found...\n" "${custom_oui}" >> "$REPORT_FILE"
						fi
						if [[ -n "$custom_name" ]] ; then
							if [[ "$scan_privacy" -eq 1 ]] ; then priv_name_save="$custom_name"; custom_name="$priv_name_txt"; fi
							LOG "No signals matching '${custom_name}' found..."
							if [[ "$scan_privacy" -eq 1 ]] ; then custom_name="$priv_name_save"; fi
							printf "No signals matching '%s' found...\n" "${custom_name}" >> "$REPORT_FILE"
						fi
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
				fi
				
				# mark scan as complete for final count
				scancomplete=1
				
				# exit after 1 loop for testing
				# LOG "exit for testing"; exit 0
				
				if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
				
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
						if [[ -z "$name" || "$name" == "Unknown" ]] ; then
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
					name="${name}${comp}"
					if [[ "$archCur" == "pager" ]] ; then
						# edit name for length over pager screen
						length=${#name}; if [[ "$length" -gt 17 ]] ; then name="${name:0:15}.."; fi
					fi
					LOG "|${rssitxt}| ${mac} - ${name}"
					# LOG magenta "|__________| ░░:░░:░░:░░:░░:░░ - REALLY LONG LONG NAME"
				done < <(
					for key in "${!BT_RSSIS[@]}"; do
						echo "${BT_RSSIS[$key]} $key"
					done | sort -rn
				)
				# sort -rn for descending, sort -n for ascending
				# LOG "DONE re-order"
				
				#    |__________| 00:00:44:00:00:00 - Unknown n/a
				
				# LOG "|- Signal -| -- MAC Address -- - Name/Manuf"
				# LOG "-------------------------------------------"
				
				# Disable case-insensitive matching to restore default behavior
				shopt -u nocasematch
			else
				if [[ "$checkouionly" -eq 1 ]] ; then
					if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$custom_oui"; custom_oui="${custom_oui:0:2}:░░:░░"; fi
					LOG "No signals matching ${custom_oui} found..."
					if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; fi
					printf "No signals matching %s found...\n" "${custom_oui}" >> "$REPORT_FILE"
				else
					if [[ -n "$target_mac" && "$scan_targeted" == "true" ]] ; then
						if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
						LOG "No signals matching ${target_mac} found..."
						if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
						printf "No signals matching %s found...\n" "${target_mac}" >> "$REPORT_FILE"
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
				fi
			fi
			
			if [[ "$scan_mute" == "false" ]] ; then
				if [[ "$founditems" -gt 0 ]]; then
					RINGTONE "Achievement" # (short)
				else
					RINGTONE "sideBeam" # (short)
				fi
			fi
			
			# set scan values
			runtime=$((SECONDS-start))
			totalruntime=$((totalruntime+runtime))
			total_scans=$((total_scans + 1))
			PAYLOAD_SET_CONFIG bluepinesuite total_scans "$total_scans"
			
			LOG blue   "------------ ${founditems} signals found -------------"
			printf "%s bluetooth signals found\n" "${founditems}" >> "$REPORT_FILE"
			printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
			# LOG blue "-------------------------------------------"
			
			gpspos_cur=$(GPS_GET) # check gps
			if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
				gps_disptxt=' +GPS+' # GPS is valid
			else
				if [[ -n "$gpspos_last" ]] ; then
					gps_disptxt=' NoGPS' # gps lost, last known coordinates: gpspos_last
				fi
			fi
			LOG cyan   "|- Signal -| -- MAC Address -- - Name/Manuf${gps_disptxt}"
			
			# printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
			# printf "|- Signal -| -- MAC Address -- - Name/Manuf\n" >> "$REPORT_FILE"
			# printf "════════════════════════════════════════════\n" >> "$REPORT_FILE"
			printf "%s - EVENT: Finish scan\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_FILE"
			
			if [[ "$scan_infrepeat" -eq 1 ]] ; then check_cancel; if [[ "$cancel_app" -eq 1 ]]; then break; fi fi
			
			if [[ "$skip_ask_1st_scan" -eq 0 && "${#BT_RSSIS[@]}" -gt 0 && "$select_target_seen" -eq 0 && "$cancel_app" -eq 0 && "$scan_targeted" == "false" ]] ; then
				if [[ "$archCur" == "pager" ]] ; then killall evtest 2>/dev/null; fi
				LOG blue   "-------------------------------------------"
				LOG "Check results and Press OK..."
				WAIT_FOR_BUTTON_PRESS A
				select_target_seen=1
				select_target_pres=1
				resp=$(CONFIRMATION_DIALOG "Do you want to select a ${text_target_LC} from the results?")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					cancel_app=1
					select_target_go=1
					trap cleanup SIGINT
					break
				else
					resp=$(CONFIRMATION_DIALOG "Do you want to continue scanning?")
					if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						cancel_app=1
						trap cleanup SIGINT
						sleep 0.5
						break
					fi
					if [[ "$scan_infrepeat" -eq 1 ]] ; then
						start_evtest
						LOG blue   "-------------------------------------------"
						if [[ "$archCur" == "pager" ]] ; then
							LOG magenta "Long Press or Tap OK to pause/stop..."
						else
							LOG magenta "Press CTRL+C / CANCEL to pause/stop..."
						fi
						LOG magenta "Cannot be paused/stopped while BT scanning"
						LOG magenta "It may take a couple seconds to process..."
						show_header_extra=1
						sleep 2
					fi
				fi
			fi
			if [[ "$scan_infrepeat" -eq 1 ]] && (( scannumber % 20 == 0 )) && (( scannumber != 0 )); then
				LOG blue   "-------------------------------------------"
				if [[ "$archCur" == "pager" ]] ; then
					LOG magenta "Long Press or Tap OK to pause/stop..."
				else
					LOG magenta "Press CTRL+C / CANCEL to pause/stop..."
				fi
				LOG magenta "Cannot be paused/stopped while BT scanning"
				LOG magenta "It may take a couple seconds to process..."
				show_header_extra=1
			fi
			
			# reset GPS on scan interval, verify connection and clear stale data
			if [[ -n "$gpspos_last" ]] && (( gps_same_count % 6 == 0 )) && (( gps_same_count != 0 )); then
				# same exact gps coordinates received multiple times in a row, verify gps is still active
				LOG blue   "-------------------------------------------"
				LOG magenta "GPS caught in coordinate loop, resetting..."
				show_header_extra=1
				gps_same_count=0
				(reset_gpsd) &
				# reset for GPS_GET takes 10 seconds, prevent lost gps on reset
				# LOG red "RESETTING GPSD 10 seconds..."
				sleep 10
			fi
			
			if [[ "$show_header_extra" -eq 1 ]] ; then
				LOG blue   "-------------------------------------------"
				LOG cyan   "|- Signal -| -- MAC Address -- - Name/Manuf${gps_disptxt}"
			fi
			
			if [[ "$scan_infrepeat" -eq 0 ]] ; then
				if [[ "${#BT_RSSIS[@]}" -gt 0 && "$scan_targeted" == "false" && "$select_target_pres" -eq 0 ]] ; then
					LOG blue   "-------------------------------------------"
					LOG "Check results and Press OK..."
					WAIT_FOR_BUTTON_PRESS A
					sleep 3
					resp=$(CONFIRMATION_DIALOG "Do you want to select a ${text_target_LC} from the results?")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						cancel_app=1
						select_target_go=1
						break
					fi
					resp=$(CONFIRMATION_DIALOG "Do you want to continue scanning?")
					if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						cancel_app=1
						sleep 0.5
						break
					fi
				fi
				# LOG "scan_infrepeat: $scan_infrepeat"
				# WAIT_FOR_BUTTON_PRESS A
			else
				sleep 0.25
			fi
			LOG blue   "------------------------- Scanning again..."
			
			# LOG blue "------------ xx signals found -------------"
			# LOG blue "-------------------------------------------"
			# LOG green "Press OK to scan again..."
			# exit after 1 loop for testing
			# LOG "exit for testing"; exit 0
			
			if [[ "$scan_infrepeat" -eq 1 ]] ; then check_cancel; if [[ "$cancel_app" -eq 1 ]]; then break; fi fi
			
		done
		
		
		killall hcitool 2>/dev/null
		killall btmon 2>/dev/null
		if [[ "$archCur" == "pager" ]] ; then killall evtest 2>/dev/null; fi
		rm "$KEYCKTMP_FILE" 2>/dev/null
		
		LOG cyan "================= Scan Results =================="
		if [[ "$totalruntime" -gt 60 ]] ; then 
			totalmin=$((totalruntime/60)); secs=$((totalruntime%60))
			if [[ "$secs" -gt 34 ]] ; then totalmin=$((totalmin+1)); fi
		else
			if [[ "$totalruntime" -gt 34 ]] ; then totalmin=1; fi
		fi
		newtargcount="${#BT_TARGETS[@]}"		
		newfoundcount=$((newtargcount-origtargcount))
			
		if [[ "$totalruntime" -ge 86400 ]] ; then
			days=$((totalruntime/86400)); hrs=$((totalruntime%86400/3600)); mins=$((totalruntime%3600/60))
			if [[ "$totalruntime" -ge 172800 ]] ; then
				totalruntime_display="${days} days ${hrs} hr ${mins} min"
			else
				totalruntime_display="${days} day ${hrs} hr ${mins} min"
			fi # echo "totalruntime_display: $totalruntime_display"
		else
			if [[ "$totalruntime" -ge 3600 ]] ; then
				hrs=$((totalruntime/3600)); mins=$((totalruntime%3600/60))
				totalruntime_display="${hrs} hr ${mins} min"
			else
				if [[ "$totalruntime" -ge 60 ]] ; then
					mins=$((totalruntime/60)); secs=$((totalruntime%60))
					if [[ "$mins" -gt 9 ]] ; then
						totalruntime_display="${mins} min"
					else
						totalruntime_display="${mins} min ${secs}s"
					fi
				else
					totalruntime_display="${totalruntime}s"
				fi
			fi
		fi
		LOG "Total Scantime: ${totalruntime_display}"
		printf "Total Scantime: %s\n" "${totalruntime_display}" >> "$REPORT_FILE"
		if [[ "$scancomplete" -eq 0 && "$scannumber" -gt 1 ]] ; then
			scannumberShow=$((scannumber-1))
		else
			scannumberShow="$scannumber"
		fi
		if [[ "$newfoundcount" -gt 0 ]] ; then
			if [[ "$scannumberShow" -gt 1 ]] ; then
				LOG "${newfoundcount} Unique ${text_target_UC}(s) Found in ${scannumberShow} Scans!"
			else
				LOG "${newfoundcount} Unique ${text_target_UC}(s) Found in ${scannumberShow} Scan!"
			fi
		else
			LOG red "No Unique ${text_target_UC}s Found in ${scannumberShow} Scan(s)"
		fi
		printf "%s Unique Targets Found in %s Scan(s)\n" "${newfoundcount}" "${scannumberShow}" >> "$REPORT_FILE"
		LOG " "
		LOG "Full results saved to: $(basename ${REPORT_FILE})"
		LOG blue "================= Scan Results =================="
		# time to view results
		sleep 3
		
		# set scan values 
		total_scan_min=$((total_scan_min + totalmin))
		PAYLOAD_SET_CONFIG bluepinesuite total_scan_min "$total_scan_min"
		
		# restore default scan settings before returning in case they were changed
		scan_btle="$hold_scan_btle"
		scan_btclassic="$hold_scan_btclassic"
		
		
		if [[ "${#BT_TARGETS[@]}" -gt 0 ]] ; then
			# ask if they want to add results after scans completed
			resp=$(CONFIRMATION_DIALOG "Do you want to add results to Saved ${text_target_UC}s?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				sleep 0.5
				saved_targets_saveall
			fi
			sleep 0.5
			# open select target screen before returning to main menu
			if [[ "$select_target_go" -eq 1 ]]; then
				cancel_app=0
				select_target
			fi
		fi
	else
		LOG "Scan skipped..."
	fi
}




# le bt scan
detect_bt_le() {
	scannumber="$1"
	TIMESTAMP="$2"
	reset_bt_adapter
	if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN SLOW; fi
	# Enable case-insensitive matching
	shopt -s nocasematch
    while read -r line; do
        mac=${line%% *}
        name=${line#"$mac"}
        name=${name# }
        # Check if MAC is valid
        # if [[ ! "$mac" =~ $VALID_MAC ]]; then
        #     continue
        # fi
		# LOG "$line"
		if [[ "$scan_BT_AXONCAMS" == "true" ]] ; then check_bt_axoncams "$mac" "$name"; fi
		if [[ "$scan_BT_CCSKIMMR" == "true" ]] ; then check_bt_ccskimmr "$mac" "$name"; fi
		if [[ "$scan_BT_FLOCKCAM" == "true" ]] ; then check_bt_flockcam "$mac" "$name"; fi
		if [[ "$scan_BT_MESHTAST" == "true" ]] ; then check_bt_meshtast "$mac" "$name"; fi
		if [[ "$scan_BT_FLIPPERS" == "true" ]] ; then check_bt_flippers "$mac" "$name"; fi
		if [[ "$scan_BT_USBKILLS" == "true" ]] ; then check_bt_usbkills "$mac" "$name"; fi
		# Pineapple pager is BT CLASSIC
    done < <(
        timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" lescan &> "$DATASTREAMBTLETMP_FILE"
		sort -u "$DATASTREAMBTLETMP_FILE"
    )
	if [[ "$scan_debug" == "true" ]] ; then
		cp "$DATASTREAMBTLETMP_FILE" "$LOOT_DETECT/${TIMESTAMP}_scanLE_${scannumber}.txt"
	fi
	# Disable case-insensitive matching to restore default behavior
	shopt -u nocasematch
	# timeout --signal=SIGINT 5s hcitool -i hci0 lescan
}

# classic bt scan
detect_bt_classic() {
	scannumber="$1"
	TIMESTAMP="$2"
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
	if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE SLOW; fi
	# LOG red "btmon"
	# (btmon &> "$DATASTREAMBTTMP_FILE") &
	(timeout --signal=SIGINT "$((DATA_SCAN_SECONDS+2))s" btmon &> "$DATASTREAMBTTMP_FILE") &
	sleep 1
	# LOG red "hcitool"
	# (timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" scan) &
	# (timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" scan --length=$DATA_SCAN_SECONDS) &
	((timeout --signal=SIGINT "${DATA_SCAN_SECONDS}s" hcitool -i "$BLE_IFACE" scan --length=$DATA_SCAN_SECONDS) &) > /dev/null 2>&1
	# LOG red "sleep"
	sleep ${DATA_SCAN_SECONDS}
		
	# finish scans
	killall hcitool 2>/dev/null
	killall btmon 2>/dev/null
	
	if [[ "$scan_stealth" -eq 0 ]] ; then LED YELLOW; fi
	# LOG magenta "testing here"
		
	if [[ -s "$DATASTREAMBTTMP_FILE" ]]; then
		# process file
		# LOG magenta "START process file"
		if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE; fi
		# add extra lines to file
		printf "\n\n\n\n" >> "$DATASTREAMBTTMP_FILE"
		
		# correct pineapple pager reading its own address/device via hardware info
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
		
		if [[ "$scan_debug" == "true" ]] ; then
			cp "$DATASTREAMBT_FILE" "$LOOT_DETECT/${TIMESTAMP}_scan_${scannumber}.txt"
		fi
		# load addresses only into tmp file
		grep -E "Address:" "$DATASTREAMBT_FILE" | sort -n | uniq > "$DATASTREAMBT2_FILE"
		
		if [[ "$scan_stealth" -eq 0 ]] ; then LED GREEN; fi
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
		
		if [[ "$scan_debug" == "true" ]] ; then
			cp "$DATASTREAMBTTMP_FILE" "$LOOT_DETECT/${TIMESTAMP}_scan_${scannumber}_TMP.txt"
			cp "$DATASTREAMBT2_FILE" "$LOOT_DETECT/${TIMESTAMP}_scan_${scannumber}_ADDR.txt"
		fi
		rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
		rm "$DATASTREAMBT2_FILE" 2>/dev/null
		
		if [[ "$scan_stealth" -eq 0 ]] ; then LED YELLOW; fi
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
		if [[ "$scan_stealth" -eq 0 ]] ; then LED RED; fi
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
					# LOG "comp2: ${comp}"
					
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
				fi					
			fi				
		done < "$DATASTREAMBT_FILE"
		
		# if BT_NAMES[$mac] is empty, tell user no signals found
		if [[ "${#BT_NAMES[@]}" -eq 0 ]] ; then
			LOG "No classic bluetooth signals found..."
			printf "No classic bluetooth signals found...\n" >> "$REPORT_DETECT_FILE"
		fi
		
		# exit after 1 loop for testing
		# LOG "exit for testing"; exit 0
		
		if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
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
			name="${BT_NAMES[$mac]}"
			comp="${BT_COMPS[$mac]}"
			if [[ "$comp" == "n/a" ]] ; then
				comp=""
			else
				if [[ -z "$name" || "$name" == "Unknown" ]] ; then
					name="$comp"
					comp=""
				else
					comp="/$comp"
				fi 
			fi
			
			check_bt_pineapps "$mac" "${name}${comp}"
			
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
	reset_gpsd
	sleep 3 # give time for GPS_GET to catchup
	
	# ---- DEFAULTS ----
	detections=0
	local scannumber=0
	local searchText=""
	local btcl_searchText=""
	local btle_searchText=""
	local searchCount=0
	local btcl_searchCount=0
	local btle_searchCount=0
	local totalmin=0
	local runtime=0
	local totalruntime=0
	local totalruntime_display=""
	
	# set on each total run
	gpspos_last=""
	
	if [[ "$scan_BT_AXONCAMS" == "true" ]] ; then
		searchCount=$((searchCount + 1))
		btle_searchCount=$((btle_searchCount + 1))
		if [[ "$searchCount" -gt 1 ]] ; then
			searchText="${searchText} / Axon"
		else
			searchText="Axon"
		fi
		if [[ "$btle_searchCount" -gt 1 ]] ; then
			btle_searchText="${btle_searchText} / Axon"
		else
			btle_searchText="Axon"
		fi
	fi
	if [[ "$scan_BT_CCSKIMMR" == "true" ]] ; then
		searchCount=$((searchCount + 1))
		btle_searchCount=$((btle_searchCount + 1))
		if [[ "$searchCount" -gt 1 ]] ; then
			searchText="${searchText} / CC Skimmer"
		else
			searchText="CC Skimmer"
		fi
		if [[ "$btle_searchCount" -gt 1 ]] ; then
			btle_searchText="${btle_searchText} / CC Skimmer"
		else
			btle_searchText="CC Skimmer"
		fi
	fi
	if [[ "$scan_BT_FLIPPERS" == "true" ]] ; then
		searchCount=$((searchCount + 1))
		btle_searchCount=$((btle_searchCount + 1))
		if [[ "$searchCount" -gt 1 ]] ; then
			searchText="${searchText} / Flipper"
		else
			searchText="Flipper"
		fi
		if [[ "$btle_searchCount" -gt 1 ]] ; then
			btle_searchText="${btle_searchText} / Flipper"
		else
			btle_searchText="Flipper"
		fi
	fi
	if [[ "$scan_BT_FLOCKCAM" == "true" ]] ; then
		searchCount=$((searchCount + 1))
		btle_searchCount=$((btle_searchCount + 1))
		if [[ "$searchCount" -gt 1 ]] ; then
			searchText="${searchText} / Flock"
		else
			searchText="Flock"
		fi
		if [[ "$btle_searchCount" -gt 1 ]] ; then
			btle_searchText="${btle_searchText} / Flock"
		else
			btle_searchText="Flock"
		fi
	fi
	if [[ "$scan_BT_MESHTAST" == "true" ]] ; then
		searchCount=$((searchCount + 1))
		btle_searchCount=$((btle_searchCount + 1))
		if [[ "$searchCount" -gt 1 ]] ; then
			searchText="${searchText} / Meshtastic"
		else
			searchText="Meshtastic"
		fi
		if [[ "$btle_searchCount" -gt 1 ]] ; then
			btle_searchText="${btle_searchText} / Meshtastic"
		else
			btle_searchText="Meshtastic"
		fi
	fi
	if [[ "$scan_BT_USBKILLS" == "true" ]] ; then
		searchCount=$((searchCount + 1))
		btle_searchCount=$((btle_searchCount + 1))
		if [[ "$searchCount" -gt 1 ]] ; then
			searchText="${searchText} / USB Kill"
		else
			searchText="USB Kill"
		fi
		if [[ "$btle_searchCount" -gt 1 ]] ; then
			btle_searchText="${btle_searchText} / USB Kill"
		else
			btle_searchText="USB Kill"
		fi
	fi
	if [[ "$scan_BT_PINEAPPS" == "true" ]] ; then
		searchCount=$((searchCount + 1))
		btcl_searchCount=$((btcl_searchCount + 1))
		if [[ "$searchCount" -gt 1 ]] ; then
			searchText="${searchText} / WiFi Pineapple"
		else
			searchText="WiFi Pineapple"
		fi
		if [[ "$btcl_searchCount" -gt 1 ]] ; then
			btcl_searchText="${btcl_searchText} / WiFi Pineapple"
		else
			btcl_searchText="WiFi Pineapple"
		fi
	fi
	# Check for BT device with WiFi Pineapple/Flipper/USB Killer characteristics
	# Confirm Scan
	
	resp=$(CONFIRMATION_DIALOG "Modify current scan settings?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
		scantime_config
	else
		sleep 2 # give time for GPS_GET to catchup
	fi
	
	resp=$(CONFIRMATION_DIALOG "Scan for ${searchText} Style Bluetooth Devices?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		sleep 1 # give time for GPS_GET to catchup
		
		rm "$DATASTREAMBT_FILE" 2>/dev/null
		rm "$DATASTREAMBT2_FILE" 2>/dev/null
		rm "$DATASTREAMBT3_FILE" 2>/dev/null
		rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
		
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		REPORT_DETECT_FILE="$LOOT_DETECT/Report_${TIMESTAMP}.txt"
		DATASTREAMBT_FILE="$LOOT_DETECT/DataBT_${TIMESTAMP}.txt"
		DATASTREAMBT2_FILE="$LOOT_DETECT/DataBT2_${TIMESTAMP}.txt"
		DATASTREAMBT3_FILE="$LOOT_DETECT/DataBT3_${TIMESTAMP}.txt"
		DATASTREAMBTTMP_FILE="$LOOT_DETECT/DataBTTMP_${TIMESTAMP}.txt"
		DATASTREAMBTLE_FILE="$LOOT_DETECT/DataBTLE_${TIMESTAMP}.txt"
		DATASTREAMBTLETMP_FILE="$LOOT_DETECT/DataBTLETMP_${TIMESTAMP}.txt"
	
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
		printf "  Bluetooth Detection Scan - Report\n" >> "$REPORT_DETECT_FILE"
		printf "  %s Device BT Scan\n" "${searchText}" >> "$REPORT_DETECT_FILE"
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_DETECT_FILE"

		if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		if [[ "$scan_debug" == "true" ]] ; then
			LOG magenta "DEBUG Mode / Extra Logging ACTIVATED"
		fi
		sleep 2 # give time for GPS_GET to catchup
		
		while true; do
			start=$SECONDS
			detections=0
			scannumber=$((scannumber + 1))
			
			BT_AXONCAMS=()
			BT_CCSKIMMR=()
			BT_FLIPPERS=()
			BT_FLOCKCAM=()
			BT_MESHTAST=()
			BT_USBKILLS=()
			BT_PINEAPPS=()
			
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			printf "%s - EVENT: Start scan #%s\n" "$(date +"%Y-%m-%d_%H%M%S")" "${scannumber}" >> "$REPORT_DETECT_FILE"
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
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_BT_PINEAPPS" == "true" ]] ; then
				if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE SLOW; fi
				if [[ "$scan_BT_PINEAPPS" == "true" ]] ; then
					LOG cyan "Scanning for WiFi Pineapple BT Signals..."
				fi
				LOG cyan "Scanning for ${DATA_SCAN_SECONDS}s..."
				printf "Scanning for %s BT Signals...\n" "${btcl_searchText}" >> "$REPORT_DETECT_FILE"
				printf "Scanning for %ss...\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_DETECT_FILE"
				# run function to search wifi pine Classic
				detect_bt_classic "$scannumber" "$TIMESTAMP"
				LOG " "
				sleep 1
			fi			
			
			if [[ "$scan_BT_AXONCAMS" == "true" || "$scan_BT_CCSKIMMR" == "true" || "$scan_BT_FLIPPERS" == "true" || "$scan_BT_FLOCKCAM" == "true" || "$scan_BT_MESHTAST" == "true" || "$scan_BT_USBKILLS" == "true" ]] ; then
				if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN SLOW; fi
				LOG cyan "Scanning for ${btle_searchText} BT Signals..."
				LOG cyan "Scanning for ${DATA_SCAN_SECONDS}s..."
				printf "Scanning for %s BT Signals...\n" "${btle_searchText}" >> "$REPORT_DETECT_FILE"
				printf "Scanning for %ss...\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_DETECT_FILE"
				# run function to search flipper + usb kills LE
				detect_bt_le "$scannumber" "$TIMESTAMP"
				LOG " "
				sleep 0.25
			fi
			
			if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
			
			if [[ "$scan_BT_AXONCAMS" == "true" ]] ; then
				warn_bt_axoncams
				LOG " "
				sleep 0.25
			fi
			
			if [[ "$scan_BT_CCSKIMMR" == "true" ]] ; then
				warn_bt_ccskimmr
				LOG " "
				sleep 0.25
			fi
			
			if [[ "$scan_BT_FLIPPERS" == "true" ]] ; then
				warn_bt_flippers
				LOG " "
				sleep 0.25
			fi
			
			if [[ "$scan_BT_FLOCKCAM" == "true" ]] ; then
				warn_bt_flockcam
				LOG " "
				sleep 0.25
			fi

			if [[ "$scan_BT_MESHTAST" == "true" ]] ; then
				warn_bt_meshtast
				LOG " "
				sleep 0.25
			fi
			
			if [[ "$scan_BT_USBKILLS" == "true" ]] ; then 
				warn_bt_usbkills
				LOG " "
				sleep 0.25
			fi
			
			if [[ "$scan_BT_PINEAPPS" == "true" ]] ; then
				warn_bt_pineapps
				LOG " "
				sleep 0.25
			fi
			
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			printf "%s - EVENT: Complete scan #%s\n" "$(date +"%Y-%m-%d_%H%M%S")" "${scannumber}" >> "$REPORT_DETECT_FILE"
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			
			# set scan values
			runtime=$((SECONDS-start))
			totalruntime=$((totalruntime+runtime))
			total_scans=$((total_scans + 1))
			# LOG blue "-------------------------------------------"
			# LOG " "
			LOG green "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			
			rm "$DATASTREAMBT_FILE" 2>/dev/null
			rm "$DATASTREAMBT2_FILE" 2>/dev/null
			rm "$DATASTREAMBT3_FILE" 2>/dev/null
			rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
			rm "$DATASTREAMBTLETMP_FILE" 2>/dev/null
			# Confirm Scan
			resp=$(CONFIRMATION_DIALOG "Scan again?")
			if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
				break
			fi
			LOG "Scanning again..."
			printf "Scanning again...\n" >> "$REPORT_DETECT_FILE"
		done
		
		if [[ "$totalruntime" -gt 60 ]] ; then 
			totalmin=$((totalruntime/60)); secs=$((totalruntime%60))
			if [[ "$secs" -gt 34 ]] ; then totalmin=$((totalmin+1)); fi
		else
			if [[ "$totalruntime" -gt 34 ]] ; then totalmin=1; fi
		fi
		
		# finished
		if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		LOG green "Detection Scan(s) Completed!"
		printf "Scans Completed!\n" >> "$REPORT_DETECT_FILE"
		if [[ ${detections} -gt 0 ]]; then
			if [[ "$scan_mute" == "false" ]] ; then
				RINGTONE "warning"
			fi
			LOG red "$detections malicious suspects found!"
			printf "%s malicious suspects found!\n" "${detections}" >> "$REPORT_DETECT_FILE"
		else
			if [[ "$scan_mute" == "false" ]] ; then
				RINGTONE "ScaleTrill"
			fi
			LOG green "No malicious suspects found!"
			printf "No malicious suspects found!\n" >> "$REPORT_DETECT_FILE"
		fi		
		# set scan values
		total_scan_min=$((total_scan_min + totalmin))
		PAYLOAD_SET_CONFIG bluepinesuite total_scan_min "$total_scan_min"
		PAYLOAD_SET_CONFIG bluepinesuite total_scans "$total_scans"
		PAYLOAD_SET_CONFIG bluepinesuite total_detected "$total_detected"
			
		printf "\n" >> "$REPORT_DETECT_FILE"
		LOG " "
		LOG "Full results saved to: $(basename ${REPORT_DETECT_FILE})"
		
		LOG " "
		if [[ ${detections} -gt 0 ]]; then
			if [[ "$scan_stealth" -eq 0 ]] ; then LED RED SLOW; fi
			sleep 2
			# ask if they want to add results after scans completed
			resp=$(CONFIRMATION_DIALOG "Do you want to add results to Saved ${text_target_UC}s?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				sleep 0.5
				saved_targets_saveall
			fi
		fi
		sleep 0.5
		
	else
		LOG "Skipped Bluetooth Scan."
	fi
}



# AirTag Manufacturer ID
# https://github.com/7ENSOR/AirTagTag/tree/main/
# Check for AirTag using manufacturer data
# if (advertisedDevice.haveManufacturerData()) {
# std::string manufacturerData = advertisedDevice.getManufacturerData();
# if (manufacturerData.size() > 2 && manufacturerData[0] == 0x4C && manufacturerData[1] == 0x00) {
# Manufacturer ID: AirTags use Apples manufacturer ID (0x004C) within their advertising packets.


# axoncam check
check_bt_axoncams() {
	local mac="$1"
	local name="$2"
	local target_oui="${mac:0:8}"
	
	# Axon OUIs
	declare -A AXONCAMS_OUI
	# 00:25:df is the OUI for Taser International Inc aka Axon
	AXONCAMS_OUI["00:25:DF"]="y"
	# From OSINTI4L - Axon OUIs dedicated to them for networking gear
	# https://github.com/OSINTI4L/wifipineapplepager-payloads/blob/master/library/user/reconnaissance/Fuzz_Finder/Fuzz_Finder.sh
	AXONCAMS_OUI["00:58:28"]="y"
	AXONCAMS_OUI["00:C0:D4"]="y"
	AXONCAMS_OUI["84:70:03"]="y"

	if [[ -v AXONCAMS_OUI["$target_oui"] ]] ; then
		# check if key exists, even if empty
		if [[ -v BT_AXONCAMS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_AXONCAMS[$mac]="$name"
			fi
		else
			BT_AXONCAMS[$mac]="$name"
		fi
		if [[ -v BT_TARGETS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_TARGETS[$mac]="$name"
			fi
		else
			BT_TARGETS[$mac]="$name"
		fi
		# LOG "AXON exists!"
	fi
}

# ccskimmr check
check_bt_ccskimmr() {
	local mac="$1"
	local name="$2"
	local target_oui="${mac:0:8}"
	
	local checkyear=0
	local checkmon=0
	local checkday=0
	local checkdateMAC=""
	local skimmerfound=0
	
	# CC Skimmer default mac prefix
	local CCSKIMMR_OUI="00:06:66"
	
	# CHECK CC Skimmer NAMES
	declare -A CCSKIMMR_NAMES
	CCSKIMMR_NAMES["HC-03"]="y"
	CCSKIMMR_NAMES["HC-05"]="y"
	CCSKIMMR_NAMES["HC-06"]="y"
	CCSKIMMR_NAMES["HC-08"]="y"
	CCSKIMMR_NAMES["RNBT"]="y"
	
	if [[ "$mac" =~ $VALID_MAC ]]; then
		# Check against the MAC address pattern for manufacturing date
		# local mac="20:13:01:31:00:00"
		checkdateMAC=${mac:0:11}
		# LOG "mac $mac is valid"
		# LOG "checkdateMAC $checkdateMAC"
		# ; checkday="${checkdateMAC:9:2}"; echo "cy $checkday"
		checkyear="${checkdateMAC:0:2}${checkdateMAC:3:2}" # ${checkdateMAC:0:2} = 20 # ${checkdateMAC:3:2} = 13
		checkmon="${checkdateMAC:6:2}"
		checkday="${checkdateMAC:9:2}"
		curyear=$(date +%Y)
		re='^[0-9]+$'
		# check if numbers first
		if [[ "$checkyear" =~ $re && "$checkmon" =~ $re && "$checkday" =~ $re ]] ; then
			if [[ "$checkyear" -ge 2013 && "$checkyear" -le "$curyear" && "$checkmon" -ge 1 && "$checkmon" -le 12 && "$checkday" -ge 1 && "$checkday" -le 31 ]] ; then
				skimmerfound=1
			fi
		fi
	fi
	if [[ "$CCSKIMMR_OUI" == "$target_oui" || -v CCSKIMMR_NAMES["$name"] || "$name" =~ ^RNBT-[A-Za-z0-9]{4}$ || "$skimmerfound" -eq 1 ]] ; then
		skimmerfound=1
		# check if key exists, even if empty
		if [[ -v BT_CCSKIMMR[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_CCSKIMMR[$mac]="$name"
			fi
		else
			BT_CCSKIMMR[$mac]="$name"
		fi
		if [[ -v BT_TARGETS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_TARGETS[$mac]="$name"
			fi
		else
			BT_TARGETS[$mac]="$name"
		fi
		# LOG "CCSKIMMR exists!"
	fi
}

# flockcam check
check_bt_flockcam() {
	local mac="$1"
	local name="$2"
	local target_oui="${mac:0:8}"
	
	# Flock OUIs
	declare -A FLOCKCAM_OUIS
	# Flock Safety — high-confidence OUIs (direct registration or exclusive use)
	# FS Ext Battery devices
	FLOCKCAM_OUIS["58:8e:81"]="y"
	FLOCKCAM_OUIS["cc:cc:cc"]="y"
	FLOCKCAM_OUIS["ec:1b:bd"]="y"
	FLOCKCAM_OUIS["90:35:ea"]="y"
	FLOCKCAM_OUIS["04:0d:84"]="y"
	FLOCKCAM_OUIS["f0:82:c0"]="y"
	FLOCKCAM_OUIS["1c:34:f1"]="y"
	FLOCKCAM_OUIS["38:5b:44"]="y"
	FLOCKCAM_OUIS["94:34:69"]="y"
	FLOCKCAM_OUIS["b4:e3:f9"]="y"
	# Flock WiFi devices
	FLOCKCAM_OUIS["70:c9:4e"]="y"
	FLOCKCAM_OUIS["3c:91:80"]="y"
	FLOCKCAM_OUIS["d8:f3:bc"]="y"
	FLOCKCAM_OUIS["80:30:49"]="y"
	FLOCKCAM_OUIS["14:5a:fc"]="y"
	FLOCKCAM_OUIS["74:4c:a1"]="y"
	FLOCKCAM_OUIS["08:3a:88"]="y"
	FLOCKCAM_OUIS["9c:2f:9d"]="y"
	FLOCKCAM_OUIS["94:08:53"]="y"
	FLOCKCAM_OUIS["e4:aa:ea"]="y"
	# Flock Safety (direct IEEE registration)
	FLOCKCAM_OUIS["b4:1e:52"]="y"
	# Flock Safety contract manufacturers - lower confidence alone.
	# These OUIs belong to Liteon Technology and USI (Universal Scientific Industrial), which produce Flock hardware but also ship unrelated consumer/enterprise devices. MAC match alone may be a false positive.
	FLOCKCAM_OUIS["f4:6a:dd"]="y"
	FLOCKCAM_OUIS["f8:a2:d6"]="y"
	FLOCKCAM_OUIS["e0:0a:f6"]="y"
	FLOCKCAM_OUIS["00:f4:8d"]="y"
	FLOCKCAM_OUIS["d0:39:57"]="y"
	FLOCKCAM_OUIS["e8:d0:fc"]="y"
	# SoundThinking (formerly ShotSpotter) — acoustic gunshot detection sensors
	# d4:11:d6 is registered to SoundThinking in the IEEE OUI database.
	FLOCKCAM_OUIS["d4:11:d6"]="y"

	# CHECK Flock NAMES
	declare -A FLOCKCAM_NAMES
	FLOCKCAM_NAMES["FS Ext Battery"]="y"
	FLOCKCAM_NAMES["Penguin"]="y"
	FLOCKCAM_NAMES["Flock"]="y"
	FLOCKCAM_NAMES["Pigvision"]="y"
	
	# FLOCK Manufacturer ID
	# BLE Manufacturer Company IDs
	# Source: wgreenberg/flock-you - XUNTONG ID associated with Flock Safety devices
	# static const uint16_t ble_manufacturer_ids[] = {
	#     0x09C8   // XUNTONG
	# };
	# Segment 3: 03 03 C8 09
	# Length: 0x03 → 3 bytes follow
	# AD Type: 0x03 → Complete List of 16-bit Service UUIDs
	# Value: C8 09 → UUID 0x09C8 (little-endian!)

	if [[ -v FLOCKCAM_OUIS["$target_oui"] || -v FLOCKCAM_NAMES["$name"] ]]; then
		# check if key exists, even if empty
		if [[ -v BT_FLOCKCAM[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_FLOCKCAM[$mac]="$name"
			fi
		else
			BT_FLOCKCAM[$mac]="$name"
		fi
		if [[ -v BT_TARGETS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_TARGETS[$mac]="$name"
			fi
		else
			BT_TARGETS[$mac]="$name"
		fi
		# LOG "FLOCK exists!"
	fi
}

# flipper check
check_bt_flippers() {
	local mac="$1"
	local name="$2"
	local target_oui="${mac:0:8}"
	
	local FLIPPER_OUI="0C:FA:22"
	local FLIPPER_NAME="flipper"
	local FLIPPER_NAME2="badusb"
	
	# Add hits, devices that include string "flipper" in name or hardcoded OUI in MAC
	if [[ "$target_oui" == "$FLIPPER_OUI" || "$name" == *"$FLIPPER_NAME"* || "$name" == *"$FLIPPER_NAME2"* ]] ; then
		# check if key exists, even if empty
		if [[ -v BT_FLIPPERS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_FLIPPERS[$mac]="$name"
			fi
		else
			BT_FLIPPERS[$mac]="$name"
		fi
		if [[ -v BT_TARGETS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_TARGETS[$mac]="$name"
			fi
		else
			BT_TARGETS[$mac]="$name"
		fi
		# LOG "FLIPPER found!"
	fi
}

# meshtastic check
check_bt_meshtast() {
	local mac="$1"
	local name="$2"
		
	# Meshtastic default name prefix
	local MESHTAST_NAME="meshtastic"
	
	# Meshtastic SERVICE_UUID
	# https://github.com/jbohack/nyanBOX/blob/main/VScode%20Platformio/src/meshcore_detector.cpp
	# const uint8_t MESHCORE_SERVICE_UUID[16] = {
	# 	0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
	# 	0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E
	# };
	# https://github.com/jbohack/nyanBOX/blob/main/VScode%20Platformio/src/meshtastic_detector.cpp
	# const uint8_t MESHTASTIC_SERVICE_UUID[16] = {
	# 	0xFD, 0xEA, 0x73, 0xE2, 0xCA, 0x5D, 0xA8, 0x9F,
	# 	0x1F, 0x46, 0xA8, 0x15, 0x18, 0xB2, 0xA1, 0x6B
	# };
	
	if [[ "$name" == *"$MESHTAST_NAME"* ]] ; then
		# check if key exists, even if empty
		if [[ -v BT_MESHTAST[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_MESHTAST[$mac]="$name"
			fi
		else
			BT_MESHTAST[$mac]="$name"
		fi
		if [[ -v BT_TARGETS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_TARGETS[$mac]="$name"
			fi
		else
			BT_TARGETS[$mac]="$name"
		fi
		# LOG "MESHTAST exists!"
	fi
}

# usbkill check
check_bt_usbkills() {
	local mac="$1"
	local name="$2"
	local target_oui="${mac:0:8}"
	
	local USBKILL_OUI="F1:9E:08"
	local USBKILL_NAME="usbkill"
	
	# Add hits, devices that include string "usbkill" in name or hardcoded OUI in MAC
	if [[ "$target_oui" == "$USBKILL_OUI" || "$name" == *"$USBKILL_NAME"* ]] ; then
		# check if key exists, even if empty
		if [[ -v BT_USBKILLS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_USBKILLS[$mac]="$name"
			fi
		else
			BT_USBKILLS[$mac]="$name"
		fi
		if [[ -v BT_TARGETS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "(unknown)" ]] ; then
				BT_TARGETS[$mac]="$name"
				# LOG "ADDING INSIDE! $mac Name: $name"
			fi
		else
			BT_TARGETS[$mac]="$name"
			# LOG "ADDING ELSE! $mac Name: $name"
		fi
		# LOG "USBKILL found! $mac Name: $name"
		# LOG "TARGET! $mac Name: ${BT_TARGETS[$mac]}"
		# LOG "BT_USBKILLS! $mac Name: ${BT_USBKILLS[$mac]}"
	fi
}

# wifipine check
check_bt_pineapps() {
	local mac="$1"
	local name="$2"
	local comp=""
	local target_oui="${mac:0:8}"
	
	local PINEAPP_OUI="00:13:37"
	local PINEAPP_NAME="pine"
	local PINEAPP_NAME2="bluez"
	local PINEAPP_NAME3="pager"
	
	if [[ "$target_oui" == "$PINEAPP_OUI" || "$name" == *"$PINEAPP_NAME"* || "$name" == *"$PINEAPP_NAME2"* || "$name" == *"$PINEAPP_NAME3"* ]] ; then
		# Add hits, devices that include string "pine" in name or hardcoded OUI in MAC
		# check if key exists, even if empty
		if [[ -v BT_PINEAPPS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "Unknown" ]] ; then
				BT_PINEAPPS[$mac]="${name}${comp}"
			fi
		else
			BT_PINEAPPS[$mac]="${name}${comp}"
		fi
		if [[ -v BT_TARGETS[$mac] ]]; then
			# only update if name not empty
			if [[ -n "$name" && "$name" != "Unknown" ]] ; then
				BT_TARGETS[$mac]="${name}${comp}"
			fi
		else
			BT_TARGETS[$mac]="${name}${comp}"
		fi
		# LOG "WiFi Pineapple found!"
		# LOG "${mac} - ${name}${comp}"
	fi
}

# custom check
check_bt_customou() {
	local mac="$1"
	local name="$2"
	local target_oui="${mac:0:8}"
	
	# search both
	if [[ -n "$custom_name" && -n "$custom_oui" ]] ; then
		# Add hits, devices that include custom oui or name
		if [[ "$target_oui" == "$custom_oui" || "$name" == *"$custom_name"* ]] ; then
			# check if key exists, even if empty
			if [[ -v BT_CUSTOMOU[$mac] ]]; then
				# only update if name not empty
				if [[ -n "$name" && "$name" != "(unknown)" && "$name" != "Unknown" ]] ; then
					BT_CUSTOMOU[$mac]="$name"
				fi
			else
				BT_CUSTOMOU[$mac]="$name"
			fi
			if [[ -v BT_TARGETS[$mac] ]]; then
				# only update if name not empty
				if [[ -n "$name" && "$name" != "(unknown)" && "$name" != "Unknown" ]] ; then
					BT_TARGETS[$mac]="$name"
					# LOG "ADDING INSIDE! $mac Name: $name"
				fi
			else
				BT_TARGETS[$mac]="$name"
				# LOG "ADDING ELSE! $mac Name: $name"
			fi
			# LOG "custom found! $mac Name: $name"
		fi
	else
		# search oui only
		if [[ -n "$custom_oui" ]] ; then
			# Add hits, devices that include custom oui or name
			if [[ "$target_oui" == "$custom_oui" ]] ; then
				# check if key exists, even if empty
				if [[ -v BT_CUSTOMOU[$mac] ]]; then
					# only update if name not empty
					if [[ -n "$name" && "$name" != "(unknown)" && "$name" != "Unknown" ]] ; then
						BT_CUSTOMOU[$mac]="$name"
					fi
				else
					BT_CUSTOMOU[$mac]="$name"
				fi
				if [[ -v BT_TARGETS[$mac] ]]; then
					# only update if name not empty
					if [[ -n "$name" && "$name" != "(unknown)" && "$name" != "Unknown" ]] ; then
						BT_TARGETS[$mac]="$name"
						# LOG "ADDING INSIDE! $mac Name: $name"
					fi
				else
					BT_TARGETS[$mac]="$name"
					# LOG "ADDING ELSE! $mac Name: $name"
				fi
				# LOG "custom found! $mac Name: $name"
			fi
		fi
		# search name only
		if [[ -n "$custom_name" ]] ; then
			# Add hits, devices that include custom oui or name
			if [[ "$name" == *"$custom_name"* ]] ; then
				# check if key exists, even if empty
				if [[ -v BT_CUSTOMOU[$mac] ]]; then
					# only update if name not empty
					if [[ -n "$name" && "$name" != "(unknown)" && "$name" != "Unknown" ]] ; then
						BT_CUSTOMOU[$mac]="$name"
					fi
				else
					BT_CUSTOMOU[$mac]="$name"
				fi
				if [[ -v BT_TARGETS[$mac] ]]; then
					# only update if name not empty
					if [[ -n "$name" && "$name" != "(unknown)" && "$name" != "Unknown" ]] ; then
						BT_TARGETS[$mac]="$name"
						# LOG "ADDING INSIDE! $mac Name: $name"
					fi
				else
					BT_TARGETS[$mac]="$name"
					# LOG "ADDING ELSE! $mac Name: $name"
				fi
				# LOG "custom found! $mac Name: $name"
			fi
		fi
	fi
}

# wifipine warn
warn_bt_pineapps() {
	if [[ ${#BT_PINEAPPS[@]} -gt 0 ]]; then
		curcount=1; totcount="${#BT_PINEAPPS[@]}"
		LOG red "-------------------------------------------------"
		LOG red "WARNING: Found ${totcount} potential WiFi Pineapple BT Device(s)"
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "WARNING: Found %s potential WiFi Pineapple BT Device(s).\n" "${totcount}" >> "$REPORT_DETECT_FILE"
		LOG " "
		# Record each WiFi Pineapple device found
		for mac in "${!BT_PINEAPPS[@]}"; do
			name="${BT_PINEAPPS[$mac]}"
			printf "Potential WiFi Pineapple:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; fi
			LOG red "Potential WiFi Pineapple:\nBT Name: $name\nBT MAC: $mac"
			detections=$((detections + 1))
			total_detected=$((total_detected + 1))
			if [[ "$curcount" -lt "$totcount" ]] ; then
				LOG " "
			fi
			curcount=$((curcount + 1))
		done
		LOG red "-------------------------------------------------"
	else 
		LOG green "No obvious WiFi Pineapple BT Devices detected."
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "No obvious WiFi Pineapple BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
	fi
}

# axoncam warn
warn_bt_axoncams() {
	if [[ ${#BT_AXONCAMS[@]} -gt 0 ]]; then
		curcount=1; totcount="${#BT_AXONCAMS[@]}"
		LOG red "-------------------------------------------------"
		LOG red "WARNING: Found ${totcount} potential Axon BT Device(s)"
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "WARNING: Found %s potential Axon BT Device(s).\n" "${totcount}" >> "$REPORT_DETECT_FILE"
		LOG " "
		# Record each BT Axon device found
		for mac in "${!BT_AXONCAMS[@]}"; do
			name="${BT_AXONCAMS[$mac]}"
			printf "Potential Axon Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; fi
			LOG red "Potential Axon Device:\nBT Name: $name\nBT MAC: $mac"
			detections=$((detections + 1))
			total_detected=$((total_detected + 1))
			if [[ "$curcount" -lt "$totcount" ]] ; then
				LOG " "
			fi
			curcount=$((curcount + 1))
		done
		LOG red "-------------------------------------------------"
	else 
		LOG green "No obvious Axon BT Devices detected."
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "No obvious Axon BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
	fi
}

# ccskimmr warn
warn_bt_ccskimmr() {
	if [[ ${#BT_CCSKIMMR[@]} -gt 0 ]]; then
		curcount=1; totcount="${#BT_CCSKIMMR[@]}"
		LOG red "-------------------------------------------------"
		LOG red "WARNING: Found ${totcount} potential CC Skimmer BT Device(s)"
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "WARNING: Found %s potential CC Skimmer BT Device(s).\n" "${totcount}" >> "$REPORT_DETECT_FILE"
		LOG " "
		# Record each BT CC Skimmer device found
		for mac in "${!BT_CCSKIMMR[@]}"; do
			name="${BT_CCSKIMMR[$mac]}"
			printf "Potential CC Skimmer Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; fi
			LOG red "Potential CC Skimmer Device:\nBT Name: $name\nBT MAC: $mac"
			detections=$((detections + 1))
			total_detected=$((total_detected + 1))
			if [[ "$curcount" -lt "$totcount" ]] ; then
				LOG " "
			fi
			curcount=$((curcount + 1))
		done
		LOG red "-------------------------------------------------"
	else 
		LOG green "No obvious CC Skimmer BT Devices detected."
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "No obvious CC Skimmer BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
	fi
}

# flipper warn
warn_bt_flippers() {
	if [[ ${#BT_FLIPPERS[@]} -gt 0 ]]; then
		curcount=1; totcount="${#BT_FLIPPERS[@]}"
		LOG red "-------------------------------------------------"
		LOG red "WARNING: Found ${totcount} potential Flipper BT Device(s)"
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "WARNING: Found %s potential Flipper BT Device(s).\n" "${totcount}" >> "$REPORT_DETECT_FILE"
		LOG " "
		# Record each BT Flipper device found
		for mac in "${!BT_FLIPPERS[@]}"; do
			name="${BT_FLIPPERS[$mac]}"
			printf "Potential Flipper Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; fi
			LOG red "Potential Flipper Device:\nBT Name: $name\nBT MAC: $mac"
			detections=$((detections + 1))
			total_detected=$((total_detected + 1))
			if [[ "$curcount" -lt "$totcount" ]] ; then
				LOG " "
			fi
			curcount=$((curcount + 1))
		done
		LOG red "-------------------------------------------------"
	else 
		LOG green "No obvious Flipper BT Devices detected."
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "No obvious Flipper BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
	fi
}

# flockcam warn
warn_bt_flockcam() {
	if [[ ${#BT_FLOCKCAM[@]} -gt 0 ]]; then
		curcount=1; totcount="${#BT_FLOCKCAM[@]}"
		LOG red "-------------------------------------------------"
		LOG red "WARNING: Found ${totcount} potential Flock BT Device(s)"
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "WARNING: Found %s potential Flock BT Device(s).\n" "${totcount}" >> "$REPORT_DETECT_FILE"
		LOG " "
		# Record each BT Flock device found
		for mac in "${!BT_FLOCKCAM[@]}"; do
			name="${BT_FLOCKCAM[$mac]}"
			printf "Potential Flock Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; fi
			LOG red "Potential Flock Device:\nBT Name: $name\nBT MAC: $mac"
			detections=$((detections + 1))
			total_detected=$((total_detected + 1))
			if [[ "$curcount" -lt "$totcount" ]] ; then
				LOG " "
			fi
			curcount=$((curcount + 1))
		done
		LOG red "-------------------------------------------------"
	else 
		LOG green "No obvious Flock BT Devices detected."
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "No obvious Flock BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
	fi
}

# meshtastic warn
warn_bt_meshtast() {
	if [[ ${#BT_MESHTAST[@]} -gt 0 ]]; then
		curcount=1; totcount="${#BT_MESHTAST[@]}"
		LOG red "-------------------------------------------------"
		LOG red "WARNING: Found ${totcount} potential Meshtastic BT Device(s)"
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "WARNING: Found %s potential Meshtastic BT Device(s).\n" "${totcount}" >> "$REPORT_DETECT_FILE"
		LOG " "
		# Record each BT Meshtastic device found
		for mac in "${!BT_MESHTAST[@]}"; do
			name="${BT_MESHTAST[$mac]}"
			printf "Potential Meshtastic Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; fi
			LOG red "Potential Meshtastic Device:\nBT Name: $name\nBT MAC: $mac"
			detections=$((detections + 1))
			total_detected=$((total_detected + 1))
			if [[ "$curcount" -lt "$totcount" ]] ; then
				LOG " "
			fi
			curcount=$((curcount + 1))
		done
		LOG red "-------------------------------------------------"
	else 
		LOG green "No obvious Meshtastic BT Devices detected."
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "No obvious Meshtastic BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
	fi
}


# usbkill warn
warn_bt_usbkills() {
	if [[ ${#BT_USBKILLS[@]} -gt 0 ]]; then
		curcount=1; totcount="${#BT_USBKILLS[@]}"
		LOG red "-------------------------------------------------"
		LOG red "WARNING: Found ${totcount} potential USB Kill BT Device(s)"
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "WARNING: Found %s potential USB Kill BT Device(s).\n" "${totcount}" >> "$REPORT_DETECT_FILE"
		LOG " "
		# Record each USB Kill device found
		for mac in "${!BT_USBKILLS[@]}"; do
			name="${BT_USBKILLS[$mac]}"
			printf "Potential USB Kill Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; fi
			LOG red "Potential USB Kill Device:\nBT Name: $name\nBT MAC: $mac"
			detections=$((detections + 1))
			total_detected=$((total_detected + 1))
			if [[ "$curcount" -lt "$totcount" ]] ; then
				LOG " "
			fi
			curcount=$((curcount + 1))
		done
		LOG red "-------------------------------------------------"
	else 
		LOG green "No obvious USB Kill BT Devices detected."
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "No obvious USB Kill BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
	fi
}

# custom warn
warn_bt_customou() {
	if [[ ${#BT_CUSTOMOU[@]} -gt 0 ]]; then
		curcount=1; totcount="${#BT_CUSTOMOU[@]}"
		LOG red "-------------------------------------------------"
		LOG red "WARNING: Matched ${totcount} BT Device(s) with Custom Detection"
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "WARNING: Matched %s BT Device(s) with Custom Detection.\n" "${totcount}" >> "$REPORT_DETECT_FILE"
		LOG " "
		# Record each BT Matched device found
		for mac in "${!BT_CUSTOMOU[@]}"; do
			name="${BT_CUSTOMOU[$mac]}"
			printf "Detected Device:\nBT Name: %s\nBT MAC: %s\n" "${name}" "${mac}" >> "$REPORT_DETECT_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then mac="${mac:0:2}:░░:░░:░░:░░:░░"; name="$priv_name_txt"; fi
			LOG red "Detected Device:\nBT Name: $name\nBT MAC: $mac"
			detections=$((detections + 1))
			total_detected=$((total_detected + 1))
			if [[ "$curcount" -lt "$totcount" ]] ; then
				LOG " "
			fi
			curcount=$((curcount + 1))
		done
		LOG red "-------------------------------------------------"
	else 
		LOG green "No Matched BT Devices detected."
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "No Matched BT Devices detected.\n" >> "$REPORT_DETECT_FILE"
	fi
}

scan_detect_from_scanned() {
	local total_BT_AXONCAMS=0
	local total_BT_CCSKIMMR=0
	local total_BT_FLIPPERS=0
	local total_BT_FLOCKCAM=0
	local total_BT_MESHTAST=0
	local total_BT_USBKILLS=0
	local total_BT_PINEAPPS=0
	local total_BT_CUSTOMOU=0
	local total_found_scans=0
	local total_found_saved=0
	local totalmin=0
	local runtime=0
	local totalruntime=0
	
	if [[ "$scan_custom" -eq 1 ]] ; then
		resp=$(CONFIRMATION_DIALOG "Confirm Detect ALL on Custom OUI/Name - Scanned/Saved ${text_target_UC}s?")
	else
		resp=$(CONFIRMATION_DIALOG "Confirm Detect ALL - Scanned/Saved ${text_target_UC}s?")
	fi
	
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		start=$SECONDS
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		REPORT_DETECT_FILE="$LOOT_DETECT/DetectTargets_${TIMESTAMP}.txt"
	
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
		if [[ "$scan_custom" -eq 1 ]] ; then
			printf "  Detect Custom OUI/Name - Scanned/Saved Targets - Report\n" >> "$REPORT_DETECT_FILE"
			if [[ -n "$custom_oui" ]] ; then
				printf "  Custom OUI: %s - Report\n" "${custom_oui}" >> "$REPORT_DETECT_FILE"
			fi
			if [[ -n "$custom_name" ]] ; then
				printf "  Custom Name: %s - Report\n" "${custom_name}" >> "$REPORT_DETECT_FILE"
			fi
		else
			printf "  Detect ALL - Scanned/Saved Targets - Report\n" >> "$REPORT_DETECT_FILE"
		fi
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_DETECT_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
		printf "%s - EVENT: Start detect\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_DETECT_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
		if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		
		detections=0
		BT_AXONCAMS=()
		BT_CCSKIMMR=()
		BT_FLIPPERS=()
		BT_FLOCKCAM=()
		BT_MESHTAST=()
		BT_USBKILLS=()
		BT_PINEAPPS=()
		BT_CUSTOMOU=()
		
		if [[ "$scan_custom" -eq 1 ]] ; then
			LOG green "Detect Custom OUI/Name - Scanned/Saved ${text_target_UC}s..."
			printf "Detect Custom OUI/Name - Scanned/Saved Targets...\n" >> "$REPORT_DETECT_FILE"
			
			LOG blue "================================================="
			if [[ -n "$custom_oui" ]] ; then
				printf "OUI: %s\n" "${custom_oui}" >> "$REPORT_DETECT_FILE"
				if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$custom_oui"; custom_oui="${custom_oui:0:2}:░░:░░"; fi
				LOG cyan "OUI: ${custom_oui}"
				if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; fi
			else
				LOG "Custom OUI not set..."
			fi
			if [[ -n "$custom_name" ]] ; then
				printf "Name: %s\n" "${custom_name}" >> "$REPORT_DETECT_FILE"
				if [[ "$scan_privacy" -eq 1 ]] ; then priv_name_save="$custom_name"; custom_name="$priv_name_txt"; fi
				LOG cyan "Name: ${custom_name}"
				if [[ "$scan_privacy" -eq 1 ]] ; then custom_name="$priv_name_save"; fi
			else
				LOG "Custom Name not set..."
			fi
			LOG blue "================================================="
		else
			LOG green "Detect ALL from Scanned/Saved ${text_target_UC}s..."
			printf "Detect ALL from Scanned/Saved Targets...\n" >> "$REPORT_DETECT_FILE"
		fi
		LOG " "
		# Enable case-insensitive matching
		shopt -s nocasematch
		if [[ "$scan_stealth" -eq 0 ]] ; then DO_A_BARREL_ROLL; fi
		# if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE SLOW; fi
		if [[ "${#BT_TARGETS[@]}" -gt 0 ]] ; then
			startScan=$SECONDS
			LOG "Scanning ${#BT_TARGETS[@]} scanned ${text_target_UC}s, please wait..."
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			printf "%s - EVENT: Start Scanning scanned Targets\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_DETECT_FILE"
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			printf "Scanning %s scanned Targets, please wait...\n" "${#BT_TARGETS[@]}" >> "$REPORT_DETECT_FILE"
			if [[ "$archCur" == "pager" ]] ; then
				if [[ "${#BT_TARGETS[@]}" -gt "$savedTargWarn" ]] ; then
					LOG magenta "====================================== WARNING =="
					LOG red     "Scanned ${text_target_UC}s count is greater than ${savedTargWarn}!"
					LOG red     "Extra time needed to scan for ALL Detections!"
					if [[ "$scan_custom" -eq 1 ]] ; then
						LOG red     "Approx. 90s for 1500 ${text_target_LC}s"
					else
						LOG red     "Approx. 3 min for 1500 ${text_target_LC}s"
					fi
					LOG magenta "====================================== WARNING =="
					printf "WARNING: Scanned Targets count is greater than %s!\n" "${savedTargWarn}" >> "$REPORT_DETECT_FILE"
					printf "Extra time needed to scan for ALL Detections!\n" >> "$REPORT_DETECT_FILE"
				fi
			fi
			LOG " "
			for mac in "${!BT_TARGETS[@]}"; do
				targetlist_name="${BT_NAMES[$mac]}"
				if [[ -z "$targetlist_name" ]] ; then
					targetlist_name="${BT_TARGETS[$mac]}"
				fi
				targetlist_comp="${BT_COMPS[$mac]}"
				if [[ "$targetlist_comp" == "n/a" ]] ; then
					targetlist_comp=""
				else
					if [[ -z "$targetlist_name" || "$targetlist_name" == "Unknown" ]] ; then
						targetlist_name="$targetlist_comp"
						targetlist_comp=""
					else
						if [[ -n "$targetlist_comp" ]] ; then
							targetlist_comp="/$targetlist_comp"
						fi
					fi
				fi
				NEW_TARGET_MAC_NAME="${targetlist_name}${targetlist_comp}"
				if [[ -z "$NEW_TARGET_MAC_NAME" ]] ; then
					NEW_TARGET_MAC_NAME="Unknown"
				fi
				if [[ "$scan_custom" -eq 1 ]] ; then
					# LOG green "CHECKING..."
					check_bt_customou "$mac" "$NEW_TARGET_MAC_NAME"
				else
					check_bt_axoncams "$mac" "$NEW_TARGET_MAC_NAME"
					check_bt_ccskimmr "$mac" "$NEW_TARGET_MAC_NAME"
					check_bt_flippers "$mac" "$NEW_TARGET_MAC_NAME"
					check_bt_flockcam "$mac" "$NEW_TARGET_MAC_NAME"
					check_bt_meshtast "$mac" "$NEW_TARGET_MAC_NAME"
					check_bt_usbkills "$mac" "$NEW_TARGET_MAC_NAME"
					check_bt_pineapps "$mac" "$NEW_TARGET_MAC_NAME"
				fi
			done
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			printf "%s - EVENT: Complete Scanning scanned Targets\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_DETECT_FILE"
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			LOG green "Completed scanning scanned ${text_target_UC}s."
			printf "Completed scanning scanned Targets.\n" >> "$REPORT_DETECT_FILE"
			runtime=$((SECONDS-startScan))
			if [[ "$runtime" -gt 60 ]] ; then
				minutes=$((runtime/60)); secs=$((runtime%60))
				LOG "Time to scan ${#BT_TARGETS[@]} scanned ${text_target_UC}(s): ${minutes}min ${secs}s"
			else
				LOG "Time to scan ${#BT_TARGETS[@]} scanned ${text_target_UC}(s): ${runtime}s"
			fi
			total_BT_AXONCAMS=${#BT_AXONCAMS[@]}
			total_BT_CCSKIMMR=${#BT_CCSKIMMR[@]}
			total_BT_FLIPPERS=${#BT_FLIPPERS[@]}
			total_BT_FLOCKCAM=${#BT_FLOCKCAM[@]}
			total_BT_MESHTAST=${#BT_MESHTAST[@]}
			total_BT_USBKILLS=${#BT_USBKILLS[@]}
			total_BT_PINEAPPS=${#BT_PINEAPPS[@]}
			total_BT_CUSTOMOU=${#BT_CUSTOMOU[@]}

			total_found_scans=$((total_BT_AXONCAMS + total_BT_CCSKIMMR + total_BT_FLIPPERS + total_BT_FLOCKCAM + total_BT_MESHTAST + total_BT_USBKILLS + total_BT_PINEAPPS + total_BT_CUSTOMOU))
			if [[ "$total_found_scans" -gt 0 ]] ; then
				LOG red "Found ${total_found_scans} suspect scanned ${text_target_LC}(s)..."
				printf "Found %s suspect scanned Target(s)...\n" "${total_found_scans}" >> "$REPORT_DETECT_FILE"
			else
				LOG "No suspect scanned ${text_target_LC}s found!"
				printf "No suspect scanned Targets found!\n" >> "$REPORT_DETECT_FILE"
			fi
			LOG blue "================================================="
			# set scan values
			total_scans=$((total_scans + 1))
			PAYLOAD_SET_CONFIG bluepinesuite total_scans "$total_scans"
		else
			LOG red "No Scanned ${text_target_UC}s available yet."
			printf "No Scanned Targets available yet.\n" >> "$REPORT_DETECT_FILE"
		fi
		LOG " "
		
		# reset totals for checking where results found
		total_BT_AXONCAMS=0
		total_BT_CCSKIMMR=0
		total_BT_FLIPPERS=0
		total_BT_FLOCKCAM=0
		total_BT_MESHTAST=0
		total_BT_USBKILLS=0
		total_BT_PINEAPPS=0
		total_BT_CUSTOMOU=0
		
		if [[ -s "$SAVEDTARGETS_FILE" ]]; then
			startScan=$SECONDS
			linecount=$(grep -c '.' "$SAVEDTARGETS_FILE")
			LOG "Scanning ${linecount} Saved ${text_target_UC}s, please wait..."
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			printf "%s - EVENT: Start Scanning Saved Targets\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_DETECT_FILE"
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			printf "Scanning %s Saved Targets, please wait...\n" "${linecount}" >> "$REPORT_DETECT_FILE"
			if [[ "$archCur" == "pager" ]] ; then
				if [[ "$linecount" -gt "$savedTargWarn" ]] ; then
					LOG magenta "====================================== WARNING =="
					LOG red     "Saved ${text_target_UC}s count is greater than ${savedTargWarn}!"
					LOG red     "Extra time needed to scan for ALL Detections!"
					if [[ "$scan_custom" -eq 1 ]] ; then
						LOG red     "Approx. 90s for 1500 ${text_target_LC}s"
					else
						LOG red     "Approx. 3 min for 1500 ${text_target_LC}s"
					fi
					LOG magenta "====================================== WARNING =="
					printf "WARNING: Saved Targets count is greater than %s!\n" "${savedTargWarn}" >> "$REPORT_DETECT_FILE"
					printf "Extra time needed to scan for ALL Detections!\n" >> "$REPORT_DETECT_FILE"
				fi
			fi
			LOG " "
			while IFS=' ' read -r key name; do
				if mac=$(echo "${key}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}'); then
					# BT_TARGETS_SAVED[$mac]="$name"
					# LOG green "adding mac to BT_TARGETS_SAVED: ${mac}"
					if [[ "$scan_custom" -eq 1 ]] ; then
						# LOG green "CHECKING..."
						check_bt_customou "$mac" "$name"
					else
						check_bt_axoncams "$mac" "$name"
						check_bt_ccskimmr "$mac" "$name"
						check_bt_flippers "$mac" "$name"
						check_bt_flockcam "$mac" "$name"
						check_bt_meshtast "$mac" "$name"
						check_bt_usbkills "$mac" "$name"
						check_bt_pineapps "$mac" "$name"
					fi
				fi
			done < "$SAVEDTARGETS_FILE"
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			printf "%s - EVENT: Complete Scanning Saved Targets\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_DETECT_FILE"
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			LOG green "Completed scanning Saved ${text_target_UC}s."
			printf "Completed scanning Saved Targets.\n" >> "$REPORT_DETECT_FILE"
			runtime=$((SECONDS-startScan))
			if [[ "$runtime" -gt 60 ]] ; then
				minutes=$((runtime/60)); secs=$((runtime%60))
				LOG "Time to scan ${linecount} Saved ${text_target_UC}s: ${minutes}min ${secs}s"
			else
				LOG "Time to scan ${linecount} Saved ${text_target_UC}s: ${runtime}s"
			fi
			total_BT_AXONCAMS=${#BT_AXONCAMS[@]}
			total_BT_CCSKIMMR=${#BT_CCSKIMMR[@]}
			total_BT_FLIPPERS=${#BT_FLIPPERS[@]}
			total_BT_FLOCKCAM=${#BT_FLOCKCAM[@]}
			total_BT_MESHTAST=${#BT_MESHTAST[@]}
			total_BT_USBKILLS=${#BT_USBKILLS[@]}
			total_BT_PINEAPPS=${#BT_PINEAPPS[@]}
			total_BT_CUSTOMOU=${#BT_CUSTOMOU[@]}

			total_found_saved=$((total_BT_AXONCAMS + total_BT_CCSKIMMR + total_BT_FLIPPERS + total_BT_FLOCKCAM + total_BT_MESHTAST + total_BT_USBKILLS + total_BT_PINEAPPS + total_BT_CUSTOMOU))
			if [[ "$total_found_saved" -gt 0 ]] ; then
				LOG red "Found ${total_found_saved} suspect Saved ${text_target_LC}(s)..."
				printf "Found %s suspect Saved Target(s)...\n" "${total_found_saved}" >> "$REPORT_DETECT_FILE"
			else
				LOG "No suspect Saved ${text_target_LC}s found!"
				printf "No suspect Saved Targets found!\n" >> "$REPORT_DETECT_FILE"
			fi
			LOG blue "================================================="
			# set scan values
			total_scans=$((total_scans + 1))
			PAYLOAD_SET_CONFIG bluepinesuite total_scans "$total_scans"
		else
			LOG red "No Saved ${text_target_UC}s available yet."
			printf "No Saved Targets available yet.\n" >> "$REPORT_DETECT_FILE"
		fi
		# Disable case-insensitive matching to restore default behavior
		shopt -u nocasematch
		LOG " "
		
		runtime=$((SECONDS-start))
		totalruntime=$((totalruntime+runtime))
		if [[ "$totalruntime" -gt 60 ]] ; then 
			totalmin=$((totalruntime/60)); secs=$((totalruntime%60))
			if [[ "$secs" -gt 34 ]] ; then totalmin=$((totalmin+1)); fi
		else
			if [[ "$totalruntime" -gt 34 ]] ; then totalmin=1; fi
		fi
		# set scan values 
		total_scan_min=$((total_scan_min + totalmin))
		PAYLOAD_SET_CONFIG bluepinesuite total_scan_min "$total_scan_min"
		
		if [[ "$total_found_scans" -gt 0 ]] ; then
			LOG "$total_found_scans Suspect(s) found in Scanned ${text_target_UC}s list!"
			printf "%s Suspect(s) found in Scanned Targets list!\n" "${total_found_scans}" >> "$REPORT_DETECT_FILE"
		fi
		if [[ "$total_found_saved" -gt 0 ]] ; then
			LOG "$total_found_saved Suspect(s) found in Saved ${text_target_UC}s list!"
			printf "%s Suspect(s) found in Saved Targets list!\n" "${total_found_saved}" >> "$REPORT_DETECT_FILE"
		fi
		if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		if [[ "$total_found_scans" -gt 0 || "$total_found_saved" -gt 0 ]] ; then
			LOG " "
		fi
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		
		if [[ "$scan_custom" -eq 1 ]] ; then
			# LOG green "CHECKING..."
			warn_bt_customou
			LOG " "
			sleep 0.25
		else
			warn_bt_axoncams
			LOG " "
			sleep 0.25
			warn_bt_ccskimmr
			LOG " "
			sleep 0.25
			warn_bt_flippers
			LOG " "
			sleep 0.25
			warn_bt_flockcam
			LOG " "
			sleep 0.25
			warn_bt_meshtast
			LOG " "
			sleep 0.25
			warn_bt_usbkills
			LOG " "
			sleep 0.25
			warn_bt_pineapps
			LOG " "
			sleep 0.25
		fi
		printf "\n" >> "$REPORT_DETECT_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
		printf "%s - EVENT: Complete detect\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_DETECT_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETECT_FILE"
			
		# finished
		if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		
		if [[ "$scan_custom" -eq 1 ]] ; then
			LOG green "Detect Custom OUI/Name Completed!"
			printf "Detect Custom OUI/Name - Scanned/Saved Targets Completed!\n" >> "$REPORT_DETECT_FILE"
		else
			LOG green "Detect ALL - Scanned/Saved ${text_target_UC}s Completed!"
			printf "Detect ALL from Scanned/Saved Targets Completed!\n" >> "$REPORT_DETECT_FILE"
		fi
		
		if [[ ${detections} -gt 0 ]]; then
			if [[ "$scan_mute" == "false" ]] ; then
				RINGTONE "warning"
			fi
			if [[ "$scan_stealth" -eq 0 ]] ; then LED RED SLOW; fi
			LOG red "$detections unique malicious suspects found!"
			printf "%s unique malicious suspects found!\n" "${detections}" >> "$REPORT_DETECT_FILE"
		else
			if [[ "$scan_mute" == "false" ]] ; then
				RINGTONE "ScaleTrill"
			fi
			LOG green "No malicious suspects found!"
			printf "No malicious suspects found!\n" >> "$REPORT_DETECT_FILE"
		fi
		# set scan values
		PAYLOAD_SET_CONFIG bluepinesuite total_detected "$total_detected"
			
		LOG " "
		printf "\n" >> "$REPORT_DETECT_FILE"
		# LOG cyan "Results saved to: ${REPORT_DETECT_FILE}"
		printf "Results saved to: %s" "${REPORT_DETECT_FILE}" >> "$REPORT_DETECT_FILE"
		
		LOG green "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
	else
		if [[ "$scan_custom" -eq 1 ]] ; then
			LOG "Skipped Detect Custom OUI/Name from Scanned + Saved ${text_target_UC}s."
		else
			LOG "Skipped Detect ALL from Scanned + Saved ${text_target_UC}s."
		fi
	fi
}


# detect jammers
detect_jammers() {
	# LOG "detect_jammers"
	reset_gpsd
	
	# possible cleanup from last run
	rm "$KEYCKTMP_FILE" 2>/dev/null
	if [[ "$archCur" == "pager" ]] ; then killall evtest 2>/dev/null; fi
	
	# set on each total run
	cancel_app=0
	gpspos_last=""
	
	# name to be used for device to be pinged
	local temp_devname="Apple"
	# adapter_base decides which adapter is the one doing the pinging
	# the other adapter will receive the request and reply back
	local adapter_base="hci0"

	local maxJams=5
	local maxNoJams=25
	local showruntimeNS=0
	local nsCheck=3050000

	local jams=0
	local nojamcount=0
	local nojamstreak=0
	local seqJams=0
	local jamLast=0
	local jammerDet=0
	local jamConf=0
	local nojamstreak_hold=0
	local jamLast_hold=0
	local totalruntime=0
	local runnum=0
	local running=0
	local cancelJamRun=0
	local checkStrict=0

	local adapterdown=0
	local hci0_status=""
	local hci0_MAC=""
	local hci0_NAME=""
	local hci0_NAMEold=""
	local hci1_status=""
	local hci1_MAC=""
	local hci1_NAME=""
	local hci1_NAMEold=""
	local pinged_device=""
	
	local status_display=""
	local jams_display=""
	local jammerDet_display=""
	local nojamstreak_display=""
	local totalruntime_display=""

	# check pause/cancel
	check_cancel_jam() {
		# LOG "checking pause/cancel"
		# load content of file into string, then check string vs match
		# local FILE_CONTENT=$(<"$KEYCKTMP_FILE")
		
		# confirm cancel is pressed
		# if grep -Eq "\\(BTN_EAST\\), value 1" "$KEYCKTMP_FILE"; then
		if [[ -s "$KEYCKTMP_FILE" ]] && grep -q "(BTN_EAST), value 1" "$KEYCKTMP_FILE"; then
			# LOG "found"
			if [[ "$archCur" == "pager" ]] ; then killall evtest 2>/dev/null; fi
			# empty file
			:> "$KEYCKTMP_FILE"
			cancel_app=1
			# if cancel_press=1 then prompt asking if they actually want to cancel.
			LOG blue "--------------------------------------------------"
			LOG "Stopping..."
			LOG "Stopping..."
			LOG "Stopping..."
			LOG blue "--------------------------------------------------"
			trap cleanup SIGINT
			sleep 0.5
		else
			# LOG "not found, empty file"
			# empty file
			:> "$KEYCKTMP_FILE"
		fi
	}

	updatebtdevname() {
		hci0_MAC=$(hciconfig hci0 | grep 'BD Address' | awk '{print $3}' 2>/dev/null)
		hci1_MAC=$(hciconfig hci1 | grep 'BD Address' | awk '{print $3}' 2>/dev/null)

		# change name for discoverable mac
		if [[ "$adapter_base" == "hci1" ]] ; then
			# LOG "hci0_MAC: $hci0_MAC"
			# LOG "hci0_NAME: $hci0_NAME"
			hci0_NAMEold="$hci0_NAME"
			# LOG "old hci0_NAMEold: $hci0_NAMEold"
			LOG cyan "--------- Updating Bluetooth device name --------"
			LOG "From: '$hci0_NAMEold'"
			LOG "To: '$temp_devname'"
			LOG "--- name will be returned back after scanning ---"
			bluetoothctl <<-EOF >/dev/null 2>&1
			select $hci0_MAC
			system-alias "$temp_devname"
			quit
			EOF
			sleep 0.5
			rm ".bluetoothctl_history" 2>/dev/null
			hci0_NAME=$(hciconfig -a hci0 | grep "Name:" | awk -F"'" '{print $2}')
			# LOG "new hci0_NAME: $hci0_NAME"
		else
			# LOG "hci1_MAC: $hci1_MAC"
			# LOG "hci1_NAME: $hci1_NAME"
			hci1_NAMEold="$hci1_NAME"
			# LOG "old hci1_NAMEold: $hci1_NAMEold"
			LOG cyan "--------- Updating Bluetooth device name --------"
			LOG "From: '$hci1_NAMEold'"
			LOG "To: '$temp_devname'"
			LOG "--- name will be returned back after scanning ---"
			bluetoothctl <<-EOF >/dev/null 2>&1
			select $hci1_MAC
			system-alias "$temp_devname"
			quit
			EOF
			sleep 0.5
			rm ".bluetoothctl_history" 2>/dev/null
			hci1_NAME=$(hciconfig -a hci1 | grep "Name:" | awk -F"'" '{print $2}')
			# LOG "new hci1_NAME: $hci1_NAME"
		fi
	}


	hci_check_status() {
		adapterdown=0
		local discov="OFF"
		
		if [[ "$adapter_base" == "hci1" ]] ; then
			hci0_output=$(hciconfig -a hci0 2>&1)
			sleep 1
			hci1_output=$(hciconfig -a hci1 2>&1)
		else
			hci1_output=$(hciconfig -a hci1 2>&1)
			sleep 1
			hci0_output=$(hciconfig -a hci0 2>&1)
		fi
		# hci0_status=$(hciconfig hci0 |& awk 'NR==3 {print $1}')
		hci0_status=$(echo "$hci0_output" | awk 'NR==3 {print $1}')
		# grab next line if possible failure
		if [[ "$hci0_status" != "UP" ]] ; then
			hci0_status=$(echo "$hci0_output" | awk 'NR==4 {print $1}')
		fi
		hci0_NAME=$(echo "$hci0_output" | grep "Name:" | awk -F"'" '{print $2}' 2>/dev/null)
		
		# hci1_status=$(hciconfig hci1 |& awk 'NR==3 {print $1}')
		hci1_status=$(echo "$hci1_output" | awk 'NR==3 {print $1}')
		# grab next line if possible failure
		if [[ "$hci1_status" != "UP" ]] ; then
			hci1_status=$(echo "$hci1_output" | awk 'NR==4 {print $1}')
		fi
		hci1_NAME=$(echo "$hci1_output" | grep "Name:" | awk -F"'" '{print $2}' 2>/dev/null)
		
		if [[ "$adapter_base" == "hci1" ]] ; then
			if echo "$hci0_output" | grep -q "PSCAN ISCAN"; then discov="ON"; fi
		else
			if echo "$hci1_output" | grep -q "PSCAN ISCAN"; then discov="ON"; fi
		fi
		if [[ "$discov" != "ON" || "$hci1_status" != "UP" || "$hci0_status" != "UP" ]] ; then
			# LOG "Working magic, adapter not discoverable or up..."
			adapterdown=1
			# printf "  hci0_output: %s\n\n" "${hci0_output}" >> "$REPORT_DETJAM_FILE"
			# printf "  hci1_output: %s\n\n" "${hci1_output}" >> "$REPORT_DETJAM_FILE"
		else
			if [[ "$running" -eq 0 || "$checkStrict" -eq 1 ]] ; then
				if echo "$hci1_output" |& grep -q "read local name on hci1: I/O error"; then
					# LOG "hci1 down"
					adapterdown=1
				fi
				if echo "$hci0_output" |& grep -q "read local name on hci0: I/O error"; then
					# LOG "hci0 down"
					adapterdown=1
				fi
			fi
		fi
	}

	bring_adapters_up() {
		if [[ "$scan_stealth" -eq 0 ]] ; then LED WHITE; fi
		LOG blue "--------------------------------------------------"
		if [[ "$running" -eq 0 ]] ; then
			LOG "Preparing Bluetooth Adapters"
			# LOG "Trying to Bring down Adapters"
			hciconfig hci0 down 2>/dev/null
			sleep 1.5
			hciconfig hci1 down 2>/dev/null
			sleep 1.5
			LOG "Please wait..."
			service $servicebt_cur restart 2>/dev/null
			sleep 2
			# LOG "Trying to Bring up Adapters"
		else
			LOG "Resetting Bluetooth status"
		fi
		if [[ "$adapter_base" == "hci1" ]] ; then
			hciconfig hci0 up piscan 2>/dev/null
			sleep 1.5
			hciconfig hci1 up noscan 2>/dev/null
			sleep 1.5
		else
			hciconfig hci0 up noscan 2>/dev/null
			sleep 1.5
			hciconfig hci1 up piscan 2>/dev/null
			sleep 1.5
		fi
		LOG "Verifying Adapters status"

		loop=0
		while true; do
			# LOG red "in loop"
			loop=$((loop + 1))
			# check both adapters are up and online
			hci_check_status
			if [[ "$adapterdown" -eq 1 ]]; then
				if [[ "$loop" -gt 1 ]] ; then
					LOG red "RESET FAILED! Trying to reset again."
				fi
				LOG "Trying to Stop Blueooth"
				service $servicebt_cur stop 2>/dev/null
				sleep 2
				LOG "Trying to Remove Bluetooth"
				rmmod btusb 2>/dev/null
				sleep 2
				LOG "Trying to Enable Bluetooth"
				modprobe btusb 2>/dev/null
				sleep 2
				LOG "Trying to Start Blueooth"
				service $servicebt_cur start 2>/dev/null
				sleep 2
				LOG "Trying to Bring up Adapters"
				if [[ "$adapter_base" == "hci1" ]] ; then
					hciconfig hci0 up piscan 2>/dev/null
					sleep 1.5
					hciconfig hci1 up noscan 2>/dev/null
					sleep 1.5
				else
					hciconfig hci0 up noscan 2>/dev/null
					sleep 1.5
					hciconfig hci1 up piscan 2>/dev/null
					sleep 1.5
				fi
				if [[ "$running" -eq 1 ]] ; then
					totalruntime=$((totalruntime+11))			
				fi		
				if [[ "$loop" -eq 5 ]] ; then
					LOG red "BLUETOOTH ADAPTER ERROR!"
					LOG "Adapter(s) could not be brought back up with software!"
					LOG " "
					LOG "Hardware Reset Required! Unplug and replug USB!"
					LOG " "
					LOG red "USB BT Adapter could also be missing?"
					LOG " "
					# exit 1
					cancel_app=1
					cancelJamRun=1
					break
				fi
			else
				LOG green "Bluetooth Adapters are ready!"
				break
			fi
		done
		LOG blue "--------------------------------------------------"
		# hide line on table
		jamConf=1
		if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE SLOW; fi
	}
	
	length_display() {
		local length=0
		local max_value=0
		local mins=0
		local secs=0
		length=${#nojamstreak}
		nojamstreak_display="$nojamstreak"
		if [[ "$length" -lt 11 ]] ; then
			max_value=$((11-length))
			nojamstreak_display+=" "
			for (( i = 0; i < max_value; i++ ))
			do
				nojamstreak_display+="¨"
			done
		fi
		length=${#jammerDet}
		jammerDet_display="$jammerDet"
		if [[ "$length" -lt 6 ]] ; then
			max_value=$((6-length))
			jammerDet_display+=" "
			for (( i = 0; i < max_value; i++ ))
			do
				jammerDet_display+="¨"
			done
		fi
		if [[ "$totalruntime" -gt 60 ]] ; then
			mins=$((totalruntime/60)); secs=$((totalruntime%60))
			if [[ "$mins" -gt 9 ]] ; then
				totalruntime_display="${mins}min"
			else
				totalruntime_display="${mins}min ${secs}s"
			fi
		else
			totalruntime_display="${totalruntime}s"
		fi
		jams_display=" $jams ¨¨¨"
	}
	
	resp=$(CONFIRMATION_DIALOG "Confirm Jammer Detection?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		if [[ "$scan_stealth" -eq 0 ]] ; then LED WHITE; fi
	
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		REPORT_DETJAM_FILE="$LOOT_DETECT/Report_Jam_${TIMESTAMP}.txt"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETJAM_FILE"
		printf "  Bluetooth Jammer Detector Scan\n" >> "$REPORT_DETJAM_FILE"
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_DETJAM_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_DETJAM_FILE"
		printf "%s - EVENT: Prepare BT Adapters\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_DETJAM_FILE"
		
		LOG blue "================================================="
		LOG cyan "======== Bluetooth Jammer Detector Scan ========="
		LOG blue "================================================="
		
		LOG "Loading..."

		# check both adapters are up and online
		hci_check_status
		if [[ "$adapterdown" -eq 0 ]] ; then
			# prepare adapters
			LOG "Preparing Bluetooth Adapters"
			hciconfig hci0 down 2>/dev/null
			sleep 1.5
			hciconfig hci1 down 2>/dev/null
			sleep 1.5
			LOG "Please wait..."
			if [[ "$adapter_base" == "hci1" ]] ; then
				hciconfig hci0 up piscan 2>/dev/null
				sleep 1.5
				hciconfig hci1 up noscan 2>/dev/null
				sleep 1.5
			else
				hciconfig hci0 up noscan 2>/dev/null
				sleep 1.5
				hciconfig hci1 up piscan 2>/dev/null
				sleep 1.5
			fi
			LOG "Verifying Adapters status"
			hci_check_status
			if [[ "$adapterdown" -eq 0 ]] ; then
				updatebtdevname
				LOG blue "--------------------------------------------------"
				LOG green "----------------- Ready to Rock! -----------------"
			else
				# Adapters down, try to bring back up
				bring_adapters_up
				updatebtdevname
				LOG blue "--------------------------------------------------"
				LOG green "----------------- Ready to Rock! -----------------"
			fi
		else
			sleep 1
			if ! hciconfig hci1 >/dev/null 2>&1; then
				resp=$(CONFIRMATION_DIALOG "USB Bluetooth / hci1 NOT FOUND!
				
Are you sure you have a USB Bluetooth Adapter plugged in and want to continue having the system reset it?")
				if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					cancelJamRun=1
				fi
			fi
			sleep 0.5
			if [[ "$cancelJamRun" -eq 0 ]] ; then
				# adapters down, try to bring back up
				bring_adapters_up
				if [[ "$cancelJamRun" -eq 0 ]] ; then
					updatebtdevname
					LOG blue "--------------------------------------------------"
					LOG green "----------------- Ready to Rock! -----------------"
				fi
			fi
		fi
		
		# check if cancelled
		if [[ "$cancelJamRun" -eq 0 ]] ; then
			if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE SLOW; fi
			if [[ "$adapter_base" == "hci1" ]] ; then
				pinged_device="$hci0_MAC"
			else
				pinged_device="$hci1_MAC"
			fi
			if [[ "$archCur" != "pager" ]] ; then
				showruntimeNS=1
				nsCheck=4650000
			fi
			
			printf "════════════════════════════════════════════\n" >> "$REPORT_DETJAM_FILE"
			printf "%s - EVENT: Start scan\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_DETJAM_FILE"
			# gps check
			gpspos_cur=$(GPS_GET)
			if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
				gpspos_last="$gpspos_cur" # GPS is valid
				printf "GPS Pos.: %s\n" "${gpspos_last}" >> "$REPORT_DETJAM_FILE"
			else
				if [[ -n "$gpspos_last" ]] ; then # gps lost, last known coordinates: gpspos_last
					printf "GPS LOST! %s (Last Known Pos.)\n" "${gpspos_last}" >> "$REPORT_DETJAM_FILE"
				fi
			fi
			printf "════════════════════════════════════════════\n" >> "$REPORT_DETJAM_FILE"
			

			LOG green "------------- Begin Jammer Detection -------------"
			:> "$KEYCKTMP_FILE"
			start_evtest
			LOG blue "--------------------------------------------------"
			if [[ "$archCur" == "pager" ]] ; then
				LOG cyan "-------- Long Press or Tap OK to stop... ---------"
			else
				LOG cyan "------------ Press CANCEL to stop... -------------"
			fi
			LOG blue "--------------------------------------------------"
			
			# start detection loop
			while true; do
				running=1
				# check cancel on each run
				check_cancel_jam; if [[ "$cancel_app" -eq 1 ]]; then break; fi
				if (( runnum % 50 == 0 )) && (( runnum != 0 )); then
					if [[ "$jamConf" -eq 0 ]] ; then
						LOG blue "--------------------------------------------------"
					fi
					if [[ "$archCur" == "pager" ]] ; then
						LOG cyan "-------- Long Press or Tap OK to stop... ---------"
					else
						LOG cyan "------------ Press CANCEL to stop... -------------"
					fi
					LOG cyan "------- It may take a second to process... -------"
					if (( runnum % 12 != 0 )); then
						LOG blue "--------------------------------------------------"
					fi
				fi
				if (( runnum % 12 == 0 )); then
					# LOG "$number is divisible by XX and can be 0."
					if [[ "$jamConf" -eq 0 ]] ; then
						LOG blue "--------------------------------------------------"
					fi
					LOG cyan "Status | Jams | Found # | Clean Streak | Uptime --"
					LOG blue "--------------------------------------------------"
				fi
				start=$SECONDS; startms=$EPOCHREALTIME; startms=${startms/./}; runnum=$((runnum+1))
				jamConf=0; nojamstreak_hold=0; jamLast_hold=0; checkStrict=0
				
				# run info ping
				if timeout --signal=SIGINT "8s" hcitool -i "$adapter_base" info "$pinged_device" &>/dev/null; then
					# got result from info
					runtime=$((SECONDS-start))
					totalruntime=$((totalruntime+runtime))
					endms=$EPOCHREALTIME; endms=${endms/./}; runtimens=$((endms - startms))
					# check runtime of result
					if [[ "$runtimens" -gt "$nsCheck" && "$runnum" -gt 1 ]] ; then
						nojamstreak_hold="$nojamstreak"; jamLast_hold="$jamLast"
						jams=$((jams+1))
						jamLast=1
						jamConf=1
						nojamcount=0
						nojamstreak=0
						length_display
						runtime_display=""
						if [[ "$showruntimeNS" -eq 1 ]] ; then
							runtime_display="${runtime}s ($runtimens ns)"
						fi
						status_display="JAM! ¨ "
						LOG red "${status_display}|${jams_display}| $jammerDet_display | $nojamstreak_display | ${totalruntime_display} ${runtime_display}"
						LOG blue "--------------------------------------------------"
						if [[ "$nojamstreak_hold" -gt 100 ]] ; then
							LOG magenta "--- JAM! ---- Possible Jam DETECTED! ---- JAM! ---"
							LOG magenta "--- Likely a device hiccup! ex. CPU/Memory Lag ---"
						else
							if [[ "$jamLast_hold" -eq 1 ]] ; then
								# LOG "Sequential JAM!"
								LOG red "-- JAM! - Jam CONFIRMED! - Getting Warm! - JAM! --"
								seqJams=$((seqJams+1))
							else
								LOG magenta "--- JAM! ---- Possible Jam DETECTED! ---- JAM! ---"
							fi
						fi
						LOG blue "--------------------------------------------------"
						printf "%s - EVENT: Jam!\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_DETJAM_FILE"
						printf "Jams: %s | Found: %s | Clean Streak: %s | Uptime: %s\n" "$jams" "$jammerDet" "$nojamstreak_hold" "$totalruntime_display" >> "$REPORT_DETJAM_FILE"
					else
						# runtime good, no jam
						nojamcount=$((nojamcount+1))
						nojamstreak=$((nojamstreak+1))
						jamLast=0
						length_display
						runtime_display=""
						if [[ "$showruntimeNS" -eq 1 ]] ; then
							runtime_display="${runtime}s ($runtimens ns)"
						fi
						if [[ "$runnum" -gt 1 ]] ; then
							# status_display="Safe ¨ "
							status_display="No Jam "
						else
							status_display="Start -"
						fi
						if [[ "$nojamcount" -ge "$maxNoJams" ]] ; then
							jams_display=" RESET"
							LOG blue "${status_display}|${jams_display}| $jammerDet_display | $nojamstreak_display | ${totalruntime_display} ${runtime_display}"
						else
							LOG "${status_display}|${jams_display}| $jammerDet_display | $nojamstreak_display | ${totalruntime_display} ${runtime_display}"
						fi
					fi
					if [[ "$nojamcount" -ge "$maxNoJams" ]] ; then
						# LOG " ------------- Resetting Jams"
						nojamcount=0
						jams=0
						seqJams=0
					fi
					sleep 1
					totalruntime=$((totalruntime+1))
				else
					# got NO result from info or TIMED OUT
					runtime=$((SECONDS-start))
					totalruntime=$((totalruntime+runtime))
					endms=$EPOCHREALTIME; endms=${endms/./}; runtimens=$((endms - startms))
					sleep 1
					# check hciconfig status for both hci0 and hci1
					checkStrict=1
					hci_check_status
					# reset strict check
					checkStrict=0
					if [[ "$adapterdown" -eq 0 ]] ; then
						# LOG "Possible Jam DETECTED!"
						# LOG "Jammer Interference or Serious CPU/Memory Lag!"
						nojamstreak_hold="$nojamstreak"; jamLast_hold="$jamLast"
						jams=$((jams+1))
						jamLast=1
						jamConf=1
						nojamcount=0
						nojamstreak=0
						length_display
						runtime_display=""
						if [[ "$showruntimeNS" -eq 1 ]] ; then
							runtime_display="${runtime}s ($runtimens ns)"
						fi
						status_display="FULLJAM"
						LOG red "${status_display}|${jams_display}| $jammerDet_display | $nojamstreak_display | ${totalruntime_display} ${runtime_display}"
						LOG blue "--------------------------------------------------"
						if [[ "$nojamstreak_hold" -gt 100 ]] ; then
							LOG red "- FULLJAM! -- Possible Jam DETECTED! -- FULLJAM! -"
							LOG magenta "--- Likely a device hiccup! ex. CPU/Memory Lag ---"
						else
							if [[ "$jamLast_hold" -eq 1 ]] ; then
								# LOG "Sequential JAM!"
								LOG red "- FULLJAM! -- Jam CONFIRMED! --- Getting Warm! ---"
								seqJams=$((seqJams+1))
							else
								LOG red "- FULLJAM! -- Possible Jam DETECTED! -- FULLJAM! -"
							fi
						fi
						LOG blue "--------------------------------------------------"
						printf "%s - EVENT: Full Jam!\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_DETJAM_FILE"
						printf "Jams: %s | Found: %s | Clean Streak: %s | Uptime: %s\n" "$jams" "$jammerDet" "$nojamstreak_hold" "$totalruntime_display" >> "$REPORT_DETJAM_FILE"
						sleep 3
						totalruntime=$((totalruntime+5))
					else
						# LOG "Adapter(s) DOWN, false positive!"
						# LOG "hcitool FAIL - HOW IS THIS POSSIBLE?"
						length_display
						runtime_display=""
						if [[ "$showruntimeNS" -eq 1 ]] ; then
							runtime_display="${runtime}s ($runtimens ns)"
						fi
						status_display="DOWN --"
						LOG magenta "${status_display}|${jams_display}| $jammerDet_display | $nojamstreak_display | ${totalruntime_display} ${runtime_display}"
						LOG blue "--------------------------------------------------"
						LOG magenta "-------- Adapter DOWN/ERROR, Resetting... --------"
						bring_adapters_up
						totalruntime=$((totalruntime+5))
					fi
				fi
				if [[ "$jams" -ge "$maxJams" ]] ; then
					# jammer detected
					LOG blue "--------------------------------------------------"
					if [[ "$seqJams" -gt 0 ]] ; then
						LOG red     "-- JAMMED! ---- Jammer CONFIRMED! ----- JAMMED! --"
						LOG red     "--------- Jammer very Close or Powerful! ---------"
					else
						LOG red     "-- JAMMED! ---- Jammer CONFIRMED! ----- JAMMED! --"
					fi
					LOG blue "--------------------------------------------------"
					# gps check
					gpspos_cur=$(GPS_GET)
					if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
						gpspos_last="$gpspos_cur" # GPS is valid
						printf "GPS Pos.: %s\n" "${gpspos_last}" >> "$REPORT_DETJAM_FILE"
					else
						if [[ -n "$gpspos_last" ]] ; then # gps lost, last known coordinates: gpspos_last
							printf "GPS LOST! %s (Last Known Pos.)\n" "${gpspos_last}" >> "$REPORT_DETJAM_FILE"
						fi
					fi
					printf "%s - EVENT: Jammer Detected!\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_DETJAM_FILE"
					jammerDet=$((jammerDet+1))
					total_detected=$((total_detected + 1))
					PAYLOAD_SET_CONFIG bluepinesuite total_detected "$total_detected"
					jamConf=1
					# LOG "Resetting Jams"
					nojamcount=0
					jams=0
					seqJams=0
					
					# silent alert/vibrate?
					if [[ "$scan_mute" == "false" ]] ; then
						RINGTONE "warning"
					fi
				fi
			done
			
			
			length_display
			printf "Total Runtime: %s\n" "$totalruntime_display" >> "$REPORT_DETJAM_FILE"
			printf "════════════════════════════════════════════\n" >> "$REPORT_DETJAM_FILE"
			printf "%s - EVENT: Finish scan\n" $(date +"%Y-%m-%d_%H%M%S") >> "$REPORT_DETJAM_FILE"
			printf "════════════════════════════════════════════\n" >> "$REPORT_DETJAM_FILE"
			
			if [[ "$totalruntime" -gt 60 ]] ; then 
				totalmin=$((totalruntime/60)); secs=$((totalruntime%60))
				if [[ "$secs" -gt 34 ]] ; then totalmin=$((totalmin+1)); fi
			else
				if [[ "$totalruntime" -gt 34 ]] ; then totalmin=1; fi
			fi
			# set scan values 
			total_scan_min=$((total_scan_min + totalmin))
			total_scans=$((total_scans + 1))
			PAYLOAD_SET_CONFIG bluepinesuite total_scan_min "$total_scan_min"
			PAYLOAD_SET_CONFIG bluepinesuite total_scans "$total_scans"
			
			if [[ "$jammerDet" -gt 0 ]] ; then
				if [[ "$scan_stealth" -eq 0 ]] ; then LED RED SLOW; fi
				if [[ "$scan_mute" == "false" ]] ; then
					RINGTONE "warning"
				fi
				LOG red "Jammer(s) detected: $jammerDet"
				printf "%s Bluetooth Jammer(s) found\n" "${jammerDet}" >> "$REPORT_DETJAM_FILE"
			else
				if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
				LOG green "No Jammers detected, all clear!"
				printf "No Jammers found, all clear!\n" >> "$REPORT_DETJAM_FILE"
			fi
		
			LOG "Cleaning up..."
			rm "$KEYCKTMP_FILE" 2>/dev/null
			if [[ "$archCur" == "pager" ]] ; then killall evtest 2>/dev/null; fi
			
			# return adapters to noscan
			hciconfig hci0 up noscan 2>/dev/null
			sleep 1
			hciconfig hci1 up noscan 2>/dev/null
			sleep 1

			# change name back for discoverable mac
			if [[ "$adapter_base" == "hci1" ]] ; then
				bluetoothctl <<-EOF >/dev/null 2>&1
				select $hci0_MAC
				system-alias "$hci0_NAMEold"
				quit
				EOF
				sleep 0.5
				rm ".bluetoothctl_history" 2>/dev/null
			else
				bluetoothctl <<-EOF >/dev/null 2>&1
				select $hci1_MAC
				system-alias "$hci1_NAMEold"
				quit
				EOF
				sleep 0.5
				rm ".bluetoothctl_history" 2>/dev/null
			fi
		fi
		LOG "Completed Jammer Detection..."
		LOG green "Press OK to continue..."
		WAIT_FOR_BUTTON_PRESS A
	else
		LOG "Skipped Jammer Detection..."
	fi
	if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
	LOG " "
}
