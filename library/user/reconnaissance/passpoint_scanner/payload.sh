#!/bin/bash
# Title: Passpoint Scanner
# Author: WiFi Pineapple Pager Community
# Description: Scanner for true Passpoint/Hotspot 2.0 networks.
#              Detects Passpoint APs via IE 221 (HS2.0 Vendor Specific OUI 50:6f:9a:10),
#              including non-transmitted BSSIDs in MBSSID (6GHz),
#              and queries ANQP data (NAI Realms, PLMNs, Domains, Venue).
# Version: 1.0

# =============================================================================
# CONFIGURATION
# =============================================================================
INTERFACE="wlan1mon"
LOOT_DIR="/root/loot/passpoint"
TEMP_DIR="/tmp/passpoint_scanner"
PASSPOINT_APS_FILE="$TEMP_DIR/passpoint_aps.txt"
UNIQUE_SSIDS_FILE="$TEMP_DIR/unique_ssids.txt"
ANQP_CAPTURE_FILE="$TEMP_DIR/anqp_capture.pcap"
RESULTS_FILE="$LOOT_DIR/passpoint_results_$(date +%Y%m%d_%H%M%S).txt"

# Channel lists
CHANNELS_24GHZ="1 2 3 4 5 6 7 8 9 10 11"
CHANNELS_5GHZ="36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161"
CHANNELS_6GHZ="5 21 37 53 69 85 101 117 133 149 165 181 197 213 229 245"  # PSC channels

# Headless mode for SSH/CLI usage
HEADLESS_MODE=false
HEADLESS_CHANNEL=""

# Parse command-line arguments for headless mode
# Usage: ./payload.sh [--headless] [--channel N]
while [ $# -gt 0 ]; do
    case "$1" in
        --headless|-H)
            HEADLESS_MODE=true
            shift
            ;;
        --channel|-c)
            HEADLESS_CHANNEL="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Override Pager-specific functions for headless mode
if $HEADLESS_MODE; then
    WAIT_FOR_INPUT() {
        echo "A"  # Auto-accept/continue
    }
    TEXT_PICKER() {
        echo "$2"  # Return default value
    }
    SPINNER() {
        :  # No-op
    }
    ALERT() {
        echo "[ALERT] $*"
    }
    LOG() {
        echo "$*"
    }
fi

# =============================================================================
# CLEANUP HANDLER
# =============================================================================
cleanup() {
    # Prevent recursive cleanup calls
    trap - EXIT SIGINT SIGTERM

    LOG "[TRAP] Cleaning up..."

    # Kill background processes
    if [ ! -z "$BEACON_PID" ]; then
        kill $BEACON_PID 2>/dev/null
        wait $BEACON_PID 2>/dev/null
    fi
    if [ ! -z "$HOPPER_PID" ]; then
        kill $HOPPER_PID 2>/dev/null
        wait $HOPPER_PID 2>/dev/null
    fi
    if [ ! -z "$ANQP_PID" ]; then
        kill $ANQP_PID 2>/dev/null
        wait $ANQP_PID 2>/dev/null
    fi

    # Kill non-system wpa_supplicant if running
    for pid in $(ps | grep "wpa_supplicant" | grep -v "var/run" | grep -v grep | awk '{print $1}'); do
        kill -9 "$pid" 2>/dev/null
    done
    rm -rf /tmp/passpoint_wpa 2>/dev/null

    # Cleanup temp files (keep loot)
    rm -rf "$TEMP_DIR" 2>/dev/null
}
trap cleanup SIGINT SIGTERM
# Note: EXIT trap disabled to prevent issues with subshell exits

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================
# ANQP queries require wpa-supplicant with HS2.0/interworking support
# Without it, we can only do beacon scanning (detect Passpoint APs, read beacon RCOIs)

ANQP_AVAILABLE=false

# Check if wpa_supplicant with HS2.0 support AND wpa-cli are installed
check_wpa_supplicant() {
    # First check for wpa-cli (required for ANQP queries)
    if ! opkg list-installed 2>/dev/null | grep -q "^wpa-cli "; then
        return 1
    fi
    # Check for wpad (full hostapd+wpa_supplicant with HS2.0)
    if opkg list-installed 2>/dev/null | grep -q "^wpad "; then
        return 0
    fi
    # Check if wpa-supplicant-openssl is installed (has HS2.0 support)
    if opkg list-installed 2>/dev/null | grep -q "^wpa-supplicant-openssl "; then
        return 0
    fi
    # Check if wpa-supplicant-mesh-openssl is installed (also has HS2.0)
    if opkg list-installed 2>/dev/null | grep -q "^wpa-supplicant-mesh-openssl "; then
        return 0
    fi
    return 1
}

# Check internet connectivity
check_internet() {
    # Try to ping opkg server or common DNS
    if ping -c 1 -W 3 downloads.openwrt.org >/dev/null 2>&1; then
        return 0
    fi
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Install wpad (includes wpa_supplicant with HS2.0 support)
install_wpa_supplicant() {
    LOG ""
    LOG "Installing HS2.0 support..."
    LOG ""

    # Check internet first
    LOG "Checking internet connection..."
    if ! check_internet; then
        LOG ""
        LOG "ERROR: No internet connection!"
        LOG ""
        LOG "Connect to internet and try again,"
        LOG "or continue with beacon-only mode."
        LOG ""
        LOG "[A] Retry  [B] Continue without"
        local btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            A)
                install_wpa_supplicant
                return $?
                ;;
            *)
                return 1
                ;;
        esac
    fi

    LOG "Internet OK. Updating packages..."

    # Update package list (ignore errors - some feeds may 404 but base feeds work)
    opkg update 2>&1 | grep -v "Failed to download" | head -5

    LOG ""

    # Check for conflicting wpad packages (wpad-basic-mbedtls, wpad-mini, etc.)
    # The full "wpad" package replaces all wpad-* variants
    local conflicts=$(opkg list-installed 2>/dev/null | grep -E "^wpad-" | cut -d' ' -f1)
    if [ -n "$conflicts" ]; then
        LOG "Package conflict detected:"
        LOG "  $conflicts"
        LOG ""
        LOG "wpad will REPLACE this."
        LOG "It has same features + HS2.0."
        LOG "All WiFi functions will still work."
        LOG ""
        LOG "[A] Replace  [B] Cancel"
        local btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            A|a)
                LOG ""
                LOG "Removing $conflicts..."
                for pkg in $conflicts; do
                    opkg remove "$pkg" 2>/dev/null
                done
                ;;
            *)
                LOG "Cancelled."
                sleep 1
                return 1
                ;;
        esac
    fi

    LOG "Installing wpad..."

    # Capture install output for error reporting
    local install_output
    local install_err

    # Install wpad (full package with hostapd+wpa_supplicant+HS2.0)
    install_output=$(opkg install wpad 2>&1)
    if [ $? -eq 0 ]; then
        # Also install wpa-cli (separate package needed for ANQP queries)
        LOG "Installing wpa-cli..."
        opkg install wpa-cli >/dev/null 2>&1
        LOG ""
        LOG "SUCCESS! Packages installed."
        LOG "ANQP queries now available."
        LOG ""
        sleep 2
        return 0
    fi
    install_err="$install_output"

    LOG ""
    LOG "ERROR: Installation failed!"
    LOG ""
    # Show last error (truncated for display)
    LOG "$(echo "$install_err" | grep -i "error\|cannot\|conflict" | head -2)"
    LOG ""
    LOG "Try manually:"
    LOG "  opkg remove wpad-basic-mbedtls"
    LOG "  opkg install wpad wpa-cli"
    LOG ""
    LOG "[A] Retry  [B] Continue without"
    local btn=$(WAIT_FOR_INPUT)
    case "$btn" in
        A)
            install_wpa_supplicant
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

