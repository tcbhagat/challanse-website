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

Production setup is driven by the guarded CLI. It refuses to proceed unless local `main` is clean and current, CI is green, GitHub and Cloudflare authentication work, and `constrovet.com` is already an active Cloudflare zone.

```bash
cd /home/taran/challanse-website
git pull --ff-only

./scripts/go-live.sh preflight
./scripts/go-live.sh provision
./scripts/go-live.sh configure-github
./scripts/go-live.sh deploy
```

`provision` idempotently creates D1, private R2, receipt and dead-letter queues, Turnstile, the reviewer Access application, and the landing DNS record. It saves only non-secret resource IDs under `~/.config/challanse/`; credentials are held in memory or sent directly to GitHub environment secrets. It never changes nameservers, mail records, or existing Constrovet records.

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

The Cloudflare token needs Workers Scripts, D1, R2, Queues, Turnstile Sites, Access Apps and Policies, Access Organization Read, and Zone DNS permissions scoped to the Constrovet account/zone. Initialize the account’s Zero Trust organization once before `provision`. Install `cloudflared` for the authenticated production verification. The CLI generates the device pepper with a cryptographically secure 32-byte random value and never commits it.

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

Production deployment is intentionally disabled unless `PILOT_DEPLOY_ENABLED=true`. Protected `main` runs contract, Worker, migration, integration, security audit, reviewer, accessibility, Android unit, and Android debug-build checks first. Production uses the GitHub `production` environment approval gate.

The capped pilot is designed around the free allowances, not an uptime guarantee: [D1 free-plan recovery is limited](https://developers.cloudflare.com/d1/platform/limits/), [R2 includes 10 GB-month of standard storage](https://developers.cloudflare.com/r2/pricing/), and [Queues includes 10,000 operations per day](https://developers.cloudflare.com/queues/platform/pricing/). Recheck these limits before enabling production because provider allowances can change.

Follow `docs/dns-cutover.md` before changing nameservers and `docs/pilot-runbook.md` for field rollout and rollback. Zero-budget operation provides no uptime SLA and no independent off-provider backup.

Emergency stop, preserving every receipt and image:

```bash
./scripts/rollback-production.sh
./scripts/rollback-production.sh --revoke-devices
```
