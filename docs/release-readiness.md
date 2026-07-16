# Release readiness

Production is intentionally blocked until every evidence gate below is complete. Passing repository tests does not make an APK releasable.

## Implemented code gates

- Cloudflare ingestion, private R2 images, D1 ledger, reviewer proxy, resumable 256 KB uploads, and signed enrichment callbacks.
- AWS ECS, RDS, SQS, DLQ, KMS, Secrets Manager, EventBridge, CloudWatch, budgets, and OIDC Terraform modules for separate staging and production accounts.
- SQS receipt ingestion with durable idempotency, crash-window recovery, database-backed replay protection, long-polling workers, visibility extension, and transactional outbox delivery.
- Manual field capture, SQLCipher configuration, reboot recovery, charging and approved-Wi-Fi constraints, duplicate-frame cooldown, and icon-only camera permission recovery.
- OCR, GST, notification, credit, and Slack provider interfaces that fail closed and remain disabled in production by default.
- Immutable release manifest generation containing the APK checksum, active and revoked signing fingerprints, commit, workflow run, deployed image, migration, Worker versions, and acceptance evidence hashes.

## Blocking operator evidence

1. Rotate the exposed pre-release Android signing identity and keep the replacement outside the repository.
2. Create separate AWS Organizations accounts for staging and production, then bootstrap the encrypted Terraform state and GitHub OIDC roles.
3. Configure active and next HMAC keys for both Cloudflare-to-AWS directions.
4. Apply Terraform in staging and complete backup restore, ECS rollback, DLQ replay, and security acceptance.
5. Populate and accept the staging report from `docs/templates/staging-acceptance.json`.
6. Run the Android 8 / 2 GB field profile, including 100 realistic writes, SQLCipher proof, reboot recovery, and interrupted-upload recovery.
7. Populate and accept the field report from `docs/templates/android-field-acceptance.json`.
8. Apply GitHub hardening, verify all HTTPS domains, then use the guarded deployment command.

No production APK may be distributed and `PILOT_DEPLOY_ENABLED` must remain `false` until all eight gates have recorded evidence.
