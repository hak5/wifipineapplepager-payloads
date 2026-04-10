<--FOR EDUCATIONAL PURPOSES ONLY-->

Name: wifi snatcher
Author: f3bandit
Version: 1.2
Devices: omg cable, wifi pager
OS: windows 11
------------------------------------------------------------------------------------------------------------------------------------------
Description:
------------------------------------------------------------------------------------------------------------------------------------------
#1 omg ducky script disable defender and uses run as cmd to run invoke-webrequest thru powershell to download aand run a powershell script 
------------------------------------------------------------------------------------------------------------------------------------------
#2 powershell script dumps, exports, zips, and uploads the loot thru scp to the wifi pager loot\wifi dir. then deletes files in %TEMP% dir 
------------------------------------------------------------------------------------------------------------------------------------------
#3 finally runs last part of the ducky script to re-enable defender.
------------------------------------------------------------------------------------------------------------------------------------------

Files:

omg_payload = copy and past into omg cable payload slot

magic.ps1 = this will download thru scp to the target pc

payload.sh = 
simple payload that on launch unzips any zip files in the loot\wifi dir then
opens a file choose menu to view the wifi dump xml files in the log viewer. to install
create a folder in /mmc/root/payloads/user/exfiltration named wifi_loot_viewer. and copy
the payload.sh file there. this won't be needed once the payload is published.

you will need to generate ssh keys for the pager and the magic.ps1 script so they can cummunicate
