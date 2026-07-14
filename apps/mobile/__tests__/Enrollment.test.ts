import { parseEnrollmentLink } from '../src/config/deviceEnrollment';

describe('device enrollment links', () => {
  it('accepts a branded HTTPS API and one-time code', () => {
    expect(parseEnrollmentLink('challanse://enroll?api=https%3A%2F%2Fapi.challanse.constrovet.com&code=ABCDEFGH')).toEqual({
      apiBaseUrl: 'https://api.challanse.constrovet.com',
      enrollmentCode: 'ABCDEFGH',
    });
  });

  it('rejects insecure and malformed enrollment links', () => {
    expect(parseEnrollmentLink('challanse://enroll?api=http%3A%2F%2Flocalhost&code=ABCDEFGH')).toBeNull();
    expect(parseEnrollmentLink('https://example.com')).toBeNull();
  });
});
