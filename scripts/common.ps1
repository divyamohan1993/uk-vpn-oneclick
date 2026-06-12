# common.ps1 - shared helpers for the UK VPN one-click tool.
# Dot-sourced by connect.ps1 and destroy.ps1. No side effects on load.
#
# IMPORTANT: native tools (aws/ssh/scp/rasdial) write progress to stderr. Under
# $ErrorActionPreference='Stop' (set by the callers), PowerShell 5.1 turns ANY
# native stderr line into a terminating error. So every function that shells out
# sets $ErrorActionPreference='Continue' locally and checks $LASTEXITCODE instead.

# All runtime secrets/state live OUTSIDE the repo so they can never be committed.
$script:StateDir = Join-Path $env:LOCALAPPDATA 'uk-vpn-oneclick'
$script:LogFile  = Join-Path $script:StateDir 'log.txt'
$StateDir        = $script:StateDir   # exported for callers

function Ensure-StateDir {
    if (-not (Test-Path $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message
    Write-Host $line -ForegroundColor $Color
    Ensure-StateDir
    $line | Out-File -FilePath $script:LogFile -Append -Encoding utf8
}

function Fail {
    param([string]$Message)
    Write-Log "ERROR: $Message" 'Red'
    throw $Message
}

# --- elevation / tooling ---------------------------------------------------

function Assert-Admin {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { Fail "This must run elevated. Double-click connect.bat / destroy.bat (they self-elevate)." }
}

# Refresh PATH from registry (a fresh winget install is not on the current session PATH)
# and return the path to aws.exe, or $null.
function Get-AwsExe {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    $cmd = Get-Command aws -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $default = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    if (Test-Path $default) { return $default }
    return $null
}

function Assert-Tooling {
    if (-not (Get-AwsExe)) {
        Write-Log 'AWS CLI not found - installing via winget...' 'Yellow'
        winget install --id Amazon.AWSCLI --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
        if (-not (Get-AwsExe)) { Fail 'AWS CLI install failed. Install it manually: https://aws.amazon.com/cli/' }
    }
    foreach ($t in 'ssh','scp') {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
            Fail "$t.exe not found. Enable 'OpenSSH Client' in Windows Settings > Optional features."
        }
    }
}

# --- aws wrapper -----------------------------------------------------------
# Runs aws, captures stdout, routes stderr to a temp file, throws on non-zero.
function Invoke-Aws {
    param([Parameter(Mandatory)][string[]]$AwsArgs)
    $ErrorActionPreference = 'Continue'   # native stderr must not auto-terminate
    $env:AWS_PAGER = ''
    $exe = Get-AwsExe
    if (-not $exe) { Fail 'AWS CLI not found.' }
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out  = & $exe @AwsArgs 2> $errFile
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $err = (Get-Content $errFile -Raw)
            throw "aws $($AwsArgs -join ' ') failed (exit $code): $err"
        }
        return ($out -join "`n")
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Assert-AwsCredentials {
    try {
        $id = Invoke-Aws @('sts','get-caller-identity','--output','json') | ConvertFrom-Json
        Write-Log "AWS account $($id.Account) as $($id.Arn)"
    } catch {
        Fail "AWS credentials not set. Open a NEW terminal, run:  aws configure  (region eu-west-2). See README.md."
    }
}

# --- lightsail helpers -----------------------------------------------------

function Test-InstanceExists {
    param([string]$Name, [string]$Region)
    try {
        $j = Invoke-Aws @('lightsail','get-instance','--instance-name',$Name,'--region',$Region,'--output','json') | ConvertFrom-Json
        return [bool]$j.instance
    } catch { return $false }
}

function Wait-InstanceIp {
    param([string]$Name, [string]$Region, [int]$Tries = 30)
    for ($i = 0; $i -lt $Tries; $i++) {
        $j = Invoke-Aws @('lightsail','get-instance','--instance-name',$Name,'--region',$Region,'--output','json') | ConvertFrom-Json
        if ($j.instance.state.name -eq 'running' -and $j.instance.publicIpAddress) {
            return $j.instance.publicIpAddress
        }
        Start-Sleep -Seconds 8
    }
    Fail "Instance '$Name' did not reach running state in time."
}

# --- ssh / scp -------------------------------------------------------------
$script:KnownHosts = Join-Path $env:TEMP 'uk-vpn-known_hosts'
$script:SshOpts = @('-o','StrictHostKeyChecking=no','-o',"UserKnownHostsFile=$script:KnownHosts",'-o','LogLevel=ERROR')

function Wait-Ssh {
    param([string]$Pem, [string]$Ip, [int]$Tries = 20)
    $ErrorActionPreference = 'Continue'
    for ($i = 0; $i -lt $Tries; $i++) {
        $o = ssh -i $Pem @script:SshOpts -o ConnectTimeout=8 "ubuntu@$Ip" 'echo READY' 2> $null
        if ($o -match 'READY') { return }
        Start-Sleep -Seconds 8
    }
    Fail "SSH to $Ip never became reachable."
}

# Sends a bash script base64-encoded (dodges all PowerShell->ssh quoting issues)
# and runs it as root. Remote stderr is merged into stdout so it streams cleanly.
function Invoke-RemoteScript {
    param([string]$Pem, [string]$Ip, [string]$Script)
    $ErrorActionPreference = 'Continue'
    $clean = $Script -replace "`r", ''
    $b64   = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clean))
    ssh -i $Pem @script:SshOpts "ubuntu@$Ip" "echo $b64 | base64 -d | sudo bash 2>&1"
    if ($LASTEXITCODE -ne 0) { Fail "Remote VPN install failed (exit $LASTEXITCODE)." }
}

