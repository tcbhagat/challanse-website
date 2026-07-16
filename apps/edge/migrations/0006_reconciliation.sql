ALTER TABLE receipts ADD COLUMN po_number TEXT NOT NULL DEFAULT '';
ALTER TABLE receipts ADD COLUMN material_code TEXT NOT NULL DEFAULT '';

CREATE TABLE review_projection_outbox (
  receipt_id TEXT PRIMARY KEY REFERENCES receipts(id),
  site_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'DELIVERED')),
  attempts INTEGER NOT NULL DEFAULT 0,
  available_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  delivered_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_review_projection_pending ON review_projection_outbox(status, available_at);
