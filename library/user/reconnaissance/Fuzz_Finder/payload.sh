#!/bin/bash
# Title: FuzzFinder
# inspired by NyanBOX (nyandevices.com)
# Author: OSINTI4L
# Description: Scans for Axon devices and alerts user if they're present.
# Version: 1.0

LOG green ""
LOG blue "Scanning for Axon devices.."
LOG green ""

fuzzfound="false"
for i in {5..1}; do
	scan=$(timeout -s INT 10s hcitool lescan | grep -e '00:25:DF' -e '00:58:28' -e '00:C0:D4' -e '84:70:03')
		if [ -n "$scan" ]; then
			fuzzfound="true"
			break
		else
			if [ "$i" -gt 1 ]; then
				LOG green "No Axon devices detected."
				LOG blue "Scans remaining: $(( i - 1 ))"
				LOG blue "Re-scanning.."
				LOG blue ""
				sleep 2
			else
				break
			fi
		fi
done

if [ "$fuzzfound" = "true" ]; then
	ALERT "AXON DEVICE DETECTED!"
	LOG red "Device information: $scan"
	LOG blue ""
	LOG blue "Exiting."
	exit 0
else
	LOG green "No Axon devices detected, exiting."
	exit 0
fi
