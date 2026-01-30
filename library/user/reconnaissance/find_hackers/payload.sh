#!/bin/bash
# Title: Find Hackers
# Description: Detects suspicious network and Bluetooth activity that may indicate the presence of nearby hackers.
# Author: NULLFaceNoCase
# Version: 1.0

# ---- FILES ----
LOOT_DIR="/root/loot/find_hackers/"
RECON_OUTPUT_JSON="/root/loot/find_hackers/all_aps.json"
RECON_DB="/root/recon/recon.db"

# ---- BLE ----
BLE_IFACE="hci0"
BLE_SCAN_SECONDS=30
BT_TIMEOUT="20s"
FLIPPER_OUI="0C:FA:22"
FLIPPER_NAME="flipper"

# ---- WIFI ----
# Min amount an AP needs to change it's SSID to qualify as spoofing
MIN_SPOOFING_COUNT=5
SLEEP_BETWEEN_SCANS=15 # Time to restart wifi and bluetooth searches

# ---- REGEX ----
VALID_MAC="([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"

declare -a AP_RESULTS
declare -A SPOOFING_MACS
declare -A BT_FLIPPERS

cleanup() {
    killall hcitool 2>/dev/null
    log_to_file "find_hackers stopped"
    sleep 0.5
    exit 0
}

setup() {
    mkdir -p "$LOOT_DIR"
    log_to_file "find_hackers starting.. loot = $LOOT_DIR"
}

log_to_file() {
    local msg="$1"
    printf "[$(date +%s)] $msg\n" >> "$LOOT_DIR/collector.log"
}

get_aps_json() {
    _pineap RECON APS format=json | jq '.' > "$RECON_OUTPUT_JSON"
}

search_ssid_json() {
    local mode="$1"
    local search_ssid="$2"

    local jq_filter
    local match=""

    if [[ -z "$search_ssid" ]]; then
        # No SSID provided: return all objects
        jq_filter='
        .[]
        | {
            mac: .mac,
            packets: .packets,
            all_ssids: (
                [
                    (.beacon[]? | {ssid, channel, hidden, freq, signal, time, count}),
                    (.response[]? | {ssid, channel, hidden, freq, signal, time, count})
                ]
                | unique_by(.ssid)
            )
        }
        '
    else
        # Determine match filter
        if [[ "$mode" == "SEARCH" ]]; then
            match='. == $ssid'
        elif [[ "$mode" == "ISEARCH" ]]; then
            match='(. | ascii_downcase) == ($ssid | ascii_downcase)'
        elif [[ "$mode" == "SUBSTRING" ]]; then
            match='contains($ssid)'
        elif [[ "$mode" == "ISUBSTRING" ]]; then
            match='ascii_downcase | contains($ssid | ascii_downcase)'
        else
            echo "Invalid mode. Use SEARCH, ISEARCH, SUBSTRING, or ISUBSTRING"
            return 1
        fi

        jq_filter="
        .[]
        | select(
            ([ (.beacon[]? | .ssid), (.response[]? | .ssid) ] | any($match))
        )
        | {
            mac: .mac,
            packets: .packets,
            all_ssids: (
                [
                    (.beacon[]? | {ssid, channel, hidden, freq, signal, time, count}),
                    (.response[]? | {ssid, channel, freq, signal, time, count})
                ]
                | unique_by(.ssid)
            )
        }
        "
    fi

    mapfile -t AP_RESULTS < <(jq -c --arg ssid "$search_ssid" "$jq_filter" "$RECON_OUTPUT_JSON")
}

