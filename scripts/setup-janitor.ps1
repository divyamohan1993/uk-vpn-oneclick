# setup-janitor.ps1 - deploy the uk-vpn-oneclick auto-delete janitor (ONE-TIME).
#
# Creates a tiny scheduled Lambda that deletes ephemeral VPN instances past their
# expires-at tag (or older than the 24h hard cap). Cost is zero within AWS Always-Free
# (Lambda 1M req + 400k GB-s, EventBridge 14M, Logs 5GB - all perpetual). This script
# also sets 1-day log retention and (optionally) a $0.01 budget tripwire, so a surprise
# charge is impossible-to-miss.
#
# REQUIRES admin-ish AWS creds ONCE (iam:CreateRole, lambda:CreateFunction,
# events:PutRule, budgets:CreateBudget). Your laptops NEVER get these - they only need
# Lightsail. Idempotent: safe to re-run. Undo with teardown-janitor.ps1.
#
#   aws configure            # an admin/root profile, just for this one run
#   ./setup-janitor.ps1 -AlertEmail you@example.com
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Region = 'eu-west-2',           # where the VPN instances live
    [int]$IntervalMinutes = 15,
    [string]$AlertEmail = ''                  # $0.01 budget tripwire; blank = skip it
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$RoleName = 'uk-vpn-janitor-role'
$FnName   = 'uk-vpn-janitor'
$RuleName = 'uk-vpn-janitor-schedule'
$LogGroup = "/aws/lambda/$FnName"
$BudgetNm = 'uk-vpn-cost-tripwire'
$janitor  = Resolve-Path (Join-Path $PSScriptRoot '..\deploy\janitor\janitor.py')

# Run an aws call that is allowed to "already exists"; swallow only that.
# NOTE: do NOT name the param $Args - that shadows PowerShell's automatic $args and
# binds empty. Use $CmdArgs.
function Aws-Idempotent {
    param([string[]]$CmdArgs, [string]$OkIfMatches = 'already exists|exists|ResourceConflict|EntityAlreadyExists|Conflict')
    try { return Invoke-Aws $CmdArgs }
    catch {
        if ($_.Exception.Message -match $OkIfMatches) { Write-Log "  (exists, skipping)"; return $null }
        throw
    }
}

