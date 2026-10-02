# <--FOR EDUCATIONAL PURPOSES ONLY-->

Name: wifi snatcher/viewer

Author: f3bandit

Version: 3.0

Devices: omg cable, wifi pager

OS: windows 11

# wifi_snatcher-viewer

web server payload for file tranfers to and from the pager for attacks

viewer payload for viewing the wifi credential xml files

magic.ps1 script that's downloaded to the target and executed by the omg cable


# Files:

omg/omg_payload = copy and paste into omg cable payload slot

magic/magic.ps1 -> copy to -> /mmc/root/scripts on the pager

/payload.sh -> copy to -> /mmc/root/payloads/user/exfiltration/wifi_loot_viewer

wifi_snatcher_server/payload.sh -> copy to -> /mmc/root/payloads/user/exfiltration/wifi_snatcher_server <--"This server only runs while payload is active!!!"

python_server_service/payload.sh -> copy to -> /mmc/root/payloads/user/exfiltration/python_server <--"This server runs as a service it will remain running till stopped manually!!!"



