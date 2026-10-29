#!/bin/bash

# Title: Pager AI Chat
# Description: AI chat with conversation memory, powered by Vireonix AI. No API key required.
# Author: spywill
# Version: 1.0

PROMPT "Pager AI Chat

Free Online AI Assistant - no API key required.
Powered by Vireonix AI.
Enter a blank message to exit.

Internet connection required."

LOG blue "------------ PAGER AI CHAT ------------"
LOG green "Free Online AI Assistant - no API key required."
LOG yellow "Powered by Vireonix AI"
LOG yellow "Internet connection required."
LOG red "Enter a blank message to exit."
LOG ""

API_URL="https://vireonix.ai/v1/chat/completions"
MODEL="auto"

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

# Check for an internet connection
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

while true; do
	USER_TEXT=$(TEXT_PICKER "Ask Pager AI Chat" "") || exit 0

	# Blank input exits the chat
	if [ -z "$USER_TEXT" ]; then
		break
	fi

	spinnerid=$(START_SPINNER "Sending message to AI...")

	# Add the user's message and retain recent conversation context.
	# Keep the system message plus the latest 12 messages.
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

	# Build the API request
	if ! jq -n \
		--arg model "$MODEL" \
		--argjson messages "$(cat "$HISTORY")" \
		'{model:$model,messages:$messages,stream:false}' \
		> "$REQUEST"; then
		STOP_SPINNER "${spinnerid}"
		LOG red "Pager AI Chat Unable to build the API request."
		PROMPT "Pager AI Chat Unable to build the API request."
		break
	fi

	# Send the request
	HTTP_CODE="$(curl -sS \
		--connect-timeout 10 \
		--max-time 90 \
		-o "$RESPONSE" \
		-w '%{http_code}' \
		-H 'Content-Type: application/json' \
		--data-binary "@$REQUEST" \
		"$API_URL" 2>"${WORK_DIR}/curl_error.txt")"
	CURL_STATUS=$?

	if [ "$CURL_STATUS" -ne 0 ]; then
		CURL_ERROR="$(cat "${WORK_DIR}/curl_error.txt")"
		[ -n "$CURL_ERROR" ] || CURL_ERROR="Network request failed."
		STOP_SPINNER "${spinnerid}"
		LOG red "Pager AI Chat $CURL_ERROR"
		PROMPT "Pager AI Chat $CURL_ERROR"
		continue
	fi

	# Handle HTTP errors
	if [ "$HTTP_CODE" != "200" ]; then
		API_ERROR="$(jq -r \
			'.error.message // .message // empty' \
			"$RESPONSE" 2>/dev/null)"

		[ -n "$API_ERROR" ] || API_ERROR="HTTP status: $HTTP_CODE"
		STOP_SPINNER "${spinnerid}"
		LOG red "Pager AI Chat $API_ERROR"
		PROMPT "Pager AI Chat $API_ERROR"
		continue
	fi

	# Extract the assistant's response
	ANSWER="$(jq -r \
		'.choices[0].message.content // empty' \
		"$RESPONSE" 2>/dev/null)"

	if [ -z "$ANSWER" ]; then
		STOP_SPINNER "${spinnerid}"
		LOG red "Pager AI Chat The API returned no readable answer."
		PROMPT "Pager AI Chat The API returned no readable answer."
		continue
	fi

	# Save the answer so the AI remembers it on the next request
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

	# Display the answer on the Pager
	LOG blue "[YOU] $USER_TEXT"
	LOG ""
	PROMPT "[AI] $ANSWER"
	LOG yellow "[AI] $ANSWER"
	LOG ""

	WAIT_FOR_BUTTON_PRESS A
done
LOG blue "Pager AI Chat closed."
