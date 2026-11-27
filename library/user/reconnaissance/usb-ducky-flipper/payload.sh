#!/bin/bash
# Title: USB Ducky / Flipper Scanner & Data Stream Capture
# Author: cncartist
# Description: Hak5 USB Rubber Ducky / Bad USB / Flipper Zero USB Scanner & Data Stream Capture.  Use Pagers USB A port for testing, not USB C.  This tool will capture and decode the key inputs for a keyboard like device and save the output of what was being sent in a data stream text file.
# Category: reconnaissance
# Version: 1.0
# 
# Acknowledgements: 
# DUMPY_REVERSE_DUCKY - Author: THENRGLABS - (idea and code for USB device auto-detect)
# Incident Response Forensic Collector - Author: curtthecoder - (logging example)
# 
# 
# ================================================
# Notes:
# ================================================
# Hak5 USB Rubber Ducky IDs (Common)
# VID:PID for Rubber Ducky
# Version 1 Firmware
# The default VID & PID is 03EB (VID) 2403 (PID) 
# Common VID/PID: 05AC:0220 (Apple Inc.)
# Alternative IDs: VID_F000&PID_FF03 (associated with Bash Bunny, similar, or custom payloads)
# 
# Flipper Zero Vendor ID (VID): 0483 (STMicroelectronics) Product ID (PID): 5740 (Virtual Com Port)
# Flipper Zero Bad USB VID:PID
# 04d9:1702 - Generic HID Keyboard (often cited in examples)
# 046a:0011 - Cherry Keyboard
# 05a4:9810 - Generic Keyboard
# 1234:abcd - Example dummy ID often used in documentation 
# 
# DUCKY_ID="1d6b:0001" # This is a placeholder; needs to be verified with 'lsusb'
# Commonly uses vendor 03eb (Atmel) or 16c0:062a (Raw HID)
# The safest approach is to search by manufacturer name if VID/PID varies.
# ================================================
# 

# ---- CONFIG ----
LOOT_BASE="/root/loot/csec/"; LOOT_DIR="${LOOT_BASE}usb-ducky-flip-scan"
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
REPORT_FILE="$LOOT_DIR/Report_${TIMESTAMP}.txt"
DATASTREAM_FILE="$LOOT_DIR/Data_${TIMESTAMP}.txt"
DATASTREAMRAW_FILE="$LOOT_DIR/DataRAW_${TIMESTAMP}.txt"
DATASTREAMTMP_FILE="$LOOT_DIR/DataTMP_${TIMESTAMP}.txt"
KEYCKTMP_FILE="$LOOT_DIR/KeyCKTMP.txt"
DATA_SCAN_SECONDS=15

# ---- DEFAULTS ----
scan_foundevents="false"
scan_decrypt="false"
shift_pressed=0
capsl_pressed=0
numlk_pressed=0
founditems=0
THRESHOLD_BYTES=100

# US Keyboard layout mapping for KEY_NAME -> (Normal, Shifted)
declare -A keymap
keymap=([KEY_A]="a A" [KEY_B]="b B" [KEY_C]="c C" [KEY_D]="d D" [KEY_E]="e E" [KEY_F]="f F" \
        [KEY_G]="g G" [KEY_H]="h H" [KEY_I]="i I" [KEY_J]="j J" [KEY_K]="k K" [KEY_L]="l L" \
        [KEY_M]="m M" [KEY_N]="n N" [KEY_O]="o O" [KEY_P]="p P" [KEY_Q]="q Q" [KEY_R]="r R" \
        [KEY_S]="s S" [KEY_T]="t T" [KEY_U]="u U" [KEY_V]="v V" [KEY_W]="w W" [KEY_X]="x X" \
        [KEY_Y]="y Y" [KEY_Z]="z Z" [KEY_1]="1 !" [KEY_2]="2 @" [KEY_3]="3 #" [KEY_4]="4 $" \
        [KEY_5]="5 %" [KEY_6]="6 ^" [KEY_7]="7 &" [KEY_8]="8 *" [KEY_9]="9 (" [KEY_0]="0 )" \
		
        [KEY_KP0]="0 0" [KEY_KP1]="1 1" [KEY_KP2]="2 2" [KEY_KP3]="3 3" [KEY_KP4]="4 4" \
        [KEY_KP5]="5 5" [KEY_KP6]="6 6" [KEY_KP7]="7 7" [KEY_KP8]="8 8" [KEY_KP9]="9 9" \
        [KEY_KPPLUS]="+ +" [KEY_KPMINUS]="- -" [KEY_KPASTERISK]="* *" [KEY_KPSLASH]="/ /" \
		
        [KEY_MINUS]="- _" [KEY_EQUAL]="= +" [KEY_LEFTBRACE]="[ {" [KEY_RIGHTBRACE]="] }" [KEY_KPDOT]=". ." \
        [KEY_BACKSLASH]="\\ |" [KEY_SEMICOLON]="; :" [KEY_APOSTROPHE]="' \"" [KEY_GRAVE]="\` ~" \
        [KEY_COMMA]=", <" [KEY_DOT]=". >" [KEY_SLASH]="/ ?")

