# Production release readiness

Production stays blocked until every gate has immutable evidence. Passing repository tests does not make a release client-ready.

## Gate 1: release identity

- The exposed certificate fingerprint is recorded as revoked and rejected by CI.
- Google Play App Signing is enabled for the existing package ID.
- The active upload key is stored outside the repository, backed up encrypted, and present only in the GitHub production environment.
- The Play app-signing certificate and upload certificate are distinct and recorded.
- The AAB checksum, SBOM, provenance, workflow run, commit, and all three fingerprints appear in the release manifest.

## Gate 2: tenant isolation and identity

- Cloudflare Access accepts only the selected enterprise OIDC provider and requires MFA.
- The zone-level Cloudflare Free Managed Ruleset is enabled and revalidated by the guarded deploy command.
- User identity is keyed by immutable OIDC issuer and subject; email is only an attribute.
- PostgreSQL RLS denies missing, conflicting, inactive, and cross-organization tenant contexts.
- Every reviewer, image, audit, reconciliation, device, and admin route passes two-tenant isolation tests.
- Single-use membership and device enrollment codes pass expiry, reuse, concurrency, and revocation tests.

## Gate 3: transactional reliability

- `IMAGE_FETCH`, `OCR`, `GST`, `EDGE_CALLBACK`, and `CREDIT_DELIVERY` are independently idempotent stages.
- OCR/GST providers return values only; PostgreSQL state, encrypted audit, workflow state, and outbound events commit atomically.
- Transactional outbox leasing, exponential retry, idempotency, terminal failure, and DLQ replay are proven.
- Callback failure does not repeat OCR or GST.
- GST and credit delivery remain disabled and no credit event can be emitted while disabled.

## Gate 4: AWS data platform

- Staging and production use separate AWS accounts and encrypted, locked Terraform state.
- Production API and workers run across two availability zones behind a private origin reached through Cloudflare Tunnel.
- RDS is Multi-AZ with deletion protection, 14-day automated PITR, daily cross-account recovery copies retained 35 days, and a successful quarterly restore exercise.
- Private S3 has public access blocked, versioning, SSE-KMS, tenant/site prefixes, lifecycle controls, and tested version-aware deletion.
- Queue age, queue depth, DLQ, API 5xx, database capacity, upload failure, certificate, and budget alarms deliver to trained operators.

## Gate 5: Android and ingestion

- SQLCipher activation, wrong-key rejection, raw-file encryption, migration, restart, reboot, and package-replacement recovery are proven.
- One hundred 500 KB–5 MB writes on Android 8 / 2 GB complete with p95 below 50 ms and no metadata loss.
- Interrupted 256 KB uploads resume from the last server-confirmed part after app or OS termination.
- Final acknowledgement is returned only after S3 and PostgreSQL/outbox durability.
- Approved Wi-Fi is treated only as a cost policy; Play Integrity is only a risk signal.

## Gate 6: client workflows

- Private images, OCR confidence/raw JSON, manual correction, optimistic `409` conflicts, immutable audit history, and audit export pass acceptance.
- Tally imports prove schema validation, checksum deduplication, unit normalization, unmatched rows, and red over-quantity rows.
- Provider states are honest: OCR active; GST, credit, WhatsApp, and Slack disabled.
- Reviewer UI passes 360 px, tablet, desktop, keyboard, and screen-reader checks.

## Gate 7: resilience and capacity

- Failure injection covers S3 writes, PostgreSQL commits, SQS sends, provider calls, callbacks, worker termination, visibility expiry, and orphan cleanup.
- A production-like restore demonstrates RPO no greater than one hour and RTO no greater than eight hours.
- The system sustains 1,000 receipts/day and 100 devices reconnecting within ten minutes; final acknowledgement p95 is below two seconds after the last byte reaches the API, and the backlog drains within 15 minutes.
- Ninety-day live-image deletion and one-year receipt/audit deletion pass; backup retention exceptions are documented and access-controlled.
- Security, capacity, and recovery reports use the templates in `docs/templates/`, include UTC completion times, name at least one externally retained evidence artifact, and record each artifact's SHA-256.

## Gate 8: controlled client release

- All three domains have valid HTTPS and pass health, readiness, CORS, Access, upload, image, review, export, alarm, backup, and rollback checks.
- Staging, Android field, security, capacity, recovery, and client acceptance report hashes appear in the release manifest.
- The first client Managed Google Play organization ID is confirmed in Play Console.
- Two devices complete a 20-receipt offline field trial with no loss or duplicates.
- `PILOT_DEPLOY_ENABLED` returns to `false` automatically.

No AAB may be promoted beyond the approved private track until all gates pass. A second trained operator and independent production approval are mandatory before onboarding client two.
