import { open } from 'react-native-quick-sqlite';
import { getOrCreateDatabaseKey } from './secureKey';
import { recordTelemetryEvent } from '../telemetry/telemetryStore';
import { withReceiptSpan } from '../telemetry/receiptTelemetry';

export type ReceiptCaptureInput = {
  imageBlob: Uint8Array | ArrayBuffer;
  capturedAtUnix?: number;
  vendorId: string;
  receiptId?: string;
  siteId: string;
  deviceId: string;
  capturedQuantity: number;
  appVersion: string;
  configurationVersion: number;
};

export type ReceiptEventRecord = {
  receiptId: string;
  capturedAtUnix: number;
  imageBytes: number;
  vendorId: string;
};

type ReceiptDatabase = {
  executeAsync: (query: string, params?: unknown[]) => Promise<unknown>;
  close: () => void;
};

const DATABASE_NAME = 'receipt-ingestion.db';

let databasePromise: Promise<ReceiptDatabase> | null = null;

function toUint8Array(blob: Uint8Array | ArrayBuffer): Uint8Array {
  return blob instanceof Uint8Array ? blob : new Uint8Array(blob);
}

function generateReceiptId(): string {
  const bytes = new Uint8Array(16);
  (globalThis as unknown as { crypto: { getRandomValues: (values: Uint8Array) => Uint8Array } }).crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function ensureReceiptColumns(database: ReceiptDatabase): Promise<void> {
  const result = (await database.executeAsync('PRAGMA table_info(receipt_events)')) as {
    rows?: Array<{ name?: string }>;
  };
  const columns = new Set((result.rows ?? []).map((row) => row.name));
  const additions = [
    ['receipt_uuid', "TEXT NOT NULL DEFAULT ''"],
    ['site_id', "TEXT NOT NULL DEFAULT ''"],
    ['device_id', "TEXT NOT NULL DEFAULT ''"],
    ['captured_quantity', 'INTEGER NOT NULL DEFAULT 1'],
    ['app_version', "TEXT NOT NULL DEFAULT ''"],
    ['configuration_version', 'INTEGER NOT NULL DEFAULT 0'],
  ] as const;
  for (const [name, definition] of additions) {
    if (!columns.has(name)) await database.executeAsync(`ALTER TABLE receipt_events ADD COLUMN ${name} ${definition}`);
  }
  await database.executeAsync(
    `UPDATE receipt_events SET receipt_uuid = lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1,1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6))) WHERE receipt_uuid = ''`,
  );
  await database.executeAsync('CREATE UNIQUE INDEX IF NOT EXISTS idx_receipt_events_uuid ON receipt_events(receipt_uuid)');
}

async function initializeDatabase(): Promise<ReceiptDatabase> {
  const key = await getOrCreateDatabaseKey();
  const database = open({ name: DATABASE_NAME }) as unknown as ReceiptDatabase;

  await database.executeAsync(`PRAGMA key = '${key}'`);
  await database.executeAsync('PRAGMA journal_mode = WAL');
  await database.executeAsync('PRAGMA synchronous = NORMAL');
  await database.executeAsync('PRAGMA temp_store = MEMORY');
  await database.executeAsync(
    'CREATE TABLE IF NOT EXISTS receipt_events (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      'receipt_uuid TEXT NOT NULL UNIQUE,' +
      'site_id TEXT NOT NULL,' +
      'device_id TEXT NOT NULL,' +
      'vendor_id TEXT NOT NULL,' +
      'captured_at_unix INTEGER NOT NULL,' +
      'captured_quantity INTEGER NOT NULL,' +
      'app_version TEXT NOT NULL,' +
      'configuration_version INTEGER NOT NULL,' +
      'image_blob BLOB NOT NULL' +
      ')',
  );
  await ensureReceiptColumns(database);
  await database.executeAsync(
    'CREATE INDEX IF NOT EXISTS idx_receipt_events_vendor_time ' +
      'ON receipt_events(vendor_id, captured_at_unix DESC)',
  );

  return database;
}

export async function getReceiptDatabase(): Promise<ReceiptDatabase> {
  if (!databasePromise) {
    databasePromise = initializeDatabase().catch((error) => {
      databasePromise = null;
      throw error;
    });
  }

  return databasePromise;
}

export async function insertReceiptEvent(
  input: ReceiptCaptureInput,
): Promise<ReceiptEventRecord> {
  return withReceiptSpan(
    'receipt.frontend_write',
    { vendor_id: input.vendorId },
    async () => {
      const database = await getReceiptDatabase();
      const imageBlob = toUint8Array(input.imageBlob);
      const capturedAtUnix = input.capturedAtUnix ?? Math.floor(Date.now() / 1000);
      const receiptId = input.receiptId ?? generateReceiptId();
      const clock = (globalThis as unknown as { performance?: { now?: () => number } }).performance;
      const startedAt = clock?.now?.() ?? Date.now();

      await database.executeAsync(
        'INSERT INTO receipt_events (receipt_uuid, site_id, device_id, vendor_id, captured_at_unix, captured_quantity, app_version, configuration_version, image_blob) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [receiptId, input.siteId, input.deviceId, input.vendorId, capturedAtUnix, input.capturedQuantity, input.appVersion, input.configurationVersion, imageBlob],
      );

      const endedAt = clock?.now?.() ?? Date.now();
      void recordTelemetryEvent({
        eventName: 'frontend_write_duration_ms',
        vendorId: input.vendorId,
        durationMs: Math.max(0, endedAt - startedAt),
        value: imageBlob.byteLength,
        attributes: {
          imageBytes: imageBlob.byteLength,
          capturedAtUnix,
        },
      });

      return {
        receiptId,
        vendorId: input.vendorId,
        capturedAtUnix,
        imageBytes: imageBlob.byteLength,
      };
    },
  );
}

export async function getReceiptContext(): Promise<{
  eventCount: number;
  lastCapturedAtUnix: number | null;
  lastVendorId: string;
}> {
  const database = await getReceiptDatabase();
  const recentRows = (await database.executeAsync(
    'SELECT vendor_id, captured_at_unix FROM receipt_events ORDER BY captured_at_unix DESC, id DESC LIMIT 1',
  )) as { rows?: Array<{ vendor_id?: string; captured_at_unix?: number }> };
  const countRows = (await database.executeAsync(
    'SELECT COUNT(*) AS event_count FROM receipt_events',
  )) as { rows?: Array<{ event_count?: number }> };

  const latestRow = recentRows.rows?.[0];
  const countRow = countRows.rows?.[0];

  return {
    eventCount: Number(countRow?.event_count ?? 0),
    lastCapturedAtUnix: latestRow?.captured_at_unix ?? null,
    lastVendorId: latestRow?.vendor_id ?? '',
  };
}
