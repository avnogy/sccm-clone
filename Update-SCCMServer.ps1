<#
.SYNOPSIS
Downloads the latest SCCM simulator files directly from the repository.
.USAGE
    .\Update-SCCMServer.ps1
#>

[CmdletBinding()]
param(
    [string]$RepositoryBaseUrl = "https://raw.githubusercontent.com/avnogy/sccm-clone/master"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$updaterName = [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
$updateMarkerPath = Join-Path $scriptDir "SCCM-Updated.txt"
$stagingPath = Join-Path $scriptDir "sccm-update-staging"
$configSourcePath = Join-Path $scriptDir "SCCM-Config.ps1"
$managedFiles = @(
    "README.md",
    "SCCM-Client-Startup.ps1",
    "SCCM-Client.ps1",
    "SCCM-Config.ps1",
    "SCCM-Server.ps1",
    "Update-SCCMServer.ps1"
)

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
        Write-Host "Failed to determine listener IPv4 address: $($_.Exception.Message)"
    }

    return $null
}

function Get-LocalSysvolPolicyPath {
    param([string]$DomainDnsRoot, [Guid]$GpoId)

    $policyFolderName = $GpoId.ToString("B").ToUpperInvariant()
    return (Join-Path $env:SystemRoot "SYSVOL\sysvol\$DomainDnsRoot\Policies\$policyFolderName")
}

function Get-LocalSysvolScriptsPath {
    param([string]$DomainDnsRoot)

    return (Join-Path $env:SystemRoot "SYSVOL\sysvol\$DomainDnsRoot\scripts")
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
    param(
        [string]$ScriptDir
    )

    $clientSourcePath = Join-Path $ScriptDir "SCCM-Client.ps1"
    $configSourcePath = Join-Path $ScriptDir "SCCM-Config.ps1"
    $clientStartupSourcePath = Join-Path $ScriptDir "SCCM-Client-Startup.ps1"

    if (-not (Test-Path $clientSourcePath) -or -not (Test-Path $configSourcePath) -or -not (Test-Path $clientStartupSourcePath)) {
        throw "Client deployment skipped: required client files are missing next to the updater script"
    }

    $requiredCommands = @("Get-ADDomain", "Get-ADObject", "Set-ADObject", "Get-GPO", "New-GPO", "New-GPLink", "Get-GPInheritance", "Set-GPRegistryValue")
    foreach ($commandName in $requiredCommands) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "Client deployment skipped: required command '$commandName' is not available"
        }
    }

    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module GroupPolicy -ErrorAction Stop

    . $configSourcePath

    $domain = Get-ADDomain -ErrorAction Stop
    $gpo = Get-GPO -Name $ClientStartupGpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $ClientStartupGpoName -ErrorAction Stop
        Write-Host "Created startup GPO: $ClientStartupGpoName"
    } else {
        Write-Host "Using existing startup GPO: $ClientStartupGpoName"
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
        Write-Host "Linked startup GPO to domain root: $($domain.DNSRoot)"
    }

    Set-GPRegistryValue -Name $ClientStartupGpoName `
        -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -ValueName "SyncForegroundPolicy" `
        -Type DWord `
        -Value 1 | Out-Null
    Set-GPRegistryValue -Name $ClientStartupGpoName `
        -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" `
        -ValueName "GpNetworkStartTimeoutPolicyValue" `
        -Type DWord `
        -Value 30 | Out-Null

    $policyPath = Get-LocalSysvolPolicyPath -DomainDnsRoot $domain.DNSRoot -GpoId $gpo.Id
    $domainScriptsPath = Get-LocalSysvolScriptsPath -DomainDnsRoot $domain.DNSRoot
    $machineScriptsPath = Join-Path $policyPath "Machine\Scripts"
    $startupPath = Join-Path $machineScriptsPath "Startup"
    New-Item -ItemType Directory -Path $domainScriptsPath -Force | Out-Null
    New-Item -ItemType Directory -Path $startupPath -Force | Out-Null

    $startupCmdName = "SCCM-Client-Startup.cmd"
    $startupPs1Name = "SCCM-Client-Startup.ps1"
    $scriptDestinations = @($startupPath, $domainScriptsPath)
    $scriptCopies = @(
        @{ Source = $clientSourcePath; Name = "SCCM-Client.ps1" },
        @{ Source = $configSourcePath; Name = "SCCM-Config.ps1" }
    )

    foreach ($destinationRoot in $scriptDestinations) {
        foreach ($scriptCopy in $scriptCopies) {
            Copy-Item -Path $scriptCopy.Source -Destination (Join-Path $destinationRoot $scriptCopy.Name) -Force
        }
    }

    $startupContent = Get-Content -Path $clientStartupSourcePath -Raw
    $startupContent = $startupContent.Replace("__CLIENT_INSTALL_ROOT__", $ClientInstallRoot.Replace('"', '""'))
    $startupContent = $startupContent.Replace("__USE_HTTPS__", $(if ($UseHTTPS) { '$true' } else { '$false' }))
    foreach ($destinationRoot in $scriptDestinations) {
        Set-Content -Path (Join-Path $destinationRoot $startupPs1Name) -Value $startupContent -Encoding UTF8
    }

    $startupCmdContent = @"
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0$startupPs1Name"
exit /b %errorlevel%
"@
    foreach ($destinationRoot in $scriptDestinations) {
        Set-Content -Path (Join-Path $destinationRoot $startupCmdName) -Value $startupCmdContent -Encoding ASCII
    }

    foreach ($stalePath in @(
        (Join-Path $startupPath "Install-SCCMClient.ps1"),
        (Join-Path $domainScriptsPath "Install-SCCMClient.ps1")
    )) {
        if (Test-Path $stalePath) {
            Remove-Item -Path $stalePath -Force
        }
    }

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

    Write-Host "Published latest client startup deployment to: $startupPath"
    Write-Host "Published client copies to domain scripts path: $domainScriptsPath"
}

