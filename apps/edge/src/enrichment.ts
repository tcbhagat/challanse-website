import { error, json } from './responses';
import type { Env } from './types';

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

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
}

function canonicalRequest(timestamp: string, requestId: string, keyId: string, method: string, path: string, contentSha256: string): string {
  return [timestamp, requestId, keyId, method.toUpperCase(), path, contentSha256].join('\n');
}

function inboundKey(env: Env, keyId: string): string {
  if (keyId === env.ENRICHMENT_TO_EDGE_HMAC_KEY_ID) return env.ENRICHMENT_TO_EDGE_HMAC_KEY ?? '';
  if (keyId === env.ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID) return env.ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY ?? '';
  return '';
}

async function consumeServiceRequest(request: Request, env: Env, payload: string): Promise<boolean> {
  const timestamp = request.headers.get('X-ChallanSe-Timestamp') ?? '';
  const requestId = request.headers.get('X-ChallanSe-Request-Id') ?? '';
  const keyId = request.headers.get('X-ChallanSe-Key-Id') ?? '';
  const contentSha256 = request.headers.get('X-ChallanSe-Content-SHA256') ?? '';
  const signature = request.headers.get('X-ChallanSe-Signature') ?? '';
  const secret = inboundKey(env, keyId);
  const timestampNumber = Number(timestamp);
  const actualContentSha256 = await sha256(payload);
  if (
    !secret
    || !requestId
    || !Number.isFinite(timestampNumber)
    || Math.abs(Date.now() - timestampNumber * 1000) > 60_000
    || !constantTimeEqual(contentSha256, actualContentSha256)
  ) return false;
  const path = new URL(request.url).pathname;
  const expected = await hmac(secret, canonicalRequest(timestamp, requestId, keyId, request.method, path, actualContentSha256));
  if (!constantTimeEqual(signature, expected)) return false;
  try {
    await env.DB.prepare(
      `INSERT INTO service_request_nonces (request_id, expires_at) VALUES (?, datetime('now', '+2 minutes'))`,
    ).bind(requestId).run();
    return true;
  } catch {
    return false;
  }
}

async function outboundHeaders(env: Env, method: string, path: string, payload: string): Promise<Record<string, string>> {
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

export async function dispatchEnrichment(env: Env, receipt: {
  id: string;
  siteId: string;
  imageKey: string;
  imageSha256: string;
  imageBytes: number;
  vendorId: string;
  capturedAtUnix: number;
  capturedQuantity: number;
}): Promise<'DISABLED' | 'QUEUED'> {
  if (!env.ENRICHMENT_URL || !env.EDGE_TO_ENRICHMENT_HMAC_KEY || !env.EDGE_TO_ENRICHMENT_HMAC_KEY_ID) {
    await env.DB.prepare(`INSERT INTO operations_log (id, site_id, event_type, detail_json) VALUES (?, ?, 'ENRICHMENT_DISABLED', ?)`)
      .bind(crypto.randomUUID(), receipt.siteId, JSON.stringify({ receiptId: receipt.id })).run();
    return 'DISABLED';
  }
  const body = JSON.stringify({
    receipt_id: receipt.id,
    site_id: receipt.siteId,
    image_key: receipt.imageKey,
    image_sha256: receipt.imageSha256,
    image_bytes: receipt.imageBytes,
    vendor_id: receipt.vendorId,
    captured_at_unix: receipt.capturedAtUnix,
    site_captured_quantity: receipt.capturedQuantity,
    schema_version: '1.0',
  });
  const path = '/v1/events/receipts';
  const response = await callEnrichment(env, path, JSON.parse(body));
  if (!response.ok) throw new Error(`enrichment_http_${response.status}`);
  return 'QUEUED';
}

export async function internalReceiptImage(request: Request, env: Env, receiptId: string): Promise<Response> {
  if (!env.ENRICHMENT_TO_EDGE_HMAC_KEY) return error(request, env, 503, 'ENRICHMENT_DISABLED', 'Enrichment is not configured.');
  if (!(await consumeServiceRequest(request, env, ''))) return error(request, env, 401, 'SERVICE_AUTH_INVALID', 'Service authentication failed.');
  const receipt = await env.DB.prepare(`SELECT image_key, image_sha256, image_bytes FROM receipts WHERE id = ? AND image_deleted_at IS NULL LIMIT 1`)
    .bind(receiptId).first<{ image_key: string; image_sha256: string; image_bytes: number }>();
  if (!receipt) return error(request, env, 404, 'IMAGE_NOT_FOUND', 'Receipt image is unavailable.');
  const object = await env.RECEIPTS.get(receipt.image_key);
  if (!object) return error(request, env, 404, 'IMAGE_NOT_FOUND', 'Receipt image is unavailable.');
  return new Response(object.body, {
    headers: {
      'Content-Type': 'image/webp',
      'Content-Length': String(receipt.image_bytes),
      'Cache-Control': 'private, no-store',
      ETag: `"${receipt.image_sha256}"`,
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

export async function enrichmentCallback(request: Request, env: Env, receiptId: string): Promise<Response> {
  if (!env.ENRICHMENT_TO_EDGE_HMAC_KEY) return error(request, env, 503, 'ENRICHMENT_DISABLED', 'Enrichment is not configured.');
  const raw = await request.text();
  if (!(await consumeServiceRequest(request, env, raw))) return error(request, env, 401, 'SERVICE_AUTH_INVALID', 'Service authentication failed.');
  const payload = JSON.parse(raw) as { status?: unknown; ocr_confidence?: unknown; raw_ocr_json?: unknown; gst_status?: unknown; version?: unknown };
  const allowedStatuses = new Set([
    'PENDING', 'QUEUED', 'PROCESSING', 'READY_FOR_REVIEW', 'NEEDS_HUMAN_REVIEW',
    'VERIFIED_GST', 'GST_ANOMALY', 'FAILED_RETRYABLE', 'FAILED_TERMINAL',
  ]);
  if (
    typeof payload.status !== 'string'
    || !allowedStatuses.has(payload.status)
    || !Number.isInteger(payload.version)
    || Number(payload.version) < 1
    || (payload.ocr_confidence != null && (typeof payload.ocr_confidence !== 'number' || payload.ocr_confidence < 0 || payload.ocr_confidence > 100))
    || JSON.stringify(payload.raw_ocr_json ?? {}).length > 250_000
  ) return error(request, env, 400, 'INVALID_ENRICHMENT', 'Enrichment result is invalid.');
  const version = Number(payload.version);
  const updated = await env.DB.prepare(
    `UPDATE receipts SET enrichment_status = ?, ocr_confidence = ?, raw_ocr_json = ?, gst_status = ?, enrichment_version = ?, updated_at = CURRENT_TIMESTAMP
     WHERE id = ? AND enrichment_version < ?`,
  ).bind(payload.status, payload.ocr_confidence ?? null, JSON.stringify(payload.raw_ocr_json ?? {}), typeof payload.gst_status === 'string' ? payload.gst_status : 'NOT_CHECKED', version, receiptId, version).run();
  if (Number(updated.meta.changes ?? 0) !== 1) return error(request, env, 409, 'ENRICHMENT_VERSION_CONFLICT', 'A newer enrichment result already exists.');
  await env.DB.prepare(`INSERT INTO receipt_audits (id, receipt_id, site_id, event_type, actor, event_json) SELECT ?, id, site_id, 'ENRICHMENT_UPDATED', 'service:enrichment', ? FROM receipts WHERE id = ?`)
    .bind(crypto.randomUUID(), JSON.stringify({ status: payload.status, version }), receiptId).run();
  return json(request, env, { receiptId, accepted: true });
}
