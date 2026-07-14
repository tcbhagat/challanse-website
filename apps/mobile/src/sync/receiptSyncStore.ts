import { getReceiptDatabase } from '../engine/receiptStore';

export type ReceiptSyncSettings = {
  ingestBaseUrl: string;
  wifiSsids: string[];
  siteId: string;
};

export type ReceiptSyncQueueItem = {
  receiptEventId: number;
  receiptId: string;
  siteId: string;
  deviceId: string;
  vendorId: string;
  capturedAtUnix: number;
  capturedQuantity: number;
  appVersion: string;
  configurationVersion: number;
  imageBlob: Uint8Array;
  status: string;
  uploadedBytes: number;
  totalBytes: number;
  attemptCount: number;
  nextAttemptAtUnix: number;
  lastError: string;
};

export type ReceiptSyncArtifact = {
  receiptEventId: number;
  mimeType: string;
  payload: Uint8Array;
  totalBytes: number;
  uploadedBytes: number;
};

export type ReceiptSyncLogEntry = {
  receiptEventId: number | null;
  state: string;
  detail: string;
  createdAtUnix: number;
};

type ReceiptDatabase = Awaited<ReturnType<typeof getReceiptDatabase>>;

const SYNC_SETTINGS_INGEST_BASE_URL = 'ingest_base_url';
const SYNC_SETTINGS_WIFI_SSIDS = 'wifi_ssids';
const SYNC_SETTINGS_SITE_ID = 'site_id';
const DEFAULT_SYNC_WIFI_SSIDS: string[] = [];

let schemaPromise: Promise<void> | null = null;

function nowUnix(): number {
  return Math.floor(Date.now() / 1000);
}

