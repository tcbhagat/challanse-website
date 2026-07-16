import {
  enrollmentRequestSchema,
  pilotRequestSchema,
  receiptReviewSchema,
  receiptUploadMetadataSchema,
  vendorSchema,
  type ReceiptListItem,
} from '@challanse/contracts';
import { error, json } from './responses';
import {
  authenticateDevice,
  authenticateReviewer,
  consumeReplayNonce,
  corsHeaders,
  isWebp,
  randomEnrollmentCode,
  randomToken,
  sha256Hex,
} from './security';
import type { DeviceIdentity, Env, ReceiptQueueMessage, ReviewerIdentity } from './types';
import { completeUploadSession, createUploadSession, getUploadSession, putUploadPart } from './resumableUploads';
import { callEnrichment, dispatchEnrichment, enrichmentCallback, internalReceiptImage } from './enrichment';

const MAX_PAGE_SIZE = 50;
const IMAGE_RETENTION_DAYS = 90;
const AUDIT_RETENTION_DAYS = 365;

function requestPath(request: Request): string {
  return new URL(request.url).pathname.replace(/\/$/, '') || '/';
}

async function parseJson(request: Request): Promise<unknown> {
  if (!(request.headers.get('Content-Type') ?? '').toLowerCase().includes('application/json')) {
    throw new Error('content_type');
  }
  return request.json();
}

async function rateLimit(request: Request, env: Env, route: string, maximum: number): Promise<boolean> {
  const remoteAddress = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const minute = Math.floor(Date.now() / 60_000);
  const key = await sha256Hex(`${route}:${remoteAddress}:${minute}`);
  await env.DB.prepare(
    `INSERT INTO request_limits (limit_key, request_count, expires_at) VALUES (?, 1, datetime('now', '+2 minutes'))
     ON CONFLICT(limit_key) DO UPDATE SET request_count = request_count + 1`,
  ).bind(key).run();
  const row = await env.DB.prepare(`SELECT request_count FROM request_limits WHERE limit_key = ?`).bind(key).first<{ request_count: number }>();
  return Number(row?.request_count ?? maximum + 1) <= maximum;
}

async function requireDevice(request: Request, env: Env): Promise<DeviceIdentity | Response> {
  const identity = await authenticateDevice(request, env);
  return identity ?? error(request, env, 401, 'DEVICE_UNAUTHORIZED', 'Device enrollment is missing or revoked.');
}

async function requireReviewer(request: Request, env: Env, admin = false): Promise<ReviewerIdentity | Response> {
  const identity = await authenticateReviewer(request, env);
  if (!identity) return error(request, env, 401, 'REVIEWER_UNAUTHORIZED', 'Reviewer authentication is required.');
  if (admin && identity.role !== 'ADMIN') return error(request, env, 403, 'ADMIN_REQUIRED', 'Administrator access is required.');
  return identity;
}

async function verifyTurnstile(token: string, request: Request, env: Env): Promise<boolean> {
  if (!env.TURNSTILE_SECRET) return env.ENVIRONMENT !== 'production';
  const body = new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: token });
  const remoteIp = request.headers.get('CF-Connecting-IP');
  if (remoteIp) body.set('remoteip', remoteIp);
  const response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body });
  if (!response.ok) return false;
  const result = await response.json<{ success?: boolean }>();
  return result.success === true;
}

