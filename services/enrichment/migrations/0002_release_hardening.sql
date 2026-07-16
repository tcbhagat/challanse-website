CREATE TABLE IF NOT EXISTS service_ingress_requests (
  request_id UUID PRIMARY KEY,
  receipt_id UUID NOT NULL UNIQUE,
  key_id TEXT NOT NULL,
  content_sha256 TEXT NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  status TEXT NOT NULL CHECK (status IN ('RESERVED', 'QUEUED')),
  task_id TEXT,
  event_json JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  queued_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS workflow_stages (
  receipt_id UUID NOT NULL,
  stage TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('PROCESSING', 'COMPLETED', 'FAILED_RETRYABLE', 'FAILED_TERMINAL')),
  attempts INTEGER NOT NULL DEFAULT 1,
  last_error_code TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (receipt_id, stage)
);

CREATE TABLE IF NOT EXISTS transactional_outbox (
  id UUID PRIMARY KEY,
  aggregate_id UUID NOT NULL,
  event_type TEXT NOT NULL,
  event_version INTEGER NOT NULL,
  payload_json JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'DELIVERED', 'FAILED_RETRYABLE', 'DISABLED')),
  attempts INTEGER NOT NULL DEFAULT 0,
  available_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  delivered_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (aggregate_id, event_type, event_version)
);

ALTER TABLE enrichment_receipts ADD COLUMN IF NOT EXISTS image_sha256 TEXT;
ALTER TABLE enrichment_receipts ADD COLUMN IF NOT EXISTS image_bytes INTEGER;
ALTER TABLE enrichment_receipts ADD COLUMN IF NOT EXISTS provider_version TEXT NOT NULL DEFAULT '';
ALTER TABLE enrichment_receipts ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ;
ALTER TABLE enrichment_receipts ADD COLUMN IF NOT EXISTS processing_completed_at TIMESTAMPTZ;

ALTER TABLE vendor_integration_profiles ADD COLUMN IF NOT EXISTS vendor_gst_number_encrypted BYTEA;
ALTER TABLE vendor_integration_profiles ADD COLUMN IF NOT EXISTS msme_udyam_number_encrypted BYTEA;
ALTER TABLE vendor_integration_profiles ADD COLUMN IF NOT EXISTS recipient_bank_account_encrypted BYTEA;
ALTER TABLE vendor_integration_profiles DROP COLUMN IF EXISTS vendor_gst_number;
ALTER TABLE vendor_integration_profiles DROP COLUMN IF EXISTS msme_udyam_number;
ALTER TABLE vendor_integration_profiles DROP COLUMN IF EXISTS recipient_bank_account;
ALTER TABLE immutable_enrichment_audits ADD COLUMN IF NOT EXISTS sensitive_event_ciphertext BYTEA;

CREATE TABLE IF NOT EXISTS site_integration_profiles (
  site_id UUID PRIMARY KEY,
  developer_gst_number_encrypted BYTEA,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tally_import_rows (
  id UUID PRIMARY KEY,
  import_id UUID NOT NULL REFERENCES tally_imports(id),
  site_id UUID NOT NULL,
  po_number TEXT NOT NULL,
  material_code TEXT NOT NULL,
  quantity DOUBLE PRECISION NOT NULL CHECK (quantity >= 0),
  unit TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (import_id, po_number, material_code, unit)
);

CREATE TABLE IF NOT EXISTS verified_receipts (
  receipt_id UUID PRIMARY KEY,
  site_id UUID NOT NULL,
  po_number TEXT NOT NULL,
  material_code TEXT NOT NULL,
  verified_quantity DOUBLE PRECISION NOT NULL CHECK (verified_quantity > 0),
  unit TEXT NOT NULL,
  reviewer_id TEXT NOT NULL,
  review_version INTEGER NOT NULL,
  reviewed_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS notification_digests (
  id UUID PRIMARY KEY,
  site_id UUID NOT NULL,
  manager_id TEXT NOT NULL,
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  receipt_count INTEGER NOT NULL,
  failed_count INTEGER NOT NULL,
  body TEXT NOT NULL,
  provider_status TEXT NOT NULL DEFAULT 'DISABLED',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (site_id, manager_id, period_start, period_end)
);

CREATE TABLE IF NOT EXISTS retention_tombstones (
  id UUID PRIMARY KEY,
  receipt_id UUID NOT NULL,
  resource_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING',
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  UNIQUE (receipt_id, resource_type)
);

CREATE INDEX IF NOT EXISTS idx_outbox_pending ON transactional_outbox (status, available_at);
CREATE INDEX IF NOT EXISTS idx_workflow_retry ON workflow_stages (status, updated_at);
CREATE INDEX IF NOT EXISTS idx_tally_rows_site ON tally_import_rows (site_id, po_number, material_code, unit);
CREATE INDEX IF NOT EXISTS idx_verified_receipts_site ON verified_receipts (site_id, po_number, material_code, unit);
