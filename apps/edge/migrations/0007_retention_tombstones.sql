CREATE TABLE retention_tombstones (
  id TEXT PRIMARY KEY,
  receipt_id TEXT NOT NULL,
  resource_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'COMPLETED', 'FAILED_RETRYABLE')),
  requested_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TEXT,
  UNIQUE (receipt_id, resource_type)
);

CREATE INDEX idx_retention_tombstones_status ON retention_tombstones(status, requested_at);
