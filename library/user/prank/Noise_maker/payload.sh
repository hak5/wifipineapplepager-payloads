#!/bin/bash

# Title: Noise maker
# Author: spywill
# Description:  Prank-style “Noise Maker” tool that turns pager into a portable chaos machine. It lets you pick from a collection of annoying sounds.
# Version: 1.0

PROMPT "# Tiny box of electronic annoyance.
# Pick a noise, unleash chaos, regret later.

Creates sounds nobody asked for.
Turning silence into a personal problem.
Because peaceful environments are overrated."

declare -A SOUNDS

SOUNDS["Cricket"]="Cricket:d=16,o=7,b=900:c,c#,c,c#,c,c#,c,c#,c,c#,c,c#"
SOUNDS["Bird"]="Bird:d=16,o=7,b=260:32g,32a,32b,32p,32b,32a,32g,32p,32d6,32g,32p,32g,32a,32b,32a,32g"
SOUNDS["Firealarm"]="Fire_alarm:d=4,o=5,b=130:e,8p,e,8p,e,8p,e"
SOUNDS["EASAlert"]="EASAlert:d=1,o=5,b=900:g,a,g,a,g,a,g,a,g,a,g,a,g,a,g,a,g,a,g,a,g,a,g,a,g,a"
SOUNDS["Pager"]="Pager:d=16,o=6,b=160:8d,p,2d,p,8d,p,2d,p,8d,p,2d"
SOUNDS["Ring"]="Ring:d=4,o=5,b=100:32b,32d6,32g6,32g6,32g6,8p,32b,32d6,32g6,32g6,32g6,2p"
SOUNDS["DeskPhone"]="Desk_Phone:d=8,o=5,b=500:c#,f,c#,f,c#,f,c#,f,c#,f,4p.,c#,f,c#,f,c#,f,c#,f,c#,f"
SOUNDS["Static"]="Static:d=32,o=2,b=900:c,b7,d,a7,e,g7,f,f7,g,e7,a,d7,b,c7,c4,b,d4,a,e4,g,f4,f,g4,e,a4,d,b4,c,c8,c,b8,d,a8,e,g8,f,f8,g,e8,a,d8,b,c8"
SOUNDS["HighPitch"]="HighPitch:d=1,o=8,b=200:b,b,b,b"
SOUNDS["LowPitch"]="LowPitch:d=1,o=4,b=200:c,c,c,c"
SOUNDS["DingDong"]="DingDong:d=4,o=5,b=120:e6,2c6"
SOUNDS["Flatline"]="Flatline:d=1,o=7,b=30:c"
SOUNDS["BackUp"]="BackUp:d=4,o=6,b=110:b,p,b,p,b,p,b,p"
SOUNDS["Microwave"]="Microwave:d=2,o=6,b=150:b,b,b"
SOUNDS["CarPanic"]="CarPanic:d=8,o=5,b=160:f,p,f,p,f,p,f,p"
SOUNDS["Scooter"]="Scooter:d=12,o=6,b=140:e,e"
SOUNDS["MadLaugh"]="MadLaugh:d=8,o=5,b=150:f6,p,f6,p,f6,p,f6,p,2f#6"
SOUNDS["Meltdown"]="Meltdown:d=8,o=4,b=180:c,c7,p,c,c7,p,c,c7,p,c#,c#7,p,c#,c#7,p,d,d7,p,d#,d#7,p,e,e7,1p"
SOUNDS["FobChirp"]="FobChirp:d=32,o=7,b=200:b,p,b"
SOUNDS["CDSkip"]="CDSkip:d=32,o=6,b=900:c,d,e,f,c,d,e,f,c,d,e,f,c,d,e,f"
SOUNDS["DentistDrill"]="DentistDrill:d=16,o=8,b=240:b,a#,b,a#,b,a#,b,a#,1b"

# Background ringtone loop
noise_maker() {
	local ringtone="$1"

	while true; do
		RINGTONE "$ringtone" 
		sleep 0.5
	done
}

NOISE_MAKER_PID=""

# Cleanup background process
cleanup() {
	if [[ -n "${NOISE_MAKER_PID:-}" ]]; then
		kill -9 "$NOISE_MAKER_PID" 2>/dev/null
		unset NOISE_MAKER_PID
	fi
}

trap cleanup EXIT INT TERM

# Main menu loop
while true; do
	resp=$(LIST_PICKER \
		"NOISE MAKER" \
		"Cricket" \
		"Bird" \
		"Firealarm" \
		"EASAlert" \
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
		"Scooter" \
		"MadLaugh" \
		"Meltdown" \
		"FobChirp" \
		"CDSkip" \
		"DentistDrill" \
		"Exit" \
		"Exit"
	)

	# Exit handling
	if [[ "$resp" == "Exit" ]]; then
		confirm=$(CONFIRMATION_DIALOG "Warning: Silence detected. Continue?") || exit 1
		if [[ "$confirm" == "$DUCKYSCRIPT_USER_CONFIRMED" ]]; then
			LOG green "Chaos level reduced to acceptable limits.
			The pager has stopped screaming."
			exit 0
		fi
		continue
	fi

	# Sound handling
	if [[ -n "${SOUNDS[$resp]:-}" ]]; then
		cleanup

		noise_maker "${SOUNDS[$resp]}" &
		NOISE_MAKER_PID=$!

		LOG yellow "$resp"
		LOG cyan "${SOUNDS[$resp]}"
		LOG ""

		WAIT_FOR_INPUT
		cleanup
	else
		LOG red "[!] Unknown selection: $resp"
	fi
done
