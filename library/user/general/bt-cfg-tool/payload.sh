#!/bin/bash
# Title: Bluetooth Config Discov/Name
# Author: cncartist
# Description: Bluetooth Discoverable Setting Changer + Bluetooth Hardware Name Changer.  Can change both USB + Internal Settings.

# Check for required tools
if ! command -v hciconfig &> /dev/null; then
    ERROR_DIALOG "hciconfig not installed"
    LOG red "Install with: opkg update && opkg install bluez-utils"
    exit 1
fi
if ! command -v bluetoothctl &> /dev/null; then
    ERROR_DIALOG "bluetoothctl not installed"
    LOG red "Install with: opkg update && opkg install bluez-utils"
    exit 1
fi

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
bluetoothd_check

LED MAGENTA
LOG magenta "-----------================-----------"
LOG cyan    "==== Bluetooth Configuration Tool ===="
LOG magenta "-----------================-----------"
LOG "Change Discoverable Setting for hci0 + hci1"
LOG "Change Hardware Names for hci0 + hci1"
LOG magenta "-----------================-----------"
LOG cyan    "------------ by cncartist ------------"
LOG magenta "-----------================-----------"
LOG green "Press OK to see Current Settings..."
LOG " "
WAIT_FOR_BUTTON_PRESS A
LOG blue "================================================="
LOG cyan "================ Current details ================"
LOG blue "================================================="
while read -r line; do
	LOG "$line"
done < <(
	hciconfig -a
)
LOG blue "================================================="
LOG green "Press OK when Ready to Start..."
LOG blue "================================================="
LOG " "
LED MAGENTA
WAIT_FOR_BUTTON_PRESS A
sleep 0.5

