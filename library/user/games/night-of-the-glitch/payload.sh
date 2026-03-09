#!/bin/bash
#
# Night of the Glitch — Pager Edition 
#Author - Notorious Squirrel ,HAK5 enthusiast.
# Controls (Pager)
#   Corridor (hub):
#     UP    = Open locker
#     RIGHT = Disarm alarm
#     DOWN  = BLACKWIRE door
#     A     = Enter Haunted Wing
#     LEFT  = Inventory
#     B     = Back
#
#   Haunted Wing:
#     UP/DOWN/LEFT/RIGHT = Move
#     A     = Visual Map
#     B     = Back to corridor
#
# Notes:
# - Designed for WiFi Pineapple Pager runtime (LOG / WAIT_FOR_INPUT).
# - Logs to /tmp/night_glitch.log for debugging if nothing appears on screen.
#

# --------------------------------------------------
# DEBUG LOGGING (so you can see what happened if UI is blank)
# --------------------------------------------------
exec >/tmp/night_glitch.log 2>&1
set +u
set +e

# --------------------------------------------------
# Load Pager runtime (one of these typically exists)
# --------------------------------------------------
source /usr/lib/pager/functions.sh 2>/dev/null || true
source /etc/pager/functions.sh 2>/dev/null || true
source /root/payloads/system/functions.sh 2>/dev/null || true

# --------------------------------------------------
# Fallbacks if LOG / WAIT_FOR_INPUT aren't present (SSH testing)
# --------------------------------------------------
type LOG >/dev/null 2>&1 || LOG(){ echo "$@"; }
type WAIT_FOR_INPUT >/dev/null 2>&1 || WAIT_FOR_INPUT(){ read -r REPLY; echo "$REPLY"; }

LOG "Night of the Glitch: payload starting…"
sleep 0.2

# ----------------------------
# Pager IO helpers
# ----------------------------
line () { LOG ""; }
say ()  { LOG "$1"; }
pause () { sleep "${1:-0.25}"; }

wait_input () {
  LOG "> "
  WAIT_FOR_INPUT
}

good_bye () { line; say "Good Bye"; exit 0; }

# ----------------------------
# State
# ----------------------------
read_note=0
terminal_unlocked=0
saw_shadow=0
alarm_armed=1
entered_datavault=0
fail_count=0
took_usb_from_van=0
ghosts_cleared=0

# inventory flags
old_usb=0
decryptor_usb=0
skeleton_keycard=0
signal_jammer=0
spectral_lens=0
vine_key=0
toy_drone=0
salt_of_life=0
fuse_item=0

# haunted wing map
current_node="Entry"

reset_game () {
  read_note=0
  terminal_unlocked=0
  saw_shadow=0
  alarm_armed=1
  entered_datavault=0
  fail_count=0
  took_usb_from_van=0
  ghosts_cleared=0

  old_usb=0
  decryptor_usb=0
  skeleton_keycard=0
  signal_jammer=0
  spectral_lens=0
  vine_key=0
  toy_drone=0
  salt_of_life=0
  fuse_item=0

  current_node="Entry"
}

# ----------------------------
# UI: chooser menus (pager-safe)
# ----------------------------
buttons_yn () {
  say "UP = Yes"
  say "DOWN = No"
  say "B = Back/Quit"
}

