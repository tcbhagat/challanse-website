import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Pressable,
  StatusBar,
  StyleSheet,
  Text,
  Vibration,
  View,
} from 'react-native';
import {
  Camera,
  CommonResolutions,
  type Frame,
  usePhotoOutput,
  useCameraDevice,
  useCameraPermission,
  useFrameOutput,
} from 'react-native-vision-camera';
import { scheduleOnRN } from 'react-native-worklets';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import DeviceInfo from 'react-native-device-info';
import { insertReceiptEvent } from './engine/receiptStore';
import {
  buildReceiptModelInput,
  classifyReceiptTensor,
  loadReceiptInferenceModel,
} from './model/receiptInference';
import { startReceiptBackgroundSync } from './sync/receiptBackgroundSync';
import type { PilotConfiguration, PilotVendor } from './config/deviceEnrollment';

type CaptureCandidate = {
  score: number;
};

const AUTO_CAPTURE_THRESHOLD = 0.71;
const MODEL_THRESHOLD = 0.5;

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function getFrameBytes(frame: Frame): Uint8Array {
  const planes = frame.isPlanar ? frame.getPlanes() : [];
  const sourceBuffer =
    planes.length > 0 && planes[0] != null ? planes[0].getPixelBuffer() : frame.getPixelBuffer();

  return new Uint8Array(sourceBuffer);
}

function scoreContrast(bytes: Uint8Array): number {
  if (bytes.length === 0) {
    return 0;
  }

  const sampleStep = Math.max(1, Math.floor(bytes.length / 256));
  let brightCount = 0;
  let diffTotal = 0;
  let lastValue = bytes[0] ?? 0;
  let sampleCount = 0;

  for (let index = 0; index < bytes.length; index += sampleStep) {
    const value = bytes[index] ?? 0;
    if (value >= 210) {
      brightCount += 1;
    }
    diffTotal += Math.abs(value - lastValue);
    lastValue = value;
    sampleCount += 1;
  }

  const brightRatio = brightCount / Math.max(1, sampleCount);
  const contrastRatio = diffTotal / Math.max(1, sampleCount) / 255;
  return clamp(brightRatio * 0.65 + contrastRatio * 0.35, 0, 1);
}

function VendorOrb({
  vendor,
  selected,
  onPress,
}: {
  vendor: PilotVendor;
  selected: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={vendor.id}
      onPress={onPress}
      style={({ pressed }) => [
        styles.vendorOrb,
        { backgroundColor: vendor.color },
        selected && styles.vendorOrbSelected,
        pressed && styles.pressed,
      ]}>
      <Text style={styles.vendorOrbText}>{vendor.initials}</Text>
    </Pressable>
  );
}

function QuantityControl({
  value,
  onDecrement,
  onIncrement,
}: {
  value: number;
  onDecrement: () => void;
  onIncrement: () => void;
}) {
  return (
    <View style={styles.quantityWrap}>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Decrease quantity"
        onPress={onDecrement}
        style={({ pressed }) => [styles.quantityButton, styles.quantityButtonNegative, pressed && styles.pressed]}>
        <Text style={styles.quantitySymbol}>−</Text>
      </Pressable>

      <Text style={styles.quantityValue}>{value}</Text>

      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Increase quantity"
        onPress={onIncrement}
        style={({ pressed }) => [styles.quantityButton, styles.quantityButtonPositive, pressed && styles.pressed]}>
        <Text style={styles.quantitySymbol}>+</Text>
      </Pressable>
    </View>
  );
}

