import * as Keychain from 'react-native-keychain';
import DeviceInfo from 'react-native-device-info';

export type PilotVendor = {
  id: string;
  name: string;
  initials: string;
  color: string;
};

export type PilotConfiguration = {
  apiBaseUrl: string;
  deviceId: string;
  deviceToken: string;
  site: { id: string; name: string };
  device: { id: string; name: string };
  vendors: PilotVendor[];
  allowedWifiSsids: string[];
  configurationVersion: number;
  limits: { dailyReceipts: number; imageBytes: number };
};

type EnrollmentCredential = {
  apiBaseUrl: string;
  deviceId: string;
  deviceToken: string;
};

const CREDENTIAL_SERVICE = 'com.constrovet.challanse.device';
const CONFIGURATION_SERVICE = 'com.constrovet.challanse.configuration';

async function storeJson(service: string, value: unknown): Promise<void> {
  await Keychain.setGenericPassword('challanse', JSON.stringify(value), {
    service,
    accessible: Keychain.ACCESSIBLE.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
  });
}

async function readJson<T>(service: string): Promise<T | null> {
  const stored = await Keychain.getGenericPassword({ service });
  if (!stored) return null;
  try {
    return JSON.parse(stored.password) as T;
  } catch {
    await Keychain.resetGenericPassword({ service });
    return null;
  }
}

export function parseEnrollmentLink(url: string): { apiBaseUrl: string; enrollmentCode: string } | null {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'challanse:' || parsed.hostname !== 'enroll') return null;
    const apiBaseUrl = parsed.searchParams.get('api')?.replace(/\/$/, '') ?? '';
    const enrollmentCode = parsed.searchParams.get('code')?.toUpperCase() ?? '';
    if (!apiBaseUrl.startsWith('https://') || !/^[A-HJ-NP-Z2-9]{8}$/.test(enrollmentCode)) return null;
    return { apiBaseUrl, enrollmentCode };
  } catch {
    return null;
  }
}

export async function exchangeEnrollmentCode(input: {
  apiBaseUrl: string;
  enrollmentCode: string;
  deviceName?: string;
}): Promise<EnrollmentCredential> {
  const response = await fetch(`${input.apiBaseUrl}/v1/devices/enroll`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({
      enrollmentCode: input.enrollmentCode,
      deviceName: input.deviceName || `${DeviceInfo.getBrand()} ${DeviceInfo.getModel()}`,
      appVersion: DeviceInfo.getVersion(),
    }),
  });
  if (!response.ok) throw new Error(response.status === 410 ? 'This QR code has expired. Ask the controller for a new code.' : 'Device enrollment failed.');
  const result = await response.json() as { deviceId: string; deviceToken: string };
  const credential = { apiBaseUrl: input.apiBaseUrl, deviceId: result.deviceId, deviceToken: result.deviceToken };
  await storeJson(CREDENTIAL_SERVICE, credential);
  return credential;
}

export async function getEnrollmentCredential(): Promise<EnrollmentCredential | null> {
  return readJson<EnrollmentCredential>(CREDENTIAL_SERVICE);
}

export async function fetchPilotConfiguration(credential: EnrollmentCredential): Promise<PilotConfiguration> {
  const response = await fetch(`${credential.apiBaseUrl}/v1/mobile/bootstrap`, {
    headers: { Authorization: `Bearer ${credential.deviceToken}`, Accept: 'application/json' },
  });
  if (!response.ok) throw new Error(response.status === 401 ? 'This device has been revoked.' : 'Site setup is temporarily unavailable.');
  const bootstrap = await response.json() as Omit<PilotConfiguration, 'apiBaseUrl' | 'deviceId' | 'deviceToken'>;
  if (!bootstrap.vendors.length) throw new Error('No active vendors are configured for this site.');
  const configuration = { ...bootstrap, ...credential };
  await storeJson(CONFIGURATION_SERVICE, configuration);
  return configuration;
}

export async function getCachedPilotConfiguration(): Promise<PilotConfiguration | null> {
  return readJson<PilotConfiguration>(CONFIGURATION_SERVICE);
}

export async function clearEnrollment(): Promise<void> {
  await Promise.all([
    Keychain.resetGenericPassword({ service: CREDENTIAL_SERVICE }),
    Keychain.resetGenericPassword({ service: CONFIGURATION_SERVICE }),
  ]);
}
