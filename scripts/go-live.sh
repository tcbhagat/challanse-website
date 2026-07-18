#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="tcbhagat/challanse"
WORKFLOW="ci-pages.yml"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/challanse"
STATE_FILE="$STATE_DIR/production.env"
DNS_BASELINE="$STATE_DIR/dns-baseline.json"
DNS_ONBOARDING_BASELINE="$STATE_DIR/dns-onboarding.json"
CF_API="https://api.cloudflare.com/client/v4"
EXPECTED_DEBUG_KEYSTORE_PATH="apps/mobile/android/app/debug.keystore"
EXPECTED_DEBUG_KEYSTORE_SHA256="221e0a3106aa4c3ccc154e0a418b55020b3f9ea6e84f92e8749cd9e2f39f5e58"
EXPECTED_DEBUG_CERT_SHA256="FAC61745DC0903786FB9EDE62A962B399F7348F0BB6F899B8332667591033B9C"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"
cd "$ROOT"

load_state() {
  set -a
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  set +a
}
save_state() {
  local name="$1" value="$2" temporary
  temporary="$(mktemp "$STATE_DIR/state.XXXXXX")"
  grep -v "^${name}=" "$STATE_FILE" > "$temporary" || true
  printf '%s=%q\n' "$name" "$value" >> "$temporary"
  mv "$temporary" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  export "$name=$value"
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
confirm() { local answer; read -r -p "$1 Type YES: " answer; [[ "$answer" == "YES" ]] || die "Cancelled."; }
prompt_secret() {
  local name="$1" label="$2" value
  value="${!name:-}"
  if [[ -z "$value" ]]; then read -r -s -p "$label: " value; printf '\n'; fi
  [[ -n "$value" ]] || die "$label is required."
  export "$name=$value"
}
prompt_value() {
  local name="$1" label="$2" value
  value="${!name:-}"
  if [[ -z "$value" ]]; then read -r -p "$label: " value; fi
  [[ -n "$value" ]] || die "$label is required."
  export "$name=$value"
}
wrangler() { npx --no-install wrangler "$@"; }
cf() {
  local method="$1" path="$2" data="${3:-}" response
  if [[ -n "$data" ]]; then
    response="$(curl -sS -X "$method" "$CF_API$path" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' --data "$data")" || die "Could not connect to Cloudflare API."
  else
    response="$(curl -sS -X "$method" "$CF_API$path" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")" || die "Could not connect to Cloudflare API."
  fi
  jq -e . >/dev/null 2>&1 <<<"$response" || die "Cloudflare returned an unreadable response for $method $path."
  if ! jq -e '.success == true' >/dev/null <<<"$response"; then
    printf 'Cloudflare error details:\n' >&2
    jq -r '.errors[]? | "- Code \(.code // "unknown"): \(.message // "Unknown Cloudflare error")"' <<<"$response" >&2
    if [[ "$method" == "POST" && "$path" == "/zones" ]]; then
      printf '%s\n' 'The token cannot create this zone. Either add constrovet.com in the Cloudflare dashboard first, or create a token with Account > Zone > Edit and Zone > DNS > Edit permissions for the Constrovet account.' >&2
      printf '%s\n' 'After the dashboard shows constrovet.com, rerun dns-onboard. Do not change Namecheap nameservers yet.' >&2
    fi
    if [[ "$path" == *'/rulesets'* ]]; then
      if [[ "$path" == "/accounts/"*'/rulesets'* ]]; then
        printf '%s\n' 'The token must include Account > Account Rulesets > Read (or Account WAF Read) so the Free Managed Ruleset can be resolved without broad account access.' >&2
      elif [[ "$path" == *'http_request_firewall_managed'* ]]; then
        printf '%s\n' 'The token must include Zone > WAF > Edit for constrovet.com so the Cloudflare Free Managed Ruleset can be enforced.' >&2
      else
        printf '%s\n' 'The token must include Zone > Dynamic URL Redirects > Edit and Zone > WAF > Edit for constrovet.com.' >&2
      fi
    fi
    die "Cloudflare API request failed: $method $path"
  fi
  printf '%s' "$response"
}
cloudflare_login() {
  load_state
  prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API token"
  prompt_value CLOUDFLARE_ACCOUNT_ID "Cloudflare account ID"
  export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
  save_state CLOUDFLARE_ACCOUNT_ID "$CLOUDFLARE_ACCOUNT_ID"
}
assert_zone() {
  local zones status
  zones="$(cf GET '/zones?name=constrovet.com')"
  ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$zones")"
  status="$(jq -r '.result[0].status // empty' <<<"$zones")"
  [[ -n "$ZONE_ID" && "$status" == "active" ]] || die "constrovet.com is not an active Cloudflare zone. Complete docs/dns-cutover.md first."
  save_state ZONE_ID "$ZONE_ID"
}

find_zone() {
  local zones
  zones="$(cf GET '/zones?name=constrovet.com')"
  ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$zones")"
  if [[ -n "$ZONE_ID" ]]; then
    local account_id
    account_id="$(jq -r '.result[0].account.id // empty' <<<"$zones")"
    [[ "$account_id" == "$CLOUDFLARE_ACCOUNT_ID" ]] || die "constrovet.com exists in a different Cloudflare account. Do not continue."
  fi
}

ensure_preserved_dns_record() {
  local type="$1" name="$2" content="$3" priority="${4:-}" records count existing expected body
  records="$(cf GET "/zones/$ZONE_ID/dns_records?name=$name&type=$type")"
  count="$(jq '.result | length' <<<"$records")"
  expected="$type|$content|false|$priority"
  if [[ "$count" == "0" ]]; then
    if [[ "$type" == "MX" ]]; then
      body="$(jq -nc --arg type "$type" --arg name "$name" --arg content "$content" --argjson priority "$priority" '{type:$type,name:$name,content:$content,priority:$priority,ttl:1,proxied:false}')"
    else
      body="$(jq -nc --arg type "$type" --arg name "$name" --arg content "$content" '{type:$type,name:$name,content:$content,ttl:1,proxied:false}')"
    fi
    cf POST "/zones/$ZONE_ID/dns_records" "$body" >/dev/null
    printf 'Created preserved record: %s %s -> %s\n' "$type" "$name" "$content"
    return
  fi
  [[ "$count" == "1" ]] || die "Multiple Cloudflare records exist for $name. Review them manually; nothing was changed."
  existing="$(jq -r '.result[0] | [.type,.content,(.proxied // false | tostring),(.priority // "" | tostring)] | join("|")' <<<"$records")"
  [[ "$existing" == "$expected" ]] || die "Conflicting Cloudflare record for $name: $existing. Expected: $expected. Nothing was changed."
  printf 'Preserved record already correct: %s %s -> %s\n' "$type" "$name" "$content"
}

ensure_app_redirect_dns() {
  local records count existing record_id proxied body
  records="$(cf GET "/zones/$ZONE_ID/dns_records?name=app.constrovet.com")"
  count="$(jq '.result | length' <<<"$records")"
  if [[ "$count" == "0" ]]; then
    body="$(jq -nc '{type:"A",name:"app",content:"34.102.192.38",ttl:1,proxied:true}')"
    cf POST "/zones/$ZONE_ID/dns_records" "$body" >/dev/null
    printf 'Created proxied app record for the approved redirect.\n'
    return
  fi
  [[ "$count" == "1" ]] || die "Multiple Cloudflare records exist for app.constrovet.com. Review them manually; nothing was changed."
  existing="$(jq -r '.result[0] | [.type,.content] | join("|")' <<<"$records")"
  [[ "$existing" == "A|34.102.192.38" ]] || die "Conflicting app record: $existing. Expected legacy A|34.102.192.38 before redirect activation."
  record_id="$(jq -r '.result[0].id' <<<"$records")"
  proxied="$(jq -r '.result[0].proxied' <<<"$records")"
  if [[ "$proxied" != "true" ]]; then
    cf PATCH "/zones/$ZONE_ID/dns_records/$record_id" '{"proxied":true}' >/dev/null
    printf 'Enabled Cloudflare proxy for app.constrovet.com.\n'
  else
    printf 'Proxied app record already correct.\n'
  fi
}

ensure_app_redirect_rule() {
  local description expression target rule rulesets ruleset_id details conflicts existing body
  description='Redirect retired app host to active static dashboard'
  expression='(http.host eq "app.constrovet.com")'
  target='https://www.constrovet.com/app/'
  rule="$(jq -nc --arg description "$description" --arg expression "$expression" --arg target "$target" '{action:"redirect",action_parameters:{from_value:{status_code:301,target_url:{value:$target},preserve_query_string:true}},expression:$expression,description:$description,enabled:true}')"
  rulesets="$(cf GET "/zones/$ZONE_ID/rulesets")"
  ruleset_id="$(jq -r '.result[]? | select(.kind == "zone" and .phase == "http_request_dynamic_redirect") | .id' <<<"$rulesets" | head -1)"
  if [[ -z "$ruleset_id" ]]; then
    body="$(jq -nc --argjson rule "$rule" '{name:"ChallanSe managed redirects",kind:"zone",phase:"http_request_dynamic_redirect",rules:[$rule]}')"
    cf POST "/zones/$ZONE_ID/rulesets" "$body" >/dev/null
    printf 'Created 301 redirect: app.constrovet.com -> %s\n' "$target"
    return
  fi
  details="$(cf GET "/zones/$ZONE_ID/rulesets/$ruleset_id")"
  conflicts="$(jq --arg host app.constrovet.com --arg description "$description" '[.result.rules[]? | select((.expression | contains($host)) and .description != $description)] | length' <<<"$details")"
  [[ "$conflicts" == "0" ]] || die "Another redirect rule already handles app.constrovet.com. Review it manually; nothing was changed."
  existing="$(jq -c --arg description "$description" '.result.rules[]? | select(.description == $description)' <<<"$details" | head -1)"
  if [[ -z "$existing" ]]; then
    cf POST "/zones/$ZONE_ID/rulesets/$ruleset_id/rules" "$rule" >/dev/null
    printf 'Added 301 redirect: app.constrovet.com -> %s\n' "$target"
    return
  fi
  jq -e --arg expression "$expression" --arg target "$target" '.action == "redirect" and .enabled == true and .expression == $expression and .action_parameters.from_value.status_code == 301 and .action_parameters.from_value.target_url.value == $target and .action_parameters.from_value.preserve_query_string == true' >/dev/null <<<"$existing" || die "The managed app redirect exists but differs from the approved 301 target. Review it manually; nothing was changed."
  printf 'App redirect rule already correct.\n'
}

free_managed_waf_ids() {
  local managed_rulesets free_ruleset_id zone_rulesets entrypoint_id details execute_rule_id
  managed_rulesets="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/rulesets?per_page=100")"
  free_ruleset_id="$(jq -r '.result[]? | select(.name == "Cloudflare Free Managed Ruleset") | .id' <<<"$managed_rulesets" | head -1)"
  [[ -n "$free_ruleset_id" ]] || die "Cloudflare Free Managed Ruleset is unavailable for this account. Nothing was changed."
  zone_rulesets="$(cf GET "/zones/$ZONE_ID/rulesets")"
  entrypoint_id="$(jq -r '.result[]? | select(.kind == "zone" and .phase == "http_request_firewall_managed") | .id' <<<"$zone_rulesets" | head -1)"
  execute_rule_id=""
  if [[ -n "$entrypoint_id" ]]; then
    details="$(cf GET "/zones/$ZONE_ID/rulesets/$entrypoint_id")"
    execute_rule_id="$(jq -r --arg managed "$free_ruleset_id" '.result.rules[]? | select(.action == "execute" and .enabled == true and .expression == "true" and .action_parameters.id == $managed) | .id' <<<"$details" | head -1)"
  fi
  printf '%s|%s|%s' "$free_ruleset_id" "$entrypoint_id" "$execute_rule_id"
}

ensure_free_managed_waf() {
  local ids free_ruleset_id entrypoint_id execute_rule_id rule body created
  ids="$(free_managed_waf_ids)"
  IFS='|' read -r free_ruleset_id entrypoint_id execute_rule_id <<<"$ids"
  if [[ -n "$execute_rule_id" ]]; then
    printf '%s\n' 'Cloudflare Free Managed Ruleset is already enabled.'
  else
    rule="$(jq -nc --arg ruleset_id "$free_ruleset_id" '{action:"execute",action_parameters:{id:$ruleset_id},expression:"true",description:"ChallanSe Cloudflare Free Managed Ruleset",enabled:true}')"
    if [[ -z "$entrypoint_id" ]]; then
      body="$(jq -nc --argjson rule "$rule" '{name:"ChallanSe managed WAF",description:"Zone-level managed WAF entry point",kind:"zone",phase:"http_request_firewall_managed",rules:[$rule]}')"
      created="$(cf POST "/zones/$ZONE_ID/rulesets" "$body")"
      entrypoint_id="$(jq -r '.result.id // empty' <<<"$created")"
      execute_rule_id="$(jq -r '.result.rules[]? | select(.description == "ChallanSe Cloudflare Free Managed Ruleset") | .id' <<<"$created" | head -1)"
    else
      created="$(cf POST "/zones/$ZONE_ID/rulesets/$entrypoint_id/rules" "$rule")"
      execute_rule_id="$(jq -r '.result.rules[]? | select(.description == "ChallanSe Cloudflare Free Managed Ruleset") | .id' <<<"$created" | head -1)"
    fi
    [[ -n "$entrypoint_id" && -n "$execute_rule_id" ]] || die "Cloudflare created an incomplete WAF configuration. Review the zone before continuing."
    printf '%s\n' 'Enabled the Cloudflare Free Managed Ruleset for constrovet.com.'
  fi
  save_state CLOUDFLARE_FREE_WAF_RULESET_ID "$free_ruleset_id"
  save_state CLOUDFLARE_FREE_WAF_ENTRYPOINT_ID "$entrypoint_id"
  save_state CLOUDFLARE_FREE_WAF_EXECUTE_RULE_ID "$execute_rule_id"
  gh variable set CLOUDFLARE_FREE_WAF_ENABLED --repo "$REPO" --env production --body true
}

