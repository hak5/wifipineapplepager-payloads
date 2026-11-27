#!/bin/bash
# Title: SSID Chaos Engine
# Author: RocketGod
# https://betaskynet.com
# Description: SSID Chaos Engine is a themed SSID broadcast generator designed to weaponize curiosity, paranoia, humor, and confusion—purely at the name level.
# Crew: The Pirates' Plunder - https://discord.gg/thepirates
# Version: 1.0

VERSION="1.0"
LOOTDIR="/root/loot/ssid_chaos"
HISTORY_FILE="$LOOTDIR/broadcast_history.log"
MAX_SSID_LENGTH=32

init_directories() {
    mkdir -p "$LOOTDIR"
}

log_broadcast() {
    echo "[$(date -Is)] Theme: $1 | SSIDs: $2" >> "$HISTORY_FILE"
}

truncate_ssid() {
    local ssid="$1"
    if [ ${#ssid} -gt $MAX_SSID_LENGTH ]; then
        echo "${ssid:0:$MAX_SSID_LENGTH}"
    else
        echo "$ssid"
    fi
}

# ============================================
# THEME LIBRARIES
# ============================================

load_theme_passive_aggressive() {
    THEME_NAME="Passive Aggressive Neighbor"
    THEME_ICON="[ANGRY]"
    SSIDS=(
        "Stop Stealing My WiFi"
        "Fuck You"
        "I Can Hear You Singing"
        "Your Music Is Too Loud"
        "Nice Parking Job Jerk"
        "We Can Smell Your Cooking"
        "Your Dog Barks All Night"
        "Put Some Pants On"
        "I Saw What You Did"
        "I banged Your Wife"
        "Return My Ladder Please"
        "Your Lawn Needs Mowing"
        "Your Kids Are Annoying"
        "I Know Your Secret"
        "We Need To Talk"
        "I Have Cameras"
        "Yes I Called The HOA"
        "Your Trash Day Is Tuesday"
        "I Saw Your Browser History"
        "Your Car Alarm Again"
        "I Pooped On Your Lawn"
    )
}

load_theme_confused_tech() {
    THEME_NAME="Confused Technology"
    THEME_ICON="[ERROR]"
    SSIDS=(
        "Loading... Please Wait"
        "Searching for Signal"
        "Error 404 WiFi Not Found"
        "Connection Timed Out"
        "Please Insert Disk 2"
        "Buffering..."
        "99 Percent Complete"
        "Have You Tried Rebooting"
        "PC Load Letter"
        "Task Failed Successfully"
        "Keyboard Not Found F1"
        "Warning Low Disk Space"
        "Would You Like To Update"
        "Your Trial Has Expired"
        "Syncing Forever"
        "Windows Is Shutting Down"
        "Blue Screen of Death"
        "Your CPU Has Melted"
        "Printer On Fire"
        "Abort Retry Fail"
    )
}

load_theme_dad_jokes() {
    THEME_NAME="Maximum Dad Jokes"
    THEME_ICON="[DAD]"
    SSIDS=(
        "WiFi So Serious"
        "LAN of Milk and Honey"
        "The LAN Before Time"
        "Bill Wi The Science Fi"
        "Drop It Like Its Hotspot"
        "Pretty Fly for a WiFi"
        "The Promised LAN"
        "No More Mister WiFi"
        "Router I Hardly Know Her"
        "WiFi Art Thou Romeo"
        "Get Off My LAN"
        "It Burns When IP"
        "Tell My WiFi Love Her"
        "Nacho WiFi"
        "Lord of the Pings"
        "Hide Yo Kids Hide Yo WiFi"
        "Wu Tang LAN"
        "Routers of Rohan"
        "The Amazing SpiderLAN"
        "This LAN Is My LAN"
    )
}

load_theme_hacker() {
    THEME_NAME="1337 H4X0R Mode"
    THEME_ICON="[HACK]"
    SSIDS=(
        "FBI Surveillance Van 7"
        "NSA Field Office 42"
        "CIA Stakeout Alpha"
        "DEA Task Force"
        "Police Undercover Unit 9"
        "Totally Not A Honeypot"
        "Your Packets Are Mine"
        "I Can See Your Packets"
        "hack the planet"
        "Zero Cool Was Here"
        "Crash Override Network"
        "Hack The Gibson"
        "Follow The White Rabbit"
        "rm -rf / for free WiFi"
        "sudo make me a sandwich"
        "Password Is Password"
        "WEP Protected Lol"
        "Definitely Not Malware"
        "Free Bitcoin Generator"
        "The Pirates Plunder"
    )
}

load_theme_paranoia() {
    THEME_NAME="Maximum Paranoia"
    THEME_ICON="[EYES]"
    SSIDS=(
        "We Know What You Did"
        "We Are Watching You"
        "You Are Being Monitored"
        "This Is Not A Drill"
        "Trust No One"
        "They Are Coming"
        "It Has Begun"
        "You Cannot Hide"
        "We See All"
        "Resistance Is Futile"
        "You Have Been Selected"
        "Your Time Is Running Out"
        "The Countdown Has Begun"
        "Phase 2 Initiated"
        "Sleeper Agents Activate"
        "Birds Arent Real WiFi"
        "5G Mind Control Tower 7"
        "Illuminati Guest Network"
        "Area 51 Employee WiFi"
        "Simulation Admin Access"
    )
}

load_theme_horror() {
    THEME_NAME="Spooky Scary"
    THEME_ICON="[FEAR]"
    SSIDS=(
        "The WiFi Is Coming"
        "From Inside The Router"
        "Im Behind You"
        "Dont Look Outside"
        "Something Is Watching"
        "You Let Me In"
        "I Live In Your Walls"
        "Check Under The Bed"
        "The Previous Owner"
        "Never Really Left"
        "It Follows Your WiFi"
        "They Never Found Them"
        "Pennywise Free WiFi"
        "Overlook Hotel Guest"
        "Room 237 WiFi"
        "Camp Crystal Lake"
        "Elm Street Hotspot"
        "Did You Hear That"
        "The Basement Has WiFi"
        "Built On Sacred Ground"
    )
}

load_theme_gamer() {
    THEME_NAME="Gamer Mode"
    THEME_ICON="[GAME]"
    SSIDS=(
        "Lag Is Not An Excuse"
        "Git Gud Scrub"
        "360 No Scope WiFi"
        "Pwned Your Connection"
        "Press F To Connect"
        "The Cake Is A Lie"
        "Do A Barrel Roll"
        "All Your Base Belong 2 Us"
        "Its Dangerous Go Alone"
        "Would You Kindly Connect"
        "You Died"
        "Wasted"
        "Pay 4.99 To Unlock WiFi"
        "Spawn Camping Here"
        "Victory Royale WiFi"
        "GG EZ"
        "AFK Getting Snacks"
        "Leroy Jenkins WiFi"
        "This Is My Swamp"
        "Respawn Point"
    )
}

load_theme_movies() {
    THEME_NAME="Cinematic Universe"
    THEME_ICON="[FILM]"
    SSIDS=(
        "May The WiFi Be With You"
        "You Shall Not Password"
        "One Does Not Simply Log In"
        "The Matrix Has You"
        "I Am Your Router"
        "Hogwarts Great Hall WiFi"
        "Batcave Guest Network"
        "Mordor Free WiFi"
        "Winterfell Guest Network"
        "Avengers Compound WiFi"
        "Skynet Global Defense"
        "Death Star Guest Access"
        "Ghostbusters HQ"
        "Wayne Manor Guest"
        "Stark Industries Secure"
        "Jurassic Park Visitor WiFi"
        "Dunder Mifflin Guest"
        "Starship Enterprise WiFi"
        "Daily Planet Staff"
        "S.H.I.E.L.D. Helicarrier"
    )
}

# ============================================
# BROADCAST ENGINE
# ============================================

apply_ssids() {
    LOG ""
    LOG "Broadcasting ${#SSIDS[@]} SSIDs..."
    LOG "------------------------------------"
    
    # Clear pool first
    PINEAPPLE_SSID_POOL_CLEAR
    sleep 1
    
    # Add all SSIDs
    local added=0
    for ssid in "${SSIDS[@]}"; do
        ssid=$(truncate_ssid "$ssid")
        LOG "  [+] $ssid"
        PINEAPPLE_SSID_POOL_ADD "$ssid"
        added=$((added + 1))
    done
    
    LOG "------------------------------------"
    
    # START THE BROADCAST - THIS IS CRITICAL!
    LOG "Starting broadcast..."
    PINEAPPLE_SSID_POOL_START start
    
    sleep 1
    log_broadcast "$THEME_NAME" "$added"
    
    LOG ""
    LOG "=== BROADCAST ACTIVE! ==="
    LOG "Theme: $THEME_NAME"
    LOG "SSIDs: $added"
    LOG ""
    
    ALERT "$THEME_ICON $added SSIDs Broadcasting!"
}

stop_broadcast() {
    LOG "Stopping broadcast..."
    PINEAPPLE_SSID_POOL_STOP
    LOG "Broadcast stopped."
    ALERT "Broadcast stopped!"
}

clear_pool() {
    LOG "Clearing SSID pool..."
    PINEAPPLE_SSID_POOL_STOP
    PINEAPPLE_SSID_POOL_CLEAR
    LOG "Pool cleared."
    ALERT "Pool cleared!"
}

# ============================================
# MAIN MENU
# ============================================

show_menu() {
    PROMPT "SSID CHAOS ENGINE v$VERSION

1. Passive Aggressive
2. Tech Errors
3. Dad Jokes
4. Hacker/FBI
5. Paranoia
6. Horror
7. Gamer
8. Movies
9. Stop Broadcast
10. Clear Pool
0. Exit"
}

main() {
    init_directories
    
    LOG "=== SSID CHAOS ENGINE v$VERSION ==="
    LOG "Ready to cause chaos..."
    LOG ""
    
    while true; do
        show_menu
        local choice=$(NUMBER_PICKER "Select option" "1")
        
        case "$choice" in
            0)
                LOG "Exiting..."
                exit 0
                ;;
            1)
                load_theme_passive_aggressive
                apply_ssids
                ;;
            2)
                load_theme_confused_tech
                apply_ssids
                ;;
            3)
                load_theme_dad_jokes
                apply_ssids
                ;;
            4)
                load_theme_hacker
                apply_ssids
                ;;
            5)
                load_theme_paranoia
                apply_ssids
                ;;
            6)
                load_theme_horror
                apply_ssids
                ;;
            7)
                load_theme_gamer
                apply_ssids
                ;;
            8)
                load_theme_movies
                apply_ssids
                ;;
            9)
                stop_broadcast
                ;;
            10)
                clear_pool
                ;;
            *)
                LOG "Invalid option: $choice"
                ;;
        esac
    done
}

main
