#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for required_command in bash grep jq shellcheck; do
  command -v "$required_command" >/dev/null 2>&1 || {
    echo "Required CI command is unavailable: $required_command" >&2
    exit 1
  }
done

contains_forbidden() {
  local status
  if grep "$@"; then
    return 0
  else
    status=$?
  fi
  [[ "$status" -eq 1 ]] && return 1
  echo "Security search failed instead of completing: grep $*" >&2
  exit "$status"
}
bash -n scripts/go-live.sh
bash -n scripts/rollback-production.sh
bash -n scripts/test-turnstile-recovery.sh
bash -n scripts/test-production-hardening.sh
bash -n scripts/test-budget-controls.sh
bash -n scripts/zero-cost-readiness.sh
bash -n scripts/test-zero-cost-readiness.sh
bash -n scripts/local-pilot.sh
bash -n scripts/quality-loop.sh
bash -n scripts/test-local-pilot-storage.sh
shellcheck -e SC1090 scripts/test-waf-provisioning.sh
shellcheck -e SC1090 scripts/go-live.sh scripts/rollback-production.sh scripts/local-pilot.sh scripts/quality-loop.sh scripts/test-local-pilot-storage.sh scripts/test-production-config.sh scripts/test-turnstile-recovery.sh scripts/test-production-hardening.sh scripts/test-budget-controls.sh scripts/zero-cost-readiness.sh scripts/test-zero-cost-readiness.sh
bash scripts/test-local-pilot-storage.sh
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
grep -Fq 'CHALLANSE_UPLOAD_CERT_SHA256' scripts/go-live.sh
grep -Fq 'CHALLANSE_PLAY_APP_SIGNING_CERT_SHA256' scripts/go-live.sh
grep -Fq 'PLAY_SERVICE_ACCOUNT_JSON' scripts/go-live.sh
grep -Fq 'bundleRelease' apps/mobile/package.json
if contains_forbidden -RInE --exclude='test-production-config.sh' --exclude='local-pilot.sh' 'assembleRelease|download-apk|app-release\.apk' .github scripts apps/mobile/package.json README.md docs/release-readiness.md; then
  echo "Production distribution must remain AAB-only through Managed Google Play." >&2
  exit 1
fi
grep -Fq 'applicationIdSuffix ".localpilot"' apps/mobile/android/app/build.gradle
grep -Fq 'SYNTHETIC TEST' apps/mobile/src/PilotApp.tsx
grep -Fq 'CONTROLLED CLIENT PILOT' apps/mobile/src/PilotApp.tsx
grep -Fq 'PasswordHasher(time_cost=3, memory_cost=65_536, parallelism=2)' services/enrichment/app/local_auth.py
grep -Fq 'restoreVerifiedWithin30Days' services/enrichment/app/pilot_control.py
grep -Fq 'encryptedBackupWithin24Hours' services/enrichment/app/pilot_control.py
grep -Fq 'AWS_DEPLOYMENT_FROZEN must equal true' scripts/quality-loop.sh
grep -Fq 'humanOnlyActions' quality/gates.json
if contains_forbidden -RInE --exclude='test-production-config.sh' 'LOCAL_REVIEWER_PASSWORD_SHA256|subprocess\.(run|Popen).*tesseract' services deploy scripts; then
  echo "Shared reviewer credentials or ad hoc Tesseract subprocesses are forbidden." >&2
  exit 1
fi
grep -Fq 'Type DEPLOY' scripts/go-live.sh
grep -Fq 'https-status' scripts/go-live.sh
grep -Fq 'harden-github' scripts/go-live.sh
grep -Fq 'ROTATE EXPOSED SIGNING KEY' scripts/go-live.sh
grep -Fq 'Rotate the exposed Android signing identity before deployment' scripts/go-live.sh
grep -Fq 'CHALLANSE_REVOKED_SIGNING_CERT_SHA256' .github/workflows/ci-pages.yml
grep -Fq 'aab_sha256' .github/workflows/ci-pages.yml
grep -Fq 'sbom_sha256' .github/workflows/ci-pages.yml
grep -Fq 'managed_organizations' .github/workflows/ci-pages.yml
grep -Fq 'Cloudflare Free Managed Ruleset' scripts/go-live.sh
grep -Fq 'CLOUDFLARE_FREE_WAF_ENABLED' scripts/go-live.sh
grep -Fq 'PLAY_RELEASE_TRACK' scripts/go-live.sh
grep -Fq 'CLIENT_ACCEPTANCE_SHA256' scripts/go-live.sh
grep -Fq 'OPERATOR_TRAINING_SHA256' scripts/go-live.sh
test -s docs/templates/operator-training.json
test -s docs/aws-deployment-freeze.md
grep -Fq 'AWS_DEPLOYMENT_FROZEN=true' docs/aws-deployment-freeze.md
for acceptance in staging android-field client security capacity recovery; do
  test -s "docs/templates/${acceptance}-acceptance.json"
