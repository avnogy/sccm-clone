<#
.SYNOPSIS
SCCM Client Simulator - Generates realistic SCCM client network traffic
.DESCRIPTION
This script uses a configured listener host and generates SCCM-like traffic patterns
including location requests, policy requests, notification polls, update scans, and heartbeats.
.USAGE
    .\SCCM-Client.ps1
    .\SCCM-Client.ps1 -Verbose
#>

[CmdletBinding()]
param()

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\SCCM-Config.ps1"

$script:LogEnabled = $true
$script:LogFilePath = $env:SCCM_CLIENT_LOG_PATH
$script:LastDeploymentCommandLine = $null

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return ""
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "")
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }
}

function Write-Log {
    param([string]$message, [string]$level = "INFO")
    if ($script:LogEnabled) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $threadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        $entry = "[$timestamp] [$level] TID:${threadId} - $message"
        Write-Host $entry
        if ($script:LogFilePath) {
            $entry | Out-File -FilePath $script:LogFilePath -Append -Encoding ASCII
        }
    }
}

function Write-VerboseLog {
    param([string]$message)
    if ($VerbosePreference -ne 'SilentlyContinue') {
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
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-VerboseLog "Certificate validation bypassed for HTTPS"
    } catch {
        Write-Log "Warning: Could not set certificate policy: $_" "WARN"
    }
}

# Listener host selection
function Get-ListenerHost {
    if ($ListenerHost) {
        Write-Log "Using listener host from config: $ListenerHost"
        return $ListenerHost
    }

    Write-Log "ERROR: ListenerHost is not configured in SCCM-Config.ps1" "ERROR"
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

            $contentType = $null
            if ($Body -and $allHeaders.ContainsKey("Content-Type")) {
                $contentType = $allHeaders["Content-Type"]
                [void]$allHeaders.Remove("Content-Type")
            } elseif ($Body) {
                $contentType = "application/xml; charset=utf-8"
            }

            $requestParams = @{
                Uri         = $Url
                Method      = $Method
                Headers     = $allHeaders
                ErrorAction = "Stop"
                TimeoutSec  = 15
            }

            if ($PSVersionTable.PSVersion.Major -lt 6) {
                $requestParams["UseBasicParsing"] = $true
            }

            if ($Body) {
                $requestParams["Body"] = $Body
            }

            if ($contentType) {
                $requestParams["ContentType"] = $contentType
            }

            $response = Invoke-WebRequest @requestParams

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

function Get-PublishedClientSourcePath {
    if ($env:USERDNSDOMAIN) {
        return "\\$($env:USERDNSDOMAIN)\SYSVOL\$($env:USERDNSDOMAIN)\scripts"
    }

    return $null
}

function Invoke-ClientSelfUpdate {
    param(
        [string]$Content,
        [string]$ListenerHost
    )

    if (-not $Content) {
        return $false
    }

    if ($Content -notmatch '<ClientScriptHash>([^<]+)</ClientScriptHash>' -or
        $Content -notmatch '<ConfigHash>([^<]+)</ConfigHash>') {
        return $false
    }

    $serverClientHash = ([regex]::Match($Content, '<ClientScriptHash>([^<]+)</ClientScriptHash>')).Groups[1].Value.Trim()
    $serverConfigHash = ([regex]::Match($Content, '<ConfigHash>([^<]+)</ConfigHash>')).Groups[1].Value.Trim()

    $localClientPath = Join-Path $scriptDir "SCCM-Client.ps1"
    $localConfigPath = Join-Path $scriptDir "SCCM-Config.ps1"
    $localClientHash = Get-FileSha256 -Path $localClientPath
    $localConfigHash = Get-FileSha256 -Path $localConfigPath

    if ($localClientHash -eq $serverClientHash -and $localConfigHash -eq $serverConfigHash) {
        return $false
    }

    $publishedSourcePath = Get-PublishedClientSourcePath
    if (-not $publishedSourcePath) {
        Write-ErrorLog "Client update available but SYSVOL source path could not be determined"
        return $false
    }

    $publishedClientPath = Join-Path $publishedSourcePath "SCCM-Client.ps1"
    $publishedConfigPath = Join-Path $publishedSourcePath "SCCM-Config.ps1"
    if (-not (Test-Path $publishedClientPath) -or -not (Test-Path $publishedConfigPath)) {
        Write-ErrorLog "Client update available but published files are missing in $publishedSourcePath"
        return $false
    }

    try {
        Write-Log "Client update detected. Refreshing local files from $publishedSourcePath"
        Copy-Item -Path $publishedClientPath -Destination $localClientPath -Force -ErrorAction Stop
        Copy-Item -Path $publishedConfigPath -Destination $localConfigPath -Force -ErrorAction Stop

        $argumentList = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $localClientPath
        )

        $clientPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        Start-Process -FilePath $clientPowerShell -ArgumentList $argumentList -WindowStyle Hidden -ErrorAction Stop
        Write-Log "Client updated successfully. Restarting client process."
        return $true
    } catch {
        Write-ErrorLog "Client self-update failed: $($_.Exception.Message)"
        return $false
    }
}

