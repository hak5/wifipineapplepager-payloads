#!/bin/bash
# Title: Channel Capture
# Author: Hak5Darren
# Description: Record filtered or full PCAPs on the selected AP channel. Optional AP-only scope. Time and size limits, disk reserve protection, and packet summaries. Pcap files saved to loot.
# Version: 1.0

bssid="${_RECON_SELECTED_AP_BSSID:-${_RECON_SELECTED_AP_MAC_ADDRESS:-}}"
channel="${_RECON_SELECTED_AP_CHANNEL:-}"
ssid="${_RECON_SELECTED_AP_SSID:-${_RECON_SELECTED_AP_BEACONED_SSID:-Hidden AP}}"
ssid="${ssid//$'\n'/ }"
ssid="${ssid//$'\r'/ }"
ssid="${ssid//$'\t'/ }"
capture_active=0
channel_locked=0
pcap_file=""
reserve_bytes=100000000
recording_depth="Small"
tcpdump_pid=""
capture_error_file=""
ap_only=0
capture_filter=()

filter_saved_capture() {
    local filtered_file="${pcap_file%.pcap}.ap-only-$$.pcap"
    (set -o noclobber; : > "$filtered_file") || return 1
    LOG "Keeping only the selected AP's frames in the saved PCAP"
    if ! tcpdump -r "$pcap_file" -w "$filtered_file" "${capture_filter[@]}"; then
        LOG "AP filtering failed. Original: $pcap_file; partial: $filtered_file"
        return 1
    fi
    mv "$filtered_file" "$pcap_file"
}

summarize_capture() {
    summary_file="${pcap_file%.pcap}.summary-$$.txt"
    (set -o noclobber; : > "$summary_file") || return 1
    (
        set -o pipefail
        LC_ALL=C tcpdump -nn -e -tt -q -r "$pcap_file" | LC_ALL=C awk '
        /^[0-9]+[.][0-9]+ / {
            packets++; found=0
            for(i=1;i<=NF;i++) if($i=="MHz" && $(i-1) ~ /^[0-9]+$/) {
                f=$(i-1)+0; frequencies[f]++; found=1; break
            }
            if(!found) unknown++
        }
        END {
            print "Packets: " packets+0
            for(f in frequencies) remaining++
            shown=0; compact=""
            while(remaining>0) {
                lowest=1000000
                for(f in frequencies) if(f+0<lowest) lowest=f+0
                if(lowest==2484) ch=14
                else if(lowest>=2412 && lowest<=2472 && (lowest-2407)%5==0) ch=(lowest-2407)/5
                else if(lowest==5935) ch=2
                else if(lowest>=5955 && lowest<=7115 && (lowest-5950)%5==0) ch=(lowest-5950)/5
                else if(lowest>=5000 && lowest<5935 && lowest%5==0) ch=(lowest-5000)/5
                else ch="?"
                label=ch "@" lowest "MHz: " frequencies[lowest]
                print "Channel " label
                if(shown<3) {compact=compact (shown ? ", " : "") label; shown++}
                else extra++
                delete frequencies[lowest]; remaining--
            }
            if(extra) compact=compact ", +" extra " more"
            if(unknown) {
                print "Unknown channel: " unknown
                compact=compact (compact!="" ? ", " : "") "unknown: " unknown
            }
            if(compact=="") compact="none (empty PCAP)"
            print "Seen: " compact
        }'
    ) > "$summary_file" || return 1
    packet_count=""; channel_summary=""
    while IFS= read -r summary_line; do
        LOG "$summary_line"
        case "$summary_line" in
            'Packets: '*) packet_count="${summary_line#Packets: }" ;;
            'Seen: '*) channel_summary="${summary_line#Seen: }" ;;
        esac
    done < "$summary_file"
    [[ "$packet_count" =~ ^[0-9]+$ && -n "$channel_summary" ]]
}

read_free_space() {
    local disk_report free_kb
    disk_report=$(df -Pk /mmc 2>/dev/null) || return 1
    free_kb=$(printf '%s\n' "$disk_report" | awk '$1 == "/dev/mmcblk0p1" && $NF == "/mmc" {print $4}')
    [[ "$free_kb" =~ ^[0-9]+$ ]] || return 1
    free_bytes=$((free_kb * 1024))
}

require_space() {
    local required="$1"
    if ! read_free_space; then
        PROMPT "Cannot verify free space on /mmc.\nNo file recorded."
        return 1
    fi
    if (( free_bytes <= reserve_bytes || required > free_bytes - reserve_bytes )); then
        LOG "Insufficient /mmc space: $free_bytes bytes free; $required bytes requested; 100 MB reserve"
        printf -v space_message 'Insufficient disk space on /mmc.\n\nFree: %s MB\nRequired: %s MB + 100 MB reserve\n\nNo file recorded.' \
            "$((free_bytes / 1000000))" "$((required / 1000000))"
        PROMPT "$space_message"
        return 1
    fi
}

