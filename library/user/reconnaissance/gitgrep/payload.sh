#!/bin/bash
# Title: GITGREP - GitHub Secret Hunter
# Description: Read-only secret hunter for GitHub users/orgs/repos and local git history. Finds committed AWS, cloud, API, webhook and private keys, then writes a masked, deduplicated report with secret-reuse detection.
# Author: sinXne0
# Version: 1.1.0
# Category: user/reconnaissance
# Firmware: 2.0.0-stable or newer
# Requires: python3-light, curl (git + git-http for history mode)
#
# GITGREP hunts for credentials that were committed by mistake.
#
#   - GitHub user, organisation or single repository
#   - local folder or local git history (added lines only)
#   - 35+ detectors: AWS, GCP, Azure, GitHub/GitLab, Slack, Discord,
#     Stripe, SendGrid, Mailgun, Mailchimp, Twilio, Telegram, npm, PyPI,
#     OpenAI, Anthropic, HuggingFace, DigitalOcean, Shopify, Postman,
#     New Relic, Grafana, Vault, age, JWT, basic-auth URLs, private keys
#     and a high-entropy generic assignment rule
#   - placeholder filtering so "your_api_key_here" and friends are ignored
#   - secrets are MASKED in the report by default
#   - re-used secrets (same value in several files) are grouped
#
# Reports are saved to /root/loot/gitgrep/ as .txt, .json, .csv and a
# short .preview.txt for the Pager screen.
#
# Legal: read-only OSINT. Scan repositories you own or are authorised to
# assess, and follow the platform terms and applicable law.
#
# LED States
#   Blue solid   - scanning
#   Green solid  - scan complete
#   Amber        - nothing found / cancelled
#   Red          - error
#   White        - idle

# === CONFIGURATION ===
LOOTDIR="${GITGREP_LOOT:-/root/loot/gitgrep}"
TOKEN_FILE="$LOOTDIR/.token"

# === PATHS ===
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd)"
PAYLOAD_DIR=""
for candidate in "$SCRIPT_DIR" \
                 "/root/payloads/user/reconnaissance/gitgrep" \
                 "/mmc/root/payloads/user/reconnaissance/gitgrep"; do
    if [ -f "$candidate/gitgrep.py" ]; then
        PAYLOAD_DIR="$candidate"
        break
    fi
done

ENGINE="$PAYLOAD_DIR/gitgrep.py"
RUNLOG="/tmp/gitgrep_run.log"

# === CLEANUP ===
cleanup() {
    rm -f "$RUNLOG"
    LED WHITE 2>/dev/null
}
trap cleanup EXIT INT TERM