done
for acceptance in security capacity recovery; do
  grep -Fq "${acceptance^^}_ACCEPTANCE_SHA256" scripts/go-live.sh
done
if contains_forbidden -RInE 'wrangler d1|challanse-pilot|bootstrap-pilot' scripts/go-live.sh apps/edge/src; then
  echo "Production commands must not use the retired Cloudflare data plane." >&2
  exit 1
fi
for required_job in validate android enrichment security terraform-plan integration; do
  grep -Eq "^  ${required_job}:" .github/workflows/ci-pages.yml || { echo "Missing required CI job: $required_job" >&2; exit 1; }
done
if grep -E '^\s*- uses:' .github/workflows/ci-pages.yml | grep -Ev 'uses: [^[:space:]@]+@[0-9a-f]{40}([[:space:]]|$)'; then
  echo "Every GitHub Action must be pinned to an immutable commit SHA." >&2
  exit 1
fi
grep -Fq 'AWS_ENRICHMENT_BOOTSTRAPPED == '\''true'\''' .github/workflows/ci-pages.yml
grep -Fq 'PILOT_DEPLOY_ENABLED == '\''true'\''' .github/workflows/ci-pages.yml
test "$(grep -c "vars.AWS_DEPLOYMENT_FROZEN != 'true'" .github/workflows/ci-pages.yml)" -eq 4
grep -Fq 'AWS_DEPLOYMENT_FROZEN must equal false before running AWS production commands.' scripts/go-live.sh
grep -Fq "AWS_DEPLOYMENT_FROZEN --repo \"\$REPO\" --body true" scripts/rollback-production.sh
grep -Fq "AWS_ENRICHMENT_BOOTSTRAPPED --repo \"\$REPO\" --env production --body false" scripts/rollback-production.sh
grep -Fq 'AWS_PRIVATE_ALB_CERTIFICATE_ARN' .github/workflows/ci-pages.yml
grep -Fq 'AWS_PRODUCTION_MONTHLY_BUDGET_USD' .github/workflows/ci-pages.yml
grep -Fq 'AWS_SECONDARY_BUDGET_EMAIL' .github/workflows/ci-pages.yml
grep -Fq 'terraform_state_bucket_arn=arn:aws:s3:::' .github/workflows/ci-pages.yml
grep -Fq 'configure-tunnel-origin' scripts/go-live.sh
grep -Fq 'CLOUDFLARE_TUNNEL_ORIGIN_TLS_VERIFIED' scripts/go-live.sh
grep -Fq 'rotate-enrichment-keys stage|promote' scripts/go-live.sh
grep -Fq 'EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY' scripts/go-live.sh
grep -Fq 'ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY' scripts/go-live.sh
grep -Fq 'EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID' apps/edge/wrangler.toml
grep -Fq 'ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID' services/enrichment/app/config.py
grep -Fq 'TENANT_CONTEXT_HMAC_KEY' services/enrichment/app/config.py
grep -Fq 'STAGING_ACCEPTANCE_SHA256' scripts/go-live.sh
grep -Fq 'ANDROID_FIELD_ACCEPTANCE_SHA256' scripts/go-live.sh
grep -Fq '0005_production_tenancy.sql' .github/workflows/ci-pages.yml
test -s services/enrichment/migrations/0005_production_tenancy.sql
test -s services/enrichment/migrations/0006_local_pilot.sql
grep -Fq 'local_receipt_queue' services/enrichment/migrations/0006_local_pilot.sql
grep -Fq 'device_rate_limit_windows' services/enrichment/migrations/0005_production_tenancy.sql
if grep -Fq 'CREATE UNIQUE INDEX IF NOT EXISTS users_email_idx' services/enrichment/migrations/0005_production_tenancy.sql; then
  echo "Email must remain an editable attribute, not an identity key." >&2
  exit 1
fi
if contains_forbidden -RInE 'env\.(DB|RECEIPTS|RECEIPT_QUEUE)' apps/edge/src; then
  echo "Cloudflare Worker must remain stateless." >&2
  exit 1
fi
grep -Eq '^FROM .+@sha256:[0-9a-f]{64}$' services/enrichment/Dockerfile
grep -Eq '^FROM .+@sha256:[0-9a-f]{64}$' deploy/local/Dockerfile.caddy
grep -Fq 'RUN setcap -r /usr/bin/caddy' deploy/local/Dockerfile.caddy
grep -Fq 'USER 1000:1000' deploy/local/Dockerfile.caddy
grep -Fq ':8443 {' deploy/local/Caddyfile
grep -Fq ':8444 {' deploy/local/Caddyfile
# shellcheck disable=SC2016 # Intentional literal source-code assertion.
ip_literal_caddy_address='https://{$CHALLANSE_LAN_IP}'
if grep -Fq "$ip_literal_caddy_address" deploy/local/Caddyfile; then
  echo "IP-literal TLS must not require SNI because clients omit SNI for IP addresses." >&2
  exit 1
