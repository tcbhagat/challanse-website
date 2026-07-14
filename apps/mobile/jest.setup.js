/* global jest, global */

global.__quickSqliteQueries = [];

jest.mock('react-native-quick-sqlite', () => ({
  open: () => ({
    executeAsync: jest.fn(async (query, params) => {
      global.__quickSqliteQueries.push({ query: String(query), params });
      if (String(query).includes('COUNT(*)')) {
        return { rows: [{ event_count: 0 }] };
      }

      return { rows: [] };
    }),
    close: jest.fn(),
  }),
}));

jest.mock('react-native-keychain', () => ({
  ACCESSIBLE: {
    WHEN_UNLOCKED_THIS_DEVICE_ONLY: 'WHEN_UNLOCKED_THIS_DEVICE_ONLY',
  },
  getGenericPassword: jest.fn(async () => false),
  setGenericPassword: jest.fn(async () => undefined),
  resetGenericPassword: jest.fn(async () => true),
}));

jest.mock('react-native-vision-camera', () => {
  const React = require('react');
  const { View } = require('react-native');

  return {
    Camera: () => React.createElement(View),
    CommonResolutions: {
      UHD_4_3: { width: 3024, height: 4032 },
      VGA_4_3: { width: 480, height: 640 },
    },
    useCameraDevice: jest.fn(() => ({ id: 'back-camera' })),
    useCameraPermission: jest.fn(() => ({
      hasPermission: true,
      requestPermission: jest.fn(async () => true),
    })),
    useFrameOutput: jest.fn(() => ({})),
    usePhotoOutput: jest.fn(() => ({
      capturePhoto: jest.fn(async () => ({
        timestamp: 1234567890,
        width: 2,
        height: 2,
        pixelFormat: 'rgb-bgra-8-bit',
        hasPixelBuffer: true,
        getPixelBuffer: () => new Uint8Array([255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255]).buffer,
        getFileData: () => new Uint8Array([1, 2, 3, 4]).buffer,
        dispose: jest.fn(),
      })),
    })),
  };
});

jest.mock('react-native-worklets', () => ({
  scheduleOnRN: jest.fn((fun, ...args) => fun(...args)),
}));

jest.mock('react-native-fast-tflite', () => ({
  loadTensorflowModel: jest.fn(async () => {
    throw new Error('mocked model load failure');
  }),
}));

jest.mock('react-native-background-actions', () => ({
  __esModule: true,
  default: {
    isRunning: jest.fn(() => false),
    start: jest.fn(async () => undefined),
    stop: jest.fn(async () => undefined),
    updateNotification: jest.fn(async () => undefined),
    on: jest.fn(),
  },
}));

jest.mock('@react-native-community/netinfo', () => ({
  __esModule: true,
  default: {
    configure: jest.fn(),
    fetch: jest.fn(async () => ({
      type: 'wifi',
      isConnected: true,
      isInternetReachable: true,
      details: {
        isConnectionExpensive: false,
        ssid: 'SITE_OFFICE_WIFI',
        bssid: '00:11:22:33:44:55',
        strength: 100,
        ipAddress: '192.168.0.10',
        subnet: '255.255.255.0',
        frequency: 2412,
        linkSpeed: 72,
        rxLinkSpeed: 72,
        txLinkSpeed: 72,
      },
    })),
  },
  NetInfoStateType: {
    unknown: 'unknown',
    none: 'none',
    cellular: 'cellular',
    wifi: 'wifi',
    bluetooth: 'bluetooth',
    ethernet: 'ethernet',
    wimax: 'wimax',
    vpn: 'vpn',
    other: 'other',
  },
}));

jest.mock('react-native-device-info', () => ({
  __esModule: true,
  default: {
    isBatteryCharging: jest.fn(async () => true),
    getVersion: jest.fn(() => '1.0.0'),
    getBrand: jest.fn(() => 'Test'),
    getModel: jest.fn(() => 'Device'),
  },
  isBatteryCharging: jest.fn(async () => true),
}));

jest.mock('@noble/hashes/sha2.js', () => ({
  sha256: jest.fn(() => new Uint8Array(32)),
}));

jest.mock('@noble/hashes/utils.js', () => ({
  bytesToHex: jest.fn((bytes) => Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('')),
}));

const ReactNative = require('react-native');
ReactNative.NativeModules.ReceiptWebpCompressor = {
  compressBase64ToWebp: jest.fn(async () => '/tmp/receipt.webp'),
};

Object.defineProperty(global, 'crypto', {
  configurable: true,
  value: {
    getRandomValues(values) {
      values.fill(7);
      return values;
    },
  },
});
