import { NativeModules, Platform } from 'react-native';
import { Buffer } from 'buffer';

type ReceiptWebpCompressorNativeModule = {
  compressBase64ToWebp(base64: string, quality: number, maxBytes: number): Promise<string>;
};

type CompressedReceiptImage = {
  filePath: string;
  bytes: Uint8Array;
  mimeType: 'image/webp';
};

function getNativeModule(): ReceiptWebpCompressorNativeModule {
  const nativeModule = NativeModules.ReceiptWebpCompressor as ReceiptWebpCompressorNativeModule | undefined;

  if (!nativeModule) {
    throw new Error('Receipt WebP compressor is unavailable.');
  }

  return nativeModule;
}

async function readFileAsBytes(filePath: string): Promise<Uint8Array> {
  const response = await fetch(`file://${filePath}`);
  return new Uint8Array(await response.arrayBuffer());
}

export async function compressReceiptBlobToWebp(
  blob: Uint8Array,
  quality = 80,
  maxBytes = 5_000_000,
): Promise<CompressedReceiptImage> {
  if (Platform.OS !== 'android') {
    throw new Error('WebP compression is only available on Android.');
  }

  const filePath = await getNativeModule().compressBase64ToWebp(Buffer.from(blob).toString('base64'), quality, maxBytes);
  const bytes = await readFileAsBytes(filePath);

  if (bytes.byteLength > maxBytes) {
    throw new Error(`Compressed receipt exceeds ${maxBytes} bytes.`);
  }

  return {
    filePath,
    bytes,
    mimeType: 'image/webp',
  };
}
