# teardown-janitor.ps1 - remove EVERYTHING setup-janitor.ps1 created. Idempotent.
# Needs the same admin-ish AWS creds as setup. After this, nothing janitor-related
# remains (and nothing it created ever cost anything).
#Requires -Version 5.1
[CmdletBinding()]
param([string]$Region = 'eu-west-2')
$ErrorActionPreference = 'Continue'   # best-effort cleanup; keep going on each step
. (Join-Path $PSScriptRoot 'common.ps1')

$RoleName = 'uk-vpn-janitor-role'
$FnName   = 'uk-vpn-janitor'
$RuleName = 'uk-vpn-janitor-schedule'
$LogGroup = "/aws/lambda/$FnName"
$BudgetNm = 'uk-vpn-cost-tripwire'

function Try-Aws { param([string[]]$Args) try { Invoke-Aws $Args | Out-Null; $true } catch { $false } }

Write-Log '=== uk-vpn janitor: TEARDOWN ===' 'Cyan'
$acct = $null
try { $acct = (Invoke-Aws @('sts','get-caller-identity','--output','json') | ConvertFrom-Json).Account } catch { }

# EventBridge target + rule first (so nothing fires mid-teardown).
if (Try-Aws @('events','remove-targets','--rule',$RuleName,'--region',$Region,'--ids','1')) { Write-Log 'Removed schedule target' }
if (Try-Aws @('events','delete-rule','--name',$RuleName,'--region',$Region))                { Write-Log 'Deleted schedule rule' }

# Lambda (its resource policy goes with it).
if (Try-Aws @('lambda','delete-function','--function-name',$FnName,'--region',$Region)) { Write-Log 'Deleted Lambda' }

# Log group.
if (Try-Aws @('logs','delete-log-group','--log-group-name',$LogGroup,'--region',$Region)) { Write-Log 'Deleted log group' }

# IAM inline policy then role.
if (Try-Aws @('iam','delete-role-policy','--role-name',$RoleName,'--policy-name','uk-vpn-janitor-policy')) { Write-Log 'Deleted role policy' }
if (Try-Aws @('iam','delete-role','--role-name',$RoleName)) { Write-Log 'Deleted IAM role' }

# Budget tripwire (global).
if ($acct -and (Try-Aws @('budgets','delete-budget','--account-id',$acct,'--budget-name',$BudgetNm))) { Write-Log 'Deleted budget tripwire' }

Write-Host ''
Write-Host '  Janitor fully removed. Ephemeral VPS will no longer auto-delete - use destroy.bat.' -ForegroundColor Green
Write-Host ''
Write-Log 'TEARDOWN complete.' 'Cyan'
