# Hybrid enrichment operations

## Authority and boundaries

- Cloudflare D1 is the authoritative mobile-ingestion ledger; private original WebP images remain in R2.
- AWS Mumbai (`ap-south-1`) runs FastAPI, SQS workers, encrypted PostgreSQL, reconciliation, digest generation, and telemetry reports.
- PostgreSQL is authoritative for enrichment and reconciliation state. Signed callbacks expose only the reviewer projection in D1.
- Manual review and Tally CSV reconciliation are active. OCR, GST, WhatsApp, Slack, and credit providers default to `disabled` and must not be marketed as active.
- Cloudflare storage is globally distributed. The system does not claim India-only data residency.

## Request security

Every Cloudflare-to-AWS and AWS-to-Cloudflare request includes:

- `X-ChallanSe-Key-Id`
- `X-ChallanSe-Timestamp`
- `X-ChallanSe-Request-Id`
- `X-ChallanSe-Content-SHA256`
- `X-ChallanSe-Signature`

The canonical value is the newline-joined timestamp, request ID, key ID, uppercase method, path, and body SHA-256. Receivers reject invalid digests, signatures, timestamps older than 60 seconds, unknown key IDs, and replayed request IDs. Cloudflare Access service credentials are required in addition to HMAC.

Each direction has active and next keys. Rotation is two-phase:

```bash
./scripts/go-live.sh rotate-enrichment-keys stage
# Deploy and verify both sides accept the staged next keys.
./scripts/go-live.sh rotate-enrichment-keys promote
# Deploy and verify again. The prior active key remains the overlap key.
```

Never skip the deployment and verification between phases.

## Durable processing

`POST /v1/events/receipts` validates authentication, reserves the request ID and receipt UUID in PostgreSQL, and returns `202` only after SQS accepts the event. Duplicate requests return the existing ingress result. The SQS worker uses long polling, extends visibility while processing, and deletes a message only after the PostgreSQL transaction and Cloudflare callback succeed. Stage uniqueness and a transactional outbox make duplicate SQS delivery safe.

The worker fetches the private image through the signed Cloudflare endpoint, verifies size and SHA-256, confirms WebP content, converts it to PNG in memory, and then invokes the selected OCR adapter. Confidence below 60 percent or provider failure becomes `NEEDS_HUMAN_REVIEW`.

## Provider activation

| Provider | Production default | Activation gate |
| --- | --- | --- |
| Textract | `disabled` | Approved AWS permissions, cost budget, redaction review, timeout and low-confidence tests |
| GST | `disabled` | Legal approval, real endpoint credentials, 3-second timeout tests, encrypted statutory fields |
| Credit queue | `disabled` | GST verified, banking/legal approval, exact `AA_1.0.0` contract acceptance |
| WhatsApp | `disabled` | Business account and approved four-hour digest template |
| Slack | `disabled` | Approved webhook and redaction review |

Mock providers are forbidden when `ENVIRONMENT=production`. GST mismatch or failure never emits a credit message.

## Failure recovery

- SQS moves a message to the DLQ after five receives; messages are retained for 14 days.
- Replay is guarded and rate-limited to one message per second: `./scripts/go-live.sh replay-dlq`.
- ECS uses deployment circuit breakers and automatic rollback.
- Production RDS is Multi-AZ with seven-day automated backups and deletion protection. Restore evidence is required before release.
- Ninety-day image and one-year receipt/audit retention use tombstones across D1, R2, and PostgreSQL.

See `docs/aws-bootstrap.md` for account provisioning and `docs/pilot-runbook.md` for release acceptance.
