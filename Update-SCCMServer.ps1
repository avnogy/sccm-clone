<#
.SYNOPSIS
Downloads the latest SCCM simulator package and extracts it in place.
.USAGE
    .\Update-SCCMServer.ps1
#>

[CmdletBinding()]
param(
    [string]$PackageUrl = "https://github.com/avnogy/sccm-clone/raw/refs/heads/master/sccm-current.zip"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$zipPath = Join-Path $scriptDir "sccm-current.zip"

Write-Host "Downloading latest package from $PackageUrl"
Invoke-WebRequest -Uri $PackageUrl -OutFile $zipPath -ErrorAction Stop

Write-Host "Extracting package to $scriptDir"
Expand-Archive -Path $zipPath -DestinationPath $scriptDir -Force

if (-not (Test-Path (Join-Path $scriptDir "SCCM-Server.ps1"))) {
    throw "Server script not found after extraction"
}

Write-Host "Update complete. Start the server manually with .\\SCCM-Server.ps1"