# Check dependencies and set ANQP_AVAILABLE flag
check_dependencies() {
    if check_wpa_supplicant; then
        ANQP_AVAILABLE=true
        return 0
    else
        ANQP_AVAILABLE=false
        return 1
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Convert hex string to decimal
hex2dec() {
    printf "%d" "0x$1" 2>/dev/null || echo "0"
}

# Convert hex to ASCII (2 hex chars = 1 ASCII char)
hex2ascii() {
    local hex="$1"
    local ascii=""
    local i=0
    while [ $i -lt ${#hex} ]; do
        local byte="${hex:$i:2}"
        local dec=$(hex2dec "$byte")
        if [ $dec -ge 32 ] && [ $dec -le 126 ]; then
            ascii="$ascii$(printf "\\x$byte")"
        else
            ascii="$ascii."
        fi
        i=$((i + 2))
    done
    echo "$ascii"
}

# Set channel on monitor interface
set_channel() {
    local channel=$1
    iw dev "$INTERFACE" set channel "$channel" 2>/dev/null
}

# Check if 6GHz is supported
check_6ghz_support() {
    iw phy | grep -q "6[0-9][0-9][0-9] MHz" && echo "1" || echo "0"
}

# Get the phy for an interface
get_phy() {
    local iface=$1
    iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy" $2}'
}

# Store phy globally since interface might be deleted
SCAN_PHY=""

# =============================================================================
# PHASE 1A: IW SCAN FOR PASSPOINT
# =============================================================================
# Uses iw scan to detect true Passpoint/Hotspot 2.0 networks
# Detection: IE 221 (Vendor Specific) with WiFi Alliance OUI 50:6f:9a type 0x10
# Note: IE 107 is just 802.11u Interworking, NOT Passpoint indicator

# Switch interface to managed mode for scanning
# Note: SCAN_PHY must be set BEFORE calling this function (subshell scoping issue)
# Note: LOG redirected to stderr to not interfere with return value
setup_managed_mode() {
    local iface=$1
    local mgmt_iface="${iface%mon}"  # wlan1mon -> wlan1

    LOG "Switching to managed mode for scan..." >&2

    # Check if already in managed mode
    local current_type=$(iw dev "$mgmt_iface" info 2>/dev/null | awk '/type/ {print $2}')
    if [ "$current_type" = "managed" ]; then
        LOG "Already in managed mode" >&2
        echo "$mgmt_iface"
        return
    fi

    # Delete monitor interface if exists
    iw dev "${mgmt_iface}mon" del 2>/dev/null
    iw dev "$iface" del 2>/dev/null

    # Create managed interface using SCAN_PHY (set before this function call)
    iw phy "$SCAN_PHY" interface add "$mgmt_iface" type managed 2>/dev/null
    ip link set "$mgmt_iface" up 2>/dev/null
    sleep 2  # Give interface time to initialize

    echo "$mgmt_iface"
}

# Restore monitor mode after scanning
restore_monitor_mode() {
    local mgmt_iface=$1
    local mon_iface="${mgmt_iface}mon"

    LOG "Restoring monitor mode..."

    # Use stored phy or get it fresh
    local phy="$SCAN_PHY"
    if [ -z "$phy" ]; then
        phy=$(get_phy "$mgmt_iface")
    fi

    # Delete managed interface
    ip link set "$mgmt_iface" down 2>/dev/null
    iw dev "$mgmt_iface" del 2>/dev/null

    # Create monitor interface
    iw phy "$phy" interface add "$mon_iface" type monitor 2>/dev/null
    ip link set "$mon_iface" up 2>/dev/null
    sleep 1

    # Update global INTERFACE variable
    INTERFACE="$mon_iface"
}

# Build frequency list for scanning
build_freq_list() {
    local freqs=""

    # 2.4 GHz (channels 1-11)
    for ch in 1 2 3 4 5 6 7 8 9 10 11; do
        freqs="$freqs $((2407 + ch * 5))"
    done

    # 5 GHz including DFS
    for ch in 36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161; do
        freqs="$freqs $((5000 + ch * 5))"
    done

    # 6 GHz PSC channels (if supported)
    if [ "$(check_6ghz_support)" = "1" ]; then
        for ch in 5 21 37 53 69 85 101 117 133 149 165 181 197 213 229 245; do
            freqs="$freqs $((5950 + ch * 5))"
        done
    fi

    echo $freqs
}

# Parse iw scan output for Passpoint networks
# Looks for IE 221 (Vendor Specific) with WiFi Alliance HS2.0 OUI (50:6f:9a) type 0x10
# Also parses IE 71 (Multiple BSSID) to find non-transmitted Passpoint BSSIDs
# IE 107 is just 802.11u Interworking - NOT Passpoint
parse_iw_scan() {
    local scan_output="$1"
    local outfile="$2"

    echo "$scan_output" | awk -v outfile="$outfile" '
    BEGIN {
        hextable = "0123456789abcdef"
        bssid = ""
        ssid = ""
        freq = 0
        signal = ""
        has_passpoint = 0   # True Passpoint (IE 221 with HS2.0 OUI)
        has_ie107 = 0       # 802.11u Interworking (supplementary)
        ie107_data = ""
        ie111_data = ""
        hs20_data = ""
        mbssid_data = ""    # IE 71 Multiple BSSID data
    }

    function hex2dec(h,    v, i, c) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
            c = substr(h, i, 1)
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }

    function hex2ascii(h,    s, i, d) {
        s = ""
        for (i = 1; i <= length(h); i += 2) {
            d = hex2dec(substr(h, i, 2))
            if (d >= 32 && d <= 126) s = s sprintf("%c", d)
        }
        return s
    }

    # Calculate non-transmitted BSSID from transmitted BSSID and index
    function calc_nontx_bssid(tx_bssid, max_ind, bssid_idx,    parts, last, mask, new_last) {
        split(tx_bssid, parts, ":")
        last = hex2dec(parts[6])
        mask = 2^max_ind - 1
        new_last = (last - (last % (mask + 1))) + bssid_idx
        return sprintf("%s:%s:%s:%s:%s:%02x", parts[1], parts[2], parts[3], parts[4], parts[5], new_last)
    }

    # Parse MBSSID IE (71) for non-transmitted Passpoint BSSIDs
    function parse_mbssid(data, tx_bssid, tx_freq, tx_signal,    pos, max_ind, subelem_id, subelem_len, profile, profile_ssid, has_hs20, bssid_idx, nontx_bssid, ch) {
        if (length(data) < 4) return

        # First byte is Max BSSID Indicator
        max_ind = hex2dec(substr(data, 1, 2))
        if (max_ind < 1 || max_ind > 8) return

        pos = 3  # After max indicator

        # Parse subelements
        while (pos + 4 <= length(data)) {
            subelem_id = hex2dec(substr(data, pos, 2))
            subelem_len = hex2dec(substr(data, pos + 2, 2))
            pos += 4

            if (subelem_len < 1 || pos + subelem_len * 2 > length(data) + 1) break

            # Subelement 0 = Nontransmitted BSSID Profile
            if (subelem_id == 0) {
                profile = substr(data, pos, subelem_len * 2)
                profile_ssid = ""
                has_hs20 = 0
                bssid_idx = 0

                # Look for SSID element (00 len ssid) and HS2.0 IE (dd len 506f9a10)
                # Also look for Multiple BSSID-Index element (55 len index)
                ppos = 1
                while (ppos + 4 <= length(profile)) {
                    elem_id = hex2dec(substr(profile, ppos, 2))
                    elem_len = hex2dec(substr(profile, ppos + 2, 2))
                    ppos += 4

                    if (elem_len < 0 || ppos + elem_len * 2 > length(profile) + 1) break

                    elem_data = substr(profile, ppos, elem_len * 2)

                    # SSID element (ID 0)
                    if (elem_id == 0 && elem_len > 0) {
                        profile_ssid = hex2ascii(elem_data)
                    }

                    # Multiple BSSID-Index (ID 85 = 0x55)
                    if (elem_id == 85 && elem_len >= 1) {
                        bssid_idx = hex2dec(substr(elem_data, 1, 2))
                    }

                    # Vendor Specific (ID 221 = 0xdd)
                    if (elem_id == 221 && elem_len >= 4) {
                        # Check for HS2.0 OUI (506f9a) type 0x10
                        if (tolower(substr(elem_data, 1, 8)) == "506f9a10") {
                            has_hs20 = 1
                        }
                    }

                    ppos += elem_len * 2
                }

                # If this profile has Passpoint, output it
                if (has_hs20 && profile_ssid != "") {
                    nontx_bssid = calc_nontx_bssid(tx_bssid, max_ind, bssid_idx)

                    # Calculate channel from freq
                    if (tx_freq >= 2412 && tx_freq <= 2484) {
                        ch = (tx_freq - 2407) / 5
                    } else if (tx_freq >= 5180 && tx_freq <= 5885) {
                        ch = (tx_freq - 5000) / 5
                    } else if (tx_freq >= 5955) {
                        ch = (tx_freq - 5950) / 5
                    } else {
                        ch = 0
                    }

                    # Output format includes VAP BSSID for ANQP query: MBSSID:vap_bssid
                    print nontx_bssid "|" profile_ssid "|" ch "|" tx_signal "|N/A|MBSSID:" tx_bssid >> outfile
                }
            }

            pos += subelem_len * 2
        }
    }

    /^BSS / {
        # Output previous AP if it has Passpoint (IE 221 with HS2.0)
        if (bssid != "" && has_passpoint) {
            # Convert freq to channel
            if (freq >= 2412 && freq <= 2484) {
                ch = (freq - 2407) / 5
            } else if (freq >= 5180 && freq <= 5885) {
                ch = (freq - 5000) / 5
            } else if (freq >= 5955) {
                ch = (freq - 5950) / 5
            } else {
                ch = 0
            }

            rcoi = (ie111_data != "") ? ie111_data : "N/A"
            print bssid "|" ssid "|" ch "|" signal "|" rcoi "|" hs20_data >> outfile
        }

        # Parse MBSSID from previous BSS if present
        if (bssid != "" && mbssid_data != "") {
            parse_mbssid(mbssid_data, bssid, freq, signal)
        }

        # Reset for new BSS
        bssid = $2
        sub(/\(on.*/, "", bssid)
        ssid = ""
        freq = 0
        signal = ""
        has_passpoint = 0
        has_ie107 = 0
        ie107_data = ""
        ie111_data = ""
        hs20_data = ""
        mbssid_data = ""
    }

    /SSID:/ {
        ssid = $0
        sub(/.*SSID: */, "", ssid)
        gsub(/^[ \t]+|[ \t]+$/, "", ssid)
        if (ssid == "") ssid = "HIDDEN"
    }

    /freq:/ {
        freq = $2
        sub(/\..*/, "", freq)
    }

    /signal:/ {
        signal = $2
        sub(/\..*/, "", signal)
    }

    # IE 71 - Multiple BSSID (contains non-transmitted BSSIDs)
    /Unknown IE \(71\):/ {
        mbssid_data = $0
        sub(/.*Unknown IE \(71\): */, "", mbssid_data)
        gsub(/[ \t]/, "", mbssid_data)
    }

    # IE 107 - 802.11u Interworking (NOT Passpoint, just supplementary info)
    /Unknown IE \(107\):/ {
        has_ie107 = 1
        ie107_data = $0
        sub(/.*Unknown IE \(107\): */, "", ie107_data)
        gsub(/ /, "", ie107_data)
    }

    # IE 111 - Roaming Consortium (RCOI)
    /Unknown IE \(111\):/ {
        ie111_data = $0
        sub(/.*Unknown IE \(111\): */, "", ie111_data)
        gsub(/ /, "", ie111_data)
    }

    # HS2.0 Detection - iw parses and displays as "HotSpot 2.0 Indication"
    /HotSpot 2\.0 Indication/ {
        has_passpoint = 1
        hs20_data = $0
        sub(/.*HotSpot 2\.0 Indication:? */, "", hs20_data)
    }

    # IE 221 - Vendor Specific with WiFi Alliance HS2.0 OUI (50:6f:9a type 10)
    # Format: "Vendor specific: OUI 50:6f:9a, data: 10 ..."
    /[Vv]endor.*[Ss]pecific.*50:6[Ff]:9[Aa]/ {
        line = tolower($0)
        # Check for HS2.0 Indication type (0x10)
        if (line ~ /50:6f:9a.*10/ || line ~ /50:6f:9a:10/) {
            has_passpoint = 1
            hs20_data = $0
            sub(/.*[Vv]endor.*: */, "", hs20_data)
        }
    }

    # Alternative format: Unknown IE (221) with hex data starting with 506f9a10
    /Unknown IE \(221\):/ {
        ie_data = tolower($0)
        sub(/.*unknown ie \(221\): */, "", ie_data)
        gsub(/[ \t]/, "", ie_data)
        # Check if it starts with HS2.0 OUI + type: 506f9a10
        if (ie_data ~ /^506f9a10/) {
            has_passpoint = 1
            hs20_data = ie_data
        }
    }

    END {
        # Output last AP if it has Passpoint
        if (bssid != "" && has_passpoint) {
            if (freq >= 2412 && freq <= 2484) {
                ch = (freq - 2407) / 5
            } else if (freq >= 5180 && freq <= 5885) {
                ch = (freq - 5000) / 5
            } else if (freq >= 5955) {
                ch = (freq - 5950) / 5
            } else {
                ch = 0
            }

            rcoi = (ie111_data != "") ? ie111_data : "N/A"
            print bssid "|" ssid "|" ch "|" signal "|" rcoi "|" hs20_data >> outfile
        }

        # Parse MBSSID from last BSS if present
        if (bssid != "" && mbssid_data != "") {
            parse_mbssid(mbssid_data, bssid, freq, signal)
        }
    }
    '
}

phase_1a_beacon_scan() {
    LOG "=== PHASE 1A: IW SCAN ==="
    LOG "Scanning for Passpoint APs..."
    SPINNER ON

    # Initialize temp directory and files
    mkdir -p "$TEMP_DIR"
    mkdir -p "$LOOT_DIR"
    > "$PASSPOINT_APS_FILE"

    # Get PHY before switching modes (must be set before setup_managed_mode due to subshell scoping)
    SCAN_PHY=$(get_phy "$INTERFACE")
    if [ -z "$SCAN_PHY" ]; then
        SCAN_PHY=$(get_phy "${INTERFACE%mon}")
    fi

    # Switch to managed mode for scanning
    local mgmt_iface=$(setup_managed_mode "$INTERFACE")

    LOG "Scanning all channels..."

    # Run iw scan for all non-DFS channels (active scan)
    iw dev "$mgmt_iface" scan 2>&1 >/dev/null
    sleep 2

    # DFS channels (5GHz UNII-2/2C/2e) require passive scanning
    LOG "Scanning DFS channels (passive)..."
    local dfs_freqs="5260 5280 5300 5320 5500 5520 5540 5560 5580 5600 5620 5640 5660 5680 5700 5720"
    iw dev "$mgmt_iface" scan freq $dfs_freqs passive 2>&1 >/dev/null
    sleep 3

    LOG "Scanning 6GHz channels (passive)..."
    local ghz6_freqs="5975 6055 6135 6215 6295 6375 6455 6535 6615 6695 6775 6855 6935 7015"
    iw dev "$mgmt_iface" scan freq $ghz6_freqs passive 2>&1 >/dev/null
    sleep 3

    # Get full dump with unknown IEs (includes all scanned channels)
    local scan_dump
    scan_dump=$(iw dev "$mgmt_iface" scan dump -u 2>&1)

    # Parse scan results for Passpoint networks
    parse_iw_scan "$scan_dump" "$PASSPOINT_APS_FILE"

    # Restore monitor mode for GAS capture
    restore_monitor_mode "$mgmt_iface"

    SPINNER OFF

    # Count discovered APs
    local ap_count=0
    if [ -f "$PASSPOINT_APS_FILE" ]; then
        ap_count=$(sort -u "$PASSPOINT_APS_FILE" | wc -l)
    fi

    LOG "Found $ap_count Passpoint APs"

    if [ "$ap_count" -eq 0 ]; then
        LOG "No Passpoint APs found"
        ALERT "No Passpoint APs"
        return 1
    fi

    LOG "[ALERT] Found $ap_count Passpoint APs"
    return 0
}

# =============================================================================
# PHASE 1B: SSID GROUPING
# =============================================================================
# Groups APs by SSID and finds strongest signal for each

phase_1b_group_ssids() {
    LOG "=== PHASE 1B: SSID GROUPING ==="

    if [ ! -f "$PASSPOINT_APS_FILE" ] || [ ! -s "$PASSPOINT_APS_FILE" ]; then
        LOG "No APs to group"
        return 1
    fi

    # Sort unique entries and group by SSID
    # Prefer transmitted BSSIDs over MBSSID non-tx (which can't be queried for ANQP)
    # Among same type, keep strongest RSSI
    # Format: BSSID|SSID|Channel|RSSI|RCOI|ANO

    > "$UNIQUE_SSIDS_FILE"

    # Process and group by SSID
    sort -u "$PASSPOINT_APS_FILE" | \
    awk -F'|' '
    {
        ssid = $2
        channel = $3
        rssi = $4
        bssid = $1
        rcoi = $5
        ano = $6

        # Convert RSSI to number (handle negative)
        rssi_num = rssi + 0

        # Check if this is an MBSSID (non-transmitted, cannot query ANQP)
        is_mbssid = (ano ~ /^MBSSID:/) ? 1 : 0

        # Preference: transmitted BSSID > MBSSID
        # If current best is MBSSID and this one is not, prefer this one
        # If both same type, prefer stronger signal
        should_update = 0
        if (!(ssid in best_rssi)) {
            should_update = 1
        } else if (best_is_mbssid[ssid] && !is_mbssid) {
            # Current best is MBSSID, this is transmitted - prefer transmitted
            should_update = 1
        } else if (!best_is_mbssid[ssid] && is_mbssid) {
            # Current best is transmitted, this is MBSSID - keep transmitted
            should_update = 0
        } else if (rssi_num > best_rssi[ssid]) {
            # Same type, prefer stronger signal
            should_update = 1
        }

        if (should_update) {
            best_rssi[ssid] = rssi_num
            best_channel[ssid] = channel
            best_bssid[ssid] = bssid
            best_rcoi[ssid] = rcoi
            best_ano[ssid] = ano
            best_is_mbssid[ssid] = is_mbssid
        }
        ap_count[ssid]++
    }
    END {
        # Output all SSIDs with their best values (busybox awk compatible)
        for (ssid in best_rssi) {
            print best_rssi[ssid] "|" ssid "|" best_channel[ssid] "|" best_bssid[ssid] "|" best_rcoi[ssid] "|" best_ano[ssid] "|" ap_count[ssid]
        }
    }' | sort -t'|' -k1 -nr | \
    awk -F'|' '{
        # Output: SSID|Channel|BSSID|RSSI|RCOI|ANO|Count
        print $2 "|" $3 "|" $4 "|" $1 "|" $5 "|" $6 "|" $7
    }' > "$UNIQUE_SSIDS_FILE"

    local ssid_count=$(wc -l < "$UNIQUE_SSIDS_FILE")
    LOG "Grouped into $ssid_count unique SSIDs"

    # Display top SSIDs
    LOG ""
    LOG "Top Passpoint Networks:"
    head -5 "$UNIQUE_SSIDS_FILE" | while IFS='|' read -r ssid channel bssid rssi rcoi ano count; do
        LOG "  $ssid (Ch:$channel, ${rssi}dBm, ${count} APs)"
    done
    LOG ""

    return 0
}

# =============================================================================
# PHASE 1C: ACTIVE ANQP QUERY
# =============================================================================
# Uses wpa_supplicant to actively query ANQP data from Passpoint APs
# Much more reliable than passive capture

WPA_SUPPLICANT_PID=""
WPA_CTRL_IFACE="/tmp/passpoint_wpa"

# Setup wpa_supplicant for ANQP queries
setup_wpa_supplicant() {
    local iface=$1

    LOG "Setting up wpa_supplicant for ANQP queries..."

    # Create minimal config for GAS queries (no association needed)
    local wpa_conf="$TEMP_DIR/wpa_supplicant.conf"
    cat > "$wpa_conf" << 'EOF'
ctrl_interface=/tmp/passpoint_wpa
interworking=1
hs20=1
bss_expiration_age=300
bss_expiration_scan_count=10
EOF

    # Kill any existing wpa_supplicant using our ctrl_interface and clean it
    # Be careful not to kill the system wpa_supplicant (uses /var/run/wpa_supplicant)
    for pid in $(ps | grep "wpa_supplicant" | grep -v "var/run" | grep -v grep | awk '{print $1}'); do
        kill -9 "$pid" 2>/dev/null
    done
    rm -rf "$WPA_CTRL_IFACE" 2>/dev/null
    sleep 2

    # Verify interface exists before starting
    if ! ip link show "$iface" >/dev/null 2>&1; then
        LOG "  Interface $iface does not exist"
        return 1
    fi

    # Start wpa_supplicant
    wpa_supplicant -B -i "$iface" -c "$wpa_conf" -D nl80211 2>&1 | grep -v "Match already configured" >&2
    WPA_SUPPLICANT_PID=$!
    sleep 3

    # Check if running (use ps/grep since pgrep may not be available)
    if ! ps | grep "wpa_supplicant" | grep -q "$iface"; then
        LOG "  Failed to start wpa_supplicant"
        return 1
    fi

    LOG "  wpa_supplicant started"
    return 0
}

# Cleanup wpa_supplicant
cleanup_wpa_supplicant() {
    local iface=$1
    # Kill only non-system wpa_supplicant processes
    for pid in $(ps | grep "wpa_supplicant" | grep -v "var/run" | grep -v grep | awk '{print $1}'); do
        kill -9 "$pid" 2>/dev/null
    done
    rm -rf "$WPA_CTRL_IFACE" 2>/dev/null
}

# Query ANQP data from a specific BSSID
# $4 is optional result_bssid for MBSSID networks (store results under non-tx BSSID)
# $5 is optional channel for targeted rescanning
query_anqp() {
    local iface=$1
    local bssid=$2
    local ssid=$3
    local result_bssid=${4:-$bssid}  # Use query BSSID if result BSSID not provided
    local channel=${5:-0}
    local outfile="$TEMP_DIR/anqp_${bssid//:/}.txt"

    # ANQP Element IDs to query:
    # 257 = Capability List
    # 258 = Venue Name
    # 261 = Roaming Consortium List (full RCOI - beacons only have up to 3)
    # 263 = NAI Realm List
    # 264 = 3GPP Cellular Network
    # 268 = Domain Name List
    # 277 = Venue URL
    local anqp_ids="257,258,261,263,264,268,277"

    # HS2.0 ANQP Subtypes:
    # 3 = Operator Friendly Name
    # 4 = WAN Metrics
    # 5 = Connection Capability
    local hs20_subtypes="3,4,5"

    LOG "  Querying ANQP from $bssid..."

    # Convert channel to frequency for targeted scanning
    channel_to_freq() {
        local ch=$1
        if [ "$ch" -ge 1 ] && [ "$ch" -le 14 ]; then
            # 2.4GHz
            if [ "$ch" -eq 14 ]; then echo 2484; else echo $((2407 + ch * 5)); fi
        elif [ "$ch" -ge 36 ] && [ "$ch" -le 177 ]; then
            # 5GHz
            echo $((5000 + ch * 5))
        elif [ "$ch" -ge 1 ] && [ "$ch" -le 233 ]; then
            # 6GHz (simplified)
            echo $((5950 + ch * 5))
        else
            echo 0
        fi
    }

    # Check if BSS is in cache (should be from the full scan done earlier)
    if ! wpa_cli -p "$WPA_CTRL_IFACE" -i "$iface" bss "$bssid" 2>/dev/null | grep -q "bssid"; then
        # BSS not in cache - do targeted rescan on the AP's channel
        LOG "  BSS not in cache, rescanning ch $channel..."

        local freq=$(channel_to_freq "$channel")
        if [ "$freq" -gt 0 ]; then
            # Targeted scan on specific frequency
            iw dev "$iface" scan freq "$freq" passive >/dev/null 2>&1
            sleep 2
            wpa_cli -p "$WPA_CTRL_IFACE" -i "$iface" scan freq="$freq" >/dev/null 2>&1
        else
            # Fallback: scan all DFS frequencies
            local dfs_freqs="5260 5280 5300 5320 5500 5520 5540 5560 5580 5600 5620 5640 5660 5680 5700 5720"
            iw dev "$iface" scan freq $dfs_freqs passive >/dev/null 2>&1
            sleep 2
            wpa_cli -p "$WPA_CTRL_IFACE" -i "$iface" scan >/dev/null 2>&1
        fi
        sleep 4

        # Check again after rescan
        if ! wpa_cli -p "$WPA_CTRL_IFACE" -i "$iface" bss "$bssid" 2>/dev/null | grep -q "bssid"; then
            LOG "  BSS still not found, skipping"
            return 1
        fi
    fi

    # Send ANQP query
    LOG "  Sending ANQP request..."
    wpa_cli -p "$WPA_CTRL_IFACE" -i "$iface" anqp_get "$bssid" "$anqp_ids" >/dev/null 2>&1

    # Send HS2.0 ANQP query (may not be supported)
    wpa_cli -p "$WPA_CTRL_IFACE" -i "$iface" hs20_anqp_get "$bssid" "$hs20_subtypes" >/dev/null 2>&1

    # Wait for GAS responses
    LOG "  Waiting for GAS response..."
    sleep 5

    # Fetch the BSS info which now includes ANQP data
    LOG "  Fetching BSS info..."
    local bss_info
    bss_info=$(wpa_cli -p "$WPA_CTRL_IFACE" -i "$iface" bss "$bssid" 2>/dev/null)

    if [ -z "$bss_info" ] || ! echo "$bss_info" | grep -q "bssid"; then
        LOG "  No response from AP"
        return 1
    fi

    LOG "  Parsing ANQP data..."
    echo "$bss_info" > "$outfile"

    # Parse the ANQP results (use result_bssid for storage, may differ for MBSSID)
    parse_wpa_anqp "$outfile" "$ssid" "$result_bssid"

    LOG "  Query complete"
    return 0
}

# Parse wpa_cli BSS output for ANQP data
parse_wpa_anqp() {
    local infile=$1
    local ssid=$2
    local bssid=$3

    # Ensure loot directory exists
    mkdir -p "$LOOT_DIR" 2>/dev/null

    # wpa_cli bss output includes lines like:
    # anqp_domain_name=example.com
    # anqp_nai_realm=...
    # anqp_3gpp=...
    # hs20_operator_friendly_name=...

    local found_anqp=0

    # Domain Name - decode from hex
    local domains_hex=$(grep "anqp_domain_name=" "$infile" 2>/dev/null | cut -d= -f2-)
    if [ -n "$domains_hex" ]; then
        local domains_decoded=$(decode_domain_name "$domains_hex")
        if [ -n "$domains_decoded" ]; then
            LOG "  [Domains] $domains_decoded"
            echo "ANQP_DOMAIN|$bssid|$ssid|$domains_decoded" >> "$RESULTS_FILE"
        fi
        found_anqp=1
    fi

    # NAI Realm - decode from hex
    local nai=$(grep "anqp_nai_realm=" "$infile" 2>/dev/null | cut -d= -f2-)
    if [ -n "$nai" ]; then
        local nai_decoded=$(echo "$nai" | parse_nai_realm_hex)
        if [ -n "$nai_decoded" ]; then
            LOG "  [NAI Realms] $nai_decoded"
            echo "ANQP_NAI_REALM|$bssid|$ssid|$nai_decoded" >> "$RESULTS_FILE"
        else
            LOG "  [NAI Realm] (hex data present)"
        fi
        found_anqp=1
    fi

    # 3GPP/PLMN - decode from hex with carrier name lookup
    local gpp=$(grep "anqp_3gpp=" "$infile" 2>/dev/null | cut -d= -f2-)
    if [ -n "$gpp" ]; then
        local plmn_raw=$(echo "$gpp" | parse_3gpp_hex)
        if [ -n "$plmn_raw" ]; then
            # Add carrier names to each PLMN
            local plmn_decoded=""
            local IFS_OLD="$IFS"
            IFS=','
            for plmn in $plmn_raw; do
                plmn=$(echo "$plmn" | tr -d ' ')
                local mcc=$(echo "$plmn" | cut -d'-' -f1)
                local mnc=$(echo "$plmn" | cut -d'-' -f2)
                local carrier=$(lookup_plmn "$mcc" "$mnc")
                if [ -n "$carrier" ]; then
                    [ -n "$plmn_decoded" ] && plmn_decoded="$plmn_decoded, "
                    plmn_decoded="$plmn_decoded$plmn ($carrier)"
                else
                    [ -n "$plmn_decoded" ] && plmn_decoded="$plmn_decoded, "
                    plmn_decoded="$plmn_decoded$plmn"
                fi
            done
            IFS="$IFS_OLD"
            LOG "  [PLMNs] $plmn_decoded"
            echo "ANQP_3GPP|$bssid|$ssid|$plmn_decoded" >> "$RESULTS_FILE"
        else
            LOG "  [3GPP] (hex data present)"
        fi
        found_anqp=1
    fi

    # Venue Name - decode from hex
    local venue_hex=$(grep "anqp_venue_name=" "$infile" 2>/dev/null | cut -d= -f2-)
    if [ -n "$venue_hex" ]; then
        local venue_decoded=$(decode_venue_name "$venue_hex")
        if [ -n "$venue_decoded" ]; then
            LOG "  [Venue] $venue_decoded"
            echo "ANQP_VENUE|$bssid|$ssid|$venue_decoded" >> "$RESULTS_FILE"
        fi
        found_anqp=1
    fi

    # HS2.0 Operator Friendly Name - decode from hex
    local opname_hex=$(grep "hs20_operator_friendly_name=" "$infile" 2>/dev/null | cut -d= -f2-)
    if [ -n "$opname_hex" ]; then
        local opname_decoded=$(decode_operator_name "$opname_hex")
        if [ -n "$opname_decoded" ]; then
            LOG "  [Operator] $opname_decoded"
            echo "ANQP_OPERATOR|$bssid|$ssid|$opname_decoded" >> "$RESULTS_FILE"
        fi
        found_anqp=1
    fi

    # Venue URL
    local venue_url=$(grep "anqp_venue_url=" "$infile" 2>/dev/null | cut -d= -f2-)
    if [ -n "$venue_url" ]; then
        LOG "  [Venue URL] $venue_url"
        echo "ANQP_VENUE_URL|$bssid|$ssid|$venue_url" >> "$RESULTS_FILE"
        found_anqp=1
    fi

    # Roaming Consortium (ANQP ID 261) - decode from hex
    local rcoi_hex=$(grep "anqp_roaming_consortium=" "$infile" 2>/dev/null | cut -d= -f2-)
    if [ -n "$rcoi_hex" ]; then
        local rcoi_decoded=$(decode_anqp_rcoi "$rcoi_hex")
        if [ -n "$rcoi_decoded" ]; then
            LOG "  [RCOI] $rcoi_decoded"
            echo "ANQP_RCOI|$bssid|$ssid|$rcoi_decoded" >> "$RESULTS_FILE"
        fi
        found_anqp=1
    fi

    if [ $found_anqp -eq 0 ]; then
        LOG "  No ANQP data in response"
    fi

    return 0
}

# Decode hex string to ASCII (printable chars only)
hex_to_ascii() {
    local hex="$1"
    echo "$hex" | sed 's/../\\x&/g' | xargs -0 printf 2>/dev/null | tr -cd '[:print:]'
}

# Decode RCOI (Roaming Consortium OI) and identify organization
# Returns: "RCOI_HEX: Description"
decode_rcoi() {
    local rcoi_hex="$1"
    rcoi_hex=$(echo "$rcoi_hex" | tr 'a-f' 'A-F')

    # Known RCOI prefixes and organizations
    case "$rcoi_hex" in
        # OpenRoaming Settlement-Free (5A03BA prefix)
        5A03BA*)
            local nibbles="${rcoi_hex:6}"
            echo "$rcoi_hex: OpenRoaming (Settlement-Free)$(decode_openroaming_nibbles "$nibbles")"
            ;;
        # OpenRoaming Settled (BAA2D0 prefix)
        BAA2D0*)
            local nibbles="${rcoi_hex:6}"
            echo "$rcoi_hex: OpenRoaming (Settled)$(decode_openroaming_nibbles "$nibbles")"
            ;;
        # eduroam
        001BC50460|5A03BA0800)
            echo "$rcoi_hex: eduroam"
            ;;
        # Wi-Fi Alliance
        506F9A*)
            echo "$rcoi_hex: Wi-Fi Alliance"
            ;;
        # Cisco OpenRoaming
        F4F5E8*)
            echo "$rcoi_hex: Cisco OpenRoaming"
            ;;
        # Boingo
        004096*)
            echo "$rcoi_hex: Boingo Wireless"
            ;;
        # iPass
        001BC5*)
            echo "$rcoi_hex: iPass/Pareteum"
            ;;
        # AT&T
        001907|002686*)
            echo "$rcoi_hex: AT&T"
            ;;
        # T-Mobile
        00019E|0020D6*)
            echo "$rcoi_hex: T-Mobile"
            ;;
        # Verizon
        0022F1*)
            echo "$rcoi_hex: Verizon"
            ;;
        # Google
        001A11*)
            echo "$rcoi_hex: Google"
            ;;
        *)
            echo "$rcoi_hex: Unknown"
            ;;
    esac
}

