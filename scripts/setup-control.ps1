# setup-control.ps1 - deploy the VPN web control panel (ONE-TIME, admin creds).
#
# Creates: DynamoDB table, an IAM role, the control Lambda + public Function URL +
# reserved concurrency, 1-day log retention, and the GitHub OIDC role for CI/CD.
# Prints the panel URL at the end. Idempotent. Undo with teardown-control.ps1.
#
#   $env:AWS_PROFILE='admin'
#   ./setup-control.ps1 -Password 'a-strong-passphrase' -AlertEmail you@example.com
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Password,   # the panel access password (hashed, never stored plaintext)
    [string]$Region = 'eu-west-2',             # the Lambda's home region
    [string]$GitHubRepo = 'divyamohan1993/uk-vpn-oneclick'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$Fn='uk-vpn-control'; $Role='uk-vpn-control-role'; $Table='uk-vpn-control'
$GhaRole='uk-vpn-gha-deploy'; $LogGrp="/aws/lambda/$Fn"
$control = Resolve-Path (Join-Path $PSScriptRoot '..\deploy\control\control.py')

# region allow-list (label per region). Shared with the janitor.
$Regions = [ordered]@{
    'eu-west-2'='London, UK'; 'eu-central-1'='Frankfurt, Germany'; 'eu-west-1'='Dublin, Ireland'
    'eu-north-1'='Stockholm, Sweden'; 'us-east-1'='Virginia, US-East'; 'us-west-2'='Oregon, US-West'
    'ca-central-1'='Montreal, Canada'; 'ap-south-1'='Mumbai, India'; 'ap-southeast-1'='Singapore'
    'ap-northeast-1'='Tokyo, Japan'; 'ap-southeast-2'='Sydney, Australia'
}
$RegionsJson  = ($Regions | ConvertTo-Json -Compress)
$RegionListJson = ($Regions.Keys | ForEach-Object { '"' + $_ + '"' }) -join ','

function Aws-Idem { param([string[]]$CmdArgs, [string]$Ok='exists|Conflict|AlreadyExists|in progress')
    try { Invoke-Aws $CmdArgs } catch { if ($_.Exception.Message -match $Ok){Write-Log '  (exists)';return $null}; throw } }