function asUint8Array(blob: unknown): Uint8Array {
  if (blob instanceof Uint8Array) {
    return blob;
  }

  if (blob instanceof ArrayBuffer) {
    return new Uint8Array(blob);
  }

  if (ArrayBuffer.isView(blob)) {
    return new Uint8Array(blob.buffer.slice(blob.byteOffset, blob.byteOffset + blob.byteLength));
  }

  if (Array.isArray(blob)) {
    return Uint8Array.from(blob);
  }

  return new Uint8Array();
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

async function ensureSyncSchema(database: ReceiptDatabase): Promise<void> {
  await database.executeAsync(
    'CREATE TABLE IF NOT EXISTS receipt_sync_state (' +
      'receipt_event_id INTEGER PRIMARY KEY,' +
      'status TEXT NOT NULL,' +
      'uploaded_bytes INTEGER NOT NULL DEFAULT 0,' +
      'total_bytes INTEGER NOT NULL DEFAULT 0,' +
      'attempt_count INTEGER NOT NULL DEFAULT 0,' +
      'next_attempt_at_unix INTEGER NOT NULL DEFAULT 0,' +
      "last_error TEXT NOT NULL DEFAULT ''," +
      'created_at_unix INTEGER NOT NULL,' +
      'updated_at_unix INTEGER NOT NULL,' +
      'last_synced_at_unix INTEGER' +
      ')',
  );
  await database.executeAsync(
    'CREATE TABLE IF NOT EXISTS receipt_sync_artifacts (' +
      'receipt_event_id INTEGER PRIMARY KEY,' +
      'mime_type TEXT NOT NULL,' +
      'payload_blob BLOB NOT NULL,' +
      'total_bytes INTEGER NOT NULL,' +
      'uploaded_bytes INTEGER NOT NULL DEFAULT 0,' +
      'created_at_unix INTEGER NOT NULL,' +
      'updated_at_unix INTEGER NOT NULL' +
      ')',
  );
  await database.executeAsync(
    'CREATE TABLE IF NOT EXISTS receipt_sync_logs (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      'receipt_event_id INTEGER,' +
      'state TEXT NOT NULL,' +
      'detail TEXT NOT NULL,' +
      'created_at_unix INTEGER NOT NULL' +
      ')',
  );
  await database.executeAsync(
    'CREATE TABLE IF NOT EXISTS receipt_sync_settings (' +
      'setting_key TEXT PRIMARY KEY,' +
      'setting_value TEXT NOT NULL' +
      ')',
  );
}

async function getSyncDatabase(): Promise<ReceiptDatabase> {
  const database = await getReceiptDatabase();

  if (!schemaPromise) {
    schemaPromise = ensureSyncSchema(database).catch((error) => {
      schemaPromise = null;
      throw error;
    });
  }

  await schemaPromise;
  return database;
}

export async function getReceiptSyncSettings(): Promise<ReceiptSyncSettings> {
  const database = await getSyncDatabase();
  const rows = (await database.executeAsync(
    'SELECT setting_key, setting_value FROM receipt_sync_settings ' +
      "WHERE setting_key IN (?, ?, ?)",
    [SYNC_SETTINGS_INGEST_BASE_URL, SYNC_SETTINGS_WIFI_SSIDS, SYNC_SETTINGS_SITE_ID],
  )) as { rows?: Array<{ setting_key?: string; setting_value?: string }> };

  const settings = new Map(
    (rows.rows ?? []).map((row) => [asString(row.setting_key), asString(row.setting_value)]),
  );

  return {
    ingestBaseUrl: settings.get(SYNC_SETTINGS_INGEST_BASE_URL) ?? '',
    wifiSsids: (settings.get(SYNC_SETTINGS_WIFI_SSIDS) ?? '')
      .split(',')
      .map((ssid) => ssid.trim())
      .filter(Boolean),
    siteId: settings.get(SYNC_SETTINGS_SITE_ID) ?? '',
  };
}

export async function setReceiptSyncSettings(settings: Partial<ReceiptSyncSettings>): Promise<void> {
  const database = await getSyncDatabase();
  const current = await getReceiptSyncSettings();
  const mergedWifiSsids = settings.wifiSsids ?? current.wifiSsids ?? DEFAULT_SYNC_WIFI_SSIDS;
  const mergedIngestBaseUrl = settings.ingestBaseUrl ?? current.ingestBaseUrl;
  const mergedSiteId = settings.siteId ?? current.siteId;

  await database.executeAsync(
    'INSERT OR REPLACE INTO receipt_sync_settings (setting_key, setting_value) VALUES (?, ?)',
    [SYNC_SETTINGS_INGEST_BASE_URL, mergedIngestBaseUrl],
  );
  await database.executeAsync(
    'INSERT OR REPLACE INTO receipt_sync_settings (setting_key, setting_value) VALUES (?, ?)',
    [SYNC_SETTINGS_WIFI_SSIDS, mergedWifiSsids.join(',')],
  );
  await database.executeAsync(
    'INSERT OR REPLACE INTO receipt_sync_settings (setting_key, setting_value) VALUES (?, ?)',
    [SYNC_SETTINGS_SITE_ID, mergedSiteId],
  );
}

export async function seedReceiptSyncSettingsIfMissing(): Promise<void> {
  const database = await getSyncDatabase();
  const current = await getReceiptSyncSettings();

  if (!current.ingestBaseUrl) {
    await database.executeAsync(
      'INSERT OR IGNORE INTO receipt_sync_settings (setting_key, setting_value) VALUES (?, ?)',
      [SYNC_SETTINGS_INGEST_BASE_URL, ''],
    );
  }

  if (current.wifiSsids.length === 0) {
    await database.executeAsync(
      'INSERT OR IGNORE INTO receipt_sync_settings (setting_key, setting_value) VALUES (?, ?)',
      [SYNC_SETTINGS_WIFI_SSIDS, DEFAULT_SYNC_WIFI_SSIDS.join(',')],
    );
  }

  if (!current.siteId) {
    await database.executeAsync(
      'INSERT OR IGNORE INTO receipt_sync_settings (setting_key, setting_value) VALUES (?, ?)',
      [SYNC_SETTINGS_SITE_ID, 'SITE_OFFICE'],
    );
  }
}

export async function listPendingReceiptSyncItems(limit = 25): Promise<ReceiptSyncQueueItem[]> {
  const database = await getSyncDatabase();
  const rows = (await database.executeAsync(
    'SELECT events.id AS receipt_event_id,' +
      'events.receipt_uuid AS receipt_uuid,' +
      'events.site_id AS site_id,' +
      'events.device_id AS device_id,' +
      'events.vendor_id AS vendor_id,' +
      'events.captured_at_unix AS captured_at_unix,' +
      'events.captured_quantity AS captured_quantity,' +
      'events.app_version AS app_version,' +
      'events.configuration_version AS configuration_version,' +
      'events.image_blob AS image_blob,' +
      "COALESCE(state.status, 'pending') AS status," +
      'COALESCE(state.uploaded_bytes, 0) AS uploaded_bytes,' +
      'COALESCE(state.total_bytes, 0) AS total_bytes,' +
      'COALESCE(state.attempt_count, 0) AS attempt_count,' +
      'COALESCE(state.next_attempt_at_unix, 0) AS next_attempt_at_unix,' +
      "COALESCE(state.last_error, '') AS last_error " +
      'FROM receipt_events events ' +
      'LEFT JOIN receipt_sync_state state ON state.receipt_event_id = events.id ' +
      "WHERE COALESCE(state.status, 'pending') != 'synced' " +
      'AND COALESCE(state.next_attempt_at_unix, 0) <= ? ' +
      'ORDER BY events.captured_at_unix ASC, events.id ASC ' +
      'LIMIT ?',
    [nowUnix(), limit],
  )) as {
    rows?: Array<{
      receipt_event_id?: number;
      receipt_uuid?: string;
      site_id?: string;
      device_id?: string;
      vendor_id?: string;
      captured_at_unix?: number;
      captured_quantity?: number;
      app_version?: string;
      configuration_version?: number;
      image_blob?: unknown;
      status?: string;
      uploaded_bytes?: number;
      total_bytes?: number;
      attempt_count?: number;
      next_attempt_at_unix?: number;
      last_error?: string;
    }>;
  };

  return (rows.rows ?? []).map((row) => ({
    receiptEventId: asNumber(row.receipt_event_id),
    receiptId: asString(row.receipt_uuid),
    siteId: asString(row.site_id),
    deviceId: asString(row.device_id),
    vendorId: asString(row.vendor_id),
    capturedAtUnix: asNumber(row.captured_at_unix),
    capturedQuantity: asNumber(row.captured_quantity, 1),
    appVersion: asString(row.app_version),
    configurationVersion: asNumber(row.configuration_version),
    imageBlob: asUint8Array(row.image_blob),
    status: asString(row.status, 'pending'),
    uploadedBytes: asNumber(row.uploaded_bytes),
    totalBytes: asNumber(row.total_bytes),
    attemptCount: asNumber(row.attempt_count),
    nextAttemptAtUnix: asNumber(row.next_attempt_at_unix),
    lastError: asString(row.last_error),
  }));
}

export async function getReceiptSyncArtifact(
  receiptEventId: number,
): Promise<ReceiptSyncArtifact | null> {
  const database = await getSyncDatabase();
  const rows = (await database.executeAsync(
    'SELECT receipt_event_id, mime_type, payload_blob, total_bytes, uploaded_bytes ' +
      'FROM receipt_sync_artifacts WHERE receipt_event_id = ? LIMIT 1',
    [receiptEventId],
  )) as {
    rows?: Array<{
      receipt_event_id?: number;
      mime_type?: string;
      payload_blob?: unknown;
      total_bytes?: number;
      uploaded_bytes?: number;
    }>;
  };

  const row = rows.rows?.[0];

  if (!row) {
    return null;
  }

  return {
    receiptEventId: asNumber(row.receipt_event_id),
    mimeType: asString(row.mime_type, 'image/webp'),
    payload: asUint8Array(row.payload_blob),
    totalBytes: asNumber(row.total_bytes),
    uploadedBytes: asNumber(row.uploaded_bytes),
  };
}

export async function upsertReceiptSyncArtifact(input: {
  receiptEventId: number;
  mimeType: string;
  payload: Uint8Array;
  totalBytes: number;
  uploadedBytes?: number;
}): Promise<void> {
  const database = await getSyncDatabase();
  const timestamp = nowUnix();

  await database.executeAsync(
    'INSERT OR REPLACE INTO receipt_sync_artifacts (' +
      'receipt_event_id, mime_type, payload_blob, total_bytes, uploaded_bytes, created_at_unix, updated_at_unix' +
      ') VALUES (?, ?, ?, ?, ?, COALESCE((SELECT created_at_unix FROM receipt_sync_artifacts WHERE receipt_event_id = ?), ?), ?)',
    [
      input.receiptEventId,
      input.mimeType,
      input.payload,
      input.totalBytes,
      input.uploadedBytes ?? 0,
      input.receiptEventId,
      timestamp,
      timestamp,
    ],
  );
}

export async function updateReceiptSyncArtifactProgress(
  receiptEventId: number,
  uploadedBytes: number,
): Promise<void> {
  const database = await getSyncDatabase();
  await database.executeAsync(
    'UPDATE receipt_sync_artifacts SET uploaded_bytes = ?, updated_at_unix = ? WHERE receipt_event_id = ?',
    [uploadedBytes, nowUnix(), receiptEventId],
  );
}

export async function upsertReceiptSyncState(input: {
  receiptEventId: number;
  status: string;
  uploadedBytes: number;
  totalBytes: number;
  attemptCount: number;
  nextAttemptAtUnix: number;
  lastError?: string;
  lastSyncedAtUnix?: number | null;
}): Promise<void> {
  const database = await getSyncDatabase();
  const timestamp = nowUnix();
  const existingRows = (await database.executeAsync(
    'SELECT created_at_unix FROM receipt_sync_state WHERE receipt_event_id = ? LIMIT 1',
    [input.receiptEventId],
  )) as { rows?: Array<{ created_at_unix?: number }> };

  const createdAtUnix = asNumber(existingRows.rows?.[0]?.created_at_unix, timestamp);

  await database.executeAsync(
    'INSERT OR REPLACE INTO receipt_sync_state (' +
      'receipt_event_id, status, uploaded_bytes, total_bytes, attempt_count, next_attempt_at_unix, last_error, created_at_unix, updated_at_unix, last_synced_at_unix' +
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      input.receiptEventId,
      input.status,
      input.uploadedBytes,
      input.totalBytes,
      input.attemptCount,
      input.nextAttemptAtUnix,
      input.lastError ?? '',
      createdAtUnix,
      timestamp,
      input.lastSyncedAtUnix ?? null,
    ],
  );
}

