$ErrorActionPreference = "Stop"

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetDir = "__CLIENT_INSTALL_ROOT__"
$useHttps = __USE_HTTPS__
$startupLogPath = Join-Path $targetDir "startup-deploy.log"

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
if (Test-Path $startupLogPath) { Remove-Item -Path $startupLogPath -Force }
"[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Startup deployment invoked" | Out-File -FilePath $startupLogPath -Append -Encoding ASCII

Copy-Item -Path (Join-Path $sourceDir "SCCM-Client.ps1") -Destination (Join-Path $targetDir "SCCM-Client.ps1") -Force
Copy-Item -Path (Join-Path $sourceDir "SCCM-Config.ps1") -Destination (Join-Path $targetDir "SCCM-Config.ps1") -Force
"[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Client files copied from $sourceDir" | Out-File -FilePath $startupLogPath -Append -Encoding ASCII

$existingProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -in @("powershell.exe", "pwsh.exe") -and
        $_.CommandLine -match "SCCM-Client\.ps1"
    }

foreach ($process in $existingProcesses) {
    try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Stopped existing client process $($process.ProcessId)" | Out-File -FilePath $startupLogPath -Append -Encoding ASCII
    } catch {
    }
}

$argumentList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $targetDir "SCCM-Client.ps1")
)

if (-not $useHttps) {
    $argumentList += "-UseHTTPS:`$false"
}

$clientPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$quotedClientPowerShell = '"' + $clientPowerShell + '"'
$quotedLogPathForSet = $startupLogPath.Replace('"', '""')
$quotedStartupLogPath = '"' + $startupLogPath + '"'
$commandLine = ($argumentList | ForEach-Object {
    if ($_ -match '\s') {
        '"' + $_.Replace('"', '""') + '"'
    } else {
        $_
    }
}) -join ' '

try {
    $process = Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList "/c set ""SCCM_CLIENT_LOG_PATH=$quotedLogPathForSet"" && $quotedClientPowerShell $commandLine >> $quotedStartupLogPath 2>&1" `
        -WindowStyle Hidden `
        -PassThru `
        -ErrorAction Stop

    "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Started SCCM client (PID: $($process.Id))" | Out-File -FilePath $startupLogPath -Append -Encoding ASCII
} catch {
    "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Failed to start SCCM client: $($_.Exception.Message)" | Out-File -FilePath $startupLogPath -Append -Encoding ASCII
    throw
}
