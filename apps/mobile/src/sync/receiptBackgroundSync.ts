import BackgroundService from 'react-native-background-actions';
import NetInfo, { NetInfoStateType } from '@react-native-community/netinfo';
import DeviceInfo from 'react-native-device-info';
import { Platform } from 'react-native';
import { sha256 } from '@noble/hashes/sha2.js';
import { bytesToHex } from '@noble/hashes/utils.js';
import {
  completeReceiptSync,
  getReceiptSyncArtifact,
  getReceiptSyncSettings,
  incrementReceiptSyncAttempt,
  listPendingReceiptSyncItems,
  markReceiptSyncState,
  purgeAcknowledgedReceiptPayloads,
  recordReceiptSyncLog,
  seedReceiptSyncSettingsIfMissing,
  setReceiptSyncSettings,
  upsertReceiptSyncArtifact,
  type ReceiptSyncQueueItem,
} from './receiptSyncStore';
import { compressReceiptBlobToWebp } from './receiptWebp';
import { getEnrollmentCredential } from '../config/deviceEnrollment';

type ReceiptSyncRuntimeGate = { allowed: boolean; reason: string; retryAfterMs: number };
type ReceiptSyncParameters = { ingestBaseUrl?: string; wifiSsids?: string[]; siteId?: string };

const TASK_NAME = 'ReceiptSync';
const BASE_BACKOFF_MS = 5000;
const MAX_BACKOFF_MS = 15 * 60 * 1000;
const IDLE_POLL_MS = 45 * 1000;
const CONSTRAINT_POLL_MS = 60 * 1000;
const MAX_ITEMS_PER_WAKE = 5;
const MAX_IMAGE_BYTES = 750_000;
let isConfigured = false;

NetInfo.configure({ shouldFetchWiFiSSID: true, useNativeReachability: true });

function sleep(milliseconds: number): Promise<void> { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }
function nowUnix(): number { return Math.floor(Date.now() / 1000); }
function normalizeSsids(ssids: string[]): string[] { return Array.from(new Set(ssids.map((ssid) => ssid.trim().toLowerCase()).filter(Boolean))); }
function backoff(attemptCount: number): number { return Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * 2 ** Math.max(0, attemptCount)); }
function nonce(): string {
  const bytes = new Uint8Array(16);
  (globalThis as unknown as { crypto: { getRandomValues: (values: Uint8Array) => Uint8Array } }).crypto.getRandomValues(bytes);
  return bytesToHex(bytes);
}

async function gate(): Promise<ReceiptSyncRuntimeGate> {
  const [settings, network, charging] = await Promise.all([getReceiptSyncSettings(), NetInfo.fetch(), DeviceInfo.isBatteryCharging()]);
  if (!settings.ingestBaseUrl.trim()) return { allowed: false, reason: 'missing_api', retryAfterMs: CONSTRAINT_POLL_MS };
  if (!charging) return { allowed: false, reason: 'not_charging', retryAfterMs: CONSTRAINT_POLL_MS };
  if (!network.isConnected || (network.type !== NetInfoStateType.wifi && network.type !== NetInfoStateType.ethernet)) {
    return { allowed: false, reason: 'not_on_wifi', retryAfterMs: CONSTRAINT_POLL_MS };
  }
  if (network.details?.isConnectionExpensive) return { allowed: false, reason: 'expensive_connection', retryAfterMs: CONSTRAINT_POLL_MS };
  const whitelist = normalizeSsids(settings.wifiSsids);
  if (!whitelist.length) return { allowed: false, reason: 'missing_wifi_whitelist', retryAfterMs: CONSTRAINT_POLL_MS };
  if (network.type === NetInfoStateType.wifi) {
    const current = typeof network.details?.ssid === 'string' ? network.details.ssid.trim().toLowerCase() : '';
    if (!current || !whitelist.includes(current)) return { allowed: false, reason: current ? 'ssid_not_whitelisted' : 'ssid_unavailable', retryAfterMs: CONSTRAINT_POLL_MS };
  }
  return { allowed: true, reason: 'eligible', retryAfterMs: 0 };
}

async function configure(parameters?: ReceiptSyncParameters): Promise<void> {
  if (isConfigured) return;
  await seedReceiptSyncSettingsIfMissing();
  if (parameters) await setReceiptSyncSettings(parameters);
  isConfigured = true;
}

async function compressedArtifact(item: ReceiptSyncQueueItem): Promise<{ bytes: Uint8Array; mimeType: string }> {
  const existing = await getReceiptSyncArtifact(item.receiptEventId);
  if (existing?.payload.byteLength) return { bytes: existing.payload, mimeType: existing.mimeType };
  await markReceiptSyncState({ receiptEventId: item.receiptEventId, status: 'compressing', detail: 'Preparing receipt image.' });
  const compressed = await compressReceiptBlobToWebp(item.imageBlob, 80, MAX_IMAGE_BYTES);
  await upsertReceiptSyncArtifact({ receiptEventId: item.receiptEventId, mimeType: compressed.mimeType, payload: compressed.bytes, totalBytes: compressed.bytes.byteLength });
  return { bytes: compressed.bytes, mimeType: compressed.mimeType };
}

