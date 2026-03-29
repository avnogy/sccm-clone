<#
.SYNOPSIS
SCCM Listener - Simulates SCCM site system roles for generating network traffic
.DESCRIPTION
This script listens on common SCCM ports and responds with appropriate mock responses
to simulate Management Point, Software Update Point, and other SCCM roles.
.PORT LIST
80/tcp    - HTTP Management Point
443/tcp   - HTTPS Management Point
8530/tcp  - HTTP Software Update Point
8531/tcp  - HTTPS Software Update Point
10123/tcp - Client Notification
#>

#Requires -RunAsAdministrator

param(
    [string]$SMBSharePath = "",
    [string]$ShareName = "",
    [string]$ExeName = "",
    [switch]$NoSMB
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\SCCM-Config.ps1"

if ($ShareName) { $SMBShareName = $ShareName }
if ($ExeName) { $DeployExeName = $ExeName }
if ([System.IO.Path]::GetExtension($DeployExeName) -notin @(".cmd", ".bat")) {
    $DeployExeName = [System.IO.Path]::ChangeExtension($DeployExeName, ".cmd")
}
$script:SMBShareName = $SMBShareName
$script:DeployExeName = $DeployExeName
$script:EnableSMB = -not $NoSMB

$script:SMBShareCreated = $false

# Global variables
$listeners = [System.Collections.ArrayList]::new()
$certThumbprint = $null

function Write-Log {
    param([string]$message)
    if ($LogToConsole) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Host "[$timestamp] $message"
    }
}

function New-SMBShare {
    param([string]$SharePath, [string]$ShareName)
    
    if (-not $SharePath) {
        $SharePath = Join-Path $env:SystemDrive "SCCMDeploy"
    }
    
    if (-not (Test-Path $SharePath)) {
        New-Item -ItemType Directory -Path $SharePath -Force | Out-Null
        Write-Log "Created SMB share directory: $SharePath"
    }
    
    $deployExePath = Join-Path $SharePath $script:DeployExeName
    $dummyExeContent = @"
@echo off
echo SCCM Deployed Executable Ran at %DATE% %TIME% >> C:\sccm_deployed.log
"@
    [System.IO.File]::WriteAllText($deployExePath, $dummyExeContent)
    Write-Log "Created deployment executable: $deployExePath"
    
    try {
        $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
        if ($existingShare) {
            Remove-SmbShare -Name $ShareName -Force -ErrorAction SilentlyContinue
        }
        
        New-SmbShare -Name $ShareName -Path $SharePath -ChangeAccess "Everyone" -Force | Out-Null
        $script:SMBShareCreated = $true
        Write-Log "Created SMB share: \\$env:COMPUTERNAME\$ShareName"
        
        $acl = Get-Acl $SharePath
        $acl.SetAccessRuleProtection($false, $false)
        $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","FullControl","ContainerInherit,ObjectInherit","None","Allow")
        $acl.AddAccessRule($accessRule)
        Set-Acl -Path $SharePath -AclObject $acl
        
        return $SharePath
    } catch {
        Write-Log "Failed to create SMB share: $_"
        return $null
    }
}

function Remove-SMBShare {
    param([string]$ShareName)
    
    try {
        $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
        if ($share) {
            Remove-SmbShare -Name $ShareName -Force
            Write-Log "Removed SMB share: $ShareName"
        }
    } catch {
        Write-Log "Failed to remove SMB share: $_"
    }
}

