import { describe, expect, it } from 'vitest';
import { API_BASE_URL } from './api';

describe('reviewer API configuration', () => {
  it('always uses an absolute API base URL', () => {
    expect(() => new URL(API_BASE_URL)).not.toThrow();
  });
});
