import type { ReceiptListItem, ReceiptReview } from '@challanse/contracts';

const configuredBase = import.meta.env.VITE_API_BASE_URL as string | undefined;
export const API_BASE_URL = (configuredBase || 'http://127.0.0.1:8787').replace(/\/$/, '');

export class ApiError extends Error {
  constructor(public status: number, message: string, public code = 'REQUEST_FAILED') {
    super(message);
  }
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    credentials: 'include',
    ...init,
    headers: { 'Content-Type': 'application/json', ...init?.headers },
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => null) as { error?: { code?: string; message?: string } } | null;
    throw new ApiError(response.status, payload?.error?.message || 'Request could not be completed.', payload?.error?.code);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

export function listReceipts(status: string, cursor?: string) {
  const params = new URLSearchParams({ status, limit: '25' });
  if (cursor) params.set('cursor', cursor);
  return api<{ receipts: ReceiptListItem[]; nextCursor: string | null }>(`/v1/reviewer/receipts?${params}`);
}

export function reviewReceipt(receiptId: string, review: ReceiptReview) {
  return api<{ receiptId: string; status: string; version: number }>(`/v1/reviewer/receipts/${receiptId}`, {
    method: 'PATCH',
    body: JSON.stringify(review),
  });
}

export function createEnrollmentCode(deviceName: string) {
  return api<{ enrollmentCode: string; expiresInSeconds: number; deviceName: string }>('/v1/admin/enrollment-codes', {
    method: 'POST',
    body: JSON.stringify({ deviceName }),
  });
}

export type AdminSummary = {
  site: { name: string; storedImageBytes: number; storageByteLimit: number; dailyReceiptLimit: number };
  counts: Record<string, number>;
  devices: Array<{ id: string; name: string; appVersion: string; active: boolean; enrolledAt: string; lastSeenAt: string | null }>;
};

export function getAdminSummary() {
  return api<AdminSummary>('/v1/admin/summary');
}

export function revokeDevice(deviceId: string) {
  return api<void>(`/v1/admin/devices/${deviceId}`, { method: 'DELETE' });
}
