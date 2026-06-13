# add-windows-device.ps1 - put THIS extra Windows laptop on the already-running UK VPN.
# Self-contained (no AWS needed). Run via add-windows-device.bat (it self-elevates).
# Requires the 'uk-vpn-devices' folder (from connect.bat) on this PC's Desktop.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$VpnName = 'UK VPN (one-click)'
$dev = Join-Path ([Environment]::GetFolderPath('Desktop')) 'uk-vpn-devices'

try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Run add-windows-device.bat (it self-elevates), not the .ps1 directly.' }
    if (-not (Test-Path $dev)) { throw "Copy the 'uk-vpn-devices' folder onto this PC's Desktop first (not found at $dev)." }

    $ik  = Join-Path $dev 'ikev2'
    # Every device uses its OWN identity (device-1..10), exactly like the WireGuard QR
    # codes, so two devices never knock each other offline. The laptop that created the
    # server is device-1; pick a number not used by any other device.
    Write-Host ''
    Write-Host '  Pick a device number for THIS laptop (1-10) that no other device is using' -ForegroundColor Yellow
    Write-Host '  (the laptop that set up the server is device-1).' -ForegroundColor Yellow
    do { $ans = Read-Host '  Device number for THIS laptop (1-10)' }
    until (($ans -as [int]) -and [int]$ans -ge 1 -and [int]$ans -le 10)
    $num = [int]$ans
    $p12 = Join-Path $ik "device-$num.p12"
    $ca  = Join-Path $ik 'ca.pem'
    $ip  = (Get-Content (Join-Path $dev 'server-ip.txt') -Raw).Trim()
    $pw  = (Get-Content (Join-Path $ik 'IMPORT-PASSWORD.txt') -Raw).Trim()
    foreach ($f in $p12, $ca) { if (-not (Test-Path $f)) { throw "Missing $f (need device-$num.p12 in the bundle - is the 'uk-vpn-devices' folder current?)." } }
    Write-Host "  Using IKEv2 identity device-$num." -ForegroundColor Cyan

    Write-Host "Setting up '$VpnName' -> server $ip ..." -ForegroundColor Cyan

    # Clear any stale certs, then import this server's CA + client cert.
    Get-ChildItem Cert:\LocalMachine\My   -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=device-\d+|CN=vpnclient' } | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=IKEv2 VPN CA' } | Remove-Item -Force -ErrorAction SilentlyContinue
    Import-Certificate -FilePath $ca -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-PfxCertificate -FilePath $p12 -CertStoreLocation Cert:\LocalMachine\My `
        -Password (ConvertTo-SecureString $pw -AsPlainText -Force) | Out-Null

    Get-VpnConnection -AllUserConnection -Name $VpnName -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-VpnConnection -Name $VpnName -AllUserConnection -Force }
    Add-VpnConnection -Name $VpnName -ServerAddress $ip -TunnelType IKEv2 `
        -AuthenticationMethod MachineCertificate -EncryptionLevel Required `
        -AllUserConnection -RememberCredential -Force
    Set-VpnConnectionIPsecConfiguration -ConnectionName $VpnName `
        -AuthenticationTransformConstants GCMAES128 -CipherTransformConstants GCMAES128 `
        -EncryptionMethod AES256 -IntegrityCheckMethod SHA256 `
        -PfsGroup None -DHGroup Group14 -AllUserConnection -Force

    $ErrorActionPreference = 'Continue'
    rasdial $VpnName | Out-Host
    $ErrorActionPreference = 'Stop'

    Write-Host "`n  Done. This laptop is on the UK VPN." -ForegroundColor Green
    Write-Host "  Connect/disconnect anytime from Settings > Network > VPN > '$VpnName'." -ForegroundColor Green
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
