import { describe, expect, it, vi } from 'vitest';

import { authenticateAccessIdentity } from './security';
import type { Env } from './types';

describe('reviewer Access authentication', () => {
  it('rejects forged Access assertions without forwarding identity', async () => {
    const verifyToken = vi.fn(async () => { throw new Error('invalid signature'); });
    const env = {
      ACCESS_TEAM_DOMAIN: 'constrovet.cloudflareaccess.com',
      ACCESS_AUD: 'reviewer-audience',
    } as unknown as Env;
    const request = new Request('https://api.challanse.constrovet.com/v1/reviewer/receipts', {
      headers: { 'Cf-Access-Jwt-Assertion': 'forged.jwt.value' },
    });
    expect(await authenticateAccessIdentity(request, env, verifyToken)).toBeNull();
  });
});
