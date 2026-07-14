#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
bash -n scripts/go-live.sh
bash -n scripts/rollback-production.sh
shellcheck -e SC1090 scripts/go-live.sh scripts/rollback-production.sh scripts/test-production-config.sh
test -x scripts/go-live.sh
test -x scripts/rollback-production.sh
grep -Fq "VITE_API_BASE_URL: /api" .github/workflows/ci-pages.yml
grep -Fq 'API_ORIGIN = "https://api.challanse.constrovet.com"' apps/reviewer/wrangler.toml
grep -Fq "Cf-Access-Jwt-Assertion" apps/reviewer/src/worker.ts
grep -Fq 'dns-onboard' scripts/go-live.sh
grep -Fq 'dns-status' scripts/go-live.sh
grep -Fq 'dns-accept' scripts/go-live.sh
grep -Fq '34.102.192.38' scripts/go-live.sh
grep -Fq 'tcbhagat.github.io' scripts/go-live.sh
grep -Fq 'alt4.aspmx.l.google.com' scripts/go-live.sh
grep -Fq 'DNS_ACCEPTED_AT' scripts/go-live.sh
if rg -I -g '!test-production-config.sh' '(gho_[A-Za-z0-9]+|sk_live_[A-Za-z0-9]+|CLOUDFLARE_API_TOKEN=.{12})' scripts apps; then
  echo "Potential committed credential detected." >&2
  exit 1
fi
echo "Production configuration checks passed."
