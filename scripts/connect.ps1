# connect.ps1 - spin up a London Lightsail box, install IKEv2, connect Windows to it.
# Run via connect.bat (it self-elevates). Idempotent guard: refuses to double-spend.
#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# ---------------- config (edit here to change region/size) ----------------
$Region    = 'eu-west-2'        # London
$Zone      = 'eu-west-2a'
$Bundle    = 'micro_3_0'        # 1 GB RAM. The 512 MB 'nano' OOMs compiling Libreswan.
$Blueprint = 'ubuntu_24_04'
$Instance  = 'uk-vpn-oneclick'
$VpnName   = 'UK VPN (one-click)'
# --------------------------------------------------------------------------

try {
    Write-Log '=== UK VPN one-click: CONNECT ===' 'Cyan'
    Assert-Admin
    Assert-Tooling
    Assert-AwsCredentials

    if (Test-InstanceExists $Instance $Region) {
        Write-Host ''
        Write-Host "An instance named '$Instance' already exists and is billing." -ForegroundColor Yellow
        Write-Host "To just reconnect: open Windows Settings > VPN and click '$VpnName'." -ForegroundColor Yellow
        Write-Host "To start fresh or stop billing: run destroy.bat first." -ForegroundColor Yellow
        return
    }

    # 1. Create the instance
    Write-Log "Creating Lightsail $Bundle in London ($Region)..."
    Invoke-Aws @('lightsail','create-instances','--instance-names',$Instance,
        '--availability-zone',$Zone,'--blueprint-id',$Blueprint,'--bundle-id',$Bundle,
        '--ip-address-type','dualstack','--region',$Region) | Out-Null

    $ip = Wait-InstanceIp $Instance $Region
    Write-Log "Instance running at $ip" 'Green'

    # 2. Lock the firewall: SSH only from this PC's IP; IKEv2 UDP 500/4500 (cert-protected)
    $myIp = Get-PublicIp
    Write-Log "Locking firewall (SSH from $myIp only, IKEv2 500/4500)..."
    Invoke-Aws @('lightsail','put-instance-public-ports','--instance-name',$Instance,'--region',$Region,
        '--port-infos',
        "fromPort=22,toPort=22,protocol=TCP,cidrs=$myIp/32",
        'fromPort=500,toPort=500,protocol=UDP,cidrs=0.0.0.0/0',
        'fromPort=4500,toPort=4500,protocol=UDP,cidrs=0.0.0.0/0') | Out-Null

    # 3. SSH key
    $pem = Join-Path $StateDir 'lightsail.pem'
    $kp  = Invoke-Aws @('lightsail','download-default-key-pair','--region',$Region) | ConvertFrom-Json
    [IO.File]::WriteAllText($pem, $kp.privateKeyBase64)
    Lock-FilePermissions $pem

    # 4. Wait for SSH, then install the VPN on the server (~5 min: Libreswan compiles)
    Wait-Ssh $pem $ip
    $p12pass = New-RandomPassword
    Write-Log 'Installing VPN on the server (~5 min, please wait)...' 'Yellow'
    $remote = (Get-RemoteInstallScript).Replace('__P12PASS__', $p12pass)
    Invoke-RemoteScript $pem $ip $remote

    # 5. Pull the client cert + CA down
    $p12 = Join-Path $StateDir 'vpnclient.p12'
    $ca  = Join-Path $StateDir 'vpn-ca.pem'
    Invoke-Scp $pem "${ip}:/tmp/winclient.p12" $p12
    Invoke-Scp $pem "${ip}:/tmp/ca.pem" $ca

    Save-State @{ instance=$Instance; region=$Region; ip=$ip; vpnName=$VpnName
                  pem=$pem; p12=$p12; ca=$ca
                  createdUtc=(Get-Date).ToUniversalTime().ToString('o') }

    # 6. Trust the CA, import the client cert, (re)create the IKEv2 connection
    Write-Log 'Importing certificate and creating the IKEv2 VPN connection...'
    # Clear stale certs from prior runs so cert selection is unambiguous.
    Get-ChildItem Cert:\LocalMachine\My   -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=vpnclient' }    | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=IKEv2 VPN CA' } | Remove-Item -Force -ErrorAction SilentlyContinue
    Import-Certificate -FilePath $ca -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    $sec = ConvertTo-SecureString $p12pass -AsPlainText -Force
    Import-PfxCertificate -FilePath $p12 -CertStoreLocation Cert:\LocalMachine\My -Password $sec | Out-Null

    Get-VpnConnection -AllUserConnection -Name $VpnName -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-VpnConnection -Name $VpnName -AllUserConnection -Force }
    Add-VpnConnection -Name $VpnName -ServerAddress $ip -TunnelType IKEv2 `
        -AuthenticationMethod MachineCertificate -EncryptionLevel Required `
        -AllUserConnection -RememberCredential -Force
    # Crypto policy that matches the server (proven values from a live setup)
    Set-VpnConnectionIPsecConfiguration -ConnectionName $VpnName `
        -AuthenticationTransformConstants GCMAES128 -CipherTransformConstants GCMAES128 `
        -EncryptionMethod AES256 -IntegrityCheckMethod SHA256 `
        -PfsGroup None -DHGroup Group14 -AllUserConnection -Force

    # 7. Connect and verify we surface in the UK
    Write-Log 'Connecting...'
    $ErrorActionPreference = 'Continue'      # rasdial is native; its stderr must not abort us
    rasdial $VpnName | Out-Host
    $ErrorActionPreference = 'Stop'
    Start-Sleep -Seconds 3
    $geo = $null
    try { $geo = Get-GeoInfo } catch { }
    Write-Host ''
    if ($geo -and $geo.country -eq 'GB') {
        Write-Host "  Connected. You are now in $($geo.city), United Kingdom (IP $($geo.ip))." -ForegroundColor Green
        Write-Host '  Stream away. When you are done, run destroy.bat to stop all billing.' -ForegroundColor Green
    } elseif ($geo) {
        Write-Host "  Connected, but your IP shows $($geo.country) (expected GB). See docs\troubleshooting.md." -ForegroundColor Yellow
    } else {
        Write-Host '  Connected. (Could not auto-verify location - check https://ifconfig.me in a browser.)' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Log 'CONNECT complete.' 'Cyan'
}
catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'If a half-created instance is left behind, run destroy.bat to clean up and stop billing.' -ForegroundColor Yellow
    exit 1
}
