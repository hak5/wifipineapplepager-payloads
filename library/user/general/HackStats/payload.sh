#!/bin/sh
# TITLE HACKSTATS
# AUTHOR Unit98.1
# DESCRIPTION Get stats on handshake & pcap captures + print AP/SSID from pcaps

HANDSHAKE_DIR="/root/loot/handshakes"

shakecount=$(find "$HANDSHAKE_DIR" -maxdepth 1 -type f -name '*.22000' | wc -l)
crackable=$(find "$HANDSHAKE_DIR" -maxdepth 1 -type f -name '*handshake.22000' | wc -l)
pcaps=$(find "$HANDSHAKE_DIR" -maxdepth 1 -type f -name '*.pcap' | wc -l)
busy=0

if [ "$shakecount" -gt 0 ]; then
  busy=1
fi

extract_ssid_from_pcap() {
  strings "$1" 2>/dev/null | grep -v '^$' | head -n 1
}

if [ "$busy" -eq 1 ]; then
  LOG "You've been busy!"
  LOG "Check out your stats below! \n"
  LOG "Total Handshakes: $shakecount"
  LOG "Full Handshakes: $crackable"
  LOG "Count of PCAP files: $pcaps"
  LOG "\nAP/SSID from PCAPs:"

  find "$HANDSHAKE_DIR" -maxdepth 1 -type f \( -name '*.pcap' -o -name '*.cap' \) -print0 \
  | while IFS= read -r -d '' p; do
      base=$(basename "$p")
      ssid=$(extract_ssid_from_pcap "$p")
      [ -z "$ssid" ] && ssid="[UNKNOWN]"
      printf "%s | %s\n" "$base" "$ssid"
    done \
  | tr '\n' '\0' \
  | xargs -0 -n 1 LOG

  ALERT "#@ HACK THE PLANET @# \n\n Crackable handshakes are waiting... \n Find them in: \n /root/loot/handshakes/"
else
  LOG "Not much to show here -.- \n Get Hacking!"
fi