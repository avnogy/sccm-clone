# SCCM Network Traffic Simulator

This repo contains a small PowerShell-based lab setup for generating SCCM-like client/server traffic for packet capture and testing.

It has two main roles:

- `SCCM-Listener.ps1`: mock Management Point / Software Update Point / notification listener
- `SCCM-ClientSimulator.ps1`: mock SCCM client that discovers a host and generates recurring traffic

`SCCM-Config.ps1` contains the shared ports, intervals, retry settings, and SMB deployment defaults used by both scripts.

## What It Simulates

The listener exposes these endpoints:

- `80/tcp`: HTTP Management Point
- `443/tcp`: HTTPS Management Point
- `8530/tcp`: HTTP Software Update Point
- `8531/tcp`: HTTPS Software Update Point
- `10123/tcp`: client notification TCP listener

The client simulator generates:

- location requests to `/sms_ls.srf`
- policy requests to `/ccm_system/request`
- notification polls on TCP `10123`
- update scan requests to `/SimpleAuthwebservice/SimpleAuth.asmx`
- heartbeats to `/sms_mp`
- optional SMB download and execution when `-AutoDeploy` is used

## Requirements

- Windows PowerShell or PowerShell on Windows
- Administrator privileges for `SCCM-Listener.ps1`
- A Windows environment with the required features available for:
  - `HttpListener` on privileged ports
  - `New-SmbShare` / `Get-SmbShare`
  - certificate creation and `netsh http add sslcert`
- For domain-controller discovery in the client:
  - at least one of `nltest`, `LOGONSERVER`, `USERDNSDOMAIN`, or current-domain ADSI lookup must work

The listener does not have to run on an actual Domain Controller. It can run on any reachable Windows host that satisfies the requirements above.

## Files

- `SCCM-Config.ps1`: shared configuration
- `SCCM-Listener.ps1`: mock SCCM server-side listener
- `SCCM-ClientSimulator.ps1`: mock SCCM client

## Quick Start

### Mode 1: Traffic Only

Run the listener without SMB deployment:

```powershell
# On the listener host, as Administrator
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Listener.ps1 -NoSMB

# On the client host
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-ClientSimulator.ps1
```

### Mode 2: Traffic Plus SMB Deployment

Run the listener with the default SMB share and deployment script:

```powershell
# On the listener host, as Administrator
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Listener.ps1

# On the client host
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-ClientSimulator.ps1 -AutoDeploy
```

### Mode 3: One-Shot

Send one immediate cycle and exit:

```powershell
# On the listener host, as Administrator
.\SCCM-Listener.ps1

# On the client host
.\SCCM-ClientSimulator.ps1 -OneShot -AutoDeploy
```

## Listener Behavior

`SCCM-Listener.ps1`:

- creates or reuses a self-signed certificate for HTTPS listeners
- binds certificates to ports `443` and `8531`
- starts listeners on the configured HTTP, HTTPS, SUP, and notification ports
- optionally creates an SMB share and publishes a deployment script
- logs inbound requests and returns mock SCCM-style responses
- cleans up listeners, certificate bindings, and the SMB share on exit

### Listener Options

```powershell
.\SCCM-Listener.ps1 -NoSMB
.\SCCM-Listener.ps1 -ShareName "CustomShare"
.\SCCM-Listener.ps1 -SMBSharePath "C:\Temp\SCCMDeploy"
.\SCCM-Listener.ps1 -ExeName "update.cmd"
```

Notes:

- `-ExeName` is normalized to a `.cmd` script if another extension is supplied.
- The generated deployment file is a simple command script that appends to `C:\sccm_deployed.log`.

## Client Behavior

`SCCM-ClientSimulator.ps1`:

- tries several methods to discover a target host
- uses HTTPS by default
- accepts self-signed certificates when HTTPS is enabled
- retries HTTP requests according to the shared config
- runs continuously until stopped, unless `-OneShot` is used
- initializes its timers so the first cycle is sent immediately

### Client Options

```powershell
.\SCCM-ClientSimulator.ps1
.\SCCM-ClientSimulator.ps1 -OneShot
.\SCCM-ClientSimulator.ps1 -UseHTTPS:$false
.\SCCM-ClientSimulator.ps1 -AutoDeploy
.\SCCM-ClientSimulator.ps1 -Verbose
```

Notes:

- `-OneShot` sends one immediate cycle of all request types, then exits.
- `-AutoDeploy` requests policy content, copies the referenced SMB payload locally, and executes it.
- `.cmd` and `.bat` payloads are executed via `cmd.exe`.

## Default Configuration

Current defaults from `SCCM-Config.ps1`:

- HTTP MP: `80`
- HTTPS MP: `443`
- HTTP SUP: `8530`
- HTTPS SUP: `8531`
- notification TCP: `10123`
- location request interval: `30` seconds
- policy request interval: `60` seconds
- notification interval: `30` seconds
- update scan interval: `60` seconds
- heartbeat interval: `120` seconds
- deployment share name: `SCCMDeploy`
- deployment file name: `sccm_update.cmd`
- request retries: `3`
- retry delay: `5` seconds

## Limitations

- This is a traffic simulator, not a real SCCM implementation.
- Response bodies are simplified and only cover the endpoints implemented in the scripts.
- Domain discovery depends on the local Windows environment.
- HTTPS handling is intentionally permissive for lab use and should not be treated as production-safe behavior.
