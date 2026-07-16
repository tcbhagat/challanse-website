import BackgroundService from 'react-native-background-actions';
import NetInfo, { NetInfoStateType } from '@react-native-community/netinfo';
import DeviceInfo from 'react-native-device-info';
import { Platform } from 'react-native';
import { sha256 } from '@noble/hashes/sha2.js';
import { bytesToHex } from '@noble/hashes/utils.js';
import {
  completeReceiptSync,
  clearReceiptUploadId,
  getReceiptSyncArtifact,
  getReceiptUploadId,
  getReceiptSyncSettings,
  incrementReceiptSyncAttempt,
  listPendingReceiptSyncItems,
  markReceiptSyncState,
  purgeAcknowledgedReceiptPayloads,
  recordReceiptSyncLog,
  seedReceiptSyncSettingsIfMissing,
  setReceiptSyncSettings,
  setReceiptUploadId,
  updateReceiptSyncArtifactProgress,
  upsertReceiptSyncArtifact,
  type ReceiptSyncQueueItem,
} from './receiptSyncStore';
import { compressReceiptBlobToWebp } from './receiptWebp';
import { getEnrollmentCredential } from '../config/deviceEnrollment';
import { listPendingTelemetryEvents, markTelemetryEventsSent, recordTelemetryEvent } from '../telemetry/telemetryStore';

type ReceiptSyncRuntimeGate = { allowed: boolean; reason: string; retryAfterMs: number };
type ReceiptSyncParameters = { ingestBaseUrl?: string; wifiSsids?: string[]; siteId?: string };

const TASK_NAME = 'ReceiptSync';
const BASE_BACKOFF_MS = 5000;
const MAX_BACKOFF_MS = 15 * 60 * 1000;
const IDLE_POLL_MS = 45 * 1000;
const CONSTRAINT_POLL_MS = 60 * 1000;
const MAX_ITEMS_PER_WAKE = 5;
const MAX_IMAGE_BYTES = 750_000;
const UPLOAD_PART_SIZE = 256_000;
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
  const imageHash = bytesToHex(sha256(artifact.bytes));
  const metadata = {
    receiptId: item.receiptId,
    vendorId: item.vendorId,
    capturedAtUnix: item.capturedAtUnix,
    capturedQuantity: item.capturedQuantity,
    imageSha256: imageHash,
    appVersion: item.appVersion,
    configurationVersion: item.configurationVersion,
    totalBytes: artifact.bytes.byteLength,
    mimeType: 'image/webp',
  };
  const root = apiBaseUrl.replace(/\/$/, '');
  let uploadId = await getReceiptUploadId(item.receiptEventId);
  if (!uploadId) {
    const sessionResponse = await fetch(`${root}/v1/uploads`, {
      method: 'POST',
      headers: { Accept: 'application/json', Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(metadata),
    });
    if (!sessionResponse.ok) throw new Error(`UPLOAD_SESSION_HTTP_${sessionResponse.status}`);
    const session = await sessionResponse.json() as { uploadId?: string; complete?: boolean };
    if (session.complete) {
      await completeReceiptSync({ receiptEventId: item.receiptEventId, uploadedBytes: artifact.bytes.byteLength, totalBytes: artifact.bytes.byteLength });
      return;
    }
    if (!session.uploadId) throw new Error('UPLOAD_SESSION_INVALID');
    uploadId = session.uploadId;
    await setReceiptUploadId(item.receiptEventId, uploadId);
  }
  const progressResponse = await fetch(`${root}/v1/uploads/${uploadId}`, { headers: { Accept: 'application/json', Authorization: `Bearer ${token}` } });
  if (!progressResponse.ok) {
    if (progressResponse.status === 404 || progressResponse.status === 409) await clearReceiptUploadId(item.receiptEventId);
    throw new Error(`UPLOAD_PROGRESS_HTTP_${progressResponse.status}`);
  }
  const progress = await progressResponse.json() as { parts: Array<{ partNumber: number; sha256: string }>; uploadedBytes: number };
  const confirmed = new Map(progress.parts.map((part) => [part.partNumber, part.sha256]));
  await markReceiptSyncState({ receiptEventId: item.receiptEventId, status: 'uploading', detail: 'Sending confirmed image parts.' });
  for (let offset = 0, partNumber = 0; offset < artifact.bytes.byteLength; offset += UPLOAD_PART_SIZE, partNumber += 1) {
    const part = artifact.bytes.slice(offset, Math.min(offset + UPLOAD_PART_SIZE, artifact.bytes.byteLength));
    const partHash = bytesToHex(sha256(part));
    if (confirmed.get(partNumber) === partHash) continue;
    const partBuffer = part.buffer.slice(part.byteOffset, part.byteOffset + part.byteLength) as ArrayBuffer;
    const partResponse = await fetch(`${root}/v1/uploads/${uploadId}/parts/${partNumber}`, {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/octet-stream',
        'X-Part-Sha256': partHash,
        'X-ChallanSe-Nonce': nonce(),
        'X-ChallanSe-Timestamp': String(nowUnix()),
      },
      body: partBuffer as unknown as RequestInit['body'],
    });
    if (!partResponse.ok) throw new Error(`UPLOAD_PART_HTTP_${partResponse.status}`);
    await updateReceiptSyncArtifactProgress(item.receiptEventId, Math.min(offset + part.byteLength, artifact.bytes.byteLength));
  }
  const response = await fetch(`${root}/v1/uploads/${uploadId}/complete`, {
    method: 'POST',
    headers: { Accept: 'application/json', Authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`UPLOAD_COMPLETE_HTTP_${response.status}`);
  await completeReceiptSync({ receiptEventId: item.receiptEventId, uploadedBytes: artifact.bytes.byteLength, totalBytes: artifact.bytes.byteLength });
  await clearReceiptUploadId(item.receiptEventId);
  await recordReceiptSyncLog({ receiptEventId: item.receiptEventId, state: 'synced', detail: 'Receipt safely acknowledged by ChallanSe.' });
  await recordTelemetryEvent({ eventName: 'sync_failure_rate', siteId: item.siteId, vendorId: item.vendorId, value: 0, success: true });
}

async function syncTelemetry(apiBaseUrl: string, token: string): Promise<void> {
  const events = await listPendingTelemetryEvents(100);
  if (!events.length) return;
  const measurements = events.map((event) => {
    const created = new Date(event.createdAtUnix * 1000).toISOString();
    return {
      source_event_id: String(event.id),
      vendor_id: event.vendorId ?? null,
      metric_name: event.eventName,
      metric_value: event.eventName === 'frontend_write_duration_ms' ? event.durationMs ?? 0 : event.value ?? (event.success ? 0 : 1),
      sample_count: 1,
      period_start: created,
      period_end: created,
    };
  }).filter((measurement) => measurement.metric_name === 'frontend_write_duration_ms' || measurement.metric_name === 'sync_failure_rate');
  if (!measurements.length) {
    await markTelemetryEventsSent(events.map((event) => event.id));
    return;
  }
  const response = await fetch(`${apiBaseUrl.replace(/\/$/, '')}/v1/mobile/telemetry`, {
    method: 'POST',
    headers: { Accept: 'application/json', Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ measurements }),
  });
  if (!response.ok) throw new Error(`TELEMETRY_HTTP_${response.status}`);
  await markTelemetryEventsSent(events.map((event) => event.id));
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
    try { await syncTelemetry(credential.apiBaseUrl, credential.deviceToken); } catch { /* telemetry remains queued */ }
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
        await recordTelemetryEvent({ eventName: 'sync_failure_rate', siteId: item.siteId, vendorId: item.vendorId, value: 1, success: false });
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
