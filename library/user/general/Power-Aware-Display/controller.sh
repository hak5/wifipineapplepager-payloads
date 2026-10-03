#!/bin/bash
# Independent power-aware screen timer. No preference writes, framebuffer writes,
# synthetic keys, service restarts, or exclusive input grabs are used.
PAD_HOME=${PAD_HOME:-/root/payloads/user/general/Power-Aware-Display}
PAD_STATE=${PAD_STATE:-/etc/pager-power-display}
PAD_RUN=${PAD_RUN:-/tmp/pager-power-display}
PAD_GAUGE=${PAD_GAUGE:-/sys/class/power_supply/bq27546-0}
PAD_INIT=${PAD_INIT:-/etc/init.d/pager-power-display}
PAD_SOCKET=${PAD_SOCKET:-/tmp/api.sock}
PAD_INPUT=${PAD_INPUT:-/dev/input/event0}
umask 077
numeric() { [[ "$1" =~ ^-?[0-9]+$ ]]; }
now() { local value rest; read -r value rest < /proc/uptime; printf '%s\n' "${value%%.*}"; }
valid_timeout() {
    # Bound the digit count before arithmetic so oversized input cannot wrap.
    [[ "$1" =~ ^[0-9]{1,9}$ ]] && ((10#$1 == 0 || (10#$1 >= 15 && 10#$1 <= 86400)))
}
load_settings() {
    battery_seconds=60; external_seconds=0
    [[ -f "$PAD_STATE/timeouts" ]] || return 0
    local b e extra
    read -r b e extra < "$PAD_STATE/timeouts"
    [[ -z "$extra" ]] && valid_timeout "$b" && valid_timeout "$e" || return 1
    battery_seconds=$((10#$b)); external_seconds=$((10#$e))
}
save_settings() {
    valid_timeout "$1" && valid_timeout "$2" || { echo 'Use 0 (Never), or 15 to 86400 seconds.'; return 1; }
    mkdir -p "$PAD_STATE" || return 1
    printf '%s %s\n' "$((10#$1))" "$((10#$2))" > "$PAD_STATE/timeouts.new" || return 1
    mv "$PAD_STATE/timeouts.new" "$PAD_STATE/timeouts"
}
format_timeout() { [[ "$1" == 0 ]] && echo Never || printf '%ss\n' "$1"; }
display_action() {
    case "$1" in wake|sleep) ;; *) return 1;; esac
    curl -fsS --max-time 2 --unix-socket "$PAD_SOCKET" -X POST \
        "http://localhost/api/pager/display/$1" >/dev/null
}
ui_available() {
    # A game such as Pong suspends the UI while it owns the display. Do not wake
    # the framebuffer or send requests into a stopped server during gameplay.
    local pid state
    pid=$(pidof pineapple) || return 1
    [[ "$pid" =~ ^[0-9]+$ && "$(readlink /proc/"$pid"/exe)" == /pineapple/pineapple ]] || return 1
    state=$(awk '{print $3}' /proc/"$pid"/stat) || return 1
    [[ "$state" != T && "$state" != t && "$state" != Z ]]
}
log_event() {
    mkdir -p "$PAD_RUN"
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$PAD_RUN/events"
    tail -n 60 "$PAD_RUN/events" > "$PAD_RUN/events.new" && mv "$PAD_RUN/events.new" "$PAD_RUN/events"
    logger -t pager-power-display "$*"
}
read_current() {
    local value
    value=$(cat "$PAD_GAUGE/current_now" 2>/dev/null) || return 1
    numeric "$value" || return 1
    printf '%s\n' "$value"
}

load_calibration() {
    local extra
    [[ -f "$PAD_STATE/calibration" ]] || return 1
    read -r battery_edge external_edge extra < "$PAD_STATE/calibration"
    [[ -z "$extra" ]] && numeric "$battery_edge" && numeric "$external_edge" &&
        (( battery_edge < external_edge && external_edge <= 0 ))
}

detect_power() {
    local supply type online current seen_offline=0
    # Prefer an explicit AC/USB online sensor when the firmware exposes one.
    # The current Pager has only a fuel gauge, so this path is future compatible.
    for supply in /sys/class/power_supply/*; do
        [[ -r "$supply/online" && -r "$supply/type" ]] || continue
        type=$(cat "$supply/type")
        case "$type" in Mains|USB|USB_*) ;; *) continue ;; esac
        online=$(cat "$supply/online")
        case "$online" in 1) echo external; return ;; 0) seen_offline=1 ;; esac
    done
    [[ "$seen_offline" == 1 ]] && { echo battery; return; }

    # Do not interpret Full, 100%, or BATTERY_CHARGING=false as cable presence.
    # Gauge inference is allowed only after the owner measures BOTH physical
    # power states. The gap between measured ranges supplies hysteresis.
    load_calibration || { echo unknown; return; }
    current=$(read_current) || { echo unknown; return; }
    if (( current <= battery_edge )); then echo battery
    elif (( current >= external_edge )); then echo external
    else echo unknown
    fi
}

sample() {
    local i value low='' high=''
    for ((i=0;i<6;i++)); do
        value=$(read_current) || return 1
        [[ -n "$low" ]] || low=$value
        [[ -n "$high" ]] || high=$value
        ((value < low)) && low=$value
        ((value > high)) && high=$value
        sleep 2
    done
    printf '%s %s\n' "$low" "$high"
}

save_calibration() {
    local ext_low=$1 ext_high=$2 bat_low=$3 bat_high=$4 gap low high value
    for value in "$ext_low" "$ext_high" "$bat_low" "$bat_high"; do
        numeric "$value" || return 1
    done
    # Require distinct, physically plausible ranges with at least 100 mA gap.
    # Reject ambiguous samples instead of guessing whether a cable is present.
    (( ext_low <= ext_high && bat_low <= bat_high && bat_high < -100000 )) || return 1
    local anchor=$ext_low
    ((anchor > 0)) && anchor=0
    gap=$((anchor - bat_high))
    ((gap >= 100000 && ext_low >= -50000)) || return 1
    low=$((bat_high + gap/3)); high=$((bat_high + 2*gap/3))
    ((high <= 0)) || return 1
    mkdir -p "$PAD_STATE" || return 1
    printf '%s %s\n' "$low" "$high" > "$PAD_STATE/calibration.new" || return 1
    mv "$PAD_STATE/calibration.new" "$PAD_STATE/calibration"
}


# A small pure decision function keeps inactivity behavior testable without
# requiring real hardware or advancing the system clock.
timer_action() {
    local seconds=$1 idle=$2 asleep=$3 input_ok=$4
    if [[ "$input_ok" != yes ]]; then echo awake
    elif ((seconds == 0 || idle < seconds)); then echo awake
    elif [[ "$asleep" == yes ]]; then echo asleep
    else echo sleep
    fi
}

daemon() {
    local watch_pid='' candidate='' count=0 observed=unknown profile=unknown
    local stamp current last_activity last_seen=0 last_wake=0 last_power=0
    local seconds=60 previous_settings='' asleep=no paused=no input_ok=no action
    local heartbeat=0 bright=0 settings_ok=yes note=Starting
    mkdir -p "$PAD_RUN" || return 1
    [[ -x "$PAD_HOME/input-watch" ]] || { log_event 'Input observer missing'; return 1; }
    load_settings || { log_event 'Invalid timeout configuration'; return 1; }
    last_activity=$(now)
    "$PAD_HOME/input-watch" "$PAD_INPUT" "$PAD_RUN" & watch_pid=$!
    # Stop the observer before returning control to native display handling.
    # No stored firmware preference is changed by this implementation.
    cleanup() {
        trap - TERM INT EXIT
        kill "$watch_pid" 2>/dev/null || true
        wait "$watch_pid" 2>/dev/null || true
        if ui_available; then display_action wake || true; fi
        printf 'Stopped; native display settings active\n' > "$PAD_RUN/phase"
        log_event 'Stopped; native display control restored'
    }
    trap 'exit 0' TERM INT
    trap cleanup EXIT
    log_event 'Started independent timer'
    while true; do
        current=$(now)
        settings_ok=yes
        if ! load_settings; then settings_ok=no; else
            if [[ "$battery_seconds $external_seconds" != "$previous_settings" ]]; then
                previous_settings="$battery_seconds $external_seconds"
                last_activity=$current
                log_event "Timeouts: battery=$battery_seconds external=$external_seconds"
            fi
        fi
        # Poll the gauge every three seconds and debounce power transitions.
        if ((current-last_power >= 3)); then
            last_power=$current; observed=$(detect_power)
            if [[ "$observed" == "$candidate" ]]; then ((count+=1))
            else candidate=$observed; count=1; fi
            if ((count>=3)) && [[ "$profile" != "$observed" ]]; then
                profile=$observed; last_activity=$current; last_wake=0
                log_event "Power: $profile"
            fi
        fi
        seconds=$battery_seconds
        [[ "$profile" == external ]] && seconds=$external_seconds
        # Observe only timestamps. The helper does not grab, consume, or replay
        # keys. Native controls and ordinary payload menus retain their input.
        input_ok=no
        read -r heartbeat 2>/dev/null < "$PAD_RUN/input-heartbeat" || heartbeat=0
        if numeric "$heartbeat" && ((current-heartbeat<=7)) && kill -0 "$watch_pid" 2>/dev/null; then input_ok=yes; fi
        read -r stamp 2>/dev/null < "$PAD_RUN/last-input" || stamp=0
        if numeric "$stamp" && ((stamp>last_seen)); then
            last_seen=$stamp; last_activity=$stamp
            if [[ "$asleep" == yes ]]; then last_wake=0; asleep=no; fi
        fi
        if ! ui_available; then
            [[ "$paused" == yes ]] || log_event 'Display control paused: UI unavailable or game active'
            paused=yes; last_activity=$current; note='Paused for UI/game'
        else
            if [[ "$paused" == yes ]]; then
                log_event 'UI returned; timer resumed'; last_activity=$current; last_wake=0; asleep=no
            fi
            paused=no
            # A virtual button can wake an already-sleeping native screen. Start
            # a fresh inactivity window in that case. While awake, virtual-only
            # activity is not visible to evdev and is an explicit limitation.
            bright=$(cat /sys/class/backlight/backlight_pwm/brightness 2>/dev/null) || bright=0
            if [[ "$asleep" == yes ]] && numeric "$bright" && ((bright>1)); then
                asleep=no; last_activity=$current; last_wake=0
                log_event 'Native screen wake observed'
            fi
            # A corrupt file during runtime must not silently apply the defaults
            # and sleep. Keep awake until a valid configuration is restored.
            if [[ "$settings_ok" != yes ]]; then action=awake
            else action=$(timer_action "$seconds" "$((current-last_activity))" "$asleep" "$input_ok"); fi
            case "$action" in
                awake)
                    note=Awake
                    [[ "$input_ok" == yes ]] || note='Input observer unavailable; keeping awake'
                    [[ "$settings_ok" == yes ]] || note='Invalid settings; keeping awake'
                    # Keep the existing native timers from expiring before our
                    # configured timer. This native call writes no preferences
                    # and does not synthesize any button events.
                    if ((current-last_wake>=2)); then
                        if display_action wake; then last_wake=$current; asleep=no
                        else note='Wake request failed'; fi
                    fi
                    ;;
                sleep)
                    if display_action sleep; then
                        asleep=yes; note=Sleeping
                        log_event "Screen slept after ${seconds}s idle ($profile)"
                    else note='Sleep request failed'; fi
                    ;;
                asleep) note=Sleeping ;;
            esac
        fi
        printf '%s\n' "$note" > "$PAD_RUN/phase"
        printf '%s %s %s %s %s\n' "$profile" "$seconds" "$((current-last_activity))" "$input_ok" "$current" > "$PAD_RUN/status.new"
        mv "$PAD_RUN/status.new" "$PAD_RUN/status"
        sleep 1 & wait $!
    done
}

install_service() {
    local template="$PAD_HOME/pager-power-display.init" staged
    [[ -f "$template" && -x "$PAD_HOME/input-watch" ]] || {
        echo 'Missing bundled init script or executable input observer.'; return 1;
    }
    # Only replace our own init script. Do not follow a symlink or overwrite an
    # unrelated service with the same name. The marker also recognizes v0.2.
    if [[ -L "$PAD_INIT" ]] || { [[ -e "$PAD_INIT" ]] &&
        ! grep -Fqx '# Independent worker, supervised by procd and optionally enabled at boot.' "$PAD_INIT"; }; then
        echo 'An unrelated init script exists; refusing to replace it.'; return 1
    fi
    # Init files contain a shell assignment. Restrict the payload path to safe
    # pathname characters before substituting it into the bundled template.
    [[ "$PAD_HOME" =~ ^/[a-zA-Z0-9_./-]+$ ]] || {
        echo 'Install the payload in a path without spaces or shell characters.'; return 1;
    }
    staged=$(mktemp "${PAD_INIT}.XXXXXX") || return 1
    if ! sed "s|^CONTROLLER=.*|CONTROLLER=$PAD_HOME/controller.sh|" "$template" > "$staged" ||
        ! chmod 755 "$staged" || ! mv "$staged" "$PAD_INIT"; then
        rm -f "$staged"; return 1
    fi
}
enable_service() {
    load_settings || return 1
    load_calibration || [[ "$(detect_power)" != unknown ]] || {
        echo 'Calibrate external power and battery first.'; return 1;
    }
    [[ -x "$PAD_HOME/input-watch" ]] || { echo 'Input observer is not installed.'; return 1; }
    install_service || return 1
    "$PAD_INIT" enable && "$PAD_INIT" start
}
disable_service() {
    [[ -e "$PAD_INIT" ]] || return 0
    "$PAD_INIT" disable || return 1
    if "$PAD_INIT" running >/dev/null 2>&1; then "$PAD_INIT" stop || return 1; fi
    # Native preferences were never changed, so no firmware reload is required.
}
status() {
    local enabled=No running=No current events=0 active='None' seconds idle input_ok updated
    "$PAD_INIT" enabled >/dev/null 2>&1 && enabled=Yes
    "$PAD_INIT" running >/dev/null 2>&1 && running=Yes
    load_settings || { echo 'Invalid timeout settings'; return 1; }
    current=$(read_current) || current=unavailable
    printf 'Service: %s | Boot: %s\nPower: %s (%s uA)\n' "$running" "$enabled" "$(detect_power)" "$current"
    printf 'Battery: %s | USB: %s\n' "$(format_timeout "$battery_seconds")" "$(format_timeout "$external_seconds")"
    if [[ "$running" == Yes ]] && read -r active seconds idle input_ok updated < "$PAD_RUN/status"; then
        printf 'Active: %s, %s\nIdle: %ss | Buttons: %s\n' "$active" "$(format_timeout "$seconds")" "$idle" "$input_ok"
        read -r events 2>/dev/null < "$PAD_RUN/input-count" || events=0
        printf 'Physical events: %s\n' "$events"
        cat "$PAD_RUN/phase"
    else echo 'Native display settings active'; fi
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-status}" in
        daemon) daemon ;;
        enable) enable_service ;;
        disable) disable_service ;;
        status) status ;;
        sample) sample ;;
        settings) save_settings "$2" "$3" ;;
        events) tail -n 10 "$PAD_RUN/events" 2>/dev/null || echo 'No events yet' ;;
        ready) load_settings && { load_calibration || [[ "$(detect_power)" != unknown ]]; } ;;
        *) echo 'Usage: controller.sh {enable|disable|status|sample|daemon|settings BATTERY USB|events|ready}' >&2; exit 2 ;;
    esac
fi
