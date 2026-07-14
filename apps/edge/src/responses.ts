import type { Env } from './types';
import { corsHeaders } from './security';

export function json(request: Request, env: Env, body: unknown, status = 200, extra: HeadersInit = {}): Response {
  return Response.json(body, {
    status,
    headers: {
      ...corsHeaders(request, env),
      ...extra,
      'Cache-Control': 'no-store',
      'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

export function error(request: Request, env: Env, status: number, code: string, message: string): Response {
  return json(request, env, { error: { code, message } }, status);
}