# Decode OpenRoaming policy nibbles (after 5A03BA or BAA2D0 prefix)
decode_openroaming_nibbles() {
    local nibbles="$1"
    [ -z "$nibbles" ] && return

    # Format: [N1][N2][N3][N4] where each is 1 hex char
    # N1: bit3=LoA, bit1=QoS, bit0=PID
    # N2: Industry type (0-B)
    # N3: Credential lifetime (0 or 8)
    # N4: Reserved

    local n1="${nibbles:0:1}"
    local n2="${nibbles:1:1}"

    [ -z "$n1" ] && return

    # Decode N1
    local n1_val=$(printf "%d" "0x$n1" 2>/dev/null)
    local loa=""
    local qos=""
    local pid=""

    [ $((n1_val & 8)) -ne 0 ] && loa="Enhanced-LoA" || loa="Baseline-LoA"
    [ $((n1_val & 2)) -ne 0 ] && qos="Silver-QoS" || qos="Bronze-QoS"
    [ $((n1_val & 1)) -ne 0 ] && pid="Identified" || pid="Anonymous"

    # Decode N2 - Industry type
    local industry=""
    case "$n2" in
        0) industry="All" ;;
        1) industry="Small-ISP" ;;
        2) industry="Corporate" ;;
        3) industry="Enterprise" ;;
        4) industry="Government" ;;
        5) industry="Automotive" ;;
        6) industry="Hospitality" ;;
        7) industry="Airlines" ;;
        8) industry="Education" ;;
        9) industry="Cable/Telecom" ;;
        [Aa]) industry="Manufacturing" ;;
        [Bb]) industry="Retail" ;;
        *) industry="" ;;
    esac

    local result=""
    [ -n "$industry" ] && result=" [$industry"
    [ -n "$pid" ] && result="$result,$pid"
    [ -n "$qos" ] && result="$result,$qos"
    [ -n "$loa" ] && result="$result,$loa"
    [ -n "$result" ] && result="$result]"

    echo "$result"
}