function Generate-SelfSignedCert {
    param([string]$Subject = "CN=SCCM-Listener")
    
    Write-Log "Generating self-signed certificate for $Subject"
    
    try {
        $cert = New-SelfSignedCertificate `
            -Subject $Subject `
            -KeyExportPolicy Exportable `
            -KeySpec Signature `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddYears(1) `
            -ErrorAction Stop
            
        Write-Log "Certificate created with thumbprint: $($cert.Thumbprint)"
        return $cert.Thumbprint
    } catch {
        Write-Log "Failed to create self-signed certificate: $_"
        return $null
    }
}

function Bind-Certificate {
    param([string]$Thumbprint, [int]$Port)
    
    try {
        $appGuid = [guid]::NewGuid().ToString("B")
        $command = "netsh http add sslcert ipport=0.0.0.0:$Port certhash=$Thumbprint appid='$appGuid'"
        Write-Log "Binding certificate to port $Port"
        Invoke-Expression $command | Out-Null
        Write-Log "Successfully bound certificate to port $Port"
        return $true
    } catch {
        Write-Log "Failed to bind certificate to port ${Port}: $($_.Exception.Message)"
        return $false
    }
}

function Unbind-Certificate {
    param([int]$Port)
    
    try {
        $command = "netsh http delete sslcert ipport=0.0.0.0:$Port"
        Invoke-Expression $command | Out-Null
        Write-Log "Unbound certificate from port $Port"
    } catch {
        Write-Log "Failed to unbind certificate from port ${Port}: $($_.Exception.Message)"
    }
}

function Cleanup {
    Write-Log "Cleaning up resources..."
    
    foreach ($listener in $listeners) {
        try {
            if ($listener -is [System.Net.HttpListener]) {
                if ($listener.IsListening) {
                    $listener.Stop()
                    $listener.Close()
                }
            } elseif ($listener -is [System.Net.Sockets.TcpListener]) {
                if ($listener.Server -and $listener.Server.IsBound) {
                    $listener.Stop()
                }
            }
        } catch { }
    }
    
    if ($certThumbprint) {
        Unbind-Certificate -Port $HTTPSPort
        Unbind-Certificate -Port $SUPSHTTPSPort
    }
    
    if ($script:SMBShareCreated) {
        Remove-SMBShare -ShareName $script:SMBShareName
    }
    
    Write-Log "Cleanup complete."
}

# Register cleanup for exit
Register-EngineEvent PowerShell.Exiting -Action { Cleanup } | Out-Null

# Trap Ctrl+C
trap {
    Write-Log "Received interrupt signal, shutting down..."
    Cleanup
    exit 0
}

# Main script starts here
Write-Log "Starting SCCM Listener..."

# Generate or use existing certificate for HTTPS ports
try {
    $existingCert = Get-ChildItem -Path Cert:\LocalMachine\My |
        Where-Object { $_.Subject -like "*SCCM*" -and $_.NotAfter -gt (Get-Date) } |
        Select-Object -First 1
        
    if ($existingCert) {
        $certThumbprint = $existingCert.Thumbprint
        Write-Log "Using existing certificate: $certThumbprint"
    } else {
        $certThumbprint = Generate-SelfSignedCert -Subject "CN=SCCM-Listener"
        if (-not $certThumbprint) {
            Write-Log "ERROR: Failed to create certificate. HTTPS listeners will not work."
        }
    }
    
    if ($certThumbprint) {
        Bind-Certificate -Thumbprint $certThumbprint -Port $HTTPSPort
        Bind-Certificate -Thumbprint $certThumbprint -Port $SUPSHTTPSPort
    }
    
} catch {
    Write-Log "ERROR during certificate setup: $_"
}

if ($script:EnableSMB) {
    Write-Log "Setting up SMB deployment share..."
    $createdPath = New-SMBShare -SharePath $SMBSharePath -ShareName $SMBShareName
    if ($createdPath) {
        Write-Log "SMB deployment share ready at: \\$env:COMPUTERNAME\$SMBShareName"
    }
}

# Function to handle HTTP requests (synchronous)
function Handle-HttpRequest {
    param(
        [System.Net.HttpListenerContext]$context,
        [int]$HttpPort,
        [int]$HttpsPort,
        [int]$SupHttpPort,
        [int]$SupHttpsPort
    )
    
    try {
        $request = $context.Request
        $response = $context.Response
        
        $remoteEndPoint = $context.Request.RemoteEndPoint
        $logMessage = "{0}:{1} -> {2}:{3} {4} {5}" -f `
            $remoteEndPoint.Address, $remoteEndPoint.Port, `
            $context.Request.LocalEndPoint.Address, $context.Request.LocalEndPoint.Port, `
            $request.HttpMethod, $request.Url.PathAndQuery
        Write-Log $logMessage
        
        Start-Sleep -Milliseconds $ResponseDelayMs
        
        $path = $request.Url.AbsolutePath.ToLower()
        $responseString = ""
        
        switch ($path) {
            "/sms_ls.srf" {
                if ($request.HttpMethod -eq "POST") {
                    $responseString = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>
<LSLocationServices>
    <MPLists>
        <MPList Value=`"http://$($env:COMPUTERNAME):${HttpPort}`"/>
        <MPList Value=`"https://$($env:COMPUTERNAME):${HttpsPort}`"/>
    </MPLists>
    <SUPLists>
        <SUPList Value=`"http://$($env:COMPUTERNAME):${SupHttpPort}`"/>
        <SUPList Value=`"https://$($env:COMPUTERNAME):${SupHttpsPort}`"/>
    </SUPLists>
</LSLocationServices>"
                    $response.ContentType = "application/xml"
                    $response.StatusCode = 200
                    $response.StatusDescription = "OK"
                } else {
                    $response.StatusCode = 405
                    $response.StatusDescription = "Method Not Allowed"
                }
            }
            
            "/ccm_system/request" {
                if ($request.HttpMethod -eq "POST") {
                    if ($script:EnableSMB -and $script:SMBShareCreated) {
                        $sMBPath = "\\$($env:COMPUTERNAME)\$script:SMBShareName\$script:DeployExeName"
                        $responseString = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>
<CCM_Policy xmlns=`"http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/02/01/CCM_Policy`">
    <PolicyID>SoftwareDeployment_001</PolicyID>
    <PolicyVersion>1.0</PolicyVersion>
    <PolicyType>Assignment</PolicyType>
    <SoftwareDeployment>
        <Name>SCCM Update Package</Name>
        <Program>$script:DeployExeName</Program>
        <CommandLine>$sMBPath</CommandLine>
        <ExecutionType>RunCommand</ExecutionType>
        <RequireUserInteraction>false</RequireUserInteraction>
        <RunMode>Elevated</RunMode>
    </SoftwareDeployment>
    <returnValue>0</returnValue>
</CCM_Policy>"
                        $response.ContentType = "application/xml"
                        $response.StatusCode = 200
                        $response.StatusDescription = "OK"
                        Write-Log "Policy sent with SMB deployment: $sMBPath"
                    } else {
                        $responseString = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>
<CCM_MethodResult xmlns=`"http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/02/01/CCM_BaseClasses`">
    <returnValue>0</returnValue>
</CCM_MethodResult>"
                        $response.ContentType = "application/xml"
                        $response.StatusCode = 200
                        $response.StatusDescription = "OK"
                    }
                } else {
                    $response.StatusCode = 405
                    $response.StatusDescription = "Method Not Allowed"
                }
            }
            
            "/SimpleAuthwebservice/SimpleAuth.asmx" {
                if ($request.HttpMethod -eq "POST") {
                    $responseString = "<?xml version=`"1.0`" encoding=`"utf-8`"?>
<soap:Envelope xmlns:soap=`"http://schemas.xmlsoap.org/soap/envelope/`">
    <soap:Body>
        <GetUpdateLocationsResponse xmlns=`"http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService`">
            <GetUpdateLocationsResult>
                <ErrorCode>0</ErrorCode>
            </GetUpdateLocationsResult>
        </GetUpdateLocationsResponse>
    </soap:Body>
</soap:Envelope>"
                    $response.ContentType = "text/xml; charset=utf-8"
                    $response.StatusCode = 200
                    $response.StatusDescription = "OK"
                } else {
                    $response.StatusCode = 405
                    $response.StatusDescription = "Method Not Allowed"
                }
            }
            
            "/sms_mp" {
                if ($request.HttpMethod -eq "POST") {
                    $responseString = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>
<CCM_Message xmlns=`"http://schemas.microsoft.com/SystemCenterConfigurationManager/2009`">
    <Header><MessageType>MPControl</MessageType></Header>
    <Body><MPControlResponse><Status>0</Status></MPControlResponse></Body>
</CCM_Message>"
                    $response.ContentType = "application/xml"
                    $response.StatusCode = 200
                    $response.StatusDescription = "OK"
                } else {
                    $response.StatusCode = 405
                    $response.StatusDescription = "Method Not Allowed"
                }
            }
            
            "/ccm_status" {
                if ($request.HttpMethod -eq "POST") {
                    $response.StatusCode = 202
                    $response.StatusDescription = "Accepted"
                } else {
                    $response.StatusCode = 405
                    $response.StatusDescription = "Method Not Allowed"
                }
            }
            
            default {
                $responseString = "<HTML><BODY>SCCM Listener - Endpoint not implemented</BODY></HTML>"
                $response.ContentType = "text/html"
                $response.StatusCode = 200
                $response.StatusDescription = "OK"
            }
        }
        
        if ($responseString) {
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseString)
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        
        $response.OutputStream.Close()
    } catch {
        Write-Log "Error processing request: $_"
        try {
            $response.StatusCode = 500
            $response.StatusDescription = "Internal Server Error"
            $response.OutputStream.Close()
        } catch { }
    }
}