function Invoke-Scp {
    param([string]$Pem, [string]$RemotePath, [string]$LocalPath)
    $ErrorActionPreference = 'Continue'
    scp -i $Pem @script:SshOpts "ubuntu@$RemotePath" $LocalPath
    if ($LASTEXITCODE -ne 0) { Fail "scp $RemotePath failed." }
}

# --- misc ------------------------------------------------------------------

function Lock-FilePermissions {
    # OpenSSH refuses a key readable by other principals. Remove inheritance and
    # grant ONLY the current user (full, so we can also delete it on teardown).
    param([string]$Path)
    icacls $Path /inheritance:r | Out-Null
    icacls $Path /grant:r "$($env:USERNAME):F" | Out-Null
}

function New-RandomPassword {
    param([int]$Length = 20)
    -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $Length | ForEach-Object { [char]$_ })
}

function Get-PublicIp {
    (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim()
}

function Get-GeoInfo {
    $ip = Get-PublicIp
    $g  = Invoke-RestMethod -Uri "https://ipinfo.io/$ip/json" -TimeoutSec 15
    [pscustomobject]@{ ip = $ip; city = $g.city; region = $g.region; country = $g.country; org = $g.org }
}

function Save-State {
    param([hashtable]$State)
    Ensure-StateDir
    $State | ConvertTo-Json | Out-File -FilePath (Join-Path $script:StateDir 'state.json') -Encoding utf8
}

function Load-State {
    $f = Join-Path $script:StateDir 'state.json'
    if (Test-Path $f) { return Get-Content $f -Raw | ConvertFrom-Json }
    return $null
}

# The server-side install. Runs as root. __P12PASS__ is replaced before sending.
# - 2 GB swap so Libreswan compiles on a 1 GB box
# - hwdsl2 installer auto-configures IKEv2 (client nickname 'vpnclient')
# - re-export the client .p12 with a KNOWN password so Windows can import it
function Get-RemoteInstallScript {
@'
set -e
export DEBIAN_FRONTEND=noninteractive
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
if [ ! -f /opt/.vpn-installed ]; then
  wget -qO /tmp/vpn.sh https://get.vpnsetup.net
  VPN_IPSEC_PSK="$(openssl rand -base64 24)" VPN_USER=vpnuser VPN_PASSWORD="$(openssl rand -base64 18)" sh /tmp/vpn.sh
  touch /opt/.vpn-installed
fi
if ! certutil -L -d sql:/etc/ipsec.d 2>/dev/null | grep -q vpnclient; then
  VPN_CLIENT_NAME=vpnclient ikev2.sh --auto || true
fi
pk12util -o /tmp/winclient.p12 -n vpnclient -d sql:/etc/ipsec.d -W "__P12PASS__" -K ""
certutil -L -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" -a > /tmp/ca.pem
chmod 644 /tmp/winclient.p12 /tmp/ca.pem
echo REMOTE_DONE_OK
'@
}
