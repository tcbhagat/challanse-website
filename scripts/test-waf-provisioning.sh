#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_CONFIG="$(mktemp -d)"
trap 'rm -rf "$TEST_CONFIG"' EXIT
export XDG_CONFIG_HOME="$TEST_CONFIG"
source "$ROOT/scripts/go-live.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

STATE="$TEST_CONFIG/waf-enabled"
CALLS="$TEST_CONFIG/calls"
touch "$CALLS"
CLOUDFLARE_ACCOUNT_ID="test-account"
ZONE_ID="test-zone"

save_state() { :; }
gh() {
  [[ "$*" == "variable set CLOUDFLARE_FREE_WAF_ENABLED --repo $REPO --env production --body true" ]] || fail "unexpected GitHub variable update: $*"
}
cf() {
  local method="$1" path="$2"
  case "$method $path" in
    "GET /accounts/test-account/rulesets?per_page=100")
      printf '{"success":true,"result":[{"id":"free-managed-id","name":"Cloudflare Free Managed Ruleset"}]}'
      ;;
    "GET /zones/test-zone/rulesets")
      if [[ -e "$STATE" ]]; then
        printf '{"success":true,"result":[{"id":"entrypoint-id","kind":"zone","phase":"http_request_firewall_managed"}]}'
      else
        printf '{"success":true,"result":[]}'
      fi
      ;;
    "GET /zones/test-zone/rulesets/entrypoint-id")
      printf '{"success":true,"result":{"rules":[{"id":"execute-id","action":"execute","enabled":true,"expression":"true","action_parameters":{"id":"free-managed-id"}}]}}'
      ;;
    "POST /zones/test-zone/rulesets")
      [[ "$3" == *'"phase":"http_request_firewall_managed"'* ]] || fail "WAF phase changed"
      [[ "$3" == *'"id":"free-managed-id"'* ]] || fail "Free Managed Ruleset was not selected"
      touch "$STATE"
      printf '%s\n' "POST" >> "$CALLS"
      printf '{"success":true,"result":{"id":"entrypoint-id","rules":[{"id":"execute-id","description":"ChallanSe Cloudflare Free Managed Ruleset"}]}}'
      ;;
    *) fail "unexpected Cloudflare call: $method $path" ;;
  esac
}

ensure_free_managed_waf >/dev/null
ensure_free_managed_waf >/dev/null
assert_free_managed_waf
[[ "$(wc -l < "$CALLS")" == "1" ]] || fail "idempotent provisioning created duplicate WAF rules"

printf 'Managed WAF provisioning checks passed.\n'
