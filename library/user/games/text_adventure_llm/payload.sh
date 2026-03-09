#!/bin/bash
# Title: Snow Crash Terminal
# Description: AI-generated cyberpunk text adventure inspired by Snow Crash
# Author: r0yfire
# Version: 1.2
# Category: Prank
#
# Jack into the Metaverse with a unique AI-generated text adventure.
# Navigate the neon-lit streets using LEFT/RIGHT to make your choices.
#
# Requires: ANTHROPIC_API_KEY (via .env file or environment variable), jq

# ============================================
# CONTROLS - Button configuration
# ============================================

BTN_CHOICE_1="LEFT"      # Select first choice option
BTN_CHOICE_2="RIGHT"     # Select second choice option
BTN_CONTINUE="A"         # Continue through narrative
BTN_EXIT="B"             # Exit game at any time

# ============================================
# OPTIONS - User configurable
# ============================================

# Anthropic API settings
API_URL="https://api.anthropic.com/v1/messages"
API_MODEL="claude-sonnet-4-20250514"
API_VERSION="2023-06-01"
MAX_TOKENS=2048
CURL_TIMEOUT=60

# ============================================
# INTERNAL - Temp files and state
# ============================================

# Get the directory where this script lives (for loading .env)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

GAME_FILE="/tmp/text_adventure_game.json"
CURRENT_NODE="start"
GAME_TITLE=""

# ============================================
# LOAD .env FILE - Before anything else
# ============================================

# Source .env file if it exists (loads ANTHROPIC_API_KEY)
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

# ============================================
# CLEANUP - Set trap EARLY
# ============================================

cleanup() {
    # Remove temp files
    rm -f "$GAME_FILE"
}
trap cleanup EXIT

# ============================================
# HELPER FUNCTIONS
# ============================================

# Handles user exit request gracefully.
handle_exit() {
    LOG ""
    LOG yellow "Disconnecting from the Metaverse..."
    LOG yellow "Until next time, hacker."
    LOG ""
    exit 0
}

# Check if device has a valid IP address (not loopback, not management network)
# Returns: 0 if valid, 1 if invalid
is_valid_ip() {
    local ip="$1"
    # Reject empty or loopback
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        return 1
    fi
    # Exclude 172.16.52.0/24 subnet (Pineapple management network)
    if echo "$ip" | grep -qE '^172\.16\.52\.'; then
        return 1
    fi
    return 0
}

# Check if device has network connectivity
# Returns: 0 if connected, 1 if not
check_network() {
    local has_ip=false

    # Try hostname -I first
    if command -v hostname >/dev/null 2>&1; then
        local ip_addr
        ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
        if is_valid_ip "$ip_addr"; then
            has_ip=true
        fi
    fi

    # Fallback to ip command
    if [ "$has_ip" = false ] && command -v ip >/dev/null 2>&1; then
        for ip_addr in $(ip -4 addr show | grep -E 'inet [0-9]' | awk '{print $2}' | cut -d'/' -f1); do
            if is_valid_ip "$ip_addr"; then
                has_ip=true
                break
            fi
        done
    fi

    [ "$has_ip" = true ]
}