# Parse RCOI hex from IE 111 beacon data
# IE 111 format: [num_anqp_ois(1)][oi_lengths(1-2)][oi1][oi2][oi3]
parse_beacon_rcoi() {
    local ie111_hex="$1"
    [ -z "$ie111_hex" ] && return

    echo "$ie111_hex" | awk '
    BEGIN { hextable = "0123456789abcdef" }
    function hex2dec(h,    v, i, c) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
            c = substr(h, i, 1)
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }
    {
        gsub(/[^0-9a-fA-F]/, "", $0)
        if (length($0) < 4) next

        # First byte: bits 7-4 = ANQP OI count, bits 3-0 = OI#1 length
        first_byte = hex2dec(substr($0, 1, 2))
        num_ois = int(first_byte / 16)  # bits 7-4
        oi1_len = first_byte % 16       # bits 3-0

        # Second byte: OI#2 length (bits 7-4), OI#3 length (bits 3-0)
        second_byte = hex2dec(substr($0, 3, 2))
        oi2_len = int(second_byte / 16)
        oi3_len = second_byte % 16

        result = ""
        pos = 5  # Start after header (2 bytes = 4 hex chars)

        # Parse OI #1
        if (oi1_len > 0 && pos + oi1_len*2 <= length($0)) {
            oi1 = toupper(substr($0, pos, oi1_len * 2))
            if (result != "") result = result ","
            result = result oi1
            pos += oi1_len * 2
        }

        # Parse OI #2
        if (oi2_len > 0 && pos + oi2_len*2 <= length($0)) {
            oi2 = toupper(substr($0, pos, oi2_len * 2))
            if (result != "") result = result ","
            result = result oi2
            pos += oi2_len * 2
        }

        # Parse OI #3
        if (oi3_len > 0 && pos + oi3_len*2 <= length($0)) {
            oi3 = toupper(substr($0, pos, oi3_len * 2))
            if (result != "") result = result ","
            result = result oi3
        }

        print result
    }'
}

# Decode ANQP Roaming Consortium (ID 261) hex response
# Format: [OI_len(1)][OI_data]... repeated
decode_anqp_rcoi() {
    local hex="$1"
    [ -z "$hex" ] && return

    # Parse ANQP 261 format and decode each OI
    local ois=$(echo "$hex" | awk '
    BEGIN { hextable = "0123456789abcdef" }
    function hex2dec(h,    v, i, c) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
            c = substr(h, i, 1)
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }
    {
        gsub(/[^0-9a-fA-F]/, "", $0)
        pos = 1
        result = ""
        while (pos + 2 <= length($0)) {
            oi_len = hex2dec(substr($0, pos, 2))
            pos += 2
            if (oi_len > 0 && oi_len <= 15 && pos + oi_len*2 - 1 <= length($0)) {
                oi = toupper(substr($0, pos, oi_len * 2))
                if (result != "") result = result "|"
                result = result oi
                pos += oi_len * 2
            } else {
                break
            }
        }
        print result
    }')

    # Decode each OI and build result string
    local result=""
    local IFS='|'
    for oi in $ois; do
        local decoded=$(decode_rcoi "$oi")
        if [ -n "$result" ]; then
            result="$result; $decoded"
        else
            result="$decoded"
        fi
    done
    echo "$result"
}

