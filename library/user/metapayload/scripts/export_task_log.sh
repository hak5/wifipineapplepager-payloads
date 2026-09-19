#!/bin/bash
# Title: Export Task Log
# Description: This script is called when you select 'export' from the task log menu.
# Author: spencershepard (GRIMM)

TASK_ID="${1}"
TASK_LOG_PATH="/root/payloads/user/metapayload/.tasks/${TASK_ID}.log"

# Load Metapayload configuration if it exists  
if [ -f /root/.metapayload ]; then
    source /root/.metapayload
fi


# ------------------------
## Export to loot directory
# ------------------------ 

mkdir -p /root/loot/metapayload
cp "$TASK_LOG_PATH" "/root/loot/metapayload/${TASK_ID}.log"
echo "Task log exported to /root/loot/metapayload/${TASK_ID}.log"



# ------------------------
## Export to Discord Webhook
## Requires: METAPAYLOAD_DISCORD_WEBHOOK_URL variable to be set in /root/.metapayload
# ------------------------
METAPAYLOAD_DISCORD_WEBHOOK_URL="${METAPAYLOAD_DISCORD_WEBHOOK_URL:-}"

if [ -n "$METAPAYLOAD_DISCORD_WEBHOOK_URL" ]; then
    LOG_CONTENT=$(cat "$TASK_LOG_PATH")
    LOG_LENGTH=${#LOG_CONTENT}
    MAX_CODE_BLOCK_LENGTH=1990  # Discord message limit is 2000, using 1990 to account for code block markers
    
    # Wrap in code block for easy copy/paste
    LOG_CONTENT_FORMATTED="${LOG_CONTENT}"
    FORMATTED_LENGTH=$((LOG_LENGTH + 8))  # Add 8 for the backticks and newlines
    
    # Escape special JSON characters
    LOG_CONTENT_ESCAPED=$(echo "$LOG_CONTENT_FORMATTED" | jq -Rs .)
    
    if [ $FORMATTED_LENGTH -le $MAX_CODE_BLOCK_LENGTH ]; then
        # Send full log in code block
        PAYLOAD=$(jq -n --arg task_id "${TASK_ID}" --arg length "${LOG_LENGTH}" --arg content "${LOG_CONTENT_FORMATTED}" \
            '{content: ("📋 **Task Log Export: \($task_id)** (\($length) chars)\n```\n\($content)\n```")}')
        
        resp=$(curl -s -X POST -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            "${METAPAYLOAD_DISCORD_WEBHOOK_URL}")
        if [ $? -eq 0 ]; then
            echo "Task log sent to Discord webhook (${LOG_LENGTH} chars)"
        else
            echo "Failed to send task log to Discord webhook"
        fi
    else
        # Log too large, send as file attachment
        echo "Task log too large (${LOG_LENGTH} chars), sending as file attachment..."
        resp=$(curl -s -X POST \
            -F "payload_json={\"content\":\"📋 Task Log Export: **${TASK_ID}** (${LOG_LENGTH} chars - too large for embed)\"}" \
            -F "file=@${TASK_LOG_PATH};filename=${TASK_ID}.log" \
            "${METAPAYLOAD_DISCORD_WEBHOOK_URL}")
        if [ $? -eq 0 ]; then
            echo "Task log sent to Discord webhook as file attachment"
        else
            echo "Failed to send task log to Discord webhook"
        fi
    fi
else
    echo "Discord Webhook URL not set. Skipping Discord export."
fi