# === UI HELPERS ===
confirmed() {
    [ "$1" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || [ "$1" = "true" ] || [ "$1" = "yes" ]
}

play_done() { RINGTONE "done:d=4,o=5,b=180:c6,e6,g6,c7" & }
play_fail() { RINGTONE "fail:d=4,o=4,b=120:g,e,c" & }

spinner_start() {
    if command -v START_SPINNER >/dev/null 2>&1; then
        START_SPINNER "$1"
    fi
}

spinner_stop() {
    if [ -n "$1" ] && command -v STOP_SPINNER >/dev/null 2>&1; then
        STOP_SPINNER "$1" >/dev/null 2>&1
    fi
}

# === DEPENDENCIES ===
python_ready() {
    command -v python3 >/dev/null 2>&1 && \
        python3 -c 'import json, tarfile, subprocess, csv, hashlib, argparse' \
            >/dev/null 2>&1
}

ensure_python() {
    if python_ready; then
        return 0
    fi

    LOG "yellow" "python3 is missing or incomplete."
    resp=$(CONFIRMATION_DIALOG "Install python3-light now? (~3 MB)")
    confirmed "$resp" || return 1

    LOG "cyan" "Updating package lists..."
    opkg update >/dev/null 2>&1
    if opkg install python3-light >/tmp/gitgrep_opkg.log 2>&1 && \
       python_ready; then
        LOG "green" "python3-light installed."
        return 0
    fi

    LOG "red" "Install failed. See /tmp/gitgrep_opkg.log"
    ALERT "python3-light install failed.\n\nRun manually:\nopkg update && opkg install python3-light"
    return 1
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi

    LOG "yellow" "curl is not installed (needed for GitHub scans)."
    resp=$(CONFIRMATION_DIALOG "Install curl now? (~1 MB)")
    confirmed "$resp" || return 1

    opkg update >/dev/null 2>&1
    if opkg install curl >/tmp/gitgrep_opkg_curl.log 2>&1 && \
       command -v curl >/dev/null 2>&1; then
        LOG "green" "curl installed."
        return 0
    fi

    LOG "red" "Install failed. See /tmp/gitgrep_opkg_curl.log"
    ALERT "curl install failed.\n\nRun manually:\nopkg update && opkg install curl"
    return 1
}

ensure_git() {
    if command -v git >/dev/null 2>&1; then
        return 0
    fi

    LOG "yellow" "git is not installed (needed for history mode)."
    resp=$(CONFIRMATION_DIALOG "Install git + git-http now? (~8 MB)")
    confirmed "$resp" || return 1

    opkg update >/dev/null 2>&1
    if opkg install git git-http >/tmp/gitgrep_opkg_git.log 2>&1 && \
       command -v git >/dev/null 2>&1; then
        LOG "green" "git installed."
        return 0
    fi

    LOG "red" "git install failed. History mode unavailable."
    return 1
}

# === TOKEN ===
load_token() {
    if [ -n "$GITHUB_TOKEN" ]; then
        printf '%s' "$GITHUB_TOKEN"
        return
    fi
    if [ -n "$GH_TOKEN" ]; then
        printf '%s' "$GH_TOKEN"
        return
    fi
    if [ -f "$TOKEN_FILE" ]; then
        head -n 1 "$TOKEN_FILE" 2>/dev/null
    fi
}

token_status() {
    if [ -n "$GITHUB_TOKEN" ] || [ -n "$GH_TOKEN" ]; then
        echo "environment"
    elif [ -s "$TOKEN_FILE" ]; then
        echo "saved"
    else
        echo "none"
    fi
}

manage_token() {
    local status choice token
    status=$(token_status)
    LOG ""
    LOG "cyan" "GitHub token: $status"
    LOG ""

    choice=$(LIST_PICKER "Token" \
        "Set / replace token" \
        "Clear saved token" \
        "Back")

    case "$choice" in
        "Set"*)
            LOG "yellow" "A token raises the API limit from 60 to 5000 requests/hour."
            LOG "yellow" "Stored in plaintext at: $TOKEN_FILE (mode 600)."
            token=$(TEXT_PICKER "Paste token (blank to cancel)" "")
            [ -z "$token" ] && return
            mkdir -p "$LOOTDIR"
            ( umask 077; printf '%s\n' "$token" > "$TOKEN_FILE" )
            chmod 600 "$TOKEN_FILE" 2>/dev/null
            LOG "green" "Token saved."
            ;;
        "Clear"*)
            rm -f "$TOKEN_FILE"
            LOG "green" "Saved token cleared."
            ;;
        *)
            return
            ;;
    esac
}

# === DEPTH ===
MAX_REPOS=30
MAX_MINUTES=15

pick_depth() {
    local choice
    choice=$(LIST_PICKER "Scan depth" \
        "Quick (5 repos, 3 min)" \
        "Standard (30 repos, 15 min)" \
        "Deep (100 repos, 45 min)")

    case "$choice" in
        "Quick"*)    MAX_REPOS=5;   MAX_MINUTES=3 ;;
        "Deep"*)     MAX_REPOS=100; MAX_MINUTES=45 ;;
        *)           MAX_REPOS=30;  MAX_MINUTES=15 ;;
    esac
}