no_recording() {
    PROMPT "No file recorded"
    exit 0
}

fail() {
    LOG "$1"
    ERROR_DIALOG "$1"
    exit 1
}

cleanup() {
    local result=0 report_tcpdump=0 diagnostic
    if (( capture_active )); then
        if [[ "$recording_depth" == "Large" ]]; then
            if kill -0 "$tcpdump_pid" 2>/dev/null; then
                kill -INT "$tcpdump_pid" 2>/dev/null || result=1
            fi
            wait "$tcpdump_pid" || result=1
            capture_active=0
            tcpdump_pid=""
            report_tcpdump=1
        elif WIFI_PCAP_STOP; then
            capture_active=0
        else
            LOG "Failed to stop recording"
            result=1
        fi
    fi
    if (( channel_locked )); then
        if PINEAPPLE_EXAMINE_RESET; then
            channel_locked=0
        else
            LOG "Failed to resume channel hopping"
            result=1
        fi
    fi
    if (( report_tcpdump )) && [[ -s "$capture_error_file" ]]; then
        while IFS= read -r diagnostic; do LOG "$diagnostic"; done < "$capture_error_file"
    fi
    return "$result"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

positive_integer() {
    [[ "$1" =~ ^[0-9]{1,10}$ ]] || return 1
    (( 10#$1 > 0 && 10#$1 <= $2 ))
}

read_size() {
    file_bytes=$(wc -c < "$pcap_file") || return 1
    file_bytes="${file_bytes//[[:space:]]/}"
    [[ "$file_bytes" =~ ^[0-9]+$ ]]
}

format_size() {
    local bytes="$1"
    printf '%s.%03s MB (%s bytes)' "$((bytes / 1000000))" \
        "$(printf '%03d' "$(((bytes % 1000000) / 1000))")" "$bytes"
}

if [[ ! "$bssid" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] ||
   [[ ! "$channel" =~ ^[0-9]+$ ]]; then
    fail "Select an access point in Recon first (BSSID and channel required)."
fi

require_space 0 || exit 0

if ! confirmed=$(CONFIRMATION_DIALOG "Record $bssid channel $channel ?"); then
    no_recording
fi
[[ "$confirmed" == "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]] || no_recording

small_option="Filtered data (small)"
large_option="Unfiltered (large)"
while true; do
    depth_choice=$(LIST_PICKER "Recording depth?" "$small_option" "$large_option" "Help" "$small_option") || no_recording
    case "$depth_choice" in
        "$small_option") recording_depth="Small"; break ;;
        "$large_option") recording_depth="Large"; break ;;
        Help)
            PROMPT $'Small: Optimized Recon PCAP.\nFilters/trims data frames to reduce size. May include both radios.\n\nLarge: Full packets from wlan1mon on the selected channel. Includes all frame types and encrypted traffic as received. Optional AP-only scope narrows the traffic. Files grow faster.'
            ;;
        *) fail "Unexpected recording depth selection." ;;
    esac
done

ap_option="AP only: $ssid"
while true; do
    scope_choice=$(LIST_PICKER "Capture scope?" "All traffic" "$ap_option" "Help" "All traffic") || no_recording
    case "$scope_choice" in
        "All traffic") break ;;
        "$ap_option")
            ap_only=1
            capture_filter=("wlan addr1 $bssid or wlan addr2 $bssid or wlan addr3 $bssid or wlan addr4 $bssid")
            break
            ;;
        Help)
            PROMPT $'All traffic: Keep traffic from every AP seen by the capture method.\n\nAP only: Only keep traffic from '"$ssid ($bssid). Ignore other APs on channel $channel."$'\n\nUnfiltered mode filters during capture. Small mode filters the saved PCAP afterward and needs temporary disk space.'
            ;;
        *) fail "Unexpected capture scope selection." ;;
    esac
done

command -v tcpdump >/dev/null 2>&1 || fail "tcpdump is required for packet summaries and AP filtering."
if [[ "$recording_depth" == "Large" ]]; then
    command -v tcpdump >/dev/null 2>&1 || fail "tcpdump is required for Large recordings."
    [[ -d /sys/class/net/wlan1mon ]] || fail "wlan1mon is unavailable. Start Wi-Fi Recon first."
fi

