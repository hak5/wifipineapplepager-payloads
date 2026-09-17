#!/bin/bash
# Title: Bluetooth Config MAC USB
# Author: cncartist
# Description: Bluetooth MAC Address Changer for USB CSR8510 / CSR v4.0 Bluetooth Adapter.  Tool will act on hci1 by default and has been tested to work on various CSR8510 Bluetooth Adapters (range from $5-10).  Can also permanently change Alias/Name for specific MAC as an option, or restore the old name before change.  Boot the pager first before plugging in USB BT Adapter to ensure it gets hci1 instead of hci0.
# 
# Alias information saved to /etc/bluetooth/keys/, removed upon factory reset.

# ---- CONFIG ----
IFACE="hci1"

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

update_bluetooth_mac(){
	# devicecurrnt="hci0"
	local devicecurrnt="$1"
	local defaultseladdrnum=0
	local newseladdrnum=0
	local founditems=0
	local aliaschange="false"
	local aliaschangetext=""
	local newalias="Pineapple Pager"
	
	# 'CSR8510 A10.' = 00:1A:7D:DA:71:13 = CSR 4.0 + CSR v4.0 = same original mac for both, second bad?
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
	
	# ---- REGEX ----
	local VALID_MAC="([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"

	LOG blue "================================================="
	LOG cyan "${devicecurrnt} Current MAC Address - ${OLD_MAC}"
	LOG cyan "${devicecurrnt} Current Name - ${OLD_NAME}"
	LOG blue "================================================="
	LOG " "

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
	
	LOG magenta "================================================="
	LOG green   "-------- Press OK when Ready to Start... --------"
	LOG magenta "================================================="
	LOG " "
	LED GREEN
	WAIT_FOR_BUTTON_PRESS A
	sleep 0.25
		
	LED MAGENTA

	# Confirm change
	resp=$(CONFIRMATION_DIALOG "Change MAC Address on Device: ${devicecurrnt}?")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		#LOG "User CONFIRMED"
		
		newseladdrnum=$(NUMBER_PICKER "Selection # (0-${maxarritems}):" $defaultseladdrnum)
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
						#LOG "User CONFIRMED"
						break
					fi
				fi
				LOG red "Skipping MAC: ${NEW_MAC}, generating new..."
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
						#LOG "User CONFIRMED"
						break
					fi
					LOG red "Skipping MAC: ${NEW_MAC}, input new..."
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
			LED CYAN
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
				sleep 0.25
				newalias=$(TEXT_PICKER "New Permament Alias:" "$newalias")
				if [[ -n "$newalias" ]] && [[ "$newalias" != " " ]]; then
					break
				else
					LOG red "Alias cannot be blank/empty!"
				fi
			done
			LOG cyan "Chosen Alias/Name: ${newalias}"
			aliaschangetext="Alias to ${newalias} & "
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			sleep 0.25
		fi
		LED MAGENTA
		
		
		
		# Confirm change
		resp=$(CONFIRMATION_DIALOG "Change USB MAC ${aliaschangetext}Address for $devicecurrnt to: ${NEW_MAC} ?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LED BLUE SLOW
			#LOG "User CONFIRMED"
			LOG "Changing USB $devicecurrnt to MAC: ${NEW_MAC}..."
			LOG blue "================================================="
			bdaddr -i $devicecurrnt "$NEW_MAC" 2>/dev/null
			sleep 2
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
			LED YELLOW SLOW
			
			# check re-plug
			LOG red "PLUG USB Bluetooth IN AGAIN to continue..."
			LOG " "
			INITIAL_COUNT=$(ls /sys/bus/usb/devices/ | wc -l)
			while true; do
				sleep 0.25
				CURRENT_COUNT=$(ls /sys/bus/usb/devices/ | wc -l)
				if [ "$CURRENT_COUNT" -gt "$INITIAL_COUNT" ]; then
					LED CYAN FAST
					LOG magenta "Device detected, please wait..."
					sleep 2
					LOG "Start device reset..."
					hciconfig "$devicecurrnt" down 2>/dev/null
					sleep 1
					hciconfig "$devicecurrnt" up 2>/dev/null
					sleep 1
					LOG green "Completed device reset!"
					LOG " "
					# LOG "exiting loop"
					break
				fi
			done
			
			
			LOG blue "================================================="
			LED MAGENTA
			LOG "Checking MAC Address has changed..."
			LOG blue "================================================="
			NEW_MAC_CHECK=$(hciconfig $devicecurrnt | grep 'BD Address' | awk '{print $3}')
			NEW_NAME_CHECK=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
			LOG "Old $devicecurrnt MAC: $OLD_MAC"
			LOG "Old $devicecurrnt Name: $OLD_NAME"
			LOG blue "================================================="
			if [[ -n "$NEW_MAC_CHECK" ]]; then
			
				# Update to new alias if chosen
				if [ "$aliaschange" = "true" ]; then
					LED CYAN SLOW
					LOG magenta "Setting Permament Alias to: ${newalias}"
					LOG magenta "For: ${NEW_MAC_CHECK}"
					# bluetoothctl select $NEW_MAC_CHECK 2>/dev/null
					# sleep 1
					# bluetoothctl system-alias "${newalias}" 2>/dev/null
					
					bluetoothctl <<-EOF
					select $NEW_MAC_CHECK
					system-alias "${newalias}"
					quit
					EOF
					sleep 0.5
					rm ".bluetoothctl_history" 2>/dev/null
					
					sleep 1
					LOG green "Completed Permament Alias change!"
					LOG blue "================================================="
					NEW_NAME_CHECK=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
				fi
				
				LED GREEN SLOW
				LOG cyan "New $devicecurrnt MAC: $NEW_MAC_CHECK"
				LOG cyan "New $devicecurrnt Name: $NEW_NAME_CHECK"
				LOG blue "================================================="
				if [[ "$OLD_NAME" != "$NEW_NAME_CHECK" ]] && [[ "$aliaschange" == "false" ]]; then
					LED MAGENTA SLOW
					LOG " "
					LOG red "Old name does not match new name!"
					resp=$(CONFIRMATION_DIALOG "Do you want to restore the name for $devicecurrnt to: ${OLD_NAME} ?")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						LOG " "
						LOG "Restoring name to: ${OLD_NAME}"
						bluetoothctl select $NEW_MAC_CHECK 2>/dev/null
						sleep 1
						bluetoothctl system-alias "${OLD_NAME}" 2>/dev/null
						sleep 1
						LOG green "Completed name restoration!"
						LOG " "
						NEW_NAME_CHECK=$(hciconfig -a $devicecurrnt | grep "Name:" | awk -F"'" '{print $2}')
						LOG blue "================================================="
						LOG cyan "New $devicecurrnt MAC: $NEW_MAC_CHECK"
						LOG cyan "Restored $devicecurrnt Name: $NEW_NAME_CHECK"
						LOG blue "================================================="
						LED GREEN SLOW
					fi
				fi
				
			else
				LED RED SLOW
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

LED MAGENTA
LOG magenta "-----------================-----------"
LOG cyan    "==== Bluetooth USB MAC Tool ===="
LOG magenta "-----------================-----------"
LOG "Change MAC Address + Alias for hci1"
LOG blue    "======================================"	
LOG "CSR8510 / CSR v4.0 Bluetooth Adapter"
LOG magenta "-----------================-----------"
LOG red "Changes are permanent + overwrite existing MAC!"
LOG red "Beware: hci1 name may change to default!"
LOG magenta "-----------================-----------"
LOG cyan    "------------ by cncartist ------------"
LOG magenta "-----------================-----------"

# External Bluetooth Adapter?
if hciconfig | grep -q $IFACE; then
	CSR_CHECK=$(hciconfig -a $IFACE | grep 'Manufacturer: Cambridge Silicon Radio' | awk '{print $1}')
	if [[ -n "$CSR_CHECK" ]]; then
		LOG green "CSR USB Bluetooth found!"
		LOG " "
	else
		LOG red "ERROR! $IFACE found, but not CSR!"
		LOG "Press OK to exit..."
		LOG " "
		WAIT_FOR_BUTTON_PRESS A
		exit 0
	fi
else
	LOG red "Device $IFACE not found!"
	LOG "Press OK to exit..."
	LOG " "
	WAIT_FOR_BUTTON_PRESS A
	exit 0
fi

LOG green "Press OK to see Current Device details..."
LOG " "
WAIT_FOR_BUTTON_PRESS A
LOG blue "================================================="
LOG cyan "================ Current details ================"
LOG blue "================================================="
OLD_MAC=$(hciconfig $IFACE | grep 'BD Address' | awk '{print $3}')
OLD_NAME=$(hciconfig -a $IFACE | grep "Name:" | awk -F"'" '{print $2}')
while read -r line; do
	LOG "$line"
done < <(
	hciconfig -a $IFACE
)

update_bluetooth_mac "$IFACE"

LOG green "Configuration complete!"
exit 0
