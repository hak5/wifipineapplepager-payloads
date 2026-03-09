#!/bin/bash
# Title: Live Probe Monitor
# Description: Probe request viewer
# Author: dudgy
# Category: reconnaissance
# Version: 1.1

# === CONFIGURATION ===
MON_IF="wlan1mon"
UPDATE_INTERVAL=2
RAW_LOG="/tmp/probes_$(date +%s).log"
DISPLAY_LINES=8

# Output settings
LOOT_DIR="/root/loot/live_probe"
LOOT_FILE=""
SAVE_TO_LOOT=false

# Discord webhook
DISCORD_WEBHOOK=""
WEBHOOK_BATCH_SIZE=5
WEBHOOK_ENABLED=false

# Load config file if exists
CONFIG_FILE="/root/payloads/user/reconnaissance/live_probe/client_probe_mon.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Prevent multiple instances
LOCKFILE="/tmp/probe_monitor.lock"
if [ -f "$LOCKFILE" ]; then
    # Check if tcpdump is actually running
    if ps w | grep -q "[t]cpdump.*wlan1mon"; then
        LOG red "Another instance is already running!"
        LOG yellow "Kill it first: killall tcpdump"
        sleep 3
        exit 1
    else
        LOG yellow "Removing stale lockfile..."
        rm -f "$LOCKFILE"
    fi
fi
touch "$LOCKFILE"

# == VARIABLES ===
declare -a webhook_buffer
probe_count=0
TCPDUMP_PID=""


cleanup() {
    # Kill tcpdump by PID first
    [ -n "$TCPDUMP_PID" ] && kill $TCPDUMP_PID 2>/dev/null
    
    # Backup: kill all tcpdump
    pkill -f "tcpdump.*$MON_IF" 2>/dev/null
    killall tcpdump 2>/dev/null
    
    # Remove temp files
    rm -f "$RAW_LOG"
    rm -f "$LOCKFILE"
      
    # Discord summary
    if [ "$WEBHOOK_ENABLED" = true ] && [ "$probe_count" -gt 0 ]; then
        curl -H "Content-Type: application/json" \
             -X POST \
             -d "{\"content\":\"**(⌐■_■) Scan Complete**\\n\\nTotal probes: **$probe_count**\"}" \
             "$DISCORD_WEBHOOK" \
             --silent --output /dev/null 2>&1 &
    fi
    
    # Loot summary
    if [ "$SAVE_TO_LOOT" = true ] && [ -f "$LOOT_FILE" ]; then
        echo "" >> "$LOOT_FILE"
        echo "=== Scan Complete ===" >> "$LOOT_FILE"
        echo "Total probes captured: $probe_count" >> "$LOOT_FILE"
        echo "Scan ended: $(date)" >> "$LOOT_FILE"
    fi
}
trap cleanup EXIT INT TERM

# === SETUP ===
LOG "🔍 Live Probe Monitor"
LOG ""

# Show output options
LOG "Output Options:"
LOG "0 = Screen only"
LOG "1 = Discord webhook"
LOG "2 = Save to loot"
LOG "3 = Both Discord + Loot"
LOG ""
sleep 2
PROMPT "Press any button to choose"

# Prompt for output choice
output_choice=$(NUMBER_PICKER "Select output option:" 0)
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Screen only (cancelled)"
        ;;
    *)
        case "$output_choice" in
            0)
                WEBHOOK_ENABLED=false
                SAVE_TO_LOOT=false
                LOG "Screen only"
                ;;
            1)
                WEBHOOK_ENABLED=true
                SAVE_TO_LOOT=false
                LOG green "✓ Discord enabled"
                ;;
            2)
                WEBHOOK_ENABLED=false
                SAVE_TO_LOOT=true
                LOG green "✓ Loot enabled"
                ;;
            3)
                WEBHOOK_ENABLED=true
                SAVE_TO_LOOT=true
                LOG green "✓ Discord + Loot enabled"
                ;;
        esac
        ;;
esac

# Setup loot file 
if [ "$SAVE_TO_LOOT" = true ]; then
    mkdir -p "$LOOT_DIR"
    LOOT_FILE="$LOOT_DIR/probes_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "=== Live Probe Monitor ==="
        echo "Scan started: $(date)"
        echo "Interface: $MON_IF"
        echo ""
    } > "$LOOT_FILE"
    LOG green "✓ Saving to loot"
fi

LOG ""
sleep 1

# Check interface exists
if ! iw dev "$MON_IF" info >/dev/null 2>&1; then
    LOG red "Interface $MON_IF not found!"
    LOG "Available interfaces:"
    iw dev | grep Interface | awk '{print "  " $2}'
    sleep 5
    exit 1
