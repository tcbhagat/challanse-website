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

  const used = await env.DB.prepare(
    `UPDATE enrollment_codes SET used_at = CURRENT_TIMESTAMP WHERE code_hash = ? AND used_at IS NULL AND expires_at > CURRENT_TIMESTAMP`,
  ).bind(codeHash).run();
  if (Number(used.meta.changes ?? 0) !== 1) return error(request, env, 409, 'ENROLLMENT_USED', 'Enrollment code has already been used.');

  const activeDevices = await env.DB.prepare(`SELECT COUNT(*) AS count FROM devices WHERE site_id = ? AND active = 1`)
    .bind(enrollment.site_id).first<{ count: number }>();
  if (Number(activeDevices?.count ?? 0) >= 5) return error(request, env, 409, 'DEVICE_LIMIT', 'The five-device pilot limit has been reached.');

  const deviceId = crypto.randomUUID();
  const token = randomToken();
  const tokenHash = await sha256Hex(`${token}:${env.DEVICE_TOKEN_PEPPER}`);
  await env.DB.prepare(
    `INSERT INTO devices (id, site_id, name, token_hash, app_version) VALUES (?, ?, ?, ?, ?)`,
  ).bind(deviceId, enrollment.site_id, input.deviceName || enrollment.device_name, tokenHash, input.appVersion).run();
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
            r.challan_number, r.material_description, r.verified_quantity, r.unit, r.notes, r.created_at
       FROM receipts r JOIN vendors v ON v.id = r.vendor_id
      WHERE r.site_id = ? AND r.status = ? AND r.created_at < ?
      ORDER BY r.created_at DESC LIMIT ?`,
  ).bind(reviewer.siteId, status, cursor, limit + 1).all<{
    id: string; vendor_id: string; vendor_name: string; captured_at_unix: number; captured_quantity: number;
    status: ReceiptListItem['status']; version: number; challan_number: string; material_description: string;
    verified_quantity: number | null; unit: string; notes: string; created_at: string;
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
    materialDescription: row.material_description,
    verifiedQuantity: row.verified_quantity,
    unit: row.unit,
    notes: row.notes,
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
    `UPDATE receipts SET status = ?, challan_number = ?, material_description = ?, verified_quantity = ?, unit = ?, notes = ?,
       reviewed_by = ?, reviewed_at = CURRENT_TIMESTAMP, version = version + 1, updated_at = CURRENT_TIMESTAMP
     WHERE id = ? AND site_id = ? AND version = ? AND status = 'NEEDS_REVIEW'`,
  ).bind(
    nextStatus, review.challanNumber, review.materialDescription, review.verifiedQuantity, review.unit, review.notes,
    reviewer.email, receiptId, reviewer.siteId, review.version,
  ).run();
  if (Number(updated.meta.changes ?? 0) !== 1) {
    return error(request, env, 409, 'REVIEW_CONFLICT', 'Receipt changed or is no longer awaiting review. Refresh before retrying.');
  }
  await env.DB.prepare(
    `INSERT INTO receipt_audits (id, receipt_id, site_id, event_type, actor, event_json) VALUES (?, ?, ?, ?, ?, ?)`,
  ).bind(
    crypto.randomUUID(), receiptId, reviewer.siteId, nextStatus, reviewer.email,
    JSON.stringify({ challanNumber: review.challanNumber, materialDescription: review.materialDescription, verifiedQuantity: review.verifiedQuantity, unit: review.unit, notes: review.notes }),
  ).run();
  return json(request, env, { receiptId, status: nextStatus, version: review.version + 1 });
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

  if (path === '/v1/mobile/bootstrap' || path === '/v1/receipts') {
    const device = await requireDevice(request, env);
    if (device instanceof Response) return device;
    if (request.method === 'GET' && path === '/v1/mobile/bootstrap') return mobileBootstrap(request, env, device);
    if (request.method === 'POST' && path === '/v1/receipts') return uploadReceipt(request, env, device);
  }

  if (path.startsWith('/v1/reviewer/') || path.startsWith('/v1/admin/')) {
    const reviewer = await requireReviewer(request, env, path.startsWith('/v1/admin/'));
    if (reviewer instanceof Response) return reviewer;
    if (request.method === 'GET' && path === '/v1/reviewer/receipts') return listReceipts(request, env, reviewer);
    const imageMatch = path.match(/^\/v1\/reviewer\/receipts\/([^/]+)\/image$/);
    if (request.method === 'GET' && imageMatch) return getReceiptImage(request, env, reviewer, imageMatch[1]);
    const receiptMatch = path.match(/^\/v1\/reviewer\/receipts\/([^/]+)$/);
    if (request.method === 'PATCH' && receiptMatch) return reviewReceipt(request, env, reviewer, receiptMatch[1]);
    if (request.method === 'POST' && path === '/v1/admin/enrollment-codes') return createEnrollmentCode(request, env, reviewer);
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
      const receipt = await env.DB.prepare(`SELECT image_key FROM receipts WHERE id = ? AND site_id = ? LIMIT 1`)
        .bind(receiptId, siteId).first<{ image_key: string }>();
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
      message.ack();
    } catch {
      message.retry();
    }
  }
}

async function reconcileAndRetain(env: Env): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE receipts SET status = 'NEEDS_REVIEW', version = version + 1, updated_at = CURRENT_TIMESTAMP
       WHERE status = 'RECEIVED' AND created_at < datetime('now', '-5 minutes')`,
    ),
    env.DB.prepare(`DELETE FROM request_nonces WHERE expires_at < CURRENT_TIMESTAMP`),
    env.DB.prepare(`DELETE FROM request_limits WHERE expires_at < CURRENT_TIMESTAMP`),
  ]);

  const expiredImages = await env.DB.prepare(
    `SELECT id, site_id, image_key, image_bytes FROM receipts
     WHERE image_deleted_at IS NULL AND created_at < datetime('now', '-${IMAGE_RETENTION_DAYS} days') LIMIT 100`,
  ).all<{ id: string; site_id: string; image_key: string; image_bytes: number }>();
  for (const receipt of expiredImages.results) {
    await env.RECEIPTS.delete(receipt.image_key);
    await env.DB.batch([
      env.DB.prepare(`UPDATE receipts SET image_deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = ?`).bind(receipt.id),
      env.DB.prepare(`UPDATE sites SET stored_image_bytes = MAX(0, stored_image_bytes - ?) WHERE id = ?`).bind(receipt.image_bytes, receipt.site_id),
    ]);
  }
  await env.DB.prepare(`DELETE FROM receipts WHERE created_at < datetime('now', '-${AUDIT_RETENTION_DAYS} days')`).run();
  await env.DB.prepare(`DELETE FROM operations_log WHERE created_at < datetime('now', '-${AUDIT_RETENTION_DAYS} days')`).run();
}

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
