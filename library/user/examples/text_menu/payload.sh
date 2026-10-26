#!/bin/bash
# Title: Text Menu Example
# Author: marcdel
# Description: Example of a log/text based alternative to an option dialog. Pattern stolen from RocketGod's Device Hunter.
# Version: 1.0

MENU_OPTIONS=(
    "Option 1"
    "Option 2"
    "Option 3"
)
TOTAL_OPTIONS=${#MENU_OPTIONS[@]}

SELECTED_OPTION=0

print_options() {
    LOG ""
    LOG "Options:"
    for i in "${!MENU_OPTIONS[@]}"; do
        if [ $i -eq $SELECTED_OPTION ]; then
            LOG "-> ${MENU_OPTIONS[$i]}"
        else
            LOG "  ${MENU_OPTIONS[$i]}"
        fi
    done
    LOG ""
    LOG "UP/DOWN=Change Selection A=Select"
}

text_menu() {
    local OPTION=0
    print_options

    while true; do
        local btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP|LEFT)
                SELECTED_OPTION=$((SELECTED_OPTION - 1))
                [ $SELECTED_OPTION -lt 0 ] && SELECTED_OPTION=$((TOTAL_OPTIONS - 1))
                print_options
                ;;
            DOWN|RIGHT)
                SELECTED_OPTION=$((SELECTED_OPTION + 1))
                [ $SELECTED_OPTION -ge $TOTAL_OPTIONS ] && SELECTED_OPTION=0
                print_options
                ;;
            A)
                echo $SELECTED_OPTION
                return 0
                ;;
            B)
                return 0
                ;;
            *)
                LOG "Invalid input: $btn"
                return -1
                ;;
        esac
    done
}

LOG " _____                   _   ";
LOG "/  ___|                 | |  ";
LOG "\\ \`--.__      _____  ___| |_ ";
LOG " \`--. \\ \\ /\\ / / _ \\/ _ \\ __|";
LOG "/\\__/ /\\ V  V /  __/  __/ |_ ";
LOG "\\____/  \\_/\\_/ \\___|\\___|\\__|";
LOG "                             ";
LOG "                             ";


LOG ""
LOG "Your Rad Payload"
LOG ""

selected=$(text_menu)
LOG ""
LOG "Selected option: ${MENU_OPTIONS[$selected]}"

LOG ""
LOG "Totally doing something with that selection..."
LOG ""

LOG "Done!"

exit 0