function Save-ManagedFile {
    param(
        [string]$FileName,
        [string]$DestinationPath
    )

    $fileUrl = "{0}/{1}" -f $RepositoryBaseUrl.TrimEnd('/'), $FileName
    $downloadPath = "${DestinationPath}.download"

    if (Test-Path $downloadPath) {
        Remove-Item -Path $downloadPath -Force
    }

    Write-Host "Downloading $fileUrl"
    $requestParams = @{
        Uri         = $fileUrl
        OutFile     = $downloadPath
        ErrorAction = "Stop"
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $requestParams["UseBasicParsing"] = $true
    }
    Invoke-WebRequest @requestParams

    if (-not (Test-Path $downloadPath)) {
        throw "Download failed: $downloadPath was not created"
    }

    Move-Item -Path $downloadPath -Destination $DestinationPath -Force
}

Write-Host "Downloading latest repository files from $RepositoryBaseUrl"
$previousSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol
try {
    $modernProtocols = [System.Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls13') {
        $modernProtocols = $modernProtocols -bor [System.Net.SecurityProtocolType]::Tls13
    }

    [System.Net.ServicePointManager]::SecurityProtocol = $modernProtocols

    if (Test-Path $stagingPath) {
        Remove-Item -Path $stagingPath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null

    foreach ($fileName in $managedFiles) {
        $destinationPath = Join-Path $stagingPath $fileName
        Save-ManagedFile -FileName $fileName -DestinationPath $destinationPath
    }
}
finally {
    [System.Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
}

foreach ($fileName in $managedFiles) {
    $stagedPath = Join-Path $stagingPath $fileName
    if (-not (Test-Path $stagedPath)) {
        throw "Managed file missing from staging: $fileName"
    }

    if ($fileName -ne $updaterName) {
        Copy-Item -Path $stagedPath -Destination (Join-Path $scriptDir $fileName) -Force
    }
}

Remove-Item -Path $stagingPath -Recurse -Force

$updateMarker = @"
UPDATED_AT=$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
PACKAGE_URL=$RepositoryBaseUrl
"@
Set-Content -Path $updateMarkerPath -Value $updateMarker -Encoding ASCII

if (-not (Test-Path (Join-Path $scriptDir "SCCM-Server.ps1"))) {
    throw "Server script not found after refresh"
}

. $configSourcePath

Write-Host "Refreshing published client deployment"
Publish-ClientStartupDeployment -ScriptDir $scriptDir

Write-Host "Update complete. Marker written to $updateMarkerPath"
Write-Host "Client startup deployment was refreshed."
Write-Host "Start the server manually with .\\SCCM-Server.ps1"
