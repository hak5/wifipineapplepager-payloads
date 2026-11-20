#!/bin/bash
# Hardware-free tests for detector thresholds, persisted options and idle policy.
set -e
base=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export PAD_STATE="$fixture/state" PAD_RUN="$fixture/run" PAD_GAUGE="$fixture/gauge"
mkdir -p "$PAD_GAUGE"
. "$base/controller.sh"
expect() { [[ "$1" == "$2" ]] || { printf 'Expected %s, got %s\n' "$2" "$1" >&2; exit 1; }; }
printf '0\n' > "$PAD_GAUGE/current_now"
expect "$(detect_power)" unknown
save_calibration 0 0 -823000 -771000
expect "$(detect_power)" external
printf '%s\n' -594000 > "$PAD_GAUGE/current_now"
expect "$(detect_power)" battery
printf '%s\n' -400000 > "$PAD_GAUGE/current_now"
expect "$(detect_power)" unknown
printf 'bad\n' > "$PAD_GAUGE/current_now"
expect "$(detect_power)" unknown
before=$(cat "$PAD_STATE/calibration")
if save_calibration -450000 -300000 -500000 -400000; then exit 1; fi
expect "$(cat "$PAD_STATE/calibration")" "$before"
# Charging measurements must work too, not only a full battery at zero current.
save_calibration 346000 367000 -823000 -771000
expect "$(cat "$PAD_STATE/calibration")" "$before"
load_settings
expect "$battery_seconds $external_seconds" '60 0'
save_settings 90 600; load_settings
expect "$battery_seconds $external_seconds" '90 600'
save_settings 00060 0; load_settings
expect "$battery_seconds $external_seconds" '60 0'
for bad in -1 1 14 86401 18446744073709551616 abc '2;echo bad'; do
    if save_settings "$bad" 0 >/dev/null; then exit 1; fi
done
expect "$(cat "$PAD_STATE/timeouts")" '60 0'
expect "$(timer_action 60 59 no yes)" awake
expect "$(timer_action 60 60 no yes)" sleep
expect "$(timer_action 60 61 yes yes)" asleep
expect "$(timer_action 0 99999 no yes)" awake
# An input reset reduces idle to zero. A failed observer must not blank a screen.
expect "$(timer_action 60 0 yes yes)" awake
expect "$(timer_action 60 999 no no)" awake
# Bad stored settings are rejected instead of evaluated as shell code.
printf 'bad values\n' > "$PAD_STATE/timeouts"
if load_settings; then exit 1; fi

# Exercise the community installer entirely inside the fixture. This checks a
# fresh install, idempotent replacement, and protection of unrelated files.
export PAD_HOME="$fixture/payload" PAD_INIT="$fixture/init/pager-power-display"
mkdir -p "$PAD_HOME" "$(dirname "$PAD_INIT")"
cp "$base/pager-power-display.init" "$PAD_HOME/"
printf '#!/bin/sh\nexit 0\n' > "$PAD_HOME/input-watch"
chmod +x "$PAD_HOME/input-watch"
install_service
[[ -x "$PAD_INIT" ]] || exit 1
grep -Fqx "CONTROLLER=$PAD_HOME/controller.sh" "$PAD_INIT"
install_service
printf 'unrelated service\n' > "$PAD_INIT"
if install_service >/dev/null; then exit 1; fi
expect "$(cat "$PAD_INIT")" 'unrelated service'
rm "$PAD_INIT"
ln -s "$PAD_HOME/input-watch" "$PAD_INIT"
if install_service >/dev/null; then exit 1; fi
echo 'PASS: calibration, settings, idle policy, observer failure, installer and overwrite protection'