export async function markReceiptSyncState(input: {
  receiptEventId: number;
  status: string;
  detail: string;
}): Promise<void> {
  const database = await getSyncDatabase();
  const existingRows = (await database.executeAsync(
    'SELECT uploaded_bytes, total_bytes, attempt_count, next_attempt_at_unix, created_at_unix, last_synced_at_unix FROM receipt_sync_state WHERE receipt_event_id = ? LIMIT 1',
    [input.receiptEventId],
  )) as {
    rows?: Array<{
      uploaded_bytes?: number;
      total_bytes?: number;
      attempt_count?: number;
      next_attempt_at_unix?: number;
      created_at_unix?: number;
      last_synced_at_unix?: number | null;
    }>;
  };

  const existing = existingRows.rows?.[0];

  await upsertReceiptSyncState({
    receiptEventId: input.receiptEventId,
    status: input.status,
    uploadedBytes: asNumber(existing?.uploaded_bytes),
    totalBytes: asNumber(existing?.total_bytes),
    attemptCount: asNumber(existing?.attempt_count),
    nextAttemptAtUnix: asNumber(existing?.next_attempt_at_unix),
    lastError: input.detail,
    lastSyncedAtUnix: existing?.last_synced_at_unix ?? null,
  });
}

export async function incrementReceiptSyncAttempt(input: {
  receiptEventId: number;
  totalBytes: number;
  uploadedBytes: number;
  lastError: string;
  nextAttemptAtUnix: number;
}): Promise<number> {
  const database = await getSyncDatabase();
  const currentRows = (await database.executeAsync(
    'SELECT attempt_count FROM receipt_sync_state WHERE receipt_event_id = ? LIMIT 1',
    [input.receiptEventId],
  )) as { rows?: Array<{ attempt_count?: number }> };

  const currentAttemptCount = asNumber(currentRows.rows?.[0]?.attempt_count);
  const nextAttemptCount = currentAttemptCount + 1;

  await upsertReceiptSyncState({
    receiptEventId: input.receiptEventId,
    status: 'backoff',
    uploadedBytes: input.uploadedBytes,
    totalBytes: input.totalBytes,
    attemptCount: nextAttemptCount,
    nextAttemptAtUnix: input.nextAttemptAtUnix,
    lastError: input.lastError,
  });

  return nextAttemptCount;
}

