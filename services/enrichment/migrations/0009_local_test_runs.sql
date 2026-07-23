CREATE TABLE IF NOT EXISTS local_test_runs (
  id UUID PRIMARY KEY,
  requested_by UUID REFERENCES users(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'QUEUED'
    CHECK (status IN ('QUEUED', 'RUNNING', 'CANCEL_REQUESTED', 'CANCELLED', 'PASSED', 'FAILED')),
  stage TEXT NOT NULL DEFAULT 'QUEUED',
  progress INTEGER NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  report_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  artifact_directory TEXT,
  error_code TEXT,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS local_test_runs_single_active_idx
  ON local_test_runs ((TRUE))
  WHERE status IN ('QUEUED', 'RUNNING', 'CANCEL_REQUESTED');

CREATE INDEX IF NOT EXISTS local_test_runs_requested_idx
  ON local_test_runs(requested_at DESC);

CREATE TABLE IF NOT EXISTS local_operator_events (
  id UUID PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  event_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  previous_hash TEXT,
  event_hash TEXT NOT NULL CHECK (event_hash ~ '^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS local_operator_events_created_idx
  ON local_operator_events(created_at DESC);

REVOKE ALL ON TABLE local_test_runs, local_operator_events FROM PUBLIC;
