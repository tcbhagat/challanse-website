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

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"
cd "$ROOT"

load_state() { set -a; source "$STATE_FILE"; set +a; }
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
      printf '%s\n' 'The token must include Zone > Dynamic URL Redirects > Edit for constrovet.com so the approved app redirect can be created.' >&2
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
resource_id() {
  local json="$1" name="$2"
  jq -r --arg name "$name" '.. | objects | select((.name? == $name) or (.queue_name? == $name)) | .uuid? // .id? // empty' <<<"$json" | head -1
}
render_edge_config() {
  load_state
  [[ -n "${D1_DATABASE_ID:-}" && -n "${ACCESS_TEAM_DOMAIN:-}" && -n "${ACCESS_AUD:-}" ]] || die "Provisioning state is incomplete."
  CLOUDFLARE_D1_DATABASE_ID="$D1_DATABASE_ID" CLOUDFLARE_ACCESS_TEAM_DOMAIN="$ACCESS_TEAM_DOMAIN" CLOUDFLARE_ACCESS_AUD="$ACCESS_AUD" node scripts/render-edge-config.mjs >/dev/null
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

ensure_wrangler_resource() {
  local kind="$1" name="$2" list id body
  case "$kind" in
    d1)
      list="$(wrangler d1 list --json)"
      id="$(resource_id "$list" "$name")"
      if [[ -z "$id" ]]; then wrangler d1 create "$name" >/dev/null; list="$(wrangler d1 list --json)"; id="$(resource_id "$list" "$name")"; fi
      [[ -n "$id" ]] || die "D1 database was not created: $name"
      printf '%s' "$id"
      return
      ;;
    r2)
      list="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets")"
      if ! jq -e --arg name "$name" '.. | objects | select(.name? == $name)' >/dev/null <<<"$list"; then
        cf PUT "/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets/$name" '{}' >/dev/null
      fi
      ;;
    queue)
      list="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/queues")"
      if ! jq -e --arg name "$name" '.. | objects | select(.queue_name? == $name)' >/dev/null <<<"$list"; then
        body="$(jq -nc --arg name "$name" '{queue_name:$name}')"
        cf POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/queues" "$body" >/dev/null
      fi
      ;;
    *) die "Unknown resource kind: $kind" ;;
  esac
  if [[ "$kind" == "r2" ]]; then
    list="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets")"
    jq -e --arg name "$name" '.. | objects | select(.name? == $name)' >/dev/null <<<"$list" || die "R2 bucket was not created: $name"
  else
    list="$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/queues")"
    jq -e --arg name "$name" '.. | objects | select(.queue_name? == $name)' >/dev/null <<<"$list" || die "Queue was not created: $name"
  fi
  printf '%s' "$name"
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

provision() {
  preflight
  prompt_value REVIEWER_EMAIL_1 "Primary reviewer email"
  prompt_value REVIEWER_EMAIL_2 "Second reviewer email"
  [[ "$REVIEWER_EMAIL_1" != "$REVIEWER_EMAIL_2" ]] || die "Reviewer emails must be different."
  snapshot_dns
  D1_DATABASE_ID="$(ensure_wrangler_resource d1 challanse-pilot)"
  ensure_wrangler_resource r2 challanse-receipts >/dev/null
  ensure_wrangler_resource queue challanse-receipts >/dev/null
  ensure_wrangler_resource queue challanse-receipts-dlq >/dev/null
  save_state D1_DATABASE_ID "$D1_DATABASE_ID"

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
  [[ -n "$turnstile_secret" ]] || die "Existing Turnstile secret is not retrievable. Rotate it in Cloudflare, then rerun provision."

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
    jq -e --arg first "$REVIEWER_EMAIL_1" --arg second "$REVIEWER_EMAIL_2" '[.. | .email? | strings] | index($first) != null and index($second) != null' >/dev/null <<<"$app" || die "Existing Access app does not contain both supplied reviewers. Update it explicitly before continuing."
  fi
  access_aud="$(jq -r '.aud // empty' <<<"$app")"
  [[ -n "$access_aud" ]] || die "Access audience was not returned."
  save_state ACCESS_TEAM_DOMAIN "$access_domain"
  save_state ACCESS_AUD "$access_aud"
  save_state TURNSTILE_SITE_KEY "$turnstile_sitekey"
  save_state REVIEWER_EMAIL_1 "$REVIEWER_EMAIL_1"
  save_state REVIEWER_EMAIL_2 "$REVIEWER_EMAIL_2"

  printf '%s' "$turnstile_secret" | gh secret set TURNSTILE_SECRET --repo "$REPO" --env production
  gh variable set CLOUDFLARE_D1_DATABASE_ID --repo "$REPO" --env production --body "$D1_DATABASE_ID"
  gh variable set CLOUDFLARE_ACCESS_TEAM_DOMAIN --repo "$REPO" --env production --body "$access_domain"
  gh variable set CLOUDFLARE_ACCESS_AUD --repo "$REPO" --env production --body "$access_aud"
  gh variable set TURNSTILE_SITE_KEY --repo "$REPO" --env production --body "$turnstile_sitekey"
  ensure_landing_dns
  if gh api "repos/$REPO/pages" >/dev/null 2>&1; then
    gh api --method PUT "repos/$REPO/pages" -f cname=challanse.constrovet.com -f build_type=workflow >/dev/null
  else
    gh api --method POST "repos/$REPO/pages" -f build_type=workflow >/dev/null
    gh api --method PUT "repos/$REPO/pages" -f cname=challanse.constrovet.com -f build_type=workflow >/dev/null
  fi
  unset turnstile_secret CLOUDFLARE_API_TOKEN
  printf 'Cloudflare resources, Access, Turnstile, DNS, and GitHub variables are provisioned. Deployment remains disabled.\n'
}