fi
sed -n '/^  gateway:/,/^  cloudflared:/p' deploy/local/docker-compose.yml | grep -Fq 'networks: [frontend, lan-publish]'
if grep -Eq '^[[:space:]]*tmpfs:[[:space:]]*\[' deploy/local/docker-compose.yml; then
  echo "Compose tmpfs mounts must use quoted block-list entries so commas remain mount options." >&2
  exit 1
fi
grep -Fq '/app/apps/edge/.wrangler:rw,noexec,nosuid,uid=1000,gid=1000,mode=0700' deploy/local/docker-compose.yml
grep -Fq '/app/apps/reviewer/.wrangler:rw,noexec,nosuid,uid=1000,gid=1000,mode=0700' deploy/local/docker-compose.yml
grep -Fq 'compose up -d --force-recreate' scripts/local-pilot.sh
test -s deploy/local/docker-compose.snap.yml
grep -Fq 'SNAP_COMPOSE_FILE=' scripts/local-pilot.sh
grep -Fq 'name=apparmor' scripts/local-pilot.sh
grep -Fq 'name=seccomp' scripts/local-pilot.sh
if grep -Eq 'privileged:[[:space:]]*true|cap_add:' deploy/local/docker-compose.snap.yml; then
  echo "Snap compatibility must not add privileges or capabilities." >&2
  exit 1
fi
grep -Eq 'deletion_protection[[:space:]]*=[[:space:]]*true' infra/terraform/production/main.tf
grep -Eq 'deletion_protection[[:space:]]*=[[:space:]]*false' infra/terraform/staging/main.tf
grep -Fq 'enable_continuous_backup = true' infra/terraform/modules/enrichment/main.tf
grep -Fq 'aws_s3_bucket.receipts.arn' infra/terraform/modules/enrichment/main.tf
grep -Fq 'eventbridge = true' infra/terraform/modules/enrichment/main.tf
grep -Fq 'resource "aws_appautoscaling_policy" "worker_queue_depth"' infra/terraform/modules/enrichment/main.tf
grep -Fq 'resource "aws_sqs_queue" "credit_dead_letter"' infra/terraform/modules/enrichment/main.tf
grep -Fq 'resource "aws_cloudwatch_metric_alarm" "credit_dlq"' infra/terraform/modules/enrichment/main.tf
grep -Fq 'resource "aws_lb_listener" "private_https"' infra/terraform/modules/enrichment/main.tf
grep -Fq 'ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"' infra/terraform/modules/enrichment/main.tf
grep -Fq 'resource "aws_flow_log" "vpc"' infra/terraform/modules/enrichment/main.tf
grep -Fq 'task_role_arn            = aws_iam_role.tunnel_task.arn' infra/terraform/modules/enrichment/main.tf
grep -Fq 'Resource = var.terraform_state_bucket_arn' infra/terraform/modules/enrichment/main.tf
if grep -Fq 'resource "aws_lb_listener" "private_http"' infra/terraform/modules/enrichment/main.tf; then
  echo "Private ALB traffic must remain HTTPS." >&2
  exit 1
fi
github_policy="$(sed -n '/resource "aws_iam_role_policy" "github_deploy"/,/resource "aws_cloudwatch_metric_alarm" "dlq"/p' infra/terraform/modules/enrichment/main.tf)"
if grep -Fq '"s3:*"' <<<"$github_policy"; then
  echo "GitHub deployment role must not regain wildcard S3 access." >&2
  exit 1
fi
grep -Fq '"s3:DeleteObjectVersion"' infra/terraform/modules/enrichment/main.tf
grep -Fq '"s3:ListBucketVersions"' infra/terraform/modules/enrichment/main.tf
grep -Eq 'database_instance_class[[:space:]]*=[[:space:]]*"db.t4g.small"' infra/terraform/production/main.tf
grep -Eq 'worker_desired_count[[:space:]]*=[[:space:]]*2' infra/terraform/production/main.tf
if contains_forbidden -RIn --exclude-dir='.terraform' --exclude='test-production-config.sh' 'PowerUserAccess' infra scripts services/enrichment/app; then
  echo "The AWS deployment role must not use broad PowerUserAccess." >&2
  exit 1
