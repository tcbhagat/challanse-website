import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { AccessIdentity, Env } from './types';

const encoder = new TextEncoder();

export function allowedOrigins(env: Env): Set<string> {
  return new Set(env.ALLOWED_ORIGINS.split(',').map((origin) => origin.trim()).filter(Boolean));
}

export function corsHeaders(request: Request, env: Env): HeadersInit {
  const origin = request.headers.get('Origin') ?? '';
  if (!allowedOrigins(env).has(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-Part-Sha256, X-ChallanSe-Nonce, X-ChallanSe-Device-Timestamp, X-ChallanSe-Site-Id, X-ChallanSe-Play-Integrity',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
}

export async function sha256Hex(value: string | ArrayBuffer): Promise<string> {
  const source = typeof value === 'string' ? encoder.encode(value) : value;
  const digest = await crypto.subtle.digest('SHA-256', source);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function randomEnrollmentCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}

export async function authenticateAccessIdentity(
  request: Request,
  env: Env,
  verifyToken: typeof jwtVerify = jwtVerify,
): Promise<AccessIdentity | null> {
  const token = request.headers.get('Cf-Access-Jwt-Assertion') ?? '';
  const domain = env.ACCESS_TEAM_DOMAIN.trim().replace(/^https?:\/\//, '').replace(/\/$/, '');
  if (!token || !domain || !env.ACCESS_AUD) return null;
  try {
    const expectedIssuer = `https://${domain}`;
    const jwks = createRemoteJWKSet(new URL(`${expectedIssuer}/cdn-cgi/access/certs`));
    const verified = await verifyToken(token, jwks, { issuer: expectedIssuer, audience: env.ACCESS_AUD });
    const issuer = String(verified.payload.iss ?? '');
    const subject = String(verified.payload.sub ?? '');
    const email = String(verified.payload.email ?? '').trim().toLowerCase();
    return issuer && subject && email ? { issuer, subject, email } : null;
  } catch {
    return null;
  }
}
