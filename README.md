# SCCM Network Traffic Simulator

This package contains two PowerShell scripts to simulate SCCM client-server network traffic for generating PCAP files:

## Files

1. `SCCM-Config.ps1` - Shared configuration (dot-sourced by both scripts)
2. `SCCM-Listener.ps1` - Run on Domain Controller (requires Admin)
3. `SCCM-ClientSimulator.ps1` - Run on client machine

## Prerequisites

- PowerShell 5.1+
- For Listener: Administrator privileges (to bind to ports 80, 443, etc.)
- Network connectivity between client and DC

## Ports Used

| Port | Protocol | Purpose |
|------|----------|---------|
| 80/tcp | HTTP | Management Point |
| 443/tcp | HTTPS | Management Point |
| 8530/tcp | HTTP | Software Update Point |
| 8531/tcp | HTTPS | Software Update Point |
| 10123/tcp | TCP | Client Notification |

## Usage

### 1. Start the Listener on DC (Run as Administrator)

```powershell
# On the Domain Controller
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SCCM-Listener.ps1
```

The listener will:
- Generate a self-signed certificate for HTTPS ports
- Listen on all configured ports
- Respond with appropriate SCCM-like responses
- Log all incoming requests to console
- Continue running until stopped with Ctrl+C

**With SMB Deployment (optional):**
```powershell
# Creates SMB share and returns deployment policy
.\SCCM-Listener.ps1 -SMBShareName "SCCMDeploy" -DeployExeName "sccm_update.exe"
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

## PCAP Capture

To capture the traffic:
1. Start Wireshark/tcpdump on the client machine
2. Or configure a span port/mirror port on your switch
3. Filter suggestions:
   - `http or tcp.port == 10123 or tcp.port == 8530 or tcp.port == 8531`
   - `ip.addr == [DC_IP] and (tcp.port == 80 or tcp.port == 443 or tcp.port == 8530 or tcp.port == 8531 or tcp.port == 10123)`
   - For SMB: `smb or smb2`

## Notes

- The listener uses a self-signed certificate - clients will warn about untrusted cert if using HTTPS
- All responses are minimal but valid to elicit the expected client behavior
- Traffic intervals are configurable in the scripts
- No actual SCCM infrastructure is required - this works against any DC
- Scripts include retry logic for failed connections

## Troubleshooting

**"Access denied" when starting listener:**
- Make sure you're running PowerShell as Administrator
- Check that the ports aren't already in use

**Client can't connect to DC:**
- Verify network connectivity
- Check Windows Firewall on DC
- Confirm the DC discovery is working (check console output)

**No traffic showing in PCAP:**
- Verify both scripts are running
- Check that client is resolving DC correctly
- Ensure traffic is flowing through the captured interface