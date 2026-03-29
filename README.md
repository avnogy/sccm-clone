# SCCM Network Traffic Simulator

This repo is a PowerShell-based lab setup for generating SCCM-like traffic for packet capture and testing.

It has two roles:

- `SCCM-Server.ps1`: mock Management Point / Software Update Point / notification listener
- `SCCM-Client.ps1`: mock SCCM client that continuously generates recurring traffic

`SCCM-Config.ps1` contains the shared ports, intervals, retry settings, and deployment defaults used by both scripts.

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

## Files

- `SCCM-Config.ps1`: shared configuration
- `SCCM-Server.ps1`: mock SCCM server-side listener
- `SCCM-Client.ps1`: mock SCCM client

## Recording the Two Stages

Your two intended capture stages map directly to the server mode you start.

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
# .\SCCM-Server.ps1 -ServeSMBPolicy -PolicyHost "192.168.1.10"

# On each client
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Client.ps1 -ServerHost 192.168.1.10
```

What happens:

- the listener creates the SMB share and deployment script
- the policy response includes a `CommandLine` UNC path of the form `\\IP\Share\file`
- every client requests policy, recognizes the deployment path in the response, copies the file over SMB, and executes it

## Listener Behavior

`SCCM-Server.ps1`:

- creates or reuses a self-signed certificate for HTTPS listeners
- binds certificates to ports `443` and `8531`
- starts listeners on the configured HTTP, HTTPS, SUP, and notification ports
- serves normal SCCM-like policy responses by default
- creates an SMB share and returns deployment policy content only when `-ServeSMBPolicy` is used
- logs inbound requests and returns mock SCCM-style responses
- cleans up listeners, certificate bindings, and the SMB share on exit

### Listener Options

```powershell
.\SCCM-Server.ps1
.\SCCM-Server.ps1 -ServeSMBPolicy
.\SCCM-Server.ps1 -ShareName "CustomShare"
.\SCCM-Server.ps1 -SMBSharePath "C:\Temp\SCCMDeploy"
.\SCCM-Server.ps1 -ExeName "update.cmd"
.\SCCM-Server.ps1 -ServeSMBPolicy -PolicyHost "192.168.1.10"
```

Notes:

- `-ServeSMBPolicy` enables the stage-2 behavior: the listener creates the SMB share and returns deployment content from `/ccm_system/request`.
- `-ExeName` is normalized to a `.cmd` script if another extension is supplied.
- `-PolicyHost` controls the host part placed in the policy `CommandLine` UNC path. If you do not set it, the listener auto-detects a local IPv4 and uses that; if detection fails, it falls back to the computer name.
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
- deployment share name: `SCCMDeploy`
- deployment file name: `sccm_update.cmd`
- request retries: `3`
- retry delay: `5` seconds

## Multi-Client Use

One listener can serve multiple clients at the same time. The listener loop drains multiple queued HTTP requests and notification connections per pass, so running several client machines against one server is supported by design for this lab use case.

## Limitations

- This is a traffic simulator, not a real SCCM implementation.
- Response bodies are simplified and only cover the endpoints implemented in the scripts.
- Listener-host discovery depends on the local Windows environment.
- HTTPS handling is intentionally permissive for lab use and should not be treated as production-safe behavior.