# Pick from a list using UP/DOWN then A to confirm
# echoes selected index (1-based); 0 means back
pick_option () {
  local title="$1"; shift
  local opts=("$@")
  local idx=0
  while true; do
    line
    say "$title"
    local i
    for i in "${!opts[@]}"; do
      if [[ $i -eq $idx ]]; then
        say "> ${opts[$i]}"
      else
        say "  ${opts[$i]}"
      fi
    done
    say "UP/DOWN=move  A=select  B=back"
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      UP)
        idx=$((idx-1)); if [[ $idx -lt 0 ]]; then idx=$((${#opts[@]}-1)); fi
        ;;
      DOWN)
        idx=$((idx+1)); if [[ $idx -ge ${#opts[@]} ]]; then idx=0; fi
        ;;
      A)
        echo $((idx+1))
        return 0
        ;;
      B)
        echo 0
        return 0
        ;;
      *)
        ;;
    esac
  done
}

show_inventory () {
  line
  say "Inventory:"
  local empty=1
  [[ $old_usb -eq 1 ]] && say "• Old USB Stick" && empty=0
  [[ $decryptor_usb -eq 1 ]] && say "• Decryptor USB" && empty=0
  [[ $skeleton_keycard -eq 1 ]] && say "• Skeleton Keycard" && empty=0
  [[ $signal_jammer -eq 1 ]] && say "• Signal Jammer" && empty=0
  [[ $spectral_lens -eq 1 ]] && say "• Spectral Lens" && empty=0
  [[ $vine_key -eq 1 ]] && say "• Vine Key" && empty=0
  [[ $toy_drone -eq 1 ]] && say "• Toy Drone" && empty=0
  [[ $salt_of_life -eq 1 ]] && say "• Salt of Life" && empty=0
  [[ $fuse_item -eq 1 ]] && say "• Fuse" && empty=0
  [[ $empty -eq 1 ]] && say "[empty]"
  say "A=continue"
  while true; do
    local cmd
    cmd=$(wait_input)
    [[ "$cmd" == "A" || "$cmd" == "B" ]] && return 0
  done
}

# ----------------------------
# Effects (pager-safe)
# ----------------------------
digit_rain () {
  local frames="${1:-10}"
  local charset="01A3C5E79F"
  local f i
  for ((f=0; f<frames; f++)); do
    local line_str=""
    for ((i=0; i<20; i++)); do
      local idx=$((RANDOM % ${#charset}))
      line_str+="${charset:idx:1}"
    done
    say "$line_str"
    pause 0.06
  done
}

# ----------------------------
# Puzzles (button-based)
# ----------------------------
puzzle_base64_note () {
  line
  say "Sticky note under keyboard:"
  say "SkFDSw=="
  say "(Decode for access word)"
  read_note=1
  say "A=back"
  while true; do
    local cmd
    cmd=$(wait_input)
    [[ "$cmd" == "A" || "$cmd" == "B" ]] && return 0
  done
}

terminal_code_picker () {
  local pick
  pick=$(pick_option "Enter Access Code" "JACK" "JUNE" "NODE" "BACK")
  case "$pick" in
    1) return 0 ;;
    4|0) return 2 ;;
    *) return 1 ;;
  esac
}

keypad_code_picker () {
  local pick
  pick=$(pick_option "Keypad Code?" "RDGS" "SEHT" "RFGS" "BACK")
  case "$pick" in
    1) return 0 ;;
    4|0) return 2 ;;
    *) return 1 ;;
  esac
}

puzzle_study () {
  local pick
  pick=$(pick_option "Unscramble: I G U E P V" "GIVE UP" "GIVE IN" "UP GIVE" "BACK")
  case "$pick" in
    1) return 0 ;;
    4|0) return 2 ;;
    *) return 1 ;;
  esac
}

puzzle_conservatory () {
  local pick
  pick=$(pick_option "Order directions" "E S W N" "N E S W" "E N S W" "BACK")
  case "$pick" in
    1) return 0 ;;
    4|0) return 2 ;;
    *) return 1 ;;
  esac
}

puzzle_children () {
  local pick
  pick=$(pick_option "Repeat colours" "blue red blue" "red blue red" "blue blue red" "BACK")
  case "$pick" in
    1) return 0 ;;
    4|0) return 2 ;;
    *) return 1 ;;
  esac
}

puzzle_kitchen () {
  local pick
  pick=$(pick_option "Ingredient?" "salt" "sugar" "oil" "BACK")
  case "$pick" in
    1) return 0 ;;
    4|0) return 2 ;;
    *) return 1 ;;
  esac
}

puzzle_basement () {
  local pick
  pick=$(pick_option "Fuse slots" "2 4 6" "1 3 5" "2 3 6" "BACK")
  case "$pick" in
    1) return 0 ;;
    4|0) return 2 ;;
    *) return 1 ;;
  esac
}

# ----------------------------
# Visual Map (A in Haunted Wing)
# ----------------------------
show_visual_map () {
  line
  say "HAUNTED WING MAP"
  say ""
  say "          [STU]"
  say "            |"
  say "          [N.H]"
  say "            |"
  say "[TRP] - [W.H] - [E.H] - [CLN]"
  say "            |"
  say "          [ENT]"
  say "            |"
  say "          [S.H] - [KIT]"
  say "            |"
  say "          [CHI]"
  say "            |"
  say "          [BAS]"
  say ""
  say "You are in: [$current_node]"
  say "A or B = Close map"

  while true; do
    local cmd
    cmd=$(wait_input)
    [[ "$cmd" == "A" || "$cmd" == "B" ]] && return
  done
}

# ----------------------------
# Scenes
# ----------------------------
banner () {
  line
  say "NIGHT OF THE GLITCH"
  say "A=Start  B=Quit"
}