# Lookup PLMN (MCC-MNC) carrier name
# Top 100 carriers from ITU E.212 database
lookup_plmn() {
    local mcc="$1"
    local mnc="$2"
    local plmn="${mcc}-${mnc}"

    case "$plmn" in
        # United States - Major Carriers
        310-410|310-280|310-380|310-170|310-980|311-180) echo "AT&T" ;;
        310-260|310-200|310-210|310-220|310-230|310-240|310-250|310-270|310-310|310-490|310-530|310-660|310-800|311-490) echo "T-Mobile" ;;
        311-480|311-481|311-482|311-483|311-484|311-485|311-486|311-487|311-488|311-489) echo "Verizon" ;;
        310-010|310-012|310-013|310-590|310-820|310-890|311-110|311-270|311-271|311-272|311-273|311-274|311-275|311-276|311-277|311-278|311-279|311-280|311-281|311-282|311-283|311-284|311-285|311-286|311-287|311-288|311-289|311-390|311-440|311-590) echo "Verizon" ;;
        312-530) echo "Sprint" ;;
        310-120) echo "Sprint (T-Mobile)" ;;
        311-660) echo "Metro PCS" ;;
        310-730|311-220|311-225|311-580) echo "U.S. Cellular" ;;
        310-370|310-470) echo "Docomo Pacific" ;;

        # Canada
        302-220|302-221) echo "Telus" ;;
        302-370|302-720) echo "Rogers" ;;
        302-490|302-500|302-510) echo "Bell" ;;
        302-610|302-640) echo "Bell MTS" ;;
        302-680) echo "SaskTel" ;;

        # United Kingdom
        234-010|234-011|234-012|234-002) echo "O2 UK" ;;
        234-015|234-016|234-077|234-091) echo "Vodafone UK" ;;
        234-020|234-094) echo "Hutchison 3G UK" ;;
        234-030|234-031|234-032|234-033|234-034|234-086|235-001|235-002) echo "EE" ;;
        234-050) echo "JT (Jersey)" ;;
        234-055) echo "Sure (Guernsey)" ;;
        234-058) echo "Manx Telecom" ;;

        # Germany
        262-01|262-06) echo "Telekom Deutschland" ;;
        262-02|262-04|262-09) echo "Vodafone Germany" ;;
        262-03|262-05|262-77) echo "Telefonica Germany" ;;
        262-07|262-08|262-11) echo "O2 Germany" ;;

        # France
        208-01|208-02) echo "Orange France" ;;
        208-10|208-11|208-13) echo "SFR" ;;
        208-15|208-16|208-35|208-36) echo "Free Mobile" ;;
        208-20|208-21|208-88) echo "Bouygues Telecom" ;;

        # Spain
        214-01|214-06) echo "Vodafone Spain" ;;
        214-03|214-07) echo "Orange Spain" ;;
        214-04|214-05) echo "Movistar" ;;

        # Italy
        222-01|222-10) echo "TIM Italy" ;;
        222-10) echo "Vodafone Italy" ;;
        222-88) echo "Wind Italy" ;;
        222-99) echo "3 Italy" ;;

        # Netherlands
        204-04) echo "Vodafone NL" ;;
        204-08|204-10|204-12|204-69) echo "KPN" ;;
        204-16|204-20) echo "T-Mobile NL" ;;

        # Australia
        505-01|505-71|505-72) echo "Telstra" ;;
        505-02|505-90) echo "Optus" ;;
        505-03|505-06|505-12) echo "Vodafone AU" ;;

        # Japan
        440-10|441-10) echo "NTT DoCoMo" ;;
        440-20|441-20) echo "SoftBank" ;;
        440-50|441-50) echo "KDDI au" ;;
        440-51|441-51) echo "KDDI au" ;;

        # South Korea
        450-05|450-11) echo "SK Telecom" ;;
        450-08) echo "KT" ;;
        450-06) echo "LG U+" ;;

        # China
        460-00|460-02|460-04|460-07|460-08) echo "China Mobile" ;;
        460-01|460-06|460-09) echo "China Unicom" ;;
        460-03|460-05|460-11) echo "China Telecom" ;;

        # India
        404-10|404-45|404-49|405-845|405-846) echo "Airtel India" ;;
        404-86|404-84|405-854) echo "Vodafone Idea" ;;
        405-840|405-854|405-855|405-856|405-857|405-858) echo "Jio" ;;

        # Mexico
        334-020) echo "Telcel" ;;
        334-030|334-090) echo "Movistar Mexico" ;;
        334-050) echo "AT&T Mexico" ;;

        # Brazil
        724-10|724-11|724-23) echo "Vivo Brazil" ;;
        724-02|724-03|724-04) echo "TIM Brazil" ;;
        724-05|724-31) echo "Claro Brazil" ;;
        724-15|724-39) echo "Oi Brazil" ;;

        # Switzerland
        228-01) echo "Swisscom" ;;
        228-02) echo "Sunrise" ;;
        228-03) echo "Salt" ;;

        # Sweden
        240-01) echo "Telia Sweden" ;;
        240-02) echo "3 Sweden" ;;
        240-07) echo "Tele2 Sweden" ;;

        # Norway
        242-01) echo "Telenor Norway" ;;
        242-02) echo "Telia Norway" ;;

        # Denmark
        238-01|238-10) echo "TDC Denmark" ;;
        238-02|238-77) echo "Telenor Denmark" ;;
        238-06) echo "3 Denmark" ;;
        238-20) echo "Telia Denmark" ;;

        # Singapore
        525-01) echo "SingTel" ;;
        525-03) echo "M1" ;;
        525-05) echo "StarHub" ;;

        # Hong Kong
        454-00|454-10|454-11) echo "CSL Hong Kong" ;;
        454-06|454-15|454-16) echo "SmarTone" ;;
        454-12|454-13) echo "China Mobile HK" ;;

        # Taiwan
        466-01) echo "Far EasTone" ;;
        466-92|466-93) echo "Chunghwa Telecom" ;;
        466-97) echo "Taiwan Mobile" ;;

        # UAE
        424-02) echo "Etisalat" ;;
        424-03) echo "du" ;;

        # Saudi Arabia
        420-01) echo "STC" ;;
        420-03) echo "Mobily" ;;
        420-04) echo "Zain SA" ;;

        # Default
        *) echo "" ;;
    esac
}

# Decode Domain Name List: format is [len][domain][len][domain]...
decode_domain_name() {
    local hex="$1"
    [ -z "$hex" ] && return

    echo "$hex" | awk '
    BEGIN { hextable = "0123456789abcdef" }
    function hex2dec(h,    v, i, c) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
            c = substr(h, i, 1)
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }
    function hex2ascii(h,    s, j, d) {
        s = ""
        for (j = 1; j <= length(h); j += 2) {
            d = hex2dec(substr(h, j, 2))
            if (d >= 32 && d <= 126) s = s sprintf("%c", d)
        }
        return s
    }
    {
        gsub(/[^0-9a-fA-F]/, "", $0)
        pos = 1
        result = ""
        while (pos + 2 <= length($0)) {
            dlen = hex2dec(substr($0, pos, 2))
            pos += 2
            if (dlen > 0 && pos + dlen*2 - 1 <= length($0)) {
                domain = hex2ascii(substr($0, pos, dlen*2))
                if (domain != "") {
                    if (result != "") result = result ", "
                    result = result domain
                }
                pos += dlen * 2
            } else break
        }
        print result
    }'
}

# Decode Venue Name: format is [group][type][lang(3)][name]...
decode_venue_name() {
    local hex="$1"
    [ -z "$hex" ] && return

    echo "$hex" | awk '
    BEGIN { hextable = "0123456789abcdef" }
    function hex2dec(h,    v, i, c) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
            c = substr(h, i, 1)
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }
    function hex2ascii(h,    s, j, d) {
        s = ""
        for (i = 1; i <= length(h); i += 2) {
            d = hex2dec(substr(h, i, 2))
            if (d >= 32 && d <= 126) s = s sprintf("%c", d)
        }
        return s
    }
    {
        gsub(/[^0-9a-fA-F]/, "", $0)
        if (length($0) < 4) next
        # Skip venue group/type (first 2 bytes)
        pos = 5
        result = ""
        while (pos + 2 <= length($0)) {
            # Each venue name: [len][lang(3)][name]
            nlen = hex2dec(substr($0, pos, 2))
            pos += 2
            if (nlen > 3 && pos + nlen*2 - 1 <= length($0)) {
                lang = hex2ascii(substr($0, pos, 6))  # 3 bytes lang code
                name = hex2ascii(substr($0, pos + 6, (nlen - 3) * 2))
                if (name != "") {
                    if (result != "") result = result "; "
                    result = result name
                }
                pos += nlen * 2
            } else break
        }
        if (result == "") {
            # Fallback: just extract printable ASCII
            result = hex2ascii($0)
        }
        print result
    }'
}

# Decode Operator Friendly Name: format is [len][lang(3)][name]...
decode_operator_name() {
    local hex="$1"
    [ -z "$hex" ] && return

    echo "$hex" | awk '
    BEGIN { hextable = "0123456789abcdef" }
    function hex2dec(h,    v, i, c) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
            c = substr(h, i, 1)
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }
    function hex2ascii(h,    s, j, d) {
        s = ""
        for (i = 1; i <= length(h); i += 2) {
            d = hex2dec(substr(h, i, 2))
            if (d >= 32 && d <= 126) s = s sprintf("%c", d)
        }
        return s
    }
    {
        gsub(/[^0-9a-fA-F]/, "", $0)
        pos = 1
        result = ""
        while (pos + 2 <= length($0)) {
            nlen = hex2dec(substr($0, pos, 2))
            pos += 2
            if (nlen > 3 && pos + nlen*2 - 1 <= length($0)) {
                lang = hex2ascii(substr($0, pos, 6))
                name = hex2ascii(substr($0, pos + 6, (nlen - 3) * 2))
                if (name != "") {
                    if (result != "") result = result "; "
                    result = result name
                }
                pos += nlen * 2
            } else break
        }
        if (result == "") result = hex2ascii($0)
        print result
    }'
}

# Parse NAI Realm hex to readable format
# Format: [count(2)][len(2)][enc(1)][realm_len(1)][realm][eap_count]...
parse_nai_realm_hex() {
    read hex
    [ -z "$hex" ] && return

    echo "$hex" | awk '
    BEGIN { hextable = "0123456789abcdef" }
    function hex2dec(h,    v, i, c) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
            c = substr(h, i, 1)
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }
    function hex2ascii(h,    s, j, d) {
        s = ""
        for (i = 1; i <= length(h); i += 2) {
            d = hex2dec(substr(h, i, 2))
            if (d >= 32 && d <= 126) s = s sprintf("%c", d)
        }
        return s
    }
    {
        gsub(/[^0-9a-fA-F]/, "", $0)
        if (length($0) < 8) next

        # NAI Realm count (2 bytes LE)
        count = hex2dec(substr($0, 3, 2) substr($0, 1, 2))
        if (count < 1 || count > 20) count = 10  # Sanity limit

        pos = 5
        result = ""
        for (c = 0; c < count && pos + 8 <= length($0); c++) {
            # Field length (2 bytes LE)
            flen_lo = hex2dec(substr($0, pos, 2))
            flen_hi = hex2dec(substr($0, pos + 2, 2))
            flen = flen_hi * 256 + flen_lo
            pos += 4

            if (flen < 2 || pos + flen*2 > length($0) + 1) break

            # Encoding (1 byte)
            pos += 2
            # Realm length (1 byte)
            realm_len = hex2dec(substr($0, pos, 2))
            pos += 2

            if (realm_len > 0 && realm_len <= 255 && pos + realm_len*2 <= length($0) + 1) {
                realm = hex2ascii(substr($0, pos, realm_len * 2))
                if (realm != "" && realm ~ /\./) {
                    if (result != "") result = result ", "
                    result = result realm
                }
                pos += realm_len * 2
            }

            # Skip EAP methods
            if (pos + 2 <= length($0)) {
                eap_count = hex2dec(substr($0, pos, 2))
                pos += 2
                # Skip EAP data (approximate)
                for (e = 0; e < eap_count && pos + 4 <= length($0); e++) {
                    eap_len = hex2dec(substr($0, pos, 2))
                    pos += 2 + eap_len * 2
                }
            }
        }
        print result
    }'
}