async function syncReceipt(item: ReceiptSyncQueueItem, apiBaseUrl: string, token: string): Promise<void> {
  const artifact = await compressedArtifact(item);
  const payloadBuffer = artifact.bytes.buffer.slice(artifact.bytes.byteOffset, artifact.bytes.byteOffset + artifact.bytes.byteLength) as ArrayBuffer;
  const imageHash = bytesToHex(sha256(artifact.bytes));
  const form = new FormData();
  form.append('metadata', JSON.stringify({
    receiptId: item.receiptId,
    vendorId: item.vendorId,
    capturedAtUnix: item.capturedAtUnix,
    capturedQuantity: item.capturedQuantity,
    imageSha256: imageHash,
    appVersion: item.appVersion,
    configurationVersion: item.configurationVersion,
  }));
  const imageBlob = new Blob([payloadBuffer as unknown as Blob], { type: artifact.mimeType, lastModified: Date.now() });
  (form as FormData & { append(name: string, value: unknown, fileName?: string): void }).append('image', imageBlob, `${item.receiptId}.webp`);

  await markReceiptSyncState({ receiptEventId: item.receiptEventId, status: 'uploading', detail: 'Sending receipt securely.' });
  const response = await fetch(`${apiBaseUrl.replace(/\/$/, '')}/v1/receipts`, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${token}`,
      'X-ChallanSe-Nonce': nonce(),
      'X-ChallanSe-Timestamp': String(nowUnix()),
    },
    body: form as unknown as RequestInit['body'],
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => null) as { error?: { code?: string; message?: string } } | null;
    throw new Error(payload?.error?.code || `UPLOAD_HTTP_${response.status}`);
  }
  await completeReceiptSync({ receiptEventId: item.receiptEventId, uploadedBytes: artifact.bytes.byteLength, totalBytes: artifact.bytes.byteLength });
  await recordReceiptSyncLog({ receiptEventId: item.receiptEventId, state: 'synced', detail: 'Receipt safely acknowledged by ChallanSe.' });
}

async function run(parameters?: ReceiptSyncParameters): Promise<void> {
  await configure(parameters);
  while (BackgroundService.isRunning()) {
    const currentGate = await gate();
    if (!currentGate.allowed) {
      await recordReceiptSyncLog({ receiptEventId: null, state: currentGate.reason, detail: 'Sync is waiting for approved charging Wi-Fi.' });
      await sleep(currentGate.retryAfterMs);
      continue;
    }
    const credential = await getEnrollmentCredential();
    if (!credential) { await sleep(CONSTRAINT_POLL_MS); continue; }
    await purgeAcknowledgedReceiptPayloads(7);
    const items = await listPendingReceiptSyncItems(MAX_ITEMS_PER_WAKE);
    if (!items.length) { await sleep(IDLE_POLL_MS); continue; }
    for (const item of items) {
      if (!BackgroundService.isRunning()) return;
      try {
        await syncReceipt(item, credential.apiBaseUrl, credential.deviceToken);
      } catch (caught) {
        const detail = caught instanceof Error ? caught.message : 'UNKNOWN_UPLOAD_FAILURE';
        const attempt = await incrementReceiptSyncAttempt({
          receiptEventId: item.receiptEventId,
          totalBytes: item.totalBytes,
          uploadedBytes: 0,
          lastError: detail,
          nextAttemptAtUnix: nowUnix() + Math.floor(backoff(item.attemptCount) / 1000),
        });
        await recordReceiptSyncLog({ receiptEventId: item.receiptEventId, state: 'backoff', detail: `Attempt ${attempt}: ${detail}` });
      }
    }
  }
}

export async function startReceiptBackgroundSync(parameters?: ReceiptSyncParameters): Promise<void> {
  if (Platform.OS !== 'android') return;
  await configure(parameters);
  if (BackgroundService.isRunning()) return;
  await BackgroundService.start(run, {
    taskName: TASK_NAME,
    taskTitle: 'ChallanSe receipt sync',
    taskDesc: 'Waiting for approved charging Wi-Fi',
    taskIcon: { name: 'ic_launcher', type: 'mipmap' },
    color: '#0f1115',
    foregroundServiceType: ['dataSync'],
    parameters,
  });
}

export async function stopReceiptBackgroundSync(): Promise<void> {
  if (Platform.OS === 'android' && BackgroundService.isRunning()) await BackgroundService.stop();
}

export async function configureReceiptSyncSettings(settings: ReceiptSyncParameters): Promise<void> {
  await setReceiptSyncSettings(settings);
  isConfigured = true;
}

export async function getReceiptSyncRuntimeGate(): Promise<ReceiptSyncRuntimeGate> { return gate(); }