scene_callout () {
  banner
  while true; do
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      A) break ;;
      B) good_bye ;;
      *) ;;
    esac
  done

  line
  say "[RING RING]"
  say "Helpdesk line lights up."
  say "Caller: Blackwire Estate"
  buttons_yn
  while true; do
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      UP)
        line
        say "You answer..."
        say "SIGNAL INTRUSION!"
        digit_rain 12
        say "Coordinates sent."
        pause 0.2
        scene_van
        return
        ;;
      DOWN)
        line
        say "You ignore it."
        say "Every screen wakes..."
        say "NEW TICKET: INTERNET DOWN"
        say "SSID: N3XU5_Guest"
        say "Assigned: YOU"
        pause 0.2
        scene_van
        return
        ;;
      B) good_bye ;;
      *) ;;
    esac
  done
}

scene_van () {
  line
  say "In the van. Drizzle."
  say "Grab old USB?"
  buttons_yn
  while true; do
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      UP)
        took_usb_from_van=1
        old_usb=1
        say "[+] Old USB Stick"
        pause 0.2
        scene_arrival
        return
        ;;
      DOWN)
        say "You leave it."
        pause 0.2
        scene_arrival
        return
        ;;
      B) good_bye ;;
      *) ;;
    esac
  done
}

scene_arrival () {
  line
  say "BLACKWIRE ESTATE"
  say "UP=Knock  DOWN=Open Door  B=Quit"
  while true; do
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      UP)  say "You knock... door opens." ; break ;;
      DOWN) say "Handle turns. Waiting." ; break ;;
      B) good_bye ;;
      *) ;;
    esac
  done

  line
  say "Inside: dust + ozone."
  say "Sockets spark."
  say "Bulbs explode!"
  pause 0.3
  say "SYSTEM FAILURE"
  digit_rain 16
  say "BOOT SEQUENCE: OK"
  pause 0.2
  say "You wake in a freezing data centre..."
  pause 0.2
  scene_intro
}

scene_intro () {
  line
  say "DATA CENTRE"
  say "UP: Terminal"
  say "RIGHT: Hide"
  say "DOWN: Exit"
  say "LEFT: Inventory"
  say "B: Quit"
  while true; do
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      LEFT) show_inventory ;;
      UP) scene_terminal; return ;;
      RIGHT) scene_hide; return ;;
      DOWN) scene_corridor; return ;;
      B) good_bye ;;
      *) ;;
    esac
  done
}

scene_hide () {
  line
  say "You hide behind racks..."
  say "A figure: your shape."
  if [[ $signal_jammer -eq 1 ]]; then
    say "Signal Jammer jitters it."
    say "You slip away."
    pause 0.2
    scene_corridor
    return
  fi
  say "Reflection crawls closer..."
  pause 0.4
  say "GAME OVER: Reflection Error"
  scene_end
}

scene_terminal () {
  while true; do
    line
    say "MAIN TERMINAL"
    say "UP: Try code"
    say "RIGHT: Search desk"
    say "DOWN: Back"
    say "LEFT: Inventory"
    say "B: Quit"
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      LEFT) show_inventory ;;
      UP)
        terminal_code_picker
        case $? in
          0)
            say "ACCESS GRANTED"
            say "Drawer opens..."
            if [[ $took_usb_from_van -eq 1 && $old_usb -eq 1 ]]; then
              say "Old NEXUS stick interfaces."
              old_usb=0
            fi
            decryptor_usb=1
            terminal_unlocked=1
            say "[+] Decryptor USB"
            pause 0.2
            scene_corridor
            return
            ;;
          1)
            say "ACCESS DENIED"
            fail_count=$((fail_count+1))
            if [[ $fail_count -ge 3 ]]; then
              say "Room doubles for a heartbeat..."
              saw_shadow=1
            fi
            ;;
          2) ;;
        esac
        ;;
      RIGHT)
        puzzle_base64_note
        ;;
      DOWN)
        scene_intro
        return
        ;;
      B) good_bye ;;
      *) ;;
    esac
  done
}

