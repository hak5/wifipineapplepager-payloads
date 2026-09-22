#!/bin/bash
# Title: Recon Toggle
# Author: DMac
# Description: Toggle Wi-Fi recon (pineapd) on/off to save battery while setting up
# Version: 1.0
#
# One payload, two actions. State is reconciled through a /tmp marker:
#   /tmp clears on reboot and recon auto-starts on boot, so "no marker" always
#   means "recon is running" -- no drift after a restart.
#     First run  -> PAUSE  (stop recon + drop the monitor radios)
#     Next  run  -> RESUME (bring radios back + restart recon)

MARKER="/tmp/recon_paused"
PINEAP="/usr/bin/_pineap"

# Pull recon name + enabled monitor interfaces from uci so this tracks your
# config instead of hard-coding device names.
RECON_NAME="$(uci -q get pineapd.@pineapd[0].reconname || echo pager)"

get_mon_ifaces() {
    local idx=0 name disabled
    while name="$(uci -q get pineapd.@interface[$idx].device 2>/dev/null)"; do
        [ -z "$name" ] && break
        disabled="$(uci -q get pineapd.@interface[$idx].disable || echo 0)"
        [ "$disabled" = "0" ] && echo "$name"
        idx=$((idx + 1))
    done
}

pause_recon() {
    id=$(START_SPINNER "Pausing")
    "$PINEAP" recon stop >/dev/null 2>&1
    for dev in $(get_mon_ifaces); do
        "$PINEAP" interface disable "$dev" >/dev/null 2>&1
    done
    touch "$MARKER"
    STOP_SPINNER ${id}
    LED R SLOW
    LOG yellow "Recon paused
                radios down
                battery drain reduced"
}

resume_recon() {
    id=$(START_SPINNER "Resuming")
    for dev in $(get_mon_ifaces); do
        "$PINEAP" interface enable "$dev" >/dev/null 2>&1
    done
    "$PINEAP" recon new "$RECON_NAME" >/dev/null 2>&1
    rm -f "$MARKER"
    STOP_SPINNER ${id}
    LED G SOLID
    LOG green "Recon resumed as '${RECON_NAME}'"
    ( sleep 2 && LED OFF ) &
}

if [ -f "$MARKER" ]; then
    resume_recon
else
    pause_recon
fi

exit 0
