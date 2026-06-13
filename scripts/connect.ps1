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
$Bundle    = 'nano_3_0'         # 512 MB RAM (+2 GB swap). Cheaper; risk is OOM compiling Libreswan - testing it.
$Blueprint = 'ubuntu_24_04'
$Instance  = 'uk-vpn-oneclick'
$VpnName   = 'UK VPN (one-click)'
# --------------------------------------------------------------------------

try {
    Write-Log '=== UK VPN one-click: CONNECT ===' 'Cyan'
    Assert-Admin
    Assert-Tooling
    Assert-AwsCredentials

    # If THIS PC is already on this VPN (a re-run), drop it first - otherwise Get-PublicIp
    # would read the VPN's UK exit IP and we'd lock the firewall to the wrong address.
    $ErrorActionPreference = 'Continue'; rasdial $VpnName /disconnect 2>$null | Out-Null; $ErrorActionPreference = 'Stop'

    # 1. Create the UK server, OR join the one that already exists (create-or-join).
    $creating = -not (Test-InstanceExists $Instance $Region)
    if ($creating) {
        Write-Log "No UK server yet - creating one ($Bundle, London $Region)..."
        # Born tagged ($TagKey=$TagValue): the tag is applied atomically at creation,
        # so even a half-finished create is recognisable - and deletable - by destroy.
        Invoke-Aws @('lightsail','create-instances','--instance-names',$Instance,
            '--availability-zone',$Zone,'--blueprint-id',$Blueprint,'--bundle-id',$Bundle,
            '--ip-address-type','dualstack','--region',$Region,
            '--tags',"key=$TagKey,value=$TagValue") | Out-Null
        $ip = Wait-InstanceIp $Instance $Region
        Write-Log "Instance running at $ip" 'Green'
    } else {
        Write-Log "UK server already exists - joining THIS device to it (no new server, no extra cost)." 'Green'
        # Self-heal: stamp our tag in case this instance predates tag-aware connect,
        # so teardown can recognise it as ours. Idempotent.
        Set-OurTag $Instance $Region
        $ip = Wait-InstanceIp $Instance $Region
    }

    # 2. Lock the firewall: SSH only from this PC's IP; VPN ports open (cert/key-protected)
    $myIp = Get-PublicIp
    Write-Log "Locking firewall (SSH from $myIp only; IKEv2 500/4500; WireGuard 51820)..."
    Invoke-Aws @('lightsail','put-instance-public-ports','--instance-name',$Instance,'--region',$Region,
        '--port-infos',
        "fromPort=22,toPort=22,protocol=TCP,cidrs=$myIp/32",
        'fromPort=500,toPort=500,protocol=UDP,cidrs=0.0.0.0/0',
        'fromPort=4500,toPort=4500,protocol=UDP,cidrs=0.0.0.0/0',
        'fromPort=51820,toPort=51820,protocol=UDP,cidrs=0.0.0.0/0') | Out-Null

    # 3. SSH key
    $pem = Join-Path $StateDir 'lightsail.pem'
    $kp  = Invoke-Aws @('lightsail','download-default-key-pair','--region',$Region) | ConvertFrom-Json
    [IO.File]::WriteAllText($pem, $kp.privateKeyBase64)
    Lock-FilePermissions $pem

    # 4. Wait for SSH, then install the VPN on the server (~5 min: Libreswan compiles)
    Wait-Ssh $pem $ip
    $p12pass = New-RandomPassword
    if ($creating) { Write-Log 'Installing VPN on the server (~5 min, first time only)...' 'Yellow' }
    else           { Write-Log 'Fetching this device''s config from the existing server...' 'Yellow' }
    $remote = (Get-RemoteInstallScript).Replace('__P12PASS__', $p12pass)
    Invoke-RemoteScript $pem $ip $remote

    # 5. Pull the client cert + CA down (for this Windows PC)
    $p12 = Join-Path $StateDir 'vpnclient.p12'
    $ca  = Join-Path $StateDir 'vpn-ca.pem'
    Invoke-Scp $pem "${ip}:/tmp/winclient.p12" $p12
    Invoke-Scp $pem "${ip}:/tmp/ca.pem" $ca

    # 5b. On first CREATE only: pull the full device bundle (WireGuard QR codes + the
    #     iPhone/Android/Linux profiles) to the Desktop. A join run skips this so it can
    #     never wipe the phone QR codes the hub laptop already holds.
    if ($creating) {
        Write-Log 'Downloading device configs (WireGuard QR codes + phone/laptop profiles)...'
        if (Test-Path $DevicesDir) { Remove-Item $DevicesDir -Recurse -Force -ErrorAction SilentlyContinue }
        Invoke-Scp $pem "${ip}:/tmp/devices" $DevicesDir -Recurse
        $guide = Join-Path $PSScriptRoot '..\docs\devices-guide.md'
        if (Test-Path $guide) { Copy-Item $guide (Join-Path $DevicesDir 'READ-ME-FIRST.md') -Force }
        # The .p12 import password (for a 2nd Windows laptop / Linux). Secret folder, never committed.
        $ik = Join-Path $DevicesDir 'ikev2'
        if (Test-Path $ik) { Set-Content -Path (Join-Path $ik 'IMPORT-PASSWORD.txt') -Value $p12pass -Encoding ascii }
        Write-Log "Device configs (incl. phone QR codes) saved to: $DevicesDir" 'Green'
    }

    Save-State @{ instance=$Instance; region=$Region; ip=$ip; vpnName=$VpnName
                  pem=$pem; p12=$p12; ca=$ca; devicesDir=$DevicesDir
                  tagKey=$TagKey; tagValue=$TagValue
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
        Write-Host "  This PC is connected. You are now in $($geo.city), United Kingdom (IP $($geo.ip))." -ForegroundColor Green
    } elseif ($geo) {
        Write-Host "  Connected, but your IP shows $($geo.country) (expected GB). See docs\troubleshooting.md." -ForegroundColor Yellow
    } else {
        Write-Host '  Connected. (Could not auto-verify location - check https://ifconfig.me in a browser.)' -ForegroundColor Yellow
    }
    Write-Host ''
    if ($creating) {
        Write-Host "  OTHER DEVICES (phones, laptops, Linux): open this folder ->" -ForegroundColor Cyan
        Write-Host "    $DevicesDir" -ForegroundColor White
        Write-Host "  Open READ-ME-FIRST.md there. Quick version:" -ForegroundColor Cyan
        Write-Host "    - Phone: open wireguard\device-1.png and scan it with the WireGuard app." -ForegroundColor Gray
        Write-Host "    - iPhone (no app): AirDrop/email ikev2\vpnclient.mobileconfig, tap to install." -ForegroundColor Gray
        Write-Host "    - Another Windows laptop: just run connect.bat there - it auto-joins this server." -ForegroundColor Gray
    }
    Write-Host '  When you are done on ALL devices, run destroy.bat to stop billing.' -ForegroundColor Green
    Write-Host ''
    Write-Log 'CONNECT complete.' 'Cyan'
}
catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'If a half-created instance is left behind, run destroy.bat to clean up and stop billing.' -ForegroundColor Yellow
    exit 1
}