# ----------------------------
# CORRIDOR (UPDATED)
# A    = Haunted Wing
# LEFT = Inventory
# ----------------------------
scene_corridor () {
  while true; do
    line
    say "CORRIDOR: BLACKWIRE"
    [[ $alarm_armed -eq 1 ]] && say "Alarm: ARMED" || say "Alarm: OFF"
    say "UP: Open locker"
    say "RIGHT: Disarm alarm"
    say "DOWN: BLACKWIRE door"
    say "A: Haunted Wing"
    say "LEFT: Inventory"
    say "B: Back"
    local cmd
    cmd=$(wait_input)

    case "$cmd" in
      UP)
        say "Locker: card + puck"
        skeleton_keycard=1
        signal_jammer=1
        say "[+] Skeleton Keycard"
        say "[+] Signal Jammer"
        ;;
      RIGHT)
        if [[ $decryptor_usb -eq 1 ]]; then
          say "Decryptor runs..."
          say "Alarm disarmed."
          alarm_armed=0
        else
          say "Need something smarter."
        fi
        ;;
      DOWN)
        scene_blackwire_door
        return
        ;;
      A)
        scene_haunted_map
        return
        ;;
      LEFT)
        show_inventory
        ;;
      B)
        scene_intro
        return
        ;;
      *)
        ;;
    esac
  done
}

scene_blackwire_door () {
  while true; do
    line
    say "BLACKWIRE DOOR"
    [[ $skeleton_keycard -eq 1 ]] && say "Keycard: READY" || say "Need a keycard."
    say "UP: Use keycard"
    say "RIGHT: Inspect keypad"
    say "LEFT: Inventory"
    say "B: Back"
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      LEFT) show_inventory ;;
      UP|RIGHT)
        if [[ $skeleton_keycard -ne 1 ]]; then
          say "No suitable card."
          continue
        fi
        keypad_code_picker
        case $? in
          0)
            say "Bolts retract."
            entered_datavault=1
            scene_datavault
            return
            ;;
          1)
            say "Angry buzz."
            fail_count=$((fail_count+1))
            [[ $fail_count -ge 3 ]] && say "Something flickers with it..."
            ;;
          2) ;;
        esac
        ;;
      B)
        scene_corridor
        return
        ;;
      *)
        ;;
    esac
  done
}

scene_datavault () {
  while true; do
    line
    say "DATA VAULT"
    say "UP: Extract ALL"
    say "RIGHT: Target ONLY"
    say "DOWN: Leave"
    say "LEFT: Inventory"
    say "B: Back"
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      LEFT) show_inventory ;;
      UP)
        if [[ $alarm_armed -eq 1 ]]; then
          say "SIRENS. Doors slam."
          say "GAME OVER: Too Greedy"
          scene_end
          return
        else
          say "ENDING: Clean Sweep"
          scene_end
          return
        fi
        ;;
      RIGHT)
        say "ENDING: Surgeon’s Cut"
        if [[ $ghosts_cleared -ge 3 ]]; then
          say "ENDING: Haunted Cleanup"
        fi
        scene_end
        return
        ;;
      DOWN)
        say "You step away."
        scene_corridor
        return
        ;;
      B)
        scene_corridor
        return
        ;;
      *)
        ;;
    esac
  done
}

scene_end () {
  line
  say "Play again?"
  buttons_yn
  while true; do
    local cmd
    cmd=$(wait_input)
    case "$cmd" in
      UP)
        reset_game
        scene_callout
        return
        ;;
      DOWN)
        say "Sleep well, hacker 😈"
        good_bye
        ;;
      B)
        good_bye
        ;;
      *)
        ;;
    esac
  done
}

# ----------------------------
# Haunted Wing
# A = Visual Map
# B = Back to corridor
# ----------------------------
show_minimap () {
  line
  say "HAUNTED WING: $current_node"
  say "UP=N  RIGHT=E  DOWN=S  LEFT=W"
  say "A=Map  B=Back"
}

node_desc () {
  case "$1" in
    "Entry") say "Cracked sign: HAUNTED WING." ;;
    "West Hall") say "Draughty. Floorboards whine." ;;
    "South Hall") say "Brine + old bread. Pans glint east." ;;
    "North Hall") say "Portraits. Footfalls out of sync." ;;
    "East Hall") say "Vines under cracked skylight." ;;
    "Study") say "Oak door. Paper + ozone." ;;
    "Conservatory") say "Broken glass. Vines twist." ;;
    "Kitchen") say "Copper pans. Chef mutters." ;;
    "Children") say "Two dolls blink: blue red blue." ;;
    "Basement") say "Low hum. Voltage in the air." ;;
    "TrapDoor") say "Runner hides a seam..." ;;
    "Clown Den") say "Terminal loops a sick smile." ;;
  esac
}

