#!/bin/bash
# Title: List Payloads
# Description: Lists all available MetaPayload payloads from configuration files
# Author: spencershepard (GRIMM)
# Version: 1.0

METAPAYLOAD_DIR="/root/payloads/user/metapayload"
CONFIG_DIR="$METAPAYLOAD_DIR/config"

LOG "Scanning MetaPayload payload configurations..."

# Verify config directory exists
if [ ! -d "$CONFIG_DIR" ]; then
    LOG red "Error: Config directory not found at $CONFIG_DIR"
    exit 1
fi

# Check if any config files exist
config_count=$(ls -1 "$CONFIG_DIR"/*.json 2>/dev/null | wc -l)
if [ "$config_count" -eq 0 ]; then
    LOG yellow "No configuration files found in $CONFIG_DIR"
    exit 0
fi

# Count total payloads first
TOTAL_PAYLOADS=0
for config_file in "$CONFIG_DIR"/*.json; do
    if [ ! -f "$config_file" ]; then
        continue
    fi
    
    payload_count=$(jq '.payloads | length' "$config_file" 2>/dev/null)
    if [ -n "$payload_count" ] && [ "$payload_count" != "null" ]; then
        ((TOTAL_PAYLOADS+=payload_count))
    fi
done

# Display summary header
LOG purple "═══════════════════════════════════════════"
LOG purple "MetaPayload Payload Catalog"
LOG purple "═══════════════════════════════════════════"
LOG purple "Total Payloads: $TOTAL_PAYLOADS"
LOG purple "═══════════════════════════════════════════"
LOG ""

# Process and display each payload
for config_file in "$CONFIG_DIR"/*.json; do
    if [ ! -f "$config_file" ]; then
        continue
    fi
    
    LOG "Processing: $(basename "$config_file")"
    
    # Read payloads from config
    payload_count=$(jq '.payloads | length' "$config_file" 2>/dev/null)
    
    if [ -z "$payload_count" ] || [ "$payload_count" == "null" ]; then
        LOG yellow "Warning: Could not parse $(basename "$config_file")"
        continue
    fi
    
    for ((i=0; i<$payload_count; i++)); do
        # Extract payload data
        name=$(jq -r ".payloads[$i].name" "$config_file")
        path=$(jq -r ".payloads[$i].path" "$config_file")
        description=$(jq -r ".payloads[$i].description" "$config_file")
        required_vars=$(jq -c ".payloads[$i].required_vars" "$config_file")
        author=$(jq -r ".payloads[$i].author" "$config_file")
        
        # Build required vars string
        req_vars_str=""
        if [ "$required_vars" != "null" ] && [ "$required_vars" != "[]" ]; then
            req_vars_str=$(echo "$required_vars" | jq -r '.[]' | tr '\n' ', ' | sed 's/,$//')
        else
            req_vars_str="None"
        fi
        
        # Display payload info
        LOG ""
        LOG "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        LOG purple "${name}"
        LOG "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        LOG "Path: ${path}"
        LOG yellow "Description: ${description}"
        LOG "Required Variables: ${req_vars_str}"
    done
done

LOG ""
LOG green "Scan complete! Found $TOTAL_PAYLOADS payloads"
exit 0
