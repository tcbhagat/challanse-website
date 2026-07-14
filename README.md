# ChallanSe controlled pilot

Production monorepo for a capped, real-data construction receipt pilot. The existing Mitranet implementation remains independent until field acceptance.

## Applications

- `challanse.constrovet.com`: static buyer landing page and protected pilot-request form.
- `review.challanse.constrovet.com`: Cloudflare Access-protected reviewer inbox.
- `api.challanse.constrovet.com`: Cloudflare Worker API, queue consumer, and retention scheduler.
- `apps/mobile`: Android 8+ offline-first capture app for enrolled site devices.

Private WebP images are stored in R2, receipt and audit records in D1, and receipt identifiers only in Cloudflare Queues. No OCR, GST, AWS, messaging, or synthetic production data is used.

## Local validation

Requires Node.js 24, Java 17, and the Android SDK for the Android build.

```bash
npm ci
npm run check
npm test
npm run build
bash scripts/test-edge-integration.sh
npm run build --workspace @challanse/mobile
```

The integration test creates an isolated local D1 database and proves enrollment, bootstrap, durable upload, idempotency, and replay rejection.

## Cloudflare resources

Create these resources before enabling deployment:

```bash
npx wrangler d1 create challanse-pilot
npx wrangler r2 bucket create challanse-receipts
npx wrangler queues create challanse-receipts
npx wrangler queues create challanse-receipts-dlq
```

Create a Turnstile widget for `challanse.constrovet.com` and a Cloudflare Access self-hosted application covering `review.challanse.constrovet.com/*` and reviewer/admin API paths. Allow only the two approved reviewer email addresses.

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

The Cloudflare token needs only Workers Scripts, D1, R2, Queues, and Zone DNS permissions for the ChallanSe zone. Generate the device pepper with a cryptographically secure 32-byte random value. Never commit either value.

## Seed a real site

Prepare reviewed values without embedding them in source control:

```bash
SITE_ID=site-pilot-01 \
SITE_NAME='Approved site name' \
REVIEWER_EMAIL='controller@example.com' \
WIFI_SSIDS_JSON='["Approved site Wi-Fi"]' \
VENDORS_JSON='[{"id":"vendor-01","name":"Approved vendor","initials":"AV","color":"#006D77"}]' \
node scripts/bootstrap-pilot.mjs > /tmp/challanse-pilot.sql

npx wrangler d1 execute challanse-pilot --remote --file /tmp/challanse-pilot.sql
```

An administrator then creates a 10-minute enrollment QR in the reviewer app. The Android device exchanges it once, stores its revocable credential in Android Keystore, and downloads the real site/vendor configuration.

## Deployment safety

Production deployment is intentionally disabled unless `PILOT_DEPLOY_ENABLED=true`. Protected `main` runs contract, Worker, migration, integration, security audit, reviewer, accessibility, Android unit, and Android debug-build checks first. Production uses the GitHub `production` environment approval gate.

The capped pilot is designed around the free allowances, not an uptime guarantee: [D1 free-plan recovery is limited](https://developers.cloudflare.com/d1/platform/limits/), [R2 includes 10 GB-month of standard storage](https://developers.cloudflare.com/r2/pricing/), and [Queues includes 10,000 operations per day](https://developers.cloudflare.com/queues/platform/pricing/). Recheck these limits before enabling production because provider allowances can change.

Follow `docs/dns-cutover.md` before changing nameservers and `docs/pilot-runbook.md` for field rollout and rollback. Zero-budget operation provides no uptime SLA and no independent off-provider backup.
