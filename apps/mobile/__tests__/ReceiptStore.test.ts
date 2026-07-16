import { getReceiptDatabaseSecurityStatus, insertReceiptEvent } from '../src/engine/receiptStore';

const queryLog = globalThis as unknown as {
  __opSqliteQueries: Array<{ query: string; params?: unknown[] }>;
};

describe('receipt hot path', () => {
  it('requires a native SQLCipher build before accepting receipt data', async () => {
    await expect(getReceiptDatabaseSecurityStatus()).resolves.toEqual({
      encrypted: true,
      databasePath: '/data/receipt-ingestion-v2.db',
    });
  });

  it('retains all metadata across 100 synthetic contract writes', async () => {
    queryLog.__opSqliteQueries.length = 0;

    for (let index = 0; index < 100; index += 1) {
      const receiptId = `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
      const record = await insertReceiptEvent({
        receiptId,
        imageBlob: new Uint8Array([index % 255, 1, 2, 3]),
        capturedAtUnix: 1_800_000_000 + index,
        vendorId: `vendor-${index % 4}`,
        siteId: 'site-pilot-01',
        deviceId: 'device-pilot-01',
        capturedQuantity: index + 1,
        appVersion: '1.0.0',
        configurationVersion: 7,
      });
      expect(record.receiptId).toBe(receiptId);
    }

    const inserts = queryLog.__opSqliteQueries.filter(({ query }) =>
      query.startsWith('INSERT INTO receipt_events'),
    );
    expect(inserts).toHaveLength(100);
    expect(inserts[9].params?.slice(0, 8)).toEqual([
      '00000000-0000-4000-8000-000000000009',
      'site-pilot-01',
      'device-pilot-01',
      'vendor-1',
      1_800_000_009,
      10,
      '1.0.0',
      7,
    ]);
  });
});