# SCCM Traffic Functions
function Send-LocationRequest {
    param([string]$ListenerHost)

    $protocol = if ($UseHTTPS) { "https" } else { "http" }
    $port = if ($UseHTTPS) { $HTTPSPort } else { $HTTPPort }
    $url = "${protocol}://${ListenerHost}:${port}/sms_ls.srf"

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
        Write-ErrorLog "Location request failed to ${url}: $($result.StatusDescription)"
        return $false
    }
}

function Send-PolicyRequest {
    param([string]$ListenerHost)

    $protocol = if ($UseHTTPS) { "https" } else { "http" }
    $port = if ($UseHTTPS) { $HTTPSPort } else { $HTTPPort }
    $url = "${protocol}://${ListenerHost}:${port}/ccm_system/request"

    $body = @"
<CCM_MethodInvocation xmlns="http://schemas.microsoft.com/SystemCenterConfigurationManager/2009">
    <MethodName>GetPolicy</MethodName>
    <Parameters>
        <Parameter>
            <Name>PolicyType</Name>
            <Value>1</Value>
        </Parameter>
    </Parameters>
</CCM_MethodInvocation>
"@

    $result = Invoke-SCCMRequest -Method "POST" -Url $url -Body $body
    if ($result.StatusCode -eq 200) {
        Write-Log "Policy request sent to $url - Response: $($result.StatusCode)"
        return $result.Content
    } else {
        Write-ErrorLog "Policy request failed to ${url}: $($result.StatusDescription)"
        return $null
    }
}

function Send-NotificationPoll {
    param([string]$ListenerHost)

    try {
        Write-VerboseLog "Attempting TCP connection to ${ListenerHost}:${NotifyPort} for notification poll"
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect($ListenerHost, $NotifyPort, $null, $null)
        $waitHandle = $asyncResult.AsyncWaitHandle

        try {
            if (-not $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(5), $false)) {
                $tcpClient.Close()
                Throw "Connection timeout"
            }

            $tcpClient.EndConnect($asyncResult) | Out-Null

            $networkStream = $tcpClient.GetStream()
            if ($networkStream.CanWrite) {
                $pollBytes = [byte[]]@([byte]0x01)
                $networkStream.Write($pollBytes, 0, $pollBytes.Length)
                $networkStream.Flush()
            }

            $tcpClient.Close()
            Write-Log "Notification poll sent to TCP ${ListenerHost}:${NotifyPort} - Connection successful"
            return $true
        } finally {
            $waitHandle.Dispose()
            if ($tcpClient.Connected) { $tcpClient.Close() }
        }
    } catch {
        Write-ErrorLog "Notification poll failed to TCP ${ListenerHost}:${NotifyPort}: $($_.Exception.Message)"
        return $false
    }
}

function Send-UpdateScan {
    param([string]$ListenerHost)

    $protocol = if ($UseHTTPS) { "https" } else { "http" }
    $port = if ($UseHTTPS) { $SUPSHTTPSPort } else { $SUPHTTPPort }
    $url = "${protocol}://${ListenerHost}:${port}/SimpleAuthwebservice/SimpleAuth.asmx"

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
        Write-ErrorLog "Update scan failed to ${url}: $($result.StatusDescription)"
        return $false
    }
}

