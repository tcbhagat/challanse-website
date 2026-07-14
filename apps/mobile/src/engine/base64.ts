/* eslint-disable no-bitwise */

const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function base64ToBytes(base64: string): Uint8Array {
  const clean = base64.replace(/[\r\n\s]/g, '');
  const outputLength =
    (clean.length * 3) / 4 - (clean.endsWith('==') ? 2 : clean.endsWith('=') ? 1 : 0);
  const bytes = new Uint8Array(outputLength);

  let byteIndex = 0;
  for (let index = 0; index < clean.length; index += 4) {
    const first = alphabet.indexOf(clean[index] ?? 'A');
    const second = alphabet.indexOf(clean[index + 1] ?? 'A');
    const thirdChar = clean[index + 2] ?? 'A';
    const fourthChar = clean[index + 3] ?? 'A';
    const third = alphabet.indexOf(thirdChar);
    const fourth = alphabet.indexOf(fourthChar);

    const chunk = (first << 18) | (second << 12) | ((third & 63) << 6) | (fourth & 63);
    bytes[byteIndex++] = (chunk >> 16) & 255;

    if (thirdChar !== '=') {
      bytes[byteIndex++] = (chunk >> 8) & 255;
    }

    if (fourthChar !== '=') {
      bytes[byteIndex++] = chunk & 255;
    }
  }

  return bytes;
}