async function enrollDevice(request: Request, env: Env): Promise<Response> {
  if (!env.DEVICE_TOKEN_PEPPER) return error(request, env, 503, 'SERVICE_NOT_CONFIGURED', 'Device enrollment is not configured.');
  if (!(await rateLimit(request, env, 'device-enroll', 10))) return error(request, env, 429, 'RATE_LIMITED', 'Too many enrollment attempts.');
  let input;
  try {
    input = enrollmentRequestSchema.parse(await parseJson(request));
  } catch {
    return error(request, env, 400, 'INVALID_ENROLLMENT', 'Enrollment code and device details are invalid.');
  }
  const codeHash = await sha256Hex(input.enrollmentCode);
  const enrollment = await env.DB.prepare(
    `SELECT site_id, device_name FROM enrollment_codes WHERE code_hash = ? AND used_at IS NULL AND expires_at > CURRENT_TIMESTAMP LIMIT 1`,
  ).bind(codeHash).first<{ site_id: string; device_name: string }>();
  if (!enrollment) return error(request, env, 410, 'ENROLLMENT_EXPIRED', 'Enrollment code is expired, invalid, or already used.');

  const activeDevices = await env.DB.prepare(`SELECT COUNT(*) AS count FROM devices WHERE site_id = ? AND active = 1`)
    .bind(enrollment.site_id).first<{ count: number }>();
  if (Number(activeDevices?.count ?? 0) >= 5) return error(request, env, 409, 'DEVICE_LIMIT', 'The five-device pilot limit has been reached.');

  const deviceId = crypto.randomUUID();
  const token = randomToken();
  const tokenHash = await sha256Hex(`${token}:${env.DEVICE_TOKEN_PEPPER}`);
  try {
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE enrollment_codes SET used_at = CURRENT_TIMESTAMP, used_by_device_id = ?
         WHERE code_hash = ? AND used_at IS NULL AND expires_at > CURRENT_TIMESTAMP`,
      ).bind(deviceId, codeHash),
      env.DB.prepare(
        `INSERT INTO devices (id, site_id, name, token_hash, app_version)
         SELECT ?, site_id, ?, ?, ? FROM enrollment_codes
         WHERE code_hash = ? AND used_by_device_id = ?`,
      ).bind(deviceId, input.deviceName || enrollment.device_name, tokenHash, input.appVersion, codeHash, deviceId),
    ]);
  } catch (caught) {
    if (caught instanceof Error && caught.message.includes('device_limit_reached')) {
      return error(request, env, 409, 'DEVICE_LIMIT', 'The five-device pilot limit has been reached.');
    }
    throw caught;
  }
  const created = await env.DB.prepare(`SELECT id FROM devices WHERE id = ? LIMIT 1`).bind(deviceId).first<{ id: string }>();
  if (!created) return error(request, env, 409, 'ENROLLMENT_USED', 'Enrollment code has already been used.');
  return json(request, env, { deviceId, deviceToken: token }, 201);
}

async function mobileBootstrap(request: Request, env: Env, device: DeviceIdentity): Promise<Response> {
  const [site, vendorsResult] = await Promise.all([
    env.DB.prepare(
      `SELECT id, name, allowed_wifi_ssids_json, configuration_version, daily_receipt_limit, image_byte_limit FROM sites WHERE id = ? AND active = 1`,
    ).bind(device.siteId).first<{
      id: string; name: string; allowed_wifi_ssids_json: string; configuration_version: number;
      daily_receipt_limit: number; image_byte_limit: number;
    }>(),
    env.DB.prepare(
      `SELECT id, name, initials, color FROM vendors WHERE site_id = ? AND active = 1 ORDER BY display_order, name LIMIT 4`,
    ).bind(device.siteId).all<{ id: string; name: string; initials: string; color: string }>(),
  ]);
  if (!site) return error(request, env, 403, 'SITE_INACTIVE', 'The enrolled site is not active.');
  const vendors = vendorsResult.results.map((vendor) => vendorSchema.parse(vendor));
  return json(request, env, {
    site: { id: site.id, name: site.name },
    device: { id: device.id, name: device.name },
    vendors,
    allowedWifiSsids: JSON.parse(site.allowed_wifi_ssids_json) as string[],
    configurationVersion: site.configuration_version,
    limits: { dailyReceipts: site.daily_receipt_limit, imageBytes: site.image_byte_limit },
  });
}

async function uploadReceipt(request: Request, env: Env, device: DeviceIdentity): Promise<Response> {
  if (!(await consumeReplayNonce(request, env, device.id))) {
    return error(request, env, 409, 'REPLAY_REJECTED', 'Upload timestamp or nonce is invalid or already used.');
  }
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return error(request, env, 400, 'INVALID_MULTIPART', 'Receipt upload must be multipart form data.');
  }
  const rawMetadata = form.get('metadata');
  const image = form.get('image');
  if (typeof rawMetadata !== 'string' || !(image instanceof File)) {
    return error(request, env, 400, 'MISSING_UPLOAD_PARTS', 'metadata and image parts are required.');
  }

  let metadata;
  try {
    metadata = receiptUploadMetadataSchema.parse(JSON.parse(rawMetadata));
  } catch {
    return error(request, env, 400, 'INVALID_METADATA', 'Receipt metadata is invalid.');
  }
  const existing = await env.DB.prepare(
    `SELECT id, site_id, device_id, image_sha256, status FROM receipts WHERE id = ? LIMIT 1`,
  ).bind(metadata.receiptId).first<{ id: string; site_id: string; device_id: string; image_sha256: string; status: string }>();
  if (existing) {
    if (existing.site_id === device.siteId && existing.device_id === device.id && existing.image_sha256 === metadata.imageSha256) {
      return json(request, env, { receiptId: existing.id, status: existing.status, duplicate: true }, 202);
    }
    return error(request, env, 409, 'RECEIPT_ID_CONFLICT', 'Receipt identifier is already associated with different content.');
  }

  const site = await env.DB.prepare(
    `SELECT daily_receipt_limit, image_byte_limit, storage_byte_limit, stored_image_bytes FROM sites WHERE id = ? AND active = 1`,
  ).bind(device.siteId).first<{
    daily_receipt_limit: number; image_byte_limit: number; storage_byte_limit: number; stored_image_bytes: number;
  }>();
  if (!site) return error(request, env, 403, 'SITE_INACTIVE', 'The enrolled site is not active.');
  if (image.size > site.image_byte_limit) return error(request, env, 413, 'IMAGE_TOO_LARGE', `Image must not exceed ${site.image_byte_limit} bytes.`);
  if (site.stored_image_bytes >= site.storage_byte_limit * 0.9) {
    return error(request, env, 507, 'PILOT_STORAGE_PAUSED', 'Cloud storage is paused; the receipt remains safely queued on this device.');
  }
  const todayCount = await env.DB.prepare(
    `SELECT COUNT(*) AS count FROM receipts WHERE site_id = ? AND created_at >= date('now')`,
  ).bind(device.siteId).first<{ count: number }>();
  if (Number(todayCount?.count ?? 0) >= site.daily_receipt_limit) {
    return error(request, env, 429, 'DAILY_LIMIT', 'The controlled pilot daily receipt limit has been reached.');
  }
  const vendor = await env.DB.prepare(`SELECT id FROM vendors WHERE id = ? AND site_id = ? AND active = 1`)
    .bind(metadata.vendorId, device.siteId).first<{ id: string }>();
  if (!vendor) return error(request, env, 400, 'INVALID_VENDOR', 'Vendor is not active for this site.');

  const bytes = await image.arrayBuffer();
  if (!isWebp(new Uint8Array(bytes))) return error(request, env, 415, 'INVALID_IMAGE', 'Only valid WebP receipt images are accepted.');
  const actualHash = await sha256Hex(bytes);
  if (actualHash !== metadata.imageSha256) return error(request, env, 422, 'CHECKSUM_MISMATCH', 'Image checksum does not match the uploaded content.');

  const imageKey = `${device.siteId}/${new Date().toISOString().slice(0, 10)}/${metadata.receiptId}.webp`;
  await env.RECEIPTS.put(imageKey, bytes, {
    httpMetadata: { contentType: 'image/webp', cacheControl: 'private, no-store' },
    customMetadata: { receiptId: metadata.receiptId, siteId: device.siteId, sha256: actualHash },
  });
  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO receipts (id, site_id, device_id, vendor_id, captured_at_unix, captured_quantity, image_key, image_bytes, image_sha256, status, app_version, configuration_version)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'RECEIVED', ?, ?)`,
      ).bind(
        metadata.receiptId, device.siteId, device.id, metadata.vendorId, metadata.capturedAtUnix,
        metadata.capturedQuantity, imageKey, image.size, actualHash, metadata.appVersion, metadata.configurationVersion,
      ),
      env.DB.prepare(`UPDATE sites SET stored_image_bytes = stored_image_bytes + ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?`)
        .bind(image.size, device.siteId),
      env.DB.prepare(
        `INSERT INTO receipt_audits (id, receipt_id, site_id, event_type, actor, event_json) VALUES (?, ?, ?, 'RECEIVED', ?, ?)`,
      ).bind(crypto.randomUUID(), metadata.receiptId, device.siteId, `device:${device.id}`, JSON.stringify({ imageBytes: image.size })),
    ]);
  } catch (caught) {
    await env.RECEIPTS.delete(imageKey);
    throw caught;
  }
  try {
    await env.RECEIPT_QUEUE.send({ receiptId: metadata.receiptId, siteId: device.siteId });
  } catch {
    await env.DB.prepare(
      `INSERT INTO operations_log (id, site_id, event_type, detail_json) VALUES (?, ?, 'QUEUE_SEND_FAILED', ?)`,
    ).bind(crypto.randomUUID(), device.siteId, JSON.stringify({ receiptId: metadata.receiptId })).run();
  }
  return json(request, env, { receiptId: metadata.receiptId, status: 'RECEIVED', duplicate: false }, 202);
}

