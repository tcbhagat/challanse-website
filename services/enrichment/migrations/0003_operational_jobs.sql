CREATE TABLE IF NOT EXISTS site_managers (
  site_id UUID NOT NULL,
  manager_id TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (site_id, manager_id)
);

CREATE TABLE IF NOT EXISTS telemetry_measurements (
  id UUID PRIMARY KEY,
  source_event_id TEXT NOT NULL UNIQUE,
  site_id UUID NOT NULL,
  vendor_id TEXT,
  metric_name TEXT NOT NULL CHECK (metric_name IN ('frontend_write_duration_ms', 'sync_failure_rate')),
  metric_value DOUBLE PRECISION NOT NULL,
  sample_count INTEGER NOT NULL CHECK (sample_count > 0),
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (period_end >= period_start)
);

CREATE TABLE IF NOT EXISTS nightly_friction_reports (
  id UUID PRIMARY KEY,
  report_date DATE NOT NULL UNIQUE,
  alerts_json JSONB NOT NULL,
  provider_status TEXT NOT NULL DEFAULT 'DISABLED',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_telemetry_period ON telemetry_measurements(metric_name, period_end, site_id);
CREATE INDEX IF NOT EXISTS idx_enrichment_retention ON enrichment_receipts(created_at);
