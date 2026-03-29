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
$updaterName = [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
$zipPath = Join-Path $scriptDir "sccm-current.zip"
$downloadPath = Join-Path $scriptDir "sccm-current.zip.download"
$updateMarkerPath = Join-Path $scriptDir "SCCM-Updated.txt"
$stagingPath = Join-Path $scriptDir "sccm-update-staging"

Write-Host "Downloading latest package from $PackageUrl"
$previousSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol
try {
    $modernProtocols = [System.Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls13') {
        $modernProtocols = $modernProtocols -bor [System.Net.SecurityProtocolType]::Tls13
    }

    [System.Net.ServicePointManager]::SecurityProtocol = $modernProtocols
    if (Test-Path $downloadPath) {
        Remove-Item -Path $downloadPath -Force
    }

    Invoke-WebRequest -Uri $PackageUrl -OutFile $downloadPath -ErrorAction Stop
}
finally {
    [System.Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
}

if (-not (Test-Path $downloadPath)) {
    throw "Package download failed: $downloadPath was not created"
}

$zipFile = Get-Item $downloadPath
if ($zipFile.Length -le 0) {
    throw "Package download failed: $downloadPath is empty"
}

$zipHeader = [System.IO.File]::ReadAllBytes($downloadPath)[0..1]
if ($zipHeader[0] -ne 0x50 -or $zipHeader[1] -ne 0x4B) {
    throw "Package download failed: $downloadPath is not a zip archive"
}

Move-Item -Path $downloadPath -Destination $zipPath -Force

if (-not (Test-Path $zipPath)) {
    throw "Package staging failed: $zipPath was not created"
}

if (Test-Path $stagingPath) {
    Remove-Item -Path $stagingPath -Recurse -Force
}

Write-Host "Extracting package to staging directory $stagingPath"
Expand-Archive -Path $zipPath -DestinationPath $stagingPath -Force

$preserveNames = @(
    $updaterName,
    [System.IO.Path]::GetFileName($zipPath),
    [System.IO.Path]::GetFileName($downloadPath),
    [System.IO.Path]::GetFileName($updateMarkerPath),
    [System.IO.Path]::GetFileName($stagingPath),
    ".git",
    ".githooks"
)

Write-Host "Removing existing package files from $scriptDir"
Get-ChildItem -Path $scriptDir -Force | Where-Object {
    $preserveNames -notcontains $_.Name
} | Remove-Item -Recurse -Force

Write-Host "Copying refreshed package into $scriptDir"
Get-ChildItem -Path $stagingPath -Force | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $scriptDir -Recurse -Force
}

$stagedUpdaterPath = Join-Path $stagingPath $updaterName
if (Test-Path $stagedUpdaterPath) {
    Copy-Item -Path $stagedUpdaterPath -Destination (Join-Path $scriptDir $updaterName) -Force
}

Remove-Item -Path $stagingPath -Recurse -Force

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
