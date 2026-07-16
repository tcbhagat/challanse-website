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
  usePhotoOutput,
  useCameraDevice,
  useCameraPermission,
} from 'react-native-vision-camera';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import DeviceInfo from 'react-native-device-info';
import { insertReceiptEvent } from './engine/receiptStore';
import { startReceiptBackgroundSync } from './sync/receiptBackgroundSync';
import type { PilotConfiguration, PilotVendor } from './config/deviceEnrollment';
import { warmPlayIntegrity } from './security/playIntegrity';

const CAPTURE_COOLDOWN_MS = 2000;

function imageFingerprint(bytes: Uint8Array): string {
  const step = Math.max(1, Math.floor(bytes.length / 64));
  let hash = 2166136261;
  for (let index = 0; index < bytes.length; index += step) {
    hash ^= bytes[index] ?? 0;
    hash = Math.imul(hash, 16777619);
  }
  return `${bytes.length}:${hash >>> 0}`;
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

function CameraPermissionAction({ onPress }: { onPress: () => void }) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel="Open camera. कैमरा खोलें"
      onPress={onPress}
      style={({ pressed }) => [styles.permissionButton, pressed && styles.pressed]}>
      <View style={styles.permissionCameraBody}>
        <View style={styles.permissionCameraTop} />
        <View style={styles.permissionCameraLens} />
      </View>
    </Pressable>
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
  const lastCaptureAtRef = useRef(0);
  const lastFingerprintRef = useRef('');
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
    warmPlayIntegrity().catch(() => undefined);
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

  const handleCapture = useCallback(async () => {
    if (captureLockRef.current) {
      return;
    }
    const now = Date.now();
    if (now - lastCaptureAtRef.current < CAPTURE_COOLDOWN_MS) return;

    captureLockRef.current = true;
    setCaptureLock(true);

    let photo = null;

    try {
      photo = await photoOutputRef.current.capturePhoto({}, {});
      const imageBytes = new Uint8Array(photo.getFileData());
      const fingerprint = imageFingerprint(imageBytes);
      if (fingerprint === lastFingerprintRef.current) return;
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
      startReceiptBackgroundSync().catch(() => undefined);

      Vibration.vibrate(16);
      lastCaptureAtRef.current = Date.now();
      lastFingerprintRef.current = fingerprint;
      setQuantity(1);
    } finally {
      photo?.dispose();
      captureLockRef.current = false;
      setCaptureLock(false);
    }
  }, [configuration]);

  const activeOutputs = useMemo(() => [photoOutput], [photoOutput]);

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
          <View style={styles.cameraFallback}>
            {!hasPermission && <CameraPermissionAction onPress={() => requestPermission().catch(() => undefined)} />}
          </View>
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

        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Capture challan. चालान की फोटो लें"
          disabled={captureLock || !canShowCamera}
          onPress={handleCapture}
          style={({ pressed }) => [styles.captureButton, pressed && styles.pressed, captureLock && styles.captureButtonBusy]}>
          <View style={styles.captureButtonInner} />
        </Pressable>

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
    alignItems: 'center',
    backgroundColor: '#000000',
    justifyContent: 'center',
  },
  permissionButton: {
    alignItems: 'center',
    backgroundColor: '#F4A300',
    borderRadius: 48,
    height: 96,
    justifyContent: 'center',
    width: 96,
  },
  permissionCameraBody: {
    alignItems: 'center',
    backgroundColor: '#071A2E',
    borderRadius: 8,
    height: 38,
    justifyContent: 'center',
    width: 54,
  },
  permissionCameraTop: {
    backgroundColor: '#071A2E',
    borderTopLeftRadius: 4,
    borderTopRightRadius: 4,
    height: 8,
    position: 'absolute',
    top: -7,
    width: 24,
  },
  permissionCameraLens: {
    borderColor: '#F4A300',
    borderRadius: 11,
    borderWidth: 4,
    height: 22,
    width: 22,
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
  captureButton: {
    alignSelf: 'center',
    width: 96,
    height: 96,
    borderRadius: 999,
    borderWidth: 5,
    borderColor: '#ffffff',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(0, 0, 0, 0.55)',
  },
  captureButtonInner: {
    width: 72,
    height: 72,
    borderRadius: 999,
    backgroundColor: '#f59e0b',
  },
  captureButtonBusy: {
    opacity: 0.45,
  },
  pressed: {
    transform: [{ scale: 0.97 }],
  },
});
