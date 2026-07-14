import { getReceiptDatabase } from '../engine/receiptStore';

export type TelemetryEventInput = {
  eventName: string;
  siteId?: string;
  vendorId?: string;
  success?: boolean;
  durationMs?: number;
  value?: number;
  attributes?: Record<string, unknown>;
  createdAtUnix?: number;
};

export type TelemetryEventRecord = TelemetryEventInput & {
  id: number;
  sentAtUnix: number | null;
};

type ReceiptDatabase = Awaited<ReturnType<typeof getReceiptDatabase>>;

let schemaPromise: Promise<void> | null = null;

function nowUnix(): number {
  return Math.floor(Date.now() / 1000);
}

function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined;
}

async function ensureTelemetrySchema(database: ReceiptDatabase): Promise<void> {
  await database.executeAsync(
    'CREATE TABLE IF NOT EXISTS telemetry_events (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      'event_name TEXT NOT NULL,' +
      'site_id TEXT,' +
      'vendor_id TEXT,' +
      'success INTEGER,' +
      'duration_ms REAL,' +
      'value REAL,' +
      'attributes_json TEXT NOT NULL DEFAULT \'{}\',' +
      'created_at_unix INTEGER NOT NULL,' +
      'sent_at_unix INTEGER' +
      ')',
  );
  await database.executeAsync(
    'CREATE INDEX IF NOT EXISTS idx_telemetry_events_unsent ' +
      'ON telemetry_events(sent_at_unix, created_at_unix DESC)',
  );
}

async function getTelemetryDatabase(): Promise<ReceiptDatabase> {
  const database = await getReceiptDatabase();

  if (!schemaPromise) {
    schemaPromise = ensureTelemetrySchema(database).catch((error) => {
      schemaPromise = null;
      throw error;
    });
  }

  await schemaPromise;
  return database;
}

export async function recordTelemetryEvent(input: TelemetryEventInput): Promise<void> {
  const database = await getTelemetryDatabase();
  await database.executeAsync(
    'INSERT INTO telemetry_events (' +
      'event_name, site_id, vendor_id, success, duration_ms, value, attributes_json, created_at_unix' +
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    [
      input.eventName,
      input.siteId ?? null,
      input.vendorId ?? null,
      typeof input.success === 'boolean' ? (input.success ? 1 : 0) : null,
      input.durationMs ?? null,
      input.value ?? null,
      JSON.stringify(input.attributes ?? {}),
      input.createdAtUnix ?? nowUnix(),
    ],
  );
}

export async function listPendingTelemetryEvents(limit = 100): Promise<TelemetryEventRecord[]> {
  const database = await getTelemetryDatabase();
  const rows = (await database.executeAsync(
    'SELECT id, event_name, site_id, vendor_id, success, duration_ms, value, attributes_json, created_at_unix, sent_at_unix ' +
      'FROM telemetry_events WHERE sent_at_unix IS NULL ORDER BY id ASC LIMIT ?',
    [limit],
  )) as {
    rows?: Array<{
      id?: number;
      event_name?: string;
      site_id?: string;
      vendor_id?: string;
      success?: number | null;
      duration_ms?: number | null;
      value?: number | null;
      attributes_json?: string;
      created_at_unix?: number;
      sent_at_unix?: number | null;
    }>;
  };

  return (rows.rows ?? []).map((row) => {
    let attributes: Record<string, unknown> = {};
    try {
      attributes = row.attributes_json ? JSON.parse(row.attributes_json) : {};
    } catch {
      attributes = {};
    }

    return {
      id: asNumber(row.id),
      eventName: asString(row.event_name),
      siteId: row.site_id ?? undefined,
      vendorId: row.vendor_id ?? undefined,
      success: asBoolean(row.success === null ? undefined : Boolean(row.success)),
      durationMs: row.duration_ms ?? undefined,
      value: row.value ?? undefined,
      attributes,
      createdAtUnix: asNumber(row.created_at_unix),
      sentAtUnix: row.sent_at_unix ?? null,
    };
  });
}

export async function markTelemetryEventsSent(ids: number[]): Promise<void> {
  if (ids.length === 0) {
    return;
  }

  const database = await getTelemetryDatabase();
  await database.executeAsync(
    `UPDATE telemetry_events SET sent_at_unix = ? WHERE id IN (${ids.map(() => '?').join(',')})`,
    [nowUnix(), ...ids],
  );
}
