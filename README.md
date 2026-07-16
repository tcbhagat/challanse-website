# ChallanSe controlled pilot

Production monorepo for a capped, real-data construction receipt pilot. Cloudflare remains the durable capture edge; asynchronous enrichment is isolated behind disabled-by-default provider adapters.

## Applications

- `challanse.constrovet.com`: static buyer landing page and protected pilot-request form.
- `review.challanse.constrovet.com`: Cloudflare Access-protected reviewer inbox.
- `api.challanse.constrovet.com`: Cloudflare Worker API, queue consumer, and retention scheduler.
- `apps/mobile`: Android 8+ offline-first capture app for enrolled site devices.
- `services/enrichment`: signed FastAPI/SQS service for enrichment, reconciliation, grouped digest records, and telemetry.

Private WebP images are stored in R2 and capture records in D1. AWS Mumbai runs SQS workers and encrypted PostgreSQL for enrichment and reconciliation. The Android queue uses OP-SQLite compiled with SQLCipher, a Keystore-held database key, 256 KB resumable upload parts, and a manual shutter. Manual review and Tally CSV reconciliation are active; OCR, GST, WhatsApp, Slack, and credit adapters remain disabled until separately approved.

## Local validation

Requires Node.js 24, Java 17, and the Android SDK for the Android build.

```bash
npm ci
npm run check
npm test
npm run test:enrichment
npm run build
bash scripts/test-edge-integration.sh
bash scripts/test-production-config.sh
npm run build --workspace @challanse/mobile
```

The integration test creates an isolated local D1 database and proves enrollment, bootstrap, durable upload, idempotency, and replay rejection.

## Cloudflare resources

Production setup is driven by the guarded CLI. It first prepares Cloudflare without changing Namecheap, verifies propagation, and records explicit website, app, and email acceptance. Production then refuses to proceed unless local `main` is clean and current, CI is green, authentication works, and `constrovet.com` is active in Cloudflare.

On Ubuntu, install the Android signing utility before `configure-github`:

```bash
sudo apt update
sudo apt install -y openjdk-17-jdk-headless
```

```bash
cd /home/taran/challanse-website
git pull --ff-only

./scripts/go-live.sh dns-onboard
# Enter the two printed nameservers in Namecheap, then wait.
./scripts/go-live.sh dns-status
./scripts/go-live.sh dns-accept
./scripts/go-live.sh preflight
./scripts/go-live.sh provision
./scripts/go-live.sh configure-github
./scripts/go-live.sh rotate-signing
./scripts/go-live.sh configure-aws
./scripts/go-live.sh configure-enrichment
./scripts/go-live.sh accept-staging /secure/staging-acceptance.json
./scripts/go-live.sh accept-android-field /secure/android-field-acceptance.json
./scripts/go-live.sh harden-github
./scripts/go-live.sh deploy
```

The keystore previously displayed in an editor is not release-safe. Before any deployment or APK distribution, run `rotate-signing`, type the exact confirmation phrase shown by the CLI, back up the replacement outside the repository, and verify that GitHub records both the new fingerprint and the revoked fingerprint. Never open or paste a `.jks` file.

`dns-onboard` idempotently creates or reuses the Cloudflare zone, preserves `www` and the legacy Google MX record as DNS-only, and replaces the retired `app` origin with a proxied `301` redirect to `https://www.constrovet.com/app/`. It aborts on conflicts and prints the exact nameservers for the owner to enter manually. `provision` then creates D1, private R2, receipt and dead-letter queues, Turnstile, the reviewer Access application, and the landing DNS record. If a first run stops after Turnstile creation, the next run retains an existing GitHub secret or explicitly confirms one API rotation before sending the replacement directly to GitHub. The CLI saves only non-secret state under `~/.config/challanse/`; credentials are held in memory or sent directly to GitHub environment secrets. It never changes Namecheap nameservers itself.

Set `PILOT_DEPLOY_ENABLED` as a repository variable. Configure the GitHub `production` environment with required reviewer approval and the remaining values:

| Type | Name |
| --- | --- |
| Repository variable | `PILOT_DEPLOY_ENABLED` (`false` until cutover approval) |
| Variable | `CLOUDFLARE_D1_DATABASE_ID` |
| Variable | `CLOUDFLARE_ACCESS_TEAM_DOMAIN` |
| Variable | `CLOUDFLARE_ACCESS_AUD` |
| Variable | `TURNSTILE_SITE_KEY` |
| Secret | `CLOUDFLARE_ACCOUNT_ID` |
| Secret | `CLOUDFLARE_API_TOKEN` |
| Secret | `DEVICE_TOKEN_PEPPER` |
| Secret | `TURNSTILE_SECRET` |
| Secret | `CHALLANSE_KEYSTORE_BASE64` |
| Secret | `CHALLANSE_KEYSTORE_PASSWORD` |
| Secret | `CHALLANSE_KEY_ALIAS` |
| Secret | `CHALLANSE_KEY_PASSWORD` |
| Secret | `EDGE_TO_ENRICHMENT_HMAC_KEY` and `EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY` |
| Secret | `ENRICHMENT_TO_EDGE_HMAC_KEY` and `ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY` |
| Secret | `ENRICHMENT_ACCESS_CLIENT_ID` and `ENRICHMENT_ACCESS_CLIENT_SECRET` |
| Variable | `EDGE_TO_ENRICHMENT_HMAC_KEY_ID` and `EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID` |
| Variable | `ENRICHMENT_TO_EDGE_HMAC_KEY_ID` and `ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID` |
| Variable | `AWS_ENRICHMENT_BOOTSTRAPPED` (`false` until AWS acceptance) |

The Cloudflare token needs Zone Read, Zone DNS Edit, Dynamic URL Redirects Edit, and Zone Edit for onboarding, plus Workers Scripts, D1, R2, Queues, Turnstile Sites, Access Apps and Policies, and Access Organization Read for production provisioning. Scope it to the Constrovet account and domain. Initialize the account’s Zero Trust organization once before `provision`. Install `cloudflared` for authenticated production verification. The CLI generates the device pepper with a cryptographically secure 32-byte random value and never commits it.

## Seed a real site

Prepare a private vendor file containing one to four real vendors:

```json
[
  {"id":"vendor-approved-id","name":"Approved vendor name","initials":"AV","color":"#006D77"}
]
```

Seed, download, install, enroll, and capture one real receipt before final verification:

```bash
./scripts/go-live.sh seed --vendors-file /secure/challanse-vendors.json
./scripts/go-live.sh download-apk
# Install the downloaded APK, enroll through the reviewer, capture and sync one real receipt.
./scripts/go-live.sh verify
```

The first reviewer entered during provisioning is the administrator; the second is a controller. The administrator creates separate 10-minute enrollment QR codes in the reviewer app. The Android device exchanges its code once, stores its revocable credential in Android Keystore, and downloads the real site/vendor configuration.

## Deployment safety

Production deployment is intentionally disabled unless the guarded CLI temporarily sets `PILOT_DEPLOY_ENABLED=true`. Protected `main` requires `validate`, `android`, `enrichment`, `security`, `integration`, and `terraform-plan`. The CLI also requires rotated signing evidence, AWS bootstrap, staging acceptance, Android field acceptance, and exact `DEPLOY <commit-sha>` confirmation.

The enrichment API returns `202` only after SQS accepts a signed, idempotently reserved event. SQS workers acknowledge only after PostgreSQL commit and a successful Cloudflare callback. Staging may use deterministic mock adapters; production forbids mocks and keeps external providers disabled until credentials, legal approval, redaction review, and provider-specific acceptance tests are complete. See `docs/hybrid-enrichment.md`.

The capped pilot has no formal SLA. Its documented target is recovery within one business day with no more than 24 hours of data loss. AWS costs require an operator-approved budget. Cloudflare storage remains globally distributed, so India-only residency is not claimed.

Follow `docs/dns-cutover.md`, `docs/aws-bootstrap.md`, `docs/pilot-runbook.md`, and `docs/release-readiness.md` before field rollout. Repository code does not prove that live AWS accounts, restore drills, or field acceptance exist; those require recorded operator evidence.

Emergency stop, preserving every receipt and image:

```bash
./scripts/rollback-production.sh
./scripts/rollback-production.sh --revoke-devices
```
