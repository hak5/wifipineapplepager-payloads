#!/bin/bash

PROBE_TIMEOUT=2
PROBE_COUNT=1
PARALLEL=4
HOST_LIMIT=1024
CAPTURE_SECONDS=10
CAPTURE_COUNT=100
CAPTURE_FILTER='arp or icmp'
TRACE_HOPS=12
HTTP_SCHEME=http
HTTP_PORT=80
HTTP_PATH=/
DNS_NAME=example.com
DNS_SERVER=system
DNS_TYPE=a
LAST_ENGINE=
EXIT_REQUESTED=0
PROFILE_KEYS=(INTERFACE TARGET SCAN PORTS RETRIES TIMEOUT DNS PROBE_TIMEOUT PROBE_COUNT PARALLEL HOST_LIMIT CAPTURE_SECONDS CAPTURE_COUNT CAPTURE_FILTER TRACE_HOPS HTTP_SCHEME HTTP_PORT HTTP_PATH DNS_NAME DNS_SERVER DNS_TYPE)

is_nmap() { [[ $SCAN =~ ^(list|ping|syn|service-light|service)$ ]]; }
has_tool() { command -v "$1" >/dev/null 2>&1; }
domain_valid() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ ]]; }
native_settings_valid() {
    uint "$PROBE_TIMEOUT" 1 30 && uint "$PROBE_COUNT" 1 5 &&
    uint "$PARALLEL" 1 16 && uint "$HOST_LIMIT" 1 4096 &&
    uint "$CAPTURE_SECONDS" 1 300 && uint "$CAPTURE_COUNT" 1 10000 &&
    uint "$TRACE_HOPS" 1 30 && uint "$HTTP_PORT" 1 65535 &&
    [[ $HTTP_SCHEME == http || $HTTP_SCHEME == https ]] &&
    [[ $HTTP_PATH == /* && $HTTP_PATH != *$'\n'* && $HTTP_PATH != *$'\r'* ]] &&
    ((${#HTTP_PATH}<=256)) && domain_valid "$DNS_NAME" &&
    [[ $DNS_TYPE =~ ^(a|aaaa|ptr|mx|txt|ns|soa|cname)$ ]] &&
    { [[ $DNS_SERVER == system || $DNS_SERVER == gateway ]] || ipv4 "$DNS_SERVER"; } &&
    [[ -n $CAPTURE_FILTER && $CAPTURE_FILTER != *$'\n'* && $CAPTURE_FILTER != *$'\r'* ]] &&
    ((${#CAPTURE_FILTER}<=256))
}
internet_available() {
    local url
    for url in https://downloads.openwrt.org/ https://nmap.org/; do
        if has_tool curl; then
            curl --fail --silent --show-error --location --connect-timeout 5 --max-time 10 --output /dev/null "$url" && return 0
        elif has_tool wget; then
            timeout 12 wget -q -O /dev/null "$url" && return 0
        fi
    done
    return 1
}
spin_step() {
    local title=$1 logfile=$2 rc
    shift 2
    SPINNER_ID=$(START_SPINNER "$title") || return 1
    if [[ $(type -t "$1") == function ]]; then
        "$@" >> "$logfile" 2>&1 &
    else
        setsid "$@" >> "$logfile" 2>&1 &
    fi
    NMAP_PID=$!
    wait "$NMAP_PID"; rc=$?
    NMAP_PID=
    stop_spinner
    return "$rc"
}
ensure_nmap() {
    local stage=${1:-start} answer logfile base
    if has_tool nmap; then LOG "Nmap installed: $(nmap --version | head -n 1)"; return 0; fi
    answer=$(CONFIRMATION_DIALOG "Nmap is not installed. Install it now?") || answer=0
    if [[ $answer != 1 ]]; then
        [[ $stage == start ]] && error "Nmap is required for this scan. Choose a native scan or install Nmap."
        return 1
    fi
    if ! has_tool opkg; then error "opkg is unavailable. Cannot install Nmap."; EXIT_REQUESTED=1; return 2; fi
    mkdir -p "$LOOT_DIR" || { error "Cannot create installation log"; EXIT_REQUESTED=1; return 2; }
    base=$(mktemp "$LOOT_DIR/install-$(date +%Y%m%d-%H%M%S)-XXXXXX") || { EXIT_REQUESTED=1; return 2; }
    logfile="$base.log"
    [[ ! -e $logfile && ! -L $logfile ]] && mv "$base" "$logfile" || { error "Cannot create installation log"; EXIT_REQUESTED=1; return 2; }
    if ! spin_step "Checking Internet access" "$logfile" internet_available; then
        error "No Internet access was available. LAN Scanner will exit."
        EXIT_REQUESTED=1; return 2
    fi
    if ! spin_step "Updating package lists" "$logfile" opkg update; then
        error "opkg update failed. See $logfile."
        EXIT_REQUESTED=1; return 2
    fi
    if ! spin_step "Installing Nmap" "$logfile" opkg install nmap || ! has_tool nmap; then
        error "Nmap installation failed. See $logfile."
        EXIT_REQUESTED=1; return 2
    fi
    LOG "Nmap installation completed"
    return 0
}
native_tool() {
    case "$SCAN" in
        native-ping) printf ping;; native-arp) printf arping;;
        native-nc) printf nc;; native-tcp) printf bash;;
        native-neigh) printf ip;;
        native-capture) printf tcpdump;; native-trace) printf traceroute;;
        native-http) printf curl;; native-dns) printf nslookup;;
    esac
}
ip_number() {
    local a b c d
    ipv4 "$1" || return 1
    IFS=. read -r a b c d <<< "$1"
    printf '%s' "$(((10#$a<<24)|(10#$b<<16)|(10#$c<<8)|10#$d))"
}
number_ip() { printf '%d.%d.%d.%d\n' "$((($1>>24)&255))" "$((($1>>16)&255))" "$((($1>>8)&255))" "$(($1&255))"; }
target_bounds() {
    local cidr bits total
    if [[ $1 == */* ]]; then
        cidr=$(subnet "$1") || return 1
        bits=${cidr##*/}; total=$((1 << (32-bits)))
        FIRST_IP=$(ip_number "${cidr%/*}"); LAST_IP=$((FIRST_IP+total-1))
        if ((bits<31)); then ((FIRST_IP+=1)); ((LAST_IP-=1)); fi
    else FIRST_IP=$(ip_number "$1") || return 1; LAST_IP=$FIRST_IP; fi
    HOST_COUNT=$((LAST_IP-FIRST_IP+1))
    ((HOST_COUNT<=HOST_LIMIT))
}
native_ports() {
    local p low high
    NATIVE_PORTS=()
    case "$PORTS" in
        fast) NATIVE_PORTS=(21 22 23 25 53 80 110 135 139 143 443 445 465 587 993 995 3389 8080 8081 8443);;
        fast100) NATIVE_PORTS=(7 9 13 21 22 23 25 26 37 53 79 80 81 88 106 110 111 113 119 135 139 143 144 179 199 389 427 443 444 445 465 513 514 515 543 544 548 554 587 631 646 873 990 993 995 1025 1026 1027 1028 1029 1110 1433 1720 1723 1755 1900 2000 2001 2049 2121 2717 3000 3128 3306 3389 3986 4899 5000 5009 5051 5060 5101 5190 5357 5432 5631 5666 5800 5900 6000 6001 6646 7070 8000 8008 8009 8080 8081 8443 8888 9100 9999 10000 32768 49152 49153 49154 49155 49156 49157);;
        top1000|all) return 1;;
        *-*) low=${PORTS%-*}; high=${PORTS#*-};
            ports_valid "$PORTS" && ((10#$high-10#$low<1024)) || return 1
            for ((p=10#$low; p<=10#$high; p++)); do NATIVE_PORTS+=("$p"); done;;
        *) NATIVE_PORTS=("$((10#$PORTS))");;
    esac
    ((${#NATIVE_PORTS[@]}<=1024))
}
native_preflight() {
    local tool route
    tool=$(native_tool)
    has_tool "$tool" || { error "$tool is unavailable. Choose another scan type."; return 1; }
    case "$SCAN" in
        native-ping|native-arp|native-nc|native-tcp)
            target_bounds "$EFFECTIVE_TARGET" || { error "Target exceeds the native limit of $HOST_LIMIT hosts. Use a smaller CIDR."; return 1; };;
        native-trace|native-http)
            ipv4 "$EFFECTIVE_TARGET" || { error "Choose an IPv4 host or Adapter gateway for this scan."; return 1; };;
    esac
    if [[ $SCAN == native-arp ]]; then
        [[ -f $NET_SYS/$IFACE/type && $(cat "$NET_SYS/$IFACE/type") == 1 ]] || { error "ARP requires an Ethernet-compatible interface."; return 1; }
        local first=$FIRST_IP last=$LAST_IP base end
        local HOST_LIMIT=4294967296
        target_bounds "$ADDRESS" || return 1
        base=$FIRST_IP; end=$LAST_IP
        FIRST_IP=$first; LAST_IP=$last; HOST_COUNT=$((last-first+1))
        ((first>=base && last<=end)) || { error "ARP targets must be on the interface's local subnet."; return 1; }
    fi
    if [[ $SCAN == native-nc || $SCAN == native-tcp ]]; then
        native_ports || { error "Native TCP supports Fast-20, Fast-100, Individual, or Range (up to 1024 ports)."; return 1; }
        ((HOST_COUNT*${#NATIVE_PORTS[@]}<=4096)) || { error "Native TCP is limited to 4096 connection attempts. Reduce hosts or ports."; return 1; }
        if [[ $SCAN == native-tcp ]]; then
            route=$(ip -4 route get "$(number_ip "$FIRST_IP")" 2>/dev/null)
            [[ " $route " == *" dev $IFACE "* ]] || { error "Raw TCP uses system routing. This target does not route via $IFACE. Use Netcat TCP for source binding."; return 1; }
        fi
    fi
    if [[ $SCAN == native-capture ]]; then
        tcpdump -i "$IFACE" -d "$CAPTURE_FILTER" >/dev/null 2>&1 || { error "Invalid tcpdump filter"; return 1; }
    fi
}
native_build_command() {
    local server=$DNS_SERVER filter=$CAPTURE_FILTER
    case "$SCAN" in
        native-neigh) CMD=(ip -4 neigh show dev "$IFACE");;
        native-trace) CMD=(timeout "$((TRACE_HOPS*PROBE_TIMEOUT+5))" traceroute -n -i "$IFACE" -m "$TRACE_HOPS" -q 1 -w "$PROBE_TIMEOUT" "$EFFECTIVE_TARGET");;
        native-http) CMD=(curl --interface "$IFACE" --connect-timeout "$PROBE_TIMEOUT" --max-time "$((PROBE_TIMEOUT*3))" --silent --show-error --head "$HTTP_SCHEME://$EFFECTIVE_TARGET:$HTTP_PORT$HTTP_PATH");;
        native-dns)
            if [[ $server == gateway ]]; then
                server=$(ip -4 route show default dev "$IFACE" | awk 'NR==1 {print $3}')
                ipv4 "$server" || return 1
            fi
            CMD=(timeout "$((PROBE_TIMEOUT*3))" nslookup "-type=$DNS_TYPE" "$DNS_NAME")
            [[ $server != system && -n $server ]] && CMD+=("$server");;
        *) CMD=(bash "$_PAYLOAD_HOME/payload.sh" --worker "$SCAN" "$IFACE" "$ADDRESS" "$EFFECTIVE_TARGET" "$PORTS" "$PROBE_TIMEOUT" "$PROBE_COUNT" "$PARALLEL" "$HOST_LIMIT" "$CAPTURE_SECONDS" "$CAPTURE_COUNT" "$filter" "$LAST_RUN");;
    esac
    return 0
}
native_probe() {
    local host=$1 port=${2:-} rc
    case "$SCAN" in
        native-ping) ping -q -I "$IFACE" -c "$PROBE_COUNT" -W "$PROBE_TIMEOUT" "$host" >/dev/null 2>&1; rc=$?;;
        native-arp) arping -f -I "$IFACE" -c "$PROBE_COUNT" -w "$PROBE_TIMEOUT" "$host" >/dev/null 2>&1; rc=$?;;
        native-nc) timeout "$((PROBE_TIMEOUT+1))" nc -n -z -w "$PROBE_TIMEOUT" -s "${ADDRESS%/*}" "$host" "$port" >/dev/null 2>&1; rc=$?;;
        native-tcp) timeout "$PROBE_TIMEOUT" bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$host" "$port" >/dev/null 2>&1; rc=$?;;
    esac
    if ((rc==0)); then
        if [[ -n $port ]]; then printf '%s tcp/%s open\n' "$host" "$port"
        else printf '%s responsive\n' "$host"; fi
    fi
    return 0
}
native_worker() {
    SCAN=$1 IFACE=$2 ADDRESS=$3 EFFECTIVE_TARGET=$4 PORTS=$5 PROBE_TIMEOUT=$6 PROBE_COUNT=$7 PARALLEL=$8 HOST_LIMIT=$9
    CAPTURE_SECONDS=${10} CAPTURE_COUNT=${11} CAPTURE_FILTER=${12} LAST_RUN=${13}
    local host p i rc pids=() batch=0
    INTERFACE=$IFACE; TARGET=$EFFECTIVE_TARGET
    settings_valid || return 2
    [[ $SCAN == native-ping || $SCAN == native-arp || $SCAN == native-nc || $SCAN == native-tcp || $SCAN == native-capture ]] || return 2
    if [[ $SCAN == native-capture ]]; then
        local filter="$CAPTURE_FILTER"
        [[ $EFFECTIVE_TARGET == */* ]] && filter="($filter) and net $EFFECTIVE_TARGET" || filter="($filter) and host $EFFECTIVE_TARGET"
        timeout -s INT "$CAPTURE_SECONDS" tcpdump -n -p -i "$IFACE" -s 96 -c "$CAPTURE_COUNT" -w "$LAST_RUN.pcap" "$filter"
        rc=$?
        if ((rc!=0 && rc!=124 && rc!=130)); then return "$rc"; fi
        printf 'Capture saved: %s.pcap\n' "$LAST_RUN"
        tcpdump -n -r "$LAST_RUN.pcap" -c "$CAPTURE_COUNT"
        return $?
    fi
    target_bounds "$EFFECTIVE_TARGET" || return 2
    if [[ $SCAN == native-nc || $SCAN == native-tcp ]]; then
        native_ports || return 2
        ((HOST_COUNT*${#NATIVE_PORTS[@]}<=4096)) || return 2
    fi
    printf 'Mode: %s; target: %s; interface: %s; hosts: %s\n' "$SCAN" "$EFFECTIVE_TARGET" "$IFACE" "$HOST_COUNT"
    for ((i=FIRST_IP; i<=LAST_IP; i++)); do
        host=$(number_ip "$i")
        if [[ $SCAN == native-ping || $SCAN == native-arp ]]; then
            native_probe "$host" & pids+=("$!"); ((batch+=1))
            if ((batch>=PARALLEL)); then for p in "${pids[@]}"; do wait "$p"; done; pids=(); batch=0; fi
        else
            for p in "${NATIVE_PORTS[@]}"; do
                native_probe "$host" "$p" & pids+=("$!"); ((batch+=1))
                if ((batch>=PARALLEL)); then for p in "${pids[@]}"; do wait "$p"; done; pids=(); batch=0; fi
            done
        fi
    done
    for p in "${pids[@]}"; do wait "$p"; done
    printf 'Native scan completed. No response does not prove a host or port is absent.\n'
    return 0
}
native_results() {
    local line lines=() text
    [[ -n $LAST_RUN && -f $LAST_RUN.txt ]] || { error "No results yet"; return; }
    while IFS= read -r line; do [[ -n $line ]] && lines+=("$line"); ((${#lines[@]}>=500)) && break; done < "$LAST_RUN.txt"
    ((${#lines[@]})) || { PROMPT "No entries. See $LAST_RUN.log"; return; }
    while text=$(page_pick "Scan Results" "${lines[@]}"); do PROMPT "$text"; done
}
pick_number() {
    local key=$1 title=$2 low=$3 high=$4 value
    value=$(NUMBER_PICKER "$title" "${!key}") || return 1
    uint "$value" "$low" "$high" || { error "Enter $low-$high"; return 1; }
    printf -v "$key" '%d' "$((10#$value))"
}
tool_options() {
    local choice value items=()
    while true; do
        items=()
        if is_nmap; then items=("Ports: $PORTS" "Max Retries: $RETRIES" "Host Timeout: ${TIMEOUT}s" "DNS Lookup: $DNS")
        else
            case "$SCAN" in
                native-ping|native-arp) items=("Probe Timeout: ${PROBE_TIMEOUT}s" "Probe Count: $PROBE_COUNT" "Parallel: $PARALLEL" "Host Limit: $HOST_LIMIT");;
                native-nc|native-tcp) items=("Ports: $PORTS" "Probe Timeout: ${PROBE_TIMEOUT}s" "Parallel: $PARALLEL" "Host Limit: $HOST_LIMIT");;
                native-capture) items=("Capture Time: ${CAPTURE_SECONDS}s" "Packet Limit: $CAPTURE_COUNT" "Filter: $CAPTURE_FILTER");;
                native-trace) items=("Max Hops: $TRACE_HOPS" "Probe Timeout: ${PROBE_TIMEOUT}s");;
                native-http) items=("Protocol: $HTTP_SCHEME" "HTTP Port: $HTTP_PORT" "Path: $HTTP_PATH" "Probe Timeout: ${PROBE_TIMEOUT}s");;
                native-dns) items=("Query: $DNS_NAME" "DNS Server: $DNS_SERVER" "Record: $DNS_TYPE" "Probe Timeout: ${PROBE_TIMEOUT}s");;
                *) PROMPT "No additional options for $(scan_label)."; return;;
            esac
        fi
        choice=$(LIST_PICKER "Tool Options" "${items[@]}" "${items[0]}") || return
        case "$choice" in
            'Ports:'*) if is_nmap; then choose_ports; else choose_native_ports; fi;;
            'Max Retries:'*) pick_number RETRIES 'Retries 0-20' 0 20;;
            'Host Timeout:'*) pick_number TIMEOUT 'Seconds (0=unlimited)' 0 86400;;
            'DNS Lookup:'*) value=$(LIST_PICKER "Reverse DNS" off on "$DNS") && DNS=$value;;
            'Probe Timeout:'*) pick_number PROBE_TIMEOUT 'Probe timeout seconds' 1 30;;
            'Probe Count:'*) pick_number PROBE_COUNT 'Probe count 1-5' 1 5;;
            'Parallel:'*) pick_number PARALLEL 'Parallel probes 1-16' 1 16;;
            'Host Limit:'*) pick_number HOST_LIMIT 'Host limit 1-4096' 1 4096;;
            'Capture Time:'*) pick_number CAPTURE_SECONDS 'Capture seconds' 1 300;;
            'Packet Limit:'*) pick_number CAPTURE_COUNT 'Packet limit' 1 10000;;
            'Max Hops:'*) pick_number TRACE_HOPS 'Max hops 1-30' 1 30;;
            'HTTP Port:'*) pick_number HTTP_PORT 'HTTP port' 1 65535;;
            'Protocol:'*) value=$(LIST_PICKER "Protocol" http https "$HTTP_SCHEME") && HTTP_SCHEME=$value;;
            'Record:'*) value=$(LIST_PICKER "DNS Record" a aaaa ptr mx txt ns soa cname "$DNS_TYPE") && DNS_TYPE=$value;;
            'Filter:'*) value=$(TEXT_PICKER "Capture Filter" "$CAPTURE_FILTER") && [[ -n $value && ${#value} -le 256 && $value != *$'\n'* && $value != *$'\r'* ]] && CAPTURE_FILTER=$value;;
            'Path:'*) value=$(TEXT_PICKER "HTTP Path" "$HTTP_PATH") && [[ $value == /* && ${#value} -le 256 && $value != *$'\n'* && $value != *$'\r'* ]] && HTTP_PATH=$value;;
            'Query:'*) value=$(TEXT_PICKER "DNS Query" "$DNS_NAME") && domain_valid "$value" && DNS_NAME=$value;;
            'DNS Server:'*) value=$(TEXT_PICKER "DNS Server" "$DNS_SERVER") && { [[ $value == system || $value == gateway ]] || ipv4 "$value"; } && DNS_SERVER=$value;;
        esac
        CUSTOM_ARGS=(); CUSTOM_SETTINGS=
    done
}
choose_native_ports() {
    local choice low high
    choice=$(LIST_PICKER "TCP Ports" Fast-20 Fast-100 Individual Range Fast-20) || return 1
    case "$choice" in
        Fast-20) PORTS=fast;;
        Fast-100) PORTS=fast100;;
        Individual) low=$(NUMBER_PICKER "TCP port" "80") || return 1; uint "$low" 1 65535 && PORTS=$((10#$low));;
        Range)
            low=$(NUMBER_PICKER "First TCP port" "80") || return 1
            high=$(NUMBER_PICKER "Last TCP port" "99") || return 1
            ports_valid "$low-$high" && ((10#$high-10#$low<1024)) || { error "Choose a range of up to 1024 ports"; return 1; }
            PORTS="$((10#$low))-$((10#$high))";;
    esac
}
