#!/bin/bash

# Title: Pager AI Chat
# Description: AI chat with conversation memory, powered by Vireonix AI with automatic JarvisClaw AI backup.
# Author: spywill
# Version: 1.1

PROMPT "Pager AI Chat

Free Online AI Assistant - no API key required.
Primary: Vireonix AI
Backup: JarvisClaw AI

Enter a blank message to exit.

Internet connection required."

LOG blue "------------ PAGER AI CHAT ------------"
LOG green "Free Online AI Assistant - no API key required."
LOG yellow "Primary AI: Vireonix AI"
LOG yellow "Backup AI: JarvisClaw AI"
LOG yellow "Internet connection required."
LOG red "Enter a blank message to exit."
LOG ""

# AI providers
API_URL="https://vireonix.ai/v1/chat/completions"
MODEL="auto"

BACKUP_URL="https://api.jarvisclaw.ai/v1/chat/completions"
BACKUP_MODEL="auto/free"

# Temporary session files
WORK_DIR="/tmp/pager_ai_chat_$$"
HISTORY="${WORK_DIR}/history.json"
REQUEST="${WORK_DIR}/request.json"
RESPONSE="${WORK_DIR}/response.json"

mkdir -p "$WORK_DIR" || exit 1

cleanup() {
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# Check required commands
if ! command -v curl >/dev/null 2>&1; then
	ERROR_DIALOG "Pager AI Chat curl is not installed."
	exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
	ERROR_DIALOG "Pager AI Chat jq is not installed."
	exit 0
fi

# Check internet connection
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	ERROR_DIALOG "Internet connection required."
	exit 0
fi

# Start a new conversation
jq -n '[
	{
		"role": "system",
		"content": "You are a helpful AI assistant chatting with a user on a Hak5 WiFi Pineapple Pager. Give accurate, useful answers. Keep replies concise and easy to read on a small screen. Use plain text where possible."
	}
]' > "$HISTORY"

# AI request function
request_ai() {
	local URL="$1"
	local AI_MODEL="$2"

	ANSWER=""
	AI_ERROR=""

	# Build API request
	if ! jq -n \
		--arg model "$AI_MODEL" \
		--argjson messages "$(cat "$HISTORY")" \
		'{model:$model,messages:$messages,stream:false}' \
		> "$REQUEST"; then

		AI_ERROR="Unable to build API request."
		return 1
	fi

	# Send API request
	HTTP_CODE="$(curl -sS \
		--connect-timeout 10 \
		--max-time 90 \
		-o "$RESPONSE" \
		-w '%{http_code}' \
		-H 'Content-Type: application/json' \
		--data-binary "@$REQUEST" \
		"$URL" 2>"${WORK_DIR}/curl_error.txt")"
	CURL_STATUS=$?

	# Handle connection errors
	if [ "$CURL_STATUS" -ne 0 ]; then
		AI_ERROR="$(cat "${WORK_DIR}/curl_error.txt")"
		[ -n "$AI_ERROR" ] || AI_ERROR="Network request failed."
		return 1
	fi

	# Handle HTTP errors
	if [ "$HTTP_CODE" != "200" ]; then
		AI_ERROR="$(jq -r \
			'.error.message // .message // empty' \
			"$RESPONSE" 2>/dev/null)"

		[ -n "$AI_ERROR" ] || AI_ERROR="HTTP status: $HTTP_CODE"
		return 1
	fi

	# Extract AI response
	ANSWER="$(jq -r \
		'.choices[0].message.content // empty' \
		"$RESPONSE" 2>/dev/null)"

	# Check for empty or invalid response
	if [ -z "$ANSWER" ] || [ "$ANSWER" = "null" ]; then
		AI_ERROR="$(jq -r \
			'.error.message // .message // empty' \
			"$RESPONSE" 2>/dev/null)"

		[ -n "$AI_ERROR" ] || AI_ERROR="AI returned no readable answer."
		return 1
	fi
	return 0
}

while true; do
	USER_TEXT=$(TEXT_PICKER "Ask Pager AI Chat" "") || exit 0

	# Blank input exits the chat
	if [ -z "$USER_TEXT" ]; then
		break
	fi

	spinnerid=$(START_SPINNER "Sending message to AI...")

	# Add user message and retain recent conversation context
	if ! jq --arg text "$USER_TEXT" \
		'. + [{"role":"user","content":$text}] |
		.[0:1] + .[-12:]' \
		"$HISTORY" > "${WORK_DIR}/history.new"; then

		STOP_SPINNER "${spinnerid}"
		LOG red "Pager AI Chat Unable to update conversation history."
		PROMPT "Pager AI Chat Unable to update conversation history."
		break
	fi

	mv "${WORK_DIR}/history.new" "$HISTORY"

	# Try primary AI first
	ACTIVE_AI="Vireonix AI"

	if ! request_ai "$API_URL" "$MODEL"; then
		PRIMARY_ERROR="$AI_ERROR"

		LOG yellow "Vireonix AI unavailable."
		LOG yellow "Switching to backup AI..."

		# Try backup AI
		ACTIVE_AI="JarvisClaw AI"

		if ! request_ai "$BACKUP_URL" "$BACKUP_MODEL"; then
			BACKUP_ERROR="$AI_ERROR"
			STOP_SPINNER "${spinnerid}"

			LOG red "Both AI providers failed."
			LOG yellow "Vireonix: $PRIMARY_ERROR"
			LOG yellow "JarvisClaw: $BACKUP_ERROR"

			PROMPT "Pager AI Chat
			Both AI providers are currently unavailable.

			Vireonix:
			$PRIMARY_ERROR

			JarvisClaw:
			$BACKUP_ERROR

			Please try again."
			continue
		fi
		LOG green "Backup AI connected successfully."
	fi

	# Save the assistant response
	if ! jq --arg text "$ANSWER" \
		'. + [{"role":"assistant","content":$text}]' \
		"$HISTORY" > "${WORK_DIR}/history.new"; then

		STOP_SPINNER "${spinnerid}"
		LOG red "Pager AI Chat Unable to save the AI response."
		PROMPT "Pager AI Chat Unable to save the AI response."
		break
	fi

	STOP_SPINNER "${spinnerid}"
	mv "${WORK_DIR}/history.new" "$HISTORY"

	# Display response
	LOG blue "[YOU] $USER_TEXT"
	LOG ""

	LOG green "[$ACTIVE_AI]"
	PROMPT "[$ACTIVE_AI] $ANSWER"

	LOG yellow "[$ACTIVE_AI] $ANSWER"
	LOG ""

	WAIT_FOR_BUTTON_PRESS A
done
LOG blue "Pager AI Chat closed."
