#!/bin/bash
# Title: Pocket Term
# Description: Pure custom command input.
# Controls: Up/Down to Scroll
# Author: Zeriaklr
# Version: 2.2

# Define and create the LOOT directory
LOOTDIR=/root/loot/Term
mkdir -p $LOOTDIR
#Change the loctaion the command are run to the home folder mostly for ls and better nav in a single command
cd

while true
do 
    # Main
    LOG magenta "Termanal"
    command=$(TEXT_PICKER "Enter Your Command" "")
    LOG blue "> $command"

    # Cleaning Up command for logging and saving (replace invalid chars with underscores)
    good_command=$(echo "$command" | tr '/: ' '_')
    lootfile=$LOOTDIR/$(date -Is)_$good_command

    LOG "Results will be saved to: $lootfile if specified\n"

    #Shows the output of the command that was entered
    $command | tee $lootfile | tr '\n' '\0' | xargs -0 -n 1 LOG green ""

    #Ask to save the out put so that the user can review at a later time and save the out come
    save=$(CONFIRMATION_DIALOG "X to Not save the output \n Checkmark to save the output")
    case "$save" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            LOG green "Saved log in $LOOTDIR \n with a file name of $lootfile"
            ;;
        $DUCKYSCRIPT_USER_DENIED)
            LOG red "Not saving Log"
            rm -f "$lootfile"
            ;;
        *)
            LOG "Unknown response: $save"
            LOG red "invalid input \n Saved log in $LOOTDIR \n with a file name of $lootfile"
            ;;
    esac

    # Breaking the loop if the user doesn't want to run another command
    end=$(CONFIRMATION_DIALOG "X to end \n CheckMark to run another Command")
    case $end in
        $DUCKYSCRIPT_USER_CONFIRMED)
            LOG green "Running again"
            ;;
        $DUCKYSCRIPT_USER_DENIED)
            LOG red "Exiting the program"
            break
            ;;
        *)
            LOG red "Invalid input. Exiting by default"
            break
            ;;
    esac
done