function New-HttpListener {
    param([int]$Port, [bool]$UseHttps = $false)

    try {
        $prefix = if ($UseHttps) { "https://+:${Port}/" } else { "http://+:${Port}/" }
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add($prefix)
        $listener.Start()
        [void]$listeners.Add($listener)

        $protocol = if ($UseHttps) { "HTTPS" } else { "HTTP" }
        Write-Log "$protocol listener started on port $Port"
        return $listener
    } catch {
        Write-Log "Failed to start listener on port ${Port}: $($_.Exception.Message)"
        return $null
    }
}

function New-TcpListener {
    param([int]$Port)

    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        [void]$listeners.Add($listener)
        Write-Log "TCP listener started on port $Port (Client Notification)"
        return $listener
    } catch {
        Write-Log "Failed to start TCP listener on port ${Port}: $($_.Exception.Message)"
        return $null
    }
}

function Handle-TcpClient {
    param([System.Net.Sockets.TcpClient]$Client)

    try {
        $remoteEndPoint = $Client.Client.RemoteEndPoint
        $localEndPoint = $Client.Client.LocalEndPoint
        Write-Log ("{0}:{1} -> {2}:{3} TCP CONNECT" -f `
            $remoteEndPoint.Address, $remoteEndPoint.Port, `
            $localEndPoint.Address, $localEndPoint.Port)

        $stream = $Client.GetStream()
        if ($stream.DataAvailable) {
            $buffer = New-Object byte[] 1024
            [void]$stream.Read($buffer, 0, 1024)
        }

        $response = [byte[]]@(0x00)
        $stream.Write($response, 0, $response.Length)
        $stream.Flush()
    } catch {
        Write-Log "TCP client handling error: $($_.Exception.Message)"
    } finally {
        $Client.Close()
    }
}

