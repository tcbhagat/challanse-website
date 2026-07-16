ALTER TABLE transactional_outbox DROP CONSTRAINT IF EXISTS transactional_outbox_status_check;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
ALTER TABLE transactional_outbox
  ADD COLUMN IF NOT EXISTS destination TEXT NOT NULL DEFAULT 'EDGE',
  ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
  ADD COLUMN IF NOT EXISTS locked_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_error_code TEXT,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
UPDATE transactional_outbox
SET idempotency_key = event_type || ':' || aggregate_id::text || ':' || event_version::text
WHERE idempotency_key IS NULL;
ALTER TABLE transactional_outbox ALTER COLUMN idempotency_key SET NOT NULL;
ALTER TABLE transactional_outbox
  ADD CONSTRAINT transactional_outbox_status_check
  CHECK (status IN ('PENDING', 'PROCESSING', 'DELIVERED', 'FAILED_RETRYABLE', 'FAILED_TERMINAL', 'DISABLED'));
CREATE UNIQUE INDEX IF NOT EXISTS transactional_outbox_destination_idempotency_idx
  ON transactional_outbox(destination, idempotency_key);
CREATE INDEX IF NOT EXISTS transactional_outbox_delivery_idx
  ON transactional_outbox(status, available_at, locked_until);
ALTER TABLE workflow_stages ADD COLUMN IF NOT EXISTS locked_until TIMESTAMPTZ;
ALTER TABLE workflow_stages DROP CONSTRAINT IF EXISTS workflow_stages_status_check;
ALTER TABLE workflow_stages ADD CONSTRAINT workflow_stages_status_check
  CHECK (status IN ('PROCESSING', 'COMPLETED', 'FAILED_RETRYABLE', 'FAILED_TERMINAL', 'DISABLED'));
CREATE UNIQUE INDEX IF NOT EXISTS immutable_enrichment_audits_stage_idx
  ON immutable_enrichment_audits (receipt_id, event_type);

