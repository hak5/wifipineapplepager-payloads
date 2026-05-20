#!/bin/bash
# Title: BluePine
# Author: cncartist
# Description: Bluepine - Bluetooth Device Detection & Hunting Suite. Detection Scanner, Jammer Locator, Target Probing, Last Target and Saved Targets List Management, Save / Load Saved Target List from File, Configuration Saving, GPS, Debugging, Privacy, Stealth, and more.  Full functionality tested on Pagers internal Bluetooth & USB CSR8510 / CSR v4.0 Bluetooth Adapter.  Without a USB CSR v4.0 Bluetooth Adapter there will be a slightly limited experience due to less signal/range, no jammer location capabilities, and inability to change the built in MAC.
# Category: reconnaissance
# Version: 1.4
# 
# ============================================
# Acknowledgements: 
# ============================================
# Find Hackers - Author: NULLFaceNoCase - (idea and concept for searching BT devices)
# Incident Response Forensic Collector - Author: curtthecoder - (logging example)
# Zombie UFO Theme - Author: Zombie Joe - (theme support & testing)
# toggle_ab_leds - https://github.com/jader242 - (stealth mode inspiration)
# https://www.rapidtables.com/code/text/ascii-table.html - (acsii verification for logo)
# https://github.com/judcrandall/lookout.py - (Axon OUI)
# Fuzz_Finder - Author: OSINTI4L - (Axon OUIs)
# https://github.com/aat440hz/CardSkimmerDetector-M5AtomS3LITE - (CC Skimmer Data)
# https://github.com/colonelpanichacks/flock-you - (Flock OUIs + Names)
# StamenScan - Author: FusedStamen - https://github.com/FusedStamen/StamenScan - (MAC filter idea)
# 
# ============================================
# Includes: 
# ============================================
#  -- Bluetooth Device Hunter (Classic + LE combined or separate):
#  -- -- -- Hunt via Scanning All, Single MAC, OUI prefix, and/or Name.
#  -- -- -- RSSI meter for each found signal, best signal showing at the bottom of the screen.
#  -- -- -- Custom configuration allowed and data builds over time in case name or manufacturer is missed on first scans.
#  -- -- -- Filters allowed, remove MAC addresses from scan that match Multicast/Random/Locally Administered.
#  -- -- -- Verbose logging / debugging available, GPS coordinate logging if GPS device enabled.
#  -- Bluetooth Device Detection: 
#  -- -- -- Axon / CC Skimmer / Flipper / Flock / Meshtastic / USB Kill / WiFi Pineapple BT Scanner.
#  -- -- -- Scan the airwaves, save targets, or scan your already saved target list from Device Hunter scans.
#  -- Bluetooth Jammer Detector & Locator: 
#  -- -- -- Detects & Locates Bluetooth Jammers/Interference Devices within close range.
#  -- -- -- USB Bluetooth Adapter Required to utilize the connection between internal and external Bluetooth.
#  -- -- -- The stronger the jammer/interference, the more easily it will be found.
#  -- -- -- Even a weak jammer can cause signal outages in devices, but it takes a very strong interference or being very close (at most 4-6 ft away from source) to interrupt the connection between the internal Bluetooth and external USB Bluetooth.
#  -- Target Probing:
#  -- -- -- Required to set a Target before accessing the Probe menu.
#  -- -- -- Set Target MAC, Hunt Target, Browse Services, Get Target Info, Get Target Vendor, Verify Target Connection.
#  -- -- -- All probe actions are passive with the exception of Verify Connection which will test connection but not send data/commands.
#  -- -- -- No activity/probing will happen on the target MAC until confirmed by the user flow.
#  -- -- -- When testing, it's normal for a secure device not accepting general connection/pairing requests to not respond to any of the Probing features.
#  -- -- -- In this suite, Get Target Vendor would be the only valid tool to lookup data related to a device MAC that's secured.
#  -- -- -- Custom OUI input needs to be a full MAC to pass the mac validator.
#  -- -- -- The last 3 octets will be removed keeping only the Custom OUI when entered.
#  -- Bluetooth Discoverable Setting Changer + Bluetooth Hardware Name Changer.
#  -- -- -- Can change both USB + Internal Settings.
#  -- Bluetooth MAC Address Changer for USB CSR8510 / CSR v4.0 Bluetooth Adapter.
#  -- -- -- Bluetooth MAC Address Changer will act on hci1 by default and has been tested to work on various CSR8510 Bluetooth Adapters (range from $5-10).  Can also permanently change Alias/Name for specific MAC as an option, or restore the old name before change.  Boot the pager first before plugging in USB BT Adapter to ensure it gets hci1 instead of hci0.
#  -- Last Target and Saved Targets list management.
#  -- -- -- Saved Targets list can be built over time, recommended to keep under a certain number and a warning will show when loading the payload with saved targets greater than the warn number.
#  -- -- -- You'll experience performance impacts loading the payload, viewing, or scanning Targets if the list is over the warn number.  It's been tested to over 6000 random MACs + Names without any crashes but takes minutes to load the list for display.
#  -- -- -- When adding Scan Targets to the Saved Target List, it will only report a new addition if the mac did not exist in the list prior.
#  -- -- -- All Scanned MACs/Names are stored in "Targets List", these are cleared automatically & lost when the payload is closed.
#  -- -- -- Saved MACs/Names that persist across app openings are stored in "Saved Targets List".
#  -- -- -- You can add Scanned Targets to the "Saved Targets List" directly after a scan, or in the "Manage Saved Targets" menu option.
#  -- Save / Load Saved Target List from file:
#  -- -- -- Saved Target List can be named for archiving, alphanumerical characters only.
#  -- Configuration saving / tracking number of scans and malicious items found over time:
#  -- -- -- Configuration backed up to "savedconfig.json" on exit.
#  -- -- -- If pager is updated/factory reset and config/history is wiped, configuration backup will restore settings.
#  -- Privacy / Streamer Mode:
#  -- -- -- (obscures MAC + Targets/Device Names) allows full functionality while obscuring ALL identifying information on screen, for both targets and self.
#  -- Friendly Mode:
#  -- -- -- Changes verbiage based on status, "target" -> "device", "hunt" -> "find"
#  -- Stealth Mode:
#  -- -- -- Sound Effects, LEDS, Payload LED Actions Disabled
#  -- Debug Mode:
#  -- -- -- A notification will show before each scan with debug enabled and extra log files saved for that process.
#  -- -- -- Saves full data stream for each Bluetooth scan at multiple points.  Please be aware these files can add up over time and it's best to clear them out or turn off debugging mode if not actively using them for debugging.
#  -- Dependencies / Ringtones:
#  -- -- -- evtest and GNU Grep are required dependencies, will install automatically if confirmed
#  -- -- -- Will check for ringtones at start and copy if confirmed
#  -- AArch64/ARM64/Debian Support
#  -- -- -- Tested on ClockworkPi (Trixie) & Hackberry (Kali) and should work on other Raspberry Pi based systems.
#  -- -- -- Support files are not included with the pager payload from the official repo, they can be found at: 
#  -- -- -- https://github.com/cncartistsec/BluePine-WiFi-Pineapple-Pager/tree/main/bt-bluepine/include
#  -- -- -- Required files in "include/aarch64" folder, desktop shortcut/icon included.
#  -- -- -- Included to convert DuckyScript commands utilized for usage on generic Debian/Bash terminals.
#  -- -- -- Loot/Reports are stored relative to the script directory, in the 'loot' folder.
# 
# ============================================
# Notes:
# ============================================
#  -- Device Hunter Scan: 
#  -- -- -- Long Press or Tap OK on Pager to pause/stop scanning (not tested with virtual pager buttons yet)
#  -- -- -- -- - Required when infinite scan is enabled (default)
#  -- -- -- -- - The pause/stop action is recorded but cannot be paused/stopped while BT scanning.
#  -- -- -- -- - It may take a couple seconds to process the pause/stop command.
#  -- -- -- -- - If you do not stop/finish the scan, targets are not saved and you are only viewing the scan details on the screen.
#  -- -- -- -- - It may pause instantly to as little as a few seconds, or the total time of "scanning/BLUE LED blinking" to pause/stop.
#  -- -- -- -- - This is to prevent stopping the actual bluetooth scans.
#  -- -- -- -- - Check for pause/stop is only done at certain points in the scanning process.
#  -- -- -- -- - You are able to pause, then continue scanning, or stop and add targets and/or return to main menu.
#  -- -- -- -- - Targets are not permanently saved until confirming to save them to Saved Targets.
#  -- -- -- -- - Best time to press pause/stop is after the final processing step/RED LED solid, before results are shown/MAGENTA LED solid.
#  -- -- -- Before each Scan, you can choose default/unchanged Scan settings, or Modify Scan settings.
#  -- -- -- -- - Pre-Scan Modify allows changing Scan duration and Scanning Classic + LE combined or separate.
#  -- -- -- -- - You would only choose one type if you knew which one has the BT device(s) you're searching for.
#  -- -- -- If locating a specific item, sometimes it's best to get multiple scans in close proximity to confirm the strength is accurate.
#  -- -- -- The best way to get used to the sensitivity is to scan for known devices and locate them within close range to see the sensitivity received.
#  -- -- -- There are many factors in Bluetooth sensitivity; walls & windows bounce or weaken signal, desks/objects can weaken signal, orientation of the pager can matter, and signals can look weak until you get closer to the actual source/Bluetooth chip on the target device. 
#  -- -- -- Using an external USB CSR8510 / CSR v4.0 Bluetooth Adapter, you can achieve better sensitivity and range.
#  -- -- -- Filters: 
#  -- -- -- -- - Filters act on the first Octet of a MAC (12:), or the MAC OUI/first 6 digits (12:34:56)
#  -- -- -- -- - Adding Filters allows faster processing, removes Targets from results, and helps if you know which MACs you are searching for.
#  -- -- -- -- - OUI: Empty OUI (00:00:00)
#  -- -- -- -- - Basic: Multicast (Group) 01 & Locally Administered (Unicast) 02
#  -- -- -- -- - Multi: ALL Multicast (01, 03, 05, 07, 09, 0B, 0D, 0F, 11-99 (odd), FF)
#  -- -- -- -- - Multi: ALL Locally Administered (x2, x6, xA, xE)
#  -- -- -- -- - Multi: ALL Random (x3, x7, xB, xF)
#  -- -- -- -- - WARNING: Filters REMOVE real devices from report/display and only applies to non-targeted scans!
#  -- Bluetooth Jammer Detector & Locator:
#  -- -- -- "Jam" counter resets every 25 "nojams" to clean out errors, and the "Found" counter will only count true confirmed jams in the area.
#  -- -- -- Confirmed jams are calculated at 5 jams per 25 scans.
#  -- -- -- A sequential jam is accounted for and more severe, meaning you are closer to the jammer/interference device.
#  -- -- -- This method may not work with certain Bluetooth dongles or setups and has only been confirmed to work with a USB CSR8510 / CSR v4.0 Bluetooth Adapter on the Pager.
#  -- Bluetooth: 
#  -- -- -- If you boot up the pager with USB bluetooth plugged in, it may reverse the hci addressing.
#  -- -- -- -- - Please boot the pager WITHOUT a USB device connected for hci0 to be addressed as the first default device.
#  -- -- -- How to verify your USB CSR8510 / CSR v4.0 Bluetooth Adapter is GENUINE
#  -- -- -- -- - Run: hciconfig hci1 -a
#  -- -- -- -- - Verify line output of -> HCI Version + LMP Version + Manufacturer
#  -- -- -- -- - Both GENUINE + FAKE/BAD Versions: # Manufacturer: Cambridge Silicon Radio (10)
#  -- -- -- -- - GENUINE: # HCI Version: 4.0 (0x6)  Revision: 0x22bb
#  -- -- -- -- - GENUINE: # LMP Version: 4.0 (0x6)  Subversion: 0x22bb
#  -- -- -- -- - FAKE/BAD: # HCI Version:  (0xe)  Revision: 0x201
#  -- -- -- -- - FAKE/BAD: # LMP Version:  (0xe)  Subversion: 0x201
#  -- -- -- -- - If you have no "Version: 4.0" in your details, the adapter will not work efficiently and is not a genuine CSR v4.0.
#  -- Debug / Logging:
#  -- -- -- Includes GPS coordinate logging if GPS device enabled.
#  -- -- -- -- - When GPS device enabled, Device Hunter Scan will show 'NoGPS' or '+GPS+' depending on GPS status.
#  -- -- -- With debug enabled, log files will add up quickly over time in filesize.
#  -- -- -- -- - Please take care to only debug when needed; it keeps full BT scan LOG files which take significant space.
#  -- Menu Display / Smaller Font Size for List Picker:
#  -- -- -- changed text_size to small and max_chars to 38/40
#  -- -- -- "text_size": "small"  &  "max_chars": 38  &  "max_chars": 40
#  -- -- -- updated theme in /mmc/root/themes/THEME/components/templates
#  -- -- -- -- - option_dialog_string.json  ( "max_chars": 38 )
#  -- -- -- -- - option_dialog_string_selected.json  ( "max_chars": 40 )
# 
# ============================================
#       LOGGING STRUCTURE / DATA FILES
# ============================================
# Main Loot Folder: "/root/loot/csec/bt-bluepine"
# Detection Reports & Logs: "/root/loot/csec/bt-bluepine/detect"
# Probe Reports & Logs: "/root/loot/csec/bt-bluepine/probe"
# Scan Reports & Logs: "/root/loot/csec/bt-bluepine/scan"
# Targets Data: "/root/loot/csec/bt-bluepine/targets"
# 
# Saved Targets File: "/root/loot/csec/bt-bluepine/targets/SavedTargets.txt"
# Last Target File (MAC only): "/root/loot/csec/bt-bluepine/targets/LastTarget.txt"
# 
# NOTE: AArch64/ARM64/Debian - Loot/Reports are stored relative to the script directory, in the 'loot' folder.
# ============================================
#             SCAN LED STATUS
# ============================================
#             ------ start ------
# GREEN:            Configuration
# MAGENTA:          IDLE
#             ------ scanning ------
# WHITE:            Resetting adapter
# BLUE SLOW blink:  Scanning Bluetooth Classic
# CYAN SLOW blink:  Scanning Bluetooth LE
# WHITE:            Finished scans
# BLUE:             Cleanup / pre-processing
# GREEN:            Build result file for processing
# YELLOW:           String manipulation of result file
# RED:              Final looping results for display
# MAGENTA:          Finished processing
#             ------ scanning ------
# ============================================
#             RINGTONEs used
# ============================================
# flutter       PAYLOAD LOADED
# glitchHack    SCAN READY
# Achievement   SCAN FOUND ITEMS
# sideBeam      SCAN FOUND NONE
# warning       DETECT FOUND ITEMS
# ScaleTrill    DETECT FOUND NONE
# ============================================
#            Version History
# ============================================
# v1.4 -- AArch64/ARM64/Debian Support
# v1.3 -- Filtering Options + Scantime Tracking
# v1.2 -- GPS Updates + Bug Fixes
# v1.1 -- Configuration Saving + Added Functionality
# v1.0 -- Initial Release
# ============================================
#          Future improvements
# ============================================
# build log viewer in?
# change actual sound setting for system/alerts?
# implement sql lite db instead of current method?
# add node support for other data source?
# add more detections/detection based on UUID?
# ============================================
# 

