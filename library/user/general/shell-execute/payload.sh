#!/bin/bash
# Title: Shell Execute
# Author: Hak5Darren
# Description: Run custom or preset shell commands and view their output in the payload log.
# Version: 1.0

LOOT_DIR=/mmc/root/loot/shell-execute
log_file=""
labels=("IP Addresses" "Routes" "Ping 1.1.1.1" "WiFi Info" "RAM Usage" "Disk Usage" "USB Devices" "System Log" "Kernel Log" "Top Processes" "Uptime")
commands=()
while IFS= read -r command; do
    commands+=("$command")
done <<'COMMANDS'
ip -o -4 addr show | awk '{print $2, $4}'
ip route
ping -c 2 1.1.1.1
iwinfo | awk '/^[^[:space:]]/{print "\n"$1} /Mode:/{if(match($0,/Mode: [^ ]+/))print "  "substr($0,RSTART,RLENGTH)} /ESSID:/{s=$0;sub(/.*ESSID: /,"",s);print "  SSID: "s} /Channel:/{if(match($0,/Channel: [0-9]+/))print "  "substr($0,RSTART,RLENGTH)} /Signal:/{if(match($0,/Signal: -?[0-9]+/))print "  "substr($0,RSTART,RLENGTH)" dBm"}'
free -m | awk '/^Mem:/ {printf "RAM: %d MB used / %d MB total\n", $3, $2; printf "Available: %d MB\n", $7}'
df -h | awk 'NR>1 {printf "%-12s %s/%s (%s)\n", $6, $3, $2, $5}'
lsusb | awk '{printf "%s:%s %s %s\n", $2, $4, $6, substr($0,index($0,$7),30)}'
logread | tail -20
dmesg | tail -30
top -b -n 1 | awk '/PID.*USER/ {p=1;next} p && NF>=7 {printf "%5s %5s %5s %s\n",$1,$7,$4,$NF;if(++n==10)exit}'
uptime
COMMANDS

custom_commands=("echo 'Custom 1'" "echo 'Custom 2'" "echo 'Custom 3'")
for index in "${!custom_commands[@]}"; do
    if saved_command=$(PAYLOAD_GET_CONFIG shell_execute "c$((index + 1))_command") && [[ "$saved_command" =~ [^[:space:]] ]]; then
        custom_commands[index]="$saved_command"
    fi
done

open_log() {
    local candidate
    [[ -n "$log_file" ]] && return 0
    mkdir -p "$LOOT_DIR" || return 1
    while true; do
        candidate="$LOOT_DIR/run-$(date +%Y%m%d-%H%M%S).log"
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            sleep 1
            continue
        fi
        if (set -o noclobber; : > "$candidate") 2>/dev/null; then
            log_file="$candidate"
            return 0
        fi
        [[ -e "$candidate" || -L "$candidate" ]] || return 1
    done
}

run_command() {
    local command="$1" line status
    local -a statuses
    LOG green "$command"
    if open_log; then
        printf '%s\n' "$command" >> "$log_file"
    else
        LOG red "Cannot save loot; output will still appear here."
    fi
    bash -o pipefail -c "$command" </dev/null 2>&1 |
        while IFS= read -r line || [[ -n "$line" ]]; do
            LOG "$line"
            if [[ -n "$log_file" ]]; then
                printf '%s\n' "$line" >> "$log_file"
            fi
        done
    statuses=("${PIPESTATUS[@]}")
    status=${statuses[0]}
    if (( status != 0 )); then
        LOG red "Exit status: $status"
    fi
    if [[ -n "$log_file" ]]; then
        printf '\nExit status: %s\n' "$status" >> "$log_file"
        LOG blue "Saved: loot/shell-execute/${log_file##*/}"
    fi
    LOG red "Press A to enter a command"
}

LOG red "Press A to enter a command"
while true; do
    WAIT_FOR_BUTTON_PRESS A || exit 1
    custom_labels=()
    for index in "${!custom_commands[@]}"; do
        custom_labels+=("C$((index + 1)): ${custom_commands[index]}")
    done
    if ! choice=$(LIST_PICKER "Shell Execute" "Enter Command" "${labels[@]}" "${custom_labels[@]}" "Exit" "Enter Command"); then
        continue
    fi
    case "$choice" in
        "Enter Command")
            command=$(TEXT_PICKER "Shell Command?" "") || continue
            [[ "$command" =~ [^[:space:]] ]] || continue
            response=$(CONFIRMATION_DIALOG "Run?:"$'\n\n'" $command") || continue
            [[ "$response" == "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]] || continue
            run_command "$command"
            ;;
        "Exit")
            exit 0
            ;;
        "${custom_labels[0]}"|"${custom_labels[1]}"|"${custom_labels[2]}")
            for index in "${!custom_labels[@]}"; do
                [[ "$choice" == "${custom_labels[index]}" ]] && break
            done
            command=$(TEXT_PICKER "Shell Command?" "${custom_commands[index]}") || continue
            [[ "$command" =~ [^[:space:]] ]] || continue
            response=$(CONFIRMATION_DIALOG "Save and execute?") || continue
            case "$response" in
                "${DUCKYSCRIPT_USER_CONFIRMED:-1}")
                    if ! PAYLOAD_SET_CONFIG shell_execute "c$((index + 1))_command" "$command"; then
                        LOG red "Could not save custom command."
                    fi
                    ;;
                *) continue ;;
            esac
            custom_commands[index]="$command"
            run_command "$command"
            ;;
        *)
            for index in "${!labels[@]}"; do
                if [[ "$choice" == "${labels[index]}" ]]; then
                    run_command "${commands[index]}"
                    break
                fi
            done
            ;;
    esac
done
