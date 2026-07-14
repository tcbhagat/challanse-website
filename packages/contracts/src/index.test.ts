import { describe, expect, it } from 'vitest';
import { receiptReviewSchema, receiptUploadMetadataSchema } from './index';

describe('receipt contracts', () => {
  it('accepts real upload metadata', () => {
    const parsed = receiptUploadMetadataSchema.parse({
      receiptId: '0195279a-7f6f-7af8-bc14-28640f0aa99a',
      vendorId: 'vendor-alpha',
      capturedAtUnix: 1_800_000_000,
      capturedQuantity: 12,
      imageSha256: 'a'.repeat(64),
      appVersion: '1.0.0',
      configurationVersion: 1,
    });
    expect(parsed.capturedQuantity).toBe(12);
  });

  it('rejects non-positive verified quantities', () => {
    expect(() => receiptReviewSchema.parse({
      action: 'VERIFY', version: 1, materialDescription: 'Cement', verifiedQuantity: 0, unit: 'BAG',
    })).toThrow();
  });
});
