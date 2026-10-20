#!/bin/bash
# Title: Power Aware Display
# Description: Keep screen on with external power; configurable power and battery timers.
# Author: Christophe
# Version: 0.3
# Category: General

PAD_HOME="${_PAYLOAD_HOME:-$(cd "$(dirname "$0")" && pwd)}"
. "$PAD_HOME/controller.sh"

calibrate_menu() {
    local external battery el eh bl bh
    "$PAD_INIT" running >/dev/null 2>&1 && {
        PROMPT 'Disable the service before calibration.'; return;
    }
    PROMPT $'Connect external USB power.\nWait until connected, then press green.\nSix current samples will be taken.' || return
    external=$(sample) || { PROMPT 'Cannot read battery current.'; return; }
    PROMPT $'Now unplug external USB power.\nLeave the Pager running on its battery.\nPress green to sample.' || return
    battery=$(sample) || { PROMPT 'Cannot read battery current.'; return; }
    read -r el eh <<< "$external"
    read -r bl bh <<< "$battery"
    if save_calibration "$el" "$eh" "$bl" "$bh"; then
        PROMPT $'Calibration saved.\nReconnect USB power if desired.\nChoose Enable to start the service.'
    else
        PROMPT $'Power readings were not distinct enough.\nCalibration was not changed.\nDo not enable until this is resolved.'
    fi
}

edit_timeout() {
    local source=$1 value label=Battery
    load_settings || { PROMPT 'Invalid timeout settings'; return; }
    if [[ "$source" == battery ]]; then value=$battery_seconds; else value=$external_seconds; fi
    [[ "$source" == external ]] && label=USB
    # Keep the title short enough for the native 480-pixel display.
    value=$(NUMBER_PICKER "$label sec (0=Never)" "$value") || return
    if [[ "$source" == battery ]]; then
        save_settings "$value" "$external_seconds" || { PROMPT 'Use 0 (Never), or 15 to 86400 seconds.'; return; }
    else
        save_settings "$battery_seconds" "$value" || { PROMPT 'Use 0 (Never), or 15 to 86400 seconds.'; return; }
    fi
    PROMPT 'Saved. An enabled service applies this automatically.'
}
while true; do
    choice=$(LIST_PICKER 'Power Aware Display' 'Status' 'Battery timeout' 'External timeout' 'Recent events' 'Calibrate power' 'Enable' 'Disable' 'Exit' 'Status') || exit 0
    case "$choice" in
        Status) PROMPT "$(status)" ;;
        'Battery timeout') edit_timeout battery ;;
        'External timeout') edit_timeout external ;;
        'Recent events') PROMPT "$(tail -n 8 "$PAD_RUN/events" 2>/dev/null || echo 'No events yet')" ;;
        'Calibrate power') calibrate_menu ;;
        Enable)
            if result=$(enable_service 2>&1); then
                PROMPT $'Enabled, including after reboot.\nPhysical buttons reset the timer.\nCheck Status for the active profile.'
            else PROMPT "Could not enable: $result"; fi ;;
        Disable)
            if result=$(disable_service 2>&1); then PROMPT 'Disabled. Native display control restored.'
            else PROMPT "Could not disable: $result"; fi ;;
        *) exit 0 ;;
    esac
done