async function listReceipts(request: Request, env: Env, reviewer: ReviewerIdentity): Promise<Response> {
  const url = new URL(request.url);
  const status = url.searchParams.get('status') ?? 'NEEDS_REVIEW';
  if (!['RECEIVED', 'NEEDS_REVIEW', 'VERIFIED', 'REJECTED'].includes(status)) {
    return error(request, env, 400, 'INVALID_STATUS', 'Receipt status filter is invalid.');
  }
  const limit = Math.min(MAX_PAGE_SIZE, Math.max(1, Number(url.searchParams.get('limit') ?? 25)));
  const cursor = url.searchParams.get('cursor') ?? '9999-12-31 23:59:59';
  const result = await env.DB.prepare(
    `SELECT r.id, r.vendor_id, v.name AS vendor_name, r.captured_at_unix, r.captured_quantity, r.status, r.version,
            r.challan_number, r.po_number, r.material_code, r.material_description, r.verified_quantity, r.unit, r.notes, r.created_at,
            r.enrichment_status, r.ocr_confidence, r.raw_ocr_json, r.gst_status
       FROM receipts r JOIN vendors v ON v.id = r.vendor_id
      WHERE r.site_id = ? AND r.status = ? AND r.created_at < ?
      ORDER BY r.created_at DESC LIMIT ?`,
  ).bind(reviewer.siteId, status, cursor, limit + 1).all<{
    id: string; vendor_id: string; vendor_name: string; captured_at_unix: number; captured_quantity: number;
    status: ReceiptListItem['status']; version: number; challan_number: string; po_number: string; material_code: string; material_description: string;
    verified_quantity: number | null; unit: string; notes: string; created_at: string; enrichment_status: string;
    ocr_confidence: number | null; raw_ocr_json: string; gst_status: string;
  }>();
  const hasMore = result.results.length > limit;
  const rows = result.results.slice(0, limit);
  const receipts: ReceiptListItem[] = rows.map((row) => ({
    id: row.id,
    vendorId: row.vendor_id,
    vendorName: row.vendor_name,
    capturedAtUnix: row.captured_at_unix,
    capturedQuantity: row.captured_quantity,
    status: row.status,
    version: row.version,
    imageUrl: `/v1/reviewer/receipts/${row.id}/image`,
    challanNumber: row.challan_number,
    poNumber: row.po_number,
    materialCode: row.material_code,
    materialDescription: row.material_description,
    verifiedQuantity: row.verified_quantity,
    unit: row.unit,
    notes: row.notes,
    enrichmentStatus: row.enrichment_status,
    ocrConfidence: row.ocr_confidence,
    rawOcrJson: JSON.parse(row.raw_ocr_json) as Record<string, unknown>,
    gstStatus: row.gst_status,
  }));
  return json(request, env, { receipts, nextCursor: hasMore ? rows.at(-1)?.created_at ?? null : null });
}

