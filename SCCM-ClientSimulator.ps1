<#
.SYNOPSIS
SCCM Client Simulator - Generates realistic SCCM client network traffic
.DESCRIPTION
This script discovers the Domain Controller and generates SCCM-like traffic patterns
including location requests, policy requests, notification polls, update scans, and heartbeats.
.USAGE
    .\SCCM-ClientSimulator.ps1
    .\SCCM-ClientSimulator.ps1 -OneShot
    .\SCCM-ClientSimulator.ps1 -Verbose
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\SCCM-Config.ps1"

[CmdletBinding()]
param(
    [switch]$OneShot,
    [switch]$UseHTTPS,
    [switch]$AutoDeploy
)

if (-not $PSBoundParameters.ContainsKey('UseHTTPS')) { $UseHTTPS = $true }

$script:LogEnabled = $true

function Write-Log {
    param([string]$message, [string]$level = "INFO")
    if ($script:LogEnabled) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $threadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        Write-Host "[$timestamp] [$level] TID:$threadId - $message"
    }
}

function Write-VerboseLog {
    param([string]$message)
    if ($PSCmdlet.Verbose) {
        Write-Log $message "VERBOSE"
    }
}

function Write-ErrorLog {
    param([string]$message)
    Write-Log $message "ERROR"
}

# Bypass certificate validation for self-signed certs (if using HTTPS)
if ($UseHTTPS) {
    try {
        add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-VerboseLog "Certificate validation bypassed for HTTPS"
    } catch {
        Write-Log "Warning: Could not set certificate policy: $_" "WARN"
    }
}

# DC Discovery Functions
function Find-DC {
    Write-Log "Discovering Domain Controller..."
    
    # Method 1: nltest /dsgetdc (most reliable)
    try {
        Write-VerboseLog "Trying nltest /dsgetdc..."
        $nltestOutput = nltest /dsgetdc 2>$null
        if ($LASTEXITCODE -eq 0) {
            if ($nltestOutput -match "DC:\\\\\\([^\\\s]+)") {
                $dc = $matches[1].TrimEnd('\')
                Write-Log "Discovered DC via nltest: $dc"
                return $dc
            }
        }
    } catch {
        Write-VerboseLog "nltest failed: $_"
    }
    
    # Method 2: DNS SRV record for SCCM
    try {
        Write-VerboseLog "Trying DNS SRV query for _sccm-proxy._tcp..."
        $domain = $env:USERDNSDOMAIN
        if ($domain) {
            $srvQuery = "_sccm-proxy._tcp.$domain"
            Write-VerboseLog "Querying SRV record: $srvQuery"
            $srvRecords = Resolve-DnsName -Type SRV -Name $srvQuery -ErrorAction Stop 2>$null
            if ($srvRecords) {
                $sorted = $srvRecords | Sort-Object Priority, Weight -Descending
                $dc = $sorted[0].NameTarget.TrimEnd('.')
                Write-Log "Discovered DC via SRV record ($srvQuery): $dc"
                return $dc
            }
        }
    } catch {
        Write-VerboseLog "DNS SRV query failed: $_"
    }
    
    # Method 3: Environment variable (LOGONSERVER)
    try {
        if ($env:LOGONSERVER) {
            $dc = $env:LOGONSERVER -Replace '^\\\\', ''
            Write-Log "Discovered DC via LOGONSERVER: $dc"
            return $dc
        }
    } catch {
        Write-VerboseLog "LOGONSERVER check failed: $_"
    }
    
    # Method 4: Current domain via ADSI (fallback)
    try {
        Write-VerboseLog "Trying ADSI domain lookup..."
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        if ($domain) {
            $dc = ($domain.DomainControllers | Select-Object -First 1).Name
            Write-Log "Discovered DC via ADSI: $dc"
            return $dc
        }
    } catch {
        Write-VerboseLog "ADSI lookup failed: $_"
    }
    
    Write-Log "ERROR: Could not discover Domain Controller using any method" "ERROR"
    return $null
}

# HTTP Request Function with retry logic
function Invoke-SCCMRequest {
    param(
        [string]$Method,
        [string]$Url,
        [string]$Body = $null,
        [hashtable]$Headers = @{}
    )
    
    for ($attempt = 0; $attempt -lt $MaxRetries; $attempt++) {
        try {
            Write-VerboseLog "Attempt $($attempt + 1) of ${MaxRetries}: $Method ${Url}"
            
            $defaultHeaders = @{
                "User-Agent" = "SMS CCM/5.00"
                "Accept" = "*/*"
                "X-Machine-Name" = $env:COMPUTERNAME
                "X-Client-Version" = "5.00"
            }
            
            $allHeaders = $defaultHeaders.Clone()
            foreach ($key in $Headers.Keys) {
                $allHeaders[$key] = $Headers[$key]
            }
            
            if ($Body -and -not $allHeaders.ContainsKey("Content-Type")) {
                $allHeaders["Content-Type"] = "application/xml; charset=utf-8"
            }
            
            $response = Invoke-WebRequest -Uri $Url -Method $Method -Body $Body -Headers $allHeaders -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
            
            Write-VerboseLog "Request successful: $($response.StatusCode)"
            return @{
                StatusCode = $response.StatusCode
                StatusDescription = $response.StatusDescription
                Content = if ($response.Content) { $response.Content } else { $null }
                Headers = $response.Headers
            }
        } catch {
            if ($attempt -lt $MaxRetries - 1) {
                Write-VerboseLog "Attempt $($attempt + 1) failed: $($_.Exception.Message). Retrying in $RetryDelay seconds..."
                Start-Sleep -Seconds $RetryDelay
            } else {
                Write-ErrorLog "Request failed after $MaxRetries attempts: $($_.Exception.Message)"
                return @{
                    StatusCode = 0
                    StatusDescription = "Failed after $MaxRetries attempts"
                    Error = $_.Exception.Message
                }
            }
        }
    }
}

# Get client IP address
function Get-ClientIP {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 | 
            Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    } catch { }
    return "0.0.0.0"
}

