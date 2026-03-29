<#
.SYNOPSIS
SCCM Server Simulator - Simulates SCCM site system roles for generating network traffic
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
    [string]$PolicyHost = "",
    [string]$ClientStartupGpoName = "SCCM Simulator Client Startup",
    [string]$ClientInstallRoot = "C:\ProgramData\SCCMSim",
    [switch]$ServeSMBPolicy
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\SCCM-Config.ps1"

if ($ShareName) { $SMBShareName = $ShareName }
if ($ExeName) { $DeployExeName = $ExeName }
if (-not $SMBSharePath) { $SMBSharePath = $DefaultSMBSharePath }
if (-not $PolicyHost) { $PolicyHost = $SMBPolicyHost }
if ([System.IO.Path]::GetExtension($DeployExeName) -notin @(".cmd", ".bat")) {
    $DeployExeName = [System.IO.Path]::ChangeExtension($DeployExeName, ".cmd")
}
$script:SMBShareName = $SMBShareName
$script:DeployExeName = $DeployExeName
$script:EnableSMB = $ServeSMBPolicy
$script:PolicyHost = $null
$script:ClientSourcePath = Join-Path $scriptDir "SCCM-Client.ps1"
$script:ConfigSourcePath = Join-Path $scriptDir "SCCM-Config.ps1"

$script:SMBShareCreated = $false

# Global variables
$listeners = [System.Collections.ArrayList]::new()
$certThumbprint = $null
$maxRequestsPerLoop = 20

function Write-Log {
    param([string]$message)
    if ($LogToConsole) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Host "[$timestamp] $message"
    }
}

function Get-ListenerIPv4 {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object {
                $_.IPAddress -notlike "169.254.*" -and
                $_.IPAddress -notlike "127.*" -and
                $_.PrefixOrigin -ne "WellKnown"
            } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) {
            return $ip
        }
    } catch {
        Write-Log "Failed to determine listener IPv4 address: $($_.Exception.Message)"
    }

    return $null
}

function New-PaddedXmlEntries {
    param(
        [string]$ElementName,
        [int]$Count,
        [string]$Prefix
    )

    $builder = New-Object System.Text.StringBuilder
    for ($index = 1; $index -le $Count; $index++) {
        $value = "{0}-{1:000}-{2}" -f $Prefix, $index, ([guid]::NewGuid().ToString("N").Substring(0, 12))
        [void]$builder.AppendLine(("        <{0}>{1}</{0}>" -f $ElementName, $value))
    }

    return $builder.ToString()
}

function Get-LocalSysvolPolicyPath {
    param([string]$DomainDnsRoot, [Guid]$GpoId)

    $policyFolderName = $GpoId.ToString("B").ToUpperInvariant()
    return (Join-Path $env:SystemRoot "SYSVOL\sysvol\$DomainDnsRoot\Policies\$policyFolderName")
}

function Update-GptVersion {
    param([string]$GptPath)

    if (-not (Test-Path $GptPath)) {
        Set-Content -Path $GptPath -Value "[General]`r`nVersion=0`r`n" -Encoding ASCII
    }

    $content = Get-Content -Path $GptPath -Raw
    $currentVersion = 0
    if ($content -match '(?m)^Version=(\d+)$') {
        $currentVersion = [int]$matches[1]
    }

    $newVersion = $currentVersion + 65536
    if ($content -match '(?m)^Version=\d+$') {
        $content = [regex]::Replace($content, '(?m)^Version=\d+$', "Version=$newVersion")
    } else {
        $content = $content.TrimEnd("`r", "`n") + "`r`nVersion=$newVersion`r`n"
    }

    Set-Content -Path $GptPath -Value $content -Encoding ASCII
}