fi

LOG "Interface: $MON_IF"

# Discord startup notification
if [ "$WEBHOOK_ENABLED" = true ]; then
    curl -H "Content-Type: application/json" \
         -X POST \
         -d "{\"content\":\"(｡◕‿‿◕｡)\\n**Probe Monitor Started**\\n\\nInterface: \`$MON_IF\`\"}" \
         "$DISCORD_WEBHOOK" \
         --silent --output /dev/null 2>&1 &
fi

# === START CAPTURE ===
LOG "Starting capture..."

# Kill any existing tcpdump first
killall tcpdump 2>/dev/null
sleep 1

# Store main script PID
MAIN_PID=$$
echo $MAIN_PID > /tmp/probe_monitor.pid

tcpdump -i "$MON_IF" -e -n -l -s 256 'type mgt subtype probe-req' 2>/dev/null > "$RAW_LOG" &
TCPDUMP_PID=$!
echo $TCPDUMP_PID > /tmp/probe_monitor_tcpdump.pid

# Start watchdog in background to clean up if script dies
(
    SCRIPT_PID=$MAIN_PID
    DUMP_PID=$TCPDUMP_PID
    while kill -0 $SCRIPT_PID 2>/dev/null; do
        sleep 2
    done
    # Script died - clean up
    kill $DUMP_PID 2>/dev/null
    killall tcpdump 2>/dev/null
    rm -f "$RAW_LOG"
    rm -f "$LOCKFILE"
    rm -f /tmp/probe_monitor.pid
    rm -f /tmp/probe_monitor_tcpdump.pid
) &

sleep 2

# Verify tcpdump started
if ! kill -0 $TCPDUMP_PID 2>/dev/null; then
    LOG red "tcpdump failed. Trying without filter..."
    killall tcpdump 2>/dev/null
    sleep 1
    tcpdump -i "$MON_IF" -e -n -l -s 256 2>/dev/null > "$RAW_LOG" &
    TCPDUMP_PID=$!
    sleep 2
    
    if ! kill -0 $TCPDUMP_PID 2>/dev/null; then
        LOG red "Capture failed to start"
        exit 1
    fi
fi

LOG green "✓ Capture active (PID: $TCPDUMP_PID)"
LOG ""
LOG "Press B to stop monitoring"
sleep 2

# === LIVE DISPLAY ===
declare -a recent_probes
declare -A seen_probes
last_size=0
dedup_window=10

# Channel lookup table
declare -A channel_map=(
    [2412]="1" [2417]="2" [2422]="3" [2427]="4" [2432]="5"
    [2437]="6" [2442]="7" [2447]="8" [2452]="9" [2457]="10" [2462]="11"
)