assert_free_managed_waf() {
  local ids free_ruleset_id entrypoint_id execute_rule_id
  ids="$(free_managed_waf_ids)"
  IFS='|' read -r free_ruleset_id entrypoint_id execute_rule_id <<<"$ids"
  [[ -n "$free_ruleset_id" && -n "$entrypoint_id" && -n "$execute_rule_id" ]] || die "Cloudflare Free Managed Ruleset is not enabled. Rerun: ./scripts/go-live.sh provision"
}

dns_onboard() {
  for command in jq curl git; do need "$command"; done
  [[ -z "$(git status --porcelain)" ]] || die "Git working tree is not clean."
  cloudflare_login
  find_zone
  if [[ -z "$ZONE_ID" ]]; then
    confirm "Create the constrovet.com Cloudflare zone on the Free plan. This does not change Namecheap nameservers."
    local body created
    body="$(jq -nc --arg name constrovet.com --arg account "$CLOUDFLARE_ACCOUNT_ID" '{name:$name,account:{id:$account},type:"full"}')"
    created="$(cf POST '/zones' "$body")"
    ZONE_ID="$(jq -r '.result.id // empty' <<<"$created")"
    [[ -n "$ZONE_ID" ]] || die "Cloudflare did not return a zone ID."
  fi
  save_state ZONE_ID "$ZONE_ID"
  ensure_app_redirect_dns
  ensure_preserved_dns_record CNAME www.constrovet.com tcbhagat.github.io
  ensure_preserved_dns_record MX constrovet.com alt4.aspmx.l.google.com 10
  ensure_app_redirect_rule

  local zone nameserver_one nameserver_two
  zone="$(cf GET "/zones/$ZONE_ID")"
  nameserver_one="$(jq -r '.result.name_servers[0] // empty' <<<"$zone")"
  nameserver_two="$(jq -r '.result.name_servers[1] // empty' <<<"$zone")"
  [[ -n "$nameserver_one" && -n "$nameserver_two" ]] || die "Cloudflare has not assigned two nameservers."
  save_state CLOUDFLARE_NAMESERVER_1 "$nameserver_one"
  save_state CLOUDFLARE_NAMESERVER_2 "$nameserver_two"
  cf GET "/zones/$ZONE_ID/dns_records?per_page=500" | jq '[.result[] | select(.name == "app.constrovet.com" or .name == "www.constrovet.com" or (.type == "MX" and .name == "constrovet.com")) | {type,name,content,priority,proxied}] | sort_by(.type,.name)' > "$DNS_ONBOARDING_BASELINE"
  chmod 600 "$DNS_ONBOARDING_BASELINE"
  cat <<EOF

Cloudflare DNS is ready. No Namecheap setting has been changed.

In Namecheap:
1. Domain List -> Manage beside constrovet.com.
2. Open Domain (not Advanced DNS).
3. Nameservers -> Custom DNS.
4. Enter exactly:
   $nameserver_one
   $nameserver_two
5. Click the green checkmark. Keep DNSSEC off and do not delete Advanced DNS records.

Then wait 15-30 minutes and run:
  ./scripts/go-live.sh dns-status
EOF
}

dns_status() {
  for command in jq curl dig; do need "$command"; done
  load_state
  [[ -n "${CLOUDFLARE_NAMESERVER_1:-}" && -n "${CLOUDFLARE_NAMESERVER_2:-}" ]] || die "Run dns-onboard first."
  local ns app_record www_record mx_record www_status app_status app_result app_final
  ns="$(dig @1.1.1.1 NS constrovet.com +short | tr '[:upper:]' '[:lower:]' | sed 's/\.$//' | sort)"
  if ! grep -Fxq "${CLOUDFLARE_NAMESERVER_1,,}" <<<"$ns" || ! grep -Fxq "${CLOUDFLARE_NAMESERVER_2,,}" <<<"$ns"; then
    printf 'Cloudflare is still waiting for the nameserver change. Current public nameservers:\n%s\n' "$ns" >&2
    die "Wait 15-30 minutes and rerun dns-status. Cloudflare activation can take up to 24 hours."
  fi
  app_record="$(dig @1.1.1.1 A app.constrovet.com +short | sort)"
  www_record="$(dig @1.1.1.1 CNAME www.constrovet.com +short | tr '[:upper:]' '[:lower:]')"
  mx_record="$(dig @1.1.1.1 MX constrovet.com +short | tr '[:upper:]' '[:lower:]')"
  [[ -n "$app_record" && "$app_record" != "34.102.192.38" ]] || die "app.constrovet.com is not using the Cloudflare proxy yet: $app_record"
  [[ "$www_record" == "tcbhagat.github.io." ]] || die "www.constrovet.com changed: $www_record"
  [[ "$mx_record" == "10 alt4.aspmx.l.google.com." ]] || die "Constrovet MX changed: $mx_record"
  www_status="$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' https://www.constrovet.com/)" || die "www.constrovet.com failed HTTPS validation."
  app_status="$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' https://app.constrovet.com/)" || die "app.constrovet.com HTTPS is not ready. Cloudflare certificate issuance can take up to 24 hours."
  app_result="$(curl -sS -L --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}|%{url_effective}' https://app.constrovet.com/)" || die "The app redirect could not be followed."
  app_final="${app_result#*|}"
  [[ "$www_status" == "200" && "$app_status" == "301" && "$app_result" == "200|https://www.constrovet.com/app/" ]] || die "App redirect validation failed: initial HTTP $app_status; final $app_result"
  printf 'DNS and HTTPS checks passed. www HTTP %s; app HTTP %s -> %s.\n' "$www_status" "$app_status" "$app_final"
  printf 'Now test email in both directions, then run: ./scripts/go-live.sh dns-accept\n'
}

dns_accept() {
  dns_status
  local answer
  read -r -p 'Open www.constrovet.com with no certificate warning. Type WEBSITE OK: ' answer
  [[ "$answer" == "WEBSITE OK" ]] || die "Website acceptance was not confirmed."
  read -r -p 'Open app.constrovet.com and confirm it redirects to www.constrovet.com/app/ with no warning. Type APP REDIRECT OK: ' answer
  [[ "$answer" == "APP REDIRECT OK" ]] || die "App redirect acceptance was not confirmed."
  read -r -p 'Send and receive @constrovet.com email successfully. Type EMAIL BOTH DIRECTIONS OK: ' answer
  [[ "$answer" == "EMAIL BOTH DIRECTIONS OK" ]] || die "Email acceptance was not confirmed."
  save_state DNS_ACCEPTED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  save_state DNS_ACCEPTED_ZONE_ID "$ZONE_ID"
  printf 'Cloudflare migration accepted. ChallanSe preflight may now continue.\n'
}
assert_clean_main() {
  [[ -z "$(git status --porcelain)" ]] || die "Git working tree is not clean."
  [[ "$(git branch --show-current)" == "main" ]] || die "Checkout main before production operations."
  git fetch origin main --quiet
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "Local main does not match origin/main."
}
latest_ci_success() {
  local conclusion sha
  conclusion="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch main --limit 1 --json conclusion --jq '.[0].conclusion')"
  sha="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch main --limit 1 --json headSha --jq '.[0].headSha')"
  [[ "$conclusion" == "success" && "$sha" == "$(git rev-parse HEAD)" ]] || die "Latest main CI for the current commit is not successful."
}
render_edge_config() {
  load_state
  [[ -n "${ACCESS_TEAM_DOMAIN:-}" && -n "${ACCESS_AUD:-}" ]] || die "Provisioning state is incomplete."
  CLOUDFLARE_ACCESS_TEAM_DOMAIN="$ACCESS_TEAM_DOMAIN" CLOUDFLARE_ACCESS_AUD="$ACCESS_AUD" node scripts/render-edge-config.mjs >/dev/null
}

preflight() {
  for command in gh jq curl openssl git node npm npx base64 sha256sum; do need "$command"; done
  assert_clean_main
  gh auth status >/dev/null
  latest_ci_success
  cloudflare_login
  wrangler whoami >/dev/null
  assert_zone
  load_state
  [[ -n "${DNS_ACCEPTED_AT:-}" && "${DNS_ACCEPTED_ZONE_ID:-}" == "$ZONE_ID" ]] || die "Run dns-status and dns-accept after website, app, and email checks pass."
  printf 'Preflight passed for %s. Production deployment remains disabled.\n' "$REPO"
}

snapshot_dns() {
  local records
  records="$(cf GET "/zones/$ZONE_ID/dns_records?per_page=500")"
  jq '[.result[] | select(.name != "challanse.constrovet.com" and .name != "api.challanse.constrovet.com" and .name != "review.challanse.constrovet.com") | {type,name,content,priority,proxied}] | sort_by(.type,.name,.content)' <<<"$records" > "$DNS_BASELINE"
  chmod 600 "$DNS_BASELINE"
}

ensure_landing_dns() {
  local records count existing body
  records="$(cf GET "/zones/$ZONE_ID/dns_records?name=challanse.constrovet.com")"
  count="$(jq '.result | length' <<<"$records")"
  if [[ "$count" == "0" ]]; then
    body="$(jq -nc '{type:"CNAME",name:"challanse",content:"tcbhagat.github.io",ttl:1,proxied:false}')"
    cf POST "/zones/$ZONE_ID/dns_records" "$body" >/dev/null
  elif [[ "$count" == "1" ]]; then
    existing="$(jq -r '.result[0] | [.type,.content,(.proxied|tostring)] | join("|")' <<<"$records")"
    [[ "$existing" == "CNAME|tcbhagat.github.io|false" ]] || die "Conflicting DNS record for challanse.constrovet.com: $existing"
  else
    die "Multiple DNS records exist for challanse.constrovet.com."
  fi
}

github_turnstile_secret_exists() {
  local exists
  exists="$(gh secret list --repo "$REPO" --env production --json name --jq 'any(.[]; .name == "TURNSTILE_SECRET")' 2>/dev/null)" || return 1
  [[ "$exists" == "true" ]]
}

github_environment_secret_exists() {
  local name="$1" exists
  exists="$(gh secret list --repo "$REPO" --env production --json name --jq "any(.[]; .name == \"$name\")" 2>/dev/null)" || return 1
  [[ "$exists" == "true" ]]
}

github_environment_variable() {
  local name="$1"
  gh variable list --repo "$REPO" --env production --json name,value --jq ".[] | select(.name == \"$name\") | .value" 2>/dev/null
}

resolve_device_token_pepper() {
  if github_environment_secret_exists DEVICE_TOKEN_PEPPER; then
    printf '%s\n' 'Existing GitHub DEVICE_TOKEN_PEPPER retained; enrolled devices remain valid.' >&2
    return
  fi
  openssl rand -hex 32
}

signing_fingerprint() {
  local keystore="$1" password="$2"
  keytool -list -v -keystore "$keystore" -alias challanse -storepass "$password" 2>/dev/null |
    sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | head -1 | tr -d ':' | tr '[:lower:]' '[:upper:]'
}

