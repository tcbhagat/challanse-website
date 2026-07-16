# Controlled pilot runbook

## Approved scope

- One construction site, no more than five enrolled Android devices and two reviewers.
- Approximately 50 receipts per day; synchronized images target 750 KB.
- Directly signed APK distribution; manual controller verification is authoritative.
- No formal SLA. Pilot recovery target is one business day with no more than 24 hours of data loss.

## Release gates

1. Rotate the exposed Android signing identity with `rotate-signing`; verify the active and revoked fingerprints differ and preserve the encrypted offline backup separately.
2. Provision separate staging and production AWS accounts using `docs/aws-bootstrap.md`.
3. Run all required CI checks: `validate`, `android`, `enrichment`, `security`, `integration`, and `terraform-plan`.
4. Deploy staging with providers disabled and process at least 20 synthetic receipts with no loss or duplication.
5. Record the reviewed staging report using `accept-staging`.
6. On Android 8/API 26 with no more than 2 GB RAM, run 100 real binary writes from 500 KB to 5 MB; require p95 below 50 ms, encryption proof, restart/reboot recovery, and no metadata loss.
7. Record the field report using `accept-android-field`.
8. Run `harden-github`; keep `PILOT_DEPLOY_ENABLED=false` until the guarded deployment begins.
9. Deploy only after typing `DEPLOY <commit-sha>` and verify the release manifest against the APK.

Templates are in `docs/templates/`. Acceptance hashes prove which reviewed files were approved; keep the original reports in the controlled release evidence store.

## Field acceptance

1. Seed only owner-approved site, Wi-Fi, reviewer, and vendor data.
2. Enroll two devices using separate single-use 10-minute QR codes. Prove expiry, reuse rejection, device cap, and revocation.
3. Capture 20 receipts offline, restart one app, reboot one device, reconnect while charging on approved Wi-Fi, and confirm exactly-once cloud records.
4. Verify image checksum, private streaming, cross-site denial, replay denial, and concurrent reviewer `409` behavior.
5. Import a synthetic then approved Tally CSV; verify duplicate detection, unit handling, and red `Site Received > PO Quantity` rows.
6. Confirm provider status visibly remains disabled for OCR, GST, WhatsApp, Slack, and credit unless separate approval evidence exists.

## Operations

- Devices never delete unsynced data. Acknowledged local images have a seven-day grace period.
- At 70% of the pilot allowance, warn administrators; at 90%, pause uploads while preserving local queues.
- R2 images are deleted after 90 days and remaining receipt/audit data after one year through tombstone workflows.
- Generate four-hour digest records without individual notifications. Delivery remains disabled until approved.
- Generate nightly friction reports for write latency above 100 ms, site sync failure above 20%, and vendor OCR confidence below 70%.
- Never log images, OCR text, credentials, GST/IRN/Udyam/bank values, or personal contacts.

## Incident response

1. Run `./scripts/rollback-production.sh` to disable deployment while preserving D1, R2, PostgreSQL, SQS, and device queues.
2. Add `--revoke-devices` only for credential compromise; this requires re-enrollment.
3. Replay DLQ messages only after the root cause is fixed and the exact queue ARN is confirmed.
4. Restore RDS to an isolated instance before any destructive production recovery.
5. Record incident timeline, affected receipt UUIDs, recovery evidence, and residual risk without copying receipt contents into logs.

Losing the direct-distribution signing key prevents seamless APK updates. Maintain one verified encrypted offline backup and store its password separately.
