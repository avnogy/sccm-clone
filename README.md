# SCCM Network Traffic Simulator

This repo is a PowerShell-based lab setup for generating SCCM-like traffic for packet capture and testing.

It has two roles:

- `SCCM-Server.ps1`: mock Management Point / Software Update Point / notification listener
- `SCCM-Client.ps1`: mock SCCM client that continuously generates recurring traffic

`SCCM-Config.ps1` contains the shared ports, intervals, retry settings, and deployment defaults used by both scripts.

The default SMB deployment path is also controlled there through:

- `DefaultSMBSharePath`
- `SMBShareName`
- `SMBPolicyHost`
- `DeployExeName`

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
- automatic SMB download and execution whenever the returned policy contains deployment content

## Requirements

- Windows PowerShell or PowerShell on Windows
- Administrator privileges for `SCCM-Server.ps1`
- A Windows environment with the required features available for:
  - `HttpListener` on privileged ports
  - `New-SmbShare` / `Get-SmbShare`
  - certificate creation and `netsh http add sslcert`
- For client target discovery:
  - at least one of `nltest`, `LOGONSERVER`, `USERDNSDOMAIN`, or current-domain ADSI lookup must work

If discovery is not convenient in your lab, clients can be pointed directly at the listener with `-ServerHost`.

The listener does not have to run on an actual Domain Controller. It can run on any reachable Windows host that satisfies the requirements above.

If you want the server to automatically roll out the current client script to domain computers, run it on a domain controller or a host that has the Active Directory and Group Policy PowerShell modules plus write access to SYSVOL.

## Files

- `SCCM-Config.ps1`: shared configuration
- `SCCM-Server.ps1`: mock SCCM server-side listener
- `SCCM-Client.ps1`: mock SCCM client
- `Update-SCCMServer.ps1`: downloads the latest zip and extracts it in place

## Recording the Two Stages

Your two intended capture stages map directly to the server mode you start.

If you want to refresh the local files from GitHub before launch, you can use:

```powershell
.\Update-SCCMServer.ps1
```

Then start the server normally with the options you want.

### Stage 1: Normal Day-to-Day SCCM Traffic

Goal:

- location requests
- policy requests without deployment content
- notification polling
- update scans
- heartbeats

Run it like this:

```powershell
# On the listener host, as Administrator
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Server.ps1

# On each client
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Client.ps1 -ServerHost 192.168.1.10
```

What happens:

- the listener returns normal mock SCCM responses
- the policy endpoint returns a basic success response with no deployment `CommandLine`
- clients keep generating recurring SCCM-like traffic only
- the server refreshes a dedicated computer-startup GPO so domain machines pick up the latest `SCCM-Client.ps1` and `SCCM-Config.ps1`

### Stage 2: Policy Delivery Followed by SMB Fetch and Execution

Goal:

- normal SCCM traffic
- a policy response that contains a UNC path to a file
- client SMB access to that file
- client execution of the downloaded payload

Run it like this:

```powershell
# On the listener host, as Administrator
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Server.ps1 -ServeSMBPolicy

# Or, if you want the policy to advertise a specific IP:
# On each client
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Client.ps1 -ServerHost 192.168.1.10
```

What happens:

- the listener creates the SMB share and deployment script
- the first stage-2 policy response for each client includes a `CommandLine` UNC path of the form `\\IP\Share\file`
- the server sends that deployment policy once per client per server run
- every client requests policy, recognizes the deployment path in the response, copies the file over SMB, and executes it
- each client executes a given deployment path once per client process lifetime, which prevents the same payload from re-running every policy interval
- the server refreshes the domain startup deployment so rebooted domain computers pick up the latest client version automatically

## Listener Behavior

`SCCM-Server.ps1`:

- creates or reuses a self-signed certificate for HTTPS listeners
- binds certificates to ports `443` and `8531`
- starts listeners on the configured HTTP, HTTPS, SUP, and notification ports
- serves normal SCCM-like policy responses by default
- creates an SMB share and sends one SMB deployment policy per client only when `-ServeSMBPolicy` is used
- refreshes a dedicated domain computer-startup GPO on each run so the latest client script is published into SYSVOL
- logs inbound requests and returns mock SCCM-style responses
- cleans up listeners, certificate bindings, and the SMB share on exit

### Listener Options

```powershell
.\SCCM-Server.ps1
.\SCCM-Server.ps1 -ServeSMBPolicy
.\SCCM-Server.ps1 -ShareName "CustomShare"
.\SCCM-Server.ps1 -SMBSharePath "C:\Temp\SCCMDeploy"
.\SCCM-Server.ps1 -ExeName "update.cmd"
.\SCCM-Server.ps1 -ClientStartupGpoName "SCCM Simulator Client Startup"
.\SCCM-Server.ps1 -ClientInstallRoot "C:\ProgramData\SCCMSim"
```

Notes:

- `-ServeSMBPolicy` enables the stage-2 behavior: the listener creates the SMB share and sends one deployment policy per client from `/ccm_system/request`.
- `-ExeName` is normalized to a `.cmd` script if another extension is supplied.
- `SMBPolicyHost` in `SCCM-Config.ps1` controls the host part placed in the policy `CommandLine` UNC path. If it is blank, the listener auto-detects a local IPv4 and uses that; if detection fails, it falls back to the computer name.
- `-ClientStartupGpoName` controls the dedicated computer-startup GPO that the server refreshes each run.
- `-ClientInstallRoot` controls where the startup script copies the client locally on each machine before launching it.
- The generated deployment file is a simple command script that appends to `C:\sccm_deployed.log`.

## Client Behavior

`SCCM-Client.ps1`:

- tries several methods to discover a target host
- can be pointed directly at a listener host with `-ServerHost`
- uses HTTPS by default
- accepts self-signed certificates when HTTPS is enabled
- retries HTTP requests according to the shared config
- runs continuously until stopped
- initializes its timers so the first cycle is sent immediately
- always requests policy content and inspects it for deployment data
- automatically executes SMB deployment content whenever the returned policy includes a `CommandLine` path
- ignores later identical deployment paths after it has already handled them once in that client process

### Client Options

```powershell
.\SCCM-Client.ps1
.\SCCM-Client.ps1 -ServerHost 192.168.1.10
.\SCCM-Client.ps1 -UseHTTPS:$false
.\SCCM-Client.ps1 -Verbose
```

Notes:

- there is no client-side deployment flag; deployment behavior is controlled entirely by the server response
- `-ServerHost` is the simplest way to run several lab clients against one known listener
- the client avoids re-running the exact same deployment path over and over during one session
- `.cmd` and `.bat` payloads are executed via `cmd.exe`

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
- deployment share path: `C:\SCCMDeploy`
- deployment share name: `SCCMDeploy`
- deployment policy host: `SMBPolicyHost` from config, otherwise auto-detect
- deployment file name: `sccm_update.cmd`
- generated deployment file size: `64` KB
- padded location response entries: `8`
- padded policy response entries: `20`
- padded update response entries: `16`
- padded heartbeat response entries: `8`
- request retries: `3`
- retry delay: `5` seconds

## Multi-Client Use

One listener can serve multiple clients at the same time. The listener loop drains multiple queued HTTP requests and notification connections per pass, so running several client machines against one server is supported by design for this lab use case.

## Limitations

- This is a traffic simulator, not a real SCCM implementation.
- Response bodies are simplified and only cover the endpoints implemented in the scripts.
- Listener-host discovery depends on the local Windows environment.
- HTTPS handling is intentionally permissive for lab use and should not be treated as production-safe behavior.