move_node () {
  local cur="$1" d="$2"
  case "$cur,$d" in
    "Entry,n") echo "West Hall" ;;
    "Entry,e") echo "South Hall" ;;
    "West Hall,n") echo "North Hall" ;;
    "West Hall,s") echo "Entry" ;;
    "West Hall,w") echo "TrapDoor" ;;
    "South Hall,w") echo "Entry" ;;
    "South Hall,e") echo "Kitchen" ;;
    "South Hall,s") echo "Children" ;;
    "North Hall,n") echo "Study" ;;
    "North Hall,s") echo "West Hall" ;;
    "North Hall,e") echo "East Hall" ;;
    "East Hall,w") echo "North Hall" ;;
    "East Hall,n") echo "Conservatory" ;;
    "East Hall,e") echo "Clown Den" ;;
    "Study,s") echo "North Hall" ;;
    "Conservatory,s") echo "East Hall" ;;
    "Kitchen,w") echo "South Hall" ;;
    "Children,n") echo "South Hall" ;;
    "Children,s") echo "Basement" ;;
    "Basement,n") echo "Children" ;;
    "TrapDoor,e") echo "West Hall" ;;
    "Clown Den,w") echo "East Hall" ;;
    *) echo "" ;;
  esac
}

haunted_trigger () {
  local n="$1"

  if [[ "$n" == "TrapDoor" ]]; then
    line
    say "String twangs."
    say "Floor opens."
    say "GAME OVER: Floor Update Required"
    scene_end
    return
  fi

  if [[ "$n" == "Clown Den" ]]; then
    line
    say "A chuckle behind you."
    say "'Re-boot your soles...'"
    say "GAME OVER: Patch Tuesday"
    scene_end
    return
  fi

  case "$n" in
    "Study")
      line
      say "Ghost: 'rearrange it...'"
      puzzle_study
      case $? in
        0) say "[+] Spectral Lens"; spectral_lens=1; ghosts_cleared=$((ghosts_cleared+1));;
        1) say "Pages flutter: WRONG";;
        2) ;;
      esac
      ;;
    "Conservatory")
      line
      say "Gardener ghost: 'sunrise order...'"
      puzzle_conservatory
      case $? in
        0) say "[+] Vine Key"; vine_key=1; ghosts_cleared=$((ghosts_cleared+1));;
        1) say "Vines tighten: WRONG";;
        2) ;;
      esac
      ;;
    "Kitchen")
      line
      say "Chef: 'makes all better...'"
      puzzle_kitchen
      case $? in
        0) say "[+] Salt of Life"; salt_of_life=1; ghosts_cleared=$((ghosts_cleared+1));;
        1) say "Chef: BLAND!";;
        2) ;;
      esac
      ;;
    "Children")
      line
      say "Dolls: 'repeat after me!'"
      puzzle_children
      case $? in
        0) say "[+] Toy Drone"; toy_drone=1; ghosts_cleared=$((ghosts_cleared+1));;
        1) say "Dolls: WRONG...";;
        2) ;;
      esac
      ;;
    "Basement")
      line
      say "Janitor: 'only evens...'"
      puzzle_basement
      case $? in
        0) say "[+] Fuse"; fuse_item=1; ghosts_cleared=$((ghosts_cleared+1));;
        1) say "Sparks jump: WRONG";;
        2) ;;
      esac
      ;;
    *)
      ;;
  esac
}

scene_haunted_map () {
  line
  say "HAUNTED WING"
  say "Navigate with arrows."
  say "A = Map"
  say "B = Corridor"
  pause 0.2

  current_node="Entry"

  while true; do
    line
    node_desc "$current_node"

    case "$current_node" in
      "Study") haunted_trigger "Study" ;;
      "Conservatory") haunted_trigger "Conservatory" ;;
      "Kitchen") haunted_trigger "Kitchen" ;;
      "Children") haunted_trigger "Children" ;;
      "Basement") haunted_trigger "Basement" ;;
      "TrapDoor") haunted_trigger "TrapDoor" ;;
      "Clown Den") haunted_trigger "Clown Den" ;;
    esac

    show_minimap
    local cmd
    cmd=$(wait_input)

    case "$cmd" in
      B)
        say "Hall sighs shut behind you."
        scene_corridor
        return
        ;;
      A)
        show_visual_map
        ;;
      UP|RIGHT|DOWN|LEFT)
        local d nxt
        case "$cmd" in
          UP) d="n" ;;
          RIGHT) d="e" ;;
          DOWN) d="s" ;;
          LEFT) d="w" ;;
        esac
        nxt=$(move_node "$current_node" "$d")
        if [[ -z "$nxt" ]]; then
          say "Cold stone. No way."
        else
          current_node="$nxt"
        fi
        ;;
      *)
        ;;
    esac
  done
}

# ----------------------------
# Start
# ----------------------------
reset_game
scene_callout
