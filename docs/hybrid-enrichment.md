# AWS-authoritative enrichment operations

## Authority and boundaries

- AWS Mumbai (`ap-south-1`) is authoritative for receipt images, metadata, reviewer state, devices, OCR, reconciliation, audit, retention, and exports.
- Original WebP images are private S3 objects encrypted with SSE-KMS and scoped by organization/site prefixes.
- RDS PostgreSQL is the system of record and enforces `organization_id` RLS on tenant tables.
- Cloudflare is stateless DNS, WAF, Access, Turnstile, replay control, and routing. It stores no receipt payloads.
- Textract OCR is active. GST, credit, WhatsApp, Slack, and individual notifications remain disabled.

## Ingestion contract

1. `POST /v1/uploads` creates an idempotent device-, organization-, site-, receipt-, and checksum-scoped session.
2. `PUT /v1/uploads/{id}/parts/{number}` stores a validated 256 KB part with the expected offset and SHA-256.
3. `GET /v1/uploads/{id}` returns confirmed parts and the next required offset.
4. `POST /v1/uploads/{id}/complete` assembles and validates WebP bytes, writes the final S3 object, and commits receipt, quota, workflow, and outbox state.
5. The API returns `202 RECEIVED` only after final S3 and PostgreSQL durability.

All mutating operations require device identity, tenant/site scope, timestamp, nonce, receipt UUID, and integrity metadata. Conditional counters prevent concurrent quota overruns. Lifecycle jobs delete orphaned parts and final objects left by failed completions.

## Request security

Service requests require Cloudflare service authentication plus directional HMAC headers:

- `X-ChallanSe-Key-Id`
- `X-ChallanSe-Timestamp`
- `X-ChallanSe-Request-Id`
- `X-ChallanSe-Content-SHA256`
- `X-ChallanSe-Signature`

Receivers reject unknown key IDs, bad body digests, stale timestamps, invalid signatures, and replayed request IDs. Active and next keys rotate in two phases:

```bash
./scripts/go-live.sh rotate-enrichment-keys stage
# Deploy and verify both sides accept active and next keys.
./scripts/go-live.sh rotate-enrichment-keys promote
# Deploy and verify again before retiring the overlap key.
```

## Durable processing

- Unique `(receipt_id, stage)` records isolate `IMAGE_FETCH`, `OCR`, `GST`, `EDGE_CALLBACK`, and `CREDIT_DELIVERY`.
- OCR and GST adapters are side-effect free and return results plus proposed events.
- Enrichment state, encrypted audit values, workflow state, and outbox events commit in one PostgreSQL transaction.
- Outbox delivery uses leases, exponential retry, unique `(event_id, destination)` keys, terminal failure status, and guarded DLQ replay.
- SQS messages are deleted only after committed processing; at-least-once delivery cannot duplicate provider stages.
- Callback failure retries only the callback event and never repeats OCR or GST.

The worker fetches the S3 object, verifies its tenant path, S3 metadata, content type, size, and SHA-256, converts WebP to PNG in memory, and invokes Textract. Confidence below 60 percent or provider failure routes the receipt to `NEEDS_HUMAN_REVIEW`.

## Provider policy

| Provider | Production state | Activation requirement |
| --- | --- | --- |
| Textract | Active | AWS permissions, budget, redaction, timeout, confidence, and fallback tests |
| GST | Disabled | Legal approval, real credentials, encrypted statutory fields, 3-second timeout and ±2% tests |
| Credit | Disabled | GST approval, banking/legal approval, FIFO contract acceptance |
| WhatsApp | Disabled | Business account and approved grouped-digest template |
| Slack | Disabled | Approved endpoint and redaction review |

Mock providers are forbidden in production. GST mismatch, failure, or disabled state never emits credit data.

## Recovery and retention

- SQS moves a message to the DLQ after five receives and retains it for 14 days.
- Queue depth scales workers; queue age and DLQ alarms notify operators.
- Production RDS uses Multi-AZ, 14-day automated PITR, deletion protection, and daily cross-account recovery copies retained 35 days.
- Live S3 image versions are removed after 90 days by a PostgreSQL-driven, version-aware tombstone workflow; receipt/audit records are removed after one year.
- Recovery backups can retain encrypted historical copies beyond live retention. Access is restricted to recovery operators and expiry follows the documented backup schedule. This exception requires client disclosure and independent privacy review.

The service target is 99.5% availability, RPO no greater than one hour, and RTO no greater than eight hours only after monitoring and restore evidence pass. No 24×7 support or certification is claimed.
