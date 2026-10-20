#!/bin/bash
# Title: O.MG Controller
# Description: Basic O.MG controls over the connected device's Wi-Fi.
# Author: Gas Station Hot Dog
# Version: 1.6.4
# Category: General
# Requirements: Pager firmware 1.0.8+, Python 3.9+, O.MG Wi-Fi connection

trap 'exit 130' HUP INT TERM

# Ordinary cancellation returns to the caller for back navigation. A UI child
# killed by a signal must stop the controller, not reopen its parent menu.
ui_pick() {
    local _ui_destination=$1 _ui_result _ui_command=$2 _ui_status=0
    shift
    _ui_result=$("$@") || _ui_status=$?
    if [ "$_ui_status" -ge 128 ]; then exit "$_ui_status"; fi
    [ "$_ui_status" -eq 0 ] || return 1
    if [ "$_ui_command" = LIST_PICKER ] && [ -z "$_ui_result" ]; then return 1; fi
    printf -v "$_ui_destination" '%s' "$_ui_result"
}

ui_wait() {
    local status=0
    WAIT_FOR_BUTTON_PRESS A || status=$?
    if [ "$status" -ge 128 ]; then exit "$status"; fi
    return "$status"
}

for tool in LOG LIST_PICKER CONFIRMATION_DIALOG WAIT_FOR_BUTTON_PRESS; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Missing Pager command: %s (firmware 1.0.8+ required)\n' "$tool" >&2
        exit 1
    fi
done
# Pager stages the launcher separately; PAYLOAD_HOME identifies installed assets.
# Never derive the asset directory from the working directory or BASH_SOURCE.
if [ -z "${PAYLOAD_HOME:-}" ]; then
    LOG red "PAYLOAD_HOME is missing. Launch from the Pager payload menu."
    ui_wait || true
    exit 1
