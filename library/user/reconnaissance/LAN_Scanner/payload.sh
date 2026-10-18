#!/bin/bash
# Title: LAN Scanner
# Description: Network mapping with native discovery, diagnostics, capture and optional Nmap scanning for use with Glytch Ethernet mod or compatible USB adapter.
# Author: Hak5Darren
# Version: 1.0

_PAYLOAD_HOME=$(cd -- "${_PAYLOAD_HOME:-${PAYLOAD_HOME:-$(dirname -- "${BASH_SOURCE[0]}")}}" && pwd)
PAYLOAD_DIR=$_PAYLOAD_HOME
PROFILE_DIR=$_PAYLOAD_HOME
LOOT_DIR=/mmc/root/loot/network-scanner
NET_SYS=/sys/class/net
PROFILE=default
INTERFACE=eth1
TARGET=SUBNET
SCAN=native-ping
PORTS=fast
RETRIES=2
TIMEOUT=30
DNS=off
LINK_WAIT=30
HELP_URL=https://community.hak5.org
HELP_TEXT="LAN Scanner Help.

For use with the Glytch Ethernet Mod or a compatible USB Ethernet adapter.

Choose a Scan Type, then Tool Options and Target. Supports subnet, gateway, custom IP and CIDR. All logs are saved to loot directory. Join the Hak5 chat for community support.

https://community.hak5.org"
SPLASH_IMAGE="$_PAYLOAD_HOME/lan_scanner.png"
SPINNER_ID=
NMAP_PID=
LAST_RUN=
VERSION_SCAN_SUPPORTED=0
CUSTOM_ARGS=()
CUSTOM_SETTINGS=
source "$_PAYLOAD_HOME/native.sh"