fi
test ! -e services/enrichment/app/cloudflare.py || { echo "Legacy Cloudflare image transport must remain absent." >&2; exit 1; }
if contains_forbidden -RIniE 'celery|redis' services/enrichment README.md docs/hybrid-enrichment.md; then
  echo "Celery/Redis references must not remain in the production enrichment path or current runbooks." >&2
  exit 1
fi
if contains_forbidden -RInE 'p95.*<.*50|toBeLessThan\(50\)' apps/mobile/__tests__; then
  echo "JavaScript tests must not claim the Android field p95 gate." >&2
  exit 1
fi
grep -A5 -Fq '"op-sqlite"' apps/mobile/package.json
grep -A5 '"op-sqlite"' apps/mobile/package.json | grep -Fq '"sqlcipher": true'
if contains_forbidden -RIniE 'tflite|tensorflow|mobilenet|auto.?capture' apps/mobile; then
  echo "Automatic ML capture assets or wiring must not be shipped." >&2
  exit 1
fi
turnstile_store_line="$(grep -n 'gh secret set TURNSTILE_SECRET' scripts/go-live.sh | cut -d: -f1)"
access_lookup_line="$(grep -n 'access/organizations' scripts/go-live.sh | cut -d: -f1)"
[[ "$turnstile_store_line" -lt "$access_lookup_line" ]] || { echo "Turnstile secret must be stored before Access provisioning." >&2; exit 1; }
bash scripts/test-turnstile-recovery.sh
bash scripts/test-production-hardening.sh
bash scripts/test-budget-controls.sh
bash scripts/test-zero-cost-readiness.sh
bash scripts/test-waf-provisioning.sh
bash scripts/test-ci-portability.sh
if grep -RIn --include='*.sh' --exclude='test-production-config.sh' '\brg\b' scripts; then
  echo "CI shell scripts must not depend on runner-specific ripgrep." >&2
  exit 1
fi
if grep -RIE --exclude='test-production-config.sh' '(gho_[A-Za-z0-9]+|sk_live_[A-Za-z0-9]+|CLOUDFLARE_API_TOKEN=.{12})' scripts apps; then
  echo "Potential committed credential detected." >&2
  exit 1
fi
grep -Fq "RUNTIME_ROOT=\"\${XDG_CACHE_HOME:-\$HOME/.cache}/challanse-local-runtime\"" scripts/local-pilot.sh
grep -Fxq '.local-runtime' .dockerignore
grep -Fxq '**/*.key' .dockerignore
grep -Fq 'WHERE id <> %s AND active LIMIT 1' services/enrichment/app/local_seed.py
if grep -Fq "RUNTIME_ROOT=\"\$ROOT/" scripts/local-pilot.sh; then
  echo "Generated local runtime material must remain outside the repository." >&2
  exit 1
fi
echo "Production configuration checks passed."
# identity_links has no updated_at column; local seeding must remain schema-compatible.
identity_link_seed_sql="$(sed -n '/INSERT INTO identity_links/,/"""/p' services/enrichment/app/local_seed.py)"
if printf '%s\n' "$identity_link_seed_sql" | grep -q 'updated_at'; then
  fail "local seed must not write identity_links.updated_at"
fi

grep -Fq 'OLLAMA_URL=http://ollama:11434' scripts/local-pilot.sh \
  || fail "local pilot must use the private Ollama network alias"
grep -Fq 'docker network connect --alias ollama' scripts/local-pilot.sh \
  || fail "local pilot must attach Ollama to the private OCR network"
grep -Fq 'python -m app.local_acceptance prepare' scripts/local-pilot.sh \
  || fail "local acceptance must use an isolated temporary tenant"
grep -Fq 'python -m app.local_acceptance cleanup' scripts/local-pilot.sh \
  || fail "local acceptance must clean its temporary tenant"
grep -Fq 'No successful acceptance report from the last 24 hours exists' scripts/local-pilot.sh \
  || fail "evidence generation must require recent successful acceptance"
grep -Fq 'python -m app.local_acceptance verify-clean' scripts/local-pilot.sh \
  || fail "evidence generation must verify acceptance cleanup"
grep -Fq '"po_number,material_code,quantity,unit\n"' scripts/generate-local-fixtures.py \
  || fail "synthetic Tally fixture must match the importer schema"
if grep -Fq 'material_description,unit,po_quantity' scripts/generate-local-fixtures.py; then
  fail "synthetic Tally fixture must not use the obsolete schema"
fi
grep -Fq 'test-data) test_data ;;' scripts/local-pilot.sh \
  || fail "local pilot must expose a safe test-data refresh command"
grep -Fq 'ChallanSe Local Synthetic Testing Runbook' docs/local-testing-runbook.md \
  || fail "beginner-safe local testing runbook is missing"
grep -Fq 'queueDepthAfterWait' docs/local-testing-runbook.md \
  || fail "local testing runbook must document acceptance validation"
