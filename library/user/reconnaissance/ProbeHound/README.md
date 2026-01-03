**Version 1.0**
**Author:** Doc Voom

# Purpose
ProbeHound is a tool inspired by "Chasing Your Tail" by Matt Edmondson, but in a stripped-down form. This tool sniffs probe requests to detect clients nearby that are probing for a target network - i.e. you want to know if anyone around you regularly connects to the network at company XYZ.

# Operation
ProbeHound uses tcpdump to sniff for probe request and then filters the requests based off of a target SSID. It is important to note that the tool specifically uses the network name and not the MAC address. SSIDs can be selected from the PineAP SSID Pool, or manually entered. Manual entry accepts partial names, though the more complete the name, the more accurate the search will be.

When a client is detected, an alert tone will play and the client's MAC address, signal strength, and the target SSID will be displayed. After detection, the script will pause and ask user if they wish to continue sniffing or exit.

Detected results are stored in a log folder as a text file ("DATE-scanlog.txt"). Log files are designed to keep each day's scans in one file (same day, same file).

The alert ringtone can be selected by changing the file name referenced in the ALERT_TONE variable.

# Acknowledgments
This is my first Bash script, and so could not have been done without examining the work of others. The script for selecting a target from the SSID Pool was adapted from "Device_Hunter" by RocketGod and NotPike Helped (Crew: The Pirates' Plunder). Also, thanks to dark_pyrro on the Hak5 Forum for helping me with my initial roadblock in developing this idea.