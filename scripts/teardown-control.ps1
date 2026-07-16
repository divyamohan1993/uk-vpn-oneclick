# teardown-control.ps1 - remove everything setup-control.ps1 created. Idempotent, best-effort.
# Deletes any running box first, then the Lambda/URL/table/role/logs. Keeps the account-wide
# GitHub OIDC provider (may be shared). Same admin creds as setup.
#Requires -Version 5.1
[CmdletBinding()]
param([string]$Region = 'eu-west-2')
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$Fn='uk-vpn-control'; $Role='uk-vpn-control-role'; $Table='uk-vpn-control'; $GhaRole='uk-vpn-gha-deploy'
$LogGrp="/aws/lambda/$Fn"
function T { param([string[]]$CmdArgs) try { Invoke-Aws $CmdArgs | Out-Null; $true } catch { $false } }

Write-Log '=== VPN control panel: TEARDOWN ===' 'Cyan'

# best-effort: delete a running box (scan the allow-list regions)
$regions='eu-west-2','eu-central-1','eu-west-1','eu-north-1','us-east-1','us-west-2','ca-central-1','ap-south-1','ap-southeast-1','ap-northeast-1','ap-southeast-2'
foreach ($r in $regions) {
    if (T @('lightsail','delete-instance','--instance-name','uk-vpn-web','--region',$r)) { Write-Log "Deleted box in $r" }
}
if (T @('lambda','delete-function-url-config','--function-name',$Fn,'--region',$Region)) { Write-Log 'Deleted Function URL' }
if (T @('lambda','delete-function','--function-name',$Fn,'--region',$Region))            { Write-Log 'Deleted Lambda' }
if (T @('dynamodb','delete-table','--table-name',$Table,'--region',$Region))             { Write-Log 'Deleted DynamoDB table' }
if (T @('logs','delete-log-group','--log-group-name',$LogGrp,'--region',$Region))        { Write-Log 'Deleted log group' }
if (T @('iam','delete-role-policy','--role-name',$Role,'--policy-name','uk-vpn-control-policy')) { Write-Log 'Deleted control role policy' }
if (T @('iam','delete-role','--role-name',$Role))                                        { Write-Log 'Deleted control role' }
if (T @('iam','delete-role-policy','--role-name',$GhaRole,'--policy-name','uk-vpn-gha-deploy-policy')) { Write-Log 'Deleted gha role policy' }
if (T @('iam','delete-role','--role-name',$GhaRole))                                     { Write-Log 'Deleted gha role' }

Write-Host ''
Write-Host '  Control panel removed. (GitHub OIDC provider kept - shared/account-wide.)' -ForegroundColor Green
Write-Log 'TEARDOWN complete.' 'Cyan'