seconds=$(NUMBER_PICKER "Seconds to record?" 30) || no_recording
positive_integer "$seconds" 2147483642 || fail "Seconds must be a positive whole number (max 2147483642)."
seconds=$((10#$seconds))

max_mb=$(NUMBER_PICKER "Max file size (MB)?" 10) || no_recording
positive_integer "$max_mb" 2147483647 || fail "Size must be a positive whole number (max 2147483647 MB)."
max_mb=$((10#$max_mb))
max_bytes=$((max_mb * 1000000))
required_bytes=$max_bytes
if (( ap_only )) && [[ "$recording_depth" == "Small" ]]; then
    required_bytes=$((max_bytes * 2))
fi
require_space "$required_bytes" || exit 0

channel_locked=1
if ! PINEAPPLE_EXAMINE_BSSID "$bssid" "$((seconds + 5))"; then
    cleanup
    fail "Could not lock the selected access point's channel."
fi

sleep 1
if ! require_space "$required_bytes"; then
    cleanup
    exit 0
fi

if [[ "$recording_depth" == "Large" ]]; then
    mkdir -p /root/loot/pcap || fail "Cannot create the PCAP loot directory."
    pcap_file="/root/loot/pcap/pcap-full-$(date +%Y%m%d-%H%M%S)-$$.pcap"
    capture_error_file="${pcap_file%.pcap}.log"
    (set -o noclobber; : > "$pcap_file") || fail "Cannot reserve a new PCAP file."
    (set -o noclobber; : > "$capture_error_file") || fail "Cannot reserve the capture log."
    tcpdump -i wlan1mon -s 0 -U -w "$pcap_file" "${capture_filter[@]}" 2>"$capture_error_file" &
    tcpdump_pid=$!
    capture_active=1
else
    capture_active=1
    if ! pcap_file=$(WIFI_PCAP_START); then
        cleanup
        fail "Could not start recording."
    fi
fi
started_at=$SECONDS
if [[ -z "$pcap_file" || "$pcap_file" != /* || "$pcap_file" == *$'\n'* ]]; then
    cleanup
    fail "Capture command did not return one absolute filename."
fi
filename="${pcap_file##*/}"
LOG "Recording $bssid channel $channel"
LOG "Depth: $recording_depth"
if (( ap_only )); then LOG "Scope: $ap_option ($bssid)"; else LOG "Scope: All traffic"; fi
[[ "$recording_depth" != "Large" ]] || LOG "Interface: wlan1mon; full packets"
LOG "PCAP: $pcap_file"
LOG "Limit: $seconds seconds / $max_mb MB (1 MB = 1000000 bytes)"

size_limited=0
space_limited=0
while (( SECONDS - started_at < seconds )); do
    sleep 1
    elapsed=$((SECONDS - started_at))
    if [[ "$recording_depth" == "Large" ]] && ! kill -0 "$tcpdump_pid" 2>/dev/null; then
        cleanup
        fail "tcpdump stopped unexpectedly. Check the Payload Log."
    fi
    if ! read_size; then
        cleanup
        fail "Cannot read capture size: $filename"
    fi
    LOG "${elapsed}s: $(format_size "$file_bytes")"
    if (( file_bytes >= max_bytes )); then
        size_limited=1
        break
    fi
    if ! read_free_space; then
        cleanup
        fail "Cannot verify free space on /mmc. Recording stopped."
    fi
    runtime_reserve=$reserve_bytes
    if (( ap_only )) && [[ "$recording_depth" == "Small" ]]; then
        runtime_reserve=$((reserve_bytes + file_bytes))
    fi
    if (( free_bytes <= runtime_reserve )); then
        space_limited=1
        break
    fi
done

elapsed=$((SECONDS - started_at))
if ! cleanup; then
    fail "Recording cleanup failed. Check the Payload Log."
fi
if (( ap_only )) && [[ "$recording_depth" == "Small" ]]; then
    read_size || fail "Cannot read capture size before AP filtering."
    if ! read_free_space || (( free_bytes < reserve_bytes + file_bytes )); then
        fail "Cannot filter the PCAP safely. Original capture retained: $filename"
    fi
    filter_saved_capture || fail "AP filtering failed. Check the Payload Log; original capture retained."
fi
read_size || fail "Cannot read final capture size: $filename"
pcap_size=$(format_size "$file_bytes")
LOG "Saved: $pcap_file"
LOG "Time: ${elapsed}s; Size: $pcap_size"

if (( space_limited )); then
    stop_reason="100 MB disk reserve reached"
    result_title="Recording stopped:"
elif (( size_limited )); then
    stop_reason="Max file size reached"
    result_title="Recording successful:"
else
    stop_reason="Time limit reached"
    result_title="Recording successful:"
fi
LOG "Stop reason: $stop_reason"
if ! summarize_capture; then
    packet_count="unavailable"
    channel_summary="unavailable (summary failed)"
    LOG "Packet/channel summary failed; PCAP retained: $pcap_file"
fi
if [[ "$recording_depth" == "Small" ]]; then mode_label="$small_option"; else mode_label="$large_option"; fi
if (( ap_only )); then scope_label="AP only"; else scope_label="All traffic"; fi
printf -v message '%s\n\nMode: %s\nScope: %s\nStop: %s\nChannel: %s\nTime: %ss of %ss\nSize: %s\nPackets: %s\n\n%s' \
    "$result_title" "$mode_label" "$scope_label" "$stop_reason" "$channel" "$elapsed" "$seconds" \
    "$pcap_size" "$packet_count" "$filename"
PROMPT "$message"