configure_github() {
  preflight
  command -v keytool >/dev/null 2>&1 || die "keytool is required only for Android signing. On Ubuntu run: sudo apt update && sudo apt install -y openjdk-17-jdk-headless"
  load_state
  [[ -n "${D1_DATABASE_ID:-}" && -n "${ACCESS_AUD:-}" && -n "${TURNSTILE_SITE_KEY:-}" ]] || die "Run provision first."
  prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API token"
  printf '%s' "$CLOUDFLARE_API_TOKEN" | gh secret set CLOUDFLARE_API_TOKEN --repo "$REPO" --env production
  printf '%s' "$CLOUDFLARE_ACCOUNT_ID" | gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$REPO" --env production
  local pepper keystore password password_confirm encoded
  pepper="$(openssl rand -hex 32)"
  printf '%s' "$pepper" | gh secret set DEVICE_TOKEN_PEPPER --repo "$REPO" --env production
  read -r -p "Secure release-keystore path [${STATE_DIR}/challanse-release.jks]: " keystore
  keystore="${keystore:-${STATE_DIR}/challanse-release.jks}"
  read -r -s -p "Android keystore/key password: " password; printf '\n'
  read -r -s -p "Repeat Android password: " password_confirm; printf '\n'
  [[ -n "$password" && "$password" == "$password_confirm" ]] || die "Android passwords do not match."
  if [[ ! -f "$keystore" ]]; then
    keytool -genkeypair -v -keystore "$keystore" -alias challanse -keyalg RSA -keysize 4096 -validity 10000 -storepass "$password" -keypass "$password" -dname 'CN=ChallanSe, O=Constrovet, C=IN' >/dev/null
    chmod 600 "$keystore"
  fi
  keytool -list -keystore "$keystore" -alias challanse -storepass "$password" >/dev/null
  encoded="$(base64 -w0 "$keystore")"
  printf '%s' "$encoded" | gh secret set CHALLANSE_KEYSTORE_BASE64 --repo "$REPO" --env production
  printf '%s' "$password" | gh secret set CHALLANSE_KEYSTORE_PASSWORD --repo "$REPO" --env production
  printf '%s' challanse | gh secret set CHALLANSE_KEY_ALIAS --repo "$REPO" --env production
  printf '%s' "$password" | gh secret set CHALLANSE_KEY_PASSWORD --repo "$REPO" --env production
  gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
  unset password password_confirm encoded pepper CLOUDFLARE_API_TOKEN
  printf 'GitHub production secrets and Android signing are configured. Back up %s offline.\n' "$keystore"
}

