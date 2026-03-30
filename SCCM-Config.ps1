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
    LocationRequest = 30
    PolicyRequest   = 60
    Notification    = 30
    UpdateScan      = 60
    Heartbeat       = 120
}

# SMB Deployment Settings
$SMBShareName = "srv"
$SMBPolicyHost = "192.168.30.6"
$DeployExeName = "sccm_update.exe"

# Client Listener Target
$ListenerHost = "192.168.10.15"

# Server Deployment Publishing
$ClientStartupGpoName = "SCCM Simulator Client Startup"
$ClientInstallRoot = "C:\ProgramData\SCCMSim"

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