cleanup() {
	killall evtest 2>/dev/null
	# unlock hid output
	modprobe usbhid 2>/dev/null
	rm "$KEYCKTMP_FILE"
    sleep 0.5
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM

# Check for required tools
check_dependencies() {
	# ORIGINAL <root> grep -V
	# grep: unrecognized option: V
	# BusyBox v1.36.1 (2025-04-13 16:38:32 UTC) multi-call binary.
	# 
	# NEW <root> grep -V
	# grep (GNU grep) 3.11
	local evtestCheck=0; local grepCheck=0; local count=0; local limit=3; local substring="BusyBox v"; local substring2='grep (GNU grep)'
	# check evtest
	if command -v evtest &> /dev/null; then
		evtestCheck=1
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
	if [[ "$grepCheck" -eq 0 || "$evtestCheck" -eq 0 ]]; then
		local dependText=""
		# ask if they want to install now
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
			LOG "opkg install evtest"
			LOG blue  "================================================="
			LOG cyan "== Or all in one command ->"
			LOG "opkg update && opkg install grep && opkg install evtest"
			LOG blue  "================================================="
			sleep 1
			exit 1
		fi
	fi
}
check_dependencies

# function to kill process if no output found
timeoutfunction(){
	# LOG red "timeoutfunction"
	cat "$DATASTREAMTMP_FILE" | grep "^Event:" > "$DATASTREAMRAW_FILE"
	sed -i '/MSC_SCAN/d' "$DATASTREAMRAW_FILE"; sed -i '/SYN_REPORT/d' "$DATASTREAMRAW_FILE"
	rm "$DATASTREAMTMP_FILE"
	if [ -n "$(find "$DATASTREAMRAW_FILE" -prune -type f -size +"${THRESHOLD_BYTES}c" 2>/dev/null)" ]; then
		# LOG red "FILE EXISTS, KEEP EVTEST"
		# sleep to wait for file count
		sleep 5
	else
		# echo "The file is not greater than ${THRESHOLD_BYTES} bytes, or does not exist."
		# LOG red "KILLING EVTEST"
		killall evtest 2>/dev/null
	fi
}
rm "$KEYCKTMP_FILE"

LED GREEN
LOG magenta "-----------================-----------"
LOG cyan    "------------ USB Hack Scan -----------"
LOG magenta "-----------================-----------"
LOG cyan    "-- Hak5 / USB Rubber Ducky Reverse ---"
LOG cyan    "--------- USB Ducky / Flipper --------"
LOG magenta "-----------================-----------"
LOG cyan    "------------ by cncartist ------------"
LOG magenta "-----------================-----------"
LOG green "Press OK when Ready to Start..."
WAIT_FOR_BUTTON_PRESS A

printf "═══════════════════════════════════════════════════════════════\n" > "$REPORT_FILE"
printf "  USB Hack Scan - Report\n" >> "$REPORT_FILE"
printf "  Date: %s\n" "${TIMESTAMP}" >> "$REPORT_FILE"
printf "═══════════════════════════════════════════════════════════════\n\n" >> "$REPORT_FILE"
printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"

# Check for USB device with Ducky characteristics
# Confirm Scan
resp=$(CONFIRMATION_DIALOG "Scan for Ducky Style USB Device?")
if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
	# remove hid for safety - HID LOCKOUT
	rmmod usbhid 2>/dev/null || modprobe -r usbhid 2>/dev/null
	LOG " "
	LED MAGENTA
	LOG cyan "Rubber Ducky USB Check"
	printf "  Rubber Ducky USB Check\n" >> "$REPORT_FILE"
	printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"
	LOG magenta "Do not plug in USB yet..."
	LOG " "
	LOG cyan "Please be aware, longer capture times = larger files and much longer decryption time!"
	LOG " "
	LOG cyan "Decryption is optional."
	LOG "Press OK to confirm..."
	LOG " "
	WAIT_FOR_BUTTON_PRESS A
	
	# ASK HOW MANY SECONDS TO RECORD DATA STREAM FOR - $DATA_SCAN_SECONDS
	# Longer times = larger file - 35 seconds =~ 4 MB / 4,000,000 bytes
	DATA_SCAN_SECONDS=$(NUMBER_PICKER "Capture duration (seconds):" $DATA_SCAN_SECONDS)
	case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED) DATA_SCAN_SECONDS=$DATA_SCAN_SECONDS ;; esac
	[ $DATA_SCAN_SECONDS -lt 5 ] && DATA_SCAN_SECONDS=5
	[ $DATA_SCAN_SECONDS -gt 120 ] && DATA_SCAN_SECONDS=120
	
	LOG green "Plug USB in or Press OK to start..."
	# pager device input = /dev/input/event0
	(evtest /dev/input/event0 | grep "^Event:" &> "$KEYCKTMP_FILE") &
	INITIAL_COUNT=$(ls /sys/bus/usb/devices/ | wc -l)
	while true; do
		line=""; sleep 0.01
		CURRENT_COUNT=$(ls /sys/bus/usb/devices/ | wc -l)
		if [ "$CURRENT_COUNT" -gt "$INITIAL_COUNT" ]; then
			# Check HID/Keyboard class
			IS_KBD=$(grep -Ei "Keyboard|HID" /proc/bus/input/devices)
			IS_CLASS=$(cat /sys/bus/usb/devices/*/bInterfaceClass 2>/dev/null | grep "03")
			if [[ -n $IS_KBD ]] || [[ -n $IS_CLASS ]]; then
				# LOG "exiting loop"
				break
			fi
		fi
		while read -r line; do # LOG "$line"
			# check for OK/GO button press, evtest finished
			if [[ "$line" == *'(BTN_EAST), value 1'* ]]; then
				# LOG "exiting loop"
				killall evtest 2>/dev/null
				break
			fi
			# sleep 0.5
		done < "$KEYCKTMP_FILE"
		if [[ "$line" == *'(BTN_EAST), value 1'* ]]; then
			# LOG "final exiting loop"
			break
		fi		
    done
	killall evtest 2>/dev/null
	rm "$KEYCKTMP_FILE"
	
	# WAIT_FOR_BUTTON_PRESS A
	LOG " "
	LOG cyan "Scanning for USB Rubber Ducky..."
	printf "Scanning for USB Rubber Ducky...\n" >> "$REPORT_FILE"
	LOG magenta "Please Wait!"
	LOG magenta "DO NOT press any buttons on USB device!"
	LOG " "
	
	# Keyboard USB device input = /dev/input/event1
	LED CYAN VERYFAST
	
	# unlock hid output
	modprobe usbhid 2>/dev/null
	
	if [ -c "/dev/input/event1" ]; then
		(sleep $((DATA_SCAN_SECONDS + 1)) && timeoutfunction) & # sleep then kill process if no output found
		LOG cyan "Data Stream Found!"
		LOG cyan "Verifying data stream for $DATA_SCAN_SECONDS seconds..."
		printf "Data Stream Found!\n" >> "$REPORT_FILE"
		printf "Verifying data stream for %s seconds...\n" "${DATA_SCAN_SECONDS}" >> "$REPORT_FILE"
		LOG " "
		
		# LOG red "evtest"
		(evtest --grab /dev/input/event1 &> "$DATASTREAMTMP_FILE") &
		# LOG red "sleep"
		sleep $((DATA_SCAN_SECONDS + 2))
		# end evtest if still running
		killall evtest 2>/dev/null
		# remove hid for safety - HID LOCKOUT
		rmmod usbhid 2>/dev/null || modprobe -r usbhid 2>/dev/null
		
		# check filesize and remove files if empty
		if [ -n "$(find "$DATASTREAMRAW_FILE" -prune -type f -size +"${THRESHOLD_BYTES}c" 2>/dev/null)" ]; then
			# echo "The file is greater than ${THRESHOLD_BYTES} bytes."
			scan_foundevents="true"
		else
			# echo "The file is not greater than ${THRESHOLD_BYTES} bytes, or does not exist."
			scan_foundevents="false"
			rm "$DATASTREAMRAW_FILE"
			rm "$DATASTREAM_FILE"
		fi
		
		RINGTONE "alert"
		LED GREEN SLOW
		
		if [ "$scan_foundevents" = "true" ]; then
			LOG green "Data Stream Captured!"
			printf "Data Stream Captured!\n" >> "$REPORT_FILE"
			LOG green "USB DEVICE can be UNPLUGGED NOW"
			LOG " "
			LOG cyan "If chosen, DECRYPTION OF DATA can take considerable time!"
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
			# Confirm Decrypt
			resp=$(CONFIRMATION_DIALOG "Would you like to decrypt the data?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				#LOG "User CONFIRMED"
				scan_decrypt="true"
			fi
		else
			LOG "Data Stream captured was blank..." 
			LOG "Try capture for longer duration?"
			printf "Data Stream captured was blank...\n" >> "$REPORT_FILE"
			LOG " "
		fi
		
		if [ "$scan_decrypt" = "true" ]; then
			LED MAGENTA SLOW
			# key up + down
			# numoflines=$(( $(wc -l < "$DATASTREAMRAW_FILE") * 2))
			numoflines=$(wc -l < "$DATASTREAMRAW_FILE")
			LOG "Number of lines in Data Stream: $numoflines"
			printf "Number of lines in Data Stream: %s\n" "${numoflines}" >> "$REPORT_FILE"
			LOG cyan "Decrypting data..."
			LOG magenta "Please wait!"
			printf "Decrypting data...\n" >> "$REPORT_FILE"
			# LOG red "full file"
			curline=0
			# do counts
			# LOG "numoflines: $numoflines"
			numoflines5per=$((numoflines * 5 / 100))
			numoflines25per=$((numoflines * 25 / 100))
			numoflines50per=$((numoflines / 2))
			numoflines75per=$((numoflines * 75 / 100))
			numoflines90per=$((numoflines * 90 / 100))
			# evtest --grab /dev/input/event1		
			# use evtest to determine data stream output
			# Process the line here # LOG "$line"
			while IFS= read -r line; do
				curline=$((curline + 1))
				case "$curline" in
				  "$numoflines5per")
					LOG cyan "Decrypting data... 5% done"
					;;
				  "$numoflines25per")
					LOG cyan "Decrypting data... 25% done"
					;;
				  "$numoflines50per")
					LOG cyan "Decrypting data... 50% done"
					;;
				  "$numoflines75per")
					LOG cyan "Decrypting data...  75% done"
					;;
				  "$numoflines90per")
					LOG cyan "Decrypting data...  90% done"
					;;
				esac
				# LOG red "while IFS"
				# if [[ "$line" == *"Event:"* ]]; then # echo "Found '$substring' in string." 
				if [[ "$line" =~ "EV_KEY" ]]; then
					# echo $line >> $DATASTREAMRAW_FILE # LOG "$line"
					# printf "%s\n" "${line}" >> "$DATASTREAMRAW_FILE"
					
					# Extract Code and Value
					kcode=$(echo $line | grep -oP 'KEY_\w+')
					kvalue=$(echo $line | grep -oP 'value \K\d')
					
					# printf "%s\n" "${kcode}" >> "$DATASTREAM_FILE"
					# LOG "kcode: ${kcode}"
					case "$kcode" in
					  "KEY_NUMLOCK")
						numlk_pressed=$kvalue
						continue
						;;
					  "KEY_CAPSLOCK")
						capsl_pressed=$kvalue
						continue
						;;
					  "KEY_LEFTSHIFT"|"KEY_RIGHTSHIFT")
						shift_pressed=$kvalue
						if [[ $capsl_pressed -eq 1 && $shift_pressed -eq 1 ]]; then
							shift_pressed=0
						fi
						continue
						;;
					esac
						
					# Only process key presses (value 1) or repeats (value 2)
					if [[ "$kvalue" -eq 1 || "$kvalue" -eq 2 ]]; then
						if [[ -n "${keymap[$kcode]}" ]]; then
							map_entry="${keymap[$kcode]}"
							# LOG "kcode: ${kcode} - map entry: ${map_entry}"
							if [[ "$shift_pressed" -eq 1 ]]; then
								printf "%s" "${map_entry#* }" >> "$DATASTREAM_FILE"
							else
								printf "%s" "${map_entry%% *}" >> "$DATASTREAM_FILE"
							fi
						else
							case "$kcode" in
							  "KEY_SPACE")
								printf " " >> "$DATASTREAM_FILE"
								;;
							  "KEY_ENTER"|"KEY_KPENTER")
								printf "\n" >> "$DATASTREAM_FILE"
								;;
							  "KEY_TAB")
								printf "\t" >> "$DATASTREAM_FILE"
								;;
							  # "KEY_BACKSPACE")
								# printf "\b \b" >> "$DATASTREAM_FILE" # Print backspace, space over char, backspace again
								# ;;
							  *)
								if [[ -n "$kcode" ]]; then
									printf "%s" "[${kcode}]" >> "$DATASTREAM_FILE"
								fi
								;;
							esac
						fi
					fi
				fi
			done < "$DATASTREAMRAW_FILE"
			
			RINGTONE "ScaleTrill"
			LED GREEN SLOW
			LOG green "Data Decryption Complete!"
			printf "Data Decryption Complete!\n" >> "$REPORT_FILE"
			LOG " "
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
		fi
	else 
		LOG green "No Ducky Input Devices detected/enabled."
		printf "No Ducky Input Devices detected/enabled.\n" >> "$REPORT_FILE"
	fi
	
	if lsusb | grep -i "Ducky" || lsusb | grep -i "16c0:062a" || lsusb | grep -i "03eb:" || lsusb | grep -i "1d6b:0001" || lsusb | grep -i "05ac:0220" || lsusb | grep -i "f000:ff03" || [ "$scan_foundevents" = "true" ]; then
		LED RED SLOW
		RINGTONE "warning"
		LOG red "WARNING: Potential USB Rubber Ducky detected!"
		printf "\n" >> "$REPORT_FILE"
		printf "WARNING: Potential USB Rubber Ducky detected!\n" >> "$REPORT_FILE"
		founditems=$((founditems + 1))
		if [ "$scan_foundevents" = "false" ]; then
			# LOG red "SHOW USB DATA HIT ON GREP PULL"
			if tmpline=$(lsusb | grep -i "Ducky" || lsusb | grep -i "16c0:062a" || lsusb | grep -i "03eb:" || lsusb | grep -i "1d6b:0001" || lsusb | grep -i "05ac:0220" || lsusb | grep -i "f000:ff03"); then
				# remove starting text "Bus 001 Device 012: ID "
				tmpline="${tmpline:22}"
				LOG red "Potential Ducky Found:\n$tmpline"
				printf "Potential Ducky Found:\n%s\n" "${tmpline}" >> "$REPORT_FILE"
			fi
		else
			LOG red "Data Stream Captured!"
			printf "Data Stream Captured!\n" >> "$REPORT_FILE"
			if [ "$scan_decrypt" = "true" ]; then
				LOG red "File Decrypted: ${DATASTREAM_FILE}"
				printf "File Decrypted: %s\n" "${DATASTREAM_FILE}" >> "$REPORT_FILE"
				LOG " "
			fi
			LOG red "File RAW: ${DATASTREAMRAW_FILE}"
			printf "File RAW: %s\n" "${DATASTREAMRAW_FILE}" >> "$REPORT_FILE"
		fi
	else
		LED GREEN SLOW
		RINGTONE "ScaleTrill"
		LOG green "No obvious USB Rubber Ducky Devices detected."
		printf "No obvious USB Rubber Ducky Devices detected.\n" >> "$REPORT_FILE"
	fi
	
	LOG " "
	if [ "$scan_foundevents" = "true" ]; then
		LOG red "USB DEVICE needs to be UNPLUGGED NOW!"
		LOG red "Waiting for 10 seconds..."
		sleep 10
	else
		LOG "USB device can be unplugged now."
	fi
	LOG "Press OK to continue..."
	WAIT_FOR_BUTTON_PRESS A
	# unlock hid output
	modprobe usbhid 2>/dev/null
	printf "═══════════════════════════════════════════════════════════════\n\n" >> "$REPORT_FILE"
	printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"
else
	LOG "Skipped Ducky Scan."
fi
		



sleep 1
# Check for USB device with Flipper Style characteristics
# Confirm Scan
resp=$(CONFIRMATION_DIALOG "Scan for Flipper Style USB Device?")
if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
	# remove hid for safety - HID LOCKOUT
	rmmod usbhid 2>/dev/null || modprobe -r usbhid 2>/dev/null
	LOG " "
	LED MAGENTA
	LOG cyan "Flipper Device USB Scan"
	printf "  Flipper Device USB Scan\n" >> "$REPORT_FILE"
	printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"
	
	LOG green "Press OK when USB plugged in..."
	WAIT_FOR_BUTTON_PRESS A
	LOG " "
	LOG cyan "Scanning for USB Flipper Device..."
	printf "Scanning for USB Flipper Device...\n" >> "$REPORT_FILE"
	LOG " "

	if tmpline=$(lsusb | grep -i "0483:5740" || lsusb | grep -i "04d9:1702" || lsusb | grep -i "046a:0011" || lsusb | grep -i "05a4:9810" || lsusb | grep -i "1234:abcd"); then
		LED RED SLOW
		RINGTONE "warning"
		LOG red "WARNING: Potential USB Flipper Device detected!"
		printf "\n" >> "$REPORT_FILE"
		printf "WARNING: Potential USB Flipper Device detected!\n" >> "$REPORT_FILE"
		founditems=$((founditems + 1))
		LOG " "
		# remove starting text "Bus 001 Device 012: ID "
		tmpline="${tmpline:22}"
		LOG red "Potential Flipper:\n$tmpline"
		printf "Potential Flipper:\n%s\n" "${tmpline}" >> "$REPORT_FILE"
	else
		LED GREEN SLOW
		RINGTONE "ScaleTrill"
		LOG green "No obvious USB Flipper Devices detected."
		printf "No obvious USB Flipper Devices detected.\n" >> "$REPORT_FILE"
	fi
	LOG " "
	LOG "USB device can be unplugged now."
	LOG "Press OK to continue..."
	WAIT_FOR_BUTTON_PRESS A
	# unlock hid output
	modprobe usbhid 2>/dev/null
	printf "═══════════════════════════════════════════════════════════════\n\n" >> "$REPORT_FILE"
	printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"
else
	LOG "Skipped Flipper Scan."
fi



# finished
LOG " "
LED MAGENTA
LOG green "Scans Completed!"
printf "Scans Completed!\n" >> "$REPORT_FILE"
if [[ ${founditems} -gt 0 ]]; then
	LOG red "$founditems malicious suspects found!"
	printf "%s malicious suspects found!\n" "${founditems}" >> "$REPORT_FILE"
else 
	LOG green "No malicious suspects found!"
	printf "No malicious suspects found!\n" >> "$REPORT_FILE"
fi
LOG " "
printf "\n" >> "$REPORT_FILE"
LOG cyan "Results saved to: ${REPORT_FILE}"
printf "Results saved to: %s" "${REPORT_FILE}" >> "$REPORT_FILE"

exit 0
