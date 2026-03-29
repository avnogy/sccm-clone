$ErrorActionPreference = "Stop"

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetDir = "__CLIENT_INSTALL_ROOT__"
$serverHost = "__SERVER_HOST__"
$useHttps = [System.Convert]::ToBoolean("__USE_HTTPS__")
$startupLogPath = Join-Path $targetDir "startup-deploy.log"

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
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
    "-File", (Join-Path $targetDir "SCCM-Client.ps1"),
    "-ServerHost", $serverHost
)

if (-not $useHttps) {
    $argumentList += "-UseHTTPS:`$false"
}

$clientPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
Start-Process -FilePath $clientPowerShell -ArgumentList $argumentList -WindowStyle Hidden
"[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Started SCCM client for server $serverHost" | Out-File -FilePath $startupLogPath -Append -Encoding ASCII