# Check architecture
archCur="pager"
architecture_check() {
	local arch=$(uname -m)
    case "$arch" in
        "mips") archCur="pager" ;;
        "aarch64") archCur="aarch64" ;;
        *) archCur="unknown" ;;
    esac
}
architecture_check

# set architecture defaults
servicebt_cur="bluetoothd"
if [[ "$archCur" == "pager" ]] ; then
	LOOT_DIR="/root/loot/csec/bt-bluepine"
else
	# AArch64/ARM64/Debian Support
	# Files are not included with the pager payload, they can be found at: 
	# https://github.com/cncartistsec/BluePine-WiFi-Pineapple-Pager/tree/main/bt-bluepine/include
	# if not running on the pager, check if script is running as root
	if [[ $EUID -ne 0 ]] ; then
		NC='\033[0m'
		colorcode='\033[1;91m' # red
		echo -e "${colorcode}===================== ERROR =====================${NC}"
		echo "This script must be run as root."
		echo -e "${colorcode}=================================================${NC}"
		echo "BluePine is originally built for the Hak5 WiFi Pineapple Pager and all scripts are run as root on that device."
		echo "Please feel free to inspect the code and be assured everything is run locally/relative to the base of 'payload.sh'."
		echo -e "${colorcode}=================================================${NC}"
		exit 1
	fi
	LOOT_DIR="./loot"
	servicebt_cur="bluetooth"
	source "./include/aarch64/funcs_duck.sh" # load funcs
