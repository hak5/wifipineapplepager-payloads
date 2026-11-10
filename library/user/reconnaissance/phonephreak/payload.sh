#!/bin/bash
# Title: PHONEPHREAK - Phone Number OSINT
# Description: PhoneInfoga-style phone number recon: E.164 parse/validate, country + line-type analysis, format variants, investigation link pack, optional web footprint check.
# Author: sinXne0
# Version: 1.0.0
# Category: user/reconnaissance
# Firmware: 2.0.0-stable or newer
# Requires: python3-light (python3-openssl for the online footprint check)
#
# PHONEPHREAK turns a phone number into an OSINT report, fully offline:
#   - validates and normalizes to E.164
#   - country + timezone from the calling code
#   - line-type detection (mobile/landline/VoIP/toll-free/premium) for the
#     NANP, UK, DE, FR, ES, IT, NL, IN, AU, JP, BR, CN, RU and more
#   - format variants (E.164 / international / national / tel: URI)
#   - investigation link pack (WhatsApp, Telegram, search dorks, Truecaller,
#     sync.me, carrier lookup)
#   - optional exact-match web footprint check via DuckDuckGo (online mode)
#
# Reports are saved to /root/loot/phonephreak/ as .txt and .json.
#
# Legal: OSINT on phone numbers queries public data only. Investigate
# numbers you are authorized to research and follow applicable law.
#
# LED States
#   Blue solid   - working
#   Green solid  - lookup complete
#   Amber        - invalid number / offline
#   White        - idle

# === CONFIGURATION ===
LOOTDIR="${PHONEPHREAK_LOOT:-/root/loot/phonephreak}"

# === PATHS ===
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd)"
PAYLOAD_DIR=""
for candidate in "$SCRIPT_DIR" \
                 "/root/payloads/user/reconnaissance/phonephreak" \
                 "/mmc/root/payloads/user/reconnaissance/phonephreak"; do
    if [ -f "$candidate/phonephreak.py" ]; then
        PAYLOAD_DIR="$candidate"
        break
    fi
done

ENGINE="$PAYLOAD_DIR/phonephreak.py"
RUNLOG="/tmp/phonephreak_run.log"

# === CLEANUP ===
cleanup() {
    rm -f "$RUNLOG"
    LED WHITE 2>/dev/null
}
trap cleanup EXIT INT TERM

