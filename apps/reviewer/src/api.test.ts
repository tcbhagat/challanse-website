import { describe, expect, it } from 'vitest';
import { API_BASE_URL, PUBLIC_API_URL } from './api';

describe('reviewer API configuration', () => {
  it('uses the same-origin reviewer proxy and an absolute enrollment API URL', () => {
    expect(API_BASE_URL).toBe('/api');
    expect(new URL(PUBLIC_API_URL).protocol).toBe('https:');
  });
});
