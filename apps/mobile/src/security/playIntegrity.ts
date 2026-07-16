import { NativeModules, Platform } from 'react-native';

type PlayIntegrityNativeModule = {
  warmUp(): Promise<boolean>;
  requestToken(requestHash: string): Promise<string>;
};

const module = NativeModules.ChallanSePlayIntegrity as PlayIntegrityNativeModule | undefined;

export async function warmPlayIntegrity(): Promise<void> {
  if (Platform.OS === 'android' && module) await module.warmUp().catch(() => false);
}

export async function playIntegrityToken(requestHash: string): Promise<string | undefined> {
  if (Platform.OS !== 'android' || !module) return undefined;
  try {
    const token = await module.requestToken(requestHash);
    return token || undefined;
  } catch {
    return undefined;
  }
}
