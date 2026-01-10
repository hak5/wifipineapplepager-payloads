#!/bin/bash
# Title:                SpeedTest Config
# Description:          Configure SpeedTest payload settings
# Author:               billyjbryant
# Version:              1.0

PAYLOAD_NAME="speedtest"

LOG cyan "SpeedTest Config"

# Get current loot generation setting
current_loot_setting=$(PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "generate_loot" 2>/dev/null)
current_loot_status="disabled"
[ "$current_loot_setting" = "yes" ] && current_loot_status="enabled"

LOG blue "Current loot generation: $current_loot_status"

if [ "$current_loot_setting" = "yes" ]; then
    if CONFIRMATION_DIALOG "Loot generation is enabled.\n\nDisable loot file generation?"; then
        PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "generate_loot" "no"
        LOG yellow "Loot generation disabled"
    else
        LOG "Loot generation setting unchanged"
    fi
else
    if CONFIRMATION_DIALOG "Loot generation is disabled.\n\nEnable loot file generation?"; then
        PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "generate_loot" "yes"
        LOG green "Loot generation enabled"
    else
        LOG "Loot generation setting unchanged"
    fi
fi

# Get current skip upload setting
current_upload_setting=$(PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "skip_upload" 2>/dev/null)
current_upload_status="disabled"
[ "$current_upload_setting" = "yes" ] && current_upload_status="enabled"

LOG blue "Current skip upload test: $current_upload_status"

if [ "$current_upload_setting" = "yes" ]; then
    if CONFIRMATION_DIALOG "Skip upload test is enabled.\n\nDisable skip upload test?"; then
        PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "skip_upload" "no"
        LOG yellow "Skip upload test disabled"
    else
        LOG "Skip upload test setting unchanged"
    fi
else
    if CONFIRMATION_DIALOG "Skip upload test is disabled.\n\nEnable skip upload test?"; then
        PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "skip_upload" "yes"
        LOG green "Skip upload test enabled"
    else
        LOG "Skip upload test setting unchanged"
    fi
fi

LOG green "Configuration complete"