alert_sus_aps() {
    for ap_json in "${AP_RESULTS[@]}"; do
        mac=$(jq -r '.mac' <<< "$ap_json")
        ssid_count=$(jq '.all_ssids | length' <<< "$ap_json")

        # All SSIDS in a string
        mapfile -t ssids < <(jq -r '.all_ssids[].ssid' <<< "$ap_json")
		# Check if AP changed SSID but has NOT met the spoofing threshold
	    if (( ssid_count > 1 && ssid_count < $MIN_SPOOFING_COUNT )); then
            log_to_file "Sus SSID that has changed names SSID List: ${ssids[*]} MAC: $mac"
		    LOG "Sus SSID that has changed names\nSSID List: ${ssids[*]}\nMAC: $mac\n"
		    ALERT "Sus SSID that has changed names\nSSID List: ${ssids[*]}\nMAC: $mac"
		elif (( ssid_count == 1 )); then
            channel=$(jq -r '.all_ssids[0]?.channel // empty' <<< "$ap_json")
            signal=$(jq -r ".all_ssids[0]?.signal // empty" <<< "$ap_json")
            log_to_file "Sus SSID SSID: ${ssids[*]} MAC: $mac Channel: $channel Signal: $signal"
		    LOG "Sus SSID\nSSID: ${ssids[*]}\nMAC: $mac\n Channel: $channel\n Signal: $signal\n\n"
		    ALERT "Sus SSID\nSSID: ${ssids[*]}\nMAC: $mac\n Channel: $channel\n Signal: $signal\n"
        elif (( ssid_count > 1 && ssid_count >= $MIN_SPOOFING_COUNT )); then
            log_to_file "Sus SSID that is spoofing SSIDs skipping SSID list MAC: $mac"
		    LOG "Sus SSID that is spoofing SSIDs skipping SSID list\nMAC: $mac\n"
        fi
    done
}

alert_aps_spoofing_ssids() {
    spoof_count=0
    for ap_json in "${AP_RESULTS[@]}"; do
        mac=$(jq -r '.mac' <<< "$ap_json")
        ssid_count=$(jq '.all_ssids | length' <<< "$ap_json")

	    if (( ssid_count >= $MIN_SPOOFING_COUNT )); then
			# Get all SSIDs being spoofed and save to an output file
			dt=$(date +%s)
			output_file="${LOOT_DIR%/}/${dt}_${mac}_ssid_pool.txt"

            for ((i = 0; i < ssid_count; i++)); do
                ssid=$(jq -r ".all_ssids[$i].ssid" <<< "$ap_json")
                echo "$ssid" >> $output_file
            done

            # Add MAC to list - will ignore these in evil twins
            SPOOFING_MACS["$mac"]=1

            log_to_file "Sus AP spoofing $ssid_count networks SSID Pool saved to $output_file MAC: $mac"
		    LOG "Sus AP spoofing $ssid_count networks\nSSID Pool saved to $output_file\nMAC: $mac"
		    ALERT "Sus AP spoofing $ssid_count networks\nSSID Pool saved to $LOOT_DIR\nMAC: $mac"
		    ((spoof_count++))
		fi
    done
    log_to_file "Found $spoof_count APs spoofing atleast $MIN_SPOOFING_COUNT networks"
	LOG "Found $spoof_count APs spoofing atleast $MIN_SPOOFING_COUNT networks\n"
}

# Extract OUI (manufacturer info) from a MAC address's first 3 bytes
get_oui() {
    echo "${1,,}" | cut -d: -f1-3
}

# TODO - Update once encryption is returned from `_pinap RECON`
# Get the encryption type from a specific BSSID using the SQLITE database
get_encryption() {
	local mac="$1"
    # Remove commas from mac
    mac=$(echo "$mac" | tr -d ':')
    encryption=$(sqlite3 $RECON_DB "SELECT encryption FROM ssid WHERE bssid LIKE '$mac' ORDER BY time DESC LIMIT 1;" 2>&1)

    # Check for error if recon is active in GUI - "Error: in prepare, database is locked"
    if [[ "${encryption,,}" == *error* ]]; then
        echo "$encryption" >&2
        return 1
    fi

    # Encryption not found
    if [[ -z "$encryption" ]]; then
        return 2
    fi

    echo "$encryption"
    return 0
}

# Returns 0 if encryption is OPN. Returns 1 if encryption is not OPN.
is_open_network() {
	local mac="$1"
	local enc="$2"

	# No encryption result - could be OPN or anything
	if [[ -z "$enc" ]]; then
		log_to_file "AP with MAC: $mac encryption value is missing"
		return 1
	fi

	# Encryption is 0 - OPN
	if [[ "$enc" == "0" ]]; then
		return 0
	else
		return 1
	fi
}

