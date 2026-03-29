<#
.SYNOPSIS
SCCM Configuration - Shared settings for Listener and Client
.DESCRIPTION
This file contains all configuration values used by both SCCM-Listener.ps1
and SCCM-ClientSimulator.ps1. Dot-source this file to load the configuration.

.USAGE
# In SCCM-Listener.ps1 or SCCM-ClientSimulator.ps1:
. "$PSScriptRoot\SCCM-Config.ps1"
#>

# HTTP/HTTPS Ports
$HTTPPort = 80
$HTTPSPort = 443
$SUPHTTPPort = 8530
$SUPSHTTPSPort = 8531
$NotifyPort = 10123

# Traffic Intervals (in seconds)
$Intervals = @{
    LocationRequest = 30
    PolicyRequest   = 60
    Notification    = 30
    UpdateScan      = 60
    Heartbeat       = 120
}

# SMB Deployment Settings
$SMBShareName = "SCCMDeploy"
$DeployExeName = "sccm_update.cmd"

# Connection Settings
$MaxRetries = 3
$RetryDelay = 5
$ResponseDelayMs = 50

# Logging
$LogToConsole = $true

# Protocol Settings
$UseHTTPS = $true
