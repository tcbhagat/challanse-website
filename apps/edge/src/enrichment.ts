import { error } from './responses';
import { corsHeaders } from './security';
import type { AccessIdentity, Env } from './types';

async function sha256(body: string | ArrayBuffer): Promise<string> {
  const bytes = typeof body === 'string' ? new TextEncoder().encode(body) : body;
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, '0')).join('');
}

async function hmac(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body));
  return Array.from(new Uint8Array(signature), (value) => value.toString(16).padStart(2, '0')).join('');
}

function canonicalRequest(timestamp: string, requestId: string, keyId: string, method: string, path: string, contentSha256: string): string {
  return [timestamp, requestId, keyId, method.toUpperCase(), path, contentSha256].join('\n');
}

async function outboundHeaders(env: Env, method: string, path: string, payload: string | ArrayBuffer): Promise<Record<string, string>> {
  if (!env.EDGE_TO_ENRICHMENT_HMAC_KEY || !env.EDGE_TO_ENRICHMENT_HMAC_KEY_ID) {
    throw new Error('edge_to_enrichment_auth_unconfigured');
  }
  const timestamp = String(Math.floor(Date.now() / 1000));
  const requestId = crypto.randomUUID();
  const contentSha256 = await sha256(payload);
  const signature = await hmac(
    env.EDGE_TO_ENRICHMENT_HMAC_KEY,
    canonicalRequest(timestamp, requestId, env.EDGE_TO_ENRICHMENT_HMAC_KEY_ID, method, path, contentSha256),
  );
  return {
    'X-ChallanSe-Signature': signature,
    'X-ChallanSe-Timestamp': timestamp,
    'X-ChallanSe-Request-Id': requestId,
    'X-ChallanSe-Key-Id': env.EDGE_TO_ENRICHMENT_HMAC_KEY_ID,
    'X-ChallanSe-Content-SHA256': contentSha256,
    'CF-Access-Client-Id': env.ENRICHMENT_ACCESS_CLIENT_ID ?? '',
    'CF-Access-Client-Secret': env.ENRICHMENT_ACCESS_CLIENT_SECRET ?? '',
  };
}

export async function callEnrichment(env: Env, path: string, payload: unknown): Promise<Response> {
  if (!env.ENRICHMENT_URL) throw new Error('enrichment_url_unconfigured');
  const body = JSON.stringify(payload);
  return fetch(`${env.ENRICHMENT_URL.replace(/\/$/, '')}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(await outboundHeaders(env, 'POST', path, body)) },
    body,
  });
}

export async function proxyAuthoritativeRequest(
  request: Request,
  env: Env,
  identity?: AccessIdentity,
  turnstileVerified = false,
): Promise<Response> {
  if (!env.ENRICHMENT_URL) return error(request, env, 503, 'AUTHORITATIVE_API_UNAVAILABLE', 'The production data service is unavailable.');
  const sourceUrl = new URL(request.url);
  const path = sourceUrl.pathname;
  const signedTarget = `${path}${sourceUrl.search}`;
  const body = request.method === 'GET' || request.method === 'HEAD' ? new ArrayBuffer(0) : await request.arrayBuffer();
  if (body.byteLength > 1_100_000) return error(request, env, 413, 'REQUEST_TOO_LARGE', 'The request exceeds the production limit.');
  const headers = new Headers(await outboundHeaders(env, request.method, signedTarget, body));
  for (const name of ['Authorization', 'Content-Type', 'Accept', 'X-Part-Sha256', 'X-ChallanSe-Nonce', 'X-ChallanSe-Device-Timestamp', 'X-ChallanSe-Site-Id', 'X-ChallanSe-Play-Integrity']) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  if (identity) {
    headers.set('X-ChallanSe-OIDC-Issuer', identity.issuer);
    headers.set('X-ChallanSe-OIDC-Subject', identity.subject);
    headers.set('X-ChallanSe-OIDC-Email', identity.email);
    headers.set('X-ChallanSe-Source-Class', 'cloudflare-access');
  }
  if (turnstileVerified) headers.set('X-ChallanSe-Turnstile-Verified', 'true');
  const upstream = await fetch(`${env.ENRICHMENT_URL.replace(/\/$/, '')}${signedTarget}`, {
    method: request.method,
    headers,
    body: body.byteLength ? body : undefined,
    redirect: 'manual',
  });
  const responseHeaders = new Headers(upstream.headers);
  for (const [name, value] of Object.entries(corsHeaders(request, env))) responseHeaders.set(name, String(value));
  responseHeaders.set('Cache-Control', responseHeaders.get('Cache-Control') ?? 'no-store');
  responseHeaders.delete('Server');
  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}