fi
if [[ "$PAYLOAD_HOME" != /* ]] || [ ! -d "$PAYLOAD_HOME" ]; then
    LOG red "PAYLOAD_HOME must point to the installed payload directory."
    ui_wait || true
    exit 1
fi
PAYLOAD_DIR="$PAYLOAD_HOME"
if [ ! -r "$PAYLOAD_DIR/controller.py" ] || [ ! -r "$PAYLOAD_DIR/session.py" ] || \
   [ ! -r "$PAYLOAD_DIR/ducky.py" ] || [ ! -r "$PAYLOAD_DIR/editor.py" ] || [ ! -r "$PAYLOAD_DIR/vendor/websocket/__init__.py" ]; then
    LOG red "Payload files missing. Copy the entire omg-controller folder."
    LOG red "Expected files in: $PAYLOAD_DIR"
    ui_wait || true
    exit 1
fi
PYTHON="$(command -v python3 2>/dev/null)"
if [ -z "$PYTHON" ] && [ -x /mmc/usr/bin/python3 ]; then
    PYTHON=/mmc/usr/bin/python3
fi
if [ -z "$PYTHON" ]; then
    LOG red "Python 3 required. See README for installation."
    ui_wait || true
    exit 1
fi

LOG "Starting O.MG controller..."
# Python imports once; the helper owns one reusable socket for this menu session.
coproc OMG_HELPER {
    LD_LIBRARY_PATH="/mmc/usr/lib:/mmc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$PYTHON" -u "$PAYLOAD_DIR/session.py"
}
HELPER_PID=$OMG_HELPER_PID
exec {HELPER_READ}<&"${OMG_HELPER[0]}"
exec {HELPER_WRITE}>&"${OMG_HELPER[1]}"
cleanup() {
    printf 'quit\n' >&"$HELPER_WRITE" 2>/dev/null || true
    kill "$HELPER_PID" 2>/dev/null || true
    wait "$HELPER_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
if ! IFS=$'\t' read -r -t 30 kind message <&"$HELPER_READ" || [ "$kind" != READY ]; then
    LOG red "Python helper failed to start. Check installation and dependencies."
    ui_wait || true
    exit 1
fi

request() {
    local kind message
    ITEMS=()
    NEW_SLOT=""
    EMPTY_SLOTS=" "
    if ! printf '%s\t%s\n' "$1" "${2:-}" >&"$HELPER_WRITE"; then
        LOG red "Helper stopped. Relaunch controller."
        exit 1
    fi
    while IFS=$'\t' read -r -t 30 kind message <&"$HELPER_READ"; do
        case "$kind" in
            LOG) LOG "$message" ;;
            ERROR) LOG red "$message" ;;
            ITEM) ITEMS+=("$message") ;;
            NEW_SLOT) NEW_SLOT=$message ;;
            EMPTY_SLOT) EMPTY_SLOTS+="$message " ;;
            FIELD) DESCRIPTORS[${message%%=*}]=${message#*=} ;;
            TEXT) EDIT_TEXT=${message:1:${#message}-2} ;;
            PAGES) PAGES=$message ;;
            TIME) LAST_TIME=$message ;;
            DONE) return "$message" ;;
        esac
    done
    LOG red "Helper stopped responding. Relaunch controller."
    exit 1
}

pause_result() {
    LOG "Press A to return to menu."
    ui_wait || true
}
run_action() {
    request "$1" "${2:-}" || true
    pause_result
}

view_slot() {
    local page=0 nav
    if ! request view "$1"; then pause_result; return; fi
    while true; do
        request view-page "$page" || break
        LOG "Press A for page navigation."
        ui_wait || return
        ui_pick nav LIST_PICKER "Payload page $((page+1))/$PAGES" "Next" "Previous" "Back" "Next" || return
        case "$nav" in
            Next) [ "$page" -lt "$((PAGES-1))" ] && page=$((page+1)) ;;
            Previous) [ "$page" -gt 0 ] && page=$((page-1)) ;;
            *) return ;;
        esac
    done
}

edit_payload() {
    local slot=$1 selected number operation value answer EDIT_TEXT
    if ! command -v TEXT_PICKER >/dev/null 2>&1; then
        LOG red "TEXT_PICKER is required for editing."; pause_result; return
    fi
    if [ "${2:-}" != loaded ]; then
        if ! request edit-load "$slot"; then pause_result; return; fi
    fi
    while true; do
        if ! request edit-list; then pause_result; return; fi
        local lines=("${ITEMS[@]}")
        ui_pick selected LIST_PICKER "Edit payload $slot" "${lines[@]}" "Append line" "Save" "Discard" "Append line" || { request edit-discard; return; }
        case "$selected" in
            Discard) request edit-discard; return ;;
            Save)
                ui_pick answer CONFIRMATION_DIALOG "Save changes to payload $slot?" || continue
                [ "$answer" = 1 ] || continue
                if request edit-save; then pause_result; return; fi
                pause_result; continue ;;
            "Append line") number=$((${#lines[@]}+1)); operation=edit-insert; EDIT_TEXT="" ;;
            *)
                number=${selected%% |*}
                [[ "$number" =~ ^[0-9]+$ ]] || continue
                ui_pick operation LIST_PICKER "Line $number" "Edit line" "Insert before" "Delete line" "Back" "Edit line" || continue
                case "$operation" in
                    "Edit line")
                        request edit-get "$number" || continue
                        operation=edit-replace ;;
                    "Insert before") operation=edit-insert; EDIT_TEXT="" ;;
                    "Delete line") request edit-delete "$number" || pause_result; continue ;;
                    *) continue ;;
                esac ;;
        esac
        ui_pick value TEXT_PICKER "Payload line $number" "$EDIT_TEXT" || continue
        if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
            LOG red "Enter one line at a time."; pause_result; continue
        fi
        request "$operation" "$number=$value" || pause_result
    done
}

create_payload() {
    local slot=$1 choice selected
    ui_pick choice LIST_PICKER "Create payload $slot" "Write new" "Import .txt" "Restore Payload Backup" "Back" "Import .txt" || return
    case "$choice" in
        "Write new") edit_payload "$slot" ;;
        "Restore Payload Backup") restore_payload "$slot" ;;
        "Import .txt")
            if ! request edit-import-files; then pause_result; return; fi
            if [ "${#ITEMS[@]}" -eq 0 ]; then
                LOG "No .txt files found. Copy files into: $PAYLOAD_DIR/payloads"
                pause_result; return
            fi
            local files=("${ITEMS[@]}")
            ui_pick selected LIST_PICKER "Import .txt" "${files[@]}" "Back" "${files[0]}" || return
            [ "$selected" = Back ] && return
            if ! request edit-import-load "$slot"$'\t'"$selected"; then pause_result; return; fi
            run_action edit-save
            request edit-discard || true ;;
    esac
}

payload_menu() {
    local selected slot action answer
    if ! request "$1"; then pause_result; return; fi
    if [ "${#ITEMS[@]}" -eq 0 ]; then LOG "No matching payload slots."; pause_result; return; fi
    local choices=("${ITEMS[@]}")
    local new_slot=$NEW_SLOT empty_slots=$EMPTY_SLOTS
    while true; do
        ui_pick selected LIST_PICKER "Payloads" "${choices[@]}" "Back" "${choices[0]}" || return
        [ "$selected" = Back ] && return
        slot=${selected%% |*}
        [[ "$slot" =~ ^[0-9]{3}$ ]] || return
        slot=$((10#$slot))
        if [[ "$empty_slots" == *" $slot "* ]] || [ "$slot" = "$new_slot" ]; then
            create_payload "$slot"
            if ! request payloads; then pause_result; return; fi
            choices=("${ITEMS[@]}"); new_slot=$NEW_SLOT; empty_slots=$EMPTY_SLOTS
            [ "${#choices[@]}" -gt 0 ] || return
            continue
        fi
        ui_pick action LIST_PICKER "Payload $slot" "Execute" "View" "Edit" "Backup Payload" "Restore Payload Backup" "Clear Slot" "Back" "Execute" || continue
        case "$action" in
            View) view_slot "$slot" ;;
            "Backup Payload") run_action edit-backup "$slot" ;;
            "Restore Payload Backup"|"Clear Slot")
                if [ "$action" = "Restore Payload Backup" ]; then
                    restore_payload "$slot"
                else
                    ui_pick answer CONFIRMATION_DIALOG "Clear payload $slot? A backup will be saved first." || continue
                    [ "$answer" = 1 ] || continue
                    run_action edit-clear "$slot"
                fi
                if ! request payloads; then pause_result; return; fi
                choices=("${ITEMS[@]}"); new_slot=$NEW_SLOT; empty_slots=$EMPTY_SLOTS
                [ "${#choices[@]}" -gt 0 ] || return ;;
            Edit)
                edit_payload "$slot"
                if ! request payloads; then pause_result; return; fi
                choices=("${ITEMS[@]}"); new_slot=$NEW_SLOT; empty_slots=$EMPTY_SLOTS
                [ "${#choices[@]}" -gt 0 ] || return ;;
            Execute)
                if ! request prepare "$slot"; then pause_result; continue; fi
                run_action execute "$slot"
                ;;
        esac
    done
}

edit_descriptors() {
    local selected index value answer
    local names=("VID" "PID" "Manufacturer" "Product" "Serial")
    local DESCRIPTORS=()
    if ! command -v TEXT_PICKER >/dev/null 2>&1; then
        LOG red "TEXT_PICKER is required for editing descriptors."
        pause_result; return
    fi
    if ! request descriptor-load; then pause_result; return; fi
    while true; do
        ui_pick selected LIST_PICKER "Edit USB descriptors" "VID" "PID" "Manufacturer" "Product" "Serial" "Save" "Cancel" "VID" || return
        case "$selected" in
            Cancel) return ;;
            Save)
                if ! request descriptor-review; then pause_result; return; fi
                LOG "Reboot O.MG after saving to apply the new defaults."
                ui_pick answer CONFIRMATION_DIALOG "Save these USB descriptors?" || continue
                [ "$answer" = 1 ] || continue
                run_action descriptor-save
                return ;;
            VID) index=0 ;; PID) index=1 ;; Manufacturer) index=2 ;;
            Product) index=3 ;; Serial) index=4 ;;
            *) return ;;
        esac
        ui_pick value TEXT_PICKER "${names[$index]}" "${DESCRIPTORS[$index]}" || continue
        # Keep input on one helper-protocol line, including empty string fields.
        if [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]]; then
            LOG red "Tabs and newlines are not allowed."; pause_result; continue
        fi
        request descriptor-edit "$index=$value" || pause_result
    done
}

descriptor_menu() {
    local selected
    while true; do
        ui_pick selected LIST_PICKER "USB descriptors" "View current" "Edit" "Back" "View current" || return
        case "$selected" in
            "View current") run_action descriptors ;;
            Edit) edit_descriptors ;;
            *) return ;;
        esac
    done
}

restore_payload() {
    local selected answer destination slot mode new_slot
    if ! request edit-backups; then pause_result; return; fi
    if [ "${#ITEMS[@]}" -eq 0 ]; then
        LOG "No backups found in the installed payload's backups folder."
        pause_result; return
    fi
    local backups=("${ITEMS[@]}")
    ui_pick selected LIST_PICKER "Restore Payload Backup" "${backups[@]}" "Back" "${backups[0]}" || return
    [ "$selected" = Back ] && return
    if ! request edit-restore-load "$selected"; then pause_result; return; fi
    if [ -n "${1:-}" ]; then
        if request edit-restore-target "$1"$'\t'"existing"; then
            ui_pick answer CONFIRMATION_DIALOG "Restore this backup to payload $1?" || { request edit-discard; return; }
            [ "$answer" = 1 ] && run_action edit-save
        else
            pause_result
        fi
        request edit-discard || true
        return
    fi
    ui_pick answer CONFIRMATION_DIALOG "Restore this backup to its original slot?" || { request edit-discard; return; }
    if [ "$answer" = 1 ]; then
        run_action edit-save
    else
        if ! request restore-slots; then pause_result; request edit-discard; return; fi
        local destinations=("${ITEMS[@]}")
        new_slot=$NEW_SLOT
        if [ "${#destinations[@]}" -eq 0 ]; then
            LOG "No destination slots available."; pause_result; request edit-discard; return
        fi
        ui_pick destination LIST_PICKER "Restore to which slot?" "${destinations[@]}" "Back" "${destinations[0]}" || { request edit-discard; return; }
        if [ "$destination" != Back ]; then
            slot=${destination%% |*}
            if [[ "$slot" =~ ^[0-9]{3}$ ]]; then
                slot=$((10#$slot)); mode=existing
                [ "$slot" = "$new_slot" ] && mode=new
                if request edit-restore-target "$slot"$'\t'"$mode"; then
                    if [ "$mode" = new ]; then
                        ui_pick answer CONFIRMATION_DIALOG "Restore to empty slot $slot?" || { request edit-discard; return; }
                    else
                        ui_pick answer CONFIRMATION_DIALOG "Replace payload $slot with this backup?" || { request edit-discard; return; }
                    fi
                    [ "$answer" = 1 ] && run_action edit-save
                else
                    pause_result
                fi
            fi
        fi
    fi
    request edit-discard || true
}

extra_menu() {
    local choice answer
    while true; do
        ui_pick choice LIST_PICKER "Extra" "USB on" "USB off" "Jiggler on" "Jiggler off" "Connection timing" "Restore Payload Backup" "Back" "USB on" || return
        case "$choice" in
            "USB on") run_action usb-on ;;
            "USB off")
                ui_pick answer CONFIRMATION_DIALOG "USB off on O.MG?" || continue
                [ "$answer" = 1 ] && run_action usb-off ;;
            "Jiggler on") run_action jiggler-on ;;
            "Jiggler off") run_action jiggler-off ;;
            "Connection timing") run_action timing ;;
            "Restore Payload Backup") restore_payload ;;
            *) return ;;
        esac
    done
}

LOG "O.MG Controller - 192.168.4.1"
while true; do
    ui_pick choice LIST_PICKER "O.MG Controller" \
        "Payloads" "Payload status" "USB descriptors" "Device status" \
        "Extra" "Reboot" "Exit" \
        "Payloads" || exit 0
    case "$choice" in
        "Device status") run_action status ;;
        "Payloads") payload_menu payloads ;;
        "Payload status") run_action payload-status ;;
        "USB descriptors") descriptor_menu ;;
        "Extra") extra_menu ;;
        "Reboot")
            LOG "Rebooting O.MG. This controller will now exit."
            LOG "Wait for the O.MG AP, reconnect the Pager, then restart this payload."
            request reboot || true
            exit 0
            ;;
        *) exit 0 ;;
    esac
done