function Publish-ClientStartupDeployment {
    if (-not (Test-Path $script:ClientSourcePath) -or -not (Test-Path $script:ConfigSourcePath)) {
        Write-Log "Client deployment skipped: client or config script missing next to the server script"
        return
    }

    $requiredCommands = @("Get-ADDomain", "Get-ADObject", "Set-ADObject", "Get-GPO", "New-GPO", "New-GPLink", "Get-GPInheritance")
    foreach ($commandName in $requiredCommands) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            Write-Log "Client deployment skipped: required command '$commandName' is not available"
            return
        }
    }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Import-Module GroupPolicy -ErrorAction Stop

        $domain = Get-ADDomain -ErrorAction Stop
        $gpo = Get-GPO -Name $ClientStartupGpoName -ErrorAction SilentlyContinue
        if (-not $gpo) {
            $gpo = New-GPO -Name $ClientStartupGpoName -ErrorAction Stop
            Write-Log "Created startup GPO: $ClientStartupGpoName"
        } else {
            Write-Log "Using existing startup GPO: $ClientStartupGpoName"
        }

        $inheritance = Get-GPInheritance -Target $domain.DistinguishedName -ErrorAction Stop
        $isLinked = $false
        foreach ($link in $inheritance.GpoLinks) {
            if ($link.DisplayName -eq $ClientStartupGpoName) {
                $isLinked = $true
                break
            }
        }
        if (-not $isLinked) {
            New-GPLink -Name $ClientStartupGpoName -Target $domain.DistinguishedName -LinkEnabled Yes | Out-Null
            Write-Log "Linked startup GPO to domain root: $($domain.DNSRoot)"
        }

        $policyPath = Get-LocalSysvolPolicyPath -DomainDnsRoot $domain.DNSRoot -GpoId $gpo.Id
        $machineScriptsPath = Join-Path $policyPath "Machine\Scripts"
        $startupPath = Join-Path $machineScriptsPath "Startup"
        New-Item -ItemType Directory -Path $startupPath -Force | Out-Null

        $startupCmdName = "SCCM-Client-Startup.cmd"
        $launcherPs1Name = "Install-SCCMClient.ps1"
        $clientScriptName = "SCCM-Client.ps1"
        $configScriptName = "SCCM-Config.ps1"

        Copy-Item -Path $script:ClientSourcePath -Destination (Join-Path $startupPath $clientScriptName) -Force
        Copy-Item -Path $script:ConfigSourcePath -Destination (Join-Path $startupPath $configScriptName) -Force

        $useHttpsLiteral = if ($UseHTTPS) { '$true' } else { '$false' }
        $launcherContent = @'
$ErrorActionPreference = "Stop"

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetDir = "__CLIENT_INSTALL_ROOT__"
$serverHost = "__SERVER_HOST__"
$useHttps = __USE_HTTPS__

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item -Path (Join-Path $sourceDir "SCCM-Client.ps1") -Destination (Join-Path $targetDir "SCCM-Client.ps1") -Force
Copy-Item -Path (Join-Path $sourceDir "SCCM-Config.ps1") -Destination (Join-Path $targetDir "SCCM-Config.ps1") -Force

$existingProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -in @("powershell.exe", "pwsh.exe") -and
        $_.CommandLine -match "SCCM-Client\.ps1"
    }

foreach ($process in $existingProcesses) {
    try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    } catch {
    }
}

$argumentList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $targetDir "SCCM-Client.ps1"),
    "-ServerHost", $serverHost
)

if (-not $useHttps) {
    $argumentList += "-UseHTTPS:`$false"
}

Start-Process -FilePath "powershell.exe" -ArgumentList $argumentList -WindowStyle Hidden
'@
        $launcherContent = $launcherContent.Replace("__CLIENT_INSTALL_ROOT__", $ClientInstallRoot.Replace('"', '""'))
        $launcherContent = $launcherContent.Replace("__SERVER_HOST__", $script:PolicyHost.Replace('"', '""'))
        $launcherContent = $launcherContent.Replace("__USE_HTTPS__", $useHttpsLiteral)
        Set-Content -Path (Join-Path $startupPath $launcherPs1Name) -Value $launcherContent -Encoding UTF8

        $startupCmdContent = @"
@echo off
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0$launcherPs1Name"
"@
        Set-Content -Path (Join-Path $startupPath $startupCmdName) -Value $startupCmdContent -Encoding ASCII

        $scriptsIniContent = @"
[Startup]
0CmdLine=$startupCmdName
0Parameters=
"@
        Set-Content -Path (Join-Path $machineScriptsPath "scripts.ini") -Value $scriptsIniContent -Encoding Unicode

        $gpoDn = "CN={$($gpo.Id.ToString().ToUpperInvariant())},CN=Policies,CN=System,$($domain.DistinguishedName)"
        $machineScriptExtension = "[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]"
        Set-ADObject -Identity $gpoDn -Replace @{gPCMachineExtensionNames = $machineScriptExtension} -ErrorAction Stop

        Update-GptVersion -GptPath (Join-Path $policyPath "GPT.ini")

        Write-Log "Published latest client startup deployment to: $startupPath"
    } catch {
        Write-Log "Client deployment update failed: $($_.Exception.Message)"
    }
}

