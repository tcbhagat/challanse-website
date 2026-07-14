import { describe, expect, it, vi } from 'vitest';

import { authenticateReviewer } from './security';
import type { Env } from './types';

describe('reviewer Access authentication', () => {
  it('rejects forged Access assertions before database authorization', async () => {
    const verifyToken = vi.fn(async () => { throw new Error('invalid signature'); });
    const first = vi.fn();
    const env = {
      ACCESS_TEAM_DOMAIN: 'constrovet.cloudflareaccess.com',
      ACCESS_AUD: 'reviewer-audience',
      DB: { prepare: vi.fn(() => ({ bind: vi.fn(() => ({ first })) })) },
    } as unknown as Env;
    const request = new Request('https://api.challanse.constrovet.com/v1/reviewer/receipts', {
      headers: { 'Cf-Access-Jwt-Assertion': 'forged.jwt.value' },
    });
    expect(await authenticateReviewer(request, env, verifyToken)).toBeNull();
    expect(first).not.toHaveBeenCalled();
  });
});
