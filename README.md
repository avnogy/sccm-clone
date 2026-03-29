# SCCM Network Traffic Simulator

This package contains two PowerShell scripts to simulate SCCM client-server network traffic for generating PCAP files:

## Files

1. `SCCM-Config.ps1` - Shared configuration (dot-sourced by both scripts)
2. `SCCM-Listener.ps1` - Run on Domain Controller (requires Admin)
3. `SCCM-ClientSimulator.ps1` - Run on client machine

## Usage

### Quick Start - Choose Your Mode

#### Mode 1: Basic HTTP/HTTPS Traffic (no deployment)

```powershell
# On DC (as Administrator):
.\SCCM-Listener.ps1 -NoSMB

# On Client:
.\SCCM-ClientSimulator.ps1
```

#### Mode 2: With SMB Deployment (downloads and runs file from DC)

```powershell
# On DC (as Administrator):
.\SCCM-Listener.ps1

# On Client:
.\SCCM-ClientSimulator.ps1 -AutoDeploy
```

#### Mode 3: One-shot (single cycle, no loop)

```powershell
# On DC:
.\SCCM-Listener.ps1

# On Client:
.\SCCM-ClientSimulator.ps1 -OneShot -AutoDeploy
```

`-OneShot` now sends one immediate cycle of traffic and exits.

---

### 1. Start the Listener on DC (Run as Administrator)

```powershell
# On the Domain Controller
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Listener.ps1
```

The listener will:
- Generate a self-signed certificate for HTTPS ports
- Listen on all configured ports
- Create SMB share for deployment (unless -NoSMB is specified)
- Respond with appropriate SCCM-like responses
- Log all incoming requests to console
- Continue running until stopped with Ctrl+C

**Options:**
```powershell
.\SCCM-Listener.ps1 -NoSMB              # Disable SMB share
.\SCCM-Listener.ps1 -ShareName "Custom"  # Custom share name
.\SCCM-Listener.ps1 -ExeName "app.cmd"   # Custom deployment script name
```

### 2. Run the Client Simulator

```powershell
# On a client machine
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-ClientSimulator.ps1
```

The client simulator will:
- Discover the Domain Controller using multiple methods
- Generate realistic SCCM client traffic patterns:
  - Location requests (/sms_ls.srf) every 30 seconds
  - Policy requests (/ccm_system/request) every 60 seconds
  - Notification polls (TCP 10123) every 30 seconds
  - Update scans (/SimpleAuthwebservice/SimpleAuth.asmx) every 60 seconds
  - Heartbeats (/sms_mp) every 120 seconds
- Continue running continuously until stopped with Ctrl+C
- Use HTTPS by default (will accept self-signed certificates)

### Options for Client Simulator

- `-OneShot`: Run through one cycle of all traffic types then exit
- `-UseHTTPS:$false`: Force HTTP only (no SSL/TLS)
- `-AutoDeploy`: Request and execute SMB deployment from DC
- `-Verbose`: Show detailed debugging information

## Traffic Patterns

The simulator generates traffic that mimics real SCCM client behavior:

1. **Initial Discovery**: DNS queries and LDAP bind to DC
2. **Location Request**: Finds available MPs and SUPs
3. **Policy Request**: Downloads client policies
4. **Notification Poll**: Checks for pending actions on TCP 10123
5. **Update Scan**: Checks for software updates
6. **Heartbeat**: Sends DDR (Discovery Data Record) to MP
7. **SMB Deployment** (with -AutoDeploy): Downloads and executes file from DC via SMB
