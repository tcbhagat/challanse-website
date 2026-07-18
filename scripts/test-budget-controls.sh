#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_CONFIG="$(mktemp -d)"
trap 'rm -rf "$TEST_CONFIG"' EXIT
export XDG_CONFIG_HOME="$TEST_CONFIG"
source "$ROOT/scripts/go-live.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export AWS_PRODUCTION_MONTHLY_BUDGET_USD=350
export AWS_STAGING_MONTHLY_BUDGET_USD=225
export AWS_BUDGET_EMAIL=primary@example.com
export AWS_SECONDARY_BUDGET_EMAIL=secondary@example.com
validate_aws_budget_inputs

if (AWS_PRODUCTION_MONTHLY_BUDGET_USD=351 validate_aws_budget_inputs) >/dev/null 2>&1; then
  fail "production budget above USD 350 was accepted"
fi
if (AWS_STAGING_MONTHLY_BUDGET_USD=226 validate_aws_budget_inputs) >/dev/null 2>&1; then
  fail "staging budget above USD 225 was accepted"
fi
if (AWS_SECONDARY_BUDGET_EMAIL=primary@example.com validate_aws_budget_inputs) >/dev/null 2>&1; then
  fail "one operator address was accepted twice"
fi
if (AWS_SECONDARY_BUDGET_EMAIL=invalid validate_aws_budget_inputs) >/dev/null 2>&1; then
  fail "invalid secondary operator email was accepted"
fi

grep -Fq 'CostCenter  = "challanse-pilot"' "$ROOT/infra/terraform/modules/enrichment/main.tf"
grep -Fq 'ClientScope = "shared-pilot"' "$ROOT/infra/terraform/modules/enrichment/main.tf"
for threshold in 50 70 90 100; do
  grep -Eq "threshold[[:space:]]+=[[:space:]]+$threshold" "$ROOT/infra/terraform/modules/enrichment/main.tf" || fail "missing AWS Budget threshold $threshold"
done
[[ "$(grep -Fc 'subscriber_email_addresses = [var.budget_email, var.secondary_budget_email]' "$ROOT/infra/terraform/modules/enrichment/main.tf")" -eq 4 ]] || fail "all four budget alerts must notify two operators"

printf 'Pilot budget controls passed.\n'
