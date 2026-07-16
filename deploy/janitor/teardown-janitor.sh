#!/usr/bin/env bash
# teardown-janitor.sh - remove everything setup-janitor.sh created. Idempotent, best-effort.
# Run in AWS CloudShell (no keys) or any Linux with admin creds.
#   bash deploy/janitor/teardown-janitor.sh
set -uo pipefail

REGION="${REGION:-eu-west-2}"
ROLE=uk-vpn-janitor-role
FN=uk-vpn-janitor
RULE=uk-vpn-janitor-schedule
LOGGRP="/aws/lambda/$FN"
BUDGET=uk-vpn-cost-tripwire

ACCT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
echo "== janitor teardown, region $REGION =="

aws events remove-targets --rule "$RULE" --region "$REGION" --ids 1 >/dev/null 2>&1 && echo "  removed schedule target" || true
aws events delete-rule --name "$RULE" --region "$REGION"            >/dev/null 2>&1 && echo "  deleted schedule rule"  || true
aws lambda delete-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1 && echo "  deleted lambda"         || true
aws logs delete-log-group --log-group-name "$LOGGRP" --region "$REGION" >/dev/null 2>&1 && echo "  deleted log group"  || true
aws iam delete-role-policy --role-name "$ROLE" --policy-name uk-vpn-janitor-policy >/dev/null 2>&1 && echo "  deleted role policy" || true
aws iam delete-role --role-name "$ROLE"                             >/dev/null 2>&1 && echo "  deleted role"           || true
[ -n "$ACCT" ] && aws budgets delete-budget --account-id "$ACCT" --budget-name "$BUDGET" >/dev/null 2>&1 && echo "  deleted budget tripwire" || true

echo "== done. Ephemeral boxes will no longer auto-delete - use destroy.bat when finished. =="
