#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="tcbhagat/challanse"
STATE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/challanse/production.env"
cd "$ROOT"

gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
printf 'New production deployments are disabled. Existing D1, R2, queues, and device data were preserved.\n'

if [[ "${1:-}" == "--revoke-devices" ]]; then
  [[ -r "$STATE_FILE" ]] || { echo "Provisioning state is missing." >&2; exit 1; }
  set -a; source "$STATE_FILE"; set +a
  read -r -p 'Revoke every enrolled device while preserving receipt data? Type REVOKE: ' answer
  [[ "$answer" == "REVOKE" ]] || { echo "Device revocation cancelled."; exit 0; }
  read -r -s -p 'Cloudflare API token: ' CLOUDFLARE_API_TOKEN; printf '\n'
  export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
  CLOUDFLARE_D1_DATABASE_ID="$D1_DATABASE_ID" CLOUDFLARE_ACCESS_TEAM_DOMAIN="$ACCESS_TEAM_DOMAIN" CLOUDFLARE_ACCESS_AUD="$ACCESS_AUD" node scripts/render-edge-config.mjs >/dev/null
  npx --no-install wrangler d1 execute challanse-pilot --remote --config apps/edge/wrangler.generated.toml --command "UPDATE devices SET active = 0; INSERT INTO operations_log (id, event_type, detail_json) VALUES (lower(hex(randomblob(16))), 'ALL_DEVICES_REVOKED', '{}');"
  unset CLOUDFLARE_API_TOKEN
  printf 'All devices revoked. Receipt and image data remain intact.\n'
fi
