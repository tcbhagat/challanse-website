import { insertReceiptEvent } from '../src/engine/receiptStore';

const queryLog = globalThis as unknown as {
  __quickSqliteQueries: Array<{ query: string; params?: unknown[] }>;
};

describe('receipt hot path', () => {
  it('retains all metadata across 100 synthetic writes within the CI latency guard', async () => {
    queryLog.__quickSqliteQueries.length = 0;
    const durations: number[] = [];

    for (let index = 0; index < 100; index += 1) {
      const startedAt = Date.now();
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
      durations.push(Date.now() - startedAt);
      expect(record.receiptId).toBe(receiptId);
    }

    const inserts = queryLog.__quickSqliteQueries.filter(({ query }) =>
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

    const sorted = [...durations].sort((left, right) => left - right);
    expect(sorted[Math.ceil(sorted.length * 0.95) - 1]).toBeLessThan(50);
  });
});