function ReceiveMaterialScreen({ configuration }: { configuration: PilotConfiguration }) {
  const insets = useSafeAreaInsets();
  const { hasPermission, requestPermission } = useCameraPermission();
  const cameraDevice = useCameraDevice('back');
  const [selectedVendorId, setSelectedVendorId] = useState(configuration.vendors[0]?.id ?? '');
  const [quantity, setQuantity] = useState(1);
  const [captureLock, setCaptureLock] = useState(false);
  const captureLockRef = useRef(false);
  const selectedVendorRef = useRef(selectedVendorId);
  const quantityRef = useRef(quantity);
  const modelRef = useRef<Awaited<ReturnType<typeof loadReceiptInferenceModel>> | null>(null);
  const photoOutput = usePhotoOutput({
    targetResolution: CommonResolutions.UHD_4_3,
    containerFormat: 'jpeg',
    quality: 0.82,
    qualityPrioritization: 'balanced',
  });
  const photoOutputRef = useRef(photoOutput);

  useEffect(() => {
    requestPermission().catch(() => undefined);
  }, [requestPermission]);

  useEffect(() => {
    startReceiptBackgroundSync({
      ingestBaseUrl: configuration.apiBaseUrl,
      wifiSsids: configuration.allowedWifiSsids,
      siteId: configuration.site.id,
    }).catch(() => undefined);
  }, [configuration]);

  useEffect(() => {
    selectedVendorRef.current = selectedVendorId;
  }, [selectedVendorId]);

  useEffect(() => {
    quantityRef.current = quantity;
  }, [quantity]);

  useEffect(() => {
    photoOutputRef.current = photoOutput;
  }, [photoOutput]);

  useEffect(() => {
    captureLockRef.current = captureLock;
  }, [captureLock]);

  useEffect(() => {
    let cancelled = false;

    loadReceiptInferenceModel().then((loadedModel) => {
      if (!cancelled) {
        modelRef.current = loadedModel;
      }
    });

    return () => {
      cancelled = true;
    };
  }, []);

  const handleCandidate = useCallback(async (candidate: CaptureCandidate) => {
    if (captureLockRef.current) {
      return;
    }

    captureLockRef.current = true;
    setCaptureLock(true);

    let photo = null;

    try {
      photo = await photoOutputRef.current.capturePhoto({}, {});

      const model = modelRef.current;
      let modelConfidence = 1;

      if (model) {
        try {
          const modelInput = buildReceiptModelInput(photo);
          const classification = classifyReceiptTensor(model, modelInput);
          modelConfidence = classification.confidence;
        } catch {
          modelConfidence = 0;
        }
      }

      const approved =
        candidate.score >= AUTO_CAPTURE_THRESHOLD &&
        (modelConfidence >= MODEL_THRESHOLD || modelRef.current == null);

      if (!approved) {
        return;
      }

      const imageBytes = new Uint8Array(photo.getFileData());
      await insertReceiptEvent({
        imageBlob: imageBytes,
        vendorId: selectedVendorRef.current,
        capturedAtUnix: Math.floor(photo.timestamp || Date.now() / 1000),
        siteId: configuration.site.id,
        deviceId: configuration.device.id,
        capturedQuantity: quantityRef.current,
        appVersion: DeviceInfo.getVersion(),
        configurationVersion: configuration.configurationVersion,
      });

      Vibration.vibrate(16);
      setQuantity(1);
    } finally {
      photo?.dispose();
      captureLockRef.current = false;
      setCaptureLock(false);
    }
  }, [configuration]);

  const frameOutput = useFrameOutput({
    targetResolution: CommonResolutions.VGA_4_3,
    pixelFormat: 'yuv',
    dropFramesWhileBusy: true,
    enablePreviewSizedOutputBuffers: true,
    allowDeferredStart: true,
    onFrame(frame) {
      'worklet';

      if (!hasPermission || captureLock) {
        frame.dispose();
        return;
      }

      const bytes = getFrameBytes(frame);
      const score = scoreContrast(bytes);

      if (score >= AUTO_CAPTURE_THRESHOLD) {
        scheduleOnRN(handleCandidate, {
          score,
        });
      }

      frame.dispose();
    },
  });

  const activeOutputs = useMemo(() => [frameOutput, photoOutput], [frameOutput, photoOutput]);

  const canShowCamera = hasPermission && cameraDevice != null;

  return (
    <View
      style={[
        styles.screen,
        {
          paddingTop: insets.top,
          paddingBottom: Math.max(insets.bottom, 18),
        },
      ]}>
      <StatusBar hidden translucent backgroundColor="#000000" barStyle="light-content" />

      <View style={styles.cameraShell}>
        {canShowCamera ? (
          <Camera
            style={StyleSheet.absoluteFill}
            device={cameraDevice}
            isActive={!captureLock}
            outputs={activeOutputs}
            enableNativeZoomGesture={false}
            enableSmoothAutoFocus
            mirrorMode="auto"
          />
        ) : (
          <View style={styles.cameraFallback} />
        )}

        <View style={styles.overlayWash} />
        <View style={styles.focusFrame} />
      </View>

      <View style={[styles.bottomRail, { paddingBottom: Math.max(16, insets.bottom) }]}>
        <View style={styles.vendorRow}>
          {configuration.vendors.map((vendor) => (
            <VendorOrb
              key={vendor.id}
              vendor={vendor}
              selected={vendor.id === selectedVendorId}
              onPress={() => {
                if (!captureLock) {
                  setSelectedVendorId(vendor.id);
                }
              }}
            />
          ))}
        </View>

        <QuantityControl
          value={quantity}
          onDecrement={() => setQuantity((current) => Math.max(1, current - 1))}
          onIncrement={() => setQuantity((current) => Math.min(99, current + 1))}
        />

      </View>
    </View>
  );
}

