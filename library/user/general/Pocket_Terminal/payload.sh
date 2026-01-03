#!/bin/bash
# Title: Pocket Term
# Description: Pure custom command input.
# Controls: Up/Down to Scroll
# Author: Zeriaklr
# Version: 2.1

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
    save=$(NUMBER_PICKER "1 Save, 2 Del" 2)

    if [ "$save" == 1 ]; then
        LOG green "Saved log in $LOOTDIR \n with a file name of $lootfile"
    elif [ "$save" == 2 ]; then
        LOG red "Not saving Log"
        rm -f "$lootfile"
    else
        LOG red "invalid input \n Saved log in $LOOTDIR \n with a file name of $lootfile"
    fi

    # Breaking the loop if the user doesn't want to run another command
    end=$(NUMBER_PICKER "1 Next, 2 Exit" 1)

    case $end in
        1)
            LOG green "Running again"
            ;;
        2)
            LOG red "Exiting the program"
            break
            ;;
        *)
            LOG red "Invalid input. Exiting by default"
            break
            ;;
    esac
done