# === ENGINE ===
run_engine() {
    local spinner rc
    local summary findings high medium low report preview

    : > "$RUNLOG"
    LED BLUE 2>/dev/null
    spinner=$(spinner_start "GITGREP scanning...")
    python3 "$ENGINE" "$@" > "$RUNLOG" 2>&1
    rc=$?
    spinner_stop "$spinner"

    if [ $rc -ne 0 ]; then
        LED RED 2>/dev/null
        play_fail
        LOG "red" "Scan failed."
        tail -n 3 "$RUNLOG" | while IFS= read -r line; do
            LOG "yellow" "  $line"
        done
        ALERT "GITGREP failed.\n\n$(tail -n 2 "$RUNLOG")"
        return 1
    fi

    summary=$(grep '^summary:' "$RUNLOG" | tail -n 1)
    report=$(grep '^report:' "$RUNLOG" | tail -n 1 | awk '{print $2}')
    preview=$(grep '^preview:' "$RUNLOG" | tail -n 1 | awk '{print $2}')

    findings=$(printf '%s\n' "$summary" | sed -n 's/.*findings=\([0-9]*\).*/\1/p')
    high=$(printf '%s\n' "$summary" | sed -n 's/.*high=\([0-9]*\).*/\1/p')
    medium=$(printf '%s\n' "$summary" | sed -n 's/.*medium=\([0-9]*\).*/\1/p')
    low=$(printf '%s\n' "$summary" | sed -n 's/.*low=\([0-9]*\).*/\1/p')
    [ -z "$findings" ] && findings=0
    [ -z "$high" ] && high=0
    [ -z "$medium" ] && medium=0
    [ -z "$low" ] && low=0

    LOG ""
    if [ "$findings" -gt 0 ]; then
        LED GREEN 2>/dev/null
        play_done
        LOG "green" "Findings: $findings  (high $high / medium $medium / low $low)"
    else
        LED AMBER 2>/dev/null
        play_done
        LOG "yellow" "No secrets found."
    fi
    LOG "cyan" "Report: $report"

    if [ "$findings" -gt 0 ] && [ -f "$preview" ]; then
        resp=$(CONFIRMATION_DIALOG "Show the top findings on screen?\n\nValues are masked.")
        if confirmed "$resp"; then
            LOG ""
            sed -n '1,18p' "$preview" | while IFS= read -r line; do
                LOG "  $line"
            done
            WAIT_FOR_INPUT
        fi
    fi

    ALERT "GITGREP complete\n\n$findings finding(s)  (H:$high M:$medium L:$low)\n\n$report"
    return 0
}

# === MODES ===
run_user() {
    local target token resp
    target=$(TEXT_PICKER "GitHub user or org" "")
    [ -z "$target" ] && return

    pick_depth
    ensure_curl || return 1

    token=$(load_token)
    if [ -n "$token" ]; then
        run_engine "$target" --loot "$LOOTDIR" \
            --max-repos "$MAX_REPOS" --max-minutes "$MAX_MINUTES" \
            --token "$token"
    else
        LOG "yellow" "No token: GitHub allows 60 API requests/hour."
        resp=$(CONFIRMATION_DIALOG "Continue without a token?")
        confirmed "$resp" || { manage_token; return; }
        run_engine "$target" --loot "$LOOTDIR" \
            --max-repos "$MAX_REPOS" --max-minutes "$MAX_MINUTES"
    fi
}

run_repo() {
    local target token resp hist
    target=$(TEXT_PICKER "Repository (owner/repo)" "")
    [ -z "$target" ] && return

    pick_depth
    ensure_curl || return 1

    hist=""
    resp=$(CONFIRMATION_DIALOG "Also scan git history?\n\nClones the repo with git (needs ~8 MB of packages).")
    if confirmed "$resp"; then
        if ensure_git; then
            hist="--history"
        fi
    fi

    token=$(load_token)
    if [ -n "$token" ]; then
        run_engine "$target" --loot "$LOOTDIR" \
            --max-repos "$MAX_REPOS" --max-minutes "$MAX_MINUTES" \
            $hist --token "$token"
    else
        run_engine "$target" --loot "$LOOTDIR" \
            --max-repos "$MAX_REPOS" --max-minutes "$MAX_MINUTES" $hist
    fi
}

