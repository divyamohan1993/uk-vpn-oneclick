# destroy.ps1 - tear everything down: Windows VPN connection, certs, Lightsail
# instance, and local secrets. Safe to run anytime (cleans partial setups too).
#Requires -Version 5.1
[CmdletBinding()]
param()
# Teardown is best-effort cleanup; native-tool stderr must not abort it.
# Invoke-Aws still throws on real AWS failures (caught below).
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

# Defaults are used ONLY when there's no state.json (fresh clone / wiped state).
# The real source of truth for WHAT to delete is the ownership tag, not these names.
$DefaultRegion   = 'eu-west-2'
$DefaultInstance = 'uk-vpn-oneclick'
$DefaultVpnName  = 'UK VPN (one-click)'

$state    = Load-State
$Region   = if ($state -and $state.region)   { $state.region }   else { $DefaultRegion }
$Instance = if ($state -and $state.instance) { $state.instance } else { $DefaultInstance }
$VpnName  = if ($state -and $state.vpnName)  { $state.vpnName }  else { $DefaultVpnName }

try {
    Write-Log '=== UK VPN one-click: DESTROY ===' 'Cyan'
    Assert-Admin

    # 1. Disconnect + remove the Windows VPN connection(s). Remove-OwnVpns clears every
    #    entry this tool recorded creating on this device (only its own); the named
    #    removal is a fallback for a pre-tracking entry. Runs before the state wipe (4).
    rasdial $VpnName /disconnect 2>$null | Out-Null
    Remove-OwnVpns
    Get-VpnConnection -AllUserConnection -Name $VpnName -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-VpnConnection -Name $VpnName -AllUserConnection -Force
        Write-Log "Removed Windows VPN connection '$VpnName'"
    }

    # 2. Remove the imported certificates (by subject; best-effort)
    Get-ChildItem Cert:\LocalMachine\My   -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=device-\d+|CN=vpnclient' } |
        ForEach-Object { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue; Write-Log 'Removed client certificate' }
    Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=IKEv2 VPN CA' } |
        ForEach-Object { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue; Write-Log 'Removed VPN CA certificate' }

    # 3. Delete ONLY the Lightsail instances THIS TOOL created (tag-gated).
    #    Deletion is driven by the ownership tag, never by name alone, so anything
    #    not carrying our tag - including a same-named instance you made by hand -
    #    is left strictly untouched.
    $ours = @(Get-OurInstances $Region)
    if ($ours.Count -gt 0) {
        foreach ($i in $ours) {
            Invoke-Aws @('lightsail','delete-instance','--instance-name',$i.name,'--region',$Region) | Out-Null
            Write-Log "Deleted Lightsail instance '$($i.name)' (tagged $TagKey=$TagValue)" 'Green'
        }
    } else {
        # Nothing of ours here. If a same-named instance exists but is NOT tagged
        # ours, refuse to delete it and hand over the exact manual command instead.
        $other = $null
        try { $other = (Invoke-Aws @('lightsail','get-instance','--instance-name',$Instance,'--region',$Region,'--output','json') | ConvertFrom-Json).instance } catch { }
        if ($other) {
            Write-Log "Instance '$Instance' exists but is NOT tagged $TagKey=$TagValue - NOT deleting it (this tool didn't create it)." 'Yellow'
            Write-Host "  If you really want it gone, delete it yourself:" -ForegroundColor Yellow
            Write-Host "    aws lightsail delete-instance --instance-name $Instance --region $Region" -ForegroundColor White
        } else {
            Write-Log 'No tool-created Lightsail instances found (nothing to delete).'
        }
    }

    # 4. Wipe local secrets (keys, certs, state)
    if (Test-Path $StateDir) {
        Get-ChildItem $StateDir -Exclude 'log.txt' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log 'Wiped local keys/certs/state.'
    }

    # 4b. Wipe the device bundle on the Desktop (WireGuard keys + profiles are secrets)
    if (Test-Path $DevicesDir) {
        Remove-Item $DevicesDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed device configs folder ($DevicesDir)."
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
