<#
.SYNOPSIS
Downloads the latest SCCM simulator package and extracts it in place.
.USAGE
    .\Update-SCCMServer.ps1
#>

[CmdletBinding()]
param(
    [string]$PackageUrl = "https://raw.githubusercontent.com/avnogy/sccm-clone/master/sccm-current.zip"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$zipPath = Join-Path $scriptDir "sccm-current.zip"
$updateMarkerPath = Join-Path $scriptDir "SCCM-Updated.txt"

Write-Host "Downloading latest package from $PackageUrl"
$previousSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol
try {
    $modernProtocols = [System.Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls13') {
        $modernProtocols = $modernProtocols -bor [System.Net.SecurityProtocolType]::Tls13
    }

    [System.Net.ServicePointManager]::SecurityProtocol = $modernProtocols
    Invoke-WebRequest -Uri $PackageUrl -OutFile $zipPath -ErrorAction Stop
}
finally {
    [System.Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
}

if (-not (Test-Path $zipPath)) {
    throw "Package download failed: $zipPath was not created"
}

$zipFile = Get-Item $zipPath
if ($zipFile.Length -le 0) {
    throw "Package download failed: $zipPath is empty"
}

Write-Host "Extracting package to $scriptDir"
Expand-Archive -Path $zipPath -DestinationPath $scriptDir -Force

$updateMarker = @"
UPDATED_AT=$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
PACKAGE_URL=$PackageUrl
ZIP_PATH=$zipPath
"@
Set-Content -Path $updateMarkerPath -Value $updateMarker -Encoding ASCII

if (-not (Test-Path (Join-Path $scriptDir "SCCM-Server.ps1"))) {
    throw "Server script not found after extraction"
}

Write-Host "Update complete. Marker written to $updateMarkerPath"
Write-Host "Start the server manually with .\\SCCM-Server.ps1"
