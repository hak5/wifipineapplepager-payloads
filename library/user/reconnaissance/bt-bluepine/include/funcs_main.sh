#!/bin/bash
# Main Functions for BluePine
# Author: cncartist
# Version: 1.5
# 
# update_bluetooth_status
# update_bluetooth_name
# generate_random_mac
# update_bluetooth_mac
# 
# saved_targets_check
# current_target_clear
# saved_targets_clear
# saved_targets_savecurrent
# saved_targets_saveall
# saved_targets_list
# select_target
# saved_target_remove_custom
# saved_targets_archive
# saved_targets_saveload
# 
# settings_check
# config_check
# config_read
# config_backup
# config_restore
# 
# start_cancelscan
# start_evtest
# check_cancel
# target_mac_check
# 
# bt_browse_services
# bt_get_info
# bt_get_vendor
# bt_verif_conn
# 

# change BT status
update_bluetooth_status(){
	# devicecurrnt="hci0"
	local devicecurrnt="$1"
	local devicestatus="DOWN"
	local devicediscov="OFF"
	
	# Confirm change
	resp=$(CONFIRMATION_DIALOG "Change Bluetooth Status/Discoverable Settings on Device: ${devicecurrnt}?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		LOG blue "================================================="
		LOG cyan "============= Current details ${devicecurrnt} =============="
		LOG blue "================================================="
		if [[ "$scan_privacy" -eq 1 ]] ; then LOG "-+ Hidden +-"; fi
		while read -r line; do
			if [[ "$scan_privacy" -eq 0 ]] ; then LOG "$line"; fi
			if echo "$line" | grep -q "DOWN"; then
				devicestatus="DOWN"
			fi
			if echo "$line" | grep -q "UP RUNNING"; then
				devicestatus="UP"
			fi
			if echo "$line" | grep -q "PSCAN ISCAN"; then
				devicediscov="ON"
			fi
		done < <(
				hciconfig -a | 
				grep -A 2 "$devicecurrnt"
		)
		LOG blue "================================================="
		if [[ "$devicestatus" == "UP" ]] ; then
			LOG green "Device $devicecurrnt is currently: $devicestatus"
		else
			LOG red "Device $devicecurrnt is currently: $devicestatus"
		fi
		if [[ "$devicediscov" == "ON" ]] ; then
			LOG red "Device $devicecurrnt IS Discoverable"
		else
			LOG green "Device $devicecurrnt is not Discoverable"
		fi
		LOG green "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		
		# Confirm change
		resp=$(CONFIRMATION_DIALOG "Change Adapter UP/DOWN Status for ${devicecurrnt}?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			resp=$(CONFIRMATION_DIALOG "Turn OFF/DOWN ${devicecurrnt}?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				# bring DOWN
				LOG green "Turning ${devicecurrnt} OFF..."
				LOG "Updating..."
				if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN VERYFAST; fi
				hciconfig "$devicecurrnt" down 2>/dev/null
				devicestatus="DOWN"
				sleep 0.5
				LOG green "Done..."
				LOG " "
				if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
			fi
			sleep 0.5
			# Confirm change
			resp=$(CONFIRMATION_DIALOG "Turn ON/UP ${devicecurrnt}?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				# bring UP
				LOG green "Turning ${devicecurrnt} ON..."
				LOG "Updating..."
				if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN VERYFAST; fi
				hciconfig "$devicecurrnt" up 2>/dev/null
				devicestatus="UP"
				sleep 0.5
				LOG green "Done..."
				LOG " "
				if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
			fi
		fi
		
		sleep 0.5
		if [[ "$devicestatus" == "DOWN" ]] ; then
			# Confirm change
			resp=$(CONFIRMATION_DIALOG "Device ${devicecurrnt} is DOWN, do you want to bring it UP?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				LOG green "Turning ${devicecurrnt} ON..."
				LOG "Updating..."
				if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN VERYFAST; fi
				hciconfig "$devicecurrnt" up 2>/dev/null
				devicestatus="UP"
				sleep 0.5
				LOG green "Done..."
				LOG " "
				if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
			fi
		fi
		if [[ "$devicestatus" == "UP" ]] ; then
			# Confirm change
			resp=$(CONFIRMATION_DIALOG "Change Discoverable Setting for ${devicecurrnt}?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				resp=$(CONFIRMATION_DIALOG "Make ${devicecurrnt} Discoverable?")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					# make Discoverable
					LOG green "Making ${devicecurrnt} Discoverable..."
					LOG "Updating..."
					if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN VERYFAST; fi
					hciconfig "$devicecurrnt" up piscan 2>/dev/null
					devicediscov="ON"
					sleep 0.5
					LOG green "Done..."
					LOG " "
					if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
				fi
				sleep 0.5
				# Confirm change
				resp=$(CONFIRMATION_DIALOG "Make ${devicecurrnt} Hidden?")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					# make Hidden
					LOG green "Making ${devicecurrnt} Hidden..."
					LOG "Updating..."
					if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN VERYFAST; fi
					hciconfig "$devicecurrnt" up noscan 2>/dev/null
					devicediscov="OFF"
					sleep 0.5
					LOG green "Done..."
					LOG " "
					if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
				fi
			fi
		else
			LOG " "
			LOG red "${devicecurrnt} is OFF/DOWN and cannot be made discoverable."
			LOG " "
		fi
		sleep 0.5
		
		LOG blue "================================================="
		LOG cyan "=============== New details ${devicecurrnt} ================"
		LOG blue "================================================="
		if [[ "$scan_privacy" -eq 1 ]] ; then LOG "-+ Hidden +-"; fi
		while read -r line; do
			if [[ "$scan_privacy" -eq 0 ]] ; then LOG "$line"; fi
			if echo "$line" | grep -q "DOWN"; then
				devicestatus="DOWN"
			fi
			if echo "$line" | grep -q "UP RUNNING"; then
				devicestatus="UP"
			fi
			if echo "$line" | grep -q "PSCAN ISCAN"; then
				devicediscov="ON"
			fi
		done < <(
				hciconfig -a | 
				grep -A 2 "$devicecurrnt"
		)
		LOG blue "================================================="
		LOG " "
		LOG green "Configuration complete for: ${devicecurrnt}"
		LOG green "Press OK to continue..."
		LOG " "
		if [[ "$scan_stealth" -eq 0 ]] ; then LED GREEN; fi
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
	else
		LOG "Status/Discoverable config skipped for: ${devicecurrnt}"
		LOG green "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
	fi
}

# change BT name
update_bluetooth_name(){
	# verify bluetoothd for this function
	bluetoothd_check
	
	# devicecurrnt="hci0"
	local devicecurrnt="$1"
	local devicestatus="DOWN"
	local newname=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
	if [[ "$scan_privacy" -eq 1 ]] ; then newname="$priv_name_txt"; fi
	local search1="Type:"
	local search2="BD Address:"
	local search3="Name:"
	local search4="Manufacturer:"
	while read -r line; do
		if echo "$line" | grep -q "DOWN"; then
			devicestatus="DOWN"
		fi
		if echo "$line" | grep -q "UP RUNNING"; then
			devicestatus="UP"
		fi
	done < <(
		hciconfig -a | 
		grep -A 2 "$devicecurrnt"
	)
	if [[ "$devicestatus" == "DOWN" ]] ; then
		# Confirm change
		resp=$(CONFIRMATION_DIALOG "Device ${devicecurrnt} is DOWN, do you want to bring it UP?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LOG green "Turning ${devicecurrnt} ON..."
			LOG "Updating..."
			if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN VERYFAST; fi
			hciconfig "$devicecurrnt" up 2>/dev/null
			devicestatus="UP"
			sleep 0.5
			LOG green "Done..."
			LOG " "
			if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		fi
	fi
	# Confirm change
	resp=$(CONFIRMATION_DIALOG "Change Bluetooth Name on Device: ${devicecurrnt}?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" && "$devicestatus" == "UP" ]] ; then
		LOG blue "================================================="
		LOG cyan "============= Current details ${devicecurrnt} =============="
		LOG blue "================================================="
		if [[ "$scan_privacy" -eq 1 ]] ; then LOG "-+ Hidden +-"; fi
		while read -r line; do
			if [[ "$scan_privacy" -eq 0 ]] ; then LOG "$line"; fi
		done < <(
			hciconfig $devicecurrnt -a | 
			grep -E "${search1}|${search2}|${search3}|${search4}"
		)
		LOG blue "================================================="
		LOG green "Press OK to pick a new name..."
		LOG " "
		if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN; fi
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		# escape name for single quotes (removes some input if single quotes present)
		newname="${newname//\'/\'}"
		newname=$(TEXT_PICKER "New name" "$newname")
		LOG cyan "New Name: ${newname}"
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5

		# Confirm Name Change
		resp=$(CONFIRMATION_DIALOG "Confirm BT Name Change to: '${newname}'
		
For Device: ${devicecurrnt}?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			MAC_CHECK=$(hciconfig $devicecurrnt | grep 'BD Address' | awk '{print $3}')
			LOG green "Updating Name to ${newname} for Device: ${devicecurrnt}..."
			LOG "Updating..."
			if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN VERYFAST; fi
			# bluetoothctl select $MAC_CHECK 2>/dev/null
			# sleep 1
			# bluetoothctl system-alias "${newname}" 2>/dev/null
			LOG "Applying change..."
			
			bluetoothctl <<-EOF >/dev/null 2>&1
			select $MAC_CHECK
			system-alias "${newname}"
			quit
			EOF
			sleep 0.5
			rm ".bluetoothctl_history" 2>/dev/null
			
			runoOld=0
			if [[ "$runoOld" -eq 1 ]] ; then
				hciconfig "$devicecurrnt" name "${newname}" 2>/dev/null
				sleep 1
				hciconfig "$devicecurrnt" down 2>/dev/null
				sleep 1
				hciconfig "$devicecurrnt" up 2>/dev/null
			fi
			sleep 1
			LOG green "Done..."
			LOG " "
			if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
			LOG blue "================================================="
			LOG cyan "=============== New details ${devicecurrnt} ================"
			LOG blue "================================================="
			if [[ "$scan_privacy" -eq 1 ]] ; then LOG "-+ Hidden +-"; fi
			while read -r line; do
				if [[ "$scan_privacy" -eq 0 ]] ; then LOG "$line"; fi
			done < <(
				hciconfig $devicecurrnt -a | 
				grep -E "${search1}|${search2}|${search3}|${search4}"
			)
			LOG blue "================================================="
			LOG " "
			LOG green "BT Name Changed to '${newname}' for: ${devicecurrnt}"
			LOG green "Press OK to continue..."
			LOG " "
			if [[ "$scan_stealth" -eq 0 ]] ; then LED GREEN; fi
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.5
		else
			LOG "Name change skipped for ${devicecurrnt}"
			LOG green "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.5
		fi
	else
		if [ "$devicestatus" = "DOWN" ]; then
			LOG red "DEVICE ${devicecurrnt} is DOWN, bring UP to change name!"
		fi
		LOG "Name change skipped for ${devicecurrnt}"
		LOG green "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
	fi
}


update_bluetooth_mac(){
	# verify bluetoothd for this function
	bluetoothd_check
	
	# devicecurrnt="hci0"
	local devicecurrnt="$1"
	local defaultseladdrnum=0
	local newseladdrnum=0
	local founditems=0
	local aliaschange="false"
	local aliaschangetext=""
	local newalias="Pineapple Pager"

	local OLD_MAC=$(hciconfig $devicecurrnt | grep 'BD Address' | awk '{print $3}')
	local OLD_NAME=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
	
	# CSR8510 A10
	# GOOD
	# HCI Version: 4.0 (0x6)  Revision: 0x22bb
    # LMP Version: 4.0 (0x6)  Subversion: 0x22bb
    # Manufacturer: Cambridge Silicon Radio (10)
	# BAD
	# HCI Version:  (0xe)  Revision: 0x201
    # LMP Version:  (0xe)  Subversion: 0x201
    # Manufacturer: Cambridge Silicon Radio (10)
	# ---- ARRAYS ----
	declare -A BT_NUMS; declare -A BT_DESCR; declare -A BT_ALIAS
	BT_NUMS[0]="00:00:00:00:00:00"; BT_DESCR["00:00:00:00:00:00"]="RANDOM NEW MAC ADDRESS"; BT_ALIAS["00:00:00:00:00:00"]="none"
	BT_NUMS[1]="00:00:00:00:00:00"; BT_DESCR["00:00:00:00:00:00"]="INPUT NEW MAC ADDRESS"; BT_ALIAS["00:00:00:00:00:00"]="none"
	BT_NUMS[2]="00:1A:7D:DA:71:13"; BT_DESCR["00:1A:7D:DA:71:13"]="USB BT - CSR v4.0"; BT_ALIAS["00:1A:7D:DA:71:13"]="LG_TV"
	# FUN
	BT_NUMS[3]="FF:FF:FF:FF:FF:FF"; BT_DESCR["FF:FF:FF:FF:FF:FF"]="Broadcast"; BT_ALIAS["FF:FF:FF:FF:FF:FF"]='1-800'
	BT_NUMS[4]="DE:AD:BE:EF:CA:FE"; BT_DESCR["DE:AD:BE:EF:CA:FE"]="Dead Beef Cafe"; BT_ALIAS["DE:AD:BE:EF:CA:FE"]="ChopSuey"
	BT_NUMS[5]="BA:AD:F0:0D:D0:0D"; BT_DESCR["BA:AD:F0:0D:D0:0D"]="Bad Food Dood"; BT_ALIAS["BA:AD:F0:0D:D0:0D"]="Special Delivery"
	BT_NUMS[6]="00:FE:ED:BE:EF:00"; BT_DESCR["00:FE:ED:BE:EF:00"]="Feed Beef"; BT_ALIAS["00:FE:ED:BE:EF:00"]="CityWok"
	BT_NUMS[7]="01:23:45:67:89:AB"; BT_DESCR["01:23:45:67:89:AB"]="Incremental"; BT_ALIAS["01:23:45:67:89:AB"]="Sesame Street Countdown"
	BT_NUMS[8]="2E:B0:00:70:00:17"; BT_DESCR["2E:B0:00:70:00:17"]="Reboot It"; BT_ALIAS["2E:B0:00:70:00:17"]='$(reboot)'
	BT_NUMS[9]="2D:48:41:4B:35:2D"; BT_DESCR["2D:48:41:4B:35:2D"]="HAK5 in Hex"; BT_ALIAS["2D:48:41:4B:35:2D"]='-HAK5-'
	# SPOOF
	BT_NUMS[10]="08:84:9D:1A:2B:3C"; BT_DESCR["08:84:9D:1A:2B:3C"]="Jabra Earbuds"; BT_ALIAS["08:84:9D:1A:2B:3C"]="Jabra Elite 4 Active"
	BT_NUMS[11]="3C:07:71:E5:A2:B9"; BT_DESCR["3C:07:71:E5:A2:B9"]="Sony TV"; BT_ALIAS["3C:07:71:E5:A2:B9"]="Sony TV"
	BT_NUMS[12]="70:2C:1F:41:E2:43"; BT_DESCR["70:2C:1F:41:E2:43"]="Samsung Fridge"; BT_ALIAS["70:2C:1F:41:E2:43"]="Samsung Smart Refrigerator"
	BT_NUMS[13]="64:B3:10:00:B0:0B"; BT_DESCR["64:B3:10:00:B0:0B"]="BlueBorne Samsung"; BT_ALIAS["64:B3:10:00:B0:0B"]="BlueBoob"
	BT_NUMS[14]="D0:65:CA:13:55:55"; BT_DESCR["D0:65:CA:13:55:55"]="BlueBorne Huawei"; BT_ALIAS["D0:65:CA:13:55:55"]="Born Blue"
	BT_NUMS[15]="00:13:37:00:13:37"; BT_DESCR["00:13:37:00:13:37"]="Pineapple Pager"; BT_ALIAS["00:13:37:00:13:37"]="Pineapple Pager"
	BT_NUMS[16]="0C:FA:22:FF:F0:07"; BT_DESCR["0C:FA:22:FF:F0:07"]="Flipper Zero"; BT_ALIAS["0C:FA:22:FF:F0:07"]="Flipper Zero"
	
	local maxarritems=$(( ${#BT_NUMS[@]} - 1 ))
	
	if [[ "$scan_privacy" -eq 1 ]] ; then OLD_MAC="${OLD_MAC:0:2}:░░:░░:░░:░░:░░"; OLD_NAME="$priv_name_txt"; fi
	LOG blue "================================================="
	LOG cyan "${devicecurrnt} Current MAC Address - ${OLD_MAC}"
	LOG cyan "${devicecurrnt} Current Name - ${OLD_NAME}"
	LOG blue "================================================="
	LOG green "Press OK to see Options + Preset MACs..."
	LOG " "
	WAIT_FOR_BUTTON_PRESS A
	sorted_BT_NUMS=( $(for key in "${!BT_NUMS[@]}"; do echo "$key"; done | sort) )
	# Record each
	for num in "${!sorted_BT_NUMS[@]}"; do
		if [[ "$num" -eq 0 ]]; then
			LOG magenta "==== Default = 0 ================================"
			LOG "${num}:  / Generate Random MAC Address"
			LOG " "
		elif [[ "$num" -eq 1 ]]; then
			LOG magenta "==== Custom = 1 ================================="
			LOG "${num}: Input Custom MAC Address"
			LOG " "
			LOG magenta "==== Presets ===================================="
		elif [[ "$num" -eq 3 ]]; then
			LOG magenta "======================================== Fun ===="
			name="${BT_DESCR[${BT_NUMS[$num]}]}"
			alias="${BT_ALIAS[${BT_NUMS[$num]}]}"
			mac="${BT_NUMS[$num]}"
			LOG "${num}: $mac | $name"
			LOG cyan "${num}: Alias: $alias"
			LOG blue "================================================="
		elif [[ "$num" -eq 10 ]]; then
			LOG magenta "====================================== Spoof ===="
			name="${BT_DESCR[${BT_NUMS[$num]}]}"
			alias="${BT_ALIAS[${BT_NUMS[$num]}]}"
			mac="${BT_NUMS[$num]}"
			LOG "${num}: $mac | $name"
			LOG cyan "${num}: Alias: $alias"
			LOG blue "================================================="
		else
			name="${BT_DESCR[${BT_NUMS[$num]}]}"
			alias="${BT_ALIAS[${BT_NUMS[$num]}]}"
			mac="${BT_NUMS[$num]}"
			LOG "${num}: $mac | $name"
			LOG cyan "${num}: Alias: $alias"
			LOG blue "================================================="
		fi
		founditems=$((founditems + 1))
	done
	LOG green   "-------- Press OK when Ready to Start... --------"
	LOG magenta "================================================="
	LOG " "
	WAIT_FOR_BUTTON_PRESS A
	sleep 0.25

	# Confirm change
	resp=$(CONFIRMATION_DIALOG "Change MAC Address on Device: ${devicecurrnt}?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		
		newseladdrnum=$(NUMBER_PICKER "Selection # (0-${maxarritems})" $defaultseladdrnum)
		case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) newseladdrnum=$defaultseladdrnum ;; esac
		[ $newseladdrnum -lt 0 ] && newseladdrnum=0
		[ $newseladdrnum -gt $maxarritems ] && newseladdrnum=$maxarritems
		
		if [[ "$newseladdrnum" -eq 0 ]]; then
			while true; do
				# run random
				NEW_MAC=$(generate_random_mac)
				# check it's not the real MAC randomly generated 
				NEW_OUI="${NEW_MAC:0:8}"
				if [[ "$NEW_MAC" != "00:1a:7d:da:71:13" ]] && [[ "$NEW_OUI" != "00:13:37" ]]; then
					# Confirm Random MAC sufficient
					resp=$(CONFIRMATION_DIALOG "This Random MAC OK? ${NEW_MAC}")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						break
					fi
				fi
				LOG red "Skip MAC: ${NEW_MAC}, generating new..."
			done
			LOG blue "================================================="
			LOG cyan "Random MAC chosen: ${NEW_MAC}"
			LOG blue "================================================="
			LOG green "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
		elif [[ "$newseladdrnum" -eq 1 ]]; then
			while true; do
				# run input
				NEW_MAC=$(MAC_PICKER "Custom MAC" "$OLD_MAC")
				# Confirm Random MAC sufficient
				if [[ "$NEW_MAC" =~ $VALID_MAC ]]; then
					resp=$(CONFIRMATION_DIALOG "This Custom MAC OK? ${NEW_MAC}")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						break
					fi
					LOG red "Skip MAC: ${NEW_MAC}, input new..."
				else 
					LOG red "Invalid MAC: ${NEW_MAC}, input new..."
				fi
			done
			LOG blue "================================================="
			LOG cyan "Custom MAC chosen: ${NEW_MAC}"
			LOG blue "================================================="
			LOG green "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
		else
			NEW_MAC="${BT_NUMS[$newseladdrnum]}"
			NEW_MAC_NAME="${BT_DESCR[${NEW_MAC}]}"
			LOG blue "================================================="
			LOG cyan "New MAC chosen: ${NEW_MAC}"
			LOG cyan "Description: ${NEW_MAC_NAME}"
			LOG blue "================================================="
			LOG green "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
		fi
		
		# Confirm change
		resp=$(CONFIRMATION_DIALOG "Do you also want to choose a new Permament Alias/Name for ${NEW_MAC} ?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN; fi
			# Change alias to new mac default or input new alias?
			aliaschange="true"
			newalias="${BT_ALIAS[${NEW_MAC}]}"
			if [[ -n "$newalias" ]] && [[ "$newalias" != "none" ]] ; then
				LOG "Preset Alias: ${newalias}"
			else
				newalias="$OLD_NAME"
				LOG "Alias: ${newalias}"
			fi
			LOG " "
			LOG "Press OK to confirm/enter new alias..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			while true; do
				# escape name for single quotes (removes some input if single quotes present)
				newalias="${newalias//\'/\'}"
				sleep 0.25
				newalias=$(TEXT_PICKER "New Permament Alias" "$newalias")
				if [[ -n "$newalias" ]] && [[ "$newalias" != " " ]]; then
					break
				else
					LOG red "Alias cannot be blank/empty!"
				fi
			done
			LOG cyan "Chosen Alias/Name: '${newalias}'"
			aliaschangetext="Alias to '${newalias}' & "
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.25
			if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		fi
		
		# Confirm change
		resp=$(CONFIRMATION_DIALOG "Change USB MAC ${aliaschangetext}Address for $devicecurrnt to: ${NEW_MAC} ?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			if [[ "$scan_stealth" -eq 0 ]] ; then LED BLUE SLOW; fi
			LOG "Changing USB $devicecurrnt to MAC: ${NEW_MAC}..."
			LOG blue "================================================="
			if [[ "$archCur" == "pager" ]] ; then
				# pager only has CSR USB BT
				bdaddr -i $devicecurrnt "$NEW_MAC" 2>/dev/null
			elif [[ "$archCur" == "aarch64" ]] ; then
				# TBD verify which adapter and which lib to use, currently assume CSR
				# bdaddr compiled for aarch64/raspberry pi/clockwork pi
				chmod +x ./include/aarch64/lib/bdaddr 2>/dev/null
				sleep 1
				./include/aarch64/lib/bdaddr -i $devicecurrnt "$NEW_MAC" 2>/dev/null
			else
				btmgmt -i $devicecurrnt public-addr "$NEW_MAC" 2>/dev/null
			fi
			sleep 2
			if [[ "$archCur" == "pager" || "$archCur" == "aarch64" ]] ; then
				# unplug
				LOG red "Please UNPLUG USB Bluetooth Adapter NOW..."
				LOG blue "================================================="
				LOG red "This needs to be done to reset the MAC!"
				LOG blue "================================================="
				LOG "You will plug it in immediately afterwards."
				LOG blue "================================================="
				LOG red "Please UNPLUG USB Bluetooth Adapter NOW..."
				LOG blue "================================================="
				LOG "Press OK to continue once unplugged..."
				LOG " "
				WAIT_FOR_BUTTON_PRESS A
			fi
			
			if [[ "$scan_stealth" -eq 0 ]] ; then LED YELLOW SLOW; fi
			if [[ "$archCur" == "pager" || "$archCur" == "aarch64" ]] ; then
				# check re-plug
				LOG red "PLUG USB Bluetooth IN AGAIN to continue..."
				LOG " "
				INITIAL_COUNT=$(ls /sys/bus/usb/devices/ | wc -l)
				while true; do
					sleep 0.25
					CURRENT_COUNT=$(ls /sys/bus/usb/devices/ | wc -l)
					if [[ "$CURRENT_COUNT" -gt "$INITIAL_COUNT" ]] ; then
						if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN FAST; fi
						LOG magenta "Device detected, please wait..."
						sleep 2
						LOG "Start device reset..."
						reset_bt_adapter "$devicecurrnt"
						# hciconfig "$devicecurrnt" down 2>/dev/null
						# sleep 1
						# hciconfig "$devicecurrnt" up 2>/dev/null
						# sleep 1
						LOG green "Completed device reset!"
						LOG " "
						# LOG "exiting loop"
						break
					fi
				done
			else
				sleep 2
				LOG "Start device reset..."
				reset_bt_adapter "$devicecurrnt"
				LOG green "Completed device reset!"
				LOG " "
			fi
			
			if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
			LOG blue "================================================="
			LOG "Checking MAC Address has changed..."
			LOG blue "================================================="
			NEW_MAC_CHECK=$(hciconfig $devicecurrnt | grep 'BD Address' | awk '{print $3}')
			NEW_NAME_CHECK=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
			LOG "Old $devicecurrnt MAC: $OLD_MAC"
			LOG "Old $devicecurrnt Name: $OLD_NAME"
			LOG blue "================================================="
			if [[ -n "$NEW_MAC_CHECK" ]]; then
			
				# Update to new alias if chosen
				if [[ "$aliaschange" == "true" ]] ; then
					if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN SLOW; fi
					LOG magenta "Setting Permament Alias to '${newalias}'"
					LOG magenta "For: ${NEW_MAC_CHECK}"
					# bluetoothctl select $NEW_MAC_CHECK 2>/dev/null
					# sleep 1
					# bluetoothctl system-alias "${newalias}" 2>/dev/null
					
					bluetoothctl <<-EOF >/dev/null 2>&1
					select $NEW_MAC_CHECK
					system-alias "${newalias}"
					quit
					EOF
					sleep 0.5
					rm ".bluetoothctl_history" 2>/dev/null
					
					runoOld=0
					if [[ "$runoOld" -eq 1 ]] ; then
						hciconfig "$devicecurrnt" name "${newalias}" 2>/dev/null
						sleep 1
						hciconfig "$devicecurrnt" down 2>/dev/null
						sleep 1
						hciconfig "$devicecurrnt" up 2>/dev/null
					fi
					sleep 1
					LOG green "Completed Permament Alias change!"
					LOG blue "================================================="
					NEW_NAME_CHECK=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
				fi
				
				if [[ "$scan_stealth" -eq 0 ]] ; then LED GREEN SLOW; fi
				LOG cyan "New $devicecurrnt MAC: $NEW_MAC_CHECK"
				LOG cyan "New $devicecurrnt Name: $NEW_NAME_CHECK"
				LOG blue "================================================="
				if [[ "$OLD_NAME" != "$NEW_NAME_CHECK" ]] && [[ "$aliaschange" == "false" ]]; then
					if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA SLOW; fi
					LOG " "
					LOG red "Old name does not match new name!"
					resp=$(CONFIRMATION_DIALOG "Do you want to restore the name for $devicecurrnt to: ${OLD_NAME} ?")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						if [[ "$scan_stealth" -eq 0 ]] ; then LED GREEN SLOW; fi
						LOG " "
						LOG "Restoring name to: ${OLD_NAME}"
						sleep 1
						bluetoothctl <<-EOF >/dev/null 2>&1
						select $NEW_MAC_CHECK
						system-alias "${OLD_NAME}"
						quit
						EOF
						# bluetoothctl select $NEW_MAC_CHECK 2>/dev/null
						# sleep 1
						# bluetoothctl system-alias "${OLD_NAME}" 2>/dev/null
						sleep 1
						LOG green "Completed name restoration!"
						LOG " "
						NEW_NAME_CHECK=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
						LOG blue "================================================="
						LOG cyan "New $devicecurrnt MAC: $NEW_MAC_CHECK"
						LOG cyan "Restored $devicecurrnt Name: $NEW_NAME_CHECK"
						LOG blue "================================================="
					fi
				fi
				
			else
				if [[ "$scan_stealth" -eq 0 ]] ; then LED RED SLOW; fi
				LOG red "================== - ERROR - ===================="
				LOG red "Device $devicecurrnt MAC could not be found!"
				LOG red "The USB device is seen as inactive!"
				LOG red "================== - ERROR - ===================="
			fi
			LOG " "
			LOG green "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.2
		else
			LOG "MAC change skipped for ${devicecurrnt}"
			LOG green "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.2
		fi
	else
		LOG "MAC change skipped for ${devicecurrnt}"
		LOG green "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.2
	fi
}

# Generate a random 6-byte hexadecimal string with colons for MAC format
function generate_random_mac() {
    # Set the U/L bit (second-least-significant bit of the first octet) to 1 for local administration
    # and the I/G bit (least significant) to 0 for unicast
    local mac=$(openssl rand -hex 6)
    local first_byte_hex=${mac:0:2}
    local first_byte=$((0x$first_byte_hex))

    # Set the U/L bit to 1 (OR with 0x02) and ensure I/G is 0 (AND with 0xFE)
    first_byte=$(((first_byte | 0x02) & 0xFE))
    local new_first_byte=$(printf "%02x" $first_byte)

    # Reconstruct the MAC address with the modified first byte
    mac="${new_first_byte}:${mac:2:2}:${mac:4:2}:${mac:6:2}:${mac:8:2}:${mac:10:2}"
    echo "$mac"
}









# saved targets check
saved_targets_check() {
	# check if file is not empty this time around
	BT_TARGETS_SAVED=()
	if [[ -s "$SAVEDTARGETS_FILE" ]]; then
		linecount=$(grep -c '.' "$SAVEDTARGETS_FILE")
		# Use IFS to split ONLY on the first space and assign to variables
		# IFS=' ' read -r key value <<< "$INPUT_STRING"
		# -r prevents backslashes from being interpreted as escape characters
		LOG "${linecount} Saved ${text_target_UC}s Found!"
		if [[ "$archCur" == "pager" ]] ; then
			if [[ "$linecount" -gt "$savedTargCrit" ]] ; then
				if [[ "$scan_stealth" -eq 0 ]] ; then LED RED SLOW; fi
				LOG red "===================================== CRITICAL =="
				LOG red "Saved ${text_target_UC}s List is extremely large!"
				LOG " "
				LOG red "You'll experience severe performance impacts loading, viewing, or scanning Saved ${text_target_UC}s!"
				LOG red "===================================== CRITICAL =="
				LOG magenta "It's recommended to Clear or Clean the Saved ${text_target_UC}s List to be lower than ${savedTargWarn} ${text_target_UC}s."
				LOG blue "================================================="
			elif [[ "$linecount" -gt "$savedTargWarn" ]] ; then
				if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA SLOW; fi
				LOG magenta "====================================== WARNING =="
				LOG "Saved ${text_target_UC}s List is very large!"
				LOG " "
				LOG "You'll experience performance impacts loading, viewing, or scanning Saved ${text_target_UC}s!"
				LOG magenta "====================================== WARNING =="
				LOG magenta "It's recommended to Clear or Clean the Saved ${text_target_UC}s List to be lower than ${savedTargWarn} ${text_target_UC}s."
				LOG blue "================================================="
			else
				# if [[ "$scan_stealth" -eq 0 ]] ; then LED CYAN SLOW; fi
				if [[ "$scan_stealth" -eq 0 ]] ; then DO_A_BARREL_ROLL; fi
			fi
		fi
		LOG "Loading Saved ${text_target_UC}s into memory, please wait..."
		LOG blue "================================================="
		start=$SECONDS
		while IFS=' ' read -r key value; do
			if mac=$(echo "${key}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}'); then
				BT_TARGETS_SAVED[$mac]="$value"
				# LOG green "adding mac to BT_TARGETS_SAVED: ${mac}"
			fi
		done < "$SAVEDTARGETS_FILE"
		if [[ "$linecount" -gt "$savedTargCrit" || "$linecount" -gt "$savedTargWarn" ]] ; then
			runtime=$((SECONDS-start))
			if [[ "$runtime" -gt 60 ]] ; then
				minutes=$((runtime/60)); secs=$((runtime%60))
				LOG "Time to load ${linecount} Saved ${text_target_UC}s: ${minutes}min ${secs}s"
			else
				LOG "Time to load ${linecount} Saved ${text_target_UC}s: ${runtime} seconds"
			fi
			LOG blue "================================================="
		fi
		if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
		LOG green "Saved ${text_target_UC}s loaded..."
		LOG blue "================================================="
	fi
}

# current target clear
current_target_clear() {
	if [[ -n "$target_mac" ]]; then
		if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
	  LOG green "========= Selected ${text_target_UC}: $target_mac ===="
		resp=$(CONFIRMATION_DIALOG "Clear ${text_target_UC} MAC? ${target_mac}")
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			target_mac=""
			echo "$target_mac" > "$TARGETMAC_FILE"
			LOG green "${text_target_UC} MAC cleared!"
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.25
		fi
	else
		LOG red "========================= No ${text_target_UC} Selected ===="
	fi
}

# saved targets clear all
saved_targets_clear() {	
	resp=$(CONFIRMATION_DIALOG "Are you sure you want to CLEAR ALL Saved ${text_target_UC}s? ")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		rm "$SAVEDTARGETS_FILE" 2>/dev/null
		BT_TARGETS_SAVED=()
		LOG green "ALL Saved ${text_target_UC}s cleared!"
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
	fi
	sleep 1
	resp=$(CONFIRMATION_DIALOG "Do you want to CLEAR ALL Unsaved Scan ${text_target_UC}s? ")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		BT_RSSIS=()
		BT_NAMES=()
		BT_COMPS=()
		BT_TARGETS=()
		BT_AXONCAMS=()
		BT_CCSKIMMR=()
		BT_FLIPPERS=()
		BT_FLOCKCAM=()
		BT_MESHTAST=()
		BT_NESTCAMS=()
		BT_TILETAGS=()
		BT_SMRTGLAS=()
		BT_USBKILLS=()
		BT_PINEAPPS=()
		BT_CUSTOMOU=()
		LOG green "ALL Scan ${text_target_UC}s cleared!"
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
	fi
	sleep 0.25
}

# saved targets save current
saved_targets_savecurrent() {
	addedtargs=0
	# check if target is set
	if [[ -n "$target_mac" ]]; then
		if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
		resp=$(CONFIRMATION_DIALOG "Confirm adding Selected ${text_target_UC} ${target_mac} to Saved ${text_target_UC}s List? ")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LOG green "========= Selected ${text_target_UC}: $target_mac ===="
			LOG "Add ${text_target_UC}: $target_mac to Saved ${text_target_UC}s..."
			
			if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
			targetlist_name="${BT_NAMES[$target_mac]}"
			targetlist_comp="${BT_COMPS[$target_mac]}"
			if [[ -z "$targetlist_name" ]]; then
				targetlist_name="Unknown"
			fi
			if [[ -z "$targetlist_comp" ]]; then
				targetlist_comp="n/a"
			fi
			
			if [[ "$targetlist_comp" == "n/a" ]] ; then
				targetlist_comp=""
			else
				if [[ -z "$targetlist_name" ]] || [[ "$targetlist_name" == "Unknown" ]] ; then
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
			
			# Check if the string exists in the file
			if [[ -s "$SAVEDTARGETS_FILE" ]] && grep -q "$target_mac" "$SAVEDTARGETS_FILE"; then
				# echo "The string variable exists in the file."
				# remove line that has mac first
				sed -i "/$target_mac/d" "$SAVEDTARGETS_FILE"
				printf "%s %s\n" "${target_mac}" "${NEW_TARGET_MAC_NAME}" >> "$SAVEDTARGETS_FILE"
			else
				# echo "The string variable does not exist in the file."
				printf "%s %s\n" "${target_mac}" "${NEW_TARGET_MAC_NAME}" >> "$SAVEDTARGETS_FILE"
			fi
			
			BT_TARGETS_SAVED[$target_mac]="$NEW_TARGET_MAC_NAME"
			
			if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
			LOG cyan "${text_target_UC}: $target_mac added to Saved ${text_target_UC}s!"
			if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.25
		fi
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
	else
		LOG red "========================= No ${text_target_UC} Selected ===="
		LOG red "Select a ${text_target_UC} first to save..."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.25
	fi
}

# saved targets saveall
saved_targets_saveall() {
	addedtargs=0
	# check if saved targetlist is empty
	if [[ "${#BT_TARGETS[@]}" -eq 0 ]] ; then
		LOG red "No Scan ${text_target_UC}s available yet."
		LOG red "Run Scan first to populate ${text_target_UC}s or set ${text_target_UC}."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.25
	else
		resp=$(CONFIRMATION_DIALOG "Are you sure you want to ADD ALL Scan ${text_target_UC}s to Saved ${text_target_UC}s List? ")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LOG "Adding all Scan ${text_target_UC}s to Saved ${text_target_UC}s List..."
			for mac in "${!BT_TARGETS[@]}"; do
				targetlist_name="${BT_NAMES[$mac]}"
				if [[ -z "$targetlist_name" ]] ; then
					targetlist_name="${BT_TARGETS[$mac]}"
				fi
				targetlist_comp="${BT_COMPS[$mac]}"
				if [[ "$targetlist_comp" == "n/a" ]] ; then
					targetlist_comp=""
				else
					if [[ -z "$targetlist_name" ]] || [[ "$targetlist_name" == "Unknown" ]] ; then
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
				# LOG "${mac} - ${NEW_TARGET_MAC_NAME}"
				# Check if the string exists in the file
				if [[ -s "$SAVEDTARGETS_FILE" ]] && grep -q "$mac" "$SAVEDTARGETS_FILE"; then
					# echo "The string variable exists in the file."
					# only add if new name known, otherwise leave unchanged
					if [[ "$NEW_TARGET_MAC_NAME" != "Unknown" ]] ; then
						# remove lines that have mac first
						sed -i "/$mac/d" "$SAVEDTARGETS_FILE"
						printf "%s %s\n" "${mac}" "${NEW_TARGET_MAC_NAME}" >> "$SAVEDTARGETS_FILE"
						BT_TARGETS_SAVED[$mac]="$NEW_TARGET_MAC_NAME"
					fi
				else
					# echo "The string variable does not exist in the file."
					printf "%s %s\n" "${mac}" "${NEW_TARGET_MAC_NAME}" >> "$SAVEDTARGETS_FILE"
					BT_TARGETS_SAVED[$mac]="$NEW_TARGET_MAC_NAME"
					addedtargs=$((addedtargs + 1))
				fi
			done
			LOG green "Added ${addedtargs} to Saved ${text_target_UC}s List."
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.25
		fi
	fi
}

# saved targets
saved_targets_list() {
	# count targets
	saved_target_count="${#BT_TARGETS_SAVED[@]}"
	saved_target_count_arr=$(( ${#BT_TARGETS_SAVED[@]} - 1 ))
	# LOG "saved_target_count: $saved_target_count"
	# check if saved targetlist is empty
	if [[ "${#BT_TARGETS_SAVED[@]}" -eq 0 ]] ; then
		LOG red "No Saved ${text_target_UC}s available yet."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.25
	else
		if [[ "$saved_target_select" -eq 1 ]]; then
			if [[ -n "$target_mac" ]]; then
				if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
				LOG green "========= Selected ${text_target_UC}: $target_mac ===="
				if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
				LOG red "Picking new ${text_target_UC} overwrites above selection."
				LOG " "
			else
				LOG red "========================= No ${text_target_UC} Selected ===="
			fi
		fi
		LOG green "${saved_target_count} Saved ${text_target_UC}s available for selection!"
		if [[ "$archCur" == "pager" ]] ; then
			if [[ "$saved_target_count" -gt "$savedTargWarn" ]] ; then
				LOG magenta "====================================== WARNING =="
				LOG red     "Saved ${text_target_LC}s count is greater than ${savedTargWarn}!"
				LOG red     "Extra time needed to prepare full list!"
				LOG red     "Approx. 1 min for 1500 ${text_target_LC}s"
				LOG magenta "====================================== WARNING =="
			fi
			LOG "Press OK to confirm viewing Saved ${text_target_UC}s..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.5
			resp=$(CONFIRMATION_DIALOG "Confirm viewing Saved ${text_target_UC}s?")
		else
			resp='y'
		fi
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			# SHOW LIST FOR SELECTION IF CONFIRMED
			if [[ "$scan_stealth" -eq 0 ]] ; then LED RED SLOW; fi
			LOG "Loading Saved ${text_target_UC}s for display..."
			LOG "Please wait..."
			# mac="$key"
			# name="${BT_NAMES[$mac]}"
			# comp="${BT_COMPS[$mac]}"
			# BT_TARGETS_SAVED[$mac]="$name"
			# BT_TARGETS_SAVED_SORT[3]="11:11:11:11:11:11"
			
			# LOG "re-order" # sort
			tmpnum=0
			# A more robust approach using a while loop:
			while IFS= read -r line; do
				# Extract value and key from the line
				key=$(echo "$line" | cut -d' ' -f1)
				# value=$(echo "$line" | cut -d' ' -f2-)
				# LOG "reorder ${key}: ${value}"
				# LOG "reorder ${tmpnum}: ${key}"
				BT_TARGETS_SAVED_SORT[$tmpnum]="$key"
				tmpnum=$((tmpnum + 1))
			done < <(
				for key in "${!BT_TARGETS_SAVED[@]}"; do
					echo "$key"
				done | sort -n
			)
			# sort -rn for descending, sort -n for ascending
			
			# LOG "Sorting..."
			BT_TARGETS_SAVED_SORT_FIN=( $(for key in "${!BT_TARGETS_SAVED_SORT[@]}"; do echo "$key"; done | sort) )
			LOG "Saved ${text_target_UC}s loaded..."
			if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
			tmpnum=0
			viewall=0
			# Record each
			LOG blue "============================== Saved ${text_target_UC}s ===="
			for num in "${!BT_TARGETS_SAVED_SORT_FIN[@]}"; do
				if [[ "$viewall" -eq 0 ]] ; then
					if (( num % 12 == 0 )) && (( num != 0 )); then
						# LOG "$number is divisible by 12 and is not 0."
						tmpnum=$((tmpnum + 1))
						if (( tmpnum % 5 == 0 )) && (( num != 0 )); then
							sleep 1
							resp=$(CONFIRMATION_DIALOG "Do you want to list ALL ${saved_target_count} Saved ${text_target_UC}s right now?")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								viewall=1
								sleep 0.25
							else 
								sleep 1
								resp=$(CONFIRMATION_DIALOG "Do you want to cancel loading the rest of Saved ${text_target_UC}s?")
								if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
									LOG " "
									LOG "Cancelled loading rest of Saved ${text_target_UC}s..."
									sleep 0.25
									break
								fi
								LOG blue "------------------- Press OK to view more... ----"
								WAIT_FOR_BUTTON_PRESS A
								sleep 0.25
							fi
						else
							LOG blue "------------------- Press OK to view more... ----"
							WAIT_FOR_BUTTON_PRESS A
							sleep 0.25
						fi
					fi
				fi
				targetlist_mac="${BT_TARGETS_SAVED_SORT[$num]}"
				targetlist_name="${BT_TARGETS_SAVED[$targetlist_mac]}"
				
				if [[ "$scan_privacy" -eq 1 ]] ; then targetlist_mac="${targetlist_mac:0:2}:░░:░░:░░:░░:░░"; targetlist_name="$priv_name_txt"; fi
				LOG "${num}: ${targetlist_mac} - ${targetlist_name}"
			done
			LOG blue "============================== Saved ${text_target_UC}s ===="
			
			if [[ "$saved_target_select" -eq 0 && "$saved_target_remove" -eq 0 && "$saved_target_rename" -eq 0 ]] ; then
				LOG "Press OK to continue..."
				LOG " "
				WAIT_FOR_BUTTON_PRESS A
				sleep 0.25
			fi
			
			if [[ "$saved_target_select" -eq 1 ]]; then
				LOG "Press OK to confirm selecting a Saved ${text_target_UC}..."
				WAIT_FOR_BUTTON_PRESS A
				sleep 0.5
				resp=$(CONFIRMATION_DIALOG "Confirm selecting Saved ${text_target_UC}?")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					# SHOW LIST FOR SELECTION IF CONFIRMED
					defaulttargaddrnum=0
					while true; do
						LOG "Press OK to select a Saved ${text_target_UC}..."
						LOG " "
						WAIT_FOR_BUTTON_PRESS A
						sleep 0.5
					
						newtargaddrnum=$(NUMBER_PICKER "Saved ${text_target_UC} # (0-${saved_target_count_arr})" $defaulttargaddrnum)
						case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) newtargaddrnum=$defaulttargaddrnum ;; esac
						[ $newtargaddrnum -lt 0 ] && newtargaddrnum=0
						[ $newtargaddrnum -gt $saved_target_count_arr ] && newtargaddrnum=$saved_target_count_arr
						
						NEW_TARGET_MAC="${BT_TARGETS_SAVED_SORT[$newtargaddrnum]}"
						NEW_TARGET_MAC_NAME="${BT_TARGETS_SAVED[$NEW_TARGET_MAC]}"
						if [[ "$scan_privacy" -eq 1 ]] ; then 
							priv_mac_save="$NEW_TARGET_MAC"
							NEW_TARGET_MAC="${NEW_TARGET_MAC:0:2}:░░:░░:░░:░░:░░"
							priv_name_save="$NEW_TARGET_MAC_NAME"
							NEW_TARGET_MAC_NAME="$priv_name_txt"
						fi
						resp=$(CONFIRMATION_DIALOG "Accept new ${text_target_UC} ${NEW_TARGET_MAC} - ${NEW_TARGET_MAC_NAME} ?")
						if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
							if [[ "$scan_privacy" -eq 1 ]] ; then NEW_TARGET_MAC="$priv_mac_save"; fi
							target_mac="$NEW_TARGET_MAC"
							echo "$target_mac" > "$TARGETMAC_FILE"
							LOG green "New ${text_target_UC} Selected!"
							if [[ "$scan_privacy" -eq 1 ]] ; then 
								priv_mac_save="$target_mac"
								target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"
							fi
							LOG magenta "===================================== ${text_target_UC} ===="
							LOG cyan "${text_target_UC} MAC: ${target_mac}"
							LOG cyan "Name/Company: ${NEW_TARGET_MAC_NAME}"
							LOG magenta "===================================== ${text_target_UC} ===="
							if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
							LOG "Press OK to continue..."
							LOG " "
							WAIT_FOR_BUTTON_PRESS A
							sleep 0.25
							break
						else 
							LOG red "Skip ${text_target_UC}: ${NEW_TARGET_MAC}, selecting new..."
						fi
						sleep 0.5
					done
				else
					LOG "Skipped selecting Saved ${text_target_UC}..."
				fi
			fi
			
			if [[ "$saved_target_rename" -eq 1 ]]; then
				sleep 0.5
				resp=$(CONFIRMATION_DIALOG "Do you want to Rename a Saved ${text_target_UC}?")
				if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					saved_target_rename=0
				fi
			fi
			if [[ "$saved_target_rename" -eq 1 ]]; then
				if [[ "$archCur" == "pager" ]] ; then
					LOG "Press OK to confirm renaming a Saved ${text_target_UC}..."
					WAIT_FOR_BUTTON_PRESS A
					sleep 0.5
					resp=$(CONFIRMATION_DIALOG "Confirm renaming Saved ${text_target_UC}?")
				else
					resp='y'
				fi
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					# SHOW LIST FOR SELECTION IF CONFIRMED
					defaulttargaddrnum=0
					while true; do
						if [[ "$archCur" == "pager" ]] ; then
							LOG "Press OK to select a Saved ${text_target_UC}..."
							LOG " "
							WAIT_FOR_BUTTON_PRESS A
						fi
						sleep 0.5
					
						newtargaddrnum=$(NUMBER_PICKER "Saved ${text_target_UC} # (0-${saved_target_count_arr})" $defaulttargaddrnum)
						case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) newtargaddrnum=$defaulttargaddrnum ;; esac
						[ $newtargaddrnum -lt 0 ] && newtargaddrnum=0
						[ $newtargaddrnum -gt $saved_target_count_arr ] && newtargaddrnum=$saved_target_count_arr
						
						NEW_TARGET_MAC="${BT_TARGETS_SAVED_SORT[$newtargaddrnum]}"
						NEW_TARGET_MAC_NAME="${BT_TARGETS_SAVED[$NEW_TARGET_MAC]}"
						OLD_TARGET_MAC_NAME="$NEW_TARGET_MAC_NAME"
						
						if [[ "$scan_privacy" -eq 1 ]] ; then 
							priv_mac_save="$NEW_TARGET_MAC"
							NEW_TARGET_MAC="${NEW_TARGET_MAC:0:2}:░░:░░:░░:░░:░░"
							priv_name_save="$NEW_TARGET_MAC_NAME"
							NEW_TARGET_MAC_NAME="$priv_name_txt"
							OLD_TARGET_MAC_NAME="$priv_name_txt"
						fi
						resp=$(CONFIRMATION_DIALOG "Rename Saved ${text_target_UC} ${NEW_TARGET_MAC} - ${NEW_TARGET_MAC_NAME} ?")
						
						if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
							while true; do
								if [[ "$archCur" == "pager" ]] ; then
									LOG "Press OK to pick a new name..."
									LOG " "
									WAIT_FOR_BUTTON_PRESS A
								fi
								sleep 0.25
								# escape name for single quotes (removes some input if single quotes present)
								NEW_TARGET_MAC_NAME="${NEW_TARGET_MAC_NAME//\'/\'}"
								NEW_TARGET_MAC_NAME=$(TEXT_PICKER "${text_target_UC} Name" "$NEW_TARGET_MAC_NAME")
								LOG cyan "New Name: ${NEW_TARGET_MAC_NAME}"
								if [[ "$archCur" == "pager" ]] ; then
									LOG "Press OK to confirm..."
									LOG " "
									WAIT_FOR_BUTTON_PRESS A
								fi
								sleep 0.25
								# Confirm Name Change
								resp=$(CONFIRMATION_DIALOG "Confirm Name Change to '${NEW_TARGET_MAC_NAME}' from '${OLD_TARGET_MAC_NAME}'?")
								if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
									LOG green "Saved Target Renamed! - ${NEW_TARGET_MAC}"
									LOG "Old Name: ${OLD_TARGET_MAC_NAME}"
									LOG magenta "New Name: ${NEW_TARGET_MAC_NAME}"
									if [[ "$scan_privacy" -eq 1 ]] ; then NEW_TARGET_MAC="$priv_mac_save"; fi
									# remove lines that has mac first
									sed -i "/$NEW_TARGET_MAC/d" "$SAVEDTARGETS_FILE"
									printf "%s %s\n" "${NEW_TARGET_MAC}" "${NEW_TARGET_MAC_NAME}" >> "$SAVEDTARGETS_FILE"
									BT_TARGETS_SAVED[$NEW_TARGET_MAC]="$NEW_TARGET_MAC_NAME"
									break
								fi
							done
							LOG "Press OK to continue..."
							LOG " "
							WAIT_FOR_BUTTON_PRESS A
							sleep 0.25
							break
						else 
							LOG red "Skip ${text_target_UC}: ${NEW_TARGET_MAC}, selecting new..."
						fi
						sleep 0.5
					done
				else
					LOG "Skipped removing Saved ${text_target_UC}..."
				fi
			fi
			
			
			if [[ "$saved_target_remove" -eq 1 ]]; then
				sleep 0.5
				resp=$(CONFIRMATION_DIALOG "Do you want to Remove a Saved ${text_target_UC}?")
				if [[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					saved_target_remove=0
				fi
			fi
			if [[ "$saved_target_remove" -eq 1 ]]; then
				if [[ "$archCur" == "pager" ]] ; then
					LOG "Press OK to confirm removing a Saved ${text_target_UC}..."
					WAIT_FOR_BUTTON_PRESS A
					sleep 0.5
					resp=$(CONFIRMATION_DIALOG "Confirm removing Saved ${text_target_UC}?")
				else
					resp='y'
				fi
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					# SHOW LIST FOR SELECTION IF CONFIRMED
					defaulttargaddrnum=0
					while true; do
						if [[ "$archCur" == "pager" ]] ; then
							LOG "Press OK to select a Saved ${text_target_UC}..."
							LOG " "
							WAIT_FOR_BUTTON_PRESS A
						fi
						sleep 0.5
					
						newtargaddrnum=$(NUMBER_PICKER "Saved ${text_target_UC} # (0-${saved_target_count_arr})" $defaulttargaddrnum)
						case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) newtargaddrnum=$defaulttargaddrnum ;; esac
						[ $newtargaddrnum -lt 0 ] && newtargaddrnum=0
						[ $newtargaddrnum -gt $saved_target_count_arr ] && newtargaddrnum=$saved_target_count_arr
						
						NEW_TARGET_MAC="${BT_TARGETS_SAVED_SORT[$newtargaddrnum]}"
						NEW_TARGET_MAC_NAME="${BT_TARGETS_SAVED[$NEW_TARGET_MAC]}"					
				
						if [[ "$scan_privacy" -eq 1 ]] ; then 
							priv_mac_save="$NEW_TARGET_MAC"
							NEW_TARGET_MAC="${NEW_TARGET_MAC:0:2}:░░:░░:░░:░░:░░"
							priv_name_save="$NEW_TARGET_MAC_NAME"
							NEW_TARGET_MAC_NAME="$priv_name_txt"
						fi
						resp=$(CONFIRMATION_DIALOG "Remove Saved ${text_target_UC} ${NEW_TARGET_MAC} - ${NEW_TARGET_MAC_NAME} ?")
						if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
							LOG green "${text_target_UC} Removed! - ${NEW_TARGET_MAC} - ${NEW_TARGET_MAC_NAME}"
							if [[ "$scan_privacy" -eq 1 ]] ; then NEW_TARGET_MAC="$priv_mac_save"; fi
							# remove lines that has mac first
							sed -i "/$NEW_TARGET_MAC/d" "$SAVEDTARGETS_FILE"
							unset BT_TARGETS_SAVED[$NEW_TARGET_MAC]
							LOG "Press OK to continue..."
							LOG " "
							WAIT_FOR_BUTTON_PRESS A
							sleep 0.25
							break
						else 
							LOG red "Skip ${text_target_UC}: ${NEW_TARGET_MAC}, selecting new..."
						fi
						sleep 0.5
					done
				else
					LOG "Skipped removing Saved ${text_target_UC}..."
				fi
			fi
		else
			LOG "Skipped viewing Saved ${text_target_UC}s..."
			LOG " "
		fi
	fi
}


# select target
select_target() {
	# local show_wait=0
	# if [[ "$select_target_go" -eq 1 ]] ; then
		# show_wait=1
	# fi
	select_target_go=0
	# count targets
	target_count="${#BT_TARGETS[@]}"
	target_count_arr=$(( ${#BT_TARGETS[@]} - 1 ))
	# check if targetlist is empty, only set per session/app run
	if [[ "${#BT_TARGETS[@]}" -eq 0 ]] ; then
		LOG red "No ${text_target_UC}s available yet."
		LOG red "Run Scan first to populate ${text_target_UC}s or set ${text_target_UC}."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.25
	else
		if [[ -n "$target_mac" ]]; then
			if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
			LOG green "========= Selected ${text_target_UC}: $target_mac ===="
			if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
			LOG red "Picking new ${text_target_UC} overwrites above selection."
		else
			LOG red "========================= No ${text_target_UC} Selected ===="
		fi
		LOG " "
		LOG green "${target_count} ${text_target_UC}s available for selection!"
		if [[ "$archCur" == "pager" ]] ; then
			if [[ "$target_count" -gt "$savedTargWarn" ]] ; then
				LOG magenta "====================================== WARNING =="
				LOG red     "${text_target_LC}s count is greater than ${savedTargWarn}!"
				LOG red     "Extra time needed to prepare full list!"
				LOG red     "Approx. 1 min for 1500 ${text_target_LC}s"
				LOG magenta "====================================== WARNING =="
			fi
			LOG "Press OK to confirm viewing ${text_target_UC}s..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.5
			resp=$(CONFIRMATION_DIALOG "Confirm viewing ${text_target_UC}s?")
		else
			resp='y'
		fi
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			# SHOW LIST FOR SELECTION IF CONFIRMED
			if [[ "$scan_stealth" -eq 0 ]] ; then LED RED SLOW; fi
			LOG "Loading ${text_target_UC}s for display..."
			LOG "Please wait..."
			# mac="$key"
			# name="${BT_NAMES[$mac]}"
			# comp="${BT_COMPS[$mac]}"
			# BT_TARGETS[$mac]="$name"
			# BT_TARGETS_SAVED_SORT[3]="11:11:11:11:11:11"
			
			# LOG "re-order" # sort
			tmpnum=0
			# A more robust approach using a while loop:
			while IFS= read -r line; do
				# Extract value and key from the line
				key=$(echo "$line" | cut -d' ' -f1)
				# value=$(echo "$line" | cut -d' ' -f2-)
				# LOG "reorder ${key}: ${value}"
				# LOG "reorder ${tmpnum}: ${key}"
				BT_TARGETS_SORT[$tmpnum]="$key"
				tmpnum=$((tmpnum + 1))
			done < <(
				for key in "${!BT_TARGETS[@]}"; do
					echo "$key"
				done | sort -n
			)
			# sort -rn for descending, sort -n for ascending
					
			# LOG "Sorting..."
			BT_TARGETS_SORT_FIN=( $(for key in "${!BT_TARGETS_SORT[@]}"; do echo "$key"; done | sort) )
			LOG "${text_target_UC}s loaded..."
			
			if [[ "$scan_stealth" -eq 0 ]] ; then LED MAGENTA; fi
			tmpnum=0
			viewall=0
			# Record each
			LOG blue "==================================== ${text_target_UC}s ===="
			for num in "${!BT_TARGETS_SORT_FIN[@]}"; do
				if [[ "$viewall" -eq 0 ]] ; then
					if (( num % 12 == 0 )) && (( num != 0 )); then
						# LOG "$number is divisible by 12 and is not 0."
						tmpnum=$((tmpnum + 1))
						if (( tmpnum % 5 == 0 )) && (( num != 0 )); then
							sleep 1
							resp=$(CONFIRMATION_DIALOG "Do you want to list ALL ${target_count} ${text_target_UC}s right now?")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								viewall=1
								sleep 0.25
							else 
								sleep 1
								resp=$(CONFIRMATION_DIALOG "Do you want to cancel loading the rest of ${text_target_UC}s?")
								if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
									LOG " "
									LOG "Cancelled loading rest of ${text_target_UC}s..."
									sleep 0.25
									break
								fi
								LOG blue "------------------- Press OK to view more... ----"
								WAIT_FOR_BUTTON_PRESS A
								sleep 0.25
							fi
						else
							LOG blue "------------------- Press OK to view more... ----"
							WAIT_FOR_BUTTON_PRESS A
							sleep 0.25
						fi
					fi
				fi
				targetlist_mac="${BT_TARGETS_SORT[$num]}"
				targetlist_name="${BT_NAMES[$targetlist_mac]}"
				if [[ -z "$targetlist_name" ]] ; then
					targetlist_name="${BT_TARGETS[$targetlist_mac]}"
				fi
				targetlist_comp="${BT_COMPS[$targetlist_mac]}"
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
				if [[ -z "$targetlist_name" ]] ; then
					targetlist_name="Unknown"
				fi
				if [[ "$scan_privacy" -eq 1 ]] ; then targetlist_mac="${targetlist_mac:0:2}:░░:░░:░░:░░:░░"; targetlist_name="$priv_name_txt"; targetlist_comp=""; fi
				LOG "${num}: ${targetlist_mac} - ${targetlist_name}${targetlist_comp}"
			done
			LOG blue "==================================== ${text_target_UC}s ===="
			
			LOG "Press OK to confirm selecting a ${text_target_UC}..."
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.5
			resp=$(CONFIRMATION_DIALOG "Confirm selecting ${text_target_UC}?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				# SHOW LIST FOR SELECTION IF CONFIRMED
				defaulttargaddrnum=0
				while true; do
					if [[ "$archCur" == "pager" ]] ; then
						LOG "Press OK to select a ${text_target_UC}..."
						LOG " "
						WAIT_FOR_BUTTON_PRESS A
					fi
					sleep 0.5
				
					newtargaddrnum=$(NUMBER_PICKER "${text_target_UC} Selection # (0-${target_count_arr})" $defaulttargaddrnum)
					case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) newtargaddrnum=$defaulttargaddrnum ;; esac
					[ $newtargaddrnum -lt 0 ] && newtargaddrnum=0
					[ $newtargaddrnum -gt $target_count_arr ] && newtargaddrnum=$target_count_arr
					
					NEW_TARGET_MAC="${BT_TARGETS_SORT[$newtargaddrnum]}"
					NEW_TARGET_MAC_NAME="${BT_NAMES[${NEW_TARGET_MAC}]}"
					if [[ -z "$NEW_TARGET_MAC_NAME" ]] ; then
						NEW_TARGET_MAC_NAME="${BT_TARGETS[$NEW_TARGET_MAC]}"
					fi
					NEW_TARGET_MAC_COMP="${BT_COMPS[${NEW_TARGET_MAC}]}"
					
					if [[ "$NEW_TARGET_MAC_COMP" == "n/a" ]] ; then
						NEW_TARGET_MAC_COMP=""
					else
						if [[ -z "$NEW_TARGET_MAC_NAME" || "$NEW_TARGET_MAC_NAME" == "Unknown" ]] ; then
							NEW_TARGET_MAC_NAME="$NEW_TARGET_MAC_COMP"
							NEW_TARGET_MAC_COMP=""
						else
							if [[ -n "$NEW_TARGET_MAC_COMP" ]] ; then
								NEW_TARGET_MAC_COMP="/$NEW_TARGET_MAC_COMP"
							fi
						fi
					fi
					NEW_TARGET_MAC_NAME="${NEW_TARGET_MAC_NAME}${NEW_TARGET_MAC_COMP}"
					if [[ -z "$NEW_TARGET_MAC_NAME" ]] ; then
						NEW_TARGET_MAC_NAME="Unknown"
					fi
					
					if [[ "$scan_privacy" -eq 1 ]] ; then 
						priv_mac_save="$NEW_TARGET_MAC"
						NEW_TARGET_MAC="${NEW_TARGET_MAC:0:2}:░░:░░:░░:░░:░░"
						priv_name_save="$NEW_TARGET_MAC_NAME"
						NEW_TARGET_MAC_NAME="$priv_name_txt"
					fi
					resp=$(CONFIRMATION_DIALOG "Accept new ${text_target_UC} ${NEW_TARGET_MAC} - ${NEW_TARGET_MAC_NAME} ?")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						if [[ "$scan_privacy" -eq 1 ]] ; then NEW_TARGET_MAC="$priv_mac_save"; fi
						target_mac="$NEW_TARGET_MAC"
						echo "$target_mac" > "$TARGETMAC_FILE"
						LOG green "New ${text_target_UC} Selected!"
						if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
						LOG magenta "===================================== ${text_target_UC} ===="
						LOG cyan "${text_target_UC} MAC: ${target_mac}"
						LOG cyan "Name/Company: ${NEW_TARGET_MAC_NAME}"
						LOG magenta "===================================== ${text_target_UC} ===="
						if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
						# if [[ "$show_wait" -eq 1 ]] ; then
						# 	LOG "Press OK to continue..."
						# 	LOG " "
						# 	WAIT_FOR_BUTTON_PRESS A
						# 	sleep 0.25
						# fi
						break
					else 
						LOG red "Skip ${text_target_UC}: ${NEW_TARGET_MAC}, selecting new..."
					fi
					sleep 0.5
				done
			else
				LOG "Skip selecting ${text_target_UC}..."
			fi
		else
			LOG "Skipped viewing ${text_target_UC}s..."
			LOG " "
		fi
	fi
}

# Remove Saved Targets by Custom OUI/Name
saved_target_remove_custom() {
	# LOG "Remove Saved by Custom OUI/Name...."	
	if [[ -s "$SAVEDTARGETS_FILE" ]]; then
		if [[ "$scan_privacy" -eq 1 ]] ; then 
			priv_mac_save="$custom_oui"
			custom_oui="HI:DD:EN"
			priv_name_save="$custom_name"
			custom_name="$priv_name_txt" 
		fi
		# Confirm remove saved targs via custom OUI/name
		resp=$(CONFIRMATION_DIALOG "Confirm Removing Saved ${text_target_UC}s by Custom OUI/Name?
		
Custom OUI: ${custom_oui}
Custom Name: ${custom_name}")
		if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; custom_name="$priv_name_save"; fi
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			# Enable case-insensitive matching
			shopt -s nocasematch
			linecountOrig=$(grep -c '.' "$SAVEDTARGETS_FILE")
			if [[ -n "$custom_oui" ]] ; then
				if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$custom_oui"; custom_oui="HI:DD:EN"; fi
				LOG "Removing Saved ${text_target_UC}s with OUI: \"${custom_oui}\"..."
				if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; fi
				# remove lines that start with custom_oui
				sed -i "/^$custom_oui/d" "$SAVEDTARGETS_FILE"
				# unset macs that match starting
				for mac in "${!BT_TARGETS_SAVED[@]}"; do
				  if [[ "$mac" == "$custom_oui"* ]]; then
					unset "BT_TARGETS_SAVED[$mac]"
				  fi
				done
				linecountNew=$(grep -c '.' "$SAVEDTARGETS_FILE")
				removedItems=$((linecountOrig - linecountNew))
				if [[ "$removedItems" -gt 0 ]] ; then
					LOG green "Removed $removedItems Saved ${text_target_UC}s matching Custom OUI!"
				else
					if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$custom_oui"; custom_oui="HI:DD:EN"; fi
					LOG red "No Saved ${text_target_UC}s matched Custom OUI: ${custom_oui}"
					if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; fi
				fi
				LOG "Press OK to continue..."
				LOG " "
				WAIT_FOR_BUTTON_PRESS A
				sleep 0.5
			fi
			linecountOrig=$(grep -c '.' "$SAVEDTARGETS_FILE")
			if [[ -n "$custom_name" ]] ; then
				if [[ "$scan_privacy" -eq 1 ]] ; then priv_name_save="$custom_name"; custom_name="$priv_name_txt"; fi
				LOG "Removing Saved ${text_target_UC}s with Name: \"${custom_name}\"..."
				if [[ "$scan_privacy" -eq 1 ]] ; then custom_name="$priv_name_save"; fi
				
				# custom_name='apple [tv] $test'
				# case insensitive sed not available
				# sed -i "/apple/Id" "$SAVEDTARGETS_FILE"
				# sed -i "/$custom_name/d" "$SAVEDTARGETS_FILE"
				# WORKS
				# sed -i '/[aA][pP][pP][lL][eE]/d' "$SAVEDTARGETS_FILE"
				formatted=""; # format string for regex matching, case insensitive
				for (( i=0; i<${#custom_name}; i++ )); do
					char="${custom_name:$i:1}"
					if [[ "$char" =~ ^[[:alpha:]]$ ]]; then
						# LOG "It is an alphabet character" # Append the character in [UpperLower] format
						formatted="${formatted}[${char,,}${char^^}]"
					else
						# LOG "NOT alphabet CHAR!!" # Append the character
						# check if char is sed metacharacter
						char=$(printf '%s' "$char" | sed 's/[[\\.*^$/]/\\&/g')
						formatted="${formatted}${char}"
					fi
				done
				# echo "Original: $custom_name"; echo "Formatted: $formatted"
				
				# remove lines that have custom_name
				sed -i "/$formatted/d" "$SAVEDTARGETS_FILE"
				
				# unset macs that match key in any sense
				for mac in "${!BT_TARGETS_SAVED[@]}"; do
				  if [[ "${BT_TARGETS_SAVED[$mac]}" == *"$custom_name"* ]]; then
					unset "BT_TARGETS_SAVED[$mac]"
				  fi
				done
				linecountNew=$(grep -c '.' "$SAVEDTARGETS_FILE")
				# removedItems=linecountOrig-linecountNew
				removedItems=$((linecountOrig - linecountNew))
				if [[ "$removedItems" -gt 0 ]] ; then
					LOG green "Removed $removedItems Saved ${text_target_UC}s matching Custom Name!"
				else
					if [[ "$scan_privacy" -eq 1 ]] ; then priv_name_save="$custom_name"; custom_name="$priv_name_txt"; fi
					LOG red "No Saved ${text_target_UC}s matched Custom Name: ${custom_name}"
					if [[ "$scan_privacy" -eq 1 ]] ; then custom_name="$priv_name_save"; fi
				fi
				LOG "Press OK to continue..."
				LOG " "
				WAIT_FOR_BUTTON_PRESS A
				sleep 0.5
			fi
			# check if saved targets are empty and clear file if so
			if [[ "${#BT_TARGETS_SAVED[@]}" -eq 0 ]] ; then
				rm "$SAVEDTARGETS_FILE" 2>/dev/null
				BT_TARGETS_SAVED=()
			fi
			# Disable case-insensitive matching to restore default behavior
			shopt -u nocasematch
		else
			LOG "Skip Remove ${text_target_UC}s Custom OUI/Name..."
		fi
	else
		LOG "Saved ${text_target_UC}s file empty!"
	fi
}


# saved targets archive
saved_targets_archive() {
	local savedTargsNew=""
	# check if file is not empty this time around
	if [[ -s "$SAVEDTARGETS_FILE" ]]; then
		resp=$(CONFIRMATION_DIALOG "Do you want to Save/Archive ALL ${#BT_TARGETS_SAVED[@]} Saved ${text_target_UC}s? ")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			# SAVEDTARGETS_FILE="$LOOT_TARGETS/SavedTargets.txt"
			sleep 1
			# ask for name to save, if no name set, use timestamp
			# only allow char and numerical
			resp=$(CONFIRMATION_DIALOG "Do you want to choose a suffix name for the Saved ${text_target_UC}s File?

Only alphanumeric characters allowed!

If no name is chosen, timestamp will be used as default.")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				sleep 1
				while true; do
					formatted=""; # format string to remove everything except num and char
					newname=$(TEXT_PICKER "Filename Suffix" "$formatted")
					# format name for filename usage
					for (( i=0; i<${#newname}; i++ )); do
						re='^[0-9]+$'
						char="${newname:$i:1}"
						if [[ "$char" =~ ^[[:alpha:]]$ || "$char" =~ $re ]]; then
							# LOG "It is an alphabet character or number" # Append the character
							formatted="${formatted}${char}"
						fi
					done
					# check if name has contents
					if [[ -n "$formatted" ]]; then
						savedTargsNew="$LOOT_TARGETS/SavedTargets_${formatted}.txt"
						# check if file is not empty this time around
						if [[ -s "$savedTargsNew" ]]; then
							LOG red "Filename already exists!"
							LOG red "SavedTargets_${formatted}.txt"
							LOG "Please input new..."
						else
							resp=$(CONFIRMATION_DIALOG "This Filename Suffix OK? ${formatted}
							
Filename: SavedTargets_${formatted}.txt")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								LOG cyan "Filename Suffix chosen: SavedTargets_${formatted}.txt"
								break
							fi
							LOG red "Skip Filename Suffix: ${formatted}, input new..."
						fi
					else
						resp=$(CONFIRMATION_DIALOG "Filename Suffix empty, use Timestamp as default?")
						if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
							TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
							LOG cyan "Name empty, use Timestamp as default"
							savedTargsNew="$LOOT_TARGETS/SavedTargets_${TIMESTAMP}.txt"
							break
						fi
						LOG red "Skip Blank/Timestamped Filename Suffix, input new..."
					fi
					sleep 1
				done
			else
				TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
				savedTargsNew="$LOOT_TARGETS/SavedTargets_${TIMESTAMP}.txt"
			fi
			sleep 1
			
			cp "$SAVEDTARGETS_FILE" "$savedTargsNew"
			LOG green "Saved ${text_target_UC}s File Archived!"
			LOG blue "=============================== Archive File ===="
			LOG "${text_target_UC} Count: ${#BT_TARGETS_SAVED[@]}"
			LOG "${savedTargsNew}"
			LOG blue "=============================== Archive File ===="
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.5
			resp=$(CONFIRMATION_DIALOG "Do you want to CLEAR ALL Saved ${text_target_UC}s now? ")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				saved_targets_clear
			else
				LOG "Skipped Clear Saved ${text_target_UC}s..."
				LOG " "
			fi
		else
			LOG "Skipped Save/Archive Saved ${text_target_UC}s File..."
			LOG " "
		fi
	else
		LOG "Saved ${text_target_UC}s File Empty..."
		LOG " "
	fi
}

# saved targets saveload
saved_targets_saveload() {
	# check if file is not empty this time around
	if [[ -s "$SAVEDTARGETS_FILE" ]]; then
		resp=$(CONFIRMATION_DIALOG "Do you want to Save/Archive Saved ${text_target_UC}s? ")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			saved_targets_archive
		fi
	else
		LOG "Saved ${text_target_UC}s File Empty..."
		LOG " "
	fi
	sleep 1
	resp=$(CONFIRMATION_DIALOG "Do you want to Load a Saved ${text_target_UC}s File? ")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		sleep 1
		# Find all Archive files
		local unsfiles=($(find "$LOOT_TARGETS" -name "SavedTargets_*" 2>/dev/null))
		# sort file list
		local files=($(printf '%s\n' "${unsfiles[@]}" | sort -n))
		unset unsfiles

		if [[ "${#files[@]}" -gt 0 ]] ; then
			local LIST_STR=""
			local count=1
			LOG "Archive Saved ${text_target_UC}s Files:"
			LOG blue "============================== Archive Files ===="
			for d in "${files[@]}"; do
				# tell how many targets per file
				LOG "${count}: $(basename ${d}) (${text_target_UC}s: $(grep -c '.' "${d}"))"
				count=$((count + 1))
			done
			LOG blue "============================== Archive Files ===="
			# confirm it will overwrite current saved targets/file
			LOG magenta "WARNING:"
			LOG magenta "Loading an Archive File will overwrite current Saved ${text_target_UC}s File!"
			if [[ "$archCur" == "pager" ]] ; then
				LOG "Press OK to continue..."
				LOG " "
				WAIT_FOR_BUTTON_PRESS A
			fi
			sleep 0.5
			
			resp=$(CONFIRMATION_DIALOG "Confirm choosing to Load a Saved ${text_target_UC}s File? ")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				local filenumsel=0
				local boolcheckval="false"
				local loopcount=0
				#LOG "BEFORE WHILE boolcheckval: $boolcheckval"
				if [[ "$archCur" == "pager" ]] ; then
					LOG "Press OK when ready to select file to load..."
					WAIT_FOR_BUTTON_PRESS A
				fi
				while [ "$boolcheckval" != "true" ]; do
					#LOG "boolcheckval: $boolcheckval"
					if [ "$boolcheckval" != "true" ]; then
					
						if [[ "$archCur" == "pager" ]] ; then
							if [ "$loopcount" -gt 0 ]; then
								LOG " ^ Scroll UP for Files, or Press OK when ready"
								WAIT_FOR_BUTTON_PRESS A
							fi
						fi
						loopcount=$((loopcount + 1))
						filenumsel=$(NUMBER_PICKER "Select a File number" "1")
						
						if [ "$filenumsel" -gt 0 ]; then
							#CHECK IF FILE IS VALID
							if [[ -v 'files[$filenumsel-1]' ]]; then
								#LOG "Index '$filenumsel' is set."
								SELECTED_FILE="${files[$filenumsel-1]}"
								resp=$(CONFIRMATION_DIALOG "Confirm loading Saved ${text_target_UC}s File? $(basename $SELECTED_FILE) 
								
New ${text_target_UC}s: $(grep -c '.' "${SELECTED_FILE}") ")
								if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
									LOG blue "================================ Chosen File ===="
									LOG "$(basename $SELECTED_FILE)"
									LOG green "New ${text_target_UC}s: $(grep -c '.' "${SELECTED_FILE}")"
									LOG blue "================================ Chosen File ===="
									boolcheckval="true"
								else
									LOG red "Skipped Loading '$(basename $SELECTED_FILE)'..."
									LOG " "
								fi
							else
								LOG red "File number '$filenumsel' does not exist, try again."
							fi
						fi						
						sleep 1
						#LOG "boolcheckval FIN: $boolcheckval"
					fi
				done
				if [[ "$archCur" == "pager" ]] ; then
					LOG "Press OK to continue..."
					LOG " "
					WAIT_FOR_BUTTON_PRESS A
				fi
				sleep 0.5
					
				resp=$(CONFIRMATION_DIALOG "FINAL: Confirm loading Saved ${text_target_UC}s File? $(basename $SELECTED_FILE) 
				
${text_target_UC}s: $(grep -c '.' "${SELECTED_FILE}")
				
This will OVERWRITE your current Saved ${text_target_UC}s file and then load the New ${text_target_UC}s. ")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					sleep 1
					# then saved targets from the new file will be loaded in
					cp "$SELECTED_FILE" "$SAVEDTARGETS_FILE"
					LOG green "Saved ${text_target_UC}s File Loaded!"
					LOG blue "============================== ${text_target_UC} Counts ===="
					LOG magenta "Previous ${text_target_UC} Count: ${#BT_TARGETS_SAVED[@]}"
					LOG green "New ${text_target_UC} Count: $(grep -c '.' "${SELECTED_FILE}")"
					LOG blue "============================== ${text_target_UC} Counts ===="
					LOG "Loading New ${text_target_UC}s..."
					LOG blue "================================================="
					sleep 0.5
					saved_targets_check
				else
					LOG "Skipped Loading '$(basename $SELECTED_FILE)'..."
					LOG " "
				fi
			else
				LOG "Skipped Load Saved ${text_target_UC}s File..."
				LOG " "
			fi			
		else
			LOG red "No Archive Saved ${text_target_UC}s Files Found!"
			LOG " "
		fi
	else
		LOG "Skipped Load Saved ${text_target_UC}s File..."
		LOG " "
	fi
}



# check settings
settings_check() {
	# check values of settings
	if [[ "$DATA_SCAN_SECONDS" -gt 2 ]]; then
		if [[ "$DATA_SCAN_SECONDS" -gt 20 ]]; then
			DATA_SCAN_SECONDS=7
		fi
	else
		DATA_SCAN_SECONDS=7
	fi
	if [[ "$scan_btle" == "true" ]]; then scan_btle="true"; else scan_btle="false"; fi
	if [[ "$scan_btclassic" == "true" ]]; then scan_btclassic="true"; else scan_btclassic="false"; fi
	if [[ "$scan_infrepeat" -eq 1 ]]; then scan_infrepeat=1; else scan_infrepeat=0; fi
	if [[ "$scan_mute" == "true" ]]; then scan_mute="true"; else scan_mute="false"; fi
	if [[ "$scan_debug" == "true" ]] ; then scan_debug="true"; else scan_debug="false"; fi
	if [[ "$skip_ask_1st_scan" -eq 1 ]]; then skip_ask_1st_scan=1; else skip_ask_1st_scan=0; fi
	if [[ "$skip_ask_ringtones" -eq 1 ]]; then skip_ask_ringtones=1; else skip_ask_ringtones=0; fi
	
	if [[ "$filter_multilocal" -eq 1 ]]; then filter_multilocal=1; else filter_multilocal=0; fi
	if [[ "$filter_randomall" -eq 1 ]]; then filter_randomall=1; else filter_randomall=0; fi
	if [[ "$filter_localall" -eq 1 ]]; then filter_localall=1; else filter_localall=0; fi
	if [[ "$filter_multiall" -eq 1 ]]; then filter_multiall=1; else filter_multiall=0; fi
	if [[ "$filter_emptyoui" -eq 1 ]]; then filter_emptyoui=1; else filter_emptyoui=0; fi
	
	if [[ "$scan_friendly" -eq 0 ]]; then
		text_hunt_UC="Hunt"
		text_hunt_LC="hunt"
		text_target_UC="Target"
		text_target_LC="target"
	else
		text_hunt_UC="Find"
		text_hunt_LC="find"
		text_target_UC="Device"
		text_target_LC="device"
	fi
	
	if [[ "$archCur" == "pager" ]] ; then
		btn_a_path="/sys/devices/platform/leds/leds/a-button-led/brightness"
		btn_b_path="/sys/devices/platform/leds/leds/b-button-led/brightness"
		if [[ "$scan_stealth" -eq 1 ]]; then
			LED OFF
			echo 0 > "$btn_a_path"
			echo 0 > "$btn_b_path"
		else
			LED MAGENTA
			echo 1 > "$btn_a_path"
			echo 1 > "$btn_b_path"
		fi
	fi
}

# configuration check to see if no config set but config avail
config_check() {
	# LOG "config_check"
	local re='^[0-9]+$'
	local total_scans_check=0
	# check if file is not empty this time around
	if [[ -s "$SAVEDCONFIG_FILE" ]]; then
		line=$(jq -r '.total_scans' "$SAVEDCONFIG_FILE") # check if num
		# echo "total_scans" # check if num
		if [[ "$line" =~ $re ]] ; then total_scans_check="$line"; fi
		
		# check if cfg set but data not presently loaded
		if [[ "$total_scans" -eq 0 && "$total_scans_check" -gt 0 ]] ; then
			# found data mismatch, ask if user wants to restore previous settings/statistics?
			# resp=$(CONFIRMATION_DIALOG "Config/History Backup Exists, but not loaded or recent firmware update has cleared all saved Configuration & History data! Confirm Load of Previous Config/History?")
			# if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				silent_backup=1
				config_restore
				silent_backup=0
			# else LOG "Configuration Restore skipped..."; fi
		fi
	fi
}

# configuration reader
config_read() {
	local line=""; local lineCk=""; local re='^[0-9]+$'
	line=$(jq -r '.DATA_SCAN_SECONDS' "$SAVEDCONFIG_FILE") # check if num
	if [[ "$line" =~ $re && "$line" -gt 1 ]] ; then DATA_SCAN_SECONDS="$line"; else DATA_SCAN_SECONDS=7; fi
	line=$(jq -r '.scan_btle' "$SAVEDCONFIG_FILE") # check if true
	if [[ "$line" == "true" ]]; then scan_btle="true"; else scan_btle="false"; fi
	line=$(jq -r '.scan_btclassic' "$SAVEDCONFIG_FILE") # check if true
	if [[ "$line" == "true" ]]; then scan_btclassic="true"; else scan_btclassic="false"; fi
	line=$(jq -r '.scan_infrepeat' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then scan_infrepeat=1; else scan_infrepeat=0; fi
	
	line=$(jq -r '.scan_mute' "$SAVEDCONFIG_FILE") # check if true
	if [[ "$line" == "true" ]]; then scan_mute="true"; else scan_mute="false"; fi
	line=$(jq -r '.scan_debug' "$SAVEDCONFIG_FILE") # check if true
	if [[ "$line" == "true" ]]; then scan_debug="true"; else scan_debug="false"; fi
	line=$(jq -r '.scan_privacy' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then scan_privacy=1; else scan_privacy=0; fi
	line=$(jq -r '.scan_friendly' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then scan_friendly=1; else scan_friendly=0; fi
	
	line=$(jq -r '.scan_stealth' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then scan_stealth=1; else scan_stealth=0; fi
	line=$(jq -r '.skip_ask_1st_scan' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then skip_ask_1st_scan=1; else skip_ask_1st_scan=0; fi
	line=$(jq -r '.skip_ask_ringtones' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then skip_ask_ringtones=1; else skip_ask_ringtones=0; fi
	line=$(jq -r '.selnum_main' "$SAVEDCONFIG_FILE")
	if [[ "$line" =~ $re && "$line" -gt 0 ]] ; then selnum_main="$line"; else selnum_main=1; fi
	
	line=$(jq -r '.filter_multilocal' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then filter_multilocal=1; else filter_multilocal=0; fi
	line=$(jq -r '.filter_randomall' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then filter_randomall=1; else filter_randomall=0; fi
	line=$(jq -r '.filter_localall' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then filter_localall=1; else filter_localall=0; fi
	line=$(jq -r '.filter_multiall' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then filter_multiall=1; else filter_multiall=0; fi
	line=$(jq -r '.filter_emptyoui' "$SAVEDCONFIG_FILE")
	if [[ "$line" -eq 1 ]] ; then filter_emptyoui=1; else filter_emptyoui=0; fi
	
	line=$(jq -r '.total_scans' "$SAVEDCONFIG_FILE") # check if num
	if [[ "$line" =~ $re && "$line" -gt 0 ]] ; then total_scans="$line"; else total_scans=0; fi
	line=$(jq -r '.total_detected' "$SAVEDCONFIG_FILE") # check if num
	if [[ "$line" =~ $re && "$line" -gt 0 ]] ; then total_detected="$line"; else total_detected=0; fi
	line=$(jq -r '.total_scan_min' "$SAVEDCONFIG_FILE") # check if num
	if [[ "$line" =~ $re && "$line" -gt 0 ]] ; then total_scan_min="$line"; else total_scan_min=0; fi
	
	line=$(jq -r '.custom_oui' "$SAVEDCONFIG_FILE") # check oui format
	lineCk="${line}:00:00:00"
	if [[ "$lineCk" =~ $VALID_MAC ]]; then custom_oui="$line"; else custom_oui=""; fi
	line=$(jq -r '.custom_name' "$SAVEDCONFIG_FILE")
	custom_name="$line"
}

# configuration backup
config_backup() {
	# LOG "config_backup"
	local confirmFile=0
	if [[ "$silent_backup" -eq 0 ]] ; then
		# check if file is not empty this time around
		if [[ -s "$SAVEDCONFIG_FILE" ]]; then
			# file exists, has contents, confirm overwrite
			resp=$(CONFIRMATION_DIALOG "Config Backup Exists!
			
Confirm Overwrite?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				confirmFile=1
			else
				LOG "Configuration Backup skipped..."
			fi
		else
			confirmFile=1 # file empty, proceed to create
		fi
	else confirmFile=1; fi
	if [[ "$confirmFile" -eq 1 ]]; then
		if [[ "$silent_backup" -eq 0 ]] ; then LOG "Configuration Backup started..."; fi
		# Create JSON file using jq
		jq -n \
		  --argjson val_DATA_SCAN_SECONDS "$DATA_SCAN_SECONDS" \
		  --arg val_scan_btle "$scan_btle" \
		  --arg val_scan_btclassic "$scan_btclassic" \
		  --argjson val_scan_infrepeat "$scan_infrepeat" \
		  --arg val_scan_mute "$scan_mute" \
		  --arg val_scan_debug "$scan_debug" \
		  --argjson val_scan_privacy "$scan_privacy" \
		  --argjson val_scan_friendly "$scan_friendly" \
		  --argjson val_scan_stealth "$scan_stealth" \
		  --argjson val_skip_ask_1st_scan "$skip_ask_1st_scan" \
		  --argjson val_skip_ask_ringtones "$skip_ask_ringtones" \
		  --argjson val_selnum_main "$selnum_main" \
		  --argjson val_filter_multilocal "$filter_multilocal" \
		  --argjson val_filter_randomall "$filter_randomall" \
		  --argjson val_filter_localall "$filter_localall" \
		  --argjson val_filter_multiall "$filter_multiall" \
		  --argjson val_filter_emptyoui "$filter_emptyoui" \
		  --argjson val_total_scans "$total_scans" \
		  --argjson val_total_detected "$total_detected" \
		  --argjson val_total_scan_min "$total_scan_min" \
		  --arg val_custom_oui "$custom_oui" \
		  --arg val_custom_name "$custom_name" \
		  '{DATA_SCAN_SECONDS: $val_DATA_SCAN_SECONDS, scan_btle: $val_scan_btle, scan_btclassic: $val_scan_btclassic, scan_infrepeat: $val_scan_infrepeat, scan_mute: $val_scan_mute, scan_debug: $val_scan_debug, scan_privacy: $val_scan_privacy, scan_friendly: $val_scan_friendly, scan_stealth: $val_scan_stealth, skip_ask_1st_scan: $val_skip_ask_1st_scan, skip_ask_ringtones: $val_skip_ask_ringtones, selnum_main: $val_selnum_main, filter_multilocal: $val_filter_multilocal, filter_randomall: $val_filter_randomall, filter_localall: $val_filter_localall, filter_multiall: $val_filter_multiall, filter_emptyoui: $val_filter_emptyoui, total_scans: $val_total_scans, total_detected: $val_total_detected, total_scan_min: $val_total_scan_min, custom_oui: $val_custom_oui, custom_name: $val_custom_name}' > "$SAVEDCONFIG_FILE"
		if [[ "$silent_backup" -eq 0 ]] ; then LOG green "Configuration Backup complete!"; fi
	fi
	if [[ "$silent_backup" -eq 0 ]] ; then LOG " "; fi
}

# configuration restore
config_restore() {
	# LOG "config_restore"
	# check if file is not empty this time around
	if [[ -s "$SAVEDCONFIG_FILE" ]]; then
		if [[ "$silent_backup" -eq 0 ]] ; then LOG "Reading Configuration..."; fi
		config_read
		if [[ "$silent_backup" -eq 0 ]] ; then LOG "Restoring Configuration..."; fi
		# restore config
		PAYLOAD_SET_CONFIG bluepinesuite DATA_SCAN_SECONDS "$DATA_SCAN_SECONDS"
		PAYLOAD_SET_CONFIG bluepinesuite scan_btle "$scan_btle"
		PAYLOAD_SET_CONFIG bluepinesuite scan_btclassic "$scan_btclassic"
		PAYLOAD_SET_CONFIG bluepinesuite scan_infrepeat "$scan_infrepeat"
		
		PAYLOAD_SET_CONFIG bluepinesuite scan_mute "$scan_mute"
		PAYLOAD_SET_CONFIG bluepinesuite scan_debug "$scan_debug"
		PAYLOAD_SET_CONFIG bluepinesuite scan_privacy "$scan_privacy"
		PAYLOAD_SET_CONFIG bluepinesuite scan_friendly "$scan_friendly"
		
		PAYLOAD_SET_CONFIG bluepinesuite scan_stealth "$scan_stealth"
		PAYLOAD_SET_CONFIG bluepinesuite skip_ask_1st_scan "$skip_ask_1st_scan"
		PAYLOAD_SET_CONFIG bluepinesuite skip_ask_ringtones "$skip_ask_ringtones"
		PAYLOAD_SET_CONFIG bluepinesuite selnum_main "$selnum_main"
		
		PAYLOAD_SET_CONFIG bluepinesuite filter_multilocal "$filter_multilocal"
		PAYLOAD_SET_CONFIG bluepinesuite filter_randomall "$filter_randomall"
		PAYLOAD_SET_CONFIG bluepinesuite filter_localall "$filter_localall"
		PAYLOAD_SET_CONFIG bluepinesuite filter_multiall "$filter_multiall"
		PAYLOAD_SET_CONFIG bluepinesuite filter_emptyoui "$filter_emptyoui"
		
		PAYLOAD_SET_CONFIG bluepinesuite total_scans "$total_scans"
		PAYLOAD_SET_CONFIG bluepinesuite total_detected "$total_detected"
		PAYLOAD_SET_CONFIG bluepinesuite total_scan_min "$total_scan_min"
		
		PAYLOAD_SET_CONFIG bluepinesuite custom_oui "$custom_oui"
		PAYLOAD_SET_CONFIG bluepinesuite custom_name "$custom_name"
		# check settings
		settings_check
		if [[ "$silent_backup" -eq 0 ]] ; then LOG green "Configuration Backup restored!"; fi
	else
		LOG red "ERROR: Configuration Backup missing!"
	fi
	if [[ "$silent_backup" -eq 0 ]] ; then LOG " "; fi
}

# start cancel Scan
start_cancelscan() {
	echo " ---- Cancel Pressed! Please wait..."
	printf "(BTN_EAST), value 1\n" >> "$KEYCKTMP_FILE"
}

# start key check collection
start_evtest() {
	# pager device input = /dev/input/event0
	# LOG "start evtest"
	# timeout not working on evtest?
	# (timeout --signal=SIGINT 999s evtest /dev/input/event0 | grep "^Event:" &> "$KEYCKTMP_FILE") &
	# (evtest /dev/input/event0 | grep "^Event:" &> "$KEYCKTMP_FILE") &
	
	# wrap the command in a second subshell and redirect its output to hide job ID and PID
	if [[ "$archCur" == "pager" ]] ; then
		((evtest /dev/input/event0 | grep "^Event:" &> "$KEYCKTMP_FILE") &) > /dev/null 2>&1
	else 
		trap start_cancelscan SIGINT
	fi
}

# check pause/cancel
check_cancel() {
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
		cancel_press=1
		# if cancel_press=1 then prompt asking if they actually want to cancel.
		LOG blue "================================================="
		LOG "Pausing..."
		LOG "Pausing..."
		LOG "Pausing..."
		LOG blue "================================================="
		sleep 4
		# Confirm Cancel
		resp=$(CONFIRMATION_DIALOG "PAUSED! Cancel further scanning?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			cancel_app=1
			cancel_press=0
			trap cleanup SIGINT
		else 
			sleep 1
			# restart evtest
			start_evtest
			cancel_app=0
			cancel_press=0
			LOG blue "-------------------------------------------"
			LOG cyan "|- Signal -| -- MAC Address -- - Name/Manuf"
			LOG blue "-------------------------------------------"
		fi
	else
		# LOG "not found, empty file"
		# empty file
		:> "$KEYCKTMP_FILE"
	fi
}

# make sure target mac is set when it needs to be
target_mac_check() {
	if [[ -z "$target_mac" ]]; then
		ERROR_DIALOG "Target Mac NOT SET when it should be!"
		# LOG red "ERROR: Target Mac not set while it should be!"
		LOG red "Exiting..."
		LOG " "
		exit 1
	fi
}





# working on BT speaker
bt_browse_services() {
	target_mac_check
	local service_count=0
	local output=""
	local tmpcheck=""
	# LOG "bt_browse_services"
	# sdptool browse $target_mac
	if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
	resp=$(CONFIRMATION_DIALOG "Confirm SDP Browse on ${target_mac} ?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
	
		LOG green "Starting SDP Browse on ${target_mac}..."
		LOG "Please wait..."
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
		
		# check if file is not empty this time around
		if [[ -s "$REPORT_PROBE_FILE" ]]; then # has contents
			printf "\n\n\n" >> "$REPORT_PROBE_FILE"
		fi
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		REPORT_PROBE_TMP="$LOOT_PROBE/Probe_TMP.txt"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "  Bluetooth Probe - SDP Browse Report\n" >> "$REPORT_PROBE_FILE"
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_PROBE_FILE"
		printf "  Target MAC: %s\n" "${target_mac}" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "%s - EVENT: Start SDP Browse\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		# REPORT_PROBE_TMP="tmp.txt"
		timeout 10s sdptool -i $BLE_IFACE browse "$target_mac" 2>&1 > "$REPORT_PROBE_TMP"
		# Browsing $target_mac ...
		# Failed to connect to SDP server on ${target_mac}: Host is down
		output="$(< "$REPORT_PROBE_TMP")"
		if [[ "$output" == "Browsing $target_mac ..." ]] ; then
			LOG magenta "Browse empty, trying records..."
			timeout 10s sdptool -i $BLE_IFACE records "$target_mac" 2>&1 > "$REPORT_PROBE_TMP"
			output="$(< "$REPORT_PROBE_TMP")"
		fi
		LOG blue "===================================== Output ===="
		tmpcheck=$(grep "Failed to connect to SDP server on" "$REPORT_PROBE_TMP")
		if [[ -n "$tmpcheck" ]] ; then
			LOG red "Failed to connect..."
			printf "Failed to connect...\n" >> "$REPORT_PROBE_FILE"
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
			printf "Output:\n%s\n" "$output" >> "$REPORT_PROBE_FILE"
			LOG blue "===================================== Output ===="
			if [[ "$scan_privacy" -eq 1 ]] ; then output="$priv_name_txt"; fi
			LOG "$output"
		else
			# check service names
			tmpcheck=$(grep "Service Name:" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG blue "==== Services Found ============================="
				LOG "$tmpcheck"
				LOG " "
				printf "Services Found:\n%s\n" "${tmpcheck}" >> "$REPORT_PROBE_FILE"
			fi
			# check PSM values
			tmpcheck=$(grep -m 1 "0x0001" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				# echo "tmpck: $tmpcheck"
				LOG "SDP 0x0001 (Service Discovery) Found!"
				printf "SDP 0x0001 (Service Discovery) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x0003" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "RFCOMM 0x0003 (Serial Emulation) Found!"
				printf "RFCOMM 0x0003 (Serial Emulation) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x0005" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "TCS-BIN 0x0005 (Telephony) Found!"
				printf "TCS-BIN 0x0005 (Telephony) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x0007" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "TCS-BIN-CORDLESS 0x0007 (Telephony) Found!"
				printf "TCS-BIN-CORDLESS 0x0007 (Telephony) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x000F" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "BNEP 0x000F (BT Network Protocol) Found!"
				printf "BNEP 0x000F (BT Network Protocol) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x0011" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "HIDP 0x0011 (HID Profile Interrupt) Found!"
				printf "HIDP 0x0011 (HID Profile Interrupt) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x0013" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "HIDP 0x0013 (HID Profile Control) Found!"
				printf "HIDP 0x0013 (HID Profile Control) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			# LOG "GOT HERE"
			tmpcheck=$(grep -m 1 "0x0017" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "AVCTP 0x0017 (A/V Control Protocol) Found!"
				printf "AVCTP 0x0017 (A/V Control Protocol) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x0019" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "AVDTP 0x0019 (A/V Dist Protocol) Found!"
				printf "AVDTP 0x0019 (A/V Dist Protocol) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x001B" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "GNSS 0x001B (Global Nav Sat System) Found!"
				printf "GNSS 0x001B (Global Nav Sat System) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x001D" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "UDI 0x001D (Unrestricted Digital) Found!"
				printf "UDI 0x001D (Unrestricted Digital) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			tmpcheck=$(grep -m 1 "0x001F" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "AvrcpBrowse 0x001F (A/V Remote) Found!"
				printf "AvrcpBrowse 0x001F (A/V Remote) Found!\n" >> "$REPORT_PROBE_FILE"
				service_count=$((service_count + 1))
			fi
			
			if [[ "$service_count" -gt 0 ]] ; then
				LOG " "
				LOG "$service_count Service PSM's found..."
				printf "%s Service PSM's found...\n" "$service_count" >> "$REPORT_PROBE_FILE"
			else
				LOG red "No Service PSM's found..."
				printf "No Service PSM's found...\n" >> "$REPORT_PROBE_FILE"
			fi
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
			printf "Output:\n%s\n" "$output" >> "$REPORT_PROBE_FILE"
		fi
		LOG blue "===================================== Output ===="
		
		rm "$REPORT_PROBE_TMP" 2>/dev/null
		
		sleep 0.5
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "%s - EVENT: Complete SDP Browse\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "Completed SDP Browse on %s\n" "${target_mac}" >> "$REPORT_PROBE_FILE"
		printf "Results saved to: %s" "${REPORT_PROBE_FILE}" >> "$REPORT_PROBE_FILE"
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
		LOG green "Completed SDP Browse on ${target_mac}..."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.25
	else 
		LOG "Skip SDP Browse on ${target_mac}..."
	fi
	if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
}

# working on BT speaker
bt_get_info() {
	target_mac_check
	local name=""
	local output=""
	local tmpcheck=""
	# LOG "bt_get_info"
	# hcitool -i hci1 info $target_mac
	if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
	resp=$(CONFIRMATION_DIALOG "Confirm Get Info on ${target_mac} ?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		LOG green "Starting Get Info on ${target_mac}..."
		LOG "Please wait..."
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
		
		# check if file is not empty this time around
		if [[ -s "$REPORT_PROBE_FILE" ]]; then # has contents
			printf "\n\n\n" >> "$REPORT_PROBE_FILE"
		fi
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		REPORT_PROBE_TMP="$LOOT_PROBE/Probe_TMP.txt"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "  Bluetooth Probe - Get Info Report\n" >> "$REPORT_PROBE_FILE"
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_PROBE_FILE"
		printf "  Target MAC: %s\n" "${target_mac}" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "%s - EVENT: Start Get Info\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		timeout 10s hcitool -i $BLE_IFACE info "$target_mac" > "$REPORT_PROBE_TMP"
		output="$(< "$REPORT_PROBE_TMP")"
		
		LOG blue "===================================== Output ===="
		# Requesting information ... Can't create connection: I/O error
		if echo "$output" | grep -q "create connection: I/O error" || [[ "$output" == "Requesting information ..." ]] ; then
			LOG red "Failed to connect..."
			printf "Failed to connect...\n" >> "$REPORT_PROBE_FILE"
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
			printf "Output:\n%s\n" "$output" >> "$REPORT_PROBE_FILE"
			LOG blue "===================================== Output ===="
			if [[ "$scan_privacy" -eq 1 ]] ; then output="$priv_name_txt"; fi
			LOG "$output"
		else
			printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
			printf "Output:\n%s\n" "$output" >> "$REPORT_PROBE_FILE"
			tmpcheck=$(grep "Device Name:" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "$tmpcheck"
				printf "%s\n" "${tmpcheck}" >> "$REPORT_PROBE_FILE"
				name=$(echo "${tmpcheck}" | grep -oP '(?<=Device Name:).*' || echo "Unknown")
				# check if key exists, even if empty
				if [[ -v BT_TARGETS[$target_mac] ]]; then
					# only update if name empty/unknown
					nameck="${BT_TARGETS[$target_mac]}"
					if [[ -n "$name" && "$name" != "Unknown" && "$nameck" == "Unknown" ]] ; then
						BT_TARGETS[$target_mac]="$name"
					fi
				fi
				# check if key exists, even if empty
				if [[ -v BT_TARGETS_SAVED[$target_mac] ]]; then
					# only update if name empty/unknown
					nameck="${BT_TARGETS_SAVED[$target_mac]}"
					if [[ -n "$name" && "$name" != "Unknown" && "$nameck" == "Unknown" ]] ; then
						BT_TARGETS_SAVED[$target_mac]="$name"
						# remove lines that has mac first
						sed -i "/$target_mac/d" "$SAVEDTARGETS_FILE"
						printf "%s %s\n" "${target_mac}" "${name}" >> "$SAVEDTARGETS_FILE"
					fi
				fi
			fi
			# LOG "GOT HERE"
			tmpcheck=$(grep "LMP Version:" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "$tmpcheck"
				printf "%s\n" "${tmpcheck}" >> "$REPORT_PROBE_FILE"
			fi
			tmpcheck=$(grep "Manufacturer:" "$REPORT_PROBE_TMP")
			if [[ -n "$tmpcheck" ]] ; then
				LOG "$tmpcheck"
				printf "%s\n" "${tmpcheck}" >> "$REPORT_PROBE_FILE"
			fi
		fi
		LOG blue "===================================== Output ===="
		
		rm "$REPORT_PROBE_TMP" 2>/dev/null
		
		sleep 0.1
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "%s - EVENT: Complete Get Info\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "Completed Get Info on %s\n" "${target_mac}" >> "$REPORT_PROBE_FILE"
		printf "Results saved to: %s" "${REPORT_PROBE_FILE}" >> "$REPORT_PROBE_FILE"
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
		LOG green "Completed Get Info on ${target_mac}..."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.25
	else 
		LOG "Skip Get Info on ${target_mac}..."
	fi
	if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
}

# working in general
bt_get_vendor() {
	# LOG "bt_get_vendor"
	# /lib/hak5/oui.txt
	local ouifile="/lib/hak5/oui.txt"
	if [[ "$archCur" != "pager" ]] ; then
		ouifile="/var/lib/ieee-data/oui.txt"
	fi
	target_mac_check
	if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
	resp=$(CONFIRMATION_DIALOG "Confirm Get Vendor on ${target_mac} ?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
		target_oui="${target_mac:0:8}"
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
		LOG green "Starting Get Vendor on ${target_mac}..."
		
		# check if file is not empty this time around
		if [[ -s "$REPORT_PROBE_FILE" ]]; then # has contents
			printf "\n\n\n" >> "$REPORT_PROBE_FILE"
		fi
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "  Bluetooth Probe - Get Vendor Report\n" >> "$REPORT_PROBE_FILE"
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_PROBE_FILE"
		printf "  Target OUI: %s\n" "${target_oui}" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "%s - EVENT: Start Get Vendor\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		
		LOG blue "===================================== Output ===="
		if target_oui_line=$(grep -E "$target_oui" "$ouifile"); then
			# replace OUI in line
			target_oui_vendor="${target_oui_line/$target_oui/}"
			if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
			printf "Target OUI: %s\nMAC: %s\nVendor: %s\n" "$target_oui" "$target_mac" "$target_oui_vendor" >> "$REPORT_PROBE_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then target_oui="${target_oui:0:5}:░░"; target_oui_vendor="$priv_name_txt"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
			LOG  "= ${text_target_UC} OUI: $target_oui = MAC: $target_mac ="
			LOG blue "==== Vendor ====================================="
			LOG magenta "$target_oui_vendor"
		else
			printf "Vendor for OUI: %s not found...\n" "$target_oui" >> "$REPORT_PROBE_FILE"
			if [[ "$scan_privacy" -eq 1 ]] ; then target_oui="${target_oui:0:5}:░░"; fi
			LOG red "Vendor for OUI: $target_oui not found..."
		fi
		LOG blue "===================================== Output ===="
		sleep 0.1
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; target_oui="${target_mac:0:8}"; fi
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "%s - EVENT: Complete Get Vendor\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "Completed Get Vendor on %s\n" "${target_mac}" >> "$REPORT_PROBE_FILE"
		printf "Results saved to: %s" "${REPORT_PROBE_FILE}" >> "$REPORT_PROBE_FILE"
		LOG green "Completed Get Vendor..."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.25
	else 
		LOG "Skip Get Vendor on ${target_mac}..."
	fi
	if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
}


# verify connection
bt_verif_conn() {
	# LOG "bt_verif_conn"
	local connMade=0
	local skipRest=0
	local output=""
	target_mac_check
	if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
	resp=$(CONFIRMATION_DIALOG "Confirm Verify ${text_target_UC} Connection on ${target_mac} ?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		LOG green "Starting Verify Connection on ${target_mac}..."
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
		
		# check if file is not empty this time around
		if [[ -s "$REPORT_PROBE_FILE" ]]; then # has contents
			printf "\n\n\n" >> "$REPORT_PROBE_FILE"
		fi
		TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "  Bluetooth Probe - Verify Connection Report\n" >> "$REPORT_PROBE_FILE"
		printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_PROBE_FILE"
		printf "  Target MAC: %s\n" "${target_mac}" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "%s - EVENT: Start Verify Connection\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		# -c = connect infinitely, -s = connect and send
		# -n = connect and be silent
		# target_mac=""; BLE_IFACE="hci1"; timeout 10s l2test -c -i $BLE_IFACE -P 0x0019 $target_mac
		# Can't connect: Host is down (147)
		
		if [[ "$connMade" -eq 0 ]] ; then
			LOG cyan "Trying Connection On AV Channel..."
			printf "Trying Connection On AV Channel...\n" >> "$REPORT_PROBE_FILE"
			LOG "Please wait 8 seconds..."
			output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x0019 $target_mac 2>&1)
			killall l2test 2>/dev/null
			if echo "$output" | grep -q "Connected to"; then
				# echo "Connection available/verified!"
				LOG green "Connection available: AVDTP (0x0019)!"
				printf "Connection available: AVDTP (0x0019)!\n" >> "$REPORT_PROBE_FILE"
				connMade=1
			else 
				LOG red "No Connection: AVDTP (0x0019)"
				printf "No Connection: AVDTP (0x0019)\n" >> "$REPORT_PROBE_FILE"
			fi
			LOG " "
		fi
		
		if [[ "$connMade" -eq 0 ]] ; then
			LOG cyan "Trying Connection On AV Channel 2..."
			printf "Trying Connection On AV Channel 2...\n" >> "$REPORT_PROBE_FILE"
			LOG "Please wait 8 seconds..."
			output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x0017 $target_mac 2>&1)
			killall l2test 2>/dev/null
			if echo "$output" | grep -q "Connected to"; then
				# echo "Connection available/verified!"
				LOG green "Connection available: AVCTP (0x0017)!"
				printf "Connection available: AVCTP (0x0017)!\n" >> "$REPORT_PROBE_FILE"
				connMade=1
			else 
				LOG red "No Connection: AVCTP (0x0017)"
				printf "No Connection: AVCTP (0x0017)\n" >> "$REPORT_PROBE_FILE"
			fi
			LOG " "
		fi
		
		if [[ "$connMade" -eq 0 ]] ; then
			resp=$(CONFIRMATION_DIALOG "Connection not made yet, continue trying more channels?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				if [[ "$connMade" -eq 0 ]] ; then
					LOG "Trying Connection On HID, HID 2, RFCOMM..."
					printf "Trying Connection On HID, HID 2, RFCOMM...\n" >> "$REPORT_PROBE_FILE"
					LOG cyan "Trying Connection On HID..."
					printf "Trying Connection On HID...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x0011 $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: HIDP (0x0011)!"
						printf "Connection available: HIDP (0x0011)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: HIDP (0x0011)"
						printf "No Connection: HIDP (0x0011)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
				
				if [[ "$connMade" -eq 0 ]] ; then
					LOG cyan "Trying Connection On HID 2..."
					printf "Trying Connection On HID 2...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x0013 $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: HIDP (0x0013)!"
						printf "Connection available: HIDP (0x0013)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: HIDP (0x0013)"
						printf "No Connection: HIDP (0x0013)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
				
				if [[ "$connMade" -eq 0 ]] ; then
					LOG cyan "Trying Connection On RFCOMM..."
					printf "Trying Connection On RFCOMM...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x0003 $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: RFCOMM (0x0003)!"
						printf "Connection available: RFCOMM (0x0003)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: RFCOMM (0x0003)"
						printf "No Connection: RFCOMM (0x0003)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
			else
				LOG "Skipped scanning more channels..."
				LOG " "
				skipRest=1
			fi
		fi
		
		if [[ "$connMade" -eq 0 && "$skipRest" -eq 0 ]] ; then
			resp=$(CONFIRMATION_DIALOG "Connection not made yet, continue trying more channels?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				if [[ "$connMade" -eq 0 ]] ; then
					LOG "Trying Connection On BNEP, GNSS, TCS, TCS 2..."
					printf "Trying Connection On BNEP, GNSS, TCS, TCS 2...\n" >> "$REPORT_PROBE_FILE"
					LOG cyan "Trying Connection On BNEP..."
					printf "Trying Connection On BNEP...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x000F $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: BNEP (0x000F)!"
						printf "Connection available: BNEP (0x000F)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: BNEP (0x000F)"
						printf "No Connection: BNEP (0x000F)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
				
				if [[ "$connMade" -eq 0 ]] ; then
					LOG cyan "Trying Connection On GNSS..."
					printf "Trying Connection On GNSS...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x001B $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: GNSS (0x001B)!"
						printf "Connection available: GNSS (0x001B)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: GNSS (0x001B)"
						printf "No Connection: GNSS (0x001B)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
				
				if [[ "$connMade" -eq 0 ]] ; then
					LOG cyan "Trying Connection On TCS..."
					printf "Trying Connection On TCS...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x0007 $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: TCS-BIN-CORDLESS (0x0007)!"
						printf "Connection available: TCS-BIN-CORDLESS (0x0007)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: TCS-BIN-CORDLESS (0x0007)"
						printf "No Connection: TCS-BIN-CORDLESS (0x0007)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
				
				if [[ "$connMade" -eq 0 ]] ; then
					LOG cyan "Trying Connection On TCS 2..."
					printf "Trying Connection On TCS 2...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x0005 $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: TCS-BIN (0x0005)!"
						printf "Connection available: TCS-BIN (0x0005)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: TCS-BIN (0x0005)"
						printf "No Connection: TCS-BIN (0x0005)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
			else
				LOG "Skipped scanning more channels..."
				LOG " "
				skipRest=1
			fi
		fi
		
		if [[ "$connMade" -eq 0 && "$skipRest" -eq 0 ]] ; then
			resp=$(CONFIRMATION_DIALOG "Connection not made yet, continue trying more channels?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				if [[ "$connMade" -eq 0 ]] ; then
					LOG "Trying Connection On UDI, AvrcpBrowse..."
					printf "Trying Connection On UDI, AvrcpBrowse...\n" >> "$REPORT_PROBE_FILE"
					LOG cyan "Trying Connection On UDI..."
					printf "Trying Connection On UDI...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x001D $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: UDI (0x001D)!"
						printf "Connection available: UDI (0x001D)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: UDI (0x001D)"
						printf "No Connection: UDI (0x001D)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
				
				if [[ "$connMade" -eq 0 ]] ; then
					LOG cyan "Trying Connection On AvrcpBrowse..."
					printf "Trying Connection On AvrcpBrowse...\n" >> "$REPORT_PROBE_FILE"
					LOG "Please wait 8 seconds..."
					output=$(timeout 8s l2test -n -i $BLE_IFACE -P 0x001F $target_mac 2>&1)
					killall l2test 2>/dev/null
					if echo "$output" | grep -q "Connected to"; then
						# echo "Connection available/verified!"
						LOG green "Connection available: AvrcpBrowse (0x001F)!"
						printf "Connection available: AvrcpBrowse (0x001F)!\n" >> "$REPORT_PROBE_FILE"
						connMade=1
					else 
						LOG red "No Connection: AvrcpBrowse (0x001F)"
						printf "No Connection: AvrcpBrowse (0x001F)\n" >> "$REPORT_PROBE_FILE"
					fi
					LOG " "
				fi
			else
				LOG "Skipped scanning more channels..."
				LOG " "
				skipRest=1
			fi
		fi
		
		if [[ "$connMade" -eq 0 && "$skipRest" -eq 0 ]] ; then
			resp=$(CONFIRMATION_DIALOG "Connection not made yet, try RFCOMM Serial Connection?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				LOG cyan "Trying Connection On RFCOMM Serial..."
				printf "Trying Connection On RFCOMM Serial...\n" >> "$REPORT_PROBE_FILE"
				LOG "Please wait 8 seconds..."
				CHANNEL=1; RFCOMM_DEV="/dev/rfcomm0"
				output=$(timeout 8s rfcomm -i $BLE_IFACE -r connect $RFCOMM_DEV $target_mac $CHANNEL 2>&1)
				killall rfcomm 2>/dev/null
				rfcomm release $RFCOMM_DEV 2>/dev/null
				if echo "$output" | grep -q "Connected $RFCOMM_DEV"; then
					# echo "Connection available/verified!"
					LOG green "Connection available: RFCOMM Serial CH1!"
					printf "Connection available: RFCOMM Serial CH1!\n" >> "$REPORT_PROBE_FILE"
					connMade=1
				else 
					LOG red "No Connection: RFCOMM Serial CH1"
					printf "No Connection: RFCOMM Serial CH1\n" >> "$REPORT_PROBE_FILE"
				fi
				LOG " "
			else
				LOG "Skipped scanning RFCOMM Serial..."
				LOG " "
				skipRest=1
			fi
		fi
		
		# CHANNEL=1; RFCOMM_DEV="/dev/rfcomm0"; output=$(timeout 8s rfcomm -i $BLE_IFACE -r connect $RFCOMM_DEV $target_mac $CHANNEL 2>&1)
		# CHANNEL=1; RFCOMM_DEV="/dev/rfcomm0"; rfcomm -i $BLE_IFACE -r connect $RFCOMM_DEV $target_mac $CHANNEL &
		# Cleanup: Release the port when finished
		# rfcomm release $RFCOMM_DEV
		
		# The -P flag to specify the Protocol/Service Multiplexer (PSM) value for L2CAP connection-oriented channels. PSM values must be odd, with the least significant bit of the most significant octet equal to 0, and typically range from 0x0001 to 0xFFFF.
		# 
		# 0x0001: SDP (Service Discovery Protocol)
		# 0x0003: RFCOMM (Serial Port Emulation)
		# 0x0005: TCS-BIN (Telephony Control Specification)
		# 0x0007: TCS-BIN-CORDLESS
		# 0x000F: BNEP (Bluetooth Network Encapsulation Protocol)
		# 0x0011: HIDP (Human Interface Device Profile - Interrupt)
		# 0x0013: HIDP (Human Interface Device Profile - Control)
		# 0x0017: AVCTP (Audio/Video Control Transport Protocol)
		# 0x0019: AVDTP (Audio/Video Distribution Transport Protocol)
		# 0x001B: GNSS (Global Navigation Satellite System)
		# 0x001D: UDI (Unrestricted Digital Information)
		# 0x001F: AvrcpBrowse (Audio/Video Remote Control Profile)
		# 0x1001-# 0xFFFF: Dynamically assigned or vendor-specific PSMs.
		
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "Output:\n%s\n" "$output" >> "$REPORT_PROBE_FILE"
		
		LOG blue "===================================== Output ===="
		if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; output="$priv_name_txt"; fi
		LOG blue "== MAC: $target_mac ======================="
		LOG blue "==== Connection Details ========================="
		LOG "$output"
		LOG blue "===================================== Output ===="
		sleep 0.1
		if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "%s - EVENT: Complete Verify Connection\n" "$(date +"%Y-%m-%d_%H%M%S")" >> "$REPORT_PROBE_FILE"
		printf "═════════════════════════════════════════════════\n" >> "$REPORT_PROBE_FILE"
		printf "Completed Verify Connection on %s\n" "${target_mac}" >> "$REPORT_PROBE_FILE"
		printf "Results saved to: %s" "${REPORT_PROBE_FILE}" >> "$REPORT_PROBE_FILE"
		LOG green "Completed Verify Connection..."
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.25
	else 
		LOG "Skip Verify Connection on ${target_mac}..."
	fi
	if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
}