# Generate the game by calling the Anthropic API
# Returns: 0 on success, 1 on failure
generate_game() {
    # Build the system prompt for game generation
    local system_prompt='You are a creative game designer. Generate a short, fun text adventure game in JSON format.

The game must have:
- Exactly 4 decision steps with 2 choices each (LEFT button and RIGHT button)
- 2 possible endings (one good, one bad)
- A cyberpunk theme heavily inspired by Neal Stephenson'\''s Snow Crash
- Reference elements like: the Metaverse, hackers, Kouriers, burbclaves, franchulates, neon-lit streets, corporate enclaves, samurai swords, the Raft, avatars, or the virus itself
- Short, punchy noir-style prose (max 50 words per scene)
- Use second person ("You jack into..." not "The player...")

Output ONLY valid JSON in this exact structure, without any preamble or comments:
{
  "title": "Game Title",
  "nodes": {
    "start": {
      "text": "Opening scene description...",
      "choice_up": "node_2a",
      "choice_up_label": "Do action A",
      "choice_down": "node_2b",
      "choice_down_label": "Do action B"
    },
    "node_2a": {
      "text": "Scene after choosing UP...",
      "choice_up": "node_3a",
      "choice_up_label": "...",
      "choice_down": "node_3b",
      "choice_down_label": "..."
    },
    "node_2b": {
      "text": "Scene after choosing DOWN...",
      "choice_up": "node_3c",
      "choice_up_label": "...",
      "choice_down": "node_3d",
      "choice_down_label": "..."
    },
    "node_3a": {
      "text": "...",
      "choice_up": "ending_good",
      "choice_up_label": "...",
      "choice_down": "ending_bad",
      "choice_down_label": "..."
    },
    "node_3b": {
      "text": "...",
      "choice_up": "ending_good",
      "choice_up_label": "...",
      "choice_down": "ending_bad",
      "choice_down_label": "..."
    },
    "node_3c": {
      "text": "...",
      "choice_up": "ending_bad",
      "choice_up_label": "...",
      "choice_down": "ending_good",
      "choice_down_label": "..."
    },
    "node_3d": {
      "text": "...",
      "choice_up": "ending_bad",
      "choice_up_label": "...",
      "choice_down": "ending_good",
      "choice_down_label": "..."
    },
    "ending_good": {
      "text": "Victory ending description...",
      "is_ending": true,
      "ending_type": "good"
    },
    "ending_bad": {
      "text": "Defeat ending description...",
      "is_ending": true,
      "ending_type": "bad"
    }
  }
}'

    local user_prompt="Generate a unique Snow Crash-inspired text adventure. The protagonist could be a hacker, Kourier, or Metaverse dweller. Include corporate intrigue, digital threats, or street-level action. Be creative and atmospheric!"

    # Build the JSON request body
    local request_body
    request_body=$(cat <<EOF
{
  "model": "$API_MODEL",
  "max_tokens": $MAX_TOKENS,
  "system": $(echo "$system_prompt" | jq -Rs .),
  "messages": [
    {
      "role": "user",
      "content": "$user_prompt"
    }
  ]
}
EOF
)

    # Make the API request (simple blocking call like tailscale_installer)
    local response
    response=$(curl -s --connect-timeout 15 --max-time "$CURL_TIMEOUT" -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: $API_VERSION" \
        -d "$request_body" \
        "$API_URL" 2>/dev/null)

    local curl_exit=$?

    # Check if curl failed
    if [ $curl_exit -ne 0 ]; then
        LOG red "ERROR: Network request failed (curl exit: $curl_exit)"
        return 1
    fi

    # Parse response and HTTP code
    local http_code
    http_code=$(echo "$response" | tail -n1)
    local json_body
    json_body=$(echo "$response" | sed '$d')

    # Check HTTP status
    if [ "$http_code" != "200" ]; then
        LOG red "ERROR: API returned HTTP $http_code"
        # Try to extract error message
        local error_msg
        error_msg=$(echo "$json_body" | jq -r '.error.message // empty' 2>/dev/null)
        if [ -n "$error_msg" ]; then
            LOG red "API Error: $error_msg"
        fi
        return 1
    fi

    # Extract the text content from Claude's response
    local game_json
    game_json=$(echo "$json_body" | jq -r '.content[0].text // empty' 2>/dev/null)

    if [ -z "$game_json" ]; then
        LOG red "ERROR: Could not extract game content from response"
        return 1
    fi

    # Strip markdown code blocks if present (Claude sometimes wraps JSON)
    # Remove leading ```json or ``` and trailing ```
    game_json=$(echo "$game_json" | sed 's/^```json//; s/^```//; s/```$//' | sed '/^$/d')

    # Validate it's proper JSON with expected structure
    # Must have start node with both choice fields
    if ! echo "$game_json" | jq -e '.nodes.start.choice_up and .nodes.start.choice_down' >/dev/null 2>&1; then
        LOG red "ERROR: Generated game has invalid structure"
        LOG red "Missing start node or choice fields"
        return 1
    fi

    # Save game to temp file
    echo "$game_json" > "$GAME_FILE"
    return 0
}

# Get a field from the current node
# Args: field_name
# Returns: field value
get_node_field() {
    local field="$1"
    jq -r ".nodes[\"$CURRENT_NODE\"][\"$field\"] // empty" "$GAME_FILE"
}

# Display the current scene
display_scene() {
    local text
    text=$(get_node_field "text")
    local is_ending
    is_ending=$(get_node_field "is_ending")

    LOG ""
    LOG "░▒▓█▓▒░▒▓█▓▒░▒▓█▓▒░▒▓█▓▒░"
    LOG ""

    # Display the scene text directly
    LOG "$text"

    LOG ""

    # If not an ending, show choices
    if [ "$is_ending" != "true" ]; then
        local choice_up_label
        choice_up_label=$(get_node_field "choice_up_label")
        local choice_down_label
        choice_down_label=$(get_node_field "choice_down_label")

        LOG "─────────────────────────────"
        LOG ""
        LOG blue "◀ $choice_up_label"
        LOG blue "▶ $choice_down_label"
        LOG ""
        LOG yellow "[$BTN_EXIT to exit]"
    fi
}

# Wait for user choice and navigate
# Returns: 0 to continue, 1 if at ending
get_choice() {
    local is_ending
    is_ending=$(get_node_field "is_ending")

    # If at ending, show result and return
    if [ "$is_ending" = "true" ]; then
        local ending_type
        ending_type=$(get_node_field "ending_type")

        LOG "▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"
        if [ "$ending_type" = "good" ]; then
            LOG green "    >> HACK SUCCESSFUL <<"
            LOG green "   You survived the Snow Crash"
            VIBRATE 2>/dev/null
        else
            LOG red "    >> SYSTEM CRASH <<"
            LOG red "   The virus got you..."
        fi
        LOG "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄"
        LOG ""
        return 1
    fi

    # Loop until a valid choice is made
    while true; do
        local button
        button=$(WAIT_FOR_INPUT)
        case $? in
            $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                exit 1
                ;;
        esac

        # Navigate based on button press
        local next_node=""
        case "$button" in
            "$BTN_CHOICE_1")
                # LEFT = first choice (mapped to choice_up in JSON)
                next_node=$(get_node_field "choice_up")
                ;;
            "$BTN_CHOICE_2")
                # RIGHT = second choice (mapped to choice_down in JSON)
                next_node=$(get_node_field "choice_down")
                ;;
            "$BTN_EXIT")
                handle_exit
                ;;
            *)
                # Ignore other buttons, loop again
                continue
                ;;
        esac

        # Validate next node exists
        if [ -z "$next_node" ]; then
            LOG red "ERROR: Invalid game state"
            LOG red "Node '$CURRENT_NODE' missing choice fields"
            return 1
        fi

        # Validate the target node actually exists
        if ! jq -e ".nodes[\"$next_node\"]" "$GAME_FILE" >/dev/null 2>&1; then
            LOG red "ERROR: Target node '$next_node' not found"
            return 1
        fi

        CURRENT_NODE="$next_node"
        return 0
    done
}

