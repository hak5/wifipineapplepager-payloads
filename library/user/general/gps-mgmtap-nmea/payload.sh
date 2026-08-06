#!/bin/bash
# Title: GPS Mgmt AP NMEA UDP Port 9999
# Author: cncartist
# Description: Turn your phone into your GPS for the Pager with minimal effort!  Allows stop/start of UDP Port 9999 NMEA GPS data collection for the Pager.  Can use Android app gpsdRelay, iPhone NMEA Send Location App, C5 Wardriver, or similar GPS relaying apps/devices to relay NMEA information to the gpsd server UDP Port 9999 on the Pagers Management AP.  This allows NMEA information to be passed to the device from any NMEA source on the Pagers Mgmt AP sending UDP NMEA data to UDP Port 9999.  It can take some time until data starts being received, and that relies on the phone/sending devices GPS signal.
# Category: general
# 
# ============================================
# Acknowledgements: 
# ============================================
# repins762 - https://github.com/repins762 - (idea)
# mobile2gps (https://github.com/ryanpohlner/mobile2gps/tree/main) - Author: Ryan Pohlner (@Spectracide on Discord) - (insight)
# gpsdRelay (https://f-droid.org/packages/io.github.project_kaat.gpsdrelay/) - Author: project-kaat (Android Relay)
# NMEA Send Location App (https://apps.apple.com/us/app/nmea-send-location/id6749798097) - Author: Alexey Matveev (iPhone Relay)
# 
# ============================================
# Notes:
# ============================================
# ORIG FW 1.0.9 = option device '/dev/serial/by-path/1.1_1-1.1:1.0'
# Check output of active GPS data with count of 10 new messages: "gpspipe -r -n 10"
# -- -- Output will be flowing when GPS is coming through
# 

backupFile="savedGPSdevice.txt"

LOG blue "========================================"
LOG      "======= GPS NMEA Android Mgmt AP ======="
LOG      "======== EXTERNAL GPS ENABLER =========="
LOG      "==== UDP Port 9999 (NMEA) GGA & RMC ===="
LOG blue "========================================"
LOG " "

resp=$(CONFIRMATION_DIALOG "Do you want to ENABLE GPS NMEA Relay on UDP port 9999?
	
	This will change the device path for GPS to listen to UDP port 9999.")
if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
	LOG "Stopping GPS instances..."
	killall gpsd 2>/dev/null
	sleep 1
	LOG "Changing Device Path..."
	# check if file is not empty this time around
	if [[ -s "$backupFile" ]]; then
		# check if file exists, means it may have been running/restarting relay
		LOG "Saving Previous Settings..."
		orig_gpsdevicepath=$(cat "$backupFile")
	else
		orig_gpsdevicepath=$(uci get gpsd.core.device)
	fi
	# LOG "orig_gpsdevicepath: $orig_gpsdevicepath"
	printf "%s" "${orig_gpsdevicepath}" > "$backupFile"
	uci set gpsd.core.device='udp://0.0.0.0:9999'
	uci commit 2>/dev/null
	sleep 1
	LOG "Applying Settings..."
	/etc/init.d/gpsd reload 2>/dev/null
	/etc/init.d/gpsd restart 2>/dev/null
	sleep 1
	LOG green "GPS Enabled!"
	LOG " "
	LOG "1. Turn on Location + WiFi on Phone"
	LOG "2. Connect to Pager Mgmt AP from Phone"
	cur_wlan0mgmt=$(uci get wireless.wlan0mgmt.disabled)
	if [[ "$cur_wlan0mgmt" -eq 1 ]] ; then
		LOG red "-- Pager Mgmt AP Disabled!"
	fi
	LOG "3. Open gpsdRelay on Phone"
	LOG "4. Add Relay to 172.16.52.1:9999 (UDP)"
	LOG "-- Options: 'NMEA relaying' ONLY to GGA & RMC"
	LOG "5. Start Phone Relay to Pager and Patience!"
	LOG " "
else 
	LOG "Skipped Enabling GPS..."
	LOG " "	
	resp=$(CONFIRMATION_DIALOG "Do you want to STOP/DISABLE GPS NMEA Relay on UDP port 9999?
	
	This will return the device path for GPS to the previous settings.")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		LOG "Stopping GPS instances..."
		killall gpsd 2>/dev/null
		sleep 1
		# check if file is not empty this time around
		if [[ -s "$backupFile" ]]; then
			LOG "Returning Device to Previous Setting..."
			saved_gpsdevicepath=$(cat "$backupFile")
			# LOG "saved_gpsdevicepath: $saved_gpsdevicepath"
			uci set gpsd.core.device="$saved_gpsdevicepath"
			uci commit 2>/dev/null
		fi
		sleep 1
		LOG "Applying Settings..."
		/etc/init.d/gpsd reload 2>/dev/null
		/etc/init.d/gpsd restart 2>/dev/null
		sleep 1
		# remove old file
		rm "$backupFile" 2>/dev/null
		LOG green "Complete!"
		LOG " "
	else 
		LOG "Skipped Stopping GPS..."
		LOG " "
	fi
fi

LOG "Finished, exiting..."
LOG " "

exit 0
