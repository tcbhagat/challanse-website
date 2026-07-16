CREATE TABLE IF NOT EXISTS service_request_nonces (
  request_id UUID PRIMARY KEY,
  key_id TEXT NOT NULL,
  content_sha256 TEXT NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '10 minutes',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_service_request_nonces_expiry ON service_request_nonces(expires_at);