# Parse 3GPP hex to PLMN format
parse_3gpp_hex() {
    read hex
    [ -z "$hex" ] && return

    # 3GPP format: GUD(1) UDHL(1) IEI(1) PLMNlen(1) NumPLMNs(1) then 3-byte PLMNs
    # Each PLMN is BCD: byte1=MCC2|MCC1, byte2=MNC3|MCC3, byte3=MNC2|MNC1
    echo "$hex" | awk '
    BEGIN { hextable = "0123456789abcdef" }
    function hex2dec(h,    v, i, c) {
        v = 0
        for (i = 1; i <= length(h); i++) {
            c = tolower(substr(h, i, 1))
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }
    {
        gsub(/[^0-9a-fA-F]/, "", $0)
        if (length($0) < 12) next

        num_plmns = hex2dec(substr($0, 9, 2))
        if (num_plmns < 1 || num_plmns > 15) next

        result = ""
        pos = 11
        for (p = 0; p < num_plmns && pos + 6 <= length($0); p++) {
            b1 = hex2dec(substr($0, pos, 2))
            b2 = hex2dec(substr($0, pos + 2, 2))
            b3 = hex2dec(substr($0, pos + 4, 2))

            mcc = sprintf("%d%d%d", b1 % 16, int(b1 / 16), b2 % 16)
            d6 = int(b2 / 16)
            if (d6 == 15) {
                mnc = sprintf("%d%d", b3 % 16, int(b3 / 16))
            } else {
                mnc = sprintf("%d%d%d", b3 % 16, int(b3 / 16), d6)
            }

            if (result != "") result = result ", "
            result = result mcc "-" mnc
            pos = pos + 6
        }
        print result
    }'
}

phase_1c_anqp_query() {
    LOG "=== PHASE 1C: ACTIVE ANQP QUERY ==="

    if [ ! -f "$UNIQUE_SSIDS_FILE" ] || [ ! -s "$UNIQUE_SSIDS_FILE" ]; then
        LOG "No SSIDs to query"
        return 1
    fi

    # Get PHY before switching modes (subshell scoping issue)
    SCAN_PHY=$(get_phy "$INTERFACE")
    if [ -z "$SCAN_PHY" ]; then
        SCAN_PHY=$(get_phy "${INTERFACE%mon}")
    fi

    # Need managed interface for wpa_supplicant
    local mgmt_iface=$(setup_managed_mode "$INTERFACE")

    # Setup wpa_supplicant
    if ! setup_wpa_supplicant "$mgmt_iface"; then
        LOG "Failed to setup wpa_supplicant"
        restore_monitor_mode "$mgmt_iface"
        return 1
    fi

    # Do a FULL scan - DFS channels require passive iw scan first
    LOG "  Scanning DFS channels (passive)..."
    local dfs_freqs="5260 5280 5300 5320 5500 5520 5540 5560 5580 5600 5620 5640 5660 5680 5700 5720"
    iw dev "$mgmt_iface" scan freq $dfs_freqs passive >/dev/null 2>&1
    sleep 3

    LOG "  Scanning 6GHz channels (passive)..."
    local ghz6_freqs="5975 6055 6135 6215 6295 6375 6455 6535 6615 6695 6775 6855 6935 7015"
    iw dev "$mgmt_iface" scan freq $ghz6_freqs passive >/dev/null 2>&1
    sleep 3

    # Trigger wpa_supplicant scan to populate its BSS cache
    LOG "  Performing full scan to populate BSS cache..."
    wpa_cli -p "$WPA_CTRL_IFACE" -i "$mgmt_iface" scan >/dev/null 2>&1
    sleep 8

    # Verify BSS cache has entries
    local bss_count=$(wpa_cli -p "$WPA_CTRL_IFACE" -i "$mgmt_iface" scan_results 2>/dev/null | wc -l)
    LOG "  Found $((bss_count - 1)) BSSes in cache"

    local ssid_count=$(wc -l < "$UNIQUE_SSIDS_FILE")
    local current=0

    # Process each unique SSID
    while IFS='|' read -r ssid channel bssid rssi rcoi ano count; do
        current=$((current + 1))

        LOG "[$current/$ssid_count] Querying: $ssid"

        # Check if this is an MBSSID network (non-transmitted BSSID)
        local query_bssid="$bssid"
        local is_mbssid=0
        if echo "$ano" | grep -q "^MBSSID:"; then
            is_mbssid=1
            # Extract the VAP (transmitted) BSSID for reference
            local vap_bssid=$(echo "$ano" | sed 's/^MBSSID://')
            LOG "  BSSID: $bssid (non-tx via MBSSID)"
            LOG "  VAP: $vap_bssid | Channel: $channel"
            LOG "  Note: ANQP not available for non-tx MBSSID"
            # Record basic info from beacon detection
            echo "ANQP_NOTE|$bssid|$ssid|MBSSID non-transmitted BSSID (ANQP N/A)" >> "$RESULTS_FILE"
        else
            LOG "  BSSID: $bssid | Channel: $channel"
            SPINNER ON
            query_anqp "$mgmt_iface" "$query_bssid" "$ssid" "$bssid" "$channel"
            SPINNER OFF
        fi

        LOG ""

    done < "$UNIQUE_SSIDS_FILE"

    # Cleanup
    cleanup_wpa_supplicant "$mgmt_iface"
    restore_monitor_mode "$mgmt_iface"

    return 0
}

# =============================================================================
# PHASE 1D: ANQP CAPTURE & PARSE
# =============================================================================
# Parses ANQP elements from captured GAS frames

# Simpler parser for pre-filtered GAS text output
parse_gas_text() {
    local gas_file="$1"
    local ssid="$2"
    local bssid="$3"
    local channel="$4"

    # Concatenate hex lines and extract ANQP data
    cat "$gas_file" | awk -v ssid="$ssid" -v outfile="$RESULTS_FILE" '
    BEGIN { hextable = "0123456789abcdef"; payload = ""; in_gas_frame = 0 }

    function hex2dec(h,    v, j, c) {
        v = 0
        for (j = 1; j <= length(h); j++) {
            c = tolower(substr(h, j, 1))
            v = v * 16 + index(hextable, c) - 1
        }
        return v
    }

    function hex2ascii(hex,    result, k, d) {
        result = ""
        for (k = 1; k <= length(hex); k += 2) {
            d = hex2dec(substr(hex, k, 2))
            if (d >= 32 && d <= 126) result = result sprintf("%c", d)
        }
        return result
    }

    # New frame header (any tcpdump timestamp line) - process previous GAS payload
    /^[0-9][0-9]:[0-9][0-9]:/ {
        if (payload != "" && in_gas_frame) process_payload()
        payload = ""
        # Check if this is a GAS frame (Act#11)
        if ($0 ~ /Act#11/) {
            in_gas_frame = 1
        } else {
            in_gas_frame = 0
        }
        next
    }

    # Accumulate hex payload only if in GAS frame
    /0x[0-9a-f]+:/ {
        if (in_gas_frame) {
            line = $0
            sub(/.*:/, "", line)
            gsub(/[ \t]/, "", line)
            payload = payload line
        }
    }

    function process_payload() {
        # Find ANQP marker (6c 02 XX 00)
        pos = index(payload, "6c020000")
        if (pos == 0) pos = index(payload, "6c027f00")
        if (pos == 0) return

        # Skip to response length (after marker)
        resp_start = pos + 8
        if (resp_start + 4 > length(payload)) return

        # Read response length (little endian)
        lo = hex2dec(substr(payload, resp_start, 2))
        hi = hex2dec(substr(payload, resp_start + 2, 2))
        resp_len = hi * 256 + lo

        # Parse ANQP elements
        elem_pos = resp_start + 4
        elem_end = elem_pos + (resp_len * 2)
        if (elem_end > length(payload)) elem_end = length(payload)

        while (elem_pos + 8 <= elem_end) {
            # Element ID (2 bytes LE)
            id_lo = hex2dec(substr(payload, elem_pos, 2))
            id_hi = hex2dec(substr(payload, elem_pos + 2, 2))
            elem_id = id_hi * 256 + id_lo

            # Element length (2 bytes LE)
            len_lo = hex2dec(substr(payload, elem_pos + 4, 2))
            len_hi = hex2dec(substr(payload, elem_pos + 6, 2))
            elem_len = len_hi * 256 + len_lo

            if (elem_len < 0 || elem_len > 500) break

            elem_data = substr(payload, elem_pos + 8, elem_len * 2)

            # Domain Name (268 / 0x010c)
            if (elem_id == 268) {
                domains = ""
                dpos = 1
                while (dpos < length(elem_data)) {
                    dlen = hex2dec(substr(elem_data, dpos, 2))
                    # Check: need dlen bytes starting at dpos+2, last pos is dpos+1+dlen*2
                    if (dlen < 1 || dpos + 1 + dlen * 2 > length(elem_data)) break
                    domain = hex2ascii(substr(elem_data, dpos + 2, dlen * 2))
                    if (length(domain) > 2) {
                        if (domains != "") domains = domains ", "
                        domains = domains domain
                    }
                    dpos = dpos + 2 + (dlen * 2)
                }
                if (domains != "") {
                    print "ANQP_DOMAIN|" ssid "|" domains >> outfile
                    print "  [Domains] " domains
                }
            }

            # NAI Realm (263 / 0x0107)
            if (elem_id == 263) {
                print "ANQP_NAI_REALM|" ssid "|found" >> outfile
                print "  [NAI Realm] present"
            }

            # 3GPP (264 / 0x0108)
            if (elem_id == 264 && elem_len > 3) {
                print "ANQP_3GPP|" ssid "|found" >> outfile
                print "  [3GPP/PLMN] present"
            }

            # HS2.0 Vendor (56797 / 0xdddd)
            if (elem_id == 56797 || elem_id == 221) {
                # Check for HS2.0 OUI (506f9a11)
                if (index(elem_data, "506f9a11") > 0) {
                    # Subtype 3 = Operator Name
                    if (index(elem_data, "506f9a1103") > 0) {
                        name_start = index(elem_data, "506f9a1103") + 10
                        if (name_start + 4 < length(elem_data)) {
                            name_len = hex2dec(substr(elem_data, name_start, 2))
                            lang = hex2ascii(substr(elem_data, name_start + 2, 6))
                            opname = hex2ascii(substr(elem_data, name_start + 8, (name_len - 3) * 2))
                            print "ANQP_OPERATOR|" ssid "|" opname >> outfile
                            print "  [Operator] " opname
                        }
                    }
                }
            }

            elem_pos = elem_pos + 8 + (elem_len * 2)
        }
    }

    END { if (payload != "" && in_gas_frame) process_payload() }
    '
}

parse_anqp_capture() {
    local pcap_file="$1"
    local ssid="$2"
    local bssid="$3"
    local channel="$4"

    LOG "  Parsing ANQP data..."

    # Extract hex dump of GAS frames and parse ANQP elements
    tcpdump -r "$pcap_file" -x -n 2>/dev/null | \
    awk -v ssid="$ssid" -v bssid="$bssid" -v channel="$channel" -v outfile="$RESULTS_FILE" '
    BEGIN {
        hextable = "0123456789abcdef"
        found_anqp = 0
    }

    /Action/ {
        if (payload != "") {
            parse_gas_frame(payload, ssid, bssid, channel)
        }
        header = $0
        payload = ""
    }

    /0x[0-9a-f]+:/ {
        line = $0
        sub(/.*:/, "", line)
        gsub(/[ \t]/, "", line)
        payload = payload line
    }

    function hex2dec(h,    v, j, ch) {
        v = 0
        for (j=1; j<=length(h); j++) {
            ch = tolower(substr(h, j, 1))
            v = v * 16 + index(hextable, ch) - 1
        }
        return v
    }

    function hex2ascii(h,    result, k, d) {
        result = ""
        for (k=1; k<=length(h); k+=2) {
            d = hex2dec(substr(h, k, 2))
            if (d >= 32 && d <= 126) {
                result = result sprintf("%c", d)
            } else {
                result = result "."
            }
        }
        return result
    }

    function parse_gas_frame(pyld, net_ssid, net_bssid, net_channel) {
        # GAS frame structure:
        # Category (1 byte): 0x04 = Public Action
        # Action (1 byte): 0x0b = GAS Initial Response / 0x0d = Comeback Response
        # Dialog Token (1 byte)
        # Status Code (2 bytes)
        # GAS Comeback Delay (2 bytes)
        # Advertisement Protocol IE (variable: 6c 02 00 00 = ANQP)
        # Query Response Length (2 bytes, LE)
        # Query Response (ANQP elements)

        if (length(pyld) < 40) return

        # Find GAS Initial Response (04 0b) or Comeback Response (04 0d)
        gas_pos = index(pyld, "040b")
        if (gas_pos == 0) gas_pos = index(pyld, "040d")
        if (gas_pos == 0) return

        found_anqp = 1

        # Skip: Category(1) + Action(1) + Dialog(1) + Status(2) + Delay(2) = 7 bytes = 14 hex
        # Then find Advertisement Protocol IE (6c 02 XX 00) for ANQP
        # The XX byte can be 00 or 7f (with query response limit bit)
        anqp_marker = index(pyld, "6c020000")
        if (anqp_marker == 0) anqp_marker = index(pyld, "6c027f00")
        if (anqp_marker == 0) {
            # Try alternate: 6c 02 (just the element ID and length)
            anqp_marker = index(pyld, "6c0200")
        }
        if (anqp_marker == 0) return

        # After 6c020000 comes Query Response Length (2 bytes LE)
        resp_start = anqp_marker + 8  # Skip 6c020000
        if (resp_start + 4 > length(pyld)) return

        resp_len_hex = substr(pyld, resp_start, 4)
        resp_len = hex2dec(substr(resp_len_hex, 3, 2) substr(resp_len_hex, 1, 2))

        if (resp_len < 4 || resp_len > 2000) return

        # ANQP elements start after length field
        elem_pos = resp_start + 4
        elem_end = elem_pos + (resp_len * 2)
        if (elem_end > length(pyld)) elem_end = length(pyld)

        # Iterate through ANQP elements
        while (elem_pos + 8 <= elem_end) {
            # Element ID (2 bytes, LE)
            elem_id_hex = substr(pyld, elem_pos, 4)
            elem_id = hex2dec(substr(elem_id_hex, 3, 2) substr(elem_id_hex, 1, 2))

            # Element Length (2 bytes, LE)
            elem_len_hex = substr(pyld, elem_pos + 4, 4)
            elem_len = hex2dec(substr(elem_len_hex, 3, 2) substr(elem_len_hex, 1, 2))

            if (elem_len < 0 || elem_len > 1000) break

            # Element Data starts at elem_pos + 8
            elem_data_start = elem_pos + 8
            elem_data = substr(pyld, elem_data_start, elem_len * 2)

            # Parse based on element ID
            if (elem_id == 258) {
                # Venue Name (0x0102)
                parse_venue_name_data(elem_data, elem_len, net_ssid, outfile)
            } else if (elem_id == 263) {
                # NAI Realm List (0x0107)
                parse_nai_realm_data(elem_data, elem_len, net_ssid, outfile)
            } else if (elem_id == 264) {
                # 3GPP Cellular (0x0108)
                parse_3gpp_data(elem_data, elem_len, net_ssid, outfile)
            } else if (elem_id == 268) {
                # Domain Name List (0x010c)
                parse_domain_data(elem_data, elem_len, net_ssid, outfile)
            } else if (elem_id == 277) {
                # Venue URL (0x0115)
                parse_venue_url_data(elem_data, elem_len, net_ssid, outfile)
            } else if (elem_id == 56797) {
                # HS2.0 Vendor Specific (0xdddd)
                parse_hs20_data(elem_data, elem_len, net_ssid, outfile)
            }

            # Move to next element
            elem_pos = elem_pos + 8 + (elem_len * 2)
        }
    }

    # Parse Venue Name element data (ID 258)
    function parse_venue_name_data(data, len, net_ssid, outfile) {
        if (len < 2) return

        venue_group = hex2dec(substr(data, 1, 2))
        venue_type = hex2dec(substr(data, 3, 2))

        # Venue Group names (802.11-2016 Table 9-62)
        group_names[0] = "Unspecified"
        group_names[1] = "Assembly"
        group_names[2] = "Business"
        group_names[3] = "Educational"
        group_names[4] = "Factory"
        group_names[5] = "Institutional"
        group_names[6] = "Mercantile"
        group_names[7] = "Residential"
        group_names[8] = "Storage"
        group_names[9] = "Utility"
        group_names[10] = "Vehicular"
        group_names[11] = "Outdoor"

        group_str = (venue_group in group_names) ? group_names[venue_group] : "Unknown"
        venue_info = group_str " (type " venue_type ")"

        # Parse venue name duples if present
        if (len > 2) {
            duple_pos = 5  # After group(1) + type(1) = 4 hex chars
            while (duple_pos + 2 <= length(data)) {
                duple_len = hex2dec(substr(data, duple_pos, 2))
                if (duple_len < 4 || duple_pos + 2 + duple_len * 2 > length(data)) break

                # Language (3 bytes)
                lang = hex2ascii(substr(data, duple_pos + 2, 6))
                # Name
                name = hex2ascii(substr(data, duple_pos + 8, (duple_len - 3) * 2))
                gsub(/[^a-zA-Z0-9 .-]/, "", name)

                if (length(name) > 1) {
                    venue_info = venue_info " [" lang "] " name
                }
                duple_pos = duple_pos + 2 + (duple_len * 2)
            }
        }

        print "ANQP_VENUE|" net_ssid "|" venue_info >> outfile
        print "  [Venue] " venue_info
    }

    # Parse NAI Realm data (ID 263)
    function parse_nai_realm_data(data, len, net_ssid, outfile) {
        if (len < 4) return

        # NAI Realm Count (2 bytes LE)
        realm_count = hex2dec(substr(data, 3, 2) substr(data, 1, 2))
        if (realm_count < 1 || realm_count > 20) return

        realms = ""
        pos = 5  # After count (4 hex chars)

        for (r = 0; r < realm_count && pos < length(data); r++) {
            # Realm data field length (2 bytes LE)
            if (pos + 4 > length(data)) break
            field_len = hex2dec(substr(data, pos + 2, 2) substr(data, pos, 2))
            if (field_len < 2) break

            # Skip encoding (1 byte)
            # Realm length (1 byte)
            if (pos + 6 > length(data)) break
            realm_len = hex2dec(substr(data, pos + 6, 2))

            # Realm string
            if (realm_len > 0 && pos + 8 + realm_len * 2 <= length(data)) {
                realm = hex2ascii(substr(data, pos + 8, realm_len * 2))
                gsub(/[^a-zA-Z0-9.-]/, "", realm)
                if (length(realm) > 2) {
                    if (realms != "") realms = realms ", "
                    realms = realms realm
                }
            }

            pos = pos + 4 + (field_len * 2)
        }

        if (realms != "") {
            print "ANQP_NAI_REALM|" net_ssid "|" realms >> outfile
            print "  [NAI Realms] " realms
        }
    }

    # Parse 3GPP Cellular data (ID 264)
    function parse_3gpp_data(data, len, net_ssid, outfile) {
        if (len < 6) return

        # GUD (1 byte), UDHL (1 byte), IEI (1 byte), PLMN len (1 byte), Num PLMNs (1 byte)
        gud = hex2dec(substr(data, 1, 2))
        udhl = hex2dec(substr(data, 3, 2))
        iei = hex2dec(substr(data, 5, 2))

        if (iei != 0) return  # Not a PLMN list

        plmn_len = hex2dec(substr(data, 7, 2))
        num_plmns = hex2dec(substr(data, 9, 2))

        if (num_plmns < 1 || num_plmns > 15) return

        plmn_list = ""
        plmn_pos = 11  # After header (10 hex chars)

        for (p = 0; p < num_plmns && plmn_pos + 6 <= length(data); p++) {
            # 3 bytes BCD encoded MCC/MNC
            b1 = hex2dec(substr(data, plmn_pos, 2))
            b2 = hex2dec(substr(data, plmn_pos + 2, 2))
            b3 = hex2dec(substr(data, plmn_pos + 4, 2))

            # Decode: MCC = d1d2d3, MNC = d4d5[d6]
            # b1 = d2d1, b2 = d6d3 (d6=F for 2-digit MNC), b3 = d5d4
            # Using modulo/division instead of bitwise ops for busybox awk compatibility
            d1 = b1 % 16
            d2 = int(b1 / 16)
            d3 = b2 % 16
            d6 = int(b2 / 16)
            d4 = b3 % 16
            d5 = int(b3 / 16)

            mcc = sprintf("%d%d%d", d1, d2, d3)

            if (d6 == 15) {
                # 2-digit MNC
                mnc = sprintf("%d%d", d4, d5)
            } else {
                # 3-digit MNC
                mnc = sprintf("%d%d%d", d4, d5, d6)
            }

            if (plmn_list != "") plmn_list = plmn_list ", "
            plmn_list = plmn_list mcc "-" mnc

            plmn_pos = plmn_pos + 6
        }

        if (plmn_list != "") {
            print "ANQP_3GPP|" net_ssid "|" plmn_list >> outfile
            print "  [PLMNs] " plmn_list
        }
    }

    # Parse Domain Name data (ID 268)
    function parse_domain_data(data, len, net_ssid, outfile) {
        if (len < 2) return

        domains = ""
        pos = 1

        while (pos + 2 <= length(data)) {
            domain_len = hex2dec(substr(data, pos, 2))
            if (domain_len < 1 || pos + 2 + domain_len * 2 > length(data)) break

            domain = hex2ascii(substr(data, pos + 2, domain_len * 2))
            gsub(/[^a-zA-Z0-9.-]/, "", domain)

            if (length(domain) > 2) {
                if (domains != "") domains = domains ", "
                domains = domains domain
            }

            pos = pos + 2 + (domain_len * 2)
        }

        if (domains != "") {
            print "ANQP_DOMAIN|" net_ssid "|" domains >> outfile
            print "  [Domains] " domains
        }
    }

    # Parse Venue URL data (ID 277)
    function parse_venue_url_data(data, len, net_ssid, outfile) {
        if (len < 3) return

        urls = ""
        pos = 1

        while (pos + 2 <= length(data)) {
            url_len = hex2dec(substr(data, pos, 2))
            if (url_len < 2 || pos + 2 + url_len * 2 > length(data)) break

            # Venue number (1 byte) then URL
            url = hex2ascii(substr(data, pos + 4, (url_len - 1) * 2))

            if (url ~ /http/) {
                if (urls != "") urls = urls ", "
                urls = urls url
            }

            pos = pos + 2 + (url_len * 2)
        }

        if (urls != "") {
            print "ANQP_VENUE_URL|" net_ssid "|" urls >> outfile
            print "  [Venue URLs] " urls
        }
    }

    # Parse HS2.0 vendor-specific data (ID 56797 = 0xDDDD)
    function parse_hs20_data(data, len, net_ssid, outfile) {
        if (len < 6) return

        # OUI (3 bytes) + WFA Subtype (1 byte) + Subtype (1 byte)
        oui = substr(data, 1, 6)
        if (oui != "506f9a") return  # Wi-Fi Alliance OUI

        wfa_subtype = hex2dec(substr(data, 7, 2))
        if (wfa_subtype != 17) return  # HS2.0 ANQP = 0x11

        hs_subtype = hex2dec(substr(data, 9, 2))

        if (hs_subtype == 3) {
            # Operator Friendly Name
            # Skip reserved (1 byte)
            name_pos = 13
            names = ""

            while (name_pos + 2 <= length(data)) {
                name_len = hex2dec(substr(data, name_pos, 2))
                if (name_len < 4 || name_pos + 2 + name_len * 2 > length(data)) break

                lang = hex2ascii(substr(data, name_pos + 2, 6))
                name = hex2ascii(substr(data, name_pos + 8, (name_len - 3) * 2))
                gsub(/[^a-zA-Z0-9 .-]/, "", name)

                if (length(name) > 1) {
                    if (names != "") names = names ", "
                    names = names "[" lang "] " name
                }

                name_pos = name_pos + 2 + (name_len * 2)
            }

            if (names != "") {
                print "ANQP_OPERATOR|" net_ssid "|" names >> outfile
                print "  [Operator] " names
            }
        }
    }

    END {
        if (payload != "") {
            parse_gas_frame(payload, ssid, bssid, channel)
        }
        if (found_anqp == 0) {
            print "  No ANQP data found in capture"
        }
    }'
}

# =============================================================================
# RESULTS SUMMARY
# =============================================================================

show_results_summary() {
    LOG ""
    LOG "=== SCAN COMPLETE ==="
    LOG ""

    if [ ! -f "$RESULTS_FILE" ] || [ ! -s "$RESULTS_FILE" ]; then
        LOG "No ANQP data captured"
        LOG "Results saved to: $LOOT_DIR"
        return
    fi

    # Count unique APs with ANQP data
    local ap_count=$(cut -d'|' -f2 "$RESULTS_FILE" 2>/dev/null | sort -u | wc -l)

    # Count different ANQP element types (grep -c returns 1 on no match, so handle it)
    local nai_count=$(grep -c "^ANQP_NAI_REALM" "$RESULTS_FILE" 2>/dev/null); nai_count=${nai_count:-0}
    local gpp_count=$(grep -c "^ANQP_3GPP" "$RESULTS_FILE" 2>/dev/null); gpp_count=${gpp_count:-0}
    local domain_count=$(grep -c "^ANQP_DOMAIN" "$RESULTS_FILE" 2>/dev/null); domain_count=${domain_count:-0}
    local venue_count=$(grep -c "^ANQP_VENUE[^_]" "$RESULTS_FILE" 2>/dev/null); venue_count=${venue_count:-0}
    local url_count=$(grep -c "^ANQP_VENUE_URL" "$RESULTS_FILE" 2>/dev/null); url_count=${url_count:-0}
    local op_count=$(grep -c "^ANQP_OPERATOR" "$RESULTS_FILE" 2>/dev/null); op_count=${op_count:-0}

    local rcoi_count=$(grep -c "^ANQP_RCOI" "$RESULTS_FILE" 2>/dev/null); rcoi_count=${rcoi_count:-0}
    local beacon_rcoi_count=$(grep -c "^BEACON_RCOI" "$RESULTS_FILE" 2>/dev/null); beacon_rcoi_count=${beacon_rcoi_count:-0}

    if $ANQP_AVAILABLE; then
        LOG "ANQP Data from $ap_count APs:"
        LOG "  RCOI:          $rcoi_count"
        LOG "  Venue Info:    $venue_count"
        LOG "  Operator:      $op_count"
        LOG "  NAI Realms:    $nai_count"
        LOG "  3GPP PLMNs:    $gpp_count"
        LOG "  Domain Names:  $domain_count"
        LOG "  Venue URLs:    $url_count"
    else
        LOG "Beacon Data from $ap_count APs:"
        LOG "  Beacon RCOIs:  $beacon_rcoi_count"
        LOG ""
        LOG "(Install wpad for"
        LOG " full ANQP data)"
    fi
    LOG ""
    LOG "Results: $RESULTS_FILE"

    ALERT "Scan complete! Check loot."
}

# =============================================================================
# USER INTERFACE
# =============================================================================

show_config_menu() {
    LOG "PASSPOINT SCANNER"
    LOG "================="
    LOG ""

    if $ANQP_AVAILABLE; then
        LOG "Mode: FULL (Beacon + ANQP)"
        LOG "  - Detect Passpoint APs"
        LOG "  - Query ANQP data"
        LOG "  - Decode RCOIs & PLMNs"
        LOG ""
        LOG "[A] Start Scan"
        LOG "[B] Exit"
    else
        LOG "Mode: BEACON ONLY"
        LOG "(wpad missing)"
        LOG ""
        LOG "Without ANQP support:"
        LOG "  + Detect Passpoint APs"
        LOG "  + Read beacon RCOIs (up to 3)"
        LOG "  - No domain names"
        LOG "  - No NAI realms"
        LOG "  - No PLMN/carrier info"
        LOG "  - No venue/operator info"
        LOG ""
        LOG "[A] Start Beacon-Only Scan"
        LOG "[B] Exit"
        LOG "[>] Install wpad"
    fi
    LOG ""
}

configure_scan() {
    # Check dependencies first
    check_dependencies

    while true; do
        show_config_menu

        local btn=$(WAIT_FOR_INPUT)

        if $ANQP_AVAILABLE; then
            case "$btn" in
                A)
                    return 0
                    ;;
                B)
                    LOG "Goodbye"
                    exit 0
                    ;;
            esac
        else
            case "$btn" in
                A)
                    # Beacon-only scan
                    return 0
                    ;;
                B)
                    LOG "Goodbye"
                    exit 0
                    ;;
                R|RIGHT|">")
                    # Try to install
                    if install_wpa_supplicant; then
                        check_dependencies
                    fi
                    ;;
            esac
        fi
    done
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