alert_evil_twin() {
    declare -A ssid_to_macs

    for ap_json in "${AP_RESULTS[@]}"; do
        mac=$(jq -r '.mac' <<< "$ap_json")
        mapfile -t ssids < <(jq -r '.all_ssids[].ssid' <<< "$ap_json")

        for ssid in "${ssids[@]}"; do
            if [[ -z "$ssid" ]]; then
                log_to_file "Skipping empty SSID with MAC: $mac"
                continue
            fi
            # Append MAC to the list for this SSID
            if [[ -n "${ssid_to_macs["$ssid"]}" ]]; then
                ssid_to_macs["$ssid"]+=",${mac}"
            else
                ssid_to_macs["$ssid"]="$mac"
            fi
        done
    done

    # Check for SSIDs with multiple MACs
    evil_count=0
    for ssid in "${!ssid_to_macs[@]}"; do
        IFS=',' read -ra macs <<< "${ssid_to_macs[$ssid]}"
        if (( ${#macs[@]} > 1 )); then
            declare -A oui_count=()
            declare -A oui_macs=()
            declare -A sus_macs=()

            # Count OUIs for all MACs, are they all using same equipment?
            for mac in "${macs[@]}"; do
                # Ignore spoofing MACs
                if [[ ${SPOOFING_MACS[$mac]} ]]; then
					log_to_file "Skipping spoofing MAC: $mac"
                    continue
                fi

				# Ignore OPN APs
				enc=$(get_encryption $mac)
				status=$?
				if [[ $status -eq 0 ]]; then
					if is_open_network $mac $enc; then
						log_to_file "Skipping MAC: $mac OPN AP"
						continue
					fi
				fi
                oui=$(get_oui "$mac")
                ((oui_count[$oui]++))
                oui_macs[$oui]+="${oui_macs[$oui]:+,}$mac"
            done

            # Find MACs with OUI (manufacturer bytes) that are unique
            for oui in "${!oui_count[@]}"; do
                if (( oui_count[$oui] < 2 )); then
                    sus_macs[$oui]+="${sus_macs[$oui]:+,}${oui_macs[$oui]}"
                fi
            done

            # If only one suspicous MAC
            if (( ${#sus_macs[@]} == 1 )); then
				all_macs=$(echo "${ssid_to_macs[$ssid]}" | tr ',' ' ')
                log_to_file "Potential evil twin SSID: $ssid SUS MAC: ${sus_macs[@]} All MACs: $all_macs}"
                LOG "Potential evil twin for SSID: $ssid\n SUS MAC: ${sus_macs[@]}\n All MACs: $all_macs\n"
            # If only 2 MACs and they are diff manufacturers
            elif (( ${#sus_macs[@]} == 2 )); then
                # Replace MAC string delimiter with spaces for printing
                all_macs=$(echo "${ssid_to_macs[$ssid]}" | tr ',' ' ')
                log_to_file "Potential evil twin for SSID: $ssid All MACs: $all_macs"
                LOG "Potential evil twin for SSID: $ssid\nAll MACs: $all_macs\n"
            # Don't alert if there are multiple sus MACs could be valid APs using different equipment
            else
                # Replace MAC string delimiter with spaces for printing
                all_macs=$(echo "${ssid_to_macs[$ssid]}" | tr ',' ' ')
                log_to_file "Multiple MACs using the same SSID: $ssid All MACs: $all_macs"
            fi

            # Evil twin count
            if (( ${#sus_macs[@]} == 1 || ${#sus_macs[@]} == 2 )); then
                ((evil_count++))
            fi
        fi
    done

	log_to_file "Found $evil_count potential evil twins"
	LOG "Found $evil_count potential evil twins\n"
}

alert_flipper_bt() {
	# Reset Bluetooth adapter to prevent errors/hanging
	hciconfig hci0 down
	hciconfig hci0 up

    while read -r line; do
        mac=${line%% *}
        name=${line#"$mac"}
        name=${name# }

        # Check if MAC is valid
        if [[ ! $mac =~ $VALID_MAC ]]; then
            continue
        fi

        # Add hits, devices that include string "flipper" in name or hardcoded OUI in MAC
        BT_FLIPPERS[$mac]="$name"
    done < <(
        timeout --signal=SIGINT "$BT_TIMEOUT" hcitool -i "$BLE_IFACE" lescan |
        grep -iE "^${FLIPPER_OUI}|${FLIPPER_NAME}" |
        sort -u
    )
        
	# Alert for each BT Flipper device found
    for mac in "${!BT_FLIPPERS[@]}"; do
        name="${BT_FLIPPERS[$mac]}"
        log_to_file "Flipper device found BT Name: $name BT MAC: $mac"
        LOG "Flipper device found\nBT Name: $name\nBT MAC: $mac"
        ALERT "Flipper device found\nBT Name: $name\nBT MAC: $mac"
    done

	log_to_file "Found ${#BT_FLIPPERS[@]} potential Flipper Zero devices"
    LOG "Found ${#BT_FLIPPERS[@]} potential Flipper Zero devices"
}

# Pager default APs
find_pagers() {
    log_to_file "Searching for Hak5 WiFi Pager devices.."
    LOG "Searching for Hak5 WiFi Pager devices.\n"
    # Management AP default name = pager, Open AP default name pager_open or pager-open
    search_ssid_json "ISUBSTRING" "pager"
    log_to_file "Found ${#AP_RESULTS[@]} APs with substring 'pager'"
    LOG "Found ${#AP_RESULTS[@]} APs with substring 'pager'\n"
    alert_sus_aps
}

# Wifi Pineapple default APS
find_pineapples() {
    log_to_file "Searching for Hak5 WiFi Pineapple devices.."
    LOG "Searching for Hak5 WiFi Pineapple devices.\n"
    search_ssid_json "ISUBSTRING" "pineapple"
    log_to_file "Found ${#AP_RESULTS[@]} APs with substring 'pineapple'"
    LOG "Found ${#AP_RESULTS[@]} APs with substring 'pineapple'\n"
    alert_sus_aps
}

# Orbic RC400L device - Hotspot device most commonly used with rayhunter software
# Can be a false positive and be used as a normal hotspot without software
find_rayhunters() {
    log_to_file "Searching for stingray hunter devices.."
    LOG "Searching for stingray hunter devices..\n"
    # Default SSID for Orbic RC400L device
    search_ssid_json "ISUBSTRING" "RC400L"
    log_to_file "Found ${#AP_RESULTS[@]} APs with substring 'RC400L'"
    LOG "Found ${#AP_RESULTS[@]} APs with substring 'RC400L'\n"
    alert_sus_aps
}

# Wifi Pineapple / Pager with "mimic open networks" & "advertise networks" on
# SSIDs will change rapidly for the same MAC - Karma attack if OPN
find_spoofing_aps() {
    log_to_file "Searching for APs spoofing networks.."
    LOG "Searching for APs spoofing networks..\n"
    search_ssid_json "" ""
    alert_aps_spoofing_ssids
}

# Find evil twins
# Using AP_RESULTS from find_spoofing_aps
find_evil_twins() {
    log_to_file "Searching for evil twin APs.."
    LOG "Searching for evil twin APs.."
    alert_evil_twin
}

# Flipper default bluetooth name
find_flippers() {
    killall hcitool 2>/dev/null
    log_to_file "Searching for Flipper devices via Bluetooth.."
    LOG "Searching for Flipper devices via Bluetooth.."
    alert_flipper_bt
}

# Trap signals: Ensures cleanup runs on Exit, Ctrl+C (SIGINT) or Kill (SIGTERM)
# SOURCE: oMen (BT Pager Warden payload)
trap cleanup EXIT SIGINT SIGTERM
setup

while true; do
    # Get all APs and save to a JSON file
    get_aps_json

    # Search for hacking devices
    find_pagers
    find_pineapples
    find_rayhunters
    find_spoofing_aps
    find_evil_twins
    find_flippers

    # Wait until next scan
    sleep "$SLEEP_BETWEEN_SCANS"
    LOG "\n\n"
done