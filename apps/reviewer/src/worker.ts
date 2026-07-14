export interface ReviewerWorkerEnv {
  API_ORIGIN: string;
  ASSETS: { fetch(request: Request): Promise<Response> };
}

const allowedProxyPath = /^\/api\/v1\/(reviewer|admin)(\/|$)/;

export async function handleReviewerRequest(request: Request, env: ReviewerWorkerEnv): Promise<Response> {
  const sourceUrl = new URL(request.url);
  if (!sourceUrl.pathname.startsWith('/api/')) return env.ASSETS.fetch(request);
  if (!allowedProxyPath.test(sourceUrl.pathname)) {
    return Response.json({ error: { code: 'NOT_FOUND', message: 'Reviewer route not found.' } }, { status: 404 });
  }
  const assertion = request.headers.get('Cf-Access-Jwt-Assertion');
  if (!assertion) {
    return Response.json({ error: { code: 'ACCESS_REQUIRED', message: 'Reviewer authentication is required.' } }, { status: 401 });
  }
  const targetUrl = new URL(sourceUrl.pathname.slice(4) + sourceUrl.search, env.API_ORIGIN);
  const headers = new Headers(request.headers);
  headers.delete('Cookie');
  headers.delete('Host');
  headers.set('Cf-Access-Jwt-Assertion', assertion);
  return fetch(new Request(targetUrl, {
    method: request.method,
    headers,
    body: request.method === 'GET' || request.method === 'HEAD' ? undefined : request.body,
    redirect: 'manual',
  }));
}

export default { fetch: handleReviewerRequest };