run_local() {
    local path
    path=$(TEXT_PICKER "Folder to scan" "/root")
    [ -z "$path" ] && return
    if [ ! -d "$path" ]; then
        ALERT "Not a folder:\n$path"
        return
    fi

    pick_depth
    run_engine --local "$path" --loot "$LOOTDIR" \
        --max-repos "$MAX_REPOS" --max-minutes "$MAX_MINUTES"
}

run_history() {
    local path
    path=$(TEXT_PICKER "Local git repository" "/root")
    [ -z "$path" ] && return
    if [ ! -d "$path" ]; then
        ALERT "Not a folder:\n$path"
        return
    fi
    if ! ensure_git; then
        return 1
    fi

    pick_depth
    run_engine --local "$path" --history --loot "$LOOTDIR" \
        --max-repos "$MAX_REPOS" --max-minutes "$MAX_MINUTES"
}

# === ABOUT ===
show_about() {
    LOG ""
    LOG "cyan" "GITGREP v1.0.0"
    LOG ""
    LOG "Read-only secret hunter for GitHub"
    LOG "users, orgs, repositories and local"
    LOG "git history."
    LOG ""
    LOG "Detects 35+ credential types:"
    LOG "  AWS, GCP, Azure, GitHub/GitLab,"
    LOG "  Slack, Discord, Stripe, SendGrid,"
    LOG "  Mailgun, Mailchimp, Twilio,"
    LOG "  Telegram, npm, PyPI, OpenAI,"
    LOG "  Anthropic, HuggingFace,"
    LOG "  DigitalOcean, Shopify, Postman,"
    LOG "  New Relic, Grafana, Vault, age,"
    LOG "  JWT, basic-auth URLs, private keys."
    LOG ""
    LOG "Values are masked by default and"
    LOG "re-used secrets are grouped."
    LOG ""
    LOG "Reports: $LOOTDIR"
    LOG ""
    LOG "yellow" "Scan only repositories you own or"
    LOG "yellow" "are authorised to assess."
    LOG ""
    WAIT_FOR_INPUT
}

# === MAIN ===
LED WHITE 2>/dev/null
LOG ""
LOG "magenta" "=============================================="
LOG "magenta" "  GITGREP - GitHub Secret Hunter v1.0.0"
LOG "magenta" "=============================================="
LOG ""
LOG "Read-only OSINT. Scan repositories you own"
LOG "or are authorised to assess."
LOG ""

resp=$(CONFIRMATION_DIALOG "I will only scan repositories I own or have permission to assess.")
case $? in
    "${DUCKYSCRIPT_REJECTED:-__rejected}"|"${DUCKYSCRIPT_ERROR:-__error}")
        exit 1 ;;
esac
confirmed "$resp" || { LOG "yellow" "Not confirmed. Exiting."; exit 1; }

if [ -z "$PAYLOAD_DIR" ] || [ ! -f "$ENGINE" ]; then
    LED RED 2>/dev/null
    ALERT "gitgrep.py not found.\n\nExpected next to payload.sh or in /root/payloads/user/reconnaissance/gitgrep"
    exit 1
fi

if ! ensure_python; then
    LED RED 2>/dev/null
    exit 1
fi

mkdir -p "$LOOTDIR"

while true; do
    choice=$(LIST_PICKER "GITGREP" \
        "Scan GitHub user/org" \
        "Scan one repository" \
        "Scan a local folder" \
        "Scan local git history" \
        "Token / settings" \
        "About / legal" \
        "Exit")

    [ -z "$choice" ] && break

    case "$choice" in
        "Scan GitHub"*)   run_user ;;
        "Scan one"*)      run_repo ;;
        "Scan a local"*)  run_local ;;
        "Scan local"*)    run_history ;;
        "Token"*)         manage_token ;;
        "About"*)         show_about ;;
        "Exit")           break ;;
        *)                LOG "yellow" "Unknown selection: $choice" ;;
    esac
    LED WHITE 2>/dev/null
done

LOG ""
LOG "green" "GITGREP exiting."
LED WHITE 2>/dev/null
exit 0
