#!/bin/bash
# Title: Remove Payloads
# Description: Removes all MetaPayload generated payloads
# Author: spencershepard (GRIMM)
# Version: 1.0

METAPAYLOAD_DIR="/root/payloads/user/metapayload"
CONFIG_DIR="$METAPAYLOAD_DIR/config"
PAYLOADS_DIR="/root/payloads"
ENV_FILE="$METAPAYLOAD_DIR/.env"

LOG "Starting MetaPayload payload removal..."

# Ask user what to remove
resp=$(CONFIRMATION_DIALOG "Remove all generated payloads?

This will delete all MetaPayload generated payloads as defined in configuration files.")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG red "Error in dialog"
        exit 1
        ;;
esac

case "$resp" in
    $DUCKYSCRIPT_USER_DENIED)
        LOG "Removal cancelled"
        exit 0
        ;;
esac

# Track removed items
REMOVED_COUNT=0
FAILED_COUNT=0

# Function to safely remove directory
remove_directory() {
    local dir="$1"
    local name="$2"
    
    if [ -d "$dir" ]; then
        if rm -rf "$dir" 2>/dev/null; then
            LOG green "Removed: $name"
            ((REMOVED_COUNT++))
        else
            LOG red "Failed to remove: $name"
            ((FAILED_COUNT++))
        fi
    fi
}

# Function to remove payload and its client copy
remove_payload() {
    local path="$1"
    local payload_dir="$PAYLOADS_DIR/$path"
    
    # Remove main payload directory
    remove_directory "$payload_dir" "$path"
    
    # Remove client directory copy if it exists
    local hyphenated_path=$(echo "$path" | tr '/_' '-' | tr '[:upper:]' '[:lower:]')
    local client_payload_dir="/root/payloads/client/$hyphenated_path"
    
    if [ -d "$client_payload_dir" ]; then
        remove_directory "$client_payload_dir" "client/$hyphenated_path"
    fi
}

# Verify config directory exists
if [ ! -d "$CONFIG_DIR" ]; then
    LOG red "Error: Config directory not found at $CONFIG_DIR"
    LOG yellow "Nothing to remove"
    exit 0
fi

# Remove payloads defined in config files
LOG "Scanning configuration files..."
for config_file in "$CONFIG_DIR"/*.json; do
    if [ ! -f "$config_file" ]; then
        continue
    fi
    
    LOG "Processing config: $(basename "$config_file")"
    
    # Read payloads from config
    payload_count=$(jq '.payloads | length' "$config_file" 2>/dev/null)
    
    if [ -z "$payload_count" ] || [ "$payload_count" == "null" ]; then
        LOG yellow "Warning: Could not parse $(basename "$config_file")"
        continue
    fi
    
    for ((i=0; i<$payload_count; i++)); do
        # Extract payload path
        path=$(jq -r ".payloads[$i].path" "$config_file")
        
        if [ -n "$path" ] && [ "$path" != "null" ]; then
            remove_payload "$path"
        fi
    done
done

# Remove Set_Variables payloads
LOG "Removing Set_Variables payloads..."

for set_dir in "$METAPAYLOAD_DIR"/Set_*; do
    if [ -d "$set_dir" ]; then
        remove_directory "$set_dir" "$(basename "$set_dir")"
    fi
done

# Ask about removing payload folders with their .env files
resp=$(CONFIRMATION_DIALOG "Remove payload folders?

Global variables will be preserved.
WARNING: Payload-specific saved variables will be reset!")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG yellow "Skipping payload folder removal"
        ;;
    *)
        case "$resp" in
            $DUCKYSCRIPT_USER_CONFIRMED)
                # Remove all payload folders (which includes .env files)
                LOG "Removing all payload folders..."
                for config_file in "$CONFIG_DIR"/*.json; do
                    if [ ! -f "$config_file" ]; then
                        continue
                    fi
                    
                    payload_count=$(jq '.payloads | length' "$config_file" 2>/dev/null)
                    
                    if [ -z "$payload_count" ] || [ "$payload_count" == "null" ]; then
                        continue
                    fi
                    
                    for ((i=0; i<$payload_count; i++)); do
                        path=$(jq -r ".payloads[$i].path" "$config_file")
                        
                        if [ -n "$path" ] && [ "$path" != "null" ]; then
                            payload_dir="$PAYLOADS_DIR/$path"
                            # Check if directory still exists (might have been removed already)
                            if [ -d "$payload_dir" ]; then
                                remove_directory "$payload_dir" "$path (with config)"
                            fi
                        fi
                    done
                done
                ;;
            *)
                LOG "Keeping payload folders"
                ;;
        esac
        ;;
esac

# Summary
LOG ""
LOG purple "==================================="
LOG purple "Removal Summary"
LOG purple "==================================="
LOG green "Successfully removed: $REMOVED_COUNT items"
if [ $FAILED_COUNT -gt 0 ]; then
    LOG red "Failed to remove: $FAILED_COUNT items"
fi
LOG purple "==================================="

if [ $FAILED_COUNT -gt 0 ]; then
    LOG yellow "Some items could not be removed. Check permissions."
    exit 1
fi

LOG green "Payload removal complete!"
exit 0