fi

# Include the function files   # or #        . "./file1.sh"
source "./include/funcs_main.sh"
source "./include/funcs_menu.sh"
source "./include/funcs_scan.sh"
# source "./include/funcs_extl.sh"

# ---- CONFIG ----
LOOT_SCAN="${LOOT_DIR}/scan"; LOOT_DETECT="${LOOT_DIR}/detect"; LOOT_PROBE="${LOOT_DIR}/probe"; LOOT_TARGETS="${LOOT_DIR}/targets"; LOOT_CONFIG="${LOOT_DIR}/config"
mkdir -p "$LOOT_DIR"; mkdir -p "$LOOT_SCAN"; mkdir -p "$LOOT_DETECT"; mkdir -p "$LOOT_PROBE"; mkdir -p "$LOOT_TARGETS"; mkdir -p "$LOOT_CONFIG"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
REPORT_FILE="$LOOT_SCAN/Report_${TIMESTAMP}.txt"
REPORT_DETECT_FILE="$LOOT_DETECT/Report_${TIMESTAMP}.txt"
REPORT_DETJAM_FILE="$LOOT_DETECT/Report_Jam_${TIMESTAMP}.txt"
REPORT_PROBE_FILE="$LOOT_PROBE/Report_${TIMESTAMP}.txt"
DATASTREAMBT_FILE="$LOOT_SCAN/${TIMESTAMP}_DataBT.txt"
DATASTREAMBT2_FILE="$LOOT_SCAN/${TIMESTAMP}_DataBT2.txt"
DATASTREAMBT3_FILE="$LOOT_SCAN/${TIMESTAMP}_DataBT3.txt"
DATASTREAMBTTMP_FILE="$LOOT_SCAN/${TIMESTAMP}_DataBTTMP.txt"
DATASTREAMBTLE_FILE="$LOOT_DETECT/DataBTLE_${TIMESTAMP}.txt"
DATASTREAMBTLETMP_FILE="$LOOT_DETECT/DataBTLETMP_${TIMESTAMP}.txt"
SAVEDTARGETS_FILE="$LOOT_TARGETS/SavedTargets.txt"
TARGETMAC_FILE="$LOOT_CONFIG/LastTarget.txt"
SAVEDCONFIG_FILE="$LOOT_CONFIG/savedconfig.json"
KEYCKTMP_FILE="$LOOT_DIR/KeyCKTMP.txt"
if [[ "$archCur" != "pager" ]] ; then
	# need to be in root group to delete loot files from FTP on other arch
	# RUN THIS to add to root group -> usermod -aG root <yourusername>
	chmod -R 775 "$LOOT_DIR" # auto set loot dir to allow ftp edits if user in root group
fi

# ---- DEFAULTS ----
scan_default="false"
scan_targeted="false"
scan_custom=0
target_mac=""
enable_CSR_func=0
saved_target_select=0
saved_target_remove=0
saved_target_rename=0
cancel_press=0
cancel_app=0
selnum=0
select_target_go=0
silent_backup=0
detections=0
lootreports=0
hold_scan_btle=""
hold_scan_btclassic=""
view_extl=0
rssitxt_switch="rssitxtsw_hci0"
priv_name_save=""
priv_mac_save=""
priv_name_txt="-+ Name Hidden +-"
priv_mac_num="12:34:56:78:90:AB"
priv_mac_txt="░░:░░:░░:░░:░░:░░"
scan_BT_AXONCAMS="false"
scan_BT_CCSKIMMR="false"
scan_BT_FLIPPERS="false"
scan_BT_FLOCKCAM="false"
scan_BT_MESHTAST="false"
scan_BT_USBKILLS="false"
scan_BT_PINEAPPS="false"
# scan_BT_APLAIRTG="false"
savedTargWarn=1000
savedTargCrit=3000
gpspos_last=""
text_hunt_UC="Find"
text_hunt_LC="find"
text_target_UC="Device"
text_target_LC="device"
# ---- DEFAULTS ----
# ---- DEFAULTS SAVED CFG ----
total_scans=0
total_detected=0
total_scan_min=0
scan_privacy=0
scan_friendly=0
scan_stealth=0
scan_btle="true"
scan_btclassic="true"
scan_infrepeat=1
scan_mute="false"
scan_debug="false"
custom_oui=""
custom_name=""
selnum_main=1
skip_ask_1st_scan=0
skip_ask_ringtones=0
filter_multilocal=0
filter_randomall=0
filter_localall=0
filter_multiall=0
filter_emptyoui=0
# number in seconds
DATA_SCAN_SECONDS=7
# ---- DEFAULTS SAVED CFG ----

# ---- ARRAYS ----
declare -A BT_RSSIS
declare -A BT_NAMES
declare -A BT_COMPS
declare -A BT_TARGETS
declare -A BT_TARGETS_SORT
declare -A BT_TARGETS_SAVED
declare -A BT_AXONCAMS
declare -A BT_CCSKIMMR
declare -A BT_FLIPPERS
declare -A BT_FLOCKCAM
declare -A BT_MESHTAST
declare -A BT_USBKILLS
declare -A BT_PINEAPPS
declare -A BT_CUSTOMOU
# declare -A BT_APLAIRTG
# ---- ARRAYS ----

# ---- BLE ----
BLE_IFACE="hci0"

# ---- REGEX ----
VALID_MAC="([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"

