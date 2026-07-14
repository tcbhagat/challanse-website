import type { Photo } from 'react-native-vision-camera';
import { loadTensorflowModel, type TfliteModel } from 'react-native-fast-tflite';

const INPUT_WIDTH = 224;
const INPUT_HEIGHT = 224;
const CHANNELS = 3;

export const RECEIPT_MODEL_CONTRACT = {
  inputShape: [1, INPUT_HEIGHT, INPUT_WIDTH, CHANNELS] as const,
  inputType: 'uint8' as const,
  outputShape: [1, 1001] as const,
  outputType: 'uint8' as const,
};

export const RECEIPT_MODEL_ASSET = require('../assets/mobilenet_v1_1.0_224_quant.tflite');

export type ReceiptModelResult = {
  confidence: number;
  classIndex: number;
};

type ReceiptPhoto = Photo & {
  pixelFormat?: string;
};

function toArrayBuffer(buffer: ArrayBufferLike): ArrayBuffer {
  if (buffer instanceof ArrayBuffer) {
    return buffer;
  }

  return new Uint8Array(buffer).slice().buffer;
}

function ensureContract(model: TfliteModel): void {
  const input = model.inputs[0];
  const output = model.outputs[0];

  const expectedInputShape = RECEIPT_MODEL_CONTRACT.inputShape.join(',');
  const expectedOutputShape = RECEIPT_MODEL_CONTRACT.outputShape.join(',');

  if (
    input == null ||
    input.dataType !== RECEIPT_MODEL_CONTRACT.inputType ||
    input.shape.join(',') !== expectedInputShape ||
    output == null ||
    output.dataType !== RECEIPT_MODEL_CONTRACT.outputType ||
    output.shape.join(',') !== expectedOutputShape
  ) {
    throw new Error('Receipt model contract mismatch.');
  }
}

export async function loadReceiptInferenceModel(): Promise<TfliteModel> {
  const model = await loadTensorflowModel(RECEIPT_MODEL_ASSET, []);
  ensureContract(model);
  return model;
}

function sourceBytesPerPixel(byteLength: number, width: number, height: number): number {
  return Math.max(1, Math.round(byteLength / Math.max(1, width * height)));
}

function getPixelFormat(photo: ReceiptPhoto): string {
  return typeof photo.pixelFormat === 'string' ? photo.pixelFormat : 'rgba';
}

function sampleRgb(
  source: Uint8Array,
  sourceWidth: number,
  sourceHeight: number,
  sourceBytesPerPixelValue: number,
  targetWidth: number,
  targetHeight: number,
  pixelFormat: string,
): Uint8Array {
  const output = new Uint8Array(targetWidth * targetHeight * CHANNELS);
  const isBgra = pixelFormat.includes('bgra');
  const isRgba = pixelFormat.includes('rgba');

  for (let y = 0; y < targetHeight; y += 1) {
    const sourceY = Math.min(sourceHeight - 1, Math.floor((y * sourceHeight) / targetHeight));

    for (let x = 0; x < targetWidth; x += 1) {
      const sourceX = Math.min(sourceWidth - 1, Math.floor((x * sourceWidth) / targetWidth));
      const sourceIndex = (sourceY * sourceWidth + sourceX) * sourceBytesPerPixelValue;
      const outputIndex = (y * targetWidth + x) * CHANNELS;

      if (sourceBytesPerPixelValue >= 4 && isBgra) {
        output[outputIndex] = source[sourceIndex + 2] ?? 0;
        output[outputIndex + 1] = source[sourceIndex + 1] ?? 0;
        output[outputIndex + 2] = source[sourceIndex] ?? 0;
      } else if (sourceBytesPerPixelValue >= 4 && isRgba) {
        output[outputIndex] = source[sourceIndex] ?? 0;
        output[outputIndex + 1] = source[sourceIndex + 1] ?? 0;
        output[outputIndex + 2] = source[sourceIndex + 2] ?? 0;
      } else {
        output[outputIndex] = source[sourceIndex] ?? 0;
        output[outputIndex + 1] = source[sourceIndex + 1] ?? source[sourceIndex] ?? 0;
        output[outputIndex + 2] = source[sourceIndex + 2] ?? source[sourceIndex] ?? 0;
      }
    }
  }

  return output;
}

export function buildReceiptModelInput(photo: Photo): Uint8Array {
  if (!photo.hasPixelBuffer) {
    throw new Error('Captured photo does not expose pixel data.');
  }

  const sourceBuffer = toArrayBuffer(photo.getPixelBuffer());
  const sourceBytes = new Uint8Array(sourceBuffer);
  const sourceBytesPerPixelValue = sourceBytesPerPixel(sourceBytes.length, photo.width, photo.height);

  return sampleRgb(
    sourceBytes,
    photo.width,
    photo.height,
    sourceBytesPerPixelValue,
    INPUT_WIDTH,
    INPUT_HEIGHT,
    getPixelFormat(photo as ReceiptPhoto),
  );
}

export function classifyReceiptTensor(model: TfliteModel, input: Uint8Array): ReceiptModelResult {
  const outputs = model.runSync([toArrayBuffer(input.buffer)]);
  const outputBuffer = outputs[0];

  if (outputBuffer == null) {
    throw new Error('Receipt model produced no output.');
  }

  const rawScores = new Uint8Array(toArrayBuffer(outputBuffer));
  let classIndex = 0;
  let confidence = 0;

  for (let index = 0; index < rawScores.length; index += 1) {
    const score = rawScores[index] / 255;
    if (score > confidence) {
      confidence = score;
      classIndex = index;
    }
  }

  return { confidence, classIndex };
}
