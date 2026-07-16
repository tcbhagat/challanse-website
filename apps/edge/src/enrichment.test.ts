import { afterEach, describe, expect, it, vi } from 'vitest';

import { callEnrichment, proxyAuthoritativeRequest } from './enrichment';
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
  return {
    ALLOWED_ORIGINS: 'https://review.challanse.constrovet.com',
    ACCESS_TEAM_DOMAIN: 'constrovet.cloudflareaccess.com',
    ACCESS_AUD: 'review-audience',
    TURNSTILE_SECRET: 'turnstile',
    ENVIRONMENT: 'production',
    ENRICHMENT_URL: 'https://enrichment.example',
    EDGE_TO_ENRICHMENT_HMAC_KEY_ID: 'edge-current',
    EDGE_TO_ENRICHMENT_HMAC_KEY: 'edge-secret',
    EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID: 'edge-next',
    EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY: 'edge-next-secret',
    ENRICHMENT_ACCESS_CLIENT_ID: 'access-id',
    ENRICHMENT_ACCESS_CLIENT_SECRET: 'access-secret',
  };
}

afterEach(() => vi.unstubAllGlobals());

describe('stateless authoritative proxy', () => {
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

  it('forwards immutable OIDC identity and site selection', async () => {
    const env = fakeEnv();
    const fetchMock = vi.fn().mockResolvedValue(new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const request = new Request('https://api.challanse.constrovet.com/v1/reviewer/receipts?status=NEEDS_REVIEW&limit=25', {
      headers: { 'X-ChallanSe-Site-Id': '22222222-2222-4222-8222-222222222222' },
    });
    await proxyAuthoritativeRequest(request, env, {
      issuer: 'https://constrovet.cloudflareaccess.com',
      subject: 'oidc-subject-1',
      email: 'reviewer@example.com',
    });
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const headers = new Headers(init.headers);
    const contentHash = await sha256('');
    const canonical = [
      headers.get('X-ChallanSe-Timestamp'),
      headers.get('X-ChallanSe-Request-Id'),
      'edge-current',
      'GET',
      '/v1/reviewer/receipts?status=NEEDS_REVIEW&limit=25',
      contentHash,
    ].join('\n');
    expect(url).toBe('https://enrichment.example/v1/reviewer/receipts?status=NEEDS_REVIEW&limit=25');
    expect(headers.get('X-ChallanSe-Signature')).toBe(await signature('edge-secret', canonical));
    expect(headers.get('X-ChallanSe-OIDC-Subject')).toBe('oidc-subject-1');
    expect(headers.get('X-ChallanSe-Site-Id')).toBe('22222222-2222-4222-8222-222222222222');
  });

  it('streams private image responses without buffering or public caching', async () => {
    const env = fakeEnv();
    const stream = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array([1, 2, 3])); controller.close(); } });
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(stream, {
      status: 200,
      headers: { 'Content-Type': 'image/webp', 'Cache-Control': 'private, no-store' },
    })));
    const response = await proxyAuthoritativeRequest(
      new Request('https://api.challanse.constrovet.com/v1/reviewer/receipts/receipt-1/image'),
      env,
      { issuer: 'https://constrovet.cloudflareaccess.com', subject: 'subject', email: 'reviewer@example.com' },
    );
    expect(response.status).toBe(200);
    expect(response.headers.get('Cache-Control')).toBe('private, no-store');
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
  });
});
