import { error, json } from './responses';
import { proxyAuthoritativeRequest } from './enrichment';
import { authenticateAccessIdentity, corsHeaders } from './security';
import type { Env } from './types';

function requestPath(request: Request): string {
  return new URL(request.url).pathname.replace(/\/$/, '') || '/';
}

async function verifyTurnstile(token: string, request: Request, env: Env): Promise<boolean> {
  if (!env.TURNSTILE_SECRET) return env.ENVIRONMENT !== 'production';
  const body = new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: token });
  const remoteIp = request.headers.get('CF-Connecting-IP');
  if (remoteIp) body.set('remoteip', remoteIp);
  const response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
    method: 'POST',
    body,
  });
  if (!response.ok) return false;
  return (await response.json<{ success?: boolean }>()).success === true;
}

function isAuthoritativeRoute(path: string): boolean {
  return path === '/v1/devices/enroll'
    || path === '/v1/mobile/bootstrap'
    || path === '/v1/mobile/telemetry'
    || path === '/v1/uploads'
    || /^\/v1\/uploads\/[^/]+(?:\/parts\/\d+|\/complete)?$/.test(path);
}

async function handleRequest(request: Request, env: Env): Promise<Response> {
  const path = requestPath(request);
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders(request, env) });
  }
  if (request.method === 'GET' && path === '/health') {
    return json(request, env, { status: 'ok', mode: 'aws-authoritative' });
  }
  if (request.method === 'GET' && path === '/ready') return proxyAuthoritativeRequest(request, env);

  if (path.startsWith('/v1/reviewer/') || path.startsWith('/v1/admin/')) {
    const identity = await authenticateAccessIdentity(request, env);
    if (!identity) return error(request, env, 401, 'REVIEWER_UNAUTHORIZED', 'Reviewer authentication is required.');
    return proxyAuthoritativeRequest(request, env, identity);
  }

  if (request.method === 'POST' && path === '/v1/pilot-requests') {
    let payload: { turnstileToken?: unknown; website?: unknown };
    try {
      payload = await request.clone().json();
    } catch {
      return error(request, env, 400, 'INVALID_PILOT_REQUEST', 'Required pilot-request fields are invalid.');
    }
    if (typeof payload.website === 'string' && payload.website) return json(request, env, { status: 'received' }, 201);
    if (typeof payload.turnstileToken !== 'string' || !(await verifyTurnstile(payload.turnstileToken, request, env))) {
      return error(request, env, 400, 'TURNSTILE_FAILED', 'Please retry the verification challenge.');
    }
    return proxyAuthoritativeRequest(request, env, undefined, true);
  }

  if (isAuthoritativeRoute(path)) return proxyAuthoritativeRequest(request, env);
  return error(request, env, 404, 'NOT_FOUND', 'The requested route does not exist.');
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handleRequest(request, env);
    } catch {
      return error(request, env, 502, 'UPSTREAM_FAILURE', 'The production data service could not complete the request.');
    }
  },
} satisfies ExportedHandler<Env>;