CREATE TABLE IF NOT EXISTS organizations (
  id UUID PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  device_limit INTEGER NOT NULL DEFAULT 100 CHECK (device_limit BETWEEN 1 AND 1000),
  device_request_limit_per_minute INTEGER NOT NULL DEFAULT 120 CHECK (device_request_limit_per_minute BETWEEN 30 AND 600),
  daily_receipt_limit INTEGER NOT NULL DEFAULT 1000 CHECK (daily_receipt_limit > 0),
  storage_byte_limit BIGINT NOT NULL DEFAULT 5000000000 CHECK (storage_byte_limit > 0),
  stored_image_bytes BIGINT NOT NULL DEFAULT 0 CHECK (stored_image_bytes >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS device_request_limit_per_minute INTEGER NOT NULL DEFAULT 120
  CHECK (device_request_limit_per_minute BETWEEN 30 AND 600);

INSERT INTO organizations (id, slug, name, active)
VALUES ('00000000-0000-4000-8000-000000000001', 'legacy-disabled', 'Legacy migration', FALSE)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE enrichment_receipts ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE workflow_stages ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE transactional_outbox ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE immutable_enrichment_audits ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE service_ingress_requests ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE vendor_integration_profiles ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE site_integration_profiles ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE tally_imports ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE tally_import_rows ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE verified_receipts ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE notification_digests ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE retention_tombstones ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE site_managers ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE telemetry_measurements ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE nightly_friction_reports ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL DEFAULT '00000000-0000-4000-8000-000000000001' REFERENCES organizations(id);
ALTER TABLE nightly_friction_reports DROP CONSTRAINT IF EXISTS nightly_friction_reports_report_date_key;
CREATE UNIQUE INDEX IF NOT EXISTS nightly_friction_reports_org_date_idx ON nightly_friction_reports (organization_id, report_date);

CREATE TABLE IF NOT EXISTS sites (
  id UUID PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  allowed_wifi_ssids JSONB NOT NULL DEFAULT '[]'::jsonb,
  configuration_version INTEGER NOT NULL DEFAULT 1,
  daily_receipt_limit INTEGER NOT NULL DEFAULT 50 CHECK (daily_receipt_limit > 0),
  image_byte_limit INTEGER NOT NULL DEFAULT 5000000 CHECK (image_byte_limit BETWEEN 100000 AND 5000000),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, id)
);

CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY,
  email TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP INDEX IF EXISTS users_email_idx;
CREATE INDEX IF NOT EXISTS users_email_lookup_idx ON users (LOWER(email));

CREATE TABLE IF NOT EXISTS roles (
  code TEXT PRIMARY KEY CHECK (code IN ('ORG_ADMIN', 'SITE_ADMIN', 'CONTROLLER', 'REVIEWER', 'AUDITOR')),
  description TEXT NOT NULL
);

INSERT INTO roles (code, description) VALUES
  ('ORG_ADMIN', 'Organization administration and all organization sites'),
  ('SITE_ADMIN', 'Administration for assigned sites'),
  ('CONTROLLER', 'Receipt review, reconciliation, and audit export'),
  ('REVIEWER', 'Receipt review for assigned sites'),
  ('AUDITOR', 'Read-only receipt and audit access')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS identity_links (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  issuer TEXT NOT NULL,
  subject TEXT NOT NULL,
  email TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (issuer, subject)
);

CREATE TABLE IF NOT EXISTS organization_memberships (
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL REFERENCES roles(code),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (organization_id, user_id)
);

CREATE TABLE IF NOT EXISTS site_memberships (
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL REFERENCES roles(code) CHECK (role <> 'ORG_ADMIN'),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (site_id, user_id),
  FOREIGN KEY (organization_id, site_id) REFERENCES sites(organization_id, id)
);

CREATE TABLE IF NOT EXISTS membership_invitations (
  id UUID PRIMARY KEY,
  code_hash TEXT NOT NULL UNIQUE CHECK (code_hash ~ '^[a-f0-9]{64}$'),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  created_site_id UUID NOT NULL,
  issuer TEXT NOT NULL,
  email TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL REFERENCES roles(code),
  site_ids UUID[] NOT NULL DEFAULT '{}',
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  created_by UUID NOT NULL REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (organization_id, created_site_id) REFERENCES sites(organization_id, id)
);

CREATE TABLE IF NOT EXISTS vendors (
  id TEXT NOT NULL,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  initials TEXT NOT NULL CHECK (CHAR_LENGTH(initials) BETWEEN 1 AND 3),
  color TEXT NOT NULL CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  display_order INTEGER NOT NULL DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (site_id, id),
  FOREIGN KEY (organization_id, site_id) REFERENCES sites(organization_id, id)
);

CREATE TABLE IF NOT EXISTS devices (
  id UUID PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  app_version TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  enrolled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ,
  FOREIGN KEY (organization_id, site_id) REFERENCES sites(organization_id, id)
);

CREATE TABLE IF NOT EXISTS enrollment_codes (
  code_hash TEXT PRIMARY KEY CHECK (code_hash ~ '^[a-f0-9]{64}$'),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  device_name TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  created_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (organization_id, site_id) REFERENCES sites(organization_id, id)
);

CREATE TABLE IF NOT EXISTS device_request_nonces (
  nonce_hash TEXT PRIMARY KEY CHECK (nonce_hash ~ '^[a-f0-9]{64}$'),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS device_rate_limit_windows (
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  window_started_at TIMESTAMPTZ NOT NULL,
  request_count INTEGER NOT NULL CHECK (request_count > 0),
  PRIMARY KEY (device_id, window_started_at)
);

CREATE TABLE IF NOT EXISTS upload_sessions (
  id UUID PRIMARY KEY,
  receipt_id UUID NOT NULL UNIQUE,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  device_id UUID NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
  vendor_id TEXT NOT NULL,
  metadata_json JSONB NOT NULL,
  total_bytes INTEGER NOT NULL CHECK (total_bytes BETWEEN 1 AND 5000000),
  image_sha256 TEXT NOT NULL CHECK (image_sha256 ~ '^[a-f0-9]{64}$'),
  final_object_key TEXT,
  integrity_status TEXT NOT NULL DEFAULT 'UNAVAILABLE' CHECK (integrity_status IN ('TRUSTED', 'RISK', 'MISSING', 'UNAVAILABLE')),
  mime_type TEXT NOT NULL CHECK (mime_type = 'image/webp'),
  status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'COMPLETING', 'COMPLETE', 'EXPIRED', 'FAILED')),
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, site_id) REFERENCES sites(organization_id, id),
  FOREIGN KEY (site_id, vendor_id) REFERENCES vendors(site_id, id)
);

