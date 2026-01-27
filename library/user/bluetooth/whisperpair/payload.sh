#!/bin/bash
# Title: WhisperPair PoC
# Author: Bazskillz (Hak5Darren adaptation)
# Description: WhisperPair Proof-of-Concept (PoC) for CVE-2025-36911, a vulnerability in the Google Fast Pair Service (GFPS).

# This PoC of a PoC requires python dependencies, which this payload will not automatically install
# Install using:
# opkg update
# opkg install --dest mmc python3 python3-bleak python3-colorama python3-cryptography

# This is based on the PoC by Bazskillz from https://github.com/Bazskillz/WhisperPair-PoC/tree/main
# The only modification to the python script is a log_print function to use the LOG DuckyScript command

# I whipped this up at 1:30 AM, so it's just proving functionality. I'm too tired to keep at it right now.
# I could see this being improved with:
# - A dependency detection/install (to mmc with --dest mmc as these packages are large)
# - Targeting by MAC using the MAC_PICKER DuckyScript command
# - Cleaning up the log_print commands to better fit the Pager display (text wrapping)
# - Interactivity (big question mark)

python3 /root/payloads/user/bluetooth/whisperpair/fast_pair_demo.py