LOG "=============================="
LOG "   PASSPOINT SCANNER v1.0"
LOG "=============================="
LOG ""
LOG "Passive 802.11u/Hotspot 2.0"
LOG "reconnaissance tool"
LOG ""
LOG "Interface: $INTERFACE"
LOG ""

# Configuration menu
configure_scan

# Execute all phases
LOG ""

# Phase 1A: Beacon Scan
if ! phase_1a_beacon_scan; then
    LOG "Scan failed - no Passpoint APs"
    exit 1
fi

# Phase 1B: Group SSIDs
if ! phase_1b_group_ssids; then
    LOG "Grouping failed"
    exit 1
fi

# Phase 1C: Active ANQP Query via wpa_supplicant (if available)
if $ANQP_AVAILABLE; then
    LOG "Querying ANQP data (~15s/network)..."
    phase_1c_anqp_query
else
    LOG ""
    LOG "=== BEACON-ONLY MODE ==="
    LOG "Skipping ANQP queries (wpad not installed)"
    LOG ""
    # In beacon-only mode, decode and display beacon RCOIs
    if [ -f "$UNIQUE_SSIDS_FILE" ]; then
        LOG "Decoding beacon RCOIs..."
        while IFS='|' read -r ssid channel bssid rssi rcoi ano count; do
            if [ -n "$rcoi" ] && [ "$rcoi" != "N/A" ]; then
                # Parse and decode the beacon RCOI
                parsed_rcois=$(parse_beacon_rcoi "$rcoi")
                if [ -n "$parsed_rcois" ]; then
                    decoded_list=""
                    IFS_OLD="$IFS"
                    IFS=','
                    for oi in $parsed_rcois; do
                        oi=$(echo "$oi" | tr -d ' ')
                        decoded=$(decode_rcoi "$oi")
                        [ -n "$decoded_list" ] && decoded_list="$decoded_list; "
                        decoded_list="$decoded_list$decoded"
                    done
                    IFS="$IFS_OLD"
                    if [ -n "$decoded_list" ]; then
                        LOG "  $ssid: $decoded_list"
                        echo "BEACON_RCOI|$bssid|$ssid|$decoded_list" >> "$RESULTS_FILE"
                    fi
                fi
            fi
        done < "$UNIQUE_SSIDS_FILE"
    fi