async function getReceiptImage(request: Request, env: Env, reviewer: ReviewerIdentity, receiptId: string): Promise<Response> {
  const row = await env.DB.prepare(
    `SELECT image_key, image_sha256 FROM receipts WHERE id = ? AND site_id = ? AND image_deleted_at IS NULL LIMIT 1`,
  ).bind(receiptId, reviewer.siteId).first<{ image_key: string; image_sha256: string }>();
  if (!row) return error(request, env, 404, 'IMAGE_NOT_FOUND', 'Receipt image is unavailable.');
  const object = await env.RECEIPTS.get(row.image_key);
  if (!object) return error(request, env, 404, 'IMAGE_NOT_FOUND', 'Receipt image is unavailable.');
  return new Response(object.body, {
    headers: {
      ...corsHeaders(request, env),
      'Content-Type': 'image/webp',
      'Cache-Control': 'private, no-store',
      ETag: `"${row.image_sha256}"`,
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

async function reviewReceipt(request: Request, env: Env, reviewer: ReviewerIdentity, receiptId: string): Promise<Response> {
  let review;
  try {
    review = receiptReviewSchema.parse(await parseJson(request));
  } catch {
    return error(request, env, 400, 'INVALID_REVIEW', 'Review fields are incomplete or invalid.');
  }
  const nextStatus = review.action === 'VERIFY' ? 'VERIFIED' : 'REJECTED';
  const updated = await env.DB.prepare(
    `UPDATE receipts SET status = ?, challan_number = ?, po_number = ?, material_code = ?, material_description = ?, verified_quantity = ?, unit = ?, notes = ?,
       reviewed_by = ?, reviewed_at = CURRENT_TIMESTAMP, version = version + 1, updated_at = CURRENT_TIMESTAMP
     WHERE id = ? AND site_id = ? AND version = ? AND status = 'NEEDS_REVIEW'`,
  ).bind(
    nextStatus, review.challanNumber, review.poNumber.toUpperCase(), review.materialCode.toUpperCase(), review.materialDescription, review.verifiedQuantity, review.unit, review.notes,
    reviewer.email, receiptId, reviewer.siteId, review.version,
  ).run();
  if (Number(updated.meta.changes ?? 0) !== 1) {
    return error(request, env, 409, 'REVIEW_CONFLICT', 'Receipt changed or is no longer awaiting review. Refresh before retrying.');
  }
  const reviewEvent = {
    receipt_id: receiptId,
    site_id: reviewer.siteId,
    po_number: review.poNumber.toUpperCase(),
    material_code: review.materialCode.toUpperCase(),
    verified_quantity: review.verifiedQuantity,
    unit: review.unit.toUpperCase(),
    reviewer_id: reviewer.email,
    review_version: review.version + 1,
    reviewed_at_iso8601: new Date().toISOString(),
    schema_version: '1.0',
  };
  await env.DB.prepare(
    `INSERT INTO receipt_audits (id, receipt_id, site_id, event_type, actor, event_json) VALUES (?, ?, ?, ?, ?, ?)`,
  ).bind(
    crypto.randomUUID(), receiptId, reviewer.siteId, nextStatus, reviewer.email,
    JSON.stringify({ challanNumber: review.challanNumber, poNumber: review.poNumber, materialCode: review.materialCode, materialDescription: review.materialDescription, verifiedQuantity: review.verifiedQuantity, unit: review.unit, notes: review.notes }),
  ).run();
  if (nextStatus === 'VERIFIED') {
    await env.DB.prepare(
      `INSERT INTO review_projection_outbox (receipt_id, site_id, payload_json)
       VALUES (?, ?, ?) ON CONFLICT(receipt_id) DO UPDATE SET payload_json = excluded.payload_json, status = 'PENDING', available_at = CURRENT_TIMESTAMP`,
    ).bind(receiptId, reviewer.siteId, JSON.stringify(reviewEvent)).run();
  }
  if (nextStatus === 'VERIFIED' && env.ENRICHMENT_URL) {
    try {
      const response = await callEnrichment(env, '/v1/events/reviews', reviewEvent);
      if (!response.ok) throw new Error(`review_projection_${response.status}`);
      await env.DB.prepare(`UPDATE review_projection_outbox SET status = 'DELIVERED', attempts = attempts + 1, delivered_at = CURRENT_TIMESTAMP WHERE receipt_id = ?`)
        .bind(receiptId).run();
    } catch {
      await env.DB.prepare(`UPDATE review_projection_outbox SET attempts = attempts + 1, available_at = datetime('now', '+1 minute') WHERE receipt_id = ?`)
        .bind(receiptId).run();
    }
  }
  return json(request, env, { receiptId, status: nextStatus, version: review.version + 1 });
}

async function importPurchaseOrders(request: Request, env: Env, reviewer: ReviewerIdentity): Promise<Response> {
  const body = await parseJson(request) as { csvContent?: unknown };
  if (typeof body.csvContent !== 'string' || body.csvContent.length < 1 || body.csvContent.length > 1_000_000) {
    return error(request, env, 400, 'INVALID_TALLY_CSV', 'A Tally CSV file below 1 MB is required.');
  }
  try {
    const response = await callEnrichment(env, '/v1/reviewer/po-imports', {
      site_id: reviewer.siteId,
      imported_by: reviewer.email,
      csv_content: body.csvContent,
    });
    const payload = await response.text();
    return new Response(payload, { status: response.status, headers: { ...corsHeaders(request, env), 'Content-Type': 'application/json' } });
  } catch {
    return error(request, env, 503, 'RECONCILIATION_UNAVAILABLE', 'Purchase-order import is temporarily unavailable.');
  }
}

async function listReconciliation(request: Request, env: Env, reviewer: ReviewerIdentity): Promise<Response> {
  try {
    const response = await callEnrichment(env, '/v1/reviewer/reconciliation/query', { site_id: reviewer.siteId });
    const raw = await response.json<{ rows?: Array<Record<string, unknown>> }>();
    if (!response.ok) return error(request, env, 503, 'RECONCILIATION_UNAVAILABLE', 'Reconciliation is temporarily unavailable.');
    const rows = (raw.rows ?? []).map((row) => ({
      poNumber: row.po_number,
      materialCode: row.material_code,
      unit: row.unit,
      poQuantity: row.po_quantity,
      siteReceived: row.site_received,
      isOver: row.is_over,
    }));
    return json(request, env, { rows });
  } catch {
    return error(request, env, 503, 'RECONCILIATION_UNAVAILABLE', 'Reconciliation is temporarily unavailable.');
  }
}

async function listDigestHistory(request: Request, env: Env, reviewer: ReviewerIdentity): Promise<Response> {
  try {
    const response = await callEnrichment(env, '/v1/reviewer/digests/query', { site_id: reviewer.siteId });
    const payload = await response.text();
    return new Response(payload, { status: response.status, headers: { ...corsHeaders(request, env), 'Content-Type': 'application/json' } });
  } catch {
    return error(request, env, 503, 'DIGEST_HISTORY_UNAVAILABLE', 'Digest history is temporarily unavailable.');
  }
}

async function listEnrichmentStatus(request: Request, env: Env, reviewer: ReviewerIdentity): Promise<Response> {
  const receiptId = new URL(request.url).searchParams.get('receiptId');
  if (receiptId && !/^[0-9a-f-]{36}$/i.test(receiptId)) return error(request, env, 400, 'INVALID_RECEIPT_ID', 'Receipt ID is invalid.');
  try {
    const response = await callEnrichment(env, '/v1/reviewer/enrichment-status/query', { site_id: reviewer.siteId, receipt_id: receiptId || null });
    const payload = await response.text();
    return new Response(payload, { status: response.status, headers: { ...corsHeaders(request, env), 'Content-Type': 'application/json' } });
  } catch {
    return error(request, env, 503, 'ENRICHMENT_STATUS_UNAVAILABLE', 'Enrichment status is temporarily unavailable.');
  }
}

async function configureSiteManager(request: Request, env: Env, reviewer: ReviewerIdentity): Promise<Response> {
  const body = await parseJson(request) as { managerId?: unknown; active?: unknown };
  const managerId = String(body.managerId ?? '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(managerId) || managerId.length > 254 || typeof body.active !== 'boolean') {
    return error(request, env, 400, 'INVALID_SITE_MANAGER', 'A valid manager email and active state are required.');
  }
  try {
    const response = await callEnrichment(env, '/v1/admin/site-managers', { site_id: reviewer.siteId, manager_id: managerId, active: body.active });
    if (!response.ok) return error(request, env, 503, 'SITE_MANAGER_UNAVAILABLE', 'Site manager configuration is temporarily unavailable.');
    return new Response(null, { status: 204, headers: corsHeaders(request, env) });
  } catch {
    return error(request, env, 503, 'SITE_MANAGER_UNAVAILABLE', 'Site manager configuration is temporarily unavailable.');
  }
}

async function createEnrollmentCode(request: Request, env: Env, reviewer: ReviewerIdentity): Promise<Response> {
  const body = await parseJson(request) as { deviceName?: string };
  const deviceName = String(body.deviceName ?? '').trim();
  if (!deviceName || deviceName.length > 80) return error(request, env, 400, 'INVALID_DEVICE_NAME', 'Device name is required.');
  const code = randomEnrollmentCode();
  const codeHash = await sha256Hex(code);
  await env.DB.prepare(
    `INSERT INTO enrollment_codes (code_hash, site_id, device_name, expires_at, created_by) VALUES (?, ?, ?, datetime('now', '+10 minutes'), ?)`,
  ).bind(codeHash, reviewer.siteId, deviceName, reviewer.email).run();
  return json(request, env, { enrollmentCode: code, expiresInSeconds: 600, deviceName }, 201);
}

async function revokeDevice(request: Request, env: Env, reviewer: ReviewerIdentity, deviceId: string): Promise<Response> {
  const result = await env.DB.prepare(`UPDATE devices SET active = 0 WHERE id = ? AND site_id = ? AND active = 1`)
    .bind(deviceId, reviewer.siteId).run();
  if (Number(result.meta.changes ?? 0) !== 1) return error(request, env, 404, 'DEVICE_NOT_FOUND', 'Active device was not found.');
  return new Response(null, { status: 204, headers: corsHeaders(request, env) });
}

async function adminSummary(request: Request, env: Env, reviewer: ReviewerIdentity): Promise<Response> {
  const [site, counts, devices] = await Promise.all([
    env.DB.prepare(
      `SELECT name, stored_image_bytes, storage_byte_limit, daily_receipt_limit FROM sites WHERE id = ?`,
    ).bind(reviewer.siteId).first<{ name: string; stored_image_bytes: number; storage_byte_limit: number; daily_receipt_limit: number }>(),
    env.DB.prepare(
      `SELECT status, COUNT(*) AS count FROM receipts WHERE site_id = ? GROUP BY status`,
    ).bind(reviewer.siteId).all<{ status: string; count: number }>(),
    env.DB.prepare(
      `SELECT id, name, app_version, active, enrolled_at, last_seen_at FROM devices WHERE site_id = ? ORDER BY enrolled_at DESC`,
    ).bind(reviewer.siteId).all<{
      id: string; name: string; app_version: string; active: number; enrolled_at: string; last_seen_at: string | null;
    }>(),
  ]);
  if (!site) return error(request, env, 404, 'SITE_NOT_FOUND', 'Site was not found.');
  return json(request, env, {
    site: {
      name: site.name,
      storedImageBytes: site.stored_image_bytes,
      storageByteLimit: site.storage_byte_limit,
      dailyReceiptLimit: site.daily_receipt_limit,
    },
    counts: Object.fromEntries(counts.results.map((row) => [row.status, row.count])),
    devices: devices.results.map((device) => ({
      id: device.id,
      name: device.name,
      appVersion: device.app_version,
      active: device.active === 1,
      enrolledAt: device.enrolled_at,
      lastSeenAt: device.last_seen_at,
    })),
  });
}

async function submitPilotRequest(request: Request, env: Env): Promise<Response> {
  if (!(await rateLimit(request, env, 'pilot-request', 5))) return error(request, env, 429, 'RATE_LIMITED', 'Too many requests. Please retry later.');
  let input;
  try {
    input = pilotRequestSchema.parse(await parseJson(request));
  } catch {
    return error(request, env, 400, 'INVALID_PILOT_REQUEST', 'Required pilot-request fields are invalid.');
  }
  if (!(await verifyTurnstile(input.turnstileToken, request, env))) {
    return error(request, env, 400, 'BOT_CHECK_FAILED', 'Verification failed. Please retry.');
  }
  await env.DB.prepare(
    `INSERT INTO pilot_requests (id, name, company, email, phone, message) VALUES (?, ?, ?, ?, ?, ?)`,
  ).bind(crypto.randomUUID(), input.name, input.company, input.email.toLowerCase(), input.phone, input.message).run();
  return json(request, env, { status: 'accepted' }, 202);
}

async function submitMobileTelemetry(request: Request, env: Env, device: DeviceIdentity): Promise<Response> {
  const payload = await parseJson(request) as { measurements?: Array<Record<string, unknown>> };
  if (!Array.isArray(payload.measurements) || payload.measurements.length < 1 || payload.measurements.length > 100) {
    return error(request, env, 400, 'INVALID_TELEMETRY', 'A bounded telemetry batch is required.');
  }
  const allowed = new Set(['frontend_write_duration_ms', 'sync_failure_rate']);
  const measurements = payload.measurements.map((measurement) => ({
    source_event_id: `${device.id}:${String(measurement.source_event_id ?? '')}`,
    site_id: device.siteId,
    vendor_id: typeof measurement.vendor_id === 'string' ? measurement.vendor_id : null,
    metric_name: measurement.metric_name,
    metric_value: measurement.metric_value,
    sample_count: measurement.sample_count,
    period_start: measurement.period_start,
    period_end: measurement.period_end,
  }));
  if (measurements.some((measurement) => !allowed.has(String(measurement.metric_name))
    || measurement.source_event_id.length < 3 || measurement.source_event_id.length > 160
    || typeof measurement.metric_value !== 'number' || measurement.metric_value < 0
    || !Number.isInteger(measurement.sample_count) || Number(measurement.sample_count) < 1
    || typeof measurement.period_start !== 'string' || typeof measurement.period_end !== 'string')) {
    return error(request, env, 400, 'INVALID_TELEMETRY', 'Telemetry values are invalid.');
  }
  try {
    const response = await callEnrichment(env, '/v1/events/telemetry', { measurements });
    if (!response.ok) return error(request, env, 503, 'TELEMETRY_UNAVAILABLE', 'Telemetry remains queued on this device.');
    return json(request, env, { accepted: measurements.length }, 202);
  } catch {
    return error(request, env, 503, 'TELEMETRY_UNAVAILABLE', 'Telemetry remains queued on this device.');
  }
}

async function handleRequest(request: Request, env: Env): Promise<Response> {
  const path = requestPath(request);
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(request, env) });
  if (request.method === 'GET' && path === '/health') return json(request, env, { status: 'ok' });
  if (request.method === 'GET' && path === '/ready') {
    const configured = Boolean(env.DEVICE_TOKEN_PEPPER && env.TURNSTILE_SECRET && env.ACCESS_TEAM_DOMAIN && env.ACCESS_AUD);
    try {
      await env.DB.prepare('SELECT 1').first();
      return json(request, env, { status: configured ? 'ready' : 'configuration_required' }, configured ? 200 : 503);
    } catch {
      return json(request, env, { status: 'database_unavailable' }, 503);
    }
  }
  if (request.method === 'POST' && path === '/v1/pilot-requests') return submitPilotRequest(request, env);
  if (request.method === 'POST' && path === '/v1/devices/enroll') return enrollDevice(request, env);
  const internalImageMatch = path.match(/^\/v1\/internal\/receipts\/([^/]+)\/image$/);
  if (request.method === 'GET' && internalImageMatch) return internalReceiptImage(request, env, internalImageMatch[1]);
  const callbackMatch = path.match(/^\/v1\/internal\/receipts\/([^/]+)\/enrichment$/);
  if (request.method === 'POST' && callbackMatch) return enrichmentCallback(request, env, callbackMatch[1]);

  if (path === '/v1/mobile/bootstrap' || path === '/v1/mobile/telemetry' || path === '/v1/receipts') {
    const device = await requireDevice(request, env);
    if (device instanceof Response) return device;
    if (request.method === 'GET' && path === '/v1/mobile/bootstrap') return mobileBootstrap(request, env, device);
    if (request.method === 'POST' && path === '/v1/mobile/telemetry') return submitMobileTelemetry(request, env, device);
    if (request.method === 'POST' && path === '/v1/receipts') return uploadReceipt(request, env, device);
  }

  if (path === '/v1/uploads' && request.method === 'POST') {
    const device = await requireDevice(request, env);
    if (device instanceof Response) return device;
    return createUploadSession(request, env, device);
  }
  const uploadMatch = path.match(/^\/v1\/uploads\/([^/]+)$/);
  if (uploadMatch && request.method === 'GET') {
    const device = await requireDevice(request, env);
    if (device instanceof Response) return device;
    return getUploadSession(request, env, device, uploadMatch[1]);
  }
  const uploadPartMatch = path.match(/^\/v1\/uploads\/([^/]+)\/parts\/(\d+)$/);
  if (uploadPartMatch && request.method === 'PUT') {
    const device = await requireDevice(request, env);
    if (device instanceof Response) return device;
    return putUploadPart(request, env, device, uploadPartMatch[1], Number(uploadPartMatch[2]));
  }
  const uploadCompleteMatch = path.match(/^\/v1\/uploads\/([^/]+)\/complete$/);
  if (uploadCompleteMatch && request.method === 'POST') {
    const device = await requireDevice(request, env);
    if (device instanceof Response) return device;
    return completeUploadSession(request, env, device, uploadCompleteMatch[1]);
  }

  if (path.startsWith('/v1/reviewer/') || path.startsWith('/v1/admin/')) {
    const reviewer = await requireReviewer(request, env, path.startsWith('/v1/admin/'));
    if (reviewer instanceof Response) return reviewer;
    if (request.method === 'GET' && path === '/v1/reviewer/receipts') return listReceipts(request, env, reviewer);
    if (request.method === 'POST' && path === '/v1/reviewer/po-imports') return importPurchaseOrders(request, env, reviewer);
    if (request.method === 'GET' && path === '/v1/reviewer/reconciliation') return listReconciliation(request, env, reviewer);
    if (request.method === 'GET' && path === '/v1/reviewer/digests') return listDigestHistory(request, env, reviewer);
    if (request.method === 'GET' && path === '/v1/reviewer/enrichment-status') return listEnrichmentStatus(request, env, reviewer);
    const imageMatch = path.match(/^\/v1\/reviewer\/receipts\/([^/]+)\/image$/);
    if (request.method === 'GET' && imageMatch) return getReceiptImage(request, env, reviewer, imageMatch[1]);
    const receiptMatch = path.match(/^\/v1\/reviewer\/receipts\/([^/]+)$/);
    if (request.method === 'PATCH' && receiptMatch) return reviewReceipt(request, env, reviewer, receiptMatch[1]);
    if (request.method === 'POST' && path === '/v1/admin/enrollment-codes') return createEnrollmentCode(request, env, reviewer);
    if (request.method === 'PUT' && path === '/v1/admin/site-manager') return configureSiteManager(request, env, reviewer);
    if (request.method === 'GET' && path === '/v1/admin/summary') return adminSummary(request, env, reviewer);
    const deviceMatch = path.match(/^\/v1\/admin\/devices\/([^/]+)$/);
    if (request.method === 'DELETE' && deviceMatch) return revokeDevice(request, env, reviewer, deviceMatch[1]);
  }
  return error(request, env, 404, 'NOT_FOUND', 'Route not found.');
}

async function consumeReceipts(batch: MessageBatch<ReceiptQueueMessage>, env: Env): Promise<void> {
  for (const message of batch.messages) {
    const { receiptId, siteId } = message.body;
    try {
      const receipt = await env.DB.prepare(
        `SELECT image_key, image_sha256, image_bytes, enrichment_status, vendor_id, captured_at_unix, captured_quantity
         FROM receipts WHERE id = ? AND site_id = ? LIMIT 1`,
      ).bind(receiptId, siteId).first<{
        image_key: string; image_sha256: string; image_bytes: number; enrichment_status: string; vendor_id: string; captured_at_unix: number; captured_quantity: number;
      }>();
      if (!receipt || !(await env.RECEIPTS.head(receipt.image_key))) throw new Error('durable_image_missing');
      const result = await env.DB.prepare(
        `UPDATE receipts SET status = 'NEEDS_REVIEW', version = version + 1, updated_at = CURRENT_TIMESTAMP
         WHERE id = ? AND site_id = ? AND status = 'RECEIVED'`,
      ).bind(receiptId, siteId).run();
      if (Number(result.meta.changes ?? 0) === 1) {
        await env.DB.prepare(
          `INSERT INTO receipt_audits (id, receipt_id, site_id, event_type, actor, event_json) VALUES (?, ?, ?, 'NEEDS_REVIEW', 'queue', '{}')`,
        ).bind(crypto.randomUUID(), receiptId, siteId).run();
      }
      if (receipt.enrichment_status === 'PENDING') {
        const enrichmentStatus = await dispatchEnrichment(env, {
          id: receiptId,
          siteId,
          imageKey: receipt.image_key,
          imageSha256: receipt.image_sha256,
          imageBytes: receipt.image_bytes,
          vendorId: receipt.vendor_id,
          capturedAtUnix: receipt.captured_at_unix,
          capturedQuantity: receipt.captured_quantity,
        });
        await env.DB.prepare(
          `UPDATE receipts SET enrichment_status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND enrichment_status = 'PENDING'`,
        ).bind(enrichmentStatus, receiptId).run();
      }
      message.ack();
    } catch {
      message.retry();
    }
  }
}

async function reconcileAndRetain(env: Env): Promise<void> {
  const recovered = await env.DB.prepare(
    `UPDATE receipts SET status = 'NEEDS_REVIEW', version = version + 1, updated_at = CURRENT_TIMESTAMP
     WHERE status = 'RECEIVED' AND created_at < datetime('now', '-5 minutes') RETURNING id, site_id, image_key`,
  ).all<{ id: string; site_id: string; image_key: string }>();
  for (const receipt of recovered.results) {
    await env.DB.prepare(
      `INSERT INTO receipt_audits (id, receipt_id, site_id, event_type, actor, event_json)
       VALUES (?, ?, ?, 'NEEDS_REVIEW', 'reconciliation', '{}')`,
    ).bind(crypto.randomUUID(), receipt.id, receipt.site_id).run();
  }

  const pendingEnrichment = await env.DB.prepare(
    `SELECT id, site_id, image_key, image_sha256, image_bytes, vendor_id, captured_at_unix, captured_quantity FROM receipts
     WHERE enrichment_status = 'PENDING' AND image_deleted_at IS NULL ORDER BY created_at LIMIT 50`,
  ).all<{ id: string; site_id: string; image_key: string; image_sha256: string; image_bytes: number; vendor_id: string; captured_at_unix: number; captured_quantity: number }>();
  for (const receipt of pendingEnrichment.results) {
    try {
      const enrichmentStatus = await dispatchEnrichment(env, {
        id: receipt.id,
        siteId: receipt.site_id,
        imageKey: receipt.image_key,
        imageSha256: receipt.image_sha256,
        imageBytes: receipt.image_bytes,
        vendorId: receipt.vendor_id,
        capturedAtUnix: receipt.captured_at_unix,
        capturedQuantity: receipt.captured_quantity,
      });
      await env.DB.prepare(
        `UPDATE receipts SET enrichment_status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND enrichment_status = 'PENDING'`,
      ).bind(enrichmentStatus, receipt.id).run();
    } catch {
      await env.DB.prepare(
        `INSERT INTO operations_log (id, site_id, event_type, detail_json) VALUES (?, ?, 'ENRICHMENT_RETRY_FAILED', ?)`,
      ).bind(crypto.randomUUID(), receipt.site_id, JSON.stringify({ receiptId: receipt.id })).run();
    }
  }

  const expiredUploadParts = await env.DB.prepare(
    `SELECT upload_parts.upload_id, upload_parts.object_key FROM upload_parts
     JOIN upload_sessions ON upload_sessions.id = upload_parts.upload_id
     WHERE upload_sessions.status = 'OPEN' AND upload_sessions.expires_at < CURRENT_TIMESTAMP LIMIT 200`,
  ).all<{ upload_id: string; object_key: string }>();
  for (const part of expiredUploadParts.results) await env.RECEIPTS.delete(part.object_key);
  await env.DB.batch([
    env.DB.prepare(`DELETE FROM request_nonces WHERE expires_at < CURRENT_TIMESTAMP`),
    env.DB.prepare(`DELETE FROM service_request_nonces WHERE expires_at < CURRENT_TIMESTAMP`),
    env.DB.prepare(`DELETE FROM request_limits WHERE expires_at < CURRENT_TIMESTAMP`),
    env.DB.prepare(`DELETE FROM upload_parts WHERE upload_id IN (SELECT id FROM upload_sessions WHERE status = 'OPEN' AND expires_at < CURRENT_TIMESTAMP)`),
    env.DB.prepare(`UPDATE upload_sessions SET status = 'ABORTED', updated_at = CURRENT_TIMESTAMP WHERE status = 'OPEN' AND expires_at < CURRENT_TIMESTAMP`),
  ]);

  const reviewProjections = await env.DB.prepare(
    `SELECT receipt_id, payload_json FROM review_projection_outbox
     WHERE status = 'PENDING' AND available_at <= CURRENT_TIMESTAMP ORDER BY created_at LIMIT 25`,
  ).all<{ receipt_id: string; payload_json: string }>();
  for (const projection of reviewProjections.results) {
    try {
      const response = await callEnrichment(env, '/v1/events/reviews', JSON.parse(projection.payload_json));
      if (!response.ok) throw new Error(`review_projection_${response.status}`);
      await env.DB.prepare(`UPDATE review_projection_outbox SET status = 'DELIVERED', attempts = attempts + 1, delivered_at = CURRENT_TIMESTAMP WHERE receipt_id = ?`)
        .bind(projection.receipt_id).run();
    } catch {
      await env.DB.prepare(`UPDATE review_projection_outbox SET attempts = attempts + 1, available_at = datetime('now', '+' || MIN(60, 1 << MIN(attempts, 6)) || ' minutes') WHERE receipt_id = ?`)
        .bind(projection.receipt_id).run();
    }
  }

  const expiredImages = await env.DB.prepare(
    `SELECT id, site_id, image_key, image_bytes FROM receipts
     WHERE image_deleted_at IS NULL AND created_at < datetime('now', '-${IMAGE_RETENTION_DAYS} days') LIMIT 100`,
  ).all<{ id: string; site_id: string; image_key: string; image_bytes: number }>();
  for (const receipt of expiredImages.results) {
    const tombstoneId = crypto.randomUUID();
    await env.DB.prepare(
      `INSERT INTO retention_tombstones (id, receipt_id, resource_type) VALUES (?, ?, 'R2_IMAGE')
       ON CONFLICT(receipt_id, resource_type) DO UPDATE SET status = 'PENDING'`,
    ).bind(tombstoneId, receipt.id).run();
    try {
      await env.RECEIPTS.delete(receipt.image_key);
      await env.DB.batch([
        env.DB.prepare(`UPDATE receipts SET image_deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = ?`).bind(receipt.id),
        env.DB.prepare(`UPDATE sites SET stored_image_bytes = MAX(0, stored_image_bytes - ?) WHERE id = ?`).bind(receipt.image_bytes, receipt.site_id),
        env.DB.prepare(`UPDATE retention_tombstones SET status = 'COMPLETED', completed_at = CURRENT_TIMESTAMP WHERE receipt_id = ? AND resource_type = 'R2_IMAGE'`).bind(receipt.id),
      ]);
    } catch {
      await env.DB.prepare(`UPDATE retention_tombstones SET status = 'FAILED_RETRYABLE' WHERE receipt_id = ? AND resource_type = 'R2_IMAGE'`)
        .bind(receipt.id).run();
    }
  }
  await env.DB.prepare(`DELETE FROM review_projection_outbox WHERE receipt_id IN (SELECT id FROM receipts WHERE created_at < datetime('now', '-${AUDIT_RETENTION_DAYS} days'))`).run();
  await env.DB.prepare(`DELETE FROM receipts WHERE created_at < datetime('now', '-${AUDIT_RETENTION_DAYS} days')`).run();
  await env.DB.prepare(`DELETE FROM operations_log WHERE created_at < datetime('now', '-${AUDIT_RETENTION_DAYS} days')`).run();
}

export const testable = { consumeReceipts, reconcileAndRetain };

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handleRequest(request, env);
    } catch {
      return error(request, env, 500, 'INTERNAL_ERROR', 'Request could not be completed.');
    }
  },
  async queue(batch: MessageBatch<ReceiptQueueMessage>, env: Env): Promise<void> {
    await consumeReceipts(batch, env);
  },
  async scheduled(_event: ScheduledController, env: Env): Promise<void> {
    await reconcileAndRetain(env);
  },
} satisfies ExportedHandler<Env, ReceiptQueueMessage>;