function New-SMBShare {
    param([string]$SharePath, [string]$ShareName)
    
    if (-not $SharePath) {
        $SharePath = $SMBSharePath
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
    $targetSizeBytes = [Math]::Max(4096, ($DeploymentFileSizeKB * 1KB))
    $paddingBuilder = New-Object System.Text.StringBuilder
    while (($dummyExeContent.Length + $paddingBuilder.Length) -lt $targetSizeBytes) {
        [void]$paddingBuilder.AppendLine(("REM package-chunk-{0:0000}-{1}" -f $paddingBuilder.Length, ([guid]::NewGuid().ToString("N"))))
    }
    $dummyExeContent += $paddingBuilder.ToString()
    [System.IO.File]::WriteAllText($deployExePath, $dummyExeContent)
    $deploySizeKB = [Math]::Round(((Get-Item $deployExePath).Length / 1KB), 1)
    Write-Log "Created deployment executable: $deployExePath (${deploySizeKB} KB)"
    
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

$script:PolicyHost = if ($PolicyHost) { $PolicyHost } else { Get-ListenerIPv4 }
if (-not $script:PolicyHost) {
    $script:PolicyHost = $env:COMPUTERNAME
    Write-Log "Policy host fallback is computer name: $script:PolicyHost"
} else {
    Write-Log "Policy host for deployment content: $script:PolicyHost"
}

Publish-ClientStartupDeployment

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
        Write-Log "Policy deployment path is: \\$script:PolicyHost\$script:SMBShareName\$script:DeployExeName"
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
        Write-Log ("CLIENT_IP={0} PROTOCOL=HTTP METHOD={1} PATH={2}" -f `
            $remoteEndPoint.Address, $request.HttpMethod, $request.Url.PathAndQuery)
        
        Start-Sleep -Milliseconds $ResponseDelayMs
        
        $path = $request.Url.AbsolutePath.ToLower()
        $responseString = ""
        
        switch ($path) {
            "/sms_ls.srf" {
                if ($request.HttpMethod -eq "POST") {
                    $mpHistory = New-PaddedXmlEntries -ElementName "History" -Count $LocationResponsePaddingEntries -Prefix "MP"
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
    <Capabilities>
        <HttpsEnabled>true</HttpsEnabled>
        <ClientVersion>5.00.9128.1000</ClientVersion>
$mpHistory    </Capabilities>
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
                    $policyAssignments = New-PaddedXmlEntries -ElementName "AssignmentID" -Count $PolicyResponsePaddingEntries -Prefix "ADV"
                    if ($script:EnableSMB -and $script:SMBShareCreated) {
                        $sMBPath = "\\$($script:PolicyHost)\$script:SMBShareName\$script:DeployExeName"
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
    <Assignments>
$policyAssignments    </Assignments>
    <returnValue>0</returnValue>
</CCM_Policy>"
                        $response.ContentType = "application/xml"
                        $response.StatusCode = 200
                        $response.StatusDescription = "OK"
                        Write-Log "Policy sent with SMB deployment: $sMBPath"
                    } else {
                        $responseString = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>
<CCM_MethodResult xmlns=`"http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/02/01/CCM_BaseClasses`">
    <Assignments>
$policyAssignments    </Assignments>
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
                    $updateLocations = New-PaddedXmlEntries -ElementName "Location" -Count $UpdateResponsePaddingEntries -Prefix "SUP"
                    $responseString = "<?xml version=`"1.0`" encoding=`"utf-8`"?>
<soap:Envelope xmlns:soap=`"http://schemas.xmlsoap.org/soap/envelope/`">
    <soap:Body>
        <GetUpdateLocationsResponse xmlns=`"http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService`">
            <GetUpdateLocationsResult>
                <ErrorCode>0</ErrorCode>
                <ContentVersion>2025.03.29.1</ContentVersion>
                <Locations>
$updateLocations                </Locations>
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
                    $heartbeatDetails = New-PaddedXmlEntries -ElementName "Record" -Count $HeartbeatResponsePaddingEntries -Prefix "DDR"
                    $responseString = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>
<CCM_Message xmlns=`"http://schemas.microsoft.com/SystemCenterConfigurationManager/2009`">
    <Header><MessageType>MPControl</MessageType></Header>
    <Body>
        <MPControlResponse>
            <Status>0</Status>
            <ServerTime>$([DateTime]::UtcNow.ToString("o"))</ServerTime>
            <Records>
$heartbeatDetails            </Records>
        </MPControlResponse>
    </Body>
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
        Write-Log ("CLIENT_IP={0} PROTOCOL=TCP PORT={1}" -f `
            $remoteEndPoint.Address, $localEndPoint.Port)

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

                for ($requestIndex = 0; $requestIndex -lt $maxRequestsPerLoop; $requestIndex++) {
                    $pendingRequest = $httpListenerState[$listener]
                    if (-not $pendingRequest -or -not $pendingRequest.IsCompleted) {
                        break
                    }

                    $context = $pendingRequest.GetAwaiter().GetResult()
                    $httpListenerState[$listener] = $listener.GetContextAsync()
                    Handle-HttpRequest -context $context -HttpPort $HTTPPort -HttpsPort $HTTPSPort -SupHttpPort $SUPHTTPPort -SupHttpsPort $SUPSHTTPSPort
                }
            } catch {
                if ($listener.IsListening) {
                    Write-Log "Listener error: $($_.Exception.Message)"
                    $httpListenerState[$listener] = $listener.GetContextAsync()
                }
            }
        }

        if ($tcpListener -and $tcpListener.Server.IsBound) {
            for ($clientIndex = 0; $clientIndex -lt $maxRequestsPerLoop; $clientIndex++) {
                if (-not $tcpListener.Pending()) {
                    break
                }

                Handle-TcpClient -Client ($tcpListener.AcceptTcpClient())
            }
        }

        Start-Sleep -Milliseconds 100
    }
} catch {
    Write-Log "Interrupted"
} finally {
    Cleanup
}
