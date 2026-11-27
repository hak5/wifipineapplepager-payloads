#!/bin/bash
#
# Title: Offline WiGLE
# Description: Offline WiGLE reconnaissance with conversion of WiGLE log file to KML format for visualization
# Author: TW-D
# Version: 1.0
#

set -eo pipefail

#
# MAIN CONSTANTS
#

# GPS_LIST command error output
#
GPSLIST_STDERR="No supported serial GPS devices found"

# Default serial port
#
GPS_SERIALPORT="/dev/serial/by-path/1.1_1-1.1:1.0"

#
# USER CONSTANTS
#

# GPS serial communication speed
#
GPS_BAUDRATE=4800

# Acceptable battery percentage threshold
#
BATTERYPERCENT_LIMIT=25

# Maximum WiGLE log file size threshold (MB)
#
WIGLESTART_LIMIT=50

set -u

#
# MAIN
#

#
# The GPS_LIST command doesn’t always reflect the actual state, as the kernel may still consider the device connected after it has been unplugged.
#
if ! GPS_LIST | grep -qxF "${GPSLIST_STDERR}"; then
    GPS_CONFIGURE "${GPS_SERIALPORT}" "${GPS_BAUDRATE}"
    /etc/init.d/gpsd restart

    gps_spinner="$(START_SPINNER "Searching for GPS coordinates to validate the configuration (300s)")"
    SECONDS=0
    while gps_get="$(GPS_GET)"; do
        if [ "${SECONDS}" -ge 300 ]; then
            STOP_SPINNER "${gps_spinner}"
            LOG red "Timeout while waiting for GPS coordinates"
            exit 1
        fi

        if [ "${gps_get}" != "0 0 0 0" ]; then
            STOP_SPINNER "${gps_spinner}"
            LOG green "Supported serial GPS device found"
            LOG blue "${gps_get}"
            break
        fi

        sleep 1s
    done
	
    wigle_start="$(WIGLE_START)"
    LOG green "Location of the WiGLE reconnaissance log"
    LOG blue "${wigle_start}"
    wigle_spinner="$(START_SPINNER "To finish the reconnaissance while ignoring the thresholds, press button B")"
    WAIT_FOR_BUTTON_PRESS B &> /tmp/wigle_button &
    while \
        [ "$(cat /tmp/wigle_button)" != "B" ] && 
        [ "$(BATTERY_PERCENT)" -gt "${BATTERYPERCENT_LIMIT}" ] && 
        [ "$(du -b "${wigle_start}" | awk '{print $1}')" -lt "$(( (1024 ** 2) * WIGLESTART_LIMIT ))" ]; 
    do
        sleep 2s
    done
    truncate -s 0 /tmp/wigle_button
    STOP_SPINNER "${wigle_spinner}"
    WIGLE_STOP

    LOG green "WiGLE log conversion to KML format"
    wigle_kml="${wigle_start%.csv}.kml"
    cat "./templates/SOF.kml" > "${wigle_kml}"
    while IFS="," read -r \
        mac \
        ssid \
        auth_mode \
        first_seen \
        channel \
        frequency \
        rssi \
        current_latitude \
        current_longitude \
        altitude_meters \
        accuracy_meters \
        rcois \
        mfgr_id \
        type; 
    do
        if [[
            -z "${current_latitude}" ||
            -z "${current_longitude}" ||
            -z "${altitude_meters}"
        ]]; then
            continue
        fi

        if [ "${ssid}" = '""' ]; then
            name="${mac}"
        else
            name="${ssid}"
        fi

        case "${auth_mode}" in
            '[OPEN'*)
                style_url="#open"
                ;;
            '[WEP'*)
                style_url="#wep"
                ;;
            '[WPA'*)
                style_url="#wpa"
                ;;
            *)
                style_url="#unknown"
                ;;
        esac

        {
            printf "\t\t<Placemark>\n"
            printf "\t\t\t<name>%s</name>\n" "${name}"
            printf "\t\t\t<styleUrl>%s</styleUrl>\n" "${style_url}"
            printf "\t\t\t<description><![CDATA[\n"
            printf "\t\t\t\t<b>MAC:</b> %s<br />\n" "${mac}"
            printf "\t\t\t\t<b>SSID:</b> %s<br />\n" "${ssid}"
            printf "\t\t\t\t<b>AuthMode:</b> %s<br />\n" "${auth_mode}"
            printf "\t\t\t\t<b>FirstSeen:</b> %s<br />\n" "${first_seen}"
            printf "\t\t\t\t<b>Channel:</b> %s<br />\n" "${channel}"
            printf "\t\t\t\t<b>Frequency:</b> %s MHz<br />\n" "${frequency}"
            printf "\t\t\t\t<b>RSSI:</b> %s<br />\n" "${rssi}"
            printf "\t\t\t\t<b>AccuracyMeters:</b> %s<br />\n" "${accuracy_meters}"
            printf "\t\t\t\t<b>RCOIs:</b> %s<br />\n" "${rcois}"
            printf "\t\t\t\t<b>MfgrId:</b> %s<br />\n" "${mfgr_id}"
            printf "\t\t\t\t<b>Type:</b> %s<br />\n" "${type}"
            printf "\t\t\t]]></description>\n"
            printf "\t\t\t<Point>\n"
            printf "\t\t\t\t<coordinates>%s,%s,%s</coordinates>\n" "${current_longitude}" "${current_latitude}" "${altitude_meters}"
            printf "\t\t\t</Point>\n"
            printf "\t\t</Placemark>\n"
        } >> "${wigle_kml}"
    done < <(tail -n +3 "${wigle_start}")
    
    cat "./templates/EOF.kml" >> "${wigle_kml}"
    LOG blue "${wigle_kml}"
else
    ALERT "${GPSLIST_STDERR}"
fi