# SCCM Traffic Functions
function Send-LocationRequest {
    param([string]$DC)
    
    $protocol = if ($UseHTTPS) { "https" } else { "http" }
    $port = if ($UseHTTPS) { $HTTPSPort } else { $HTTPPort }
    $url = "$protocol://$DC`:$port/sms_ls.srf"
    
    $clientIP = Get-ClientIP
    $body = @"
<LocationRequest>
    <Client>
        <NetbiosName>$env:COMPUTERNAME</NetbiosName>
        <ADSite>$env:USERDNSDOMAIN</ADSite>
        <IPAddress>$clientIP</IPAddress>
    </Client>
    <Request>
        <Action>GetMPList</Action>
    </Request>
</LocationRequest>
"@
    
    $result = Invoke-SCCMRequest -Method "POST" -Url $url -Body $body
    if ($result.StatusCode -eq 200) {
        Write-Log "Location request sent to $url - Response: $($result.StatusCode)"
        return $true
    } else {
        Write-ErrorLog "Location request failed to $url`: $($result.StatusDescription)"
        return $false
    }
}

function Send-PolicyRequest {
    param([string]$DC, [switch]$ReturnContent)
    
    $protocol = if ($UseHTTPS) { "https" } else { "http" }
    $port = if ($UseHTTPS) { $HTTPSPort } else { $HTTPPort }
    $url = "$protocol://$DC`:$port/ccm_system/request"
    
    $body = @"
<CCM_MethodInvocation xmlns="http://schemas.microsoft.com/SystemCenterConfigurationManager/2009">
    <MethodName>GetPolicy</MethodName>
    <Parameters>
        <Parameter>
            <Name>PolicyType</Name>
            <Value>1</Value>
        </Parameter>
    </Parameters>
</CCM_MethodInvocation
"@
    
    $result = Invoke-SCCMRequest -Method "POST" -Url $url -Body $body
    if ($result.StatusCode -eq 200) {
        Write-Log "Policy request sent to $url - Response: $($result.StatusCode)"
        if ($ReturnContent -and $result.Content) {
            return $result.Content
        }
        return $true
    } else {
        Write-ErrorLog "Policy request failed to $url`: $($result.StatusDescription)"
        return $false
    }
}

