#!/bin/bash

# Title: Heads or tails
# Description: Play a game of HEADS or TAILS
# Author: spywill
# Version: 1.0

# Initialize counters
h=0
t=0
x=0

# Ask user to play HEADS or TAILS
resp=$(CONFIRMATION_DIALOG "PLAY HEADS OR TAILS

Enter [H] for HEADS
OR
Enter [T] for TAILS")

case "$resp" in
	$DUCKYSCRIPT_USER_CONFIRMED)
		;;
	$DUCKYSCRIPT_USER_DENIED)
		ERROR_DIALOG "User selected no, exiting"
		exit
		;;
	*)
		ERROR_DIALOG "Unknown response: $resp, exiting"
		exit
		;;
esac

# MAIN GAME LOOP
while true; do

	# Ask for Heads or Tails each round
	HEADS_TAILS=$(TEXT_PICKER "H-HEADS T-TAILS" "")

	# Determine user choice
	case "$HEADS_TAILS" in
		[Hh]) LOG "You have chosen (HEADS)"; user_choice="HEADS" ;;
		[Tt]) LOG "You have chosen (TAILS)"; user_choice="TAILS" ;;
		*) LOG "Defaulting to (HEADS)"; user_choice="HEADS" ;;
	esac

	spinnerid=$(START_SPINNER "Selected $user_choice")

	# Coin flip (50/50)
	sides=(HEADS TAILS)
	side=$(( RANDOM % 2 ))
	sleep 3
	result="${sides[side]}"

	# Win/Lose logic
	if [ "$result" = "$user_choice" ]; then
		STOP_SPINNER "$spinnerid"

		if [ "$result" = "HEADS" ]; then
			(( h++ )); count=$h
		else
			(( t++ )); count=$t
		fi

		PROMPT "($result)

YOU WIN
COUNT: $count"
		LOG green "($result) YOU WIN COUNT: $count"
	else
		STOP_SPINNER "$spinnerid"
		(( x++ ))

		ERROR_DIALOG "($result)

YOU LOSE
COUNT: $x"
		LOG red "($result) YOU LOSE COUNT: $x"
		WAIT_FOR_INPUT
		sleep 5
	fi

	# Ask if user wants to play again
	again=$(CONFIRMATION_DIALOG "Play again?")

	case "$again" in
		$DUCKYSCRIPT_USER_CONFIRMED)
			continue  # loop repeats
			;;
		$DUCKYSCRIPT_USER_DENIED)
			ERROR_DIALOG "User selected no, exiting"
			exit
			;;
		*)
			ERROR_DIALOG "Unknown response: $again, exiting"
			exit
			;;
	esac

done
