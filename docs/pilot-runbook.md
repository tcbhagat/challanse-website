# Client rollout and operations runbook

## Approved first-release scope

- Up to three clients, 100 enrolled Android devices, about 20 sites, and 1,000 receipts daily.
- Managed Google Play private AAB distribution only.
- Textract-assisted OCR, manual verification, Tally reconciliation, and audit exports are active.
- GST, credit, WhatsApp, Slack, automated statutory claims, and individual notifications are disabled.
- Business-hours support: Monday–Friday, 09:00–18:00 India Standard Time, excluding published holidays. Do not advertise 24×7 support.

## Release sequence

0. Confirm the current approval envelope and spending gates in `pilot-budget.md`; no persistent AWS provisioning is permitted without the required budget and two-operator alerts.

1. Rotate the exposed upload identity and prove the revoked fingerprint cannot pass CI.
2. Enable Google Play App Signing and configure the private application and client organization availability.
3. Provision separate staging and production AWS accounts using `docs/aws-bootstrap.md`.
4. Configure enterprise OIDC with MFA and verify PostgreSQL membership remains the final authorization decision.
5. Run `validate`, `android`, `enrichment`, `security`, `integration`, and `terraform-plan`.
6. Process at least 20 synthetic staging receipts with no loss, duplication, or cross-tenant access.
7. Record staging, Android, security, capacity, and recovery acceptance using the templates in `docs/templates/`; keep the referenced evidence files outside the repository.
8. Record first-client acceptance, configure the `internal` Play track, and run `harden-github`.
9. Verify every acceptance report and evidence artifact SHA-256 before typing the exact `DEPLOY <commit-sha>` confirmation.
10. Verify the release manifest against the AAB, Play certificates, SBOM, infrastructure evidence, and acceptance hashes.
11. Promote to `alpha` and then `production` only after explicit client acceptance evidence.

## Field acceptance

1. Bootstrap only owner-approved organizations, sites, Wi-Fi policies, OIDC administrators, and vendors.
2. Enroll two devices with separate single-use 10-minute codes; prove expiry, reuse denial, revocation, and tenant/site scope.
3. Capture 20 receipts offline, restart one app, reboot one device, reconnect while charging on approved Wi-Fi, and confirm exactly-once cloud records.
4. Verify checksum, private S3 image streaming, replay denial, cross-tenant denial, and concurrent reviewer `409` behavior.
5. Import an approved Tally CSV and verify validation, checksum deduplication, unit normalization, unmatched rows, and red over-quantity rows.
6. Confirm the UI states OCR as active and GST, credit, WhatsApp, and Slack as disabled.

## Daily operations

- Devices retain unsynced receipts indefinitely. Acknowledged local images are deleted only after seven days.
- Approved SSID is a data-cost control and is never treated as physical-presence proof.
- Review queue age, DLQ, API errors, database capacity, upload failures, certificate expiry, and budget alarms each business day.
- Generate organization-scoped audit exports through authenticated reviewer routes; never export one tenant's data from another tenant context.
- Never log images, OCR text, credentials, GST/IRN/Udyam/bank values, or personal contacts.

## Backup and recovery

- Verify automated backups daily and perform a quarterly isolated PostgreSQL/S3 restoration exercise.
- Accept production only after a production-like restore demonstrates RPO no greater than one hour and RTO no greater than eight hours.
- Live images are deleted after 90 days and receipt/audit rows after one year. Encrypted recovery copies follow the documented 35-day backup schedule and are a disclosed retention exception.
- Record restore start/end, selected recovery point, object and row counts, application checks, operator identity, and evidence hashes.

## Incident response

1. Disable new releases with `./scripts/rollback-production.sh`; device queues and authoritative AWS data remain intact.
2. Add `--revoke-devices` only for device-credential compromise; re-enrollment is then mandatory.
3. Contain access through Cloudflare Access membership revocation, device revocation, HMAC key overlap rotation, or AWS service scaling as appropriate.
4. Replay DLQ events only after fixing the root cause and confirming the exact environment and queue.
5. Restore to isolated infrastructure before destructive recovery or comparison.
6. Record timeline, affected receipt UUIDs, tenant scope, recovery evidence, notification decision, and residual risk without copying receipt contents into logs.

Before client two, train a second operator and require independent deployment approval. Availability and recovery objectives are operational targets, not an SLA, until incorporated into a signed client agreement.