try {
    Write-Log '=== VPN control panel: SETUP ===' 'Cyan'
    if (-not (Get-AwsExe)) { Fail 'AWS CLI not found.' }
    $acct = (Invoke-Aws @('sts','get-caller-identity','--output','json') | ConvertFrom-Json).Account
    Write-Log "Account $acct, region $Region"

    # --- password hashing (PBKDF2-HMAC-SHA256, 600k) matching control.py ---
    if ($Password.Length -lt 12) { Fail 'Use a password of at least 12 chars (it is the whole gate).' }
    $iters = 600000
    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password, $salt, $iters, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $hash = $kdf.GetBytes(32); $kdf.Dispose()
    $toHex = { param($b) -join ($b | ForEach-Object { $_.ToString('x2') }) }
    $saltHex = & $toHex $salt; $hashHex = & $toHex $hash
    $sessBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($sessBytes)
    $sessSecret = & $toHex $sessBytes

    # --- DynamoDB table (on-demand) + TTL on expire_at ---
    Write-Log 'DynamoDB table...'
    Aws-Idem @('dynamodb','create-table','--table-name',$Table,'--region',$Region,
        '--attribute-definitions','AttributeName=pk,AttributeType=S',
        '--key-schema','AttributeName=pk,KeyType=HASH',
        '--billing-mode','PAY_PER_REQUEST') | Out-Null
    Invoke-Aws @('dynamodb','wait','table-exists','--table-name',$Table,'--region',$Region) | Out-Null
    try { Invoke-Aws @('dynamodb','update-time-to-live','--table-name',$Table,'--region',$Region,
        '--time-to-live-specification','Enabled=true,AttributeName=expire_at') | Out-Null } catch {}

    # --- IAM role for the control Lambda ---
    Write-Log 'IAM role...'
    $trust = Join-Path $env:TEMP 'ukctl-trust.json'
    @"
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"$acct"}}}]}
"@ | Set-Content $trust -Encoding ascii
    Aws-Idem @('iam','create-role','--role-name',$Role,'--assume-role-policy-document',"file://$trust") | Out-Null
    $perm = Join-Path $env:TEMP 'ukctl-perm.json'
    @"
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["lightsail:GetInstances","lightsail:GetInstance","lightsail:CreateInstances","lightsail:DeleteInstance","lightsail:PutInstancePublicPorts","lightsail:TagResource"],"Resource":"*"},
 {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DeleteItem"],"Resource":"arn:aws:dynamodb:$($Region):$($acct):table/$Table"},
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}
]}
"@ | Set-Content $perm -Encoding ascii
    Invoke-Aws @('iam','put-role-policy','--role-name',$Role,'--policy-name','uk-vpn-control-policy','--policy-document',"file://$perm") | Out-Null
    $roleArn = (Invoke-Aws @('iam','get-role','--role-name',$Role,'--output','json') | ConvertFrom-Json).Role.Arn

    # --- package control.py + segno (pure-Python) ---
    Write-Log 'Packaging Lambda (control.py + segno)...'
    $build = Join-Path $env:TEMP 'ukctl-build'
    Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $build -Force | Out-Null
    & python -m pip install --quiet --target $build segno 2>&1 | Out-Null
    Copy-Item $control (Join-Path $build 'control.py') -Force
    $zip = Join-Path $env:TEMP 'ukctl.zip'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $build '*') -DestinationPath $zip -Force

    # --- Lambda (create or update). FUNC_URL is filled in after the URL exists. ---
    # Write --environment as a JSON FILE (shorthand Variables={} breaks on commas/= inside
    # REGIONS_JSON). $mkEnv writes the file for a given FUNC_URL and returns file://path.
    $envFile = Join-Path $env:TEMP 'ukctl-env.json'
    $mkEnv = {
        param($furl)
        (@{ Variables = [ordered]@{ TABLE=$Table; PW_SALT=$saltHex; PW_HASH=$hashHex
            SESSION_SECRET=$sessSecret; PBKDF2_ITERS="$iters"; REGIONS_JSON=$RegionsJson
            FUNC_URL=$furl } } | ConvertTo-Json -Depth 6 -Compress) | Set-Content $envFile -Encoding ascii
        "file://$envFile"
    }
    $envArg = & $mkEnv 'https://placeholder'
    $exists = $null; try { $exists = Invoke-Aws @('lambda','get-function','--function-name',$Fn,'--region',$Region,'--output','json') } catch {}
    if ($exists) {
        Write-Log 'Updating Lambda code + config...'
        Invoke-Aws @('lambda','update-function-code','--function-name',$Fn,'--region',$Region,'--zip-file',"fileb://$zip") | Out-Null
        Invoke-Aws @('lambda','wait','function-updated','--function-name',$Fn,'--region',$Region) | Out-Null
    } else {
        Write-Log 'Creating Lambda (retry for role propagation)...'
        $ok=$false; for($i=0;$i -lt 10 -and -not $ok;$i++){ try {
            Invoke-Aws @('lambda','create-function','--function-name',$Fn,'--region',$Region,'--runtime','python3.12',
                '--handler','control.handler','--timeout','30','--memory-size','256','--role',$roleArn,
                '--zip-file',"fileb://$zip",'--environment',$envArg) | Out-Null; $ok=$true
        } catch { if($_.Exception.Message -match 'cannot be assumed|InvalidParameterValue'){Start-Sleep 6}else{throw} } }
        if(-not $ok){ Fail 'Lambda create failed.' }
    }
    # reserved concurrency = the real-time flood cost cap. AWS requires the account to keep
    # >=10 unreserved, so only set it if the account limit allows; otherwise the (already low)
    # account-wide concurrency limit itself bounds a flood.
    try {
        $lim = [int](Invoke-Aws @('lambda','get-account-settings','--region',$Region,'--output','json') | ConvertFrom-Json).AccountLimit.ConcurrentExecutions
        if ($lim -ge 15) {
            Invoke-Aws @('lambda','put-function-concurrency','--function-name',$Fn,'--region',$Region,'--reserved-concurrent-executions','5') | Out-Null
            Write-Log 'Reserved concurrency = 5 (flood cost cap).'
        } else {
            Write-Log "Account concurrency limit is $lim (low) - the account cap itself bounds a flood; skipping reservation." 'Yellow'
        }
    } catch { Write-Log "  (reserved-concurrency skipped: $($_.Exception.Message))" 'Yellow' }
    # 1-day log retention
    Aws-Idem @('logs','create-log-group','--log-group-name',$LogGrp,'--region',$Region) | Out-Null
    Invoke-Aws @('logs','put-retention-policy','--log-group-name',$LogGrp,'--region',$Region,'--retention-in-days','1') | Out-Null

    # --- public front: API Gateway HTTP API (proxy -> Lambda) ---
    # NOT a Lambda Function URL. An AuthType=NONE Function URL is refused on this account
    # (403 at the URL auth layer even with a correct public resource policy), while an
    # IAM-signed request to the same URL returns 200 - i.e. the PUBLIC path is blocked, not
    # the function. API Gateway invokes via lambda:InvokeFunction (works) and delivers the
    # same payload-format-2.0 event, so control.py needs no change.
    Write-Log 'API Gateway HTTP API...'
    $fnArn = "arn:aws:lambda:$($Region):$($acct):function:$Fn"
    $apiId = $null
    try { $apiId = ((Invoke-Aws @('apigatewayv2','get-apis','--region',$Region,'--output','json') | ConvertFrom-Json).Items |
                    Where-Object { $_.Name -eq $Fn } | Select-Object -First 1).ApiId } catch {}
    if (-not $apiId) {
        $apiId = (Invoke-Aws @('apigatewayv2','create-api','--name',$Fn,'--protocol-type','HTTP',
                    '--target',$fnArn,'--region',$Region,'--output','json') | ConvertFrom-Json).ApiId
    }
    Aws-Idem @('lambda','add-permission','--function-name',$Fn,'--region',$Region,'--statement-id','apigw',
        '--action','lambda:InvokeFunction','--principal','apigateway.amazonaws.com',
        '--source-arn',"arn:aws:execute-api:$($Region):$($acct):$apiId/*") | Out-Null
    $furlTrim = "https://$apiId.execute-api.$($Region).amazonaws.com"
    # now that the URL is known, put it into the env (the box beacon needs it)
    $envArg2 = & $mkEnv $furlTrim
    Invoke-Aws @('lambda','wait','function-updated','--function-name',$Fn,'--region',$Region) | Out-Null
    Invoke-Aws @('lambda','update-function-configuration','--function-name',$Fn,'--region',$Region,'--environment',$envArg2) | Out-Null

    # --- GitHub OIDC provider + scoped deploy role (CI/CD, no stored keys) ---
    Write-Log 'GitHub OIDC deploy role...'
    Aws-Idem @('iam','create-open-id-connect-provider','--url','https://token.actions.githubusercontent.com','--client-id-list','sts.amazonaws.com','--thumbprint-list','ffffffffffffffffffffffffffffffffffffffff') | Out-Null
    $ghaTrust = Join-Path $env:TEMP 'ukctl-gha-trust.json'
    @"
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam::$($acct):oidc-provider/token.actions.githubusercontent.com"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com","token.actions.githubusercontent.com:sub":"repo:$($GitHubRepo):ref:refs/heads/main"}}}]}
"@ | Set-Content $ghaTrust -Encoding ascii
    Aws-Idem @('iam','create-role','--role-name',$GhaRole,'--assume-role-policy-document',"file://$ghaTrust") | Out-Null
    try { Invoke-Aws @('iam','update-assume-role-policy','--role-name',$GhaRole,'--policy-document',"file://$ghaTrust") | Out-Null } catch {}
    $ghaPerm = Join-Path $env:TEMP 'ukctl-gha-perm.json'
    @"
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["lambda:UpdateFunctionCode","lambda:UpdateFunctionConfiguration"],"Resource":["arn:aws:lambda:$($Region):$($acct):function:$Fn","arn:aws:lambda:$($Region):$($acct):function:uk-vpn-janitor"]}]}
"@ | Set-Content $ghaPerm -Encoding ascii
    Invoke-Aws @('iam','put-role-policy','--role-name',$GhaRole,'--policy-name','uk-vpn-gha-deploy-policy','--policy-document',"file://$ghaPerm") | Out-Null

    Remove-Item $trust,$perm,$ghaTrust,$ghaPerm -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host "  VPN control panel is LIVE:" -ForegroundColor Green
    Write-Host "    $furlTrim" -ForegroundColor White
    Write-Host "  Open it, enter your password, pick a region, Start. Auto-deletes in ~5h." -ForegroundColor Green
    Write-Host "  GitHub deploy role: arn:aws:iam::$($acct):role/$GhaRole (for the CI/CD workflow)." -ForegroundColor Gray
    Write-Host ''
    Write-Log 'SETUP complete.' 'Cyan'
}
catch {
    Write-Host "control setup FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
