# Title:        Custom NMAP Scan
# Description:  Custom nmap scan with zenmap style, you choose the scan type
# Author:       0xmupa
# Version:      1.0

LOOTDIR=/root/loot/nmapcust

# Scan types (zenmap style)

scan_names=(
"Quick scan"
"Quick scan plus"
"Intense scan"
"Intense scan no ping"
"Ping scan"
"TCP SYN scan"
"UDP scan"
"Full port scan"
"Custom scan (manual flags)"
)

scan_options_flags=(
"-T4 -F"
"-T4 -F -sV -O"
"-T4 -A"
"-T4 -A -Pn"
"-sn"
"-sS"
"-sU --top-ports 100"
"-p- -T4"
""
)

# Menu Prompt, and scan type selection
menu=""
i=1
for s in "${scan_names[@]}"; do
    menu+="$i) $s\n"
    i=$((i+1))
done

PROMPT "Select scan type:\n\n$menu"
scan_id=$(NUMBER_PICKER "Scan number" "1")

scan_name=${scan_names[$scan_id-1]}
scan_flags=${scan_options_flags[$scan_id-1]}

# If the chosen option is custom, the user can choose the nmap flags.
if [ "$scan_id" -eq 9 ]; then
    scan_flags=$(TEXT_PICKER "Enter the nmap flags" "")
fi

# Target selection, and loot preparation
PROMPT "Target type:\n1) Manual input\n2) Connected subnet"
target_mode=$(NUMBER_PICKER "Target option" "1")

if [ "$target_mode" -eq 1 ]; then
    target=$(TEXT_PICKER "IP or subnet" "192.168.1.1")

elif [ "$target_mode" -eq 2 ]; then
    nets=$(ip -o -f inet addr show | awk '/scope global/ {print $4}')
    net_arr=($nets)
    net_menu=$(echo "$nets" | awk '{print NR")",$0}')

    PROMPT "Available subnets:\n\n$net_menu"
    net_id=$(NUMBER_PICKER "Subnet number" "1")
    target=${net_arr[$net_id-1]}
fi

mkdir -p $LOOTDIR
ts=$(date +%Y%m%d_%H%M%S)
outfile=$LOOTDIR/$ts

# log info
LOG "scan   : $scan_name"
LOG "flags   : $scan_flags"
LOG "target : $target"
LOG "output : $outfile"
LOG "starting nmap...\n"

# Run scan
nmap $scan_flags -oA $outfile $target \
| tr '\n' '\0' \
| xargs -0 -n 1 LOG

LOG "\ndone."