# ============================================
# MAIN SCRIPT
# ============================================

# Display header
LOG ""
LOG blue "─────────────────────────────────"
LOG blue "  ░▒▓ SNOW CRASH TERMINAL ▓▒░    "
LOG blue "    << METAVERSE UPLINK >>       "
LOG blue "─────────────────────────────────"
LOG ""
LOG yellow "  \"The Deliverator belongs to an"
LOG yellow "   elite order...\""
LOG ""

# Step 1: Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    ERROR_DIALOG "jq not installed"
    LOG red "FATAL: Missing codec - jq not found"
    LOG "Install with: opkg install jq"
    exit 1
fi

# Step 2: Check for API key
if [ -z "$ANTHROPIC_API_KEY" ]; then
    ERROR_DIALOG "No Metaverse credentials"
    LOG red "FATAL: Metaverse access denied"
    LOG "Create .env file with ANTHROPIC_API_KEY"
    LOG "or export it to your environment"
    exit 1
fi

# Step 3: Check network connectivity
if ! check_network; then
    ERROR_DIALOG "No uplink detected"
    LOG red "FATAL: Cannot reach the Metaverse"
    LOG "Establish network connection first"
    exit 1
fi

# Step 4: Generate the game (no spinner - just like Shodan script)
LOG "Initializing Metaverse uplink..."
LOG "Rendering reality... (this may take a moment)"
LOG ""

if ! generate_game; then
    ERROR_DIALOG "Failed to generate game"
    exit 1
fi

# Get and display the game title
GAME_TITLE=$(jq -r '.title // "Unknown Protocol"' "$GAME_FILE")
LOG ""
LOG green ">> REALITY LOADED <<"
LOG ""
LOG blue "▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"
LOG yellow "  $GAME_TITLE"
LOG blue "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄"
LOG ""
LOG "  [$BTN_CHOICE_1]     First choice"
LOG "  [$BTN_CHOICE_2]    Second choice"
LOG "  [$BTN_EXIT]        Exit game"
LOG ""
LOG "[$BTN_CONTINUE to jack in, $BTN_EXIT to quit]"

# Wait for start or exit
while true; do
    button=$(WAIT_FOR_INPUT)
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            exit 1
            ;;
    esac

    case "$button" in
        "$BTN_EXIT")
            LOG ""
            LOG yellow "Goodbye, hacker."
            exit 0
            ;;
        *)
            # Any other button starts the game
            break
            ;;
    esac
done

# Step 5: Game loop
CURRENT_NODE="start"

while true; do
    display_scene

    if ! get_choice; then
        # Reached an ending
        break
    fi
done

# Step 6: End screen
LOG ""
LOG "[$BTN_CONTINUE to disconnect]"

# Wait for continue or exit
while true; do
    button=$(WAIT_FOR_INPUT)
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            exit 1
            ;;
    esac

    case "$button" in
        "$BTN_CONTINUE"|"$BTN_EXIT")
            break
            ;;
        *)
            # Ignore other buttons
            ;;
    esac
done

LOG ""
LOG blue ">> Logging out of Metaverse <<"
LOG green "Until next time, hacker."
exit 0
