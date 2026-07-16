#!/usr/bin/env bash
# setup-janitor.sh - deploy the uk-vpn-oneclick auto-delete janitor from AWS CloudShell
# (or any Linux with the AWS CLI + admin creds). Run this in CloudShell so NO access key is
# ever created or stored - CloudShell uses your console session and vanishes when closed.
#
#   git clone https://github.com/divyamohan1993/uk-vpn-oneclick
#   cd uk-vpn-oneclick
#   bash deploy/janitor/setup-janitor.sh you@example.com    # email is optional (budget alert)
#
# Idempotent. Undo with teardown-janitor.sh. Cost is 0 within AWS Always-Free.
set -euo pipefail

REGION="${REGION:-eu-west-2}"          # must match connect.ps1's $Region
INTERVAL="${INTERVAL_MINUTES:-15}"
EMAIL="${1:-}"
ROLE=uk-vpn-janitor-role
FN=uk-vpn-janitor
RULE=uk-vpn-janitor-schedule
LOGGRP="/aws/lambda/$FN"
BUDGET=uk-vpn-cost-tripwire

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAN="$DIR/janitor.py"
[ -f "$JAN" ] || { echo "ERROR: janitor.py not found next to this script ($JAN)"; exit 1; }

ACCT=$(aws sts get-caller-identity --query Account --output text)
echo "== janitor setup: account $ACCT, region $REGION, every $INTERVAL min =="

# 1. Execution role (assume-role scoped to this account) + least-privilege inline policy.
aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"lambda.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$ACCT\"}}}]}" \
  --description "uk-vpn-oneclick janitor: delete expired VPN instances" >/dev/null 2>&1 && echo "  role created" || echo "  role exists"
aws iam put-role-policy --role-name "$ROLE" --policy-name uk-vpn-janitor-policy \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lightsail:GetInstances\",\"Resource\":\"*\"},{\"Effect\":\"Allow\",\"Action\":\"lightsail:DeleteInstance\",\"Resource\":\"arn:aws:lightsail:$REGION:$ACCT:Instance/*\"},{\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"}]}"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)
echo "  role: $ROLE_ARN"

# 2. Package + create/update the Lambda (retry while the new role propagates).
TMP=$(mktemp -d); cp "$JAN" "$TMP/janitor.py"; ( cd "$TMP" && zip -q janitor.zip janitor.py )
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  echo "  updating Lambda code..."
  aws lambda update-function-code --function-name "$FN" --region "$REGION" --zip-file "fileb://$TMP/janitor.zip" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --environment "Variables={TARGET_REGION=$REGION}" >/dev/null
else
  echo "  creating Lambda..."
  for i in $(seq 1 10); do
    if aws lambda create-function --function-name "$FN" --region "$REGION" \
        --runtime python3.12 --handler janitor.handler --timeout 60 --memory-size 128 \
        --role "$ROLE_ARN" --zip-file "fileb://$TMP/janitor.zip" \
        --environment "Variables={TARGET_REGION=$REGION}" >/dev/null 2>&1; then break; fi
    echo "    role not propagated yet, waiting 6s..."; sleep 6
  done
fi
FN_ARN=$(aws lambda get-function --function-name "$FN" --region "$REGION" --query Configuration.FunctionArn --output text)

# 3. Log group with 1-day retention (so logs never accumulate any cost).
aws logs create-log-group --log-group-name "$LOGGRP" --region "$REGION" >/dev/null 2>&1 || true
aws logs put-retention-policy --log-group-name "$LOGGRP" --region "$REGION" --retention-in-days 1

# 4. EventBridge scheduled rule -> Lambda (scheduled rules are free).
UNIT=minutes; [ "$INTERVAL" -eq 1 ] && UNIT=minute
RULE_ARN=$(aws events put-rule --name "$RULE" --region "$REGION" \
  --schedule-expression "rate($INTERVAL $UNIT)" --description "uk-vpn-oneclick janitor cadence" \
  --query RuleArn --output text)
aws lambda add-permission --function-name "$FN" --region "$REGION" \
  --statement-id uk-vpn-janitor-eventbridge --action lambda:InvokeFunction \
  --principal events.amazonaws.com --source-arn "$RULE_ARN" >/dev/null 2>&1 || echo "  invoke-permission exists"
aws events put-targets --rule "$RULE" --region "$REGION" --targets "Id=1,Arn=$FN_ARN" >/dev/null

# 5. Smoke test: run it once now.
echo "  smoke test:"; aws lambda invoke --function-name "$FN" --region "$REGION" /tmp/jan-out.json >/dev/null && sed 's/^/    /' /tmp/jan-out.json && echo

# 6. Optional 0.01 USD budget tripwire (global). Skipped without an email arg.
if [ -n "$EMAIL" ]; then
  aws budgets create-budget --account-id "$ACCT" \
    --budget "{\"BudgetName\":\"$BUDGET\",\"BudgetLimit\":{\"Amount\":\"0.01\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}" \
    --notifications-with-subscribers "[{\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":0.0,\"ThresholdType\":\"ABSOLUTE_VALUE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$EMAIL\"}]}]" \
    >/dev/null 2>&1 && echo "  budget tripwire -> $EMAIL" || echo "  budget exists or failed (non-fatal)"
else
  echo "  (no email arg -> skipped the 0.01 USD budget tripwire; recommended)"
fi

echo "== DONE. Janitor live: deletes uk-vpn-oneclick boxes past expires-at (or >24h) every $INTERVAL min. Cost 0 within AWS Always-Free. =="