validate_new_keystore_path() {
  local keystore="$1" parent resolved_parent
  [[ "$keystore" == *.jks ]] || die "Release keystore path must end in .jks."
  [[ ! -e "$keystore" ]] || die "Refusing to overwrite an existing release keystore: $keystore"
  parent="$(dirname "$keystore")"
  [[ -d "$parent" ]] || die "Keystore parent directory does not exist: $parent"
  resolved_parent="$(cd "$parent" && pwd -P)"
  [[ "$resolved_parent" != "$ROOT" && "$resolved_parent" != "$ROOT"/* ]] || die "Release keystore must be stored outside the Git repository."
  [[ "$(basename "$keystore")" =~ ^[A-Za-z0-9._-]+\.jks$ ]] || die "Keystore filename contains unsafe characters. Use letters, numbers, dots, dashes, or underscores."
}

debug_keystore_is_expected() {
  local keystore="$1" file_digest certificate_digest
  [[ -r "$keystore" ]] || return 1
  file_digest="$(sha256sum "$keystore" | awk '{print $1}')"
  [[ "$file_digest" == "$EXPECTED_DEBUG_KEYSTORE_SHA256" ]] || return 1
  certificate_digest="$(
    keytool -list -v -keystore "$keystore" -alias androiddebugkey -storepass android -keypass android 2>/dev/null |
      sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' |
      head -1 |
      tr -d ':' |
      tr '[:lower:]' '[:upper:]'
  )"
  [[ "$certificate_digest" == "$EXPECTED_DEBUG_CERT_SHA256" ]]
}

release_keystore_paths_in_history() {
  local repository="$1" object path temporary
  while read -r object path; do
    [[ "$path" =~ \.(jks|keystore)$ ]] || continue
    if [[ "$path" != "$EXPECTED_DEBUG_KEYSTORE_PATH" ]]; then
      printf '%s@%s\n' "$path" "$object"
      continue
    fi
    if [[ "$(git -C "$repository" cat-file -t "$object" 2>/dev/null || true)" != "blob" ]]; then
      printf '%s@%s\n' "$path" "$object"
      continue
    fi
    temporary="$(mktemp "$STATE_DIR/debug-keystore-history.XXXXXX")"
    git -C "$repository" cat-file blob "$object" > "$temporary"
    if ! debug_keystore_is_expected "$temporary"; then
      printf '%s@%s\n' "$path" "$object"
    fi
    shred -u -- "$temporary"
  done < <(git -C "$repository" rev-list --objects --all)
}

release_keystore_paths_in_worktree() {
  local scan_root="$1" keystore relative
  while IFS= read -r -d '' keystore; do
    relative="${keystore#"$scan_root"/}"
    if [[ "$relative" != "$EXPECTED_DEBUG_KEYSTORE_PATH" ]] || ! debug_keystore_is_expected "$keystore"; then
      printf '%s\n' "$keystore"
    fi
  done < <(find "$scan_root" -type f \( -name '*.jks' -o -name '*.keystore' \) -print0)
}

rotate_turnstile_secret() {
  local sitekey="$1" rotated secret
  printf '%s\n' 'The existing Turnstile widget has no secret in GitHub because an earlier provisioning run stopped before completion.' >&2
  confirm "Rotate this unused Turnstile secret once and send the replacement directly to the GitHub production environment."
  rotated="$(cf POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/challenges/widgets/$sitekey/rotate_secret" '{"invalidate_immediately":true}')"
  secret="$(jq -r '.result.secret // empty' <<<"$rotated")"
  [[ -n "$secret" ]] || die "Cloudflare rotated the Turnstile widget but did not return a replacement secret."
  printf '%s' "$secret"
}

resolve_turnstile_secret() {
  local sitekey="$1" returned_secret="$2"
  if [[ -n "$returned_secret" ]]; then
    printf '%s' "$returned_secret"
    return
  fi
  if github_turnstile_secret_exists; then
    printf '%s\n' 'Existing GitHub TURNSTILE_SECRET retained; no rotation performed.' >&2
    return
  fi
  rotate_turnstile_secret "$sitekey"
}

provision() {
  preflight
  prompt_value REVIEWER_EMAIL_1 "Primary reviewer email"
  prompt_value REVIEWER_EMAIL_2 "Second reviewer email"
  [[ "$REVIEWER_EMAIL_1" != "$REVIEWER_EMAIL_2" ]] || die "Reviewer emails must be different."
  snapshot_dns
  local widgets widget turnstile_sitekey turnstile_secret organization access_domain apps app access_aud body email_rules
  widgets="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/challenges/widgets?filter=name:ChallanSe%20pilot&per_page=50")"
  widget="$(jq -c '.result[]? | select(.name == "ChallanSe pilot")' <<<"$widgets" | head -1)"
  if [[ -z "$widget" ]]; then
    body="$(jq -nc '{name:"ChallanSe pilot",domains:["challanse.constrovet.com"],mode:"managed",region:"world"}')"
    widget="$(cf POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/challenges/widgets" "$body" | jq -c '.result')"
  fi
  turnstile_sitekey="$(jq -r '.sitekey // empty' <<<"$widget")"
  turnstile_secret="$(jq -r '.secret // empty' <<<"$widget")"
  [[ -n "$turnstile_sitekey" ]] || die "Turnstile site key was not returned."
  turnstile_secret="$(resolve_turnstile_secret "$turnstile_sitekey" "$turnstile_secret")"
  if [[ -n "$turnstile_secret" ]]; then
    printf '%s' "$turnstile_secret" | gh secret set TURNSTILE_SECRET --repo "$REPO" --env production
    unset turnstile_secret
  fi

  organization="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/organizations")"
  access_domain="$(jq -r '.result.auth_domain // empty' <<<"$organization")"
  [[ -n "$access_domain" ]] || die "Cloudflare Zero Trust organization is not initialized. Initialize it once, then rerun."
  apps="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps")"
  app="$(jq -c '.result[]? | select(.name == "ChallanSe reviewers")' <<<"$apps" | head -1)"
  if [[ -z "$app" ]]; then
    email_rules="$(jq -nc --arg first "$REVIEWER_EMAIL_1" --arg second "$REVIEWER_EMAIL_2" '[{email:{email:$first}},{email:{email:$second}}]')"
    body="$(jq -nc --argjson include "$email_rules" '{name:"ChallanSe reviewers",type:"self_hosted",destinations:[{type:"public",uri:"review.challanse.constrovet.com"}],session_duration:"8h",app_launcher_visible:false,policies:[{name:"Approved ChallanSe reviewers",decision:"allow",precedence:1,include:$include}]}')"
    app="$(cf POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps" "$body" | jq -c '.result')"
  else
    app="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$(jq -r .id <<<"$app")" | jq -c '.result')"
    if ! jq -e '(.allowed_idps | length) == 1 and .auto_redirect_to_identity == true and .mfa_config.mfa_disabled == false' >/dev/null <<<"$app"; then
      jq -e --arg first "$REVIEWER_EMAIL_1" --arg second "$REVIEWER_EMAIL_2" '[.. | .email? | strings] | index($first) != null and index($second) != null' >/dev/null <<<"$app" || die "Existing Access app is neither enterprise-OIDC/MFA hardened nor limited to both supplied pre-launch reviewers."
    fi
  fi
  access_aud="$(jq -r '.aud // empty' <<<"$app")"
  [[ -n "$access_aud" ]] || die "Access audience was not returned."
  save_state ACCESS_TEAM_DOMAIN "$access_domain"
  save_state ACCESS_AUD "$access_aud"
  save_state TURNSTILE_SITE_KEY "$turnstile_sitekey"
  save_state REVIEWER_EMAIL_1 "$REVIEWER_EMAIL_1"
  save_state REVIEWER_EMAIL_2 "$REVIEWER_EMAIL_2"

  gh variable set CLOUDFLARE_ACCESS_TEAM_DOMAIN --repo "$REPO" --env production --body "$access_domain"
  gh variable set CLOUDFLARE_ACCESS_AUD --repo "$REPO" --env production --body "$access_aud"
  gh variable set TURNSTILE_SITE_KEY --repo "$REPO" --env production --body "$turnstile_sitekey"
  ensure_landing_dns
  ensure_free_managed_waf
  if gh api "repos/$REPO/pages" >/dev/null 2>&1; then
    gh api --method PUT "repos/$REPO/pages" -f cname=challanse.constrovet.com -f build_type=workflow >/dev/null
  else
    gh api --method POST "repos/$REPO/pages" -f build_type=workflow >/dev/null
    gh api --method PUT "repos/$REPO/pages" -f cname=challanse.constrovet.com -f build_type=workflow >/dev/null
  fi
  unset turnstile_secret CLOUDFLARE_API_TOKEN
  printf 'Stateless Cloudflare routing, Access, Turnstile, DNS, and GitHub variables are provisioned. AWS remains authoritative and deployment remains disabled.\n'
}

configure_identity() {
  preflight
  local identity_provider_id providers provider_type apps app app_id policies policy policy_id app_body policy_body verified
  read -r -p 'Cloudflare enterprise OIDC identity-provider UUID: ' identity_provider_id
  [[ "$identity_provider_id" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Identity-provider ID must be a UUID from Zero Trust > Settings > Authentication > Login methods."
  providers="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/identity_providers?per_page=100")"
  provider_type="$(jq -r --arg id "$identity_provider_id" '.result[]? | select(.id == $id) | .type // empty' <<<"$providers")"
  [[ "$provider_type" == "oidc" ]] || die "The selected login method is not a generic enterprise OIDC provider: ${provider_type:-not found}."

  apps="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps")"
  app="$(jq -c '.result[]? | select(.name == "ChallanSe reviewers")' <<<"$apps" | head -1)"
  [[ -n "$app" ]] || die "Run provision before configuring enterprise identity."
  app_id="$(jq -r '.id' <<<"$app")"
  app_body="$(jq -nc --arg idp "$identity_provider_id" '{name:"ChallanSe reviewers",type:"self_hosted",destinations:[{type:"public",uri:"review.challanse.constrovet.com"}],session_duration:"8h",app_launcher_visible:false,allow_authenticate_via_warp:false,allowed_idps:[$idp],auto_redirect_to_identity:true,mfa_config:{mfa_disabled:false,session_duration:"8h",allowed_authenticators:["totp","security_key","biometrics"]}}')"
  cf PUT "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$app_id" "$app_body" >/dev/null

  policies="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$app_id/policies")"
  policy="$(jq -c '.result[]? | select(.name == "Approved ChallanSe reviewers")' <<<"$policies" | head -1)"
  [[ -n "$policy" ]] || die "The ChallanSe reviewer Access policy was not found."
  policy_id="$(jq -r '.id' <<<"$policy")"
  policy_body="$(jq -nc --arg idp "$identity_provider_id" '{name:"Approved ChallanSe reviewers",decision:"allow",precedence:1,include:[{everyone:{}}],require:[{login_method:{id:$idp}},{auth_method:{auth_method:"mfa"}}],session_duration:"8h",mfa_config:{mfa_disabled:false,session_duration:"8h",allowed_authenticators:["totp","security_key","biometrics"]}}')"
  cf PUT "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$app_id/policies/$policy_id" "$policy_body" >/dev/null

  verified="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$app_id")"
  jq -e --arg idp "$identity_provider_id" '.result.allowed_idps == [$idp] and .result.auto_redirect_to_identity == true and .result.mfa_config.mfa_disabled == false' >/dev/null <<<"$verified" || die "Cloudflare did not retain the OIDC and MFA application settings."
  verified="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$app_id/policies/$policy_id")"
  jq -e --arg idp "$identity_provider_id" '([.result.require[]?.login_method.id] | index($idp) != null) and ([.result.require[]?.auth_method.auth_method] | index("mfa") != null) and .result.mfa_config.mfa_disabled == false' >/dev/null <<<"$verified" || die "Cloudflare did not retain the OIDC and MFA policy requirements."

  save_state ACCESS_IDENTITY_PROVIDER_ID "$identity_provider_id"
  save_state ACCESS_MFA_ENFORCED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh variable set ACCESS_IDENTITY_PROVIDER_ID --repo "$REPO" --env production --body "$identity_provider_id"
  gh variable set ACCESS_MFA_ENFORCED --repo "$REPO" --env production --body true
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  printf '%s\n' 'Reviewer Access now permits only the selected enterprise OIDC provider and requires MFA; database membership remains the final authorization check.'
}

configure_github() {
  preflight
  command -v keytool >/dev/null 2>&1 || die "keytool is required only for Android signing. On Ubuntu run: sudo apt update && sudo apt install -y openjdk-17-jdk-headless"
  load_state
  [[ -n "${ACCESS_AUD:-}" && -n "${TURNSTILE_SITE_KEY:-}" ]] || die "Run provision first."
  prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API token"
  printf '%s' "$CLOUDFLARE_API_TOKEN" | gh secret set CLOUDFLARE_API_TOKEN --repo "$REPO" --env production
  printf '%s' "$CLOUDFLARE_ACCOUNT_ID" | gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$REPO" --env production
  local pepper keystore password password_confirm encoded fingerprint existing_fingerprint answer
  pepper="$(resolve_device_token_pepper)"
  if [[ -n "$pepper" ]]; then
    printf '%s' "$pepper" | gh secret set DEVICE_TOKEN_PEPPER --repo "$REPO" --env production
  fi
  existing_fingerprint="$(github_environment_variable CHALLANSE_UPLOAD_CERT_SHA256)"
  load_state
  if [[ -n "$existing_fingerprint" && -n "${SIGNING_CERT_SHA256:-}" && "$existing_fingerprint" == "$SIGNING_CERT_SHA256" ]]; then
    printf 'Existing Android signing identity retained: %s\n' "$existing_fingerprint"
    gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
    unset pepper CLOUDFLARE_API_TOKEN
    printf 'GitHub production secrets are configured; no credentials were rotated.\n'
    return
  fi
  if github_environment_secret_exists CHALLANSE_KEYSTORE_BASE64; then
    printf '%s\n' 'Existing upload-key secrets have no trusted local fingerprint. No Play release has been published, so rotate them before launch.'
    read -r -p 'Type ROTATE SIGNING to create a fresh pre-release identity: ' answer
    [[ "$answer" == "ROTATE SIGNING" ]] || die "Signing rotation cancelled; GitHub secrets were unchanged."
  fi
  keystore="${STATE_DIR}/challanse-release-$(date -u +%Y%m%dT%H%M%SZ).jks"
  validate_new_keystore_path "$keystore"
  printf 'New release keystore will be created outside the repository at: %s\n' "$keystore"
  confirm "Create this new Android signing identity."
  read -r -s -p "Android keystore/key password: " password; printf '\n'
  read -r -s -p "Repeat Android password: " password_confirm; printf '\n'
  [[ -n "$password" && "$password" == "$password_confirm" ]] || die "Android passwords do not match."
  keytool -genkeypair -v -keystore "$keystore" -alias challanse -keyalg RSA -keysize 4096 -validity 10000 -storepass "$password" -keypass "$password" -dname 'CN=ChallanSe, O=Constrovet, C=IN' >/dev/null
  chmod 600 "$keystore"
  keytool -list -keystore "$keystore" -alias challanse -storepass "$password" >/dev/null
  fingerprint="$(signing_fingerprint "$keystore" "$password")"
  [[ "$fingerprint" =~ ^[0-9A-F]{64}$ ]] || die "Could not read the signing certificate SHA-256 fingerprint."
  encoded="$(base64 -w0 "$keystore")"
  printf '%s' "$encoded" | gh secret set CHALLANSE_KEYSTORE_BASE64 --repo "$REPO" --env production
  printf '%s' "$password" | gh secret set CHALLANSE_KEYSTORE_PASSWORD --repo "$REPO" --env production
  printf '%s' challanse | gh secret set CHALLANSE_KEY_ALIAS --repo "$REPO" --env production
  printf '%s' "$password" | gh secret set CHALLANSE_KEY_PASSWORD --repo "$REPO" --env production
  gh variable set CHALLANSE_UPLOAD_CERT_SHA256 --repo "$REPO" --env production --body "$fingerprint"
  save_state SIGNING_KEYSTORE_PATH "$keystore"
  save_state SIGNING_CERT_SHA256 "$fingerprint"
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  unset password password_confirm encoded pepper CLOUDFLARE_API_TOKEN
  printf 'GitHub production secrets and Android signing are configured.\nCertificate SHA-256: %s\nBack up %s offline.\n' "$fingerprint" "$keystore"
}

configure_enrichment() {
  preflight
  need aws
  local enrichment_url access_client_id access_client_secret tunnel_token device_pepper pepper_confirmation play_credentials_file play_credentials_json tenant_context_key edge_key edge_next_key service_key service_next_key edge_key_id edge_next_key_id service_key_id service_next_key_id runtime_secret_arn runtime_json updated_runtime timestamp
  if github_environment_secret_exists EDGE_TO_ENRICHMENT_HMAC_KEY || github_environment_secret_exists EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY || github_environment_secret_exists ENRICHMENT_TO_EDGE_HMAC_KEY || github_environment_secret_exists ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY; then
    die "Directional enrichment keys already exist. Use the documented dual-key rotation procedure; configure-enrichment never replaces active keys."
  fi
  prompt_value ENRICHMENT_URL "Cloudflare Access-protected enrichment URL"
  enrichment_url="${ENRICHMENT_URL:-}"
  [[ "$enrichment_url" =~ ^https://[A-Za-z0-9.-]+$ ]] || die "Enrichment URL must be an HTTPS origin without a path."
  prompt_secret ENRICHMENT_ACCESS_CLIENT_ID "Cloudflare Access service-token client ID"
  prompt_secret ENRICHMENT_ACCESS_CLIENT_SECRET "Cloudflare Access service-token client secret"
  prompt_secret CLOUDFLARE_TUNNEL_TOKEN "Cloudflare Tunnel connector token"
  read -r -p 'Play Integrity Google credential JSON file (service_account or external_account): ' play_credentials_file
  play_credentials_file="$(realpath -e "$play_credentials_file")"
  [[ -f "$play_credentials_file" && "$play_credentials_file" != "$ROOT"/* ]] || die "Play Integrity credentials must be an existing JSON file outside this repository."
  jq -e '(.type == "service_account" and (.client_email | type == "string") and (.private_key | type == "string")) or (.type == "external_account" and (.audience | type == "string"))' >/dev/null "$play_credentials_file" || die "Play Integrity credentials must be a valid service_account or external_account configuration."
  play_credentials_json="$(jq -c . "$play_credentials_file")"
  prompt_value AWS_RUNTIME_SECRET_ARN "AWS enrichment runtime secret ARN"
  prompt_value AWS_DEAD_LETTER_QUEUE_URL "AWS receipt dead-letter queue URL"
  access_client_id="$ENRICHMENT_ACCESS_CLIENT_ID"
  access_client_secret="$ENRICHMENT_ACCESS_CLIENT_SECRET"
  tunnel_token="$CLOUDFLARE_TUNNEL_TOKEN"
  printf '%s\n' 'The original device pepper cannot be read back from GitHub. No production devices may exist at this pre-launch step.'
  read -r -p 'Type ROTATE UNUSED DEVICE PEPPER to create one authoritative value for AWS and GitHub: ' pepper_confirmation
  [[ "$pepper_confirmation" == "ROTATE UNUSED DEVICE PEPPER" ]] || die "Device pepper initialization cancelled."
  device_pepper="$(openssl rand -hex 32)"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  edge_key="$(openssl rand -hex 32)"
  edge_next_key="$(openssl rand -hex 32)"
  service_key="$(openssl rand -hex 32)"
  service_next_key="$(openssl rand -hex 32)"
  edge_key_id="edge-${timestamp}-current"
  edge_next_key_id="edge-${timestamp}-next"
  service_key_id="service-${timestamp}-current"
  service_next_key_id="service-${timestamp}-next"
  runtime_secret_arn="$AWS_RUNTIME_SECRET_ARN"
  runtime_json="$(aws secretsmanager get-secret-value --secret-id "$runtime_secret_arn" --query SecretString --output text)"
  jq -e '(.DATABASE_URL | type == "string" and length > 0) and (.SYSTEM_DATABASE_URL | type == "string" and length > 0)' >/dev/null <<<"$runtime_json" || die "AWS runtime secret does not contain the Terraform-created app and system database URLs."
  tenant_context_key="$(jq -r '.TENANT_CONTEXT_HMAC_KEY // empty' <<<"$runtime_json")"
  if [[ ! "$tenant_context_key" =~ ^[a-f0-9]{64,}$ ]]; then
    tenant_context_key="$(openssl rand -hex 32)"
  fi
  updated_runtime="$(jq -c \
    --arg edge_key_id "$edge_key_id" --arg edge_key "$edge_key" \
    --arg edge_next_key_id "$edge_next_key_id" --arg edge_next_key "$edge_next_key" \
    --arg service_key_id "$service_key_id" --arg service_key "$service_key" \
    --arg service_next_key_id "$service_next_key_id" --arg service_next_key "$service_next_key" \
    --arg access_id "$access_client_id" --arg access_secret "$access_client_secret" \
    --arg tunnel_token "$tunnel_token" --arg device_pepper "$device_pepper" --arg tenant_context_key "$tenant_context_key" \
    --argjson play_credentials "$play_credentials_json" \
    '. + {EDGE_TO_ENRICHMENT_HMAC_KEY_ID:$edge_key_id,EDGE_TO_ENRICHMENT_HMAC_KEY:$edge_key,EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID:$edge_next_key_id,EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY:$edge_next_key,ENRICHMENT_TO_EDGE_HMAC_KEY_ID:$service_key_id,ENRICHMENT_TO_EDGE_HMAC_KEY:$service_key,ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID:$service_next_key_id,ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY:$service_next_key,CLOUDFLARE_ACCESS_CLIENT_ID:$access_id,CLOUDFLARE_ACCESS_CLIENT_SECRET:$access_secret,CLOUDFLARE_TUNNEL_TOKEN:$tunnel_token,DEVICE_TOKEN_PEPPER:$device_pepper,TENANT_CONTEXT_HMAC_KEY:$tenant_context_key,PLAY_INTEGRITY_CREDENTIALS_JSON:($play_credentials|tojson)}' <<<"$runtime_json")"
  aws secretsmanager put-secret-value --secret-id "$runtime_secret_arn" --secret-string "$updated_runtime" >/dev/null
  printf '%s' "$edge_key" | gh secret set EDGE_TO_ENRICHMENT_HMAC_KEY --repo "$REPO" --env production
  printf '%s' "$edge_next_key" | gh secret set EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY --repo "$REPO" --env production
  printf '%s' "$service_key" | gh secret set ENRICHMENT_TO_EDGE_HMAC_KEY --repo "$REPO" --env production
  printf '%s' "$service_next_key" | gh secret set ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY --repo "$REPO" --env production
  printf '%s' "$access_client_id" | gh secret set ENRICHMENT_ACCESS_CLIENT_ID --repo "$REPO" --env production
  printf '%s' "$access_client_secret" | gh secret set ENRICHMENT_ACCESS_CLIENT_SECRET --repo "$REPO" --env production
  printf '%s' "$device_pepper" | gh secret set DEVICE_TOKEN_PEPPER --repo "$REPO" --env production
  gh variable set ENRICHMENT_URL --repo "$REPO" --env production --body "$enrichment_url"
  gh variable set EDGE_TO_ENRICHMENT_HMAC_KEY_ID --repo "$REPO" --env production --body "$edge_key_id"
  gh variable set EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID --repo "$REPO" --env production --body "$edge_next_key_id"
  gh variable set ENRICHMENT_TO_EDGE_HMAC_KEY_ID --repo "$REPO" --env production --body "$service_key_id"
  gh variable set ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID --repo "$REPO" --env production --body "$service_next_key_id"
  gh variable set AWS_RUNTIME_SECRET_ARN --repo "$REPO" --env production --body "$runtime_secret_arn"
  gh variable set AWS_DEAD_LETTER_QUEUE_URL --repo "$REPO" --env production --body "$AWS_DEAD_LETTER_QUEUE_URL"
  save_state ENRICHMENT_URL "$enrichment_url"
  save_state EDGE_TO_ENRICHMENT_HMAC_KEY_ID "$edge_key_id"
  save_state EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID "$edge_next_key_id"
  save_state ENRICHMENT_TO_EDGE_HMAC_KEY_ID "$service_key_id"
  save_state ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID "$service_next_key_id"
  unset edge_key edge_next_key service_key service_next_key access_client_id access_client_secret tunnel_token device_pepper tenant_context_key play_credentials_json runtime_json updated_runtime ENRICHMENT_ACCESS_CLIENT_SECRET CLOUDFLARE_TUNNEL_TOKEN
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  printf '%s\n' 'Directional HMAC keys and Access service credentials were sent directly to GitHub and AWS Secrets Manager; they were not saved locally.'
}

configure_play() {
  preflight
  local service_account_file organization_ids_file play_fingerprint upload_fingerprint cloud_project_number confirmation organization_ids_canonical organization_ids_sha256 organization_ids_count
  upload_fingerprint="$(github_environment_variable CHALLANSE_UPLOAD_CERT_SHA256)"
  [[ "$upload_fingerprint" =~ ^[0-9A-F]{64}$ ]] || die "Rotate/configure the upload key before Managed Google Play setup."
  printf '%s\n' 'In Play Console, create a private app with package ID com.constrovet.challanse and enable Google-managed Play App Signing.'
  printf '%s\n' 'Add the client organization IDs under Managed Google Play availability and grant the deployment service account access to this app.'
  read -r -p 'Type PLAY PRIVATE APP READY after those console steps are complete: ' confirmation
  [[ "$confirmation" == "PLAY PRIVATE APP READY" ]] || die "Managed Google Play setup was not confirmed."
  read -r -p 'Play app-signing certificate SHA-256 (64 hex characters, no colons): ' play_fingerprint
  play_fingerprint="$(tr -d ':' <<<"$play_fingerprint" | tr '[:lower:]' '[:upper:]')"
  [[ "$play_fingerprint" =~ ^[0-9A-F]{64}$ && "$play_fingerprint" != "$upload_fingerprint" ]] || die "Play app-signing fingerprint is invalid or incorrectly matches the upload certificate."
  read -r -p 'Google Cloud project number linked to Play Integrity: ' cloud_project_number
  [[ "$cloud_project_number" =~ ^[1-9][0-9]{5,19}$ ]] || die "Play Integrity Cloud project number is invalid."
  read -r -p 'Google Play service-account JSON file: ' service_account_file
  service_account_file="$(realpath -e "$service_account_file")"
  [[ -f "$service_account_file" && "$service_account_file" != "$ROOT"/* ]] || die "Service-account JSON must be an existing file outside this repository."
  jq -e '.type == "service_account" and (.client_email | type == "string" and length > 0) and (.private_key | type == "string" and length > 0)' >/dev/null "$service_account_file" || die "Invalid Google Play service-account JSON."
  read -r -p 'JSON file containing the approved Managed Google Play organization ID array: ' organization_ids_file
  organization_ids_file="$(realpath -e "$organization_ids_file")"
  [[ -f "$organization_ids_file" && "$organization_ids_file" != "$ROOT"/* ]] || die "Organization IDs must be supplied from a file outside this repository."
  jq -e 'type == "array" and length > 0 and length <= 100 and all(.[]; type == "string" and test("^[A-Za-z0-9._-]{3,128}$")) and (unique | length) == length' >/dev/null "$organization_ids_file" || die "Organization IDs file must contain 1-100 unique ID strings."
  organization_ids_canonical="$(jq -c 'sort' "$organization_ids_file")"
  organization_ids_sha256="$(printf '%s' "$organization_ids_canonical" | sha256sum | awk '{print $1}')"
  organization_ids_count="$(jq 'length' <<<"$organization_ids_canonical")"
  gh secret set PLAY_SERVICE_ACCOUNT_JSON --repo "$REPO" --env production < "$service_account_file"
  printf '%s' "$organization_ids_canonical" | gh secret set PLAY_MANAGED_ORGANIZATION_IDS --repo "$REPO" --env production
  gh variable set CHALLANSE_PLAY_APP_SIGNING_CERT_SHA256 --repo "$REPO" --env production --body "$play_fingerprint"
  gh variable set PLAY_INTEGRITY_CLOUD_PROJECT_NUMBER --repo "$REPO" --env production --body "$cloud_project_number"
  gh variable set PLAY_MANAGED_ORGANIZATIONS_SHA256 --repo "$REPO" --env production --body "$organization_ids_sha256"
  gh variable set PLAY_MANAGED_ORGANIZATIONS_COUNT --repo "$REPO" --env production --body "$organization_ids_count"
  gh variable set PLAY_RELEASE_TRACK --repo "$REPO" --env production --body internal
  gh variable set PLAY_PUBLISH_ENABLED --repo "$REPO" --env production --body true
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  unset organization_ids_canonical
  printf 'Managed Google Play is configured for %s approved organization(s) on the internal track. Production remains disabled.\n' "$organization_ids_count"
}

accept_client() {
  local report="${1:-}" digest confirmation
  [[ -r "$report" ]] || die "Usage: $0 accept-client /secure/client-acceptance.json"
  jq -e '
    .schema_version == "1.0" and (.client_organization_id_hash | test("^[a-f0-9]{64}$")) and
    .managed_play_access_confirmed == true and .controlled_rollout_accepted == true and
    (.accepted_by | type == "string" and length > 0) and
    (.accepted_at | type == "string") and (try (.accepted_at | fromdateiso8601) catch null) != null and
    (.evidence_artifacts | type == "array" and length > 0) and
    all(.evidence_artifacts[];
      (.name | type == "string" and length > 0) and
      (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ([.evidence_artifacts[].name] | unique | length) == (.evidence_artifacts | length)
  ' "$report" >/dev/null || die "Client acceptance does not satisfy the controlled-rollout gate."
  digest="$(sha256sum "$report" | awk '{print $1}')"
  read -r -p "Type ACCEPT CLIENT $digest after reviewing the signed evidence: " confirmation
  [[ "$confirmation" == "ACCEPT CLIENT $digest" ]] || die "Client acceptance cancelled."
  gh variable set CLIENT_ACCEPTANCE_SHA256 --repo "$REPO" --env production --body "$digest"
  printf 'Client acceptance evidence recorded: %s\n' "$digest"
}

accept_operator_training() {
  local report="${1:-}" digest confirmation
  [[ -r "$report" ]] || die "Usage: $0 accept-operator-training /secure/operator-training.json"
  jq -e '
    .schema_version == "1.0" and .trained_operators >= 2 and
    .incident_runbook_exercise_passed == true and .restore_observation_completed == true and
    .independent_production_approval_enabled == true and
    (.completed_at | type == "string" and length > 0) and
    (.evidence_owner | type == "string" and length > 0)
  ' "$report" >/dev/null || die "Operator training evidence does not satisfy the client-two gate."
  digest="$(sha256sum "$report" | awk '{print $1}')"
  read -r -p "Type ACCEPT OPERATOR TRAINING $digest after reviewing the evidence: " confirmation
  [[ "$confirmation" == "ACCEPT OPERATOR TRAINING $digest" ]] || die "Operator training acceptance cancelled."
  gh variable set OPERATOR_TRAINING_SHA256 --repo "$REPO" --env production --body "$digest"
  printf 'Second-operator training evidence recorded: %s\n' "$digest"
}

accept_security() {
  local report="${1:-}" digest confirmation
  [[ -r "$report" ]] || die "Usage: $0 accept-security /secure/security-acceptance.json"
  jq -e '
    .schema_version == "1.0" and .tenants_tested >= 2 and
    .cross_tenant_endpoint_tests_passed == true and .postgres_rls_direct_access_denied == true and
    .forged_oidc_rejected == true and .replayed_device_nonces_rejected == true and
    .owasp_masvs_review_completed == true and .owasp_api_review_completed == true and
    (.unresolved_critical_findings | type == "number") and .unresolved_critical_findings == 0 and
    (.unresolved_high_findings | type == "number") and .unresolved_high_findings == 0 and
    (.completed_at | type == "string") and (try (.completed_at | fromdateiso8601) catch null) != null and
    (.evidence_owner | type == "string" and length > 0) and
    (.evidence_artifacts | type == "array" and length > 0) and
    all(.evidence_artifacts[];
      (.name | type == "string" and length > 0) and
      (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ([.evidence_artifacts[].name] | unique | length) == (.evidence_artifacts | length)
  ' "$report" >/dev/null || die "Security evidence does not satisfy the production gate."
  digest="$(sha256sum "$report" | awk '{print $1}')"
  read -r -p "Type ACCEPT SECURITY $digest after reviewing the evidence: " confirmation
  [[ "$confirmation" == "ACCEPT SECURITY $digest" ]] || die "Security acceptance cancelled."
  gh variable set SECURITY_ACCEPTANCE_SHA256 --repo "$REPO" --env production --body "$digest"
  printf 'Security acceptance evidence recorded: %s\n' "$digest"
}

accept_capacity() {
  local report="${1:-}" digest confirmation
  [[ -r "$report" ]] || die "Usage: $0 accept-capacity /secure/capacity-acceptance.json"
  jq -e '
    .schema_version == "1.0" and
    (.receipts_per_day | type == "number") and .receipts_per_day >= 1000 and
    (.reconnecting_devices | type == "number") and .reconnecting_devices >= 100 and
    (.reconnect_window_minutes | type == "number") and .reconnect_window_minutes >= 0 and .reconnect_window_minutes <= 10 and
    (.final_ack_p95_ms | type == "number") and .final_ack_p95_ms >= 0 and .final_ack_p95_ms < 2000 and
    (.backlog_drain_minutes | type == "number") and .backlog_drain_minutes >= 0 and .backlog_drain_minutes <= 15 and
    (.lost_receipts | type == "number") and .lost_receipts == 0 and
    (.duplicate_receipts | type == "number") and .duplicate_receipts == 0 and
    (.acceptance_network_profile | type == "string" and length > 0) and
    (.completed_at | type == "string") and (try (.completed_at | fromdateiso8601) catch null) != null and
    (.evidence_owner | type == "string" and length > 0) and
    (.evidence_artifacts | type == "array" and length > 0) and
    all(.evidence_artifacts[];
      (.name | type == "string" and length > 0) and
      (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ([.evidence_artifacts[].name] | unique | length) == (.evidence_artifacts | length)
  ' "$report" >/dev/null || die "Capacity evidence does not satisfy the production gate."
  digest="$(sha256sum "$report" | awk '{print $1}')"
  read -r -p "Type ACCEPT CAPACITY $digest after reviewing the evidence: " confirmation
  [[ "$confirmation" == "ACCEPT CAPACITY $digest" ]] || die "Capacity acceptance cancelled."
  gh variable set CAPACITY_ACCEPTANCE_SHA256 --repo "$REPO" --env production --body "$digest"
  printf 'Capacity acceptance evidence recorded: %s\n' "$digest"
}

accept_recovery() {
  local report="${1:-}" digest confirmation
  [[ -r "$report" ]] || die "Usage: $0 accept-recovery /secure/recovery-acceptance.json"
  jq -e '
    .schema_version == "1.0" and .postgres_restore_passed == true and .s3_restore_passed == true and
    (.rpo_minutes | type == "number") and .rpo_minutes >= 0 and .rpo_minutes <= 60 and
    (.rto_minutes | type == "number") and .rto_minutes >= 0 and .rto_minutes <= 480 and
    .rollback_passed == true and
    .alarm_delivery_passed == true and .cross_account_snapshot_verified == true and
    (.completed_at | type == "string") and (try (.completed_at | fromdateiso8601) catch null) != null and
    (.evidence_owner | type == "string" and length > 0) and
    (.evidence_artifacts | type == "array" and length > 0) and
    all(.evidence_artifacts[];
      (.name | type == "string" and length > 0) and
      (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ([.evidence_artifacts[].name] | unique | length) == (.evidence_artifacts | length)
  ' "$report" >/dev/null || die "Recovery evidence does not satisfy the RPO/RTO production gate."
  digest="$(sha256sum "$report" | awk '{print $1}')"
  read -r -p "Type ACCEPT RECOVERY $digest after reviewing the evidence: " confirmation
  [[ "$confirmation" == "ACCEPT RECOVERY $digest" ]] || die "Recovery acceptance cancelled."
  gh variable set RECOVERY_ACCEPTANCE_SHA256 --repo "$REPO" --env production --body "$digest"
  printf 'Recovery acceptance evidence recorded: %s\n' "$digest"
}

set_play_track() {
  preflight
  local track="${1:-}" confirmation
  [[ "$track" == "internal" || "$track" == "alpha" || "$track" == "production" ]] || die "Usage: $0 set-play-track internal|alpha|production"
  if [[ "$track" == "production" ]]; then
    [[ "$(github_environment_variable CLIENT_ACCEPTANCE_SHA256)" =~ ^[a-f0-9]{64}$ ]] || die "Production track requires signed client acceptance evidence."
  fi
  read -r -p "Type SET PLAY TRACK $track to change the next release track: " confirmation
  [[ "$confirmation" == "SET PLAY TRACK $track" ]] || die "Play track unchanged."
  gh variable set PLAY_RELEASE_TRACK --repo "$REPO" --env production --body "$track"
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  printf 'Next Managed Google Play release track: %s\n' "$track"
}

rotate_enrichment_keys() {
  preflight
  need aws
  local mode="${1:-}" runtime_secret_arn runtime_json updated_runtime confirmation timestamp
  local edge_key_id edge_key edge_next_key_id edge_next_key service_key_id service_key service_next_key_id service_next_key
  [[ "$mode" == "stage" || "$mode" == "promote" ]] || die "Usage: $0 rotate-enrichment-keys stage|promote"
  runtime_secret_arn="$(github_environment_variable AWS_RUNTIME_SECRET_ARN)"
  [[ -n "$runtime_secret_arn" ]] || die "AWS_RUNTIME_SECRET_ARN is missing from the production environment."
  runtime_json="$(aws secretsmanager get-secret-value --secret-id "$runtime_secret_arn" --query SecretString --output text)"
  jq -e '[.EDGE_TO_ENRICHMENT_HMAC_KEY_ID,.EDGE_TO_ENRICHMENT_HMAC_KEY,.EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID,.EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY,.ENRICHMENT_TO_EDGE_HMAC_KEY_ID,.ENRICHMENT_TO_EDGE_HMAC_KEY,.ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID,.ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY] | all(type == "string" and length > 0)' >/dev/null <<<"$runtime_json" || die "AWS runtime secret does not contain a complete active/next directional key set."
  edge_key_id="$(jq -r .EDGE_TO_ENRICHMENT_HMAC_KEY_ID <<<"$runtime_json")"
  edge_key="$(jq -r .EDGE_TO_ENRICHMENT_HMAC_KEY <<<"$runtime_json")"
  edge_next_key_id="$(jq -r .EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID <<<"$runtime_json")"
  edge_next_key="$(jq -r .EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY <<<"$runtime_json")"
  service_key_id="$(jq -r .ENRICHMENT_TO_EDGE_HMAC_KEY_ID <<<"$runtime_json")"
  service_key="$(jq -r .ENRICHMENT_TO_EDGE_HMAC_KEY <<<"$runtime_json")"
  service_next_key_id="$(jq -r .ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID <<<"$runtime_json")"
  service_next_key="$(jq -r .ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY <<<"$runtime_json")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ "$mode" == "stage" ]]; then
    read -r -p 'Type STAGE ENRICHMENT KEYS to generate replacement next keys: ' confirmation
    [[ "$confirmation" == "STAGE ENRICHMENT KEYS" ]] || die "Enrichment key staging cancelled."
    edge_next_key_id="edge-${timestamp}-next"
    edge_next_key="$(openssl rand -hex 32)"
    service_next_key_id="service-${timestamp}-next"
    service_next_key="$(openssl rand -hex 32)"
  else
    read -r -p 'Type PROMOTE ENRICHMENT KEYS to swap active and next keys: ' confirmation
    [[ "$confirmation" == "PROMOTE ENRICHMENT KEYS" ]] || die "Enrichment key promotion cancelled."
    local previous_edge_key_id="$edge_key_id" previous_edge_key="$edge_key" previous_service_key_id="$service_key_id" previous_service_key="$service_key"
    edge_key_id="$edge_next_key_id"; edge_key="$edge_next_key"; edge_next_key_id="$previous_edge_key_id"; edge_next_key="$previous_edge_key"
    service_key_id="$service_next_key_id"; service_key="$service_next_key"; service_next_key_id="$previous_service_key_id"; service_next_key="$previous_service_key"
  fi
  updated_runtime="$(jq -c \
    --arg edge_key_id "$edge_key_id" --arg edge_key "$edge_key" --arg edge_next_key_id "$edge_next_key_id" --arg edge_next_key "$edge_next_key" \
    --arg service_key_id "$service_key_id" --arg service_key "$service_key" --arg service_next_key_id "$service_next_key_id" --arg service_next_key "$service_next_key" \
    '. + {EDGE_TO_ENRICHMENT_HMAC_KEY_ID:$edge_key_id,EDGE_TO_ENRICHMENT_HMAC_KEY:$edge_key,EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID:$edge_next_key_id,EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY:$edge_next_key,ENRICHMENT_TO_EDGE_HMAC_KEY_ID:$service_key_id,ENRICHMENT_TO_EDGE_HMAC_KEY:$service_key,ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID:$service_next_key_id,ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY:$service_next_key}' <<<"$runtime_json")"
  aws secretsmanager put-secret-value --secret-id "$runtime_secret_arn" --secret-string "$updated_runtime" >/dev/null
  printf '%s' "$edge_key" | gh secret set EDGE_TO_ENRICHMENT_HMAC_KEY --repo "$REPO" --env production
  printf '%s' "$edge_next_key" | gh secret set EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY --repo "$REPO" --env production
  printf '%s' "$service_key" | gh secret set ENRICHMENT_TO_EDGE_HMAC_KEY --repo "$REPO" --env production
  printf '%s' "$service_next_key" | gh secret set ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY --repo "$REPO" --env production
  gh variable set EDGE_TO_ENRICHMENT_HMAC_KEY_ID --repo "$REPO" --env production --body "$edge_key_id"
  gh variable set EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID --repo "$REPO" --env production --body "$edge_next_key_id"
  gh variable set ENRICHMENT_TO_EDGE_HMAC_KEY_ID --repo "$REPO" --env production --body "$service_key_id"
  gh variable set ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID --repo "$REPO" --env production --body "$service_next_key_id"
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  unset edge_key edge_next_key service_key service_next_key runtime_json updated_runtime
  printf 'Directional enrichment keys %sd. Production remains disabled; deploy the overlap set before the next phase.\n' "$mode"
}

validate_aws_budget_inputs() {
  [[ "$AWS_PRODUCTION_MONTHLY_BUDGET_USD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Production monthly budget must be numeric."
  [[ "$AWS_STAGING_MONTHLY_BUDGET_USD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Staging monthly budget must be numeric."
  awk -v value="$AWS_PRODUCTION_MONTHLY_BUDGET_USD" 'BEGIN { exit !(value > 0 && value <= 350) }' || die "Production budget exceeds the approved USD 350 ceiling."
  awk -v value="$AWS_STAGING_MONTHLY_BUDGET_USD" 'BEGIN { exit !(value > 0 && value <= 225) }' || die "Staging budget exceeds the approved USD 225 ceiling."
  [[ "$AWS_BUDGET_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Primary AWS budget email is invalid."
  [[ "$AWS_SECONDARY_BUDGET_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Secondary AWS budget email is invalid."
  [[ "${AWS_BUDGET_EMAIL,,}" != "${AWS_SECONDARY_BUDGET_EMAIL,,}" ]] || die "AWS budget notifications require two different operator emails."
}

configure_aws() {
  preflight
  local variables name label value
  variables='AWS_PRODUCTION_ACCOUNT_ID AWS_PRODUCTION_TERRAFORM_ROLE_ARN AWS_ECR_REPOSITORY AWS_ADOT_COLLECTOR_IMAGE AWS_CLOUDFLARED_IMAGE AWS_PRIVATE_ALB_CERTIFICATE_ARN AWS_TERRAFORM_STATE_BUCKET AWS_TERRAFORM_STATE_KMS_KEY_ARN AWS_BACKUP_DESTINATION_VAULT_ARN AWS_PRODUCTION_MONTHLY_BUDGET_USD AWS_STAGING_MONTHLY_BUDGET_USD AWS_BUDGET_EMAIL AWS_SECONDARY_BUDGET_EMAIL AWS_GITHUB_OIDC_PROVIDER_ARN'
  for name in $variables; do
    label="${name//_/ }"
    prompt_value "$name" "$label"
  done
  validate_aws_budget_inputs
  for name in $variables; do
    value="${!name}"
    gh variable set "$name" --repo "$REPO" --env production --body "$value"
  done
  gh variable set AWS_ENRICHMENT_BOOTSTRAPPED --repo "$REPO" --env production --body false
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  printf '%s\n' 'AWS deployment variables are configured. Run the Terraform bootstrap with services_enabled=false, populate the AWS runtime secret, then set AWS_ENRICHMENT_BOOTSTRAPPED=true.'
}

configure_tunnel_origin() {
  preflight
  cloudflare_login
  local tunnel_id private_origin_url current_config existing_config body response configured_service configured_server_name
  prompt_value CLOUDFLARE_TUNNEL_ID "Cloudflare Tunnel ID"
  prompt_value AWS_PRIVATE_ORIGIN_URL "Terraform private_origin_url output"
  tunnel_id="$CLOUDFLARE_TUNNEL_ID"
  private_origin_url="$AWS_PRIVATE_ORIGIN_URL"
  [[ "$tunnel_id" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Cloudflare Tunnel ID must be a UUID."
  [[ "$private_origin_url" =~ ^https://[A-Za-z0-9.-]+\.elb\.amazonaws\.com$ ]] || die "Private origin must be the Terraform HTTPS ALB output."
  current_config="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations")"
  existing_config="$(jq -c '.result.config // {}' <<<"$current_config")"
  body="$(jq -nc --argjson existing "$existing_config" --arg service "$private_origin_url" '
    $existing
    | .ingress = (
        [(.ingress // [])[] | select((.hostname // "") != "api.challanse.constrovet.com" and ((.service // "") | startswith("http_status:") | not))]
        + [{hostname:"api.challanse.constrovet.com",service:$service,originRequest:{originServerName:"api.challanse.constrovet.com",noTLSVerify:false}},{service:"http_status:404"}]
      )
    | {config:.}
  ')"
  response="$(cf PUT "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" "$body")"
  configured_service="$(jq -r '.result.config.ingress[0].service // empty' <<<"$response")"
  configured_server_name="$(jq -r '.result.config.ingress[0].originRequest.originServerName // empty' <<<"$response")"
  [[ "$configured_service" == "$private_origin_url" && "$configured_server_name" == "api.challanse.constrovet.com" ]] || die "Cloudflare Tunnel did not retain the verified HTTPS origin configuration."
  gh variable set CLOUDFLARE_TUNNEL_ID --repo "$REPO" --env production --body "$tunnel_id"
  gh variable set AWS_PRIVATE_ORIGIN_URL --repo "$REPO" --env production --body "$private_origin_url"
  gh variable set CLOUDFLARE_TUNNEL_ORIGIN_TLS_VERIFIED --repo "$REPO" --env production --body true
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  unset CLOUDFLARE_API_TOKEN AWS_PRIVATE_ORIGIN_URL
  printf '%s\n' 'Cloudflare Tunnel now validates the private ALB certificate for api.challanse.constrovet.com. Production remains disabled.'
}

rotate_signing() {
  preflight
  command -v keytool >/dev/null 2>&1 || die "keytool is required. On Ubuntu run: sudo apt update && sudo apt install -y openjdk-17-jdk-headless"
  load_state
  local old_keystore="${SIGNING_KEYSTORE_PATH:-}" old_fingerprint="${SIGNING_CERT_SHA256:-}" keystore password password_confirm fingerprint encoded confirmation backup_dir backup_path backup_password backup_password_confirm
  [[ -n "$old_keystore" && -n "$old_fingerprint" ]] || die "Existing signing state is missing. Run configure-github instead."
  if [[ -n "$(release_keystore_paths_in_history "$ROOT")" ]]; then
    die "A release keystore path exists in Git history. Remove it from history and rotate any affected credentials before continuing."
  fi
  if [[ -n "$(release_keystore_paths_in_worktree "$ROOT")" ]]; then
    die "A release keystore exists inside the repository working tree. Remove it securely before continuing."
  fi
  printf 'Exposed signing certificate SHA-256: %s\n' "$old_fingerprint"
  read -r -p 'Type ROTATE EXPOSED SIGNING KEY to continue: ' confirmation
  [[ "$confirmation" == "ROTATE EXPOSED SIGNING KEY" ]] || die "Signing rotation cancelled."
  keystore="${STATE_DIR}/challanse-release-$(date -u +%Y%m%dT%H%M%SZ).jks"
  validate_new_keystore_path "$keystore"
  printf 'Replacement keystore will be created at: %s\n' "$keystore"
  read -r -s -p "New Android keystore/key password: " password; printf '\n'
  read -r -s -p "Repeat new Android password: " password_confirm; printf '\n'
  [[ -n "$password" && "$password" == "$password_confirm" ]] || die "Android passwords do not match."
  keytool -genkeypair -v -keystore "$keystore" -alias challanse -keyalg RSA -keysize 4096 -validity 10000 -storepass "$password" -keypass "$password" -dname 'CN=ChallanSe, O=Constrovet, C=IN' >/dev/null
  chmod 600 "$keystore"
  fingerprint="$(signing_fingerprint "$keystore" "$password")"
  [[ "$fingerprint" =~ ^[0-9A-F]{64}$ && "$fingerprint" != "$old_fingerprint" ]] || die "Replacement signing identity is invalid or unchanged."
  read -r -p "Mounted offline-backup directory (outside this repository): " backup_dir
  backup_dir="$(realpath -e "$backup_dir")"
  [[ -d "$backup_dir" && -w "$backup_dir" && "$backup_dir" != "$ROOT"/* && "$backup_dir" != "$STATE_DIR"/* ]] || die "Backup directory must exist, be writable, and be outside the repository and live key directory."
  backup_path="$backup_dir/$(basename "$keystore").enc"
  [[ ! -e "$backup_path" ]] || die "Encrypted backup already exists: $backup_path"
  read -r -s -p "Separate offline-backup password: " backup_password; printf '\n'
  read -r -s -p "Repeat offline-backup password: " backup_password_confirm; printf '\n'
  [[ -n "$backup_password" && "$backup_password" == "$backup_password_confirm" && "$backup_password" != "$password" ]] || die "Backup passwords do not match or reuse the signing password."
  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -in "$keystore" -out "$backup_path" -pass fd:3 3<<<"$backup_password"
  chmod 600 "$backup_path"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$backup_path" -pass fd:3 3<<<"$backup_password" | cmp -s - "$keystore" || die "Encrypted signing backup verification failed."
  encoded="$(base64 -w0 "$keystore")"
  printf '%s' "$encoded" | gh secret set CHALLANSE_KEYSTORE_BASE64 --repo "$REPO" --env production
  printf '%s' "$password" | gh secret set CHALLANSE_KEYSTORE_PASSWORD --repo "$REPO" --env production
  printf '%s' challanse | gh secret set CHALLANSE_KEY_ALIAS --repo "$REPO" --env production
  printf '%s' "$password" | gh secret set CHALLANSE_KEY_PASSWORD --repo "$REPO" --env production
  gh variable set CHALLANSE_REVOKED_SIGNING_CERT_SHA256 --repo "$REPO" --env production --body "$old_fingerprint"
  gh variable set CHALLANSE_UPLOAD_CERT_SHA256 --repo "$REPO" --env production --body "$fingerprint"
  save_state SIGNING_KEYSTORE_PATH "$keystore"
  save_state SIGNING_CERT_SHA256 "$fingerprint"
  save_state SIGNING_ENCRYPTED_BACKUP_PATH "$backup_path"
  if [[ -f "$old_keystore" ]]; then shred -u -- "$old_keystore"; fi
  unset password password_confirm backup_password backup_password_confirm encoded CLOUDFLARE_API_TOKEN
  printf 'Signing identity rotated. New certificate SHA-256: %s\nLive key: %s\nVerified encrypted offline backup: %s\nStore the backup password separately and never open a .jks file in an editor.\n' "$fingerprint" "$keystore" "$backup_path"
}

deploy() {
  preflight
  local required_secrets required_variables run_id pending ids body deployment_flag commit_sha confirmation github_fingerprint organization_count protection required_approvals
  required_secrets='["CLOUDFLARE_ACCOUNT_ID","CLOUDFLARE_API_TOKEN","DEVICE_TOKEN_PEPPER","TURNSTILE_SECRET","CHALLANSE_KEYSTORE_BASE64","CHALLANSE_KEYSTORE_PASSWORD","CHALLANSE_KEY_ALIAS","CHALLANSE_KEY_PASSWORD","PLAY_SERVICE_ACCOUNT_JSON","PLAY_MANAGED_ORGANIZATION_IDS","EDGE_TO_ENRICHMENT_HMAC_KEY","EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY","ENRICHMENT_TO_EDGE_HMAC_KEY","ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY","ENRICHMENT_ACCESS_CLIENT_ID","ENRICHMENT_ACCESS_CLIENT_SECRET"]'
  required_variables='["CLOUDFLARE_ACCESS_TEAM_DOMAIN","CLOUDFLARE_ACCESS_AUD","CLOUDFLARE_FREE_WAF_ENABLED","ACCESS_IDENTITY_PROVIDER_ID","ACCESS_MFA_ENFORCED","TURNSTILE_SITE_KEY","CHALLANSE_UPLOAD_CERT_SHA256","CHALLANSE_PLAY_APP_SIGNING_CERT_SHA256","CHALLANSE_REVOKED_SIGNING_CERT_SHA256","PLAY_PUBLISH_ENABLED","PLAY_INTEGRITY_CLOUD_PROJECT_NUMBER","PLAY_MANAGED_ORGANIZATIONS_SHA256","PLAY_MANAGED_ORGANIZATIONS_COUNT","PLAY_RELEASE_TRACK","ENRICHMENT_URL","EDGE_TO_ENRICHMENT_HMAC_KEY_ID","EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID","ENRICHMENT_TO_EDGE_HMAC_KEY_ID","ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID","AWS_PRODUCTION_ACCOUNT_ID","AWS_PRODUCTION_TERRAFORM_ROLE_ARN","AWS_ECR_REPOSITORY","AWS_ADOT_COLLECTOR_IMAGE","AWS_CLOUDFLARED_IMAGE","AWS_PRIVATE_ALB_CERTIFICATE_ARN","AWS_TERRAFORM_STATE_BUCKET","AWS_TERRAFORM_STATE_KMS_KEY_ARN","AWS_BACKUP_DESTINATION_VAULT_ARN","AWS_PRODUCTION_MONTHLY_BUDGET_USD","AWS_STAGING_MONTHLY_BUDGET_USD","AWS_BUDGET_EMAIL","AWS_SECONDARY_BUDGET_EMAIL","AWS_GITHUB_OIDC_PROVIDER_ARN","AWS_RUNTIME_SECRET_ARN","AWS_DEAD_LETTER_QUEUE_URL","AWS_ENRICHMENT_BOOTSTRAPPED","CLOUDFLARE_TUNNEL_ID","AWS_PRIVATE_ORIGIN_URL","CLOUDFLARE_TUNNEL_ORIGIN_TLS_VERIFIED","STAGING_ACCEPTANCE_SHA256","ANDROID_FIELD_ACCEPTANCE_SHA256","SECURITY_ACCEPTANCE_SHA256","CAPACITY_ACCEPTANCE_SHA256","RECOVERY_ACCEPTANCE_SHA256"]'
  jq -e --argjson required "$required_secrets" '($required - [.[].name]) | length == 0' >/dev/null < <(gh secret list --repo "$REPO" --env production --json name) || die "Required production secrets are missing."
  jq -e --argjson required "$required_variables" '($required - [.[].name]) | length == 0' >/dev/null < <(gh variable list --repo "$REPO" --env production --json name) || die "Required production variables are missing."
  local revoked_fingerprint
  revoked_fingerprint="$(github_environment_variable CHALLANSE_REVOKED_SIGNING_CERT_SHA256)"
  github_fingerprint="$(github_environment_variable CHALLANSE_UPLOAD_CERT_SHA256)"
  [[ -n "$revoked_fingerprint" && -n "$github_fingerprint" && "$revoked_fingerprint" != "$github_fingerprint" ]] || die "Rotate the exposed Android signing identity before deployment: ./scripts/go-live.sh rotate-signing"
  [[ "$(github_environment_variable ACCESS_MFA_ENFORCED)" == "true" ]] || die "Enterprise OIDC with MFA is not enforced. Run: ./scripts/go-live.sh configure-identity"
  [[ "$(github_environment_variable CLOUDFLARE_FREE_WAF_ENABLED)" == "true" ]] || die "Cloudflare Free Managed Ruleset is not recorded as enabled. Rerun provision."
  [[ "$(github_environment_variable CLOUDFLARE_TUNNEL_ORIGIN_TLS_VERIFIED)" == "true" ]] || die "Cloudflare Tunnel origin TLS is not verified. Run configure-tunnel-origin after the private ALB exists."
  assert_free_managed_waf
  [[ "$(github_environment_variable PLAY_PUBLISH_ENABLED)" == "true" ]] || die "Managed Google Play publishing remains disabled. Run configure-play after Play Console setup."
  [[ "$(github_environment_variable PLAY_RELEASE_TRACK)" =~ ^(internal|alpha|production)$ ]] || die "Managed Google Play release track is invalid."
  organization_count="$(github_environment_variable PLAY_MANAGED_ORGANIZATIONS_COUNT)"
  [[ "$organization_count" =~ ^[1-9][0-9]*$ ]] || die "Managed Google Play organization count is invalid."
  if [[ "$organization_count" -gt 1 ]]; then
    [[ "$(github_environment_variable OPERATOR_TRAINING_SHA256)" =~ ^[a-f0-9]{64}$ ]] || die "Client two requires accepted second-operator training evidence. Run: ./scripts/go-live.sh accept-operator-training /secure/operator-training.json"
    protection="$(gh api "repos/$REPO/branches/main/protection")"
    required_approvals="$(jq -r '.required_pull_request_reviews.required_approving_review_count // 0' <<<"$protection")"
    [[ "$required_approvals" -ge 1 && "$(jq -r '.enforce_admins.enabled // false' <<<"$protection")" == "true" ]] || die "Client two requires one independent PR approval with administrator enforcement. Add a second maintainer and rerun harden-github."
  fi
  if [[ "$(github_environment_variable PLAY_RELEASE_TRACK)" == "production" ]]; then
    [[ "$(github_environment_variable CLIENT_ACCEPTANCE_SHA256)" =~ ^[a-f0-9]{64}$ ]] || die "Production Play track requires signed client acceptance evidence."
  fi
  [[ "$(github_environment_variable STAGING_ACCEPTANCE_SHA256)" =~ ^[a-f0-9]{64}$ ]] || die "Staging acceptance evidence is missing or malformed."
  [[ "$(github_environment_variable ANDROID_FIELD_ACCEPTANCE_SHA256)" =~ ^[a-f0-9]{64}$ ]] || die "Android field acceptance evidence is missing or malformed."
  [[ "$(github_environment_variable SECURITY_ACCEPTANCE_SHA256)" =~ ^[a-f0-9]{64}$ ]] || die "Security acceptance evidence is missing or malformed."
  [[ "$(github_environment_variable CAPACITY_ACCEPTANCE_SHA256)" =~ ^[a-f0-9]{64}$ ]] || die "Capacity acceptance evidence is missing or malformed."
  [[ "$(github_environment_variable RECOVERY_ACCEPTANCE_SHA256)" =~ ^[a-f0-9]{64}$ ]] || die "Recovery acceptance evidence is missing or malformed."
  [[ "$(github_environment_variable AWS_ENRICHMENT_BOOTSTRAPPED)" == "true" ]] || die "AWS enrichment is not bootstrapped. Keep services stopped, populate the runtime secret, validate staging, then set AWS_ENRICHMENT_BOOTSTRAPPED=true."
  deployment_flag="$(gh variable list --repo "$REPO" --json name,value --jq '.[] | select(.name == "PILOT_DEPLOY_ENABLED") | .value')"
  [[ "$deployment_flag" == "false" ]] || die "PILOT_DEPLOY_ENABLED must be false before deployment. Run rollback-production.sh first."
  load_state
  github_fingerprint="$(github_environment_variable CHALLANSE_UPLOAD_CERT_SHA256)"
  [[ -n "${SIGNING_CERT_SHA256:-}" && "$github_fingerprint" == "$SIGNING_CERT_SHA256" ]] || die "Signing fingerprint is missing or inconsistent. Rerun configure-github."
  commit_sha="$(git rev-parse HEAD)"
  printf 'Production commit: %s\nSigning certificate SHA-256: %s\n' "$commit_sha" "$github_fingerprint"
  read -r -p "Type DEPLOY $commit_sha to continue: " confirmation
  [[ "$confirmation" == "DEPLOY $commit_sha" ]] || die "Deployment cancelled."
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body true
  trap 'gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false >/dev/null 2>&1 || true' EXIT
  gh workflow run "$WORKFLOW" --repo "$REPO" --ref main
  sleep 5
  run_id="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --event workflow_dispatch --branch main --limit 1 --json databaseId --jq '.[0].databaseId')"
  [[ -n "$run_id" ]] || die "Could not find dispatched workflow run."
  for _ in $(seq 1 90); do
    pending="$(gh api "repos/$REPO/actions/runs/$run_id/pending_deployments")"
    if [[ "$(jq 'length' <<<"$pending")" -gt 0 ]]; then
      ids="$(jq '[.[].environment.id]' <<<"$pending")"
      body="$(jq -nc --argjson ids "$ids" '{environment_ids:$ids,state:"approved",comment:"Approved by guarded ChallanSe production CLI"}')"
      gh api --method POST "repos/$REPO/actions/runs/$run_id/pending_deployments" --input - <<<"$body" >/dev/null
      break
    fi
    [[ "$(gh run view "$run_id" --repo "$REPO" --json status --jq .status)" == "completed" ]] && break
    sleep 10
  done
  gh run watch "$run_id" --repo "$REPO" --exit-status
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  trap - EXIT
  save_state LAST_DEPLOY_RUN_ID "$run_id"
  save_state LAST_DEPLOY_COMMIT_SHA "$commit_sha"
  printf 'Production workflow completed successfully: https://github.com/%s/actions/runs/%s\n' "$REPO" "$run_id"
}

accept_staging() {
  local report="${1:-}"
  [[ -r "$report" ]] || die "Usage: $0 accept-staging /secure/staging-acceptance.json"
  jq -e '
    .schema_version == "1.0" and
    (.synthetic_receipts | type == "number") and .synthetic_receipts >= 20 and
    (.lost_receipts | type == "number") and .lost_receipts == 0 and
    (.duplicate_receipts | type == "number") and .duplicate_receipts == 0 and
    .cross_site_access_denied == true and .callback_replay_denied == true and
    .dlq_replay_passed == true and .rollback_passed == true and
    (.completed_at | type == "string") and (try (.completed_at | fromdateiso8601) catch null) != null and
    (.evidence_owner | type == "string" and length > 0) and
    (.evidence_artifacts | type == "array" and length > 0) and
    all(.evidence_artifacts[];
      (.name | type == "string" and length > 0) and
      (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ([.evidence_artifacts[].name] | unique | length) == (.evidence_artifacts | length)
  ' "$report" >/dev/null || die "Staging report does not satisfy the required release gates."
  local digest confirmation
  digest="$(sha256sum "$report" | awk '{print $1}')"
  read -r -p "Type ACCEPT STAGING $digest after reviewing the report: " confirmation
  [[ "$confirmation" == "ACCEPT STAGING $digest" ]] || die "Staging acceptance cancelled."
  gh variable set STAGING_ACCEPTANCE_SHA256 --repo "$REPO" --env production --body "$digest"
  printf 'Staging acceptance evidence recorded: %s\n' "$digest"
}

accept_android_field() {
  local report="${1:-}"
  [[ -r "$report" ]] || die "Usage: $0 accept-android-field /secure/android-field-acceptance.json"
  jq -e '
    .schema_version == "1.0" and
    (.android_api_level | type == "number") and .android_api_level == 26 and
    (.device_ram_mb | type == "number") and .device_ram_mb > 0 and .device_ram_mb <= 2048 and
    (.binary_writes | type == "number") and .binary_writes >= 100 and
    (.minimum_image_bytes | type == "number") and .minimum_image_bytes > 0 and .minimum_image_bytes <= 500000 and
    (.maximum_image_bytes | type == "number") and .maximum_image_bytes >= 5000000 and
    (.p95_write_ms | type == "number") and .p95_write_ms >= 0 and .p95_write_ms < 50 and
    (.metadata_loss_count | type == "number") and .metadata_loss_count == 0 and
    .sqlcipher_status_verified == true and .wrong_key_rejected == true and
    .raw_database_scan_clean == true and .restart_recovery_passed == true and .reboot_sync_passed == true and
    .interrupted_upload_resume_passed == true and
    (.completed_at | type == "string") and (try (.completed_at | fromdateiso8601) catch null) != null and
    (.evidence_owner | type == "string" and length > 0) and
    (.evidence_artifacts | type == "array" and length > 0) and
    all(.evidence_artifacts[];
      (.name | type == "string" and length > 0) and
      (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ([.evidence_artifacts[].name] | unique | length) == (.evidence_artifacts | length)
  ' "$report" >/dev/null || die "Android field report does not satisfy encryption, durability, and p95 gates."
  local digest confirmation
  digest="$(sha256sum "$report" | awk '{print $1}')"
  read -r -p "Type ACCEPT ANDROID $digest after reviewing device evidence: " confirmation
  [[ "$confirmation" == "ACCEPT ANDROID $digest" ]] || die "Android field acceptance cancelled."
  gh variable set ANDROID_FIELD_ACCEPTANCE_SHA256 --repo "$REPO" --env production --body "$digest"
  printf 'Android field acceptance evidence recorded: %s\n' "$digest"
}

rotate_device_pepper() {
  preflight
  need aws
  need cloudflared
  local access_token context organization_id site_id confirmation pepper runtime_secret_arn runtime_json updated_runtime revoke_response
  printf '%s\n' 'WARNING: This revokes every enrolled Android device. Each device must be enrolled again; locally queued receipts remain on the devices.'
  read -r -p 'Site UUID used to authorize this organization-wide operation: ' site_id
  [[ "$site_id" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Site ID must be a UUID."
  access_token="$(cloudflared access token --app=https://review.challanse.constrovet.com)"
  [[ -n "$access_token" ]] || die "Could not obtain a Cloudflare Access token. Sign in as an ORG_ADMIN and retry."
  context="$(curl -fsS -H "Cookie: CF_Authorization=$access_token" -H "X-ChallanSe-Site-Id: $site_id" https://review.challanse.constrovet.com/api/v1/reviewer/context)" || die "Could not resolve the authenticated organization context."
  organization_id="$(jq -r '.organizationId // empty' <<<"$context")"
  [[ "$organization_id" =~ ^[0-9a-fA-F-]{36}$ ]] || die "The reviewer context did not return an organization UUID."
  read -r -p "Type ROTATE DEVICE PEPPER $organization_id to continue: " confirmation
  [[ "$confirmation" == "ROTATE DEVICE PEPPER $organization_id" ]] || die "Device credential rotation cancelled."
  revoke_response="$(curl -fsS -X POST \
    -H "Cookie: CF_Authorization=$access_token" \
    -H "X-ChallanSe-Site-Id: $site_id" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg confirmation "REVOKE ALL DEVICES $organization_id" '{confirmation:$confirmation}')" \
    https://review.challanse.constrovet.com/api/v1/admin/devices/revoke-all)" || die "Device revocation failed; the pepper was not changed."
  jq -e '.revoked | type == "number" and . >= 0' >/dev/null <<<"$revoke_response" || die "Device revocation returned an invalid response; the pepper was not changed."
  runtime_secret_arn="$(github_environment_variable AWS_RUNTIME_SECRET_ARN)"
  [[ -n "$runtime_secret_arn" ]] || die "AWS_RUNTIME_SECRET_ARN is missing from the production environment."
  runtime_json="$(aws secretsmanager get-secret-value --secret-id "$runtime_secret_arn" --query SecretString --output text)"
  pepper="$(openssl rand -hex 32)"
  updated_runtime="$(jq -c --arg pepper "$pepper" '.DEVICE_TOKEN_PEPPER=$pepper' <<<"$runtime_json")"
  printf '%s' "$updated_runtime" | aws secretsmanager put-secret-value --secret-id "$runtime_secret_arn" --secret-string file:///dev/stdin >/dev/null
  printf '%s' "$pepper" | gh secret set DEVICE_TOKEN_PEPPER --repo "$REPO" --env production
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  unset access_token context revoke_response pepper runtime_json updated_runtime CLOUDFLARE_API_TOKEN
  printf 'Device pepper rotated after revoking all organization devices. Re-enroll devices before syncing; local queues were not deleted.\n'
}

replay_dlq() {
  need aws
  need jq
  local queue_url queue_arn count confirmation task
  queue_url="$(github_environment_variable AWS_DEAD_LETTER_QUEUE_URL)"
  [[ -n "$queue_url" ]] || prompt_value queue_url "AWS receipt dead-letter queue URL"
  queue_arn="$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
  count="$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text)"
  [[ "$queue_arn" == arn:aws:sqs:ap-south-1:*:challanse-production-receipts-dlq ]] || die "DLQ ARN is not the expected ChallanSe production queue."
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || die "The ChallanSe dead-letter queue has no visible messages."
  printf 'Dead-letter messages available: %s\n' "$count"
  read -r -p "Type REPLAY DLQ $count to redrive them through idempotent processing: " confirmation
  [[ "$confirmation" == "REPLAY DLQ $count" ]] || die "DLQ replay cancelled."
  task="$(aws sqs start-message-move-task --source-arn "$queue_arn" --max-number-of-messages-per-second 1 --output json)"
  jq -e '.TaskHandle | type == "string" and length > 0' >/dev/null <<<"$task" || die "AWS did not start the DLQ replay."
  printf 'DLQ replay started at one message per second. Monitor the DLQ and workflow-stage alarms before increasing throughput.\n'
}

https_status() {
  preflight
  local landing api reviewer
  landing="$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' https://challanse.constrovet.com/)" || die "Landing HTTPS certificate is not ready."
  api="$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' https://api.challanse.constrovet.com/health)" || die "API HTTPS certificate is not ready."
  reviewer="$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' https://review.challanse.constrovet.com/)" || die "Reviewer HTTPS certificate is not ready."
  [[ "$landing" == "200" && "$api" == "200" && ( "$reviewer" == "302" || "$reviewer" == "403" ) ]] || die "HTTPS readiness failed: landing=$landing api=$api reviewer=$reviewer"
  gh api --method PUT "repos/$REPO/pages" -F cname=challanse.constrovet.com -F build_type=workflow -F https_enforced=true >/dev/null
  save_state PRODUCTION_HTTPS_ACCEPTED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'All ChallanSe HTTPS endpoints are ready and GitHub Pages HTTPS enforcement is enabled.\n'
}

assert_production_https_accepted() {
  load_state
  [[ -n "${PRODUCTION_HTTPS_ACCEPTED_AT:-}" ]] || die "Run ./scripts/go-live.sh https-status after the first successful deployment."
}

harden_github() {
  preflight
  local push_maintainers approvals body confirmation
  push_maintainers="$(gh api "repos/$REPO/collaborators?affiliation=direct&per_page=100" --jq '[.[] | select(.permissions.push == true)] | length')"
  approvals=0
  if [[ "$push_maintainers" -ge 2 ]]; then approvals=1; fi
  printf 'Branch protection will require pull requests, resolved conversations, strict CI, and administrator enforcement. Required approvals: %s\n' "$approvals"
  [[ "$approvals" == "1" ]] || printf '%s\n' 'Only one push-capable maintainer is available, so independent review cannot yet be enforced.'
  read -r -p 'Type HARDEN MAIN to apply these repository rules: ' confirmation
  [[ "$confirmation" == "HARDEN MAIN" ]] || die "Branch protection unchanged."
  body="$(jq -nc --argjson approvals "$approvals" '{required_status_checks:{strict:true,contexts:["validate","android","enrichment","security","integration","terraform-plan"]},enforce_admins:true,required_pull_request_reviews:{dismiss_stale_reviews:true,require_code_owner_reviews:false,required_approving_review_count:$approvals,require_last_push_approval:false},restrictions:null,required_conversation_resolution:true,allow_force_pushes:false,allow_deletions:false,required_linear_history:true}')"
  gh api --method PUT "repos/$REPO/branches/main/protection" --input - <<<"$body" >/dev/null
  printf 'Main branch protection hardened. Add a second maintainer to enforce one independent approval.\n'
}

seed() {
  local vendors_file=""
  [[ "${1:-}" == "--vendors-file" && -n "${2:-}" ]] || die "Usage: $0 seed --vendors-file /secure/challanse-vendors.json"
  vendors_file="$2"; [[ -r "$vendors_file" ]] || die "Vendor file is not readable: $vendors_file"
  jq -e 'type == "array" and length >= 1 and length <= 20 and all(.[]; (.id|type=="string" and test("^[A-Za-z0-9._-]{1,64}$")) and (.name|type=="string" and length >= 2 and length <= 160) and (.initials|type=="string" and length >= 1 and length <= 3) and (.color|type=="string" and test("^#[0-9A-Fa-f]{6}$")))' "$vendors_file" >/dev/null || die "Vendor JSON is invalid."
  preflight
  need aws
  assert_production_https_accepted
  local organization_id organization_slug organization_name site_id site_name wifi_ssids_json reviewer_issuer reviewer_subject reviewer_email reviewer_display_name confirmation payload runtime_secret_arn runtime_json bootstrap_runtime restore_runtime cluster task_definition subnets security_group task_response task_arn exit_code stopped_reason task_status restore_status bootstrap_secret_staged=0
  read -r -p 'Organization UUID: ' organization_id
  [[ "$organization_id" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Organization ID must be a UUID."
  read -r -p 'Organization slug (lowercase letters, numbers, dashes): ' organization_slug
  [[ "$organization_slug" =~ ^[a-z0-9-]{2,80}$ ]] || die "Organization slug is invalid."
  prompt_value organization_name "Organization name"
  [[ ${#organization_name} -le 160 ]] || die "Organization name is too long."
  read -r -p 'Site UUID: ' site_id
  [[ "$site_id" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Site ID must be a UUID."
  prompt_value site_name "Site name"
  [[ ${#site_name} -le 160 ]] || die "Site name is too long."
  prompt_value wifi_ssids_json 'Approved Wi-Fi SSIDs JSON, for example ["Site Office"]'
  jq -e 'type == "array" and length >= 1 and length <= 20 and all(.[]; type == "string" and length >= 1 and length <= 64)' >/dev/null <<<"$wifi_ssids_json" || die "Wi-Fi JSON is invalid."
  prompt_value reviewer_issuer "Reviewer OIDC issuer URL"
  [[ "$reviewer_issuer" =~ ^https:// ]] || die "OIDC issuer must be an HTTPS URL."
  prompt_value reviewer_subject "Reviewer immutable OIDC subject"
  prompt_value reviewer_email "Reviewer email attribute"
  [[ "$reviewer_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Reviewer email is invalid."
  prompt_value reviewer_display_name "Reviewer display name"
  read -r -p "Type BOOTSTRAP $organization_id to authorize this tenant bootstrap: " confirmation
  [[ "$confirmation" == "BOOTSTRAP $organization_id" ]] || die "Tenant bootstrap cancelled."
  payload="$(jq -nc \
    --arg organization_id "$organization_id" --arg organization_slug "$organization_slug" --arg organization_name "$organization_name" \
    --arg site_id "$site_id" --arg site_name "$site_name" --argjson allowed_wifi_ssids "$wifi_ssids_json" \
    --arg reviewer_issuer "$reviewer_issuer" --arg reviewer_subject "$reviewer_subject" --arg reviewer_email "$reviewer_email" \
    --arg reviewer_display_name "$reviewer_display_name" --argjson vendors "$(jq -c . "$vendors_file")" --arg confirmation "$confirmation" \
    '{organization_id:$organization_id,organization_slug:$organization_slug,organization_name:$organization_name,site_id:$site_id,site_name:$site_name,allowed_wifi_ssids:$allowed_wifi_ssids,reviewer_issuer:$reviewer_issuer,reviewer_subject:$reviewer_subject,reviewer_email:$reviewer_email,reviewer_display_name:$reviewer_display_name,vendors:$vendors,confirmation:$confirmation}')"
  runtime_secret_arn="$(github_environment_variable AWS_RUNTIME_SECRET_ARN)"
  [[ -n "$runtime_secret_arn" ]] || die "AWS_RUNTIME_SECRET_ARN is missing from the production environment."
  runtime_json="$(aws secretsmanager get-secret-value --secret-id "$runtime_secret_arn" --query SecretString --output text)"
  jq -e '.TENANT_BOOTSTRAP_JSON == "{}"' >/dev/null <<<"$runtime_json" || die "A tenant bootstrap payload is already staged. Clear it through the incident runbook before retrying."
  bootstrap_runtime="$(jq -c --argjson payload "$payload" '.TENANT_BOOTSTRAP_JSON=($payload|tojson)' <<<"$runtime_json")"
  restore_runtime="$(jq -c '.TENANT_BOOTSTRAP_JSON="{}"' <<<"$runtime_json")"

  cluster="$(aws ecs list-clusters --query "clusterArns[?contains(@, 'challanse-production')] | [0]" --output text)"
  task_definition="$(aws ecs list-task-definitions --family-prefix challanse-production-migration --sort DESC --max-items 1 --query 'taskDefinitionArns[0]' --output text)"
  subnets="$(aws ec2 describe-subnets --filters Name=tag:Project,Values=challanse Name=tag:Environment,Values=production Name=tag:Name,Values='*private*' --query 'Subnets[].SubnetId' --output text | tr '\t' ',')"
  security_group="$(aws ec2 describe-security-groups --filters Name=group-name,Values=challanse-production-service Name=tag:Project,Values=challanse Name=tag:Environment,Values=production --query 'SecurityGroups[0].GroupId' --output text)"
  [[ "$cluster" == arn:* && "$task_definition" == arn:* && "$subnets" == subnet-* && "$security_group" == sg-* ]] || die "Could not discover the production migration task network. Deploy AWS infrastructure first."

  printf '%s' "$bootstrap_runtime" | aws secretsmanager put-secret-value --secret-id "$runtime_secret_arn" --secret-string file:///dev/stdin >/dev/null
  bootstrap_secret_staged=1
  trap 'status=$?; if [[ "${bootstrap_secret_staged:-0}" == "1" ]]; then printf "%s" "$restore_runtime" | aws secretsmanager put-secret-value --secret-id "$runtime_secret_arn" --secret-string file:///dev/stdin >/dev/null || printf "%s\n" "CRITICAL: tenant bootstrap payload restoration failed; disable deployments and follow the incident runbook." >&2; fi; exit "$status"' EXIT
  set +e
  task_response="$(aws ecs run-task --cluster "$cluster" --task-definition "$task_definition" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$security_group],assignPublicIp=DISABLED}" \
    --overrides '{"containerOverrides":[{"name":"migration","command":["python","-m","app.bootstrap"]}]}' --output json)"
  task_status=$?
  if [[ $task_status -eq 0 ]]; then
    task_arn="$(jq -r '.tasks[0].taskArn // empty' <<<"$task_response")"
    [[ -n "$task_arn" ]] || task_status=1
  fi
  if [[ $task_status -eq 0 ]]; then
    aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task_arn"
    task_status=$?
  fi
  if [[ $task_status -eq 0 ]]; then
    task_response="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" --output json)"
    exit_code="$(jq -r '.tasks[0].containers[] | select(.name == "migration") | .exitCode // empty' <<<"$task_response")"
    stopped_reason="$(jq -r '.tasks[0].stoppedReason // "unknown"' <<<"$task_response")"
    [[ "$exit_code" == "0" ]] || task_status=1
  fi
  printf '%s' "$restore_runtime" | aws secretsmanager put-secret-value --secret-id "$runtime_secret_arn" --secret-string file:///dev/stdin >/dev/null
  restore_status=$?
  if [[ $restore_status -eq 0 ]]; then bootstrap_secret_staged=0; fi
  set -e
  trap - EXIT
  unset payload runtime_json bootstrap_runtime restore_runtime task_response CLOUDFLARE_API_TOKEN
  [[ $restore_status -eq 0 ]] || die "Tenant bootstrap payload restoration failed. Disable deployments and follow the incident runbook before retrying."
  [[ $task_status -eq 0 ]] || die "Tenant bootstrap task failed (${stopped_reason:-AWS task start failure}). The staged payload was cleared."
  printf 'AWS tenant bootstrap completed for organization %s and site %s. Generate enrollment codes in the reviewer application.\n' "$organization_id" "$site_id"
}

verify_dns_unchanged() {
  [[ -r "$DNS_BASELINE" ]] || die "DNS baseline is missing. Rerun provision before verification."
  local current
  current="$(mktemp)"
  cf GET "/zones/$ZONE_ID/dns_records?per_page=500" | jq '[.result[] | select(.name != "challanse.constrovet.com" and .name != "api.challanse.constrovet.com" and .name != "review.challanse.constrovet.com") | {type,name,content,priority,proxied}] | sort_by(.type,.name,.content)' > "$current"
  cmp -s "$DNS_BASELINE" "$current" || { diff -u "$DNS_BASELINE" "$current" >&2 || true; rm -f "$current"; die "Existing DNS or email records changed since provisioning."; }
  rm -f "$current"
}

verify() {
  preflight
  local health ready landing_status reviewer_status evil_cors access_token inbox receipt_id image_url
  health="$(curl -fsS https://api.challanse.constrovet.com/health)"; jq -e '.status == "ok"' >/dev/null <<<"$health"
  ready="$(curl -fsS https://api.challanse.constrovet.com/ready)"; jq -e '.status == "ready"' >/dev/null <<<"$ready"
  landing_status="$(curl -sS -o /dev/null -w '%{http_code}' https://challanse.constrovet.com/)"; [[ "$landing_status" == "200" ]] || die "Landing returned HTTP $landing_status"
  reviewer_status="$(curl -sS -o /dev/null -w '%{http_code}' https://review.challanse.constrovet.com/)"; [[ "$reviewer_status" == "302" || "$reviewer_status" == "403" ]] || die "Reviewer is not protected by Access; HTTP $reviewer_status"
  evil_cors="$(curl -sSI -H 'Origin: https://evil.example' https://api.challanse.constrovet.com/health | tr -d '\r' | grep -i '^access-control-allow-origin:' || true)"; [[ -z "$evil_cors" ]] || die "API allowed an unapproved origin."
  verify_dns_unchanged
  need cloudflared
  access_token="$(cloudflared access token --app=https://review.challanse.constrovet.com)"
  [[ -n "$access_token" ]] || die "Could not obtain Cloudflare Access token."
  inbox="$(curl -fsS -H "Cookie: CF_Authorization=$access_token" 'https://review.challanse.constrovet.com/api/v1/reviewer/receipts?status=NEEDS_REVIEW&limit=1')"
  jq -e '.receipts | type == "array"' >/dev/null <<<"$inbox" || die "Authenticated reviewer proxy failed."
  receipt_id="$(jq -r '.receipts[0].id // empty' <<<"$inbox")"
  [[ -n "$receipt_id" ]] || die "No real receipt is available. Enroll a device, capture one real receipt, sync it, then rerun verify."
  image_url="/api/v1/reviewer/receipts/$receipt_id/image"
  curl -fsS -H "Cookie: CF_Authorization=$access_token" "https://review.challanse.constrovet.com$image_url" -o /dev/null
  unset access_token CLOUDFLARE_API_TOKEN
  printf 'Production verification passed, including authenticated private image streaming and unchanged DNS.\n'
}

download_aab() {
  load_state
  local run_id="${LAST_DEPLOY_RUN_ID:-}" output="${ROOT}/dist/release"
  if [[ -z "$run_id" ]]; then run_id="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --event workflow_dispatch --status success --limit 1 --json databaseId --jq '.[0].databaseId')"; fi
  [[ -n "$run_id" ]] || die "No successful production run was found."
  rm -rf "$output"; mkdir -p "$output"
  gh run download "$run_id" --repo "$REPO" --name challanse-android-app-bundle --dir "$output"
  gh run download "$run_id" --repo "$REPO" --name challanse-release-manifest --dir "$output" || die "Release manifest artifact was not found."
  local bundle; bundle="$(find "$output" -type f -name '*.aab' -print -quit)"; [[ -n "$bundle" ]] || die "AAB artifact was not found."
  local actual expected
  actual="$(sha256sum "$bundle" | awk '{print $1}')"
  expected="$(jq -r '.aab_sha256 // empty' "$output/release-manifest.json")"
  [[ -n "$expected" && "$actual" == "$expected" ]] || die "AAB checksum does not match the signed release manifest."
  printf '%s  %s\n' "$actual" "$bundle"
  printf 'Verified release manifest: %s\n' "$output/release-manifest.json"
}

usage() {
  cat <<'USAGE'
Usage: scripts/go-live.sh <command>
  dns-onboard
  dns-status
  dns-accept
  preflight
  provision
  configure-identity
  configure-github
  configure-enrichment
  configure-tunnel-origin
  configure-play
  accept-client /secure/client-acceptance.json
  accept-operator-training /secure/operator-training.json
  accept-security /secure/security-acceptance.json
  accept-capacity /secure/capacity-acceptance.json
  accept-recovery /secure/recovery-acceptance.json
  set-play-track internal|alpha|production
  rotate-enrichment-keys stage|promote
  configure-aws
  rotate-signing
  harden-github
  deploy
  accept-staging /secure/staging-acceptance.json
  accept-android-field /secure/android-field-acceptance.json
  https-status
  rotate-device-pepper
  replay-dlq
  seed --vendors-file /secure/challanse-vendors.json
  verify
  download-aab
USAGE
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    dns-onboard) dns_onboard ;;
    dns-status) dns_status ;;
    dns-accept) dns_accept ;;
    preflight) preflight ;;
    provision) provision ;;
    configure-identity) configure_identity ;;
    configure-github) configure_github ;;
    configure-enrichment) configure_enrichment ;;
    configure-tunnel-origin) configure_tunnel_origin ;;
    configure-play) configure_play ;;
    accept-client) accept_client "${2:-}" ;;
    accept-operator-training) accept_operator_training "${2:-}" ;;
    accept-security) accept_security "${2:-}" ;;
    accept-capacity) accept_capacity "${2:-}" ;;
    accept-recovery) accept_recovery "${2:-}" ;;
    set-play-track) set_play_track "${2:-}" ;;
    rotate-enrichment-keys) rotate_enrichment_keys "${2:-}" ;;
    configure-aws) configure_aws ;;
    rotate-signing) rotate_signing ;;
    harden-github) harden_github ;;
    deploy) deploy ;;
    accept-staging) accept_staging "${2:-}" ;;
    accept-android-field) accept_android_field "${2:-}" ;;
    https-status) https_status ;;
    rotate-device-pepper) rotate_device_pepper ;;
    replay-dlq) replay_dlq ;;
    seed) shift; seed "$@" ;;
    verify) verify ;;
    download-aab) download_aab ;;
    help|-h|--help|'') usage ;;
    *) usage >&2; exit 1 ;;
  esac
fi
