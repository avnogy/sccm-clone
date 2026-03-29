<#
.SYNOPSIS
Downloads the latest SCCM simulator package, extracts it in place, and starts the server.
.USAGE
    .\Update-SCCMServer.ps1
    .\Update-SCCMServer.ps1 -ServeSMBPolicy
    .\Update-SCCMServer.ps1 -PolicyHost 192.168.1.10
#>

[CmdletBinding()]
param(
    [string]$PackageUrl = "https://github.com/avnogy/sccm-clone/raw/refs/heads/master/sccm-current.zip",
    [string]$SMBSharePath = "",
    [string]$ShareName = "",
    [string]$ExeName = "",
    [string]$PolicyHost = "",
    [string]$ClientStartupGpoName = "",
    [string]$ClientInstallRoot = "",
    [switch]$ServeSMBPolicy
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$zipPath = Join-Path $scriptDir "sccm-current.zip"
$serverScriptPath = Join-Path $scriptDir "SCCM-Server.ps1"

Write-Host "Downloading latest package from $PackageUrl"
Invoke-WebRequest -Uri $PackageUrl -OutFile $zipPath -ErrorAction Stop

Write-Host "Extracting package to $scriptDir"
Expand-Archive -Path $zipPath -DestinationPath $scriptDir -Force

if (-not (Test-Path $serverScriptPath)) {
    throw "Server script not found after extraction: $serverScriptPath"
}

$serverArguments = @()
if ($SMBSharePath) { $serverArguments += @("-SMBSharePath", $SMBSharePath) }
if ($ShareName) { $serverArguments += @("-ShareName", $ShareName) }
if ($ExeName) { $serverArguments += @("-ExeName", $ExeName) }
if ($PolicyHost) { $serverArguments += @("-PolicyHost", $PolicyHost) }
if ($ClientStartupGpoName) { $serverArguments += @("-ClientStartupGpoName", $ClientStartupGpoName) }
if ($ClientInstallRoot) { $serverArguments += @("-ClientInstallRoot", $ClientInstallRoot) }
if ($ServeSMBPolicy) { $serverArguments += "-ServeSMBPolicy" }

Write-Host "Starting updated server: $serverScriptPath"
& $serverScriptPath @serverArguments