error() { LOG "[!] $*"; PROMPT "$*"; }
stop_spinner() {
    if [[ -n $SPINNER_ID ]]; then STOP_SPINNER "$SPINNER_ID"; SPINNER_ID=; fi
}
cleanup() {
    if [[ -n $NMAP_PID ]]; then
        kill -- "-$NMAP_PID" 2>/dev/null || kill "$NMAP_PID" 2>/dev/null
        wait "$NMAP_PID" 2>/dev/null
        NMAP_PID=
    fi
    stop_spinner
}
uint() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 )); }
ipv4() {
    local a b c d part
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    for part in "$a" "$b" "$c" "$d"; do uint "$part" 0 255 || return 1; done
}
target_valid() {
    [[ $1 == SUBNET || $1 == GATEWAY ]] && return 0
    if [[ $1 == */* ]]; then
        ipv4 "${1%/*}" && uint "${1##*/}" 0 32
    else ipv4 "$1"; fi
}
ports_valid() {
    local low high
    case "$1" in fast|fast100|top1000|all) return 0;; esac
    if [[ $1 == *-* ]]; then
        low=${1%-*}; high=${1#*-}
        uint "$low" 1 65535 && uint "$high" 1 65535 && ((10#$low <= 10#$high))
    else uint "$1" 1 65535; fi
}
settings_valid() {
    [[ $INTERFACE =~ ^[a-zA-Z0-9_.:-]{1,32}$ ]] &&
    target_valid "$TARGET" &&
    [[ $SCAN =~ ^(list|ping|syn|service-light|service|native-ping|native-arp|native-nc|native-tcp|native-neigh|native-capture|native-trace|native-http|native-dns)$ ]] &&
    ports_valid "$PORTS" && uint "$RETRIES" 0 20 &&
    uint "$TIMEOUT" 0 86400 && [[ $DNS == on || $DNS == off ]] && native_settings_valid
}
subnet() {
    local cidr=$1 a b c d bits ipnum mask net
    ipv4 "${cidr%/*}" && uint "${cidr##*/}" 0 32 || return 1
    IFS=. read -r a b c d <<< "${cidr%/*}"
    bits=$((10#${cidr##*/}))
    ipnum=$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
    mask=$(( (0xffffffff << (32-bits)) & 0xffffffff ))
    net=$((ipnum & mask))
    printf '%d.%d.%d.%d/%d\n' "$(((net>>24)&255))" "$(((net>>16)&255))" "$(((net>>8)&255))" "$((net&255))" "$bits"
}
resolve_interface() {
    [[ -d $NET_SYS/$INTERFACE ]] || { error "Interface $INTERFACE missing"; return 1; }
    IFACE=$INTERFACE
}
network_ready() {
    local waited=0
    resolve_interface || return 1
    SPINNER_ID=$(START_SPINNER "Waiting for $IFACE IPv4") || return 1
    while ((waited < LINK_WAIT)); do
        ADDRESS=$(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null | awk 'NR==1 {print $4}')
        if [[ $(cat "$NET_SYS/$IFACE/carrier" 2>/dev/null) == 1 ]] && [[ -n $ADDRESS ]]; then
            stop_spinner
            EFFECTIVE_TARGET=$TARGET
            case "$TARGET" in
                SUBNET) EFFECTIVE_TARGET=$(subnet "$ADDRESS") || { error "Invalid interface IPv4 prefix"; return 1; };;
                GATEWAY) EFFECTIVE_TARGET=$(ip -4 route show default dev "$IFACE" | awk 'NR==1 {print $3}'); ipv4 "$EFFECTIVE_TARGET" || { error "No gateway on $IFACE"; return 1; };;
            esac
            LOG "Interface: $IFACE  IPv4: $ADDRESS  Target: $EFFECTIVE_TARGET"
            return 0
        fi
        sleep 1; ((waited+=1))
    done
    stop_spinner
    error "$IFACE needs link and DHCP IPv4. Timed out after ${LINK_WAIT}s."
    return 1
}
check_version_scan() {
    local version line
    VERSION_SCAN_SUPPORTED=0
    version=$(nmap --version 2>/dev/null) || return 0
    while IFS= read -r line; do
        [[ $line == "Compiled without:"* && $line == *openssl* ]] && VERSION_SCAN_SUPPORTED=1
    done <<< "$version"
    return 0
}
service_notice() {
    [[ $SCAN == service || $SCAN == service-light ]] || return 0
    if [[ $VERSION_SCAN_SUPPORTED != 1 ]]; then
        LOG "Service version probes disabled: DTLS support is unverified. Using TCP SYN scan; service labels are port-name guesses."
    fi
}
settings_key() {
    local key
    for key in "${PROFILE_KEYS[@]}"; do printf '%s|' "${!key}"; done
}
custom_active() { is_nmap && ((${#CUSTOM_ARGS[@]})) && [[ $CUSTOM_SETTINGS == "$(settings_key)" ]]; }
build_command() {
    if ! is_nmap; then native_build_command; return $?; fi
    if custom_active; then
        CMD=(nmap "${CUSTOM_ARGS[@]}" -oA "$LAST_RUN")
        return 0
    fi
    CMD=(nmap -e "$IFACE")
    [[ $DNS == off ]] && CMD+=(-n)
    case "$SCAN" in
        list) CMD+=(-sL);;
        ping) CMD+=(-sn);;
        syn) CMD+=(-sS);;
        service-light) CMD+=(-sS); [[ $VERSION_SCAN_SUPPORTED == 1 ]] && CMD+=(-sV --version-light);;
        service) CMD+=(-sS); [[ $VERSION_SCAN_SUPPORTED == 1 ]] && CMD+=(-sV);;
    esac
    case "$SCAN" in
        syn|service-light|service)
            case "$PORTS" in
                fast|fast100) CMD+=(-F);;
                top1000) CMD+=(--top-ports 1000);;
                all) CMD+=(-p-);;
                *) CMD+=(-p "$PORTS");;
            esac;;
    esac
    CMD+=(--max-retries "$RETRIES" --host-timeout "${TIMEOUT}s" --stats-every 5s -oA "$LAST_RUN" "$EFFECTIVE_TARGET")
}
command_text() {
    local word result=
    for word in "$@"; do
        printf -v word '%q' "$word"
        result+="${result:+ }$word"
    done
    printf '%s' "$result"
}
command_preview() {
    local IFACE=$INTERFACE ADDRESS EFFECTIVE_TARGET=$TARGET
    local LAST_RUN="$LOOT_DIR/scan-$(date +%Y%m%d-%H%M%S)" CMD=() VERSION_SCAN_SUPPORTED=0
    if [[ $TARGET == SUBNET && $SCAN != native-neigh && $SCAN != native-dns ]] && ! custom_active; then
        ADDRESS=$(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null | awk 'NR==1 {print $4}')
        EFFECTIVE_TARGET=$(subnet "$ADDRESS") || return 1
    fi
    if [[ $TARGET == GATEWAY && $SCAN != native-neigh && $SCAN != native-dns ]]; then
        EFFECTIVE_TARGET=$(ip -4 route show default dev "$IFACE" | awk 'NR==1 {print $3}')
        ipv4 "$EFFECTIVE_TARGET" || return 1
    fi
    is_nmap && has_tool nmap && check_version_scan
    build_command
    command_text "${CMD[@]}"
}
parse_command() {
    local input=$1 state=plain word= char active=0 i
    PARSED=()
    for ((i=0; i<${#input}; i++)); do
        char=${input:i:1}
        case "$state" in
            single)
                if [[ $char == "'" ]]; then state=plain; else word+=$char; fi;;
            double)
                case "$char" in
                    '"') state=plain;;
                    '\')
                        ((i+=1)); ((i<${#input})) || return 1
                        char=${input:i:1}
                        case "$char" in '"'|'\'|'$'|'`') word+=$char;; *) word+="\$char";; esac;;
                    *) word+=$char;;
                esac;;
            plain)
                case "$char" in
                    " "|$'\t'|$'\n')
                        if ((active)); then PARSED+=("$word"); word=; active=0; fi;;
                    "'") state=single; active=1;;
                    '"') state=double; active=1;;
                    '\')
                        ((i+=1)); ((i<${#input})) || return 1
                        word+=${input:i:1}; active=1;;
                    ';'|'|'|'&'|'<'|'>'|'`'|'$'|'('|')') return 1;;
                    *) word+=$char; active=1;;
                esac;;
        esac
    done
    [[ $state == plain ]] || return 1
    ((active)) && PARSED+=("$word")
    ((${#PARSED[@]})) && [[ ${PARSED[0]} == nmap ]]
}
edit_nmap_command() {
    is_nmap || { error "Select an Nmap scan to edit an Nmap command."; return 1; }
    local current answer edited arg i pending=()
    current=$(command_preview) || { error "Cannot build command: $INTERFACE needs an IPv4 address for Adapter subnet."; return 1; }
    answer=$(CONFIRMATION_DIALOG "Edit?: $current") || return 1
    [[ $answer == 1 ]] || return 0
    edited=$(TEXT_PICKER "Custom Nmap Command" "$current") || return 0
    [[ $edited == "$current" ]] && return 0
    parse_command "$edited" || { error "Enter an nmap command with valid quotes. Shell operators are not supported."; return 1; }
    check_version_scan
    for ((i=1; i<${#PARSED[@]}; i++)); do
        arg=${PARSED[i]}
        case "$arg" in
            -oA) ((i+=1)); ((i<${#PARSED[@]})) || { error "Missing -oA filename"; return 1; };;
            -oA?*) ;;
            -oN*|-oG*|-oX*|-oS*|--append-output|--resume*)
                error "Output files are managed by the payload. Use -oA from the displayed command."; return 1;;
            -sV|-A)
                [[ $VERSION_SCAN_SUPPORTED == 1 ]] || { error "This Nmap build cannot run service probes safely."; return 1; }
                pending+=("$arg");;
            *) pending+=("$arg");;
        esac
    done
    ((${#pending[@]})) || { error "Enter Nmap options and a target"; return 1; }
    CUSTOM_ARGS=("${pending[@]}")
    CUSTOM_SETTINGS=$(settings_key)
    LOG "Custom Nmap command selected"
}
new_scan_log() {
    local candidate suffix occupied
    while true; do
        candidate="$LOOT_DIR/scan-$(date +%Y%m%d-%H%M%S)"
        occupied=0
        for suffix in log meta nmap gnmap xml txt pcap; do
            [[ -e $candidate.$suffix || -L $candidate.$suffix ]] && occupied=1
        done
        if ((occupied)); then sleep 1; continue; fi
        if (set -C; : > "$candidate.log") 2>/dev/null; then
            LAST_RUN=$candidate
            return 0
        fi
        [[ -e $candidate.log || -L $candidate.log ]] && continue
        error "Cannot create scan log"
        return 1
    done
}
confirm_quit() {
    local answer
    answer=$(CONFIRMATION_DIALOG "Quit LAN Scanner?") || return 1
    [[ $answer == "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]]
}
show_help() { PROMPT_QR "$HELP_URL" "$HELP_TEXT"; }
scan_estimate() {
    local seconds probes per_probe ports=1
    local FIRST_IP LAST_IP HOST_COUNT NATIVE_PORTS=()
    case "$SCAN" in
        native-ping|native-arp|native-nc|native-tcp)
            target_bounds "$EFFECTIVE_TARGET" || { printf 'Unavailable: host limit %s' "$HOST_LIMIT"; return; }
            case "$SCAN" in
                native-ping) per_probe=$((PROBE_COUNT*PROBE_TIMEOUT+PROBE_COUNT-1));;
                native-arp) per_probe=$PROBE_TIMEOUT;;
                native-nc) per_probe=$((PROBE_TIMEOUT+1));;
                native-tcp) per_probe=$PROBE_TIMEOUT;;
            esac
            if [[ $SCAN == native-nc || $SCAN == native-tcp ]]; then
                native_ports || { printf Unavailable; return; }
                ports=${#NATIVE_PORTS[@]}
            fi
            probes=$((HOST_COUNT*ports))
            seconds=$(((probes+PARALLEL-1)/PARALLEL*per_probe))
            printf 'Up to about %sm %ss, plus overhead' "$((seconds/60))" "$((seconds%60))";;
        native-capture) printf 'Up to %ss' "$CAPTURE_SECONDS";;
        native-trace) printf 'Up to about %ss' "$((TRACE_HOPS*PROBE_TIMEOUT+5))";;
        native-http|native-dns) printf 'Up to about %ss' "$((PROBE_TIMEOUT*3))";;
        native-neigh) printf 'A few seconds';;
        *) printf 'Variable (Nmap controls probe timing)';;
    esac
}
execute_scan() {
    local confirm rc summary line
    settings_valid || { error "Invalid scan settings"; return 1; }
    if is_nmap; then ensure_nmap start || return $?; check_version_scan; fi
    case "$SCAN" in
        native-neigh|native-dns)
            resolve_interface || return 1
            ADDRESS=$(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null | awk 'NR==1 {print $4}')
            EFFECTIVE_TARGET=$TARGET;;
        *) network_ready || return 1;;
    esac
    if is_nmap; then service_notice
    else native_preflight || return 1; fi
    if [[ $SCAN == native-dns && $DNS_SERVER == gateway ]]; then
        ipv4 "$(ip -4 route show default dev "$IFACE" | awk 'NR==1 {print $3}')" || { error "No DNS gateway on $IFACE"; return 1; }
    fi
    if custom_active; then
        confirm=$(CONFIRMATION_DIALOG "Run $(command_preview)?
Time: $(scan_estimate). Start?") || return 1
    else
        confirm=$(CONFIRMATION_DIALOG "Run $(scan_label) on ${EFFECTIVE_TARGET:-$INTERFACE} via $IFACE.
Time: $(scan_estimate). Start?") || return 1
    fi
    [[ $confirm == "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]] || return 0
    mkdir -p "$LOOT_DIR" || { error "Cannot create loot directory"; return 1; }
    new_scan_log || return 1
    build_command
    { printf 'Command: '; printf '%q ' "${CMD[@]}"; printf '\nScan: %s\nInterface: %s\nAddress: %s\nProfile: %s\n' "$(scan_label)" "$IFACE" "$ADDRESS" "$PROFILE"; } > "${LAST_RUN}.meta"
    printf 'Version detection enabled: %s\n' "$VERSION_SCAN_SUPPORTED" >> "${LAST_RUN}.meta"
    LOG "Running $(scan_label); log ${LAST_RUN}.log"
    SPINNER_ID=$(START_SPINNER "$(scan_label) running") || return 1
    setsid "${CMD[@]}" > "${LAST_RUN}.log" 2>&1 &
    NMAP_PID=$!
    wait "$NMAP_PID"; rc=$?
    NMAP_PID=
    stop_spinner
    while IFS= read -r line || [[ -n $line ]]; do LOG "$line"; done < "${LAST_RUN}.log"
    printf 'Exit status: %s\n' "$rc" >> "${LAST_RUN}.meta"
    if is_nmap; then
        LAST_ENGINE=nmap
        summary=$(awk '/^Nmap done:/ {line=$0} END {print line}' "${LAST_RUN}.nmap" 2>/dev/null)
    else
        LAST_ENGINE=native
        cp "${LAST_RUN}.log" "${LAST_RUN}.txt"
        summary="$(scan_label) completed. Results saved."
    fi
    if ((rc != 0)); then
        error "$(scan_label) failed ($rc). See ${LAST_RUN}.log"
        return 1
    fi
    LOG "$summary"
    PROMPT "${summary:-Scan completed. See scan log.}"
    [[ $SCAN == list ]] && ! custom_active && PROMPT "List entries are addresses, not confirmed live hosts."
    view_results
}
choose_ports() {
    local choice low high
    choice=$(LIST_PICKER "TCP ports" "Fast-100" "Top-1000" "Individual" "Range" "All" "Fast-100") || return 1
    case "$choice" in
        "Fast-100") PORTS=fast;;
        "Top-1000") PORTS=top1000;;
        "All") PORTS=all;;
        Individual)
            low=$(NUMBER_PICKER "TCP port" "80") || return 1
            uint "$low" 1 65535 || { error "Port must be 1-65535"; return 1; }
            PORTS=$((10#$low));;
        Range)
            low=$(NUMBER_PICKER "First TCP port" "1") || return 1
            high=$(NUMBER_PICKER "Last TCP port" "1024") || return 1
            ports_valid "$low-$high" || { error "Invalid port range"; return 1; }
            PORTS="$((10#$low))-$((10#$high))";;
        *) return 1;;
    esac
}
choose_scan() {
    local choice speed
    choice=$(LIST_PICKER "Scan Type" "Nmap-Ping" "Nmap-Passive" "Nmap-Port" "Nmap-Service" "Native-Ping" "Native-ARP" "Netcat-TCP" "Raw-TCP" "Neighbor Cache" "Packet Capture" "Traceroute" "HTTP Headers" "DNS Lookup" "Nmap-Ping") || return 1
    case "$choice" in
        Nmap-Passive) SCAN=list;;
        Nmap-Ping) SCAN=ping;;
        Nmap-Port) choose_ports && SCAN=syn;;
        Nmap-Service)
            speed=$(LIST_PICKER "Nmap Service Speed" Fast Slow Fast) || return 1
            case "$speed" in Fast) SCAN=service-light;; Slow) SCAN=service;; esac;;
        Native-Ping) SCAN=native-ping;; Native-ARP) SCAN=native-arp;;
        Netcat-TCP) choose_native_ports && SCAN=native-nc;;
        Raw-TCP) choose_native_ports && SCAN=native-tcp;;
        'Neighbor Cache') SCAN=native-neigh;;
        'Packet Capture') SCAN=native-capture;; Traceroute) SCAN=native-trace;;
        'HTTP Headers') SCAN=native-http;; 'DNS Lookup') SCAN=native-dns;;
        *) return 1;;
    esac
    CUSTOM_ARGS=(); CUSTOM_SETTINGS=
}
choose_cidr() {
    local value default_cidr=192.168.1.0/24
    [[ $TARGET == */* ]] && default_cidr=$TARGET
    value=$(IP_PICKER "IPv4 CIDR" "$default_cidr") || return 1
    if [[ $value == */* ]] && target_valid "$value"; then
        TARGET=$(subnet "$value")
    else
        error "Enter IPv4/prefix, e.g. 192.168.1.0/24"
        return 1
    fi
}
scan_phrase() {
    if custom_active; then printf '%s' custom; return; fi
    case "$SCAN" in
        list) printf '%s' 'passively';;
        ping) printf '%s' 'with ping';;
        service-light) printf '%s' 'services (fast)';;
        service) printf '%s' 'services (slow)';;
        syn)
            case "$PORTS" in
                fast) printf '%s' 'ports (fast)';;
                top1000) printf '%s' 'top 1000 ports';;
                all) printf '%s' 'all ports';;
                *-*) printf 'port range %s' "$PORTS";;
                *) printf 'port %s' "$PORTS";;
            esac;;
    esac
}
scan_label() {
    if custom_active; then printf '%s' Nmap-Custom; return; fi
    local ports_label
    case "$PORTS" in
        fast) ports_label=Fast;;
        fast100) ports_label=Fast-100;;
        top1000) ports_label=1000;;
        all) ports_label=All;;
        *-*) ports_label="Range: $PORTS";;
        *) ports_label="Individual: $PORTS";;
    esac
    case "$SCAN" in
        list) printf '%s' Nmap-Passive;;
        ping) printf '%s' Nmap-Ping;;
        syn) printf 'Nmap-Port %s' "$ports_label";;
        service-light) printf '%s' 'Nmap-Service Fast';;
        service) printf '%s' 'Nmap-Service Slow';;
        native-ping) printf '%s' Native-Ping;; native-arp) printf '%s' Native-ARP;;
        native-nc) printf 'Netcat-TCP %s' "$ports_label";; native-tcp) printf 'Raw-TCP %s' "$ports_label";;
        native-neigh) printf '%s' 'Neighbor Cache';;
        native-capture) printf '%s' 'Packet Capture';; native-trace) printf '%s' Traceroute;;
        native-http) printf '%s' 'HTTP Headers';; native-dns) printf '%s' 'DNS Lookup';;
    esac
}
options_menu() {
    local choice value interface_item scan_item target_item before_settings command_item items=()
    while true; do
        interface_item="Interface: $INTERFACE"
        scan_item="Scan: $(scan_label)"
        case "$TARGET" in SUBNET) target_item="Target: Adapter subnet";; GATEWAY) target_item="Target: Adapter gateway";; *) target_item="Target: $TARGET";; esac
        items=("$scan_item" "Tool Options" "$target_item" "$interface_item")
        is_nmap && items+=("Nmap command")
        choice=$(LIST_PICKER "Configure" "${items[@]}" "$scan_item") || return
        before_settings=$(settings_key)
        case "$choice" in
            "Tool Options") tool_options;;
            "Nmap command") edit_nmap_command;;
            "$scan_item") choose_scan;;
            "$target_item")
                value=$(LIST_PICKER "Target" "Adapter subnet" "Adapter gateway" "IPv4 host" "IPv4 CIDR" "Adapter subnet") || continue
                case "$value" in
                    "Adapter subnet") TARGET=SUBNET;;
                    "Adapter gateway") TARGET=GATEWAY;;
                    "IPv4 host")
                        if [[ $TARGET != SUBNET && $TARGET != GATEWAY && $TARGET != */* ]]; then value=$TARGET
                        else value=192.168.1.1; fi
                        value=$(IP_PICKER "Target IPv4" "$value") || continue
                        ipv4 "$value" && TARGET=$value;;
                    "IPv4 CIDR") choose_cidr;;
                esac;;
            "$interface_item")
                value=$(TEXT_PICKER "Interface?" "$INTERFACE") || continue
                [[ $value =~ ^[a-zA-Z0-9_.:-]{1,32}$ ]] && INTERFACE=$value || error "Invalid interface name";;
            *) return;;
        esac
        if [[ $before_settings != "$(settings_key)" ]]; then CUSTOM_ARGS=(); CUSTOM_SETTINGS=; fi
    done
}
profile_name_valid() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }
save_profile() {
    local name=$1 file stamp tmp key
    profile_name_valid "$name" && settings_valid || { error "Invalid profile name or settings"; return 1; }
    mkdir -p "$PROFILE_DIR" || return 1
    file="$PROFILE_DIR/$name.cfg"
    [[ ! -L $file && ! -d $file ]] || { error "Profile target is not a regular file"; return 1; }
    if [[ -e $file ]]; then
        stamp=$(date +%Y%m%d-%H%M%S)
        while [[ -e $file.$stamp.bak || -L $file.$stamp.bak ]]; do sleep 1; stamp=$(date +%Y%m%d-%H%M%S); done
        cp -p "$file" "$file.$stamp.bak" || return 1
    fi
    tmp=$(mktemp "$PROFILE_DIR/.profile-XXXXXX") || return 1
    for key in "${PROFILE_KEYS[@]}"; do printf '%s=%s\n' "$key" "${!key}"; done > "$tmp"
    mv "$tmp" "$file" || { error "Cannot save profile"; return 1; }
    PROFILE=$name
    LOG "Saved profile $name"
}
load_profile() {
    local name=$1 key value allowed field seen=' ' count=0 expected=${#PROFILE_KEYS[@]}
    local INTERFACE TARGET SCAN PORTS RETRIES TIMEOUT DNS PROBE_TIMEOUT PROBE_COUNT PARALLEL HOST_LIMIT CAPTURE_SECONDS CAPTURE_COUNT CAPTURE_FILTER TRACE_HOPS HTTP_SCHEME HTTP_PORT HTTP_PATH DNS_NAME DNS_SERVER DNS_TYPE
    profile_name_valid "$name" && [[ -f $PROFILE_DIR/$name.cfg && ! -L $PROFILE_DIR/$name.cfg ]] || return 1
    while IFS='=' read -r key value || [[ -n $key ]]; do
        allowed=0
        for field in "${PROFILE_KEYS[@]}"; do [[ $key == "$field" ]] && allowed=1; done
        ((allowed)) && [[ $seen != *" $key "* ]] || return 1
        seen+="$key "; ((count+=1))
        printf -v "$key" '%s' "$value"
    done < "$PROFILE_DIR/$name.cfg"
    ((count == expected)) && settings_valid || return 1
    LOADED=()
    for key in "${PROFILE_KEYS[@]}"; do
        case "$key" in RETRIES|TIMEOUT|PROBE_TIMEOUT|PROBE_COUNT|PARALLEL|HOST_LIMIT|CAPTURE_SECONDS|CAPTURE_COUNT|TRACE_HOPS|HTTP_PORT) printf -v "$key" '%d' "$((10#${!key}))";; esac
        LOADED+=("${!key}")
    done
}
apply_profile() {
    local i
    load_profile "$1" || { error "Profile missing or invalid"; return 1; }
    CUSTOM_ARGS=(); CUSTOM_SETTINGS=
    for ((i=0; i<${#PROFILE_KEYS[@]}; i++)); do printf -v "${PROFILE_KEYS[i]}" '%s' "${LOADED[i]}"; done
    PROFILE=$1
}
profiles_menu() {
    local choice file name names=()
    while true; do
        choice=$(LIST_PICKER "Profiles" "Load" "Save default" "Save as" "Load") || return
        case "$choice" in
            Load)
                names=()
                for file in "$PROFILE_DIR"/*.cfg; do
                    [[ -f $file && ! -L $file ]] || continue
                    name=${file##*/}; name=${name%.cfg}
                    profile_name_valid "$name" && names+=("$name")
                done
                ((${#names[@]})) || { error "No saved profiles"; continue; }
                name=$(LIST_PICKER "Load profile" "${names[@]}" "${names[0]}") || continue
                apply_profile "$name";;
            "Save default") save_profile default;;
            "Save as") name=$(TEXT_PICKER "Profile name" "profile01") && save_profile "$name";;
            *) return;;
        esac
    done
}
page_pick() {
    local title=$1 start=0 choice item items=() page=()
    shift; items=("$@")
    ((${#items[@]})) || return 1
    while true; do
        page=("${items[@]:start:20}")
        ((start>0)) && page+=("Previous page")
        ((start+20<${#items[@]})) && page+=("Next page")
        choice=$(LIST_PICKER "$title" "${page[@]}" "${page[0]}") || return 1
        case "$choice" in
            "Next page") ((start+=20));;
            "Previous page") ((start-=20));;
            *) printf '%s\n' "$choice"; return 0;;
        esac
    done
}
host_records() { awk '/^Host:/ {print $2}' "$1" | sort -u; }
port_records() {
    awk -v ip="$2" '/^Nmap scan report for / {active=($NF==ip || $NF=="("ip")")} active && /^[0-9]+\/(tcp|udp)[[:space:]]/ {print}' "$1"
}
view_results() {
    if [[ $LAST_ENGINE == native ]]; then native_results; return; fi
    local host choice line details hosts=() ports=()
    [[ -n $LAST_RUN && -f ${LAST_RUN}.gnmap ]] || { error "No results yet"; return; }
    while IFS= read -r host; do ipv4 "$host" && hosts+=("$host"); done < <(host_records "${LAST_RUN}.gnmap")
    ((${#hosts[@]})) || { PROMPT "No host entries. See $LAST_RUN"; return; }
    while host=$(page_pick "Scan host entries" "${hosts[@]}"); do
        choice=$(LIST_PICKER "$host" "View ports" "Set target" "Scan host now" "View ports") || continue
        case "$choice" in
            "Set target") TARGET=$host; LOG "Target set to $host"; return;;
            "Scan host now") TARGET=$host; choose_scan && execute_scan; return;;
            "View ports")
                ports=()
                while IFS= read -r line; do [[ -n $line ]] && ports+=("$line"); done < <(port_records "${LAST_RUN}.nmap" "$host")
                if ((${#ports[@]})); then
                    while line=$(page_pick "$host ports" "${ports[@]}"); do PROMPT "$host
$line"; done
                else PROMPT "No reported ports for $host. Discovery/list scans do not scan ports; see full loot for filtered or closed ports."; fi;;
        esac
    done
}
main() {
    local helper choice
    for helper in ip awk bash timeout setsid LIST_PICKER IP_PICKER NUMBER_PICKER TEXT_PICKER PROMPT PROMPT_QR PROMPT_IMAGE LOG START_SPINNER STOP_SPINNER CONFIRMATION_DIALOG WAIT_FOR_BUTTON_PRESS mktemp; do
        command -v "$helper" >/dev/null || { printf 'Missing command: %s\n' "$helper" >&2; return 1; }
    done
    PROMPT_IMAGE "$SPLASH_IMAGE" || :
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ -f $PROFILE_DIR/default.cfg ]]; then apply_profile default; fi
    LOG "LAN Scanner 2.0: native tools and optional Nmap"
    ensure_nmap startup
    ((EXIT_REQUESTED)) && return 1
    while true; do
        choice=$(LIST_PICKER "LAN Scanner" "Start Scan" "Configure" "Profiles" "Scan Results" "Payload Log" "Help" "Quit" "Start Scan") || choice=Quit
        case "$choice" in
            "Start Scan") execute_scan; ((EXIT_REQUESTED)) && return 1;;
            Configure) options_menu;;
            Profiles) profiles_menu;;
            "Scan Results") view_results;;
            "Payload Log") LOG "Press B to return to the Main Menu"; WAIT_FOR_BUTTON_PRESS B;;
            Help) show_help;;
            Quit) confirm_quit && return 0;;
            *) continue;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${1:-} == --worker ]]; then shift; native_worker "$@"
    else main "$@"; fi
fi