CREATE TABLE IF NOT EXISTS upload_parts (
  upload_id UUID NOT NULL REFERENCES upload_sessions(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  part_number INTEGER NOT NULL CHECK (part_number >= 0),
  byte_offset INTEGER NOT NULL CHECK (byte_offset >= 0),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  sha256 TEXT NOT NULL CHECK (sha256 ~ '^[a-f0-9]{64}$'),
  object_key TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (upload_id, part_number),
  FOREIGN KEY (organization_id, upload_id) REFERENCES upload_sessions(organization_id, id)
);

CREATE TABLE IF NOT EXISTS receipts (
  id UUID PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
  device_id UUID NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
  vendor_id TEXT NOT NULL,
  captured_at_unix BIGINT NOT NULL,
  captured_quantity DOUBLE PRECISION NOT NULL CHECK (captured_quantity > 0),
  image_key TEXT NOT NULL,
  image_bytes INTEGER NOT NULL CHECK (image_bytes > 0),
  image_sha256 TEXT NOT NULL CHECK (image_sha256 ~ '^[a-f0-9]{64}$'),
  status TEXT NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED', 'NEEDS_REVIEW', 'VERIFIED', 'REJECTED')),
  enrichment_status TEXT NOT NULL DEFAULT 'QUEUED',
  gst_status TEXT NOT NULL DEFAULT 'DISABLED',
  integrity_status TEXT NOT NULL DEFAULT 'UNAVAILABLE' CHECK (integrity_status IN ('TRUSTED', 'RISK', 'MISSING', 'UNAVAILABLE')),
  ocr_confidence DOUBLE PRECISION,
  raw_ocr_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  challan_number TEXT NOT NULL DEFAULT '',
  po_number TEXT NOT NULL DEFAULT '',
  material_code TEXT NOT NULL DEFAULT '',
  material_description TEXT NOT NULL DEFAULT '',
  verified_quantity DOUBLE PRECISION,
  unit TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  version INTEGER NOT NULL DEFAULT 1,
  app_version TEXT NOT NULL,
  configuration_version INTEGER NOT NULL,
  image_deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, site_id, id),
  FOREIGN KEY (organization_id, site_id) REFERENCES sites(organization_id, id),
  FOREIGN KEY (site_id, vendor_id) REFERENCES vendors(site_id, id)
);