# === UI HELPERS ===
confirmed() {
    [ "$1" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || [ "$1" = "true" ]
}

play_done() { RINGTONE "done:d=4,o=5,b=180:c6,e6,g6,c7" & }
play_fail() { RINGTONE "fail:d=4,o=4,b=120:g,e,c" & }

# === DEPENDENCIES ===
# The Pager's opkg has `install`/`remove` disabled. install_pkg.py installs
# packages via `opkg download` + python tarfile instead, resolving deps.
run_installer() {
    python3 "$PAYLOAD_DIR/install_pkg.py" "$@"
}

ensure_python() {
    if command -v python3 >/dev/null 2>&1; then
        return 0
    fi

    LOG "yellow" "python3 is not installed."
    resp=$(CONFIRMATION_DIALOG "Install python3-light now? (~3 MB)")
    confirmed "$resp" || return 1

    LOG "cyan" "Updating package lists..."
    opkg update >/dev/null 2>&1
    # opkg install is disabled on Pager firmware; try it first as a best
    # effort, then fall back to the shipped installer.
    if opkg install python3-light >/tmp/phonephreak_opkg.log 2>&1 && \
       command -v python3 >/dev/null 2>&1; then
        LOG "green" "python3-light installed."
        return 0
    fi
    if run_installer python3-light >/tmp/phonephreak_opkg.log 2>&1 && \
       command -v python3 >/dev/null 2>&1; then
        LOG "green" "python3-light installed."
        return 0
    fi

    LOG "red" "Install failed. See /tmp/phonephreak_opkg.log"
    ALERT "python3-light install failed.\n\nIf python3 is present but incomplete, run:\npython3 install_pkg.py python3-light\n\nOtherwise install python3-light via the Pager Portal or Cloud C2."
    return 1
}

ensure_online_deps() {
    # The online footprint check needs the `ssl` module (python3-openssl).
    if python3 -c "import ssl" >/dev/null 2>&1; then
        return 0
    fi
    LOG "yellow" "python3-openssl (ssl module) is missing for the online check."
    resp=$(CONFIRMATION_DIALOG "Install python3-openssl now?\n\nNeeded for the online footprint check.")
    confirmed "$resp" || return 1
    LED BLUE
    LOG "cyan" "Installing python3-openssl..."
    run_installer python3-openssl
    if python3 -c "import ssl" >/dev/null 2>&1; then
        LOG "green" "python3-openssl installed."
        return 0
    fi
    LOG "red" "python3-openssl install failed."
    ALERT "Could not install python3-openssl.\n\nRun manually:\npython3 install_pkg.py python3-openssl"
    return 1
}

# === LOOKUP ===
run_lookup() {
    local number resp rc

    number=$(TEXT_PICKER "Phone number (+CC...)" "+1 ")
    [ -z "$number" ] && return

    mkdir -p "$LOOTDIR"
    LED BLUE
    LOG ""
    LOG "cyan" "Analyzing $number ..."
    : > "$RUNLOG"
    python3 "$ENGINE" "$number" --loot "$LOOTDIR" > "$RUNLOG" 2>&1
    rc=$?

    if [ $rc -ne 0 ]; then
        LED AMBER
        play_fail
        LOG "yellow" "$(tail -n 1 "$RUNLOG")"
        ALERT "Lookup failed.\n\n$(tail -n 2 "$RUNLOG")"
        return
    fi

    # Show the key fields on screen
    grep -E "^(valid|country|timezone|line type|carrier|nsn)" "$RUNLOG" | \
    while IFS= read -r line; do
        LOG "  $line"
    done

    LED GREEN
    play_done

    resp=$(CONFIRMATION_DIALOG "Run online footprint check?\n\nExact-match web search via DuckDuckGo (needs internet + python3-openssl).")
    if confirmed "$resp"; then
        ensure_online_deps || { LED AMBER; LOG "yellow" "Online check skipped."; return; }
        LED BLUE
        LOG "cyan" "Online footprint check..."
        : > "$RUNLOG"
        python3 "$ENGINE" "$number" --loot "$LOOTDIR" --online > "$RUNLOG" 2>&1
        if [ $? -eq 0 ]; then
            grep -A 3 "online footprint" "$RUNLOG" | while IFS= read -r line; do
                LOG "  $line"
            done
        else
            LOG "yellow" "$(tail -n 1 "$RUNLOG")"
        fi
        LED GREEN
    fi

    resp=$(CONFIRMATION_DIALOG "Show QR for the WhatsApp link?\n\nScan it with a phone to open wa.me.")
    if confirmed "$resp"; then
        local e164
        e164=$(grep "^  e164" "$RUNLOG" | awk '{print $NF}')
        [ -n "$e164" ] && PROMPT_QR "https://wa.me/${e164#+}" "WhatsApp link for $e164"
    fi

    ALERT "PHONEPHREAK report saved\n\n$(grep '^report:' "$RUNLOG" | awk '{print $2}')"
}

# === BULK ===
run_bulk() {
    local path spinner rc
    path=$(TEXT_PICKER "File with one number per line" "$LOOTDIR/numbers.txt")
    [ -z "$path" ] && return

    if [ ! -f "$path" ]; then
        ALERT "File not found:\n$path\n\nCreate it first (one number per line)."
        return
    fi

    mkdir -p "$LOOTDIR"
    LED BLUE
    spinner=$(START_SPINNER "Bulk lookup running...")
    : > "$RUNLOG"
    python3 "$ENGINE" --bulk "$path" --loot "$LOOTDIR" > "$RUNLOG" 2>&1
    rc=$?
    STOP_SPINNER "$spinner" >/dev/null 2>&1

    if [ $rc -ne 0 ]; then
        LED AMBER
        play_fail
        ALERT "Bulk lookup failed.\n\n$(tail -n 2 "$RUNLOG")"
        return
    fi

    LED GREEN
    play_done
    LOG ""
    tail -n 6 "$RUNLOG" | while IFS= read -r line; do
        [ -n "$line" ] && LOG "  $line"
    done
    ALERT "Bulk lookup complete.\n\n$(tail -n 1 "$RUNLOG")"
}

# === ABOUT ===
show_about() {
    LOG ""
    LOG "cyan" "PHONEPHREAK v1.0.0"
    LOG ""
    LOG "Phone number OSINT, PhoneInfoga-style."
    LOG ""
    LOG "Offline per number:"
    LOG "  - E.164 validate + normalize"
    LOG "  - country / timezone"
    LOG "  - line type (mobile, landline,"
    LOG "    VoIP, toll-free, premium)"
    LOG "  - format variants"
    LOG "  - investigation link pack"
    LOG ""
    LOG "Online (optional): exact-match web"
    LOG "footprint via DuckDuckGo."
    LOG ""
    LOG "Reports: $LOOTDIR"
    LOG ""
    LOG "yellow" "Research only numbers you are"
    LOG "yellow" "authorized to investigate."
    LOG ""
    WAIT_FOR_INPUT
}

# === MAIN ===
LED WHITE 2>/dev/null
LOG ""
LOG "magenta" "=============================================="
LOG "magenta" "  PHONEPHREAK - Phone Number OSINT v1.0.0"
LOG "magenta" "=============================================="
LOG ""
LOG "Passive OSINT. Investigate only numbers"
LOG "you are authorized to research."
LOG ""

resp=$(CONFIRMATION_DIALOG "I will only research numbers I am authorized to investigate.")
case $? in
    "${DUCKYSCRIPT_REJECTED:-__rejected}"|"${DUCKYSCRIPT_ERROR:-__error}")
        exit 1 ;;
esac
confirmed "$resp" || { LOG "yellow" "Not confirmed. Exiting."; exit 1; }

if [ -z "$PAYLOAD_DIR" ] || [ ! -f "$ENGINE" ]; then
    LED RED 2>/dev/null
    ALERT "phonephreak.py not found.\n\nExpected next to payload.sh or in /root/payloads/user/reconnaissance/phonephreak"
    exit 1
fi

if ! ensure_python; then
    LED RED 2>/dev/null
    exit 1
fi

mkdir -p "$LOOTDIR"

while true; do
    choice=$(LIST_PICKER "PHONEPHREAK" \
        "Lookup a number" \
        "Bulk from file" \
        "About / legal" \
        "Exit")

    [ -z "$choice" ] && break

    case "$choice" in
        "Lookup"*) run_lookup ;;
        "Bulk"*)   run_bulk ;;
        "About"*)  show_about ;;
        "Exit")    break ;;
        *)         LOG "yellow" "Unknown selection: $choice" ;;
    esac
    LED WHITE 2>/dev/null
done

LOG ""
LOG "green" "PHONEPHREAK exiting."
LED WHITE 2>/dev/null
exit 0