deploy() {
  preflight
  local required_secrets required_variables run_id pending ids body
  required_secrets='["CLOUDFLARE_ACCOUNT_ID","CLOUDFLARE_API_TOKEN","DEVICE_TOKEN_PEPPER","TURNSTILE_SECRET","CHALLANSE_KEYSTORE_BASE64","CHALLANSE_KEYSTORE_PASSWORD","CHALLANSE_KEY_ALIAS","CHALLANSE_KEY_PASSWORD"]'
  required_variables='["CLOUDFLARE_D1_DATABASE_ID","CLOUDFLARE_ACCESS_TEAM_DOMAIN","CLOUDFLARE_ACCESS_AUD","TURNSTILE_SITE_KEY"]'
  jq -e --argjson required "$required_secrets" '($required - [.[].name]) | length == 0' >/dev/null < <(gh secret list --repo "$REPO" --env production --json name) || die "Required production secrets are missing."
  jq -e --argjson required "$required_variables" '($required - [.[].name]) | length == 0' >/dev/null < <(gh variable list --repo "$REPO" --env production --json name) || die "Required production variables are missing."
  confirm "This will deploy production and build a signed APK."
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
  printf 'Production workflow completed successfully: https://github.com/%s/actions/runs/%s\n' "$REPO" "$run_id"
}

seed() {
  local vendors_file=""
  [[ "${1:-}" == "--vendors-file" && -n "${2:-}" ]] || die "Usage: $0 seed --vendors-file /secure/challanse-vendors.json"
  vendors_file="$2"; [[ -r "$vendors_file" ]] || die "Vendor file is not readable: $vendors_file"
  jq -e 'type == "array" and length >= 1 and length <= 4 and all(.[]; (.id|type=="string") and (.name|type=="string") and (.initials|type=="string") and (.color|test("^#[0-9A-Fa-f]{6}$")))' "$vendors_file" >/dev/null || die "Vendor JSON is invalid."
  preflight
  load_state
  prompt_value SITE_ID "Site ID"
  prompt_value SITE_NAME "Site name"
  prompt_value WIFI_SSIDS_JSON 'Approved Wi-Fi SSIDs JSON, for example ["Site Office"]'
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null <<<"$WIFI_SSIDS_JSON" || die "Wi-Fi JSON is invalid."
  local reviewers sql_file vendors_json
  reviewers="$(jq -nc --arg first "$REVIEWER_EMAIL_1" --arg second "$REVIEWER_EMAIL_2" '[$first,$second]')"
  vendors_json="$(jq -c . "$vendors_file")"
  sql_file="$(mktemp /tmp/challanse-seed.XXXXXX.sql)"
  trap 'rm -f "$sql_file"' RETURN
  SITE_ID="$SITE_ID" SITE_NAME="$SITE_NAME" REVIEWER_EMAILS_JSON="$reviewers" WIFI_SSIDS_JSON="$WIFI_SSIDS_JSON" VENDORS_JSON="$vendors_json" node scripts/bootstrap-pilot.mjs > "$sql_file"
  render_edge_config
  confirm "Apply the reviewed real site, reviewers, Wi-Fi, and vendors to production D1."
  wrangler d1 execute challanse-pilot --remote --config apps/edge/wrangler.generated.toml --file "$sql_file"
  rm -f "$sql_file"; trap - RETURN
  printf 'Real pilot configuration seeded. Generate enrollment QR codes in the reviewer application.\n'
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

download_apk() {
  load_state
  local run_id="${LAST_DEPLOY_RUN_ID:-}" output="${ROOT}/dist/release"
  if [[ -z "$run_id" ]]; then run_id="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --event workflow_dispatch --status success --limit 1 --json databaseId --jq '.[0].databaseId')"; fi
  [[ -n "$run_id" ]] || die "No successful production run was found."
  rm -rf "$output"; mkdir -p "$output"
  gh run download "$run_id" --repo "$REPO" --name challanse-android-release --dir "$output"
  local apk; apk="$(find "$output" -type f -name '*.apk' -print -quit)"; [[ -n "$apk" ]] || die "APK artifact was not found."
  sha256sum "$apk"
}

usage() {
  cat <<'USAGE'
Usage: scripts/go-live.sh <command>
  dns-onboard
  dns-status
  dns-accept
  preflight
  provision
  configure-github
  deploy
  seed --vendors-file /secure/challanse-vendors.json
  verify
  download-apk
USAGE
}

case "${1:-}" in
  dns-onboard) dns_onboard ;;
  dns-status) dns_status ;;
  dns-accept) dns_accept ;;
  preflight) preflight ;;
  provision) provision ;;
  configure-github) configure_github ;;
  deploy) deploy ;;
  seed) shift; seed "$@" ;;
  verify) verify ;;
  download-apk) download_apk ;;
  help|-h|--help|'') usage ;;
  *) usage >&2; exit 1 ;;
esac