function Send-NotificationPoll {
    param([string]$DC)
    
    try {
        Write-VerboseLog "Attempting TCP connection to $DC`:$NotifyPort for notification poll"
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect($DC, $NotifyPort, $null, $null)
        $waitHandle = $asyncResult.AsyncWaitHandle
        
        try {
            if (-not $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(5), $false)) {
                $tcpClient.Close()
                Throw "Connection timeout"
            }
            
            $tcpClient.EndConnect($asyncResult) | Out-Null
            
            $networkStream = $tcpClient.GetStream()
            if ($networkStream.CanWrite) {
                $pollByte = [byte]0x01
                $networkStream.Write($pollByte, 0, 1)
                $networkStream.Flush()
            }
            
            $tcpClient.Close()
            Write-Log "Notification poll sent to TCP $DC`:$NotifyPort - Connection successful"
            return $true
        } finally {
            $waitHandle.Dispose()
            if ($tcpClient.Connected) { $tcpClient.Close() }
        }
    } catch {
        Write-ErrorLog "Notification poll failed to TCP $DC`:$NotifyPort`: $($_.Exception.Message)"
        return $false
    }
}

function Send-UpdateScan {
    param([string]$DC)
    
    $protocol = if ($UseHTTPS) { "https" } else { "http" }
    $port = if ($UseHTTPS) { $SUPSHTTPSPort } else { $SUPHTTPPort }
    $url = "$protocol://$DC`:$port/SimpleAuthwebservice/SimpleAuth.asmx"
    
    $body = @"
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Body>
        <GetUpdateLocations xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService" />
    </soap:Body>
</soap:Envelope>
"@
    
    $headers = @{
        "SOAPAction" = "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetUpdateLocations"
    }
    
    $result = Invoke-SCCMRequest -Method "POST" -Url $url -Body $body -Headers $headers
    if ($result.StatusCode -eq 200) {
        Write-Log "Update scan sent to $url - Response: $($result.StatusCode)"
        return $true
    } else {
        Write-ErrorLog "Update scan failed to $url`: $($result.StatusDescription)"
        return $false
    }
}

function Send-Heartbeat {
    param([string]$DC)
    
    $protocol = if ($UseHTTPS) { "https" } else { "http" }
    $port = if ($UseHTTPS) { $HTTPSPort } else { $HTTPPort }
    $url = "$protocol://$DC`:$port/sms_mp"
    
    $clientIP = Get-ClientIP
    $timestamp = (Get-Date).ToUniversalTime().ToString("o")
    $body = @"
<CCM_Message xmlns="http://schemas.microsoft.com/SystemCenterConfigurationManager/2009">
    <Header>
        <MessageType>MPControl</MessageType>
        <From>$env:COMPUTERNAME</From>
        <To>MP</To>
        <ID>$(New-Guid)</ID>
        <Time>$timestamp</Time>
    </Header>
    <Body>
        <DDREvent>
            <ComputerName>$env:COMPUTERNAME</ComputerName>
            <ADSite>$env:USERDNSDOMAIN</ADSite>
            <IPAddress>$clientIP</IPAddress>
            <Timestamp>$timestamp</Timestamp>
        </DDREvent>
    </Body>
</CCM_Message
"@
    
    $result = Invoke-SCCMRequest -Method "POST" -Url $url -Body $body
    if ($result.StatusCode -eq 200) {
        Write-Log "Heartbeat sent to $url - Response: $($result.StatusCode)"
        return $true
    } else {
        Write-ErrorLog "Heartbeat failed to $url`: $($result.StatusDescription)"
        return $false
    }
}