while true; do
    # Check for B button
    button_pressed=$(timeout 0.1 sh -c 'read -n 1 key 2>/dev/null; echo $key' 2>/dev/null)
    if [ "$button_pressed" = "b" ] || [ "$button_pressed" = "B" ]; then
        # Immediate cleanup on B press
        [ -n "$TCPDUMP_PID" ] && kill $TCPDUMP_PID 2>/dev/null
        killall tcpdump 2>/dev/null
        rm -f "$RAW_LOG"
        rm -f "$LOCKFILE"
        
        # Send Discord summary
        if [ "$WEBHOOK_ENABLED" = true ] && [ "$probe_count" -gt 0 ]; then
            curl -H "Content-Type: application/json" \
                 -X POST \
                 -d "{\"content\":\"**(⌐■_■) Scan Complete**\\n\\nTotal probes: **$probe_count**\"}" \
                 "$DISCORD_WEBHOOK" \
                 --silent --output /dev/null 2>&1 &
        fi
        
        # Loot summary
        if [ "$SAVE_TO_LOOT" = true ] && [ -f "$LOOT_FILE" ]; then
            echo "" >> "$LOOT_FILE"
            echo "=== Scan Complete ===" >> "$LOOT_FILE"
            echo "Total probes captured: $probe_count" >> "$LOOT_FILE"
            echo "Scan ended: $(date)" >> "$LOOT_FILE"
        fi
        
        exit 0
    fi
    
    # Process new captures
    [ ! -f "$RAW_LOG" ] && { sleep "$UPDATE_INTERVAL"; continue; }
    
    current_size=$(wc -l < "$RAW_LOG" 2>/dev/null || echo 0)
    [ "$current_size" -le "$last_size" ] && { sleep "$UPDATE_INTERVAL"; continue; }
    
    new_lines=$(tail -n $((current_size - last_size)) "$RAW_LOG" 2>/dev/null)
    
    while IFS= read -r line; do
        [[ "$line" =~ [Pp]robe ]] || continue
        
        channel_mhz=""
        mac=""
        bssid=""
        ssid=""
        
        # Extract channel
        if [[ $line =~ ([0-9]{4})\ MHz ]]; then
            channel_mhz="${BASH_REMATCH[1]}"
        fi
        
        # Extract client MAC
        if [[ $line =~ SA:([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}) ]]; then
            mac="${BASH_REMATCH[1]}"
        fi
        
        # Fallback: third MAC
        if [ -z "$mac" ] || [ "$mac" = "ff:ff:ff:ff:ff:ff" ]; then
            temp_line="$line"
            macs=()
            while [[ $temp_line =~ ([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}) ]]; do
                macs+=("${BASH_REMATCH[1]}")
                temp_line="${temp_line#*${BASH_REMATCH[1]}}"
            done
            [ ${#macs[@]} -ge 3 ] && mac="${macs[2]}"
        fi
        
        # Extract BSSID
        if [[ $line =~ BSSID:([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}) ]]; then
            bssid="${BASH_REMATCH[1]}"
            [ "$bssid" = "ff:ff:ff:ff:ff:ff" ] && bssid=""
        fi
        
        # Extract SSID
        ssid=$(echo "$line" | sed -n 's/.*Probe Request (\([^)]*\)).*/\1/p')
        [ -z "$ssid" ] && ssid="[broadcast]"
        
        [ -z "$mac" ] && continue
        
        formatted_mac="${mac^^}"
        formatted_bssid="${bssid^^}"
        
        # Deduplication
        probe_key="${formatted_mac}:${ssid}"
        current_time=$(date +%s)
        
        if [[ -n "${seen_probes[$probe_key]}" ]]; then
            last_seen="${seen_probes[$probe_key]}"
            time_diff=$((current_time - last_seen))
            [ $time_diff -lt $dedup_window ] && continue
        fi
        
        seen_probes[$probe_key]=$current_time
        
        # Convert frequency to channel
        if [[ -n "${channel_map[$channel_mhz]}" ]]; then
            channel_num="${channel_map[$channel_mhz]}"
        elif [[ $channel_mhz -ge 5000 ]] && [[ $channel_mhz -lt 6000 ]]; then
            channel_num="5GHz"
        elif [[ $channel_mhz -ge 5900 ]]; then
            channel_num="6GHz"
        else
            channel_num="?"
        fi
        
        # Screen display
        recent_probes+=("CH${channel_num} $formatted_mac → $ssid")
        ((probe_count++))
        
        # Save to loot
        if [ "$SAVE_TO_LOOT" = true ]; then
            echo "$formatted_mac,$formatted_bssid,$ssid,$channel_num,$(date +%Y-%m-%d\ %H:%M:%S)" >> "$LOOT_FILE"
        fi
        
        # Discord batching
        if [ "$WEBHOOK_ENABLED" = true ]; then
            if [ -n "$formatted_bssid" ]; then
                webhook_buffer+=("CH${channel_num} $formatted_mac → $ssid (BSSID: $formatted_bssid)")
            else
                webhook_buffer+=("CH${channel_num} $formatted_mac → $ssid")
            fi
            
            if [ ${#webhook_buffer[@]} -ge $WEBHOOK_BATCH_SIZE ]; then
                batch_msg="(˶ᵔ ᵕ ᵔ˶) ‹𝟹\\n**New Probes**\\n\`\`\`\\n"
                for item in "${webhook_buffer[@]}"; do
                    batch_msg+="$item\\n"
                done
                batch_msg+="\`\`\`"
                
                curl -H "Content-Type: application/json" \
                     -X POST \
                     -d "{\"content\":\"$batch_msg\"}" \
                     "$DISCORD_WEBHOOK" \
                     --silent --output /dev/null 2>&1 &
                
                webhook_buffer=()
            fi
        fi
        
        # Keep display manageable
        [ ${#recent_probes[@]} -gt $DISPLAY_LINES ] && recent_probes=("${recent_probes[@]:1}")
    done <<< "$new_lines"
    
    last_size=$current_size
    
    # Update display
    clear
    LOG blue "━━━ LIVE PROBE REQUESTS ━━━"
    LOG ""
    
    if [ ${#recent_probes[@]} -eq 0 ]; then
        LOG "Waiting for probe requests..."
        LOG "(Captured $current_size frames total)"
    else
        for probe in "${recent_probes[@]}"; do
            LOG purple "  $probe"
        done
    fi
    
    LOG ""
    LOG blue "Total probes: $probe_count | Press B to stop"
    
    sleep "$UPDATE_INTERVAL"
done

exit 1