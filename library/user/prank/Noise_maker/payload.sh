#!/bin/bash

# Title: Noise maker
# Author: spywill
# Description:  Prank-style “Noise Maker” tool that turns pager into a portable chaos machine. It lets you pick from a collection of annoying sounds.
# Version: 2.0

PROMPT "Tiny box of electronic annoyance.
Pick a noise, unleash chaos, regret later.

Creates sounds nobody asked for.
Turning silence into a personal problem.
Because peaceful environments are overrated."

SOUND_DIR="${_PAYLOAD_HOME}sounds"
PLAYER_PID_FILE="/tmp/noise_maker_player_$$.pid"

# Check sound directory
if [[ ! -d "$SOUND_DIR" ]]; then
	ERROR_DIALOG "Sound directory not found!
	Expected location:
	$SOUND_DIR

	Please install the MP3 sound files."
	exit 0
fi

# Stop current playback
cleanup() {
	local player_pid=""
	if [[ -f "$PLAYER_PID_FILE" ]]; then
		player_pid=$(cat "$PLAYER_PID_FILE" 2>/dev/null)
		if [[ "$player_pid" =~ ^[0-9]+$ ]]; then
			kill "$player_pid" 2>/dev/null
		fi
		rm -f "$PLAYER_PID_FILE"
	fi

	if [[ -n "${NOISE_MAKER_PID:-}" ]]; then
		kill "$NOISE_MAKER_PID" 2>/dev/null
		wait "$NOISE_MAKER_PID" 2>/dev/null
		NOISE_MAKER_PID=""
	fi
}

trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# Play selected MP3 continuously
noise_maker() {
	local file="$1"
	local pid

	while true; do
		pwmplay "$file" &
		pid=$!
		echo "$pid" > "$PLAYER_PID_FILE"
		wait "$pid"
		rm -f "$PLAYER_PID_FILE"
		sleep 0.1
	done
}

# Main menu
while true; do
	resp=$(LIST_PICKER \
		"NOISE MAKER" \
		"Cricket" \
		"Bird" \
		"Rooster" \
		"DogBarking" \
		"Firealarm" \
		"AlarmClock" \
		"Alert" \
		"Pager" \
		"Ring" \
		"DeskPhone" \
		"Static" \
		"HighPitch" \
		"LowPitch" \
		"DingDong" \
		"Flatline" \
		"BackUp" \
		"Microwave" \
		"CarPanic" \
		"Fart" \
		"FunnyLaugh" \
		"FobChirp" \
		"CDSkip" \
		"DentistDrill" \
		"PoliceSiren" \
		"Laser" \
		"Heartbeat" \
		"UFO" \
		"Doorbell" \
		"Warning" \
		"Glitch" \
		"Emergency" \
		"WaterDrip" \
		"Dialup" \
		"Exit" \
		"Exit"
	)

	# Exit handling
	if [[ "$resp" == "Exit" ]]; then
		confirm=$(CONFIRMATION_DIALOG "Warning: Silence detected. Continue?") || continue
		if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
			cleanup
			LOG green "Level reduced to acceptable limits.
			The pager has stopped screaming."
			exit 0
		fi
		continue
	fi

	# Check selection
	if [[ -z "$resp" ]]; then
		continue
	fi

	# Sound file
	file="$SOUND_DIR/$resp.mp3"
	if [[ ! -s "$file" ]]; then
		LOG red "Sound file missing:
		$resp.mp3"
		# Wait for Pager button input
		WAIT_FOR_INPUT
		continue
	fi

	# Stop previous playback
	cleanup

	# Start playback
	LOG yellow "Now Playing:"
	LOG cyan "$resp"
	LOG ""
	noise_maker "$file" &
	NOISE_MAKER_PID=$!

	# Wait for Pager button input
	WAIT_FOR_INPUT
	# Stop playback
	cleanup
done
