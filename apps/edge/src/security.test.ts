import { describe, expect, it } from 'vitest';
import { allowedOrigins, randomEnrollmentCode, sha256Hex } from './security';
import type { Env } from './types';

describe('edge security primitives', () => {
  it('accepts only configured exact origins', () => {
    const env = { ALLOWED_ORIGINS: 'https://challanse.constrovet.com,https://review.challanse.constrovet.com' } as Env;
    const origins = allowedOrigins(env);
    expect(origins.has('https://review.challanse.constrovet.com')).toBe(true);
    expect(origins.has('https://evil.constrovet.com')).toBe(false);
  });

  it('creates human-safe one-time codes and deterministic hashes', async () => {
    expect(randomEnrollmentCode()).toMatch(/^[A-HJ-NP-Z2-9]{8}$/);
    expect(await sha256Hex('test')).toBe('9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08');
  });
});
