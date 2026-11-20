#!/bin/bash
# The Python test runner supplies an isolated directory and removes it afterward.
set -eu
source "$1"
trap - EXIT INT HUP TERM
TEST_DIR="$2"
CLI="$3"
SCENARIO="$4"
INSTALLED=0
PROMPTS=0
PACKAGE_INDEX_READY=0
printf '0\n' > "$TEST_DIR/checks"
: > "$TEST_DIR/packages"

LOG() { :; }
message() { printf 'MESSAGE %s\n' "$1"; }
LIST_PICKER() { :; }
TEXT_PICKER() { :; }
CONFIRMATION_DIALOG() { :; }
python3() { :; }
command() {
    if [[ "$*" == '-v python3' && "$SCENARIO" == python_missing && "$INSTALLED" == 0 ]]; then
        return 1
    fi
    builtin command "$@"
}
confirm() {
    PROMPTS=$((PROMPTS + 1))
    [[ "$SCENARIO" != decline && "$SCENARIO" != optional_decline ]]
}
cli() {
    [[ "$*" == dependencies ]] || return 1
    local checks
    read -r checks < "$TEST_DIR/checks"
    printf '%s\n' "$((checks + 1))" > "$TEST_DIR/checks"
    case "$SCENARIO" in
        ready|python_missing) printf 'ready\n' ;;
        reinstall) printf 'reinstall pyusb\n' ;;
        unrecognized) printf 'required unexpected-package\n' ;;
        optional_decline|optional_failure) printf 'optional python3-cryptography\n' ;;
        optional_install)
            if [[ "$INSTALLED" == 1 ]]; then printf 'ready\n'; else printf 'optional python3-cryptography\n'; fi ;;
        serial)
            if [[ "$INSTALLED" == 1 ]]; then printf 'ready\n'; else printf 'required python3-pyserial\n'; fi ;;
        *)
            if [[ "$INSTALLED" == 1 && "$SCENARIO" != still_missing ]]; then
                printf 'ready\n'
            else
                printf 'required libusb-1.0-0\n'
            fi ;;
    esac
}
opkg() {
    if [[ "$1" == status || "$1" == '-d' ]]; then
        [[ "$SCENARIO" == installed_broken ]] || return 1
        printf 'Status: install ok installed\n'
        return 0
    fi
    printf '%s\n' "$*" >> "$TEST_DIR/packages"
    case "$1" in
        update)
            [[ "$SCENARIO" != refresh_failure ]] || { printf 'TEST_PRIVATE_PACKAGE_DETAIL\n'; return 1; } ;;
        install)
            [[ "$SCENARIO" != install_failure && "$SCENARIO" != optional_failure ]] || {
                printf 'TEST_PRIVATE_PACKAGE_DETAIL\n'; return 1;
            }
            INSTALLED=1 ;;
        *) return 1 ;;
    esac
}

result=0
ensure_runtime || result=$?
read -r checks < "$TEST_DIR/checks"
packages=$(cat "$TEST_DIR/packages")
case "$SCENARIO" in
    ready) [[ "$result" == 0 && "$PROMPTS" == 0 && "$checks" == 2 && -z "$packages" ]] ;;
    python_missing) [[ "$result" == 0 && "$checks" == 2 && "$packages" == $'update\ninstall -d mmc python3' ]] ;;
    decline) [[ "$result" == 1 && "$PROMPTS" == 1 && -z "$packages" ]] ;;
    install_failure) [[ "$result" == 1 && "$packages" == $'update\ninstall -d mmc libusb-1.0-0' ]] ;;
    refresh_failure) [[ "$result" == 1 && "$packages" == update ]] ;;
    install) [[ "$result" == 0 && "$checks" == 2 && "$packages" == $'update\ninstall -d mmc libusb-1.0-0' ]] ;;
    still_missing) [[ "$result" == 1 && "$checks" == 2 && "$packages" == $'update\ninstall -d mmc libusb-1.0-0' ]] ;;
    installed_broken) [[ "$result" == 1 && "$PROMPTS" == 0 && -z "$packages" ]] ;;
    optional_decline) [[ "$result" == 0 && "$PROMPTS" == 1 && "$checks" == 2 && -z "$packages" ]] ;;
    optional_failure) [[ "$result" == 0 && "$checks" == 2 && "$packages" == $'update\ninstall -d mmc python3-cryptography' ]] ;;
    optional_install) [[ "$result" == 0 && "$checks" == 2 && "$packages" == $'update\ninstall -d mmc python3-cryptography' ]] ;;
    serial) [[ "$result" == 0 && "$checks" == 2 && "$packages" == $'update\ninstall -d mmc python3-pyserial' ]] ;;
    reinstall|unrecognized) [[ "$result" == 1 && "$PROMPTS" == 0 && -z "$packages" ]] ;;
    *) exit 1 ;;
esac
printf 'PASS %s\n' "$SCENARIO"
