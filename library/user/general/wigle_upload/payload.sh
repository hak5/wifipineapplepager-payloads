#!/bin/bash
# Title: Wigle Upload
# Author: marcdel
# Description: Upload captured data to Wigle.net
# Version: 1.0

LOG "Uploading $(ls -1 /root/loot/wigle | wc -l) files to wigle.net"
WIGLE_UPLOAD --archive /root/loot/wigle/*.csv