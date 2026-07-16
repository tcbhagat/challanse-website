import { afterEach, describe, expect, it, vi } from 'vitest';

import { callEnrichment, internalReceiptImage } from './enrichment';
import type { Env } from './types';

async function sha256(body: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body));
  return Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, '0')).join('');
}

async function signature(secret: string, canonical: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signed = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(canonical));
  return Array.from(new Uint8Array(signed), (value) => value.toString(16).padStart(2, '0')).join('');
}

function fakeEnv(): Env {
  const nonces = new Set<string>();
  const database = {
    prepare(sql: string) {
      return {
        bind(...values: unknown[]) {
          return {
            async run() {
              if (sql.includes('service_request_nonces')) {
                const requestId = String(values[0]);
                if (nonces.has(requestId)) throw new Error('duplicate');
                nonces.add(requestId);
              }
              return { meta: { changes: 1 } };
            },
            async first() {
              if (sql.includes('FROM receipts')) return { image_key: 'site/receipt.webp', image_sha256: 'a'.repeat(64), image_bytes: 12 };
              return null;
            },
          };
        },
      };
    },
  };
  return {
    DB: database as unknown as D1Database,
    RECEIPTS: { get: vi.fn().mockResolvedValue({ body: new Uint8Array([1, 2, 3]) }) } as unknown as R2Bucket,
    RECEIPT_QUEUE: {} as Queue,
    ALLOWED_ORIGINS: 'https://review.challanse.constrovet.com',
    ACCESS_TEAM_DOMAIN: '',
    ACCESS_AUD: '',
    DEVICE_TOKEN_PEPPER: 'pepper',
    TURNSTILE_SECRET: 'turnstile',
    ENVIRONMENT: 'production',
    ENRICHMENT_URL: 'https://enrichment.example',
    EDGE_TO_ENRICHMENT_HMAC_KEY_ID: 'edge-current',
    EDGE_TO_ENRICHMENT_HMAC_KEY: 'edge-secret',
    EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID: 'edge-next',
    EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY: 'edge-next-secret',
    ENRICHMENT_TO_EDGE_HMAC_KEY_ID: 'enrichment-current',
    ENRICHMENT_TO_EDGE_HMAC_KEY: 'enrichment-secret',
    ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID: 'enrichment-next',
    ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY: 'enrichment-next-secret',
    ENRICHMENT_ACCESS_CLIENT_ID: 'access-id',
    ENRICHMENT_ACCESS_CLIENT_SECRET: 'access-secret',
  };
}

afterEach(() => vi.unstubAllGlobals());

describe('directional enrichment authentication', () => {
  it('forwards Access credentials and a verifiable content signature', async () => {
    const env = fakeEnv();
    const fetchMock = vi.fn().mockResolvedValue(new Response('{}', { status: 202 }));
    vi.stubGlobal('fetch', fetchMock);
    await callEnrichment(env, '/v1/events/reviews', { receipt_id: 'receipt-1' });
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const headers = new Headers(init.headers);
    const body = String(init.body);
    const contentHash = await sha256(body);
    const canonical = [
      headers.get('X-ChallanSe-Timestamp'),
      headers.get('X-ChallanSe-Request-Id'),
      'edge-current',
      'POST',
      '/v1/events/reviews',
      contentHash,
    ].join('\n');
    expect(url).toBe('https://enrichment.example/v1/events/reviews');
    expect(headers.get('CF-Access-Client-Id')).toBe('access-id');
    expect(headers.get('CF-Access-Client-Secret')).toBe('access-secret');
    expect(headers.get('X-ChallanSe-Content-SHA256')).toBe(contentHash);
    expect(headers.get('X-ChallanSe-Signature')).toBe(await signature('edge-secret', canonical));
  });

  it('streams a private image once and rejects a replayed request ID', async () => {
    const env = fakeEnv();
    const timestamp = String(Math.floor(Date.now() / 1000));
    const requestId = crypto.randomUUID();
    const path = '/v1/internal/receipts/receipt-1/image';
    const contentHash = await sha256('');
    const signed = await signature('enrichment-secret', [timestamp, requestId, 'enrichment-current', 'GET', path, contentHash].join('\n'));
    const headers = {
      'X-ChallanSe-Timestamp': timestamp,
      'X-ChallanSe-Request-Id': requestId,
      'X-ChallanSe-Key-Id': 'enrichment-current',
      'X-ChallanSe-Content-SHA256': contentHash,
      'X-ChallanSe-Signature': signed,
    };
    const first = await internalReceiptImage(new Request(`https://api.example${path}`, { headers }), env, 'receipt-1');
    const replay = await internalReceiptImage(new Request(`https://api.example${path}`, { headers }), env, 'receipt-1');
    expect(first.status).toBe(200);
    expect(first.headers.get('Cache-Control')).toBe('private, no-store');
    expect(replay.status).toBe(401);
  });

  it('accepts the staged next callback key during rotation', async () => {
    const env = fakeEnv();
    const timestamp = String(Math.floor(Date.now() / 1000));
    const requestId = crypto.randomUUID();
    const path = '/v1/internal/receipts/receipt-1/image';
    const contentHash = await sha256('');
    const signed = await signature('enrichment-next-secret', [timestamp, requestId, 'enrichment-next', 'GET', path, contentHash].join('\n'));
    const response = await internalReceiptImage(new Request(`https://api.example${path}`, { headers: {
      'X-ChallanSe-Timestamp': timestamp,
      'X-ChallanSe-Request-Id': requestId,
      'X-ChallanSe-Key-Id': 'enrichment-next',
      'X-ChallanSe-Content-SHA256': contentHash,
      'X-ChallanSe-Signature': signed,
    } }), env, 'receipt-1');
    expect(response.status).toBe(200);
  });
});