update_bluetooth_status(){
	# devicecurrnt="hci0"
	local devicecurrnt="$1"
	local devicestatus="DOWN"
	local devicediscov="OFF"
	local confirmchange="false"
	
	LED MAGENTA
	
	# Confirm change
	resp=$(CONFIRMATION_DIALOG "Change Bluetooth Status/Discoverable Settings on Device: ${devicecurrnt}?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		#LOG "User CONFIRMED"
		confirmchange="true"
	fi
	if [ "$confirmchange" = "true" ]; then
		LOG blue "================================================="
		LOG cyan "============= Current details ${devicecurrnt} =============="
		LOG blue "================================================="
		while read -r line; do
			LOG "$line"
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
		LOG " "
		LOG green "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		
		# Confirm change
		resp=$(CONFIRMATION_DIALOG "Change Adapter UP/DOWN Status for ${devicecurrnt}?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			#LOG "User CONFIRMED"
			# Confirm change
			resp=$(CONFIRMATION_DIALOG "Turn OFF/DOWN ${devicecurrnt}?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				#LOG "User CONFIRMED"
				# bring DOWN
				LOG green "Turning ${devicecurrnt} OFF..."
				LOG "Updating..."
				LED CYAN VERYFAST
				hciconfig "$devicecurrnt" down 2>/dev/null
				devicestatus="DOWN"
				sleep 0.5
				LOG green "Done..."
				LOG " "
				LED MAGENTA
			fi
			sleep 0.5
			# Confirm change
			resp=$(CONFIRMATION_DIALOG "Turn ON/UP ${devicecurrnt}?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				#LOG "User CONFIRMED"
				# bring UP
				LOG green "Turning ${devicecurrnt} ON..."
				LOG "Updating..."
				LED CYAN VERYFAST
				hciconfig "$devicecurrnt" up 2>/dev/null
				devicestatus="UP"
				sleep 0.5
				LOG green "Done..."
				LOG " "
				LED MAGENTA
			fi
		fi
		
		sleep 0.5
		if [[ "$devicestatus" == "DOWN" ]] ; then
			# Confirm change
			resp=$(CONFIRMATION_DIALOG "Device ${devicecurrnt} is DOWN, do you want to bring it UP?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				LOG green "Turning ${devicecurrnt} ON..."
				LOG "Updating..."
				LED CYAN VERYFAST
				hciconfig "$devicecurrnt" up 2>/dev/null
				devicestatus="UP"
				sleep 0.5
				LOG green "Done..."
				LOG " "
				LED MAGENTA
			fi
		fi
		if [[ "$devicestatus" == "UP" ]] ; then
			# Confirm change
			resp=$(CONFIRMATION_DIALOG "Change Discoverable Setting for ${devicecurrnt}?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				#LOG "User CONFIRMED"
				# Confirm change
				resp=$(CONFIRMATION_DIALOG "Make ${devicecurrnt} Discoverable?")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					#LOG "User CONFIRMED"
					# make Discoverable
					LOG green "Making ${devicecurrnt} Discoverable..."
					LOG "Updating..."
					LED CYAN VERYFAST
					hciconfig "$devicecurrnt" up piscan 2>/dev/null
					devicediscov="ON"
					sleep 0.5
					LOG green "Done..."
					LOG " "
					LED MAGENTA
				fi
				sleep 0.5
				# Confirm change
				resp=$(CONFIRMATION_DIALOG "Make ${devicecurrnt} Hidden?")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					#LOG "User CONFIRMED"
					# make Hidden
					LOG green "Making ${devicecurrnt} Hidden..."
					LOG "Updating..."
					LED CYAN VERYFAST
					hciconfig "$devicecurrnt" up noscan 2>/dev/null
					devicediscov="OFF"
					sleep 0.5
					LOG green "Done..."
					LOG " "
					LED MAGENTA
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
		while read -r line; do
			LOG "$line"
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
		LED GREEN
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





update_bluetooth_name(){
	# devicecurrnt="hci0"
	local devicecurrnt="$1"
	local devicestatus="DOWN"
	local newname=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
	local search1="Type:"
	local search2="BD Address:"
	local search3="Name:"
	local search4="Manufacturer:"
	
	LED MAGENTA

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
			LED CYAN VERYFAST
			hciconfig "$devicecurrnt" up 2>/dev/null
			devicestatus="UP"
			sleep 0.5
			LOG green "Done..."
			LOG " "
			LED MAGENTA
		fi
	fi
	# Confirm change
	resp=$(CONFIRMATION_DIALOG "Change Bluetooth Name on Device: ${devicecurrnt}?")
	if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ] && [ "$devicestatus" = "UP" ]; then
		#LOG "User CONFIRMED"
		LOG blue "================================================="
		LOG cyan "============= Current details ${devicecurrnt} =============="
		LOG blue "================================================="
		while read -r line; do
			LOG "$line"
		done < <(
			hciconfig $devicecurrnt -a | 
			grep -E "${search1}|${search2}|${search3}|${search4}"
		)
		LOG blue "================================================="

		LOG " "
		LOG "Press OK to pick a new name..."
		LOG " "
		LED CYAN
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5
		newname=$(TEXT_PICKER "Target hostname" "$newname")
		LOG cyan "New Name: ${newname}"
		LOG "Press OK to continue..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		sleep 0.5

		# Confirm Name Change
		resp=$(CONFIRMATION_DIALOG "Confirm BT Name Change to ${newname} for Device: ${devicecurrnt}?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			MAC_CHECK=$(hciconfig $devicecurrnt | grep 'BD Address' | awk '{print $3}')
			#LOG "User CONFIRMED"
			LOG green "Updating Name to ${newname} for Device: ${devicecurrnt}..."
			LOG "Updating..."
			LED CYAN VERYFAST
			# bluetoothctl select $MAC_CHECK 2>/dev/null
			# sleep 1
			# bluetoothctl system-alias "${newname}" 2>/dev/null
			LOG "Applying change..."
			
			bluetoothctl <<-EOF
			select $MAC_CHECK
			system-alias "${newname}"
			quit
			EOF
			sleep 0.5
			rm ".bluetoothctl_history" 2>/dev/null
			
			# hciconfig "$devicecurrnt" name "$newname" 2>/dev/null
			# sleep 1
			# LOG "Applying change..."
			# hciconfig "$devicecurrnt" down 2>/dev/null
			# sleep 1
			# hciconfig "$devicecurrnt" up 2>/dev/null
			
			sleep 1
			LOG green "Done..."
			LOG " "
			LED MAGENTA
			
			LOG blue "================================================="
			LOG cyan "=============== New details ${devicecurrnt} ================"
			LOG blue "================================================="
			while read -r line; do
				LOG "$line"
			done < <(
				hciconfig $devicecurrnt -a | 
				grep -E "${search1}|${search2}|${search3}|${search4}"
			)
			LOG blue "================================================="
			LOG " "
			LOG green "BT Name Changed to ${newname} for: ${devicecurrnt}"
			LOG green "Press OK to continue..."
			LOG " "
			LED GREEN
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


# Confirm Modify
if hciconfig | grep -q hci0; then
	resp=$(CONFIRMATION_DIALOG "Modify hci0?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		#LOG "User CONFIRMED"
		update_bluetooth_status "hci0"
		update_bluetooth_name "hci0"
	else 
		LOG "Modify skipped for hci0"
		LOG " "
	fi
fi

# Confirm Modify
if hciconfig | grep -q hci1; then
	resp=$(CONFIRMATION_DIALOG "Modify hci1?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		#LOG "User CONFIRMED"
		update_bluetooth_status "hci1"
		update_bluetooth_name "hci1"
	else 
		LOG "Modify skipped for hci1"
		LOG " "
	fi
fi

LOG green "Configuration complete!"
exit 0