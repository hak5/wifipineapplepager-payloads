#!/bin/bash
# Title: Number Guesser
# Description: Pager-safe number guessing game with 5 tries and cheat mode
# Author: DoctorEnilno
# Version: 1.9
# Category: Games

# ====================================
# Settings
# ====================================

MAX_NUMBER=100
MIN_NUMBER=1
CHEAT_MODE=0     # 0=Off | 1=On
MAX_TRIES=5

# ====================================
# Functions
# ====================================

show_header() {
    LOG ""
    LOG blue "Number Guessing Game"
    LOG blue "By DoctorEnilno / EnilnoVortex"
    LOG ""
}

pick_number() {
    __number=$(( RANDOM % (MAX_NUMBER - MIN_NUMBER + 1) + MIN_NUMBER ))
}

get_user_guess() {
    usernum=$(NUMBER_PICKER "Guess a number between $MIN_NUMBER and $MAX_NUMBER" "1") || exit 0
}

# ====================================
# Main Loop
# ====================================

game_loop() {
    pick_number

    if [ $CHEAT_MODE -eq 1 ]; then
        LOG yellow "Cheat: The number is $__number"
    fi

    __tries=0

    while [ $__tries -lt $MAX_TRIES ]; do
        __tries=$((__tries + 1))
        LOG blue "Attempt $__tries of $MAX_TRIES"

        get_user_guess

        # Pager-safe numeric check
        case "$usernum" in
            ''|*[!0-9]*)
                LOG yellow "Please enter a valid number!"
                continue
                ;;
        esac

        # Range check
        if [ $usernum -lt $MIN_NUMBER ] || [ $usernum -gt $MAX_NUMBER ]; then
            LOG yellow "Out of bounds! Enter $MIN_NUMBER-$MAX_NUMBER."
            continue
        fi

        # Compare guess
        if [ $usernum -lt $__number ]; then
            LOG cyan "Too low!"
        elif [ $sernum -gt $__number ]; then
            LOG cyan "Too high!"
        else
            PROMPT "Congratulations! You guessed the number $number!"
            return
        fi
    done

    LOG "Game over! The number was $__number."
}

# ====================================
# Startup
# ====================================

show_header
game_loop
