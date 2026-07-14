import * as Keychain from 'react-native-keychain';

const SERVICE_NAME = 'com.constrovet.challanse.db-key';

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('');
}

function generateDatabaseKey(): string {
  const bytes = new Uint8Array(32);
  const cryptoApi = globalThis as typeof globalThis & {
    crypto?: {
      getRandomValues: (values: Uint8Array) => Uint8Array;
    };
  };
  const generator = cryptoApi.crypto?.getRandomValues;

  if (!generator) {
    throw new Error('Secure randomness is unavailable.');
  }

  generator(bytes);
  return bytesToHex(bytes);
}

export async function getOrCreateDatabaseKey(): Promise<string> {
  const existing = await Keychain.getGenericPassword({ service: SERVICE_NAME });

  if (existing) {
    return existing.password;
  }

  const password = generateDatabaseKey();
  await Keychain.setGenericPassword('receipt-ingestion', password, {
    service: SERVICE_NAME,
    accessible: Keychain.ACCESSIBLE.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
  });

  return password;
}