export default function ReceiveMaterialApp({ configuration }: { configuration: PilotConfiguration }) {
  return <ReceiveMaterialScreen configuration={configuration} />;
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: '#000000',
  },
  cameraShell: {
    ...StyleSheet.absoluteFill,
    backgroundColor: '#000000',
  },
  cameraFallback: {
    ...StyleSheet.absoluteFill,
    backgroundColor: '#000000',
  },
  overlayWash: {
    ...StyleSheet.absoluteFill,
    backgroundColor: 'rgba(0, 0, 0, 0.18)',
  },
  focusFrame: {
    position: 'absolute',
    left: '10%',
    top: '15%',
    right: '10%',
    bottom: '26%',
    borderWidth: 2,
    borderColor: 'rgba(255, 255, 255, 0.16)',
    borderRadius: 36,
  },
  bottomRail: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    paddingHorizontal: 18,
    gap: 16,
  },
  vendorRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    gap: 10,
  },
  vendorOrb: {
    width: 72,
    height: 72,
    borderRadius: 999,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
    borderColor: 'rgba(255, 255, 255, 0.18)',
    shadowColor: '#000000',
    shadowOpacity: 0.22,
    shadowRadius: 14,
    shadowOffset: { width: 0, height: 6 },
  },
  vendorOrbSelected: {
    borderColor: '#ffffff',
    transform: [{ scale: 1.04 }],
  },
  vendorOrbText: {
    color: '#0a0a0a',
    fontSize: 24,
    fontWeight: '900',
  },
  quantityWrap: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 14,
  },
  quantityButton: {
    width: 92,
    height: 92,
    borderRadius: 999,
    alignItems: 'center',
    justifyContent: 'center',
  },
  quantityButtonNegative: {
    backgroundColor: 'rgba(255, 255, 255, 0.06)',
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.16)',
  },
  quantityButtonPositive: {
    backgroundColor: '#ffffff',
  },
  quantitySymbol: {
    fontSize: 56,
    lineHeight: 56,
    fontWeight: '900',
    color: '#ffffff',
  },
  quantityValue: {
    minWidth: 88,
    textAlign: 'center',
    fontSize: 44,
    lineHeight: 50,
    fontWeight: '900',
    color: '#ffffff',
  },
  pressed: {
    transform: [{ scale: 0.97 }],
  },
});