export async function completeReceiptSync(input: {
  receiptEventId: number;
  uploadedBytes: number;
  totalBytes: number;
}): Promise<void> {
  await upsertReceiptSyncState({
    receiptEventId: input.receiptEventId,
    status: 'synced',
    uploadedBytes: input.totalBytes,
    totalBytes: input.totalBytes,
    attemptCount: 0,
    nextAttemptAtUnix: 0,
    lastError: '',
    lastSyncedAtUnix: nowUnix(),
  });
}

export async function recordReceiptSyncLog(input: {
  receiptEventId: number | null;
  state: string;
  detail: string;
}): Promise<void> {
  const database = await getSyncDatabase();
  await database.executeAsync(
    'INSERT INTO receipt_sync_logs (receipt_event_id, state, detail, created_at_unix) VALUES (?, ?, ?, ?)',
    [input.receiptEventId, input.state, input.detail, nowUnix()],
  );
}

export async function getRecentReceiptSyncLogs(limit = 50): Promise<ReceiptSyncLogEntry[]> {
  const database = await getSyncDatabase();
  const rows = (await database.executeAsync(
    'SELECT receipt_event_id, state, detail, created_at_unix ' +
      'FROM receipt_sync_logs ORDER BY id DESC LIMIT ?',
    [limit],
  )) as {
    rows?: Array<{
      receipt_event_id?: number | null;
      state?: string;
      detail?: string;
      created_at_unix?: number;
    }>;
  };

  return (rows.rows ?? []).map((row) => ({
    receiptEventId: typeof row.receipt_event_id === 'number' ? row.receipt_event_id : null,
    state: asString(row.state),
    detail: asString(row.detail),
    createdAtUnix: asNumber(row.created_at_unix),
  }));
}

export async function purgeAcknowledgedReceiptPayloads(graceDays = 7): Promise<void> {
  const database = await getSyncDatabase();
  const cutoff = nowUnix() - graceDays * 24 * 60 * 60;
  await database.executeAsync(
    `UPDATE receipt_events SET image_blob = X'' WHERE id IN (` +
      `SELECT receipt_event_id FROM receipt_sync_state WHERE status = 'synced' AND last_synced_at_unix IS NOT NULL AND last_synced_at_unix <= ?` +
    `) AND length(image_blob) > 0`,
    [cutoff],
  );
  await database.executeAsync(
    `DELETE FROM receipt_sync_artifacts WHERE receipt_event_id IN (` +
      `SELECT receipt_event_id FROM receipt_sync_state WHERE status = 'synced' AND last_synced_at_unix IS NOT NULL AND last_synced_at_unix <= ?` +
    `)`,
    [cutoff],
  );
}
