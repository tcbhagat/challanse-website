PRAGMA foreign_keys = ON;

CREATE TABLE sites (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  allowed_wifi_ssids_json TEXT NOT NULL DEFAULT '[]',
  configuration_version INTEGER NOT NULL DEFAULT 1,
  daily_receipt_limit INTEGER NOT NULL DEFAULT 50,
  image_byte_limit INTEGER NOT NULL DEFAULT 750000,
  storage_byte_limit INTEGER NOT NULL DEFAULT 5000000000,
  stored_image_bytes INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE vendors (
  id TEXT PRIMARY KEY,
  site_id TEXT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  initials TEXT NOT NULL,
  color TEXT NOT NULL,
  display_order INTEGER NOT NULL DEFAULT 0,
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX vendors_site_order_idx ON vendors(site_id, active, display_order);

CREATE TABLE reviewers (
  email TEXT PRIMARY KEY,
  site_id TEXT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK(role IN ('ADMIN', 'CONTROLLER')),
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE enrollment_codes (
  code_hash TEXT PRIMARY KEY,
  site_id TEXT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  device_name TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_by TEXT NOT NULL,
  used_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  site_id TEXT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  app_version TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  enrolled_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at TEXT
);
CREATE INDEX devices_site_active_idx ON devices(site_id, active);

CREATE TABLE receipts (
  id TEXT PRIMARY KEY,
  site_id TEXT NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
  vendor_id TEXT NOT NULL REFERENCES vendors(id) ON DELETE RESTRICT,
  captured_at_unix INTEGER NOT NULL,
  captured_quantity INTEGER NOT NULL CHECK(captured_quantity > 0),
  image_key TEXT NOT NULL UNIQUE,
  image_bytes INTEGER NOT NULL,
  image_sha256 TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('RECEIVED', 'NEEDS_REVIEW', 'VERIFIED', 'REJECTED')),
  version INTEGER NOT NULL DEFAULT 1,
  app_version TEXT NOT NULL,
  configuration_version INTEGER NOT NULL,
  challan_number TEXT NOT NULL DEFAULT '',
  material_description TEXT NOT NULL DEFAULT '',
  verified_quantity REAL,
  unit TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  reviewed_by TEXT,
  reviewed_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  image_deleted_at TEXT
);
CREATE INDEX receipts_site_status_created_idx ON receipts(site_id, status, created_at DESC);
CREATE INDEX receipts_received_idx ON receipts(status, created_at) WHERE status = 'RECEIVED';

CREATE TABLE receipt_audits (
  id TEXT PRIMARY KEY,
  receipt_id TEXT NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
  site_id TEXT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  actor TEXT NOT NULL,
  event_json TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX receipt_audits_receipt_idx ON receipt_audits(receipt_id, created_at);

CREATE TABLE pilot_requests (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  company TEXT NOT NULL,
  email TEXT NOT NULL,
  phone TEXT NOT NULL DEFAULT '',
  message TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'NEW',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE request_nonces (
  nonce_hash TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL
);

CREATE TABLE operations_log (
  id TEXT PRIMARY KEY,
  site_id TEXT,
  event_type TEXT NOT NULL,
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE request_limits (
  limit_key TEXT PRIMARY KEY,
  request_count INTEGER NOT NULL,
  expires_at TEXT NOT NULL
);
