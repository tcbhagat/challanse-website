import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { DeviceIdentity, Env, ReviewerIdentity } from './types';

const encoder = new TextEncoder();

export function allowedOrigins(env: Env): Set<string> {
  return new Set(env.ALLOWED_ORIGINS.split(',').map((origin) => origin.trim()).filter(Boolean));
}

export function corsHeaders(request: Request, env: Env): HeadersInit {
  const origin = request.headers.get('Origin') ?? '';
  if (!allowedOrigins(env).has(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-ChallanSe-Nonce, X-ChallanSe-Timestamp',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
}

export async function sha256Hex(value: string | ArrayBuffer): Promise<string> {
  const source = typeof value === 'string' ? encoder.encode(value) : value;
  const digest = await crypto.subtle.digest('SHA-256', source);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function randomToken(byteLength = 32): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

export function randomEnrollmentCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}

function bearerToken(request: Request): string {
  const authorization = request.headers.get('Authorization') ?? '';
  return authorization.startsWith('Bearer ') ? authorization.slice(7).trim() : '';
}

export async function authenticateDevice(request: Request, env: Env): Promise<DeviceIdentity | null> {
  const token = bearerToken(request);
  if (!token) return null;
  const tokenHash = await sha256Hex(`${token}:${env.DEVICE_TOKEN_PEPPER}`);
  const row = await env.DB.prepare(
    `SELECT id, site_id, name FROM devices WHERE token_hash = ? AND active = 1 LIMIT 1`,
  ).bind(tokenHash).first<{ id: string; site_id: string; name: string }>();
  if (!row) return null;
  await env.DB.prepare(`UPDATE devices SET last_seen_at = CURRENT_TIMESTAMP WHERE id = ?`).bind(row.id).run();
  return { id: row.id, siteId: row.site_id, name: row.name };
}

export async function consumeReplayNonce(request: Request, env: Env, deviceId: string): Promise<boolean> {
  const nonce = request.headers.get('X-ChallanSe-Nonce') ?? '';
  const timestamp = Number(request.headers.get('X-ChallanSe-Timestamp') ?? 0);
  const now = Math.floor(Date.now() / 1000);
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(nonce) || !Number.isInteger(timestamp) || Math.abs(now - timestamp) > 300) {
    return false;
  }
  const nonceHash = await sha256Hex(`${deviceId}:${nonce}`);
  const result = await env.DB.prepare(
    `INSERT OR IGNORE INTO request_nonces (nonce_hash, device_id, expires_at) VALUES (?, ?, datetime('now', '+10 minutes'))`,
  ).bind(nonceHash, deviceId).run();
  return Number(result.meta.changes ?? 0) === 1;
}

export async function authenticateReviewer(request: Request, env: Env): Promise<ReviewerIdentity | null> {
  const token = request.headers.get('Cf-Access-Jwt-Assertion') ?? '';
  const domain = env.ACCESS_TEAM_DOMAIN.trim().replace(/^https?:\/\//, '').replace(/\/$/, '');
  if (!token || !domain || !env.ACCESS_AUD) return null;
  try {
    const issuer = `https://${domain}`;
    const jwks = createRemoteJWKSet(new URL(`${issuer}/cdn-cgi/access/certs`));
    const verified = await jwtVerify(token, jwks, { issuer, audience: env.ACCESS_AUD });
    const email = String(verified.payload.email ?? '').trim().toLowerCase();
    if (!email) return null;
    const row = await env.DB.prepare(
      `SELECT email, site_id, role FROM reviewers WHERE email = ? AND active = 1 LIMIT 1`,
    ).bind(email).first<{ email: string; site_id: string; role: 'ADMIN' | 'CONTROLLER' }>();
    return row ? { email: row.email, siteId: row.site_id, role: row.role } : null;
  } catch {
    return null;
  }
}

export function isWebp(bytes: Uint8Array): boolean {
  if (bytes.byteLength < 12) return false;
  return String.fromCharCode(...bytes.slice(0, 4)) === 'RIFF' && String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP';
}
