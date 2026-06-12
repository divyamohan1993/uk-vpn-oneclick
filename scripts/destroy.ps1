# destroy.ps1 - tear everything down: Windows VPN connection, certs, Lightsail
# instance, and local secrets. Safe to run anytime (cleans partial setups too).
#Requires -Version 5.1
[CmdletBinding()]
param()
# Teardown is best-effort cleanup; native-tool stderr must not abort it.
# Invoke-Aws still throws on real AWS failures (caught below).
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$Region   = 'eu-west-2'
$Instance = 'uk-vpn-oneclick'
$VpnName  = 'UK VPN (one-click)'

try {
    Write-Log '=== UK VPN one-click: DESTROY ===' 'Cyan'
    Assert-Admin

    # 1. Disconnect + remove the Windows VPN connection
    rasdial $VpnName /disconnect 2>$null | Out-Null
    Get-VpnConnection -AllUserConnection -Name $VpnName -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-VpnConnection -Name $VpnName -AllUserConnection -Force
        Write-Log "Removed Windows VPN connection '$VpnName'"
    }

    # 2. Remove the imported certificates (by subject; best-effort)
    Get-ChildItem Cert:\LocalMachine\My   -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=vpnclient' } |
        ForEach-Object { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue; Write-Log 'Removed client certificate' }
    Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=IKEv2 VPN CA' } |
        ForEach-Object { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue; Write-Log 'Removed VPN CA certificate' }

    # 3. Delete the Lightsail instance (stops all billing)
    if (Test-InstanceExists $Instance $Region) {
        Invoke-Aws @('lightsail','delete-instance','--instance-name',$Instance,'--region',$Region) | Out-Null
        Write-Log "Deleted Lightsail instance '$Instance'" 'Green'
    } else {
        Write-Log "No Lightsail instance '$Instance' found (nothing to delete)."
    }

    # 4. Wipe local secrets (keys, certs, state)
    if (Test-Path $StateDir) {
        Get-ChildItem $StateDir -Exclude 'log.txt' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log 'Wiped local keys/certs/state.'
    }

    Write-Host ''
    Write-Host '  Torn down. Nothing is running, ongoing cost is now zero.' -ForegroundColor Green
    Write-Host ''
    Write-Log 'DESTROY complete.' 'Cyan'
}
catch {
    Write-Host ''
    Write-Host "Teardown hit an error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Check manually:  aws lightsail get-instances --region $Region" -ForegroundColor Yellow
    exit 1
}
