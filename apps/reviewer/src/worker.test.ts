import { afterEach, describe, expect, it, vi } from 'vitest';
import { handleReviewerRequest, type ReviewerWorkerEnv } from './worker';

const assetFetch = vi.fn(async () => new Response('asset'));
const env = { API_ORIGIN: 'https://api.challanse.constrovet.com', ASSETS: { fetch: assetFetch } } satisfies ReviewerWorkerEnv;

afterEach(() => vi.unstubAllGlobals());

describe('reviewer same-origin proxy', () => {
  it('serves non-API requests from static assets', async () => {
    expect(await (await handleReviewerRequest(new Request('https://review.challanse.constrovet.com/'), env)).text()).toBe('asset');
  });

  it('rejects a reviewer request without an Access assertion', async () => {
    const response = await handleReviewerRequest(new Request('https://review.challanse.constrovet.com/api/v1/reviewer/receipts'), env);
    expect(response.status).toBe(401);
  });

  it('forwards the assertion and streams private images without cookies', async () => {
    vi.stubGlobal('fetch', vi.fn(async (request: Request) => {
      expect(request.url).toBe('https://api.challanse.constrovet.com/v1/reviewer/receipts/receipt-1/image');
      expect(request.headers.get('Cf-Access-Jwt-Assertion')).toBe('signed-access-jwt');
      expect(request.headers.has('Cookie')).toBe(false);
      return new Response(new Uint8Array([82, 73, 70, 70]), { headers: { 'Content-Type': 'image/webp' } });
    }));
    const response = await handleReviewerRequest(new Request(
      'https://review.challanse.constrovet.com/api/v1/reviewer/receipts/receipt-1/image',
      { headers: { 'Cf-Access-Jwt-Assertion': 'signed-access-jwt', Cookie: 'CF_Authorization=private' } },
    ), env);
    expect(response.headers.get('Content-Type')).toBe('image/webp');
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([82, 73, 70, 70]));
  });

  it('does not expose mobile routes through the reviewer', async () => {
    const response = await handleReviewerRequest(new Request(
      'https://review.challanse.constrovet.com/api/v1/mobile/bootstrap',
      { headers: { 'Cf-Access-Jwt-Assertion': 'signed-access-jwt' } },
    ), env);
    expect(response.status).toBe(404);
  });
});
