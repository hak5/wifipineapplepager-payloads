#!/bin/bash

# Title: Simon Says
# Description: Memory game with lights and sounds!
# Author: RocketGod 
# https://betaskynet.com
# Crew: The Pirates' Plunder - https://discord.gg/thepirates
# Version: 1.0

LOOT_DIR="/root/loot/simon_says"
HIGH_SCORE_FILE="$LOOT_DIR/high_score"

declare -a PATTERN
SCORE=0
HIGH_SCORE=0

# === LED CONTROL ===

led_pattern() {
    . /lib/hak5/commands.sh
    HAK5_API_POST "system/led" "$1" >/dev/null 2>&1
}

led_off() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":100,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_up() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[true,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_down() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,true]}}]}'
}

led_left() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[false,true,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_right() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[true,true,false],"4":[false,false,false]}}]}'
}

led_all_red() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,false,false],"2":[true,false,false],"3":[true,false,false],"4":[true,false,false]}}]}'
}

# === SOUNDS ===

play_up()      { RINGTONE "U:d=16,o=6,b=200:c" & }
play_down()    { RINGTONE "D:d=16,o=5,b=200:g" & }
play_left()    { RINGTONE "L:d=16,o=5,b=200:e" & }
play_right()   { RINGTONE "R:d=16,o=6,b=200:e" & }
play_wrong()   { RINGTONE "error" & }
play_win()     { RINGTONE "bonus" & }
play_start()   { RINGTONE "getkey" & }
play_levelup() { RINGTONE "xp" & }

# === GAME ===

flash_direction() {
    local dir=$1
    local ms=${2:-300}
    case "$dir" in
        UP)    led_up;    play_up ;;
        DOWN)  led_down;  play_down ;;
        LEFT)  led_left;  play_left ;;
        RIGHT) led_right; play_right ;;
    esac
    sleep 0.$((ms / 100))
    led_off
    sleep 0.08
}

add_to_pattern() {
    local dirs=("UP" "DOWN" "LEFT" "RIGHT")
    PATTERN+=("${dirs[$((RANDOM % 4))]}")
}

show_pattern() {
    local speed=350
    [ $SCORE -gt 4 ] && speed=300
    [ $SCORE -gt 8 ] && speed=250
    [ $SCORE -gt 12 ] && speed=200
    [ $SCORE -gt 16 ] && speed=160
    [ $SCORE -gt 20 ] && speed=130
    
    for dir in "${PATTERN[@]}"; do
        flash_direction "$dir" $speed
    done
}

get_player_input() {
    for expected in "${PATTERN[@]}"; do
        local btn=$(WAIT_FOR_INPUT)
        
        # A = quit
        [ "$btn" = "A" ] && return 2
        
        case "$btn" in
            UP)    led_up;    play_up ;;
            DOWN)  led_down;  play_down ;;
            LEFT)  led_left;  play_left ;;
            RIGHT) led_right; play_right ;;
        esac
        sleep 0.12
        led_off
        
        [ "$btn" != "$expected" ] && return 1
    done
    return 0
}

startup_spin() {
    for b in led_up led_right led_down led_left led_up led_right led_down led_left; do
        $b; sleep 0.06
    done
    led_off
}

game_over_flash() {
    play_wrong
    for i in 1 2 3; do
        led_all_red; sleep 0.1
        led_off; sleep 0.06
    done
}

# === MAIN ===

mkdir -p "$LOOT_DIR"
[ -f "$HIGH_SCORE_FILE" ] && HIGH_SCORE=$(cat "$HIGH_SCORE_FILE" 2>/dev/null)
[[ ! "$HIGH_SCORE" =~ ^[0-9]+$ ]] && HIGH_SCORE=0

PATTERN=()
SCORE=0

LOG "SIMON SAYS - by RocketGod"
LOG "High Score: $HIGH_SCORE"
LOG ""
play_start
startup_spin

while true; do
    add_to_pattern
    SCORE=${#PATTERN[@]}
    
    if [ $((SCORE % 4)) -eq 0 ] && [ $SCORE -gt 0 ]; then
        play_levelup
        LOG "LEVEL UP! Speed increased!"
    fi
    
    LOG "Round $SCORE"
    show_pattern
    
    get_player_input
    result=$?
    
    if [ $result -eq 2 ]; then
        led_off
        SCORE=$((SCORE - 1))
        [ $SCORE -gt $HIGH_SCORE ] && echo "$SCORE" > "$HIGH_SCORE_FILE"
        LOG "Quit - Score: $SCORE"
        exit 0
    elif [ $result -eq 1 ]; then
        game_over_flash
        SCORE=$((SCORE - 1))
        [ $SCORE -gt $HIGH_SCORE ] && { echo "$SCORE" > "$HIGH_SCORE_FILE"; HIGH_SCORE=$SCORE; }
        LOG "WRONG! Score: $SCORE (Best: $HIGH_SCORE)"
        LOG "Any button=Retry, A=Quit"
        btn=$(WAIT_FOR_INPUT)
        [ "$btn" = "A" ] && { led_off; exit 0; }
        PATTERN=()
        SCORE=0
        LOG ""
        LOG "SIMON SAYS - by RocketGod"
        LOG "High Score: $HIGH_SCORE"
        play_start
        startup_spin
    else
        play_win
    fi
done