try {
    Write-Log '=== uk-vpn janitor: SETUP ===' 'Cyan'
    if (-not (Get-AwsExe)) { Fail 'AWS CLI not found.' }
    $acct = (Invoke-Aws @('sts','get-caller-identity','--output','json') | ConvertFrom-Json).Account
    Write-Log "Account $acct, region $Region"

    # Regions the janitor sweeps - must cover every region the control panel can use.
    $Regions = 'eu-west-2','eu-central-1','eu-west-1','eu-north-1','us-east-1','us-west-2',
               'ca-central-1','ap-south-1','ap-southeast-1','ap-northeast-1','ap-southeast-2'
    $RegionCsv = $Regions -join ','
    $RegionListJson = ($Regions | ForEach-Object { '"' + $_ + '"' }) -join ','
    # --environment must be a JSON FILE: the shorthand Variables={} breaks on the commas
    # in the region list.
    $janEnvFile = Join-Path $env:TEMP 'ukjanitor-env.json'
    (@{ Variables = @{ TARGET_REGIONS = $RegionCsv } } | ConvertTo-Json -Compress) | Set-Content $janEnvFile -Encoding ascii

    # 1. IAM role the Lambda runs as (delete-only on Lightsail + write its own logs).
    $trust = Join-Path $env:TEMP 'ukjanitor-trust.json'
    # Scope the assume-role to THIS account (confused-deputy guard).
    @"
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"$acct"}}}]}
"@ | Set-Content $trust -Encoding ascii
    Write-Log 'Creating IAM role...'
    Aws-Idempotent @('iam','create-role','--role-name',$RoleName,
        '--assume-role-policy-document',"file://$trust",
        '--description','uk-vpn-oneclick janitor: delete expired VPN instances') | Out-Null

    $perm = Join-Path $env:TEMP 'ukjanitor-perm.json'
    # Least privilege: GetInstances is a list op (must be Resource *), but the destructive
    # DeleteInstance is scoped to Lightsail instances in THIS region+account, so a code
    # regression can never reach anything else. Logs are the function's own.
    @"
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"lightsail:GetInstances","Resource":"*"},
 {"Effect":"Allow","Action":"lightsail:DeleteInstance","Resource":"*","Condition":{"StringEquals":{"aws:RequestedRegion":[$RegionListJson]}}},
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}
]}
"@ | Set-Content $perm -Encoding ascii
    Invoke-Aws @('iam','put-role-policy','--role-name',$RoleName,
        '--policy-name','uk-vpn-janitor-policy','--policy-document',"file://$perm") | Out-Null
    $roleArn = (Invoke-Aws @('iam','get-role','--role-name',$RoleName,'--output','json') | ConvertFrom-Json).Role.Arn
    Write-Log "Role: $roleArn"

    # 2. Package + create/update the Lambda.
    $zip = Join-Path $env:TEMP 'uk-vpn-janitor.zip'
    Remove-Item $zip -ErrorAction SilentlyContinue
    Compress-Archive -Path $janitor -DestinationPath $zip -Force
    $existing = $null
    try { $existing = Invoke-Aws @('lambda','get-function','--function-name',$FnName,'--region',$Region,'--output','json') } catch { }
    if ($existing) {
        Write-Log 'Updating Lambda code...'
        Invoke-Aws @('lambda','update-function-code','--function-name',$FnName,'--region',$Region,
            '--zip-file',"fileb://$zip") | Out-Null
        Invoke-Aws @('lambda','wait','function-updated','--function-name',$FnName,'--region',$Region) | Out-Null
        Invoke-Aws @('lambda','update-function-configuration','--function-name',$FnName,'--region',$Region,
            '--environment',"file://$janEnvFile") | Out-Null
    } else {
        Write-Log 'Creating Lambda (retrying for IAM role propagation)...'
        $created = $false
        for ($i=0; $i -lt 10 -and -not $created; $i++) {
            try {
                Invoke-Aws @('lambda','create-function','--function-name',$FnName,'--region',$Region,
                    '--runtime','python3.12','--handler','janitor.handler','--timeout','120',
                    '--memory-size','128','--role',$roleArn,'--zip-file',"fileb://$zip",
                    '--environment',"file://$janEnvFile") | Out-Null
                $created = $true
            } catch {
                if ($_.Exception.Message -match 'cannot be assumed|InvalidParameterValueException') {
                    Write-Log '  role not propagated yet, waiting 6s...'; Start-Sleep 6
                } else { throw }
            }
        }
        if (-not $created) { Fail 'Lambda create failed after role-propagation retries.' }
    }
    $fnArn = (Invoke-Aws @('lambda','get-function','--function-name',$FnName,'--region',$Region,'--output','json') | ConvertFrom-Json).Configuration.FunctionArn

    # 3. Log group with 1-DAY retention so logs never accumulate cost.
    Aws-Idempotent @('logs','create-log-group','--log-group-name',$LogGroup,'--region',$Region) | Out-Null
    Invoke-Aws @('logs','put-retention-policy','--log-group-name',$LogGroup,'--region',$Region,'--retention-in-days','1') | Out-Null

    # 4. EventBridge scheduled rule -> Lambda (scheduled rules are free).
    Write-Log "Scheduling every $IntervalMinutes min..."
    $unit = if ($IntervalMinutes -eq 1) { 'minute' } else { 'minutes' }   # rate(1 minute) is singular
    $ruleArn = (Invoke-Aws @('events','put-rule','--name',$RuleName,'--region',$Region,
        '--schedule-expression',"rate($IntervalMinutes $unit)",
        '--description','uk-vpn-oneclick janitor cadence','--output','json') | ConvertFrom-Json).RuleArn
    Aws-Idempotent @('lambda','add-permission','--function-name',$FnName,'--region',$Region,
        '--statement-id','uk-vpn-janitor-eventbridge','--action','lambda:InvokeFunction',
        '--principal','events.amazonaws.com','--source-arn',$ruleArn) | Out-Null
    Invoke-Aws @('events','put-targets','--rule',$RuleName,'--region',$Region,
        '--targets',"Id=1,Arn=$fnArn") | Out-Null

    # 5. Smoke test: invoke once now and show the result.
    Write-Log 'Invoking janitor once as a smoke test...'
    $out = Join-Path $env:TEMP 'ukjanitor-out.json'
    Invoke-Aws @('lambda','invoke','--function-name',$FnName,'--region',$Region,$out) | Out-Null
    Write-Log ("  janitor said: " + ((Get-Content $out -Raw).Trim()))

    # 6. Optional $0.01 budget tripwire (global/us-east-1). Skipped without an email.
    if ($AlertEmail) {
        Write-Log "Creating `$0.01 budget alert -> $AlertEmail ..."
        $bjson = Join-Path $env:TEMP 'ukjanitor-budget.json'
        @"
{"BudgetName":"$BudgetNm","BudgetLimit":{"Amount":"0.01","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}
"@ | Set-Content $bjson -Encoding ascii
        $njson = Join-Path $env:TEMP 'ukjanitor-notify.json'
        @"
[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":0.0,"ThresholdType":"ABSOLUTE_VALUE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"$AlertEmail"}]}]
"@ | Set-Content $njson -Encoding ascii
        Aws-Idempotent @('budgets','create-budget','--account-id',$acct,
            '--budget',"file://$bjson",'--notifications-with-subscribers',"file://$njson") | Out-Null
    } else {
        Write-Log 'No -AlertEmail given; SKIPPING the $0.01 budget tripwire (recommended: add one).' 'Yellow'
    }

    Remove-Item $trust,$perm -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  Janitor live. Ephemeral VPN instances now self-delete within ~15 min of expiry.' -ForegroundColor Green
    Write-Host '  Cost: $0 within AWS Always-Free. Undo anytime with teardown-janitor.ps1.' -ForegroundColor Green
    Write-Host ''
    Write-Log 'SETUP complete.' 'Cyan'
}
catch {
    Write-Host ''
    Write-Host "Janitor setup FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'If this was AccessDenied, re-run with admin/root AWS creds (one-time).' -ForegroundColor Yellow
    exit 1
}