function Send-Heartbeat {
    param([string]$ListenerHost)

    $protocol = if ($UseHTTPS) { "https" } else { "http" }
    $port = if ($UseHTTPS) { $HTTPSPort } else { $HTTPPort }
    $url = "${protocol}://${ListenerHost}:${port}/sms_mp"

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
</CCM_Message>
"@

    $result = Invoke-SCCMRequest -Method "POST" -Url $url -Body $body
    if ($result.StatusCode -eq 200) {
        Write-Log "Heartbeat sent to $url - Response: $($result.StatusCode)"
        return $true
    } else {
        Write-ErrorLog "Heartbeat failed to ${url}: $($result.StatusDescription)"
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

            if ($script:LastDeploymentCommandLine -eq $sMBPath) {
                Write-VerboseLog "Deployment path already executed in this client session"
                return $true
            }

            if ($sMBPath -match '\\\\([^\\]+)\\([^\\]+)\\(.+)') {
                $server = $matches[1]
                $share = $matches[2]
                $fileName = $matches[3]
                $extension = [System.IO.Path]::GetExtension($fileName)
                $remoteDirectory = Split-Path -Path $sMBPath -Parent

                Write-Log "Downloading from \\$server\$share..."

                $localPath = Join-Path $env:TEMP $fileName
                $localDirectory = Split-Path -Path $localPath -Parent
                $remoteConfigPath = Join-Path $remoteDirectory "config.ini"
                $localConfigPath = Join-Path $localDirectory "config.ini"

                try {
                    Copy-Item -Path $sMBPath -Destination $localPath -Force -ErrorAction Stop
                    Write-Log "Downloaded to: $localPath"

                    if (Test-Path $remoteConfigPath) {
                        Copy-Item -Path $remoteConfigPath -Destination $localConfigPath -Force -ErrorAction Stop
                        Write-Log "Downloaded companion config: $localConfigPath"
                    } else {
                        Write-VerboseLog "No companion config found at $remoteConfigPath"
                    }

                    Write-Log "Executing: $localPath"
                    if ($extension -in @(".cmd", ".bat")) {
                        $process = Start-Process -FilePath $env:ComSpec -ArgumentList "/c", "`"$localPath`"" -WorkingDirectory $localDirectory -NoNewWindow -PassThru -ErrorAction Stop
                    } else {
                        $process = Start-Process -FilePath $localPath -WorkingDirectory $localDirectory -NoNewWindow -PassThru -ErrorAction Stop
                    }

                    $script:LastDeploymentCommandLine = $sMBPath
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
    Write-Log "Using HTTPS: $UseHTTPS"

    # Use configured listener host
    $listenerHost = Get-ListenerHost
    if (-not $listenerHost) {
        Write-Log "FATAL: Could not determine listener host. Exiting." "ERROR"
        exit 1
    }

    Write-Log "Using listener host: $listenerHost"

    # Initialize timers
    $timers = @{}
    foreach ($key in $Intervals.Keys) {
        $timers[$key] = [DateTime]::UtcNow.AddSeconds(-1 * $Intervals[$key])
    }

    # Main loop
    while ($true) {
        $now = [DateTime]::UtcNow
        $anyActivity = $false

        # Location Request
        if (($now - $timers.LocationRequest).TotalSeconds -ge $Intervals.LocationRequest) {
            if (Send-LocationRequest -ListenerHost $listenerHost) {
                $timers.LocationRequest = $now
                $anyActivity = $true
            }
        }

        # Notification Poll
        if (($now - $timers.Notification).TotalSeconds -ge $Intervals.Notification) {
            if (Send-NotificationPoll -ListenerHost $listenerHost) {
                $timers.Notification = $now
                $anyActivity = $true
            }
        }

        # Policy Request
        if (($now - $timers.PolicyRequest).TotalSeconds -ge $Intervals.PolicyRequest) {
            $policyContent = Send-PolicyRequest -ListenerHost $listenerHost

            if ($null -ne $policyContent) {
                $timers.PolicyRequest = $now
                $anyActivity = $true
            }

            if ($policyContent) {
                Invoke-SMBDeployment -Content $policyContent
                if (Invoke-ClientSelfUpdate -Content $policyContent -ListenerHost $listenerHost) {
                    exit 0
                }
            }
        }

        # Update Scan
        if (($now - $timers.UpdateScan).TotalSeconds -ge $Intervals.UpdateScan) {
            if (Send-UpdateScan -ListenerHost $listenerHost) {
                $timers.UpdateScan = $now
                $anyActivity = $true
            }
        }

        # Heartbeat
        if (($now - $timers.Heartbeat).TotalSeconds -ge $Intervals.Heartbeat) {
            if (Send-Heartbeat -ListenerHost $listenerHost) {
                $timers.Heartbeat = $now
                $anyActivity = $true
            }
        }

        if (-not $anyActivity) {
            Start-Sleep -Milliseconds 500
        }
    }

} catch {
    Write-Log "FATAL ERROR: $_" "ERROR"
    exit 1
}
