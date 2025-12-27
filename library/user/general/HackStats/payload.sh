#!/bin/sh
# TITLE HACKSTATS
# AUTHOR Unit98.1
# DESCRIPTION Get stats on handshake & pcap captures

shakes=$(/root/loot/handshakes/)
shakecount=$(find /root/loot/handshakes -maxdepth 1 -type f -name '*.22000' | wc -l)
crackable=$(find /root/loot/handshakes -maxdepth 1 -type f -name '*handshake.22000' | wc -l)
pcaps=$(find /root/loot/handshakes -maxdepth 1 -type f -name '*.pcap' | wc -l)
busy=0

if [ "$shakecount" -gt 0 ]; then
    busy=1
fi

#Logging stats (update to include what you wish)
if [ "$busy" -eq 1 ]; then
    LOG "You've been busy!"
    LOG "Check out your stats below! \n"
    LOG "Total Handshakes: $shakecount"
    LOG "Full Handshakes: $crackable"
    LOG "Count of PCAP files: $pcaps"
    ALERT "#@ HACK THE PLANET @# \n\n Crackable handshakes are waiting... \n Find them in: \n /root/loot/handshakes/"
else
    LOG "Not much to show here -.- \n Get Hacking!"
fi