CREATE TABLE IF NOT EXISTS audit_events (
  id UUID PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
  receipt_id UUID REFERENCES receipts(id) ON DELETE RESTRICT,
  event_type TEXT NOT NULL,
  actor_type TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  event_json JSONB NOT NULL,
  source_class TEXT NOT NULL DEFAULT 'cloudflare',
  previous_hash TEXT,
  event_hash TEXT NOT NULL CHECK (event_hash ~ '^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (organization_id, site_id) REFERENCES sites(organization_id, id),
  FOREIGN KEY (organization_id, site_id, receipt_id) REFERENCES receipts(organization_id, site_id, id)
);

CREATE TABLE IF NOT EXISTS pilot_requests (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL,
  company TEXT NOT NULL,
  email TEXT NOT NULL,
  phone TEXT NOT NULL DEFAULT '',
  message TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS receipts_tenant_inbox_idx ON receipts (organization_id, site_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS uploads_expiry_idx ON upload_sessions (status, expires_at);
CREATE INDEX IF NOT EXISTS device_nonce_expiry_idx ON device_request_nonces (expires_at);
CREATE INDEX IF NOT EXISTS devices_tenant_active_idx ON devices (organization_id, site_id, active);
CREATE INDEX IF NOT EXISTS upload_parts_tenant_idx ON upload_parts (organization_id, upload_id, part_number);
CREATE INDEX IF NOT EXISTS audit_events_tenant_time_idx ON audit_events (organization_id, site_id, created_at DESC);
CREATE INDEX IF NOT EXISTS membership_invitations_tenant_expiry_idx ON membership_invitations (organization_id, expires_at) WHERE used_at IS NULL;

CREATE TABLE IF NOT EXISTS tenant_context_secrets (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  secret BYTEA NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNLOGGED TABLE IF NOT EXISTS tenant_session_contexts (
  backend_pid INTEGER NOT NULL,
  transaction_id BIGINT NOT NULL,
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (backend_pid, transaction_id)
);

CREATE OR REPLACE FUNCTION challanse_current_organization_id()
RETURNS UUID
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT organization_id
  FROM public.tenant_session_contexts
  WHERE backend_pid = pg_backend_pid() AND transaction_id = txid_current()
$$;

CREATE OR REPLACE FUNCTION challanse_set_tenant_context(requested_organization_id UUID, signature TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  signing_secret BYTEA;
  message TEXT;
  expected_signature TEXT;
BEGIN
  SELECT secret INTO signing_secret FROM public.tenant_context_secrets WHERE singleton = TRUE;
  IF signing_secret IS NULL THEN
    RAISE EXCEPTION 'tenant_context_unconfigured';
  END IF;
  message := requested_organization_id::TEXT || ':' || pg_backend_pid()::TEXT || ':' || txid_current()::TEXT;
  expected_signature := encode(hmac(convert_to(message, 'UTF8'), signing_secret, 'sha256'), 'hex');
  IF signature IS NULL OR signature <> expected_signature THEN
    RAISE EXCEPTION 'tenant_context_signature_invalid';
  END IF;
  DELETE FROM public.tenant_session_contexts
  WHERE backend_pid = pg_backend_pid() OR created_at < NOW() - INTERVAL '1 hour';
  INSERT INTO public.tenant_session_contexts (backend_pid, transaction_id, organization_id)
  VALUES (pg_backend_pid(), txid_current(), requested_organization_id);
END
$$;

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON organizations;
CREATE POLICY tenant_isolation ON organizations
  USING (id = challanse_current_organization_id())
  WITH CHECK (id = challanse_current_organization_id());

DO $rls$
DECLARE
  table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'sites', 'organization_memberships', 'site_memberships', 'membership_invitations', 'vendors', 'devices',
    'enrollment_codes', 'device_request_nonces', 'device_rate_limit_windows', 'upload_sessions', 'upload_parts',
    'receipts', 'audit_events', 'enrichment_receipts', 'workflow_stages',
    'transactional_outbox', 'immutable_enrichment_audits', 'service_ingress_requests',
    'vendor_integration_profiles', 'site_integration_profiles', 'tally_imports',
    'tally_import_rows', 'verified_receipts', 'notification_digests',
    'retention_tombstones', 'site_managers', 'telemetry_measurements',
    'nightly_friction_reports'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', table_name);
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', table_name);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (organization_id = challanse_current_organization_id()) WITH CHECK (organization_id = challanse_current_organization_id())',
      table_name
    );
  END LOOP;
END
$rls$;