# Start all listeners
Write-Log "Starting listeners..."

# Start HTTP listeners (pass port variables to each)
$httpListeners = @(
    New-HttpListener -Port $HTTPPort -UseHttps:$false
    New-HttpListener -Port $HTTPSPort -UseHttps:$true
    New-HttpListener -Port $SUPHTTPPort -UseHttps:$false
    New-HttpListener -Port $SUPSHTTPSPort -UseHttps:$true
) | Where-Object { $null -ne $_ }

# Start TCP listener for notifications
$tcpListener = New-TcpListener -Port $NotifyPort

if (-not $httpListeners -and -not $tcpListener) {
    Write-Log "ERROR: No listeners started successfully."
    exit 1
}

Write-Log "All listeners started. Press Ctrl+C to stop."

$httpListenerState = @{}
foreach ($listener in $httpListeners) {
    $httpListenerState[$listener] = $listener.GetContextAsync()
}

# Keep script alive
try {
    while ($true) {
        foreach ($listener in $httpListeners) {
            try {
                if (-not $listener.IsListening) {
                    continue
                }

                $pendingRequest = $httpListenerState[$listener]
                if ($pendingRequest -and $pendingRequest.IsCompleted) {
                    $context = $pendingRequest.GetAwaiter().GetResult()
                    Handle-HttpRequest -context $context -HttpPort $HTTPPort -HttpsPort $HTTPSPort -SupHttpPort $SUPHTTPPort -SupHttpsPort $SUPSHTTPSPort
                    $httpListenerState[$listener] = $listener.GetContextAsync()
                }
            } catch {
                if ($listener.IsListening) {
                    Write-Log "Listener error: $($_.Exception.Message)"
                    $httpListenerState[$listener] = $listener.GetContextAsync()
                }
            }
        }

        if ($tcpListener -and $tcpListener.Server.IsBound -and $tcpListener.Pending()) {
            Handle-TcpClient -Client ($tcpListener.AcceptTcpClient())
        }

        Start-Sleep -Milliseconds 100
    }
} catch {
    Write-Log "Interrupted"
} finally {
    Cleanup
}
