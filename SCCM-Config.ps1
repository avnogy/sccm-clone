<#
.SYNOPSIS
SCCM Configuration - Shared settings for Listener and Client
.DESCRIPTION
This file contains all configuration values used by both SCCM-Server.ps1
and SCCM-Client.ps1. Dot-source this file to load the configuration.

.USAGE
# In SCCM-Server.ps1 or SCCM-Client.ps1:
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
    LocationRequest = 60
    PolicyRequest   = 120
    Notification    = 60
    UpdateScan      = 120
    Heartbeat       = 240
}

# SMB Deployment Settings
$DefaultSMBSharePath = "C:\SCCMDeploy"
$SMBShareName = "SCCMDeploy"
$SMBPolicyHost = "192.168.20.9"
$DeployExeName = "sccm_update.exe"
$DeploymentFileSizeKB = 64

# Response Body Sizing
$LocationResponsePaddingEntries = 8
$PolicyResponsePaddingEntries = 20
$UpdateResponsePaddingEntries = 16
$HeartbeatResponsePaddingEntries = 8

# Connection Settings
$MaxRetries = 3
$RetryDelay = 5
$ResponseDelayMs = 50

# Logging
$LogToConsole = $true

# Protocol Settings
$UseHTTPS = $true