cleanup() {
    killall hcitool 2>/dev/null
	killall btmon 2>/dev/null
	if [[ "$archCur" == "pager" ]] ; then
		killall evtest 2>/dev/null
		btn_a_path="/sys/devices/platform/leds/leds/a-button-led/brightness"
		btn_b_path="/sys/devices/platform/leds/leds/b-button-led/brightness"
		echo 1 > "$btn_a_path" 2>/dev/null
		echo 1 > "$btn_b_path" 2>/dev/null
	fi
	rm "$DATASTREAMBT_FILE" 2>/dev/null
	rm "$DATASTREAMBT2_FILE" 2>/dev/null
	rm "$DATASTREAMBT3_FILE" 2>/dev/null
	rm "$DATASTREAMBTTMP_FILE" 2>/dev/null
	rm "$KEYCKTMP_FILE" 2>/dev/null
	silent_backup=1
	config_backup
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM SIGHUP

bluepinelogo() {
	LOG cyan   "¨ ██████╗ ██╗ ¨ ¨ ██╗ ¨ ██╗███████╗¨ ¨ ^x^ . x^ "
	LOG cyan   "¨ ██╔══██╗██║ ¨ ¨ ██║ ¨ ██║██╔════╝ ^x.:;\,:/_.x^"
	LOG cyan   "¨ ██████╔╝██║ ¨ ¨ ██║ ¨ ██║█████╗ ¨ ¨ ,\-:.\;/. "
	LOG cyan   "¨ ██╔══██╗██║ ¨ ¨ ██║ ¨ ██║██╔══╝ ¨ ¨-\.,.|./,/x>"
	LOG cyan   "¨ ██████╔╝███████╗╚██████╔╝███████╗¨ ¨ (-_v_-) "
	LOG cyan   "¨ ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝ ¨ (/-\_/-\) "
	LOG cyan   "¨¨ ██████╗ ██╗ ███╗ ¨ ██╗ ███████╗ ¨ (_\-/-\-/_) "
	LOG cyan   "¨¨ ██╔══██╗██║ ████╗¨ ██║ ██╔════╝¨ (\_/-\_/-\_|)"
	LOG cyan   "¨¨ ██████╔╝██║ ██╔██╗ ██║ █████╗ ¨¨ (/-\_/-\_/-\)"
	LOG cyan   "¨¨ ██╔═══╝ ██║ ██║╚██╗██║ ██╔══╝ ¨¨ (\_/-\_/-\_|)"
	LOG cyan   "¨¨ ██║ ¨ ¨ ██║ ██║ ╚████║ ███████╗¨ (/-\_/-\_/-\)"
	LOG cyan   "¨¨ ╚═╝ ¨ ¨ ╚═╝ ╚═╝¨ ╚═══╝ ╚══════╝ ¨ (\_\\\_//_/) "
}

#  SET CFG OPTIONS
# PAYLOAD_GET_CONFIG - Retrieve a permanent payload configuration option
	# PAYLOAD_GET_CONFIG [payload name] [option]
# PAYLOAD_SET_CONFIG - Set a permanent payload configuration option
	# PAYLOAD_SET_CONFIG [payload name] [option] [value]
# PAYLOAD_DEL_CONFIG - Delete a permanent payload configuration option
	# PAYLOAD_DEL_CONFIG [payload name] [option]

# load config and check if empty, if so reset to default
DATA_SCAN_SECONDS=$(PAYLOAD_GET_CONFIG bluepinesuite DATA_SCAN_SECONDS)
scan_btle=$(PAYLOAD_GET_CONFIG bluepinesuite scan_btle)
scan_btclassic=$(PAYLOAD_GET_CONFIG bluepinesuite scan_btclassic)
scan_infrepeat=$(PAYLOAD_GET_CONFIG bluepinesuite scan_infrepeat)
scan_mute=$(PAYLOAD_GET_CONFIG bluepinesuite scan_mute)
scan_debug=$(PAYLOAD_GET_CONFIG bluepinesuite scan_debug)
total_scans=$(PAYLOAD_GET_CONFIG bluepinesuite total_scans)
total_detected=$(PAYLOAD_GET_CONFIG bluepinesuite total_detected)
total_scan_min=$(PAYLOAD_GET_CONFIG bluepinesuite total_scan_min)
scan_privacy=$(PAYLOAD_GET_CONFIG bluepinesuite scan_privacy)
scan_friendly=$(PAYLOAD_GET_CONFIG bluepinesuite scan_friendly)
scan_stealth=$(PAYLOAD_GET_CONFIG bluepinesuite scan_stealth)
custom_oui=$(PAYLOAD_GET_CONFIG bluepinesuite custom_oui)
custom_name=$(PAYLOAD_GET_CONFIG bluepinesuite custom_name)
selnum_main=$(PAYLOAD_GET_CONFIG bluepinesuite selnum_main)
skip_ask_1st_scan=$(PAYLOAD_GET_CONFIG bluepinesuite skip_ask_1st_scan)
skip_ask_ringtones=$(PAYLOAD_GET_CONFIG bluepinesuite skip_ask_ringtones)
filter_multilocal=$(PAYLOAD_GET_CONFIG bluepinesuite filter_multilocal)
filter_randomall=$(PAYLOAD_GET_CONFIG bluepinesuite filter_randomall)
filter_localall=$(PAYLOAD_GET_CONFIG bluepinesuite filter_localall)
filter_multiall=$(PAYLOAD_GET_CONFIG bluepinesuite filter_multiall)
filter_emptyoui=$(PAYLOAD_GET_CONFIG bluepinesuite filter_emptyoui)

[[ -z "$DATA_SCAN_SECONDS" ]] && DATA_SCAN_SECONDS=7
[[ -z "$scan_btle" ]] && scan_btle="true"
[[ -z "$scan_btclassic" ]] && scan_btclassic="true"
[[ -z "$scan_infrepeat" ]] && scan_infrepeat=1
[[ -z "$scan_mute" ]] && scan_mute="false"
[[ -z "$scan_debug" ]] && scan_debug="false"
[[ -z "$total_scans" ]] && total_scans=0
[[ -z "$total_detected" ]] && total_detected=0
[[ -z "$total_scan_min" ]] && total_scan_min=0
[[ -z "$scan_privacy" ]] && scan_privacy=0
[[ -z "$scan_friendly" ]] && scan_friendly=0
[[ -z "$scan_stealth" ]] && scan_stealth=0
[[ -z "$custom_oui" ]] && custom_oui=""
[[ -z "$custom_name" ]] && custom_name=""
[[ -z "$selnum_main" ]] && selnum_main=1
[[ -z "$skip_ask_1st_scan" ]] && skip_ask_1st_scan=0
[[ -z "$skip_ask_ringtones" ]] && skip_ask_ringtones=0
[[ -z "$filter_multilocal" ]] && filter_multilocal=0
[[ -z "$filter_randomall" ]] && filter_randomall=0
[[ -z "$filter_localall" ]] && filter_localall=0
[[ -z "$filter_multiall" ]] && filter_multiall=0
[[ -z "$filter_emptyoui" ]] && filter_emptyoui=0

# check dependencies + ringtones
check_dependencies
if [[ "$skip_ask_ringtones" -eq 0 && "$archCur" == "pager" ]] ; then check_ringtones; fi
# check config value versus found
config_check
# check settings
settings_check

# kill evtest if still running and rm old key file
if [[ "$archCur" == "pager" ]] ; then
	(killall evtest 2>/dev/null) &
fi
rm "$KEYCKTMP_FILE" 2>/dev/null

# check if file is not empty this time around
if [[ -s "$TARGETMAC_FILE" ]]; then
	# target_mac_check=$(<"$TARGETMAC_FILE")
	# read out first line of file only to var
	IFS= read -r target_mac_check < "$TARGETMAC_FILE"
	target_mac=$(echo "${target_mac_check}" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
fi

# warn of global settings enabled
if [[ "$scan_friendly" -eq 1 ]] || [[ "$scan_privacy" -eq 1 ]] || [[ "$scan_stealth" -eq 1 ]] ; then
	LOG blue "================================================="
	if [[ "$scan_stealth" -eq 1 ]] ; then
		LOG blue "============ Stealth Mode Enabled... ============"
	fi
	if [[ "$scan_privacy" -eq 1 ]] ; then
		LOG blue "============ Privacy Mode Enabled... ============"
	fi
	if [[ "$scan_friendly" -eq 1 ]] ; then
		LOG blue "== (: (: (: Friendly Mode Enabled... :) :) :) ==="
	fi
	LOG blue "================================================="
	sleep 1
fi

# reset gpsd in background
(reset_gpsd) &
# verify bluetoothd running at start
bluetoothd_check
# run saved targets check/load
saved_targets_check

# start logo and display
LOG blue   "|||||||||||||||||||||||||||||||||||||¨¨¨¨¨¨¨¨¨¨¨¨¨"
sleep 1
bluepinelogo
if [[ "$scan_mute" == "false" ]] ; then
	RINGTONE "flutter" # (short)
fi
sleep 0.5
LOG cyan   "||||||| - Press OK to Start - ||||||| ^^^^^^^^^ ||"
# LOG blue   "░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"
# LOG blue   "||||||||||||||||||||||||||||||||||||||||||||||||||"
WAIT_FOR_BUTTON_PRESS A
sleep 0.5

# External Bluetooth Adapter?
external_bt_check

while true; do
	scan_custom=0
	main_menu
	main_option="$selnum"
	if [[ "$main_option" -eq 1 ]]; then
		LOG "Running Scan Program...."
		scan_targeted="false"
		device_hunter
	elif [[ "$main_option" -eq 2 ]]; then
		while true; do
			scan_BT_AXONCAMS="false"
			scan_BT_CCSKIMMR="false"
			scan_BT_FLIPPERS="false"
			scan_BT_FLOCKCAM="false"
			scan_BT_MESHTAST="false"
			scan_BT_USBKILLS="false"
			scan_BT_PINEAPPS="false"
			scan_custom=0
			LOG "Detection...."
			sub_menu_detection
			submenu_option="$selnum"
			if [[ "$submenu_option" -eq 0 ]]; then
				LOG "Back to Main Menu...."
				break
			elif [[ "$submenu_option" -eq 1 ]]; then
				LOG "Running All Detections...."
				scan_BT_AXONCAMS="true"
				scan_BT_CCSKIMMR="true"
				scan_BT_FLIPPERS="true"
				scan_BT_FLOCKCAM="true"
				scan_BT_MESHTAST="true"
				scan_BT_USBKILLS="true"
				scan_BT_PINEAPPS="true"
				scan_detection
			elif [[ "$submenu_option" -eq 2 ]]; then
				LOG "Running Detect ALL - Scanned/Saved ${text_target_UC}s...."
				scan_BT_AXONCAMS="true"
				scan_BT_CCSKIMMR="true"
				scan_BT_FLIPPERS="true"
				scan_BT_FLOCKCAM="true"
				scan_BT_MESHTAST="true"
				scan_BT_USBKILLS="true"
				scan_BT_PINEAPPS="true"
				scan_detect_from_scanned
			elif [[ "$submenu_option" -eq 3 ]]; then
				LOG "Detect Custom OUI/Name - Scanned/Saved ${text_target_UC}s...."
				enter_custom_oui
				enter_custom_name
				if [[ -n "$custom_oui" ]] || [[ -n "$custom_name" ]] ; then
					scan_custom=1
					scan_detect_from_scanned
				else
					LOG "Custom OUI/Name not set..."
					LOG " "
				fi
			elif [[ "$submenu_option" -eq 4 ]]; then
				LOG "Running Axon Detection...."
				scan_BT_AXONCAMS="true"
				scan_detection
			elif [[ "$submenu_option" -eq 5 ]]; then
				LOG "Running CC Skimmer Detection...."
				scan_BT_CCSKIMMR="true"
				scan_detection
			elif [[ "$submenu_option" -eq 6 ]]; then
				LOG "Running Flipper Detection...."
				scan_BT_FLIPPERS="true"
				scan_detection
			elif [[ "$submenu_option" -eq 7 ]]; then
				LOG "Running Flock Detection...."
				scan_BT_FLOCKCAM="true"
				scan_detection
			elif [[ "$submenu_option" -eq 8 ]]; then
				LOG "Running Meshtastic Detection...."
				scan_BT_MESHTAST="true"
				scan_detection
			elif [[ "$submenu_option" -eq 9 ]]; then
				LOG "Running USB Kill Detection...."
				scan_BT_USBKILLS="true"
				scan_detection
			elif [[ "$submenu_option" -eq 10 ]]; then
				LOG "Running WiFi Pineapple Detection...."
				scan_BT_PINEAPPS="true"
				scan_detection
			fi
		done
	elif [[ "$main_option" -eq 3 ]]; then
		LOG "Jammer Detector...."
		detect_jammers
	elif [[ "$main_option" -eq 4 ]]; then
		LOG "View ${text_target_UC}s / Select ${text_target_UC}...."
		select_target
	elif [[ "$main_option" -eq 5 ]]; then
		while true; do
			LOG "Probe...."
			sub_menu_probe
			submenu_option="$selnum"
			if [[ "$submenu_option" -eq 0 ]]; then
				LOG "Back to Main Menu...."
				break
			elif [[ "$submenu_option" -eq 1 ]]; then
				LOG "${text_hunt_UC} ${text_target_UC}...."
				scan_targeted="true"
				device_hunter
			elif [[ "$submenu_option" -eq 2 ]]; then
				LOG "Browse Services...."
				bt_browse_services
			elif [[ "$submenu_option" -eq 3 ]]; then
				LOG "Get Device Info...."
				bt_get_info
			elif [[ "$submenu_option" -eq 4 ]]; then
				LOG "Get Device Vendor...."
				bt_get_vendor
			elif [[ "$submenu_option" -eq 5 ]]; then
				LOG "Verify ${text_target_UC} Connection...."
				bt_verif_conn
			elif [[ "$submenu_option" -eq 6 ]]; then
				sub_items_extl
			fi
		done 
	elif [[ "$main_option" -eq 6 ]]; then
		LOG "${text_hunt_UC} Custom OUI/Name...."
		enter_custom_oui
		enter_custom_name
		if [[ -n "$custom_oui" || -n "$custom_name" ]] ; then
			scan_custom=1
			device_hunter
		else
			LOG "Custom OUI/Name not set..."
			LOG " "
		fi
	elif [[ "$main_option" -eq 7 ]]; then
		while true; do
			saved_target_select=0
			saved_target_remove=0
			saved_target_rename=0
			LOG "Manage Saved ${text_target_UC}s...."
			sub_menu_savedtargoptions
			submenu_option="$selnum"
			if [[ "$submenu_option" -eq 0 ]]; then
				LOG "Back to Main Menu...."
				break
			elif [[ "$submenu_option" -eq 1 ]]; then
				LOG "View Saved ${text_target_UC}s...."
				saved_targets_list
			elif [[ "$submenu_option" -eq 2 ]]; then
				LOG "Save Current ${text_target_UC}...."
				saved_targets_savecurrent
			elif [[ "$submenu_option" -eq 3 ]]; then
				LOG "Set ${text_target_UC} MAC...."
				resp=$(CONFIRMATION_DIALOG "Confirm entering new ${text_target_UC} MAC?")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					target_mac_old="$target_mac"
					if [[ "$scan_privacy" -eq 1 ]] ; then target_mac_old="$priv_mac_num"; fi
					while true; do
						# run input
						target_mac=$(MAC_PICKER "${text_target_UC} MAC" "$target_mac_old")
						# Confirm Random MAC sufficient
						if [[ "$target_mac" =~ $VALID_MAC ]]; then
							resp=$(CONFIRMATION_DIALOG "This ${text_target_UC} MAC OK? ${target_mac}")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								break
							fi
							LOG red "Skipping MAC: ${target_mac}, input new..."
						else 
							LOG red "Invalid MAC: ${target_mac}, input new..."
						fi
						sleep 1
					done
					echo "$target_mac" > "$TARGETMAC_FILE"
					LOG blue "================================================="
					LOG green "${text_target_UC} MAC: ${target_mac}"
					LOG blue "================================================="
				fi
			elif [[ "$submenu_option" -eq 4 ]]; then
				LOG "Clear Current ${text_target_UC}...."
				current_target_clear
			elif [[ "$submenu_option" -eq 5 ]]; then
				LOG "Select from Saved ${text_target_UC}s...."
				saved_target_select=1
				saved_targets_list
			elif [[ "$submenu_option" -eq 6 ]]; then
				LOG "Save ALL Scan ${text_target_UC}s...."
				saved_targets_saveall
			elif [[ "$submenu_option" -eq 7 ]]; then
				LOG "Save / Load Saved ${text_target_UC}s File...."
				saved_targets_saveload
			elif [[ "$submenu_option" -eq 8 ]]; then
				LOG "Rename / Remove Saved ${text_target_UC}...."
				saved_target_rename=1
				saved_target_remove=1
				saved_targets_list
			elif [[ "$submenu_option" -eq 9 ]]; then
				LOG "Remove Saved ${text_target_UC}s by Custom OUI/Name...."
				enter_custom_oui
				enter_custom_name
				if [[ -n "$custom_oui" || -n "$custom_name" ]] ; then
					saved_target_remove_custom
				else
					LOG "Custom OUI/Name not set..."
					LOG " "
				fi
			elif [[ "$submenu_option" -eq 10 ]]; then
				LOG "Clear Saved ${text_target_UC}s...."
				saved_targets_clear
			fi
		done
	elif [[ "$main_option" -eq 8 ]]; then
		while true; do
			LOG "Preferences...."
			sub_menu_preferences
			submenu_option="$selnum"
			if [[ "$submenu_option" -eq 0 ]]; then
				LOG "Back to Main Menu...."
				break
			elif [[ "$submenu_option" -eq 1 ]]; then
				LOG "Global Settings Config...."
				global_config
			elif [[ "$submenu_option" -eq 2 ]]; then
				while true; do
					LOG "Manage Bluetooth...."
					sub_sub_menu_managebt
					submenu_option="$selnum"
					if [[ "$submenu_option" -eq 0 ]]; then
						LOG "Back to Preferences...."
						break
					elif [[ "$submenu_option" -eq 1 ]]; then
						LOG "Change Bluetooth Name...."
						if hciconfig | grep -q hci0; then
							resp=$(CONFIRMATION_DIALOG "Modify hci0 Bluetooth Name?")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								update_bluetooth_name "hci0"
							else 
								LOG "Change Name skipped for hci0..."
							fi
						fi
						if hciconfig | grep -q hci1; then
							resp=$(CONFIRMATION_DIALOG "Modify hci1 Bluetooth Name?")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								update_bluetooth_name "hci1"
							else 
								LOG "Change Name skipped for hci1..."
							fi
						fi
					elif [[ "$submenu_option" -eq 2 ]]; then
						LOG "Change Bluetooth MAC / Alias...."
						if [[ "$archCur" == "pager" ]] ; then
							if hciconfig | grep -q hci1; then
								if [[ "$enable_CSR_func" -eq 0 ]]; then
									LOG red "WARNING: USB CSR BT not detected!"
									LOG red "WARNING: Changing MAC on USB BT may not work!"
								fi
								update_bluetooth_mac "hci1"
							else
								LOG red "Bluetooth MAC cannot be changed for hci0!"
							fi
						else
							LOG red "WARNING: Changing MAC may not work if hardware does not support it!"
							update_bluetooth_mac "hci0"
							if hciconfig | grep -q hci1; then
								update_bluetooth_mac "hci1"
							fi
						fi
					elif [[ "$submenu_option" -eq 3 ]]; then
						LOG "Change Bluetooth Status / Discovery Setting...."
						if hciconfig | grep -q hci0; then
							resp=$(CONFIRMATION_DIALOG "Modify hci0 Status/Discovery Setting?")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								update_bluetooth_status "hci0"
							else 
								LOG "Change Status/Discovery Setting skipped for hci0..."
							fi
						fi
						if hciconfig | grep -q hci1; then
							resp=$(CONFIRMATION_DIALOG "Modify hci1 Status/Discovery Setting?")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								update_bluetooth_status "hci1"
							else 
								LOG "Change Status/Discovery Setting skipped for hci1..."
							fi
						fi
					elif [[ "$submenu_option" -eq 4 ]]; then
						LOG "Retest USB Bluetooth for CSR...."
						external_bt_check
					fi
				done
				submenu_option=0
			elif [[ "$submenu_option" -eq 3 ]]; then
				LOG "Sound...."
				mute_config
			elif [[ "$submenu_option" -eq 4 ]]; then
				LOG "Debug Mode...."
				debug_config
			elif [[ "$submenu_option" -eq 5 ]]; then
				LOG "Stealth Mode / Disable LEDS...."
				stealth_config
			elif [[ "$submenu_option" -eq 6 ]]; then
				LOG "Device ${text_hunt_UC}er Scan Filter Config...."
				filter_config
				LOG " "
			elif [[ "$submenu_option" -eq 7 ]]; then
				LOG "Clear History / Data / Settings...."
				resp=$(CONFIRMATION_DIALOG "Do you want to CLEAR ALL History / Scan Counts? ")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					sleep 1
					resp=$(CONFIRMATION_DIALOG "CONFIRM CLEAR ALL History / Scan Counts? - THIS ACTION CANNOT BE REVERSED!")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						PAYLOAD_DEL_CONFIG bluepinesuite total_scans
						PAYLOAD_DEL_CONFIG bluepinesuite total_detected
						PAYLOAD_DEL_CONFIG bluepinesuite total_scan_min
						total_scans=0; total_detected=0; total_scan_min=0
						LOG green "Total Scans + Detected cleared!"				
						LOG "Press OK to continue..."
						LOG " "
						WAIT_FOR_BUTTON_PRESS A
						sleep 0.25
					fi
				fi
				resp=$(CONFIRMATION_DIALOG "Do you want to CLEAR ALL ${text_target_UC}s / Saved ${text_target_UC}s? ")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					sleep 1
					resp=$(CONFIRMATION_DIALOG "CONFIRM CLEAR ALL ${text_target_UC}s / Saved ${text_target_UC}? - THIS ACTION CANNOT BE REVERSED!")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						BT_RSSIS=()
						BT_NAMES=()
						BT_COMPS=()
						BT_FLIPPERS=()
						BT_USBKILLS=()
						BT_PINEAPPS=()
						BT_TARGETS=()
						LOG "ALL Scan ${text_target_UC}s cleared!"
						rm "$SAVEDTARGETS_FILE" 2>/dev/null
						saved_targets_check
						LOG "ALL Saved ${text_target_UC}s cleared!"
						target_mac=""
						echo "$target_mac" > "$TARGETMAC_FILE"
						LOG "${text_target_UC} MAC cleared!"
						LOG green "All ${text_target_UC}s / Saved ${text_target_UC}s cleared..."
						LOG "Press OK to continue..."
						LOG " "
						WAIT_FOR_BUTTON_PRESS A
						sleep 0.25
					fi
				fi
				resp=$(CONFIRMATION_DIALOG "Do you want to Reset Configuration to Default? ")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					sleep 1
					resp=$(CONFIRMATION_DIALOG "CONFIRM Reset Configuration to Default? - THIS ACTION CANNOT BE REVERSED!")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						LOG "Resetting configuration..."
						# defaults from above
						scan_btle="true"
						scan_btclassic="true"
						scan_infrepeat=1
						scan_mute="false"
						scan_debug="false"
						scan_targeted="false"
						scan_privacy=0
						scan_friendly=0
						scan_stealth=0
						skip_ask_1st_scan=0
						skip_ask_ringtones=0
						filter_multilocal=0
						filter_randomall=0
						filter_localall=0
						filter_multiall=0
						filter_emptyoui=0
						DATA_SCAN_SECONDS=7
						custom_oui=""
						custom_name=""
						LED MAGENTA
						if [[ "$archCur" == "pager" ]] ; then
							btn_a_path="/sys/devices/platform/leds/leds/a-button-led/brightness"
							btn_b_path="/sys/devices/platform/leds/leds/b-button-led/brightness"
							btn_a_state=$(cat "$btn_a_path")
							btn_b_state=$(cat "$btn_b_path")
							if [ "$btn_a_state" -eq 0 ] || [ "$btn_b_state" -eq 0 ] ; then
								echo 1 > "$btn_a_path"
								echo 1 > "$btn_b_path"
								# LOG "A + B Button LEDS restored..."
							fi
						fi
						# save config
						PAYLOAD_SET_CONFIG bluepinesuite DATA_SCAN_SECONDS "$DATA_SCAN_SECONDS"
						PAYLOAD_SET_CONFIG bluepinesuite scan_btle "$scan_btle"
						PAYLOAD_SET_CONFIG bluepinesuite scan_btclassic "$scan_btclassic"
						PAYLOAD_SET_CONFIG bluepinesuite scan_infrepeat "$scan_infrepeat"
						PAYLOAD_SET_CONFIG bluepinesuite scan_mute "$scan_mute"
						PAYLOAD_SET_CONFIG bluepinesuite scan_debug "$scan_debug"
						PAYLOAD_SET_CONFIG bluepinesuite scan_privacy "$scan_privacy"
						PAYLOAD_SET_CONFIG bluepinesuite scan_friendly "$scan_friendly"
						PAYLOAD_SET_CONFIG bluepinesuite scan_stealth "$scan_stealth"
						PAYLOAD_SET_CONFIG bluepinesuite skip_ask_1st_scan "$skip_ask_1st_scan"
						PAYLOAD_SET_CONFIG bluepinesuite skip_ask_ringtones "$skip_ask_ringtones"
						PAYLOAD_SET_CONFIG bluepinesuite filter_multilocal "$filter_multilocal"
						PAYLOAD_SET_CONFIG bluepinesuite filter_randomall "$filter_randomall"
						PAYLOAD_SET_CONFIG bluepinesuite filter_localall "$filter_localall"
						PAYLOAD_SET_CONFIG bluepinesuite filter_multiall "$filter_multiall"
						PAYLOAD_SET_CONFIG bluepinesuite filter_emptyoui "$filter_emptyoui"
						PAYLOAD_SET_CONFIG bluepinesuite custom_oui "$custom_oui"
						PAYLOAD_SET_CONFIG bluepinesuite custom_name "$custom_name"
						LOG "Settings saved..."
						# defaults from above
						LOG green "Configuration reset!"
						LOG "Press OK to continue..."
						LOG " "
						WAIT_FOR_BUTTON_PRESS A
						sleep 0.25
					fi
				fi
				resp=$(CONFIRMATION_DIALOG "Do you want to CLEAR ALL Report + Log Files? ")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					lootreports=$(find "$LOOT_SCAN" "$LOOT_DETECT" "$LOOT_PROBE" -maxdepth 1 -type f -name "Report*" -print | wc -l)
					lootdetects=$(find "$LOOT_DETECT" -maxdepth 1 -type f -name "DetectTargets*" -print | wc -l)
					lootreports=$((lootreports + lootdetects))
					sleep 1
					LOG cyan "$lootreports Report Files Found..."	
					LOG "Debug/Log Files are not counted..."			
					LOG "Press OK to confirm..."
					LOG " "
					WAIT_FOR_BUTTON_PRESS A
					sleep 0.25
					resp=$(CONFIRMATION_DIALOG "CONFIRM CLEAR ALL Report + Log Files? - THIS ACTION CANNOT BE REVERSED!")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						LOG "Deleting files in ${LOOT_SCAN}..."
						rm -rf "${LOOT_SCAN}"/*
						LOG "Deleting files in ${LOOT_DETECT}..."
						rm -rf "${LOOT_DETECT}"/*
						LOG "Deleting files in ${LOOT_PROBE}..."
						rm -rf "${LOOT_PROBE}"/*
						LOG green "Report + Log Files Deleted!"				
						LOG "Press OK to continue..."
						LOG " "
						WAIT_FOR_BUTTON_PRESS A
						sleep 0.25
					fi
				fi
			elif [[ "$submenu_option" -eq 8 ]]; then
				while true; do
					LOG "Extra...."
					sub_sub_menu_extra
					submenu_option="$selnum"
					if [[ "$submenu_option" -eq 0 ]]; then
						LOG "Back to Preferences...."
						break
					elif [[ "$submenu_option" -eq 1 ]]; then
						LOG "Privacy / Streamer Mode...."
						privacy_config
					elif [[ "$submenu_option" -eq 2 ]]; then
						LOG "Friendly Mode...."
						friendly_config
					elif [[ "$submenu_option" -eq 3 ]]; then
						LOG "Skip Asking to Save Results after 1st Scan...."
						skip_ask_config
					elif [[ "$submenu_option" -eq 4 ]]; then
						LOG "Restore A + B LEDS...."
						restore_ableds
					elif [[ "$submenu_option" -eq 5 ]]; then
						LOG "Backup / Restore Config & History...."
						resp=$(CONFIRMATION_DIALOG "Backup Config & History?")
						if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
							config_backup
						else 
							LOG "Skip Backup Config & History..."
						fi
						# check file has contents
						if [[ -s "$SAVEDCONFIG_FILE" ]]; then
							sleep 0.5
							resp=$(CONFIRMATION_DIALOG "Restore Config & History?")
							if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
								config_restore
							else 
								LOG "Skip Restore Config & History..."
							fi
						fi
					fi
				done
			fi
		done
	elif [[ "$main_option" -eq 9 ]]; then
		LOG "Info...."
		lootreports=$(find "$LOOT_SCAN" "$LOOT_DETECT" "$LOOT_PROBE" -maxdepth 1 -type f -name "Report*" -print | wc -l)
		lootdetects=$(find "$LOOT_DETECT" -maxdepth 1 -type f -name "DetectTargets*" -print | wc -l)
		loottargets=$(find "$LOOT_TARGETS" -maxdepth 1 -type f -name "SavedTargets_*" -print | wc -l)
		lootreports=$((lootreports + lootdetects + loottargets))
		MAC_CHECK=$(hciconfig $BLE_IFACE | grep 'BD Address' | awk '{print $3}')
		NAME_CHECK=$(hciconfig -a $BLE_IFACE | grep "Name:" | awk -F"'" '{print $2}')
		target_count="${#BT_TARGETS[@]}"
		saved_target_count="${#BT_TARGETS_SAVED[@]}"
		filterCount=0; filterText=""
		if [[ "$filter_multilocal" -eq 1 && "$filter_randomall" -eq 1 && "$filter_localall" -eq 1 && "$filter_multiall" -eq 1 && "$filter_emptyoui" -eq 1 ]] ; then
			filterCount=1
			filterText="ALL Filters Enabled"
		else
			if [[ "$filter_emptyoui" -eq 1 ]] ; then
				filterCount=$((filterCount + 1))
				if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, NoOUI"; else filterText="NoOUI"; fi
			fi
			if [[ "$filter_multilocal" -eq 1 ]] ; then
				filterCount=$((filterCount + 1))
				if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, Basic"; else filterText="Basic"; fi
			fi
			if [[ "$filter_multiall" -eq 1 ]] ; then
				filterCount=$((filterCount + 1))
				if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, ALL Mcast"; else filterText="ALL Mcast"; fi
			fi
			if [[ "$filter_localall" -eq 1 ]] ; then
				filterCount=$((filterCount + 1))
				if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, ALL Loc"; else filterText="ALL Loc"; fi
			fi
			if [[ "$filter_randomall" -eq 1 ]] ; then
				filterCount=$((filterCount + 1))
				if [[ "$filterCount" -gt 1 ]] ; then filterText="${filterText}, ALL Rand"; else filterText="ALL Rand"; fi
			fi
		fi
		if [[ "$scan_privacy" -eq 1 ]] ; then MAC_CHECK="${MAC_CHECK:0:2}:░░:░░:░░:░░:░░"; NAME_CHECK="$priv_name_txt"; fi
		LOG magenta "================================ Device Info ===="
		LOG cyan "BT Device: $BLE_IFACE | MAC Address: $MAC_CHECK"
		LOG "Device Name: $NAME_CHECK"
		if [[ "$enable_CSR_func" -eq 1 ]] ; then
			LOG green "CSR Functionality Enabled | Loot/Reports: $lootreports"
		else
			LOG red "CSR Functionality DISABLED | Loot/Reports: $lootreports"
		fi
		gpspos_cur=$(GPS_GET)
		if [[ "$gpspos_cur" != "0 0 0 0" ]] ; then
			gpspos_last="$gpspos_cur" # GPS is valid
		fi
		if [[ -n "$gpspos_last" ]] ; then
			# requires no quote on end
			printf -v gps_formatted "%.4f %.4f %.4f %.4f" $gpspos_last
			if [[ "$scan_privacy" -eq 1 ]] ; then 
				LOG "GPS Last Pos.: -+ Hidden +-"
			else
				LOG "GPS Last Pos.: $gps_formatted"
			fi
		fi
		sleep 1
		LOG magenta "================================== Scan Info ===="
		if [[ "$total_scan_min" -gt 0 ]] ; then
			if [[ "$total_scan_min" -ge 1440 ]] ; then
				days=$((total_scan_min/1440)); hrs=$((total_scan_min%1440/60)); mins=$((total_scan_min%60))
				if [[ "$total_scan_min" -ge 2880 ]] ; then
					totalruntime_display="${days} days ${hrs} hr ${mins} min"
				else
					totalruntime_display="${days} day ${hrs} hr ${mins} min"
				fi # echo "totalruntime_display: $totalruntime_display"
			else
				if [[ "$total_scan_min" -ge 60 ]] ; then
					hrs=$((total_scan_min/60)); mins=$((total_scan_min%60))
					totalruntime_display="${hrs} hr ${mins} min"
				else
					totalruntime_display="${total_scan_min} min"
				fi
			fi
			LOG cyan "Total Scantime: ${totalruntime_display}"
		fi
		LOG cyan "Total Scans: $total_scans | Malicious Items Found: $total_detected"
		LOG "Current ${text_target_UC}s: $target_count | Saved ${text_target_UC}s: $saved_target_count"
		if [[ -n "$target_mac" ]]; then
			if [[ "$scan_privacy" -eq 1 ]] ; then priv_mac_save="$target_mac"; target_mac="${target_mac:0:2}:░░:░░:░░:░░:░░"; fi
			LOG "Current ${text_target_UC}: $target_mac"
			if [[ "$scan_privacy" -eq 1 ]] ; then target_mac="$priv_mac_save"; fi
		else
			LOG "Current ${text_target_UC}: None"
		fi
		if [[ -n "$custom_oui" ]] || [[ -n "$custom_name" ]] ; then
			if [[ "$scan_privacy" -eq 1 ]] ; then 
				priv_mac_save="$custom_oui"
				priv_name_save="$custom_name"
				custom_oui="${custom_oui:0:2}:░░:░░"
				custom_name="-+ Hidden +-"
			fi
			if [[ -n "$custom_name" ]] ; then
				LOG "${text_target_UC} OUI: $custom_oui | Custom Name: $custom_name"
			else
				LOG "${text_target_UC} OUI: $custom_oui | Custom Name not set..."
			fi
			if [[ "$scan_privacy" -eq 1 ]] ; then custom_oui="$priv_mac_save"; custom_name="$priv_name_save"; fi
		else
			LOG "Custom OUI/Name not set"
		fi
		sleep 2
		LOG magenta "============================== Scan Settings ===="
		if [[ "$scan_btclassic" == "true" ]] && [[ "$scan_btle" == "true" ]] ; then
			LOG cyan "Scan Classic + LE Bluetooth for ${DATA_SCAN_SECONDS}s each"
		else 
			if [[ "$scan_btclassic" == "true" ]] ; then
				LOG cyan "Scan Classic Bluetooth for ${DATA_SCAN_SECONDS}s"
			fi
			if [[ "$scan_btle" == "true" ]] ; then
				LOG cyan "Scan LE Bluetooth for ${DATA_SCAN_SECONDS}s"
			fi
		fi
		if [[ "$scan_mute" == "false" ]] ; then
			LOG "Repeat: $scan_infrepeat | Sound Effects: On | Debug: $scan_debug"
		else
			LOG "Repeat: $scan_infrepeat | Sound Effects: Off | Debug: $scan_debug"
		fi
		LOG "Stealth Mode: $scan_stealth | Privacy: $scan_privacy | Friendly: $scan_friendly"
		if [[ "$filterCount" -gt 0 ]] ; then
			LOG "Filter(s): ${filterText}"
		else
			LOG blue "Scan Filters: Disabled"
		fi
		# LOG magenta "======================================= Info ===="
		sleep 1
		LOG magenta "= Press OK to Return to Main Menu... == Info ===="
		WAIT_FOR_BUTTON_PRESS A
		LOG " "
	fi
	sleep 0.5
done


LOG blue   "░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"
LOG cyan   "░░░░░░░░░░░░ Thank you for playing! ░░░░░░░░░░░░░░"
LOG blue   "░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"; LOG " "; exit 0