function Invoke-SMBDeployment {
    param([string]$Content)
    
    if (-not $Content) {
        return $false
    }
    
    try {
        if ($Content -match '<CommandLine>([^<]+)</CommandLine>') {
            $sMBPath = $matches[1].Trim()
            Write-Log "Policy received - SMB deployment: $sMBPath"
            
            if ($sMBPath -match '\\\\([^\\]+)\\([^\\]+)\\(.+)') {
                $server = $matches[1]
                $share = $matches[2]
                $fileName = $matches[3]
                
                Write-Log "Downloading from \\$server\$share..."
                
                $localPath = Join-Path $env:TEMP $fileName
                
                try {
                    Copy-Item -Path $sMBPath -Destination $localPath -Force -ErrorAction Stop
                    Write-Log "Downloaded to: $localPath"
                    
                    Write-Log "Executing: $localPath"
                    $process = Start-Process -FilePath $localPath -NoNewWindow -PassThru -ErrorAction Stop
                    
                    Write-Log "Deployment executed successfully (PID: $($process.Id))"
                    return $true
                } catch {
                    Write-ErrorLog "Failed to download/execute: $($_.Exception.Message)"
                    return $false
                }
            }
        } else {
            Write-VerboseLog "No deployment command in policy"
            return $false
        }
    } catch {
        Write-ErrorLog "Deployment parse failed: $($_.Exception.Message)"
        return $false
    }
    
    return $false
}

# Main execution
try {
    Write-Log "Starting SCCM Client Simulator..."
    Write-Log "OneShot mode: $OneShot"
    Write-Log "Using HTTPS: $UseHTTPS"
    Write-Log "AutoDeploy mode: $AutoDeploy"
    
    # Discover DC
    $DC = Find-DC
    if (-not $DC) {
        Write-Log "FATAL: Could not discover Domain Controller. Exiting." "ERROR"
        exit 1
    }
    
    Write-Log "Using DC: $DC"
    
    # Initialize timers
    $timers = @{}
    foreach ($key in $Intervals.Keys) {
        $timers[$key] = [DateTime]::UtcNow
    }
    
    # Main loop
    do {
        $now = [DateTime]::UtcNow
        $anyActivity = $false
        
        # Location Request
        if (($now - $timers.LocationRequest).TotalSeconds -ge $Intervals.LocationRequest) {
            if (Send-LocationRequest -DC $DC) {
                $timers.LocationRequest = $now
                $anyActivity = $true
            }
        }
        
        # Notification Poll
        if (($now - $timers.Notification).TotalSeconds -ge $Intervals.Notification) {
            if (Send-NotificationPoll -DC $DC) {
                $timers.Notification = $now
                $anyActivity = $true
            }
        }
        
        # Policy Request
        if (($now - $timers.PolicyRequest).TotalSeconds -ge $Intervals.PolicyRequest) {
            $policyContent = $null
            if ($AutoDeploy) {
                $policyContent = Send-PolicyRequest -DC $DC -ReturnContent
            } else {
                $policyResult = Send-PolicyRequest -DC $DC
            }
            
            if ($policyContent -or $policyResult) {
                $timers.PolicyRequest = $now
                $anyActivity = $true
            }
            
            if ($AutoDeploy -and $policyContent) {
                Invoke-SMBDeployment -Content $policyContent
            }
        }
        
        # Update Scan
        if (($now - $timers.UpdateScan).TotalSeconds -ge $Intervals.UpdateScan) {
            if (Send-UpdateScan -DC $DC) {
                $timers.UpdateScan = $now
                $anyActivity = $true
            }
        }
        
        # Heartbeat
        if (($now - $timers.Heartbeat).TotalSeconds -ge $Intervals.Heartbeat) {
            if (Send-Heartbeat -DC $DC) {
                $timers.Heartbeat = $now
                $anyActivity = $true
            }
        }
        
        if (-not $anyActivity) {
            Start-Sleep -Milliseconds 500
        }
        
    } while (-not $OneShot)
    
    Write-Log "Simulation completed."
    
} catch {
    Write-Log "FATAL ERROR: $_" "ERROR"
    exit 1
}