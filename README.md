# ChallanSe production platform

Multi-tenant construction receipt capture and reconciliation for Android field devices and finance reviewers. AWS Mumbai is the authoritative application data plane; Cloudflare provides stateless DNS, WAF, Access, Turnstile, and routing.

## Product scope

- Offline-first Android 8+ manual capture with SQLCipher, Android Keystore, WorkManager, 256 KB resumable parts, seven-day acknowledged-image grace, and indefinite retention of unsynced receipts.
- Enterprise OIDC reviewer access with MFA, immutable issuer/subject identities, organization/site roles, PostgreSQL row-level security, and tenant-scoped S3 objects.
- Textract-assisted OCR, manual correction, optimistic review locking, Tally CSV reconciliation, audit history, and organization-scoped JSON/CSV exports.
- Managed Google Play private AAB distribution for approved client organization IDs.
- GST, credit, WhatsApp, Slack, and individual notifications remain disabled.

Initial design capacity is three clients, 100 devices, about 20 sites, and 1,000 receipts daily. The service target is 99.5% availability, RPO no greater than one hour, and RTO no greater than eight hours. These are release targets, not contractual guarantees, until production monitoring and restore exercises provide evidence.

## Runtime boundaries

- `challanse.constrovet.com`: buyer site and protected pilot-request endpoint.
- `review.challanse.constrovet.com`: Access-protected reviewer and tenant administration UI.
- `api.challanse.constrovet.com`: stateless Cloudflare Worker routing to the private AWS API.
- `apps/mobile`: Android capture and synchronization application.
- `services/enrichment`: FastAPI ingestion, SQS workers, PostgreSQL workflows, OCR, review, reconciliation, retention, exports, and telemetry.
- `infra/terraform`: separate staging and production AWS account stacks in `ap-south-1`.

Original WebP images live in private, versioned, SSE-KMS S3. Receipt, reviewer, device, OCR, reconciliation, and audit records live in RDS PostgreSQL. Cloudflare does not store application receipt payloads.

## Local validation

Requires Node.js 24, Java 17, Android SDK, Docker, Terraform 1.9, ShellCheck, and GitHub CLI.

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

Integration tests use PostgreSQL and LocalStack containers to exercise RLS, idempotency, invitations, SQS, reconciliation, and lifecycle jobs.

## Guarded production sequence

```bash
cd /home/taran/challanse-website
git pull --ff-only

./scripts/go-live.sh preflight
./scripts/go-live.sh provision
./scripts/go-live.sh configure-identity
./scripts/go-live.sh configure-github
./scripts/go-live.sh rotate-signing
./scripts/go-live.sh configure-aws
./scripts/go-live.sh configure-enrichment
./scripts/go-live.sh configure-tunnel-origin
./scripts/go-live.sh configure-play
./scripts/go-live.sh accept-staging /secure/staging-acceptance.json
./scripts/go-live.sh accept-android-field /secure/android-field-acceptance.json
./scripts/go-live.sh accept-security /secure/security-acceptance.json
./scripts/go-live.sh accept-capacity /secure/capacity-acceptance.json
./scripts/go-live.sh accept-recovery /secure/recovery-acceptance.json
./scripts/go-live.sh accept-client /secure/client-acceptance.json
./scripts/go-live.sh harden-github
./scripts/go-live.sh deploy
```

The previously exposed keystore is revoked and must never be opened, copied, or reused. `rotate-signing` creates a new upload key outside the repository, records the revoked and active upload fingerprints, and preserves Google Play's separate app-signing fingerprint. Production builds AABs only; direct APK distribution is prohibited.

`provision` is intentionally stateless: it configures Turnstile, reviewer Access, DNS, GitHub variables, and routing without creating D1, R2, or Cloudflare Queues. `configure-identity` permits one enterprise OIDC provider, forces MFA, and leaves PostgreSQL membership as the final authorization check. After Terraform creates the private HTTPS ALB, `configure-tunnel-origin` sets Cloudflare Tunnel to validate its certificate with `api.challanse.constrovet.com` as the TLS server name; `noTLSVerify` is never enabled.

## Tenant onboarding

Prepare a private vendor file with real owner-approved data:

```json
[
  {"id":"vendor-approved-id","name":"Approved vendor name","initials":"AV","color":"#006D77"}
]
```

```bash
./scripts/go-live.sh seed --vendors-file /secure/challanse-vendors.json
./scripts/go-live.sh set-play-track internal
./scripts/go-live.sh deploy
./scripts/go-live.sh download-aab
./scripts/go-live.sh verify
```

The seed command runs a guarded private ECS bootstrap task and binds the first administrator to an immutable OIDC issuer/subject. Additional users join through single-use membership invitations. Android devices enroll with separate single-use 10-minute codes and store revocable device credentials in Android Keystore.

Managed Google Play organization availability is configured in Play Console and evidenced by a canonical organization-ID hash; the IDs are not committed. Promote `internal` to `alpha`, and then `production`, only after recorded client acceptance.

## Release and operations

Production remains disabled unless the guarded CLI temporarily sets `PILOT_DEPLOY_ENABLED=true`; it restores the variable to `false` on completion or failure. Protected `main` requires `validate`, `android`, `enrichment`, `security`, `integration`, and `terraform-plan`. Security, capacity, and recovery reports must reference hashed evidence artifacts and pass strict typed thresholds before deployment. Every release manifest records commit, workflow run, AAB checksum, upload and Play signing fingerprints, revoked fingerprint, SBOM, image digest, migrations, acceptance evidence, and deployed Worker versions.

Production OCR uses Textract. GST, credit, WhatsApp, Slack, and individual alerts fail closed and remain visibly disabled. Do not claim GST validation, automated statutory compliance, credit eligibility, OCR accuracy, savings, ISO certification, or DPDP legal compliance without independent evidence.

Business-hours support is documented in `docs/pilot-runbook.md`; no 24×7 support is offered. Follow `docs/aws-bootstrap.md`, `docs/hybrid-enrichment.md`, `docs/release-readiness.md`, and `docs/pilot-runbook.md` before onboarding a client.

The three-month pilot is governed by `docs/pilot-budget.md`: INR 450,000 total cash ceiling, INR 60,000 combined monthly cloud ceiling, separate staging/production budgets, two-operator alerts, and stop/reapproval gates. Passing technical checks does not authorize expenditure beyond those controls.

Emergency stop preserves server data and every device's local queue:

```bash
./scripts/rollback-production.sh
./scripts/rollback-production.sh --revoke-devices
```