fi

# Show results
show_results_summary

LOG ""
LOG "[A] View Details [B] Exit"

btn=$(WAIT_FOR_INPUT)
if [ "$btn" = "A" ]; then
    # Display detailed results grouped by AP
    if [ -f "$RESULTS_FILE" ] && [ -s "$RESULTS_FILE" ]; then
        LOG ""
        LOG "=== DETAILED RESULTS ==="
        LOG "(Grouped by AP)"
        LOG ""

        # Get unique BSSIDs from results
        bssids=$(cut -d'|' -f2 "$RESULTS_FILE" | sort -u)

        for bssid in $bssids; do
            # Get SSID for this BSSID from the results
            ssid=$(grep "|$bssid|" "$RESULTS_FILE" | head -1 | cut -d'|' -f3)

            # Get channel/RSSI from discovered APs file if available
            ap_info=""
            if [ -f "$PASSPOINT_APS_FILE" ]; then
                ap_info=$(grep "^$bssid|" "$PASSPOINT_APS_FILE" | head -1)
            fi
            channel=$(echo "$ap_info" | cut -d'|' -f3)
            rssi=$(echo "$ap_info" | cut -d'|' -f4)

            LOG "----------------------------"
            LOG "AP: $ssid"
            LOG "BSSID: $bssid"
            [ -n "$channel" ] && LOG "Channel: $channel | RSSI: ${rssi}dBm"
            LOG ""

            # Show all ANQP data for this BSSID
            grep "|$bssid|" "$RESULTS_FILE" | while IFS='|' read -r type b s data; do
                case "$type" in
                    ANQP_RCOI|BEACON_RCOI)
                        LOG "  RCOI: $data"
                        ;;
                    ANQP_VENUE)
                        LOG "  Venue: $data"
                        ;;
                    ANQP_OPERATOR)
                        LOG "  Operator: $data"
                        ;;
                    ANQP_NAI_REALM)
                        LOG "  NAI Realms: $data"
                        ;;
                    ANQP_3GPP)
                        LOG "  PLMNs: $data"
                        ;;
                    ANQP_DOMAIN)
                        LOG "  Domains: $data"
                        ;;
                    ANQP_VENUE_URL)
                        LOG "  Venue URLs: $data"
                        ;;
                    ANQP_NOTE)
                        LOG "  Note: $data"
                        ;;
                esac
            done
            LOG ""
        done
    else
        LOG "No ANQP data to display"
    fi

    # Show any discovered APs without ANQP data
    if [ -f "$PASSPOINT_APS_FILE" ]; then
        # Find BSSIDs that have no ANQP results
        no_anqp_aps=""
        while IFS='|' read -r bssid ssid channel rssi rcoi ano; do
            if [ -f "$RESULTS_FILE" ]; then
                if ! grep -q "|$bssid|" "$RESULTS_FILE" 2>/dev/null; then
                    no_anqp_aps="$no_anqp_aps$bssid|$ssid|$channel|$rssi\n"
                fi
            else
                no_anqp_aps="$no_anqp_aps$bssid|$ssid|$channel|$rssi\n"
            fi
        done < "$PASSPOINT_APS_FILE"

        if [ -n "$no_anqp_aps" ]; then
            LOG "=== APs WITHOUT ANQP DATA ==="
            printf "%b" "$no_anqp_aps" | while IFS='|' read -r bssid ssid channel rssi; do
                [ -n "$bssid" ] && LOG "$bssid | $ssid | Ch$channel | ${rssi}dBm"
            done
        fi
    fi
fi

LOG ""
LOG "Scan complete"
exit 0
