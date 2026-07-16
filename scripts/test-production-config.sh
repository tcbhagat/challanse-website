#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
bash -n scripts/go-live.sh
bash -n scripts/rollback-production.sh
bash -n scripts/test-turnstile-recovery.sh
bash -n scripts/test-production-hardening.sh
shellcheck -e SC1090 scripts/go-live.sh scripts/rollback-production.sh scripts/test-production-config.sh scripts/test-turnstile-recovery.sh scripts/test-production-hardening.sh
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
grep -Fq 'Cloudflare error details:' scripts/go-live.sh
grep -Fq 'Account > Zone > Edit' scripts/go-live.sh
grep -Fq 'Zone > Dynamic URL Redirects > Edit' scripts/go-live.sh
grep -Fq 'https://www.constrovet.com/app/' scripts/go-live.sh
grep -Fq 'APP REDIRECT OK' scripts/go-live.sh
grep -Fq 'invalidate_immediately' scripts/go-live.sh
grep -Fq 'ROTATE DEVICE PEPPER' scripts/go-live.sh
grep -Fq 'CHALLANSE_SIGNING_CERT_SHA256' scripts/go-live.sh
grep -Fq 'Type DEPLOY' scripts/go-live.sh
grep -Fq 'https-status' scripts/go-live.sh
grep -Fq 'harden-github' scripts/go-live.sh
grep -Fq 'ROTATE EXPOSED SIGNING KEY' scripts/go-live.sh
grep -Fq 'Rotate the exposed Android signing identity before deployment' scripts/go-live.sh
grep -Fq 'CHALLANSE_REVOKED_SIGNING_CERT_SHA256' .github/workflows/ci-pages.yml
for required_job in validate android enrichment security terraform-plan integration; do
  grep -Eq "^  ${required_job}:" .github/workflows/ci-pages.yml || { echo "Missing required CI job: $required_job" >&2; exit 1; }
done
if grep -E '^\s*- uses:' .github/workflows/ci-pages.yml | grep -Ev 'uses: [^[:space:]@]+@[0-9a-f]{40}([[:space:]]|$)'; then
  echo "Every GitHub Action must be pinned to an immutable commit SHA." >&2
  exit 1
fi
grep -Fq 'AWS_ENRICHMENT_BOOTSTRAPPED == '\''true'\''' .github/workflows/ci-pages.yml
grep -Fq 'PILOT_DEPLOY_ENABLED == '\''true'\''' .github/workflows/ci-pages.yml
grep -Fq 'rotate-enrichment-keys stage|promote' scripts/go-live.sh
grep -Fq 'EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY' scripts/go-live.sh
grep -Fq 'ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY' scripts/go-live.sh
grep -Fq 'EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID' apps/edge/wrangler.toml
grep -Fq 'ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID' apps/edge/wrangler.toml
grep -Fq 'STAGING_ACCEPTANCE_SHA256' scripts/go-live.sh
grep -Fq 'ANDROID_FIELD_ACCEPTANCE_SHA256' scripts/go-live.sh
grep -Fq '0004_replay_protection.sql' .github/workflows/ci-pages.yml
test -s services/enrichment/migrations/0004_replay_protection.sql
test -s apps/edge/migrations/0007_retention_tombstones.sql
grep -Eq '^FROM .+@sha256:[0-9a-f]{64}$' services/enrichment/Dockerfile
grep -Fq 'deletion_protection      = true' infra/terraform/production/main.tf
grep -Fq 'deletion_protection      = false' infra/terraform/staging/main.tf
if rg -n -i 'celery|redis' services/enrichment README.md docs/hybrid-enrichment.md; then
  echo "Celery/Redis references must not remain in the production enrichment path or current runbooks." >&2
  exit 1
fi
if rg -n 'p95.*<.*50|toBeLessThan\(50\)' apps/mobile/__tests__; then
  echo "JavaScript tests must not claim the Android field p95 gate." >&2
  exit 1
fi
grep -A5 -Fq '"op-sqlite"' apps/mobile/package.json
grep -A5 '"op-sqlite"' apps/mobile/package.json | grep -Fq '"sqlcipher": true'
if rg -n -i 'tflite|tensorflow|mobilenet|auto.?capture' apps/mobile; then
  echo "Automatic ML capture assets or wiring must not be shipped." >&2
  exit 1
fi
turnstile_store_line="$(grep -n 'gh secret set TURNSTILE_SECRET' scripts/go-live.sh | cut -d: -f1)"
access_lookup_line="$(grep -n 'access/organizations' scripts/go-live.sh | cut -d: -f1)"
[[ "$turnstile_store_line" -lt "$access_lookup_line" ]] || { echo "Turnstile secret must be stored before Access provisioning." >&2; exit 1; }
bash scripts/test-turnstile-recovery.sh
bash scripts/test-production-hardening.sh
if grep -RIE --exclude='test-production-config.sh' '(gho_[A-Za-z0-9]+|sk_live_[A-Za-z0-9]+|CLOUDFLARE_API_TOKEN=.{12})' scripts apps; then
  echo "Potential committed credential detected." >&2
  exit 1
fi
echo "Production configuration checks passed."
