import { z } from 'zod';

export const receiptStatuses = ['RECEIVED', 'NEEDS_REVIEW', 'VERIFIED', 'REJECTED'] as const;
export const receiptStatusSchema = z.enum(receiptStatuses);
export type ReceiptStatus = z.infer<typeof receiptStatusSchema>;

export const vendorSchema = z.object({
  id: z.string().min(1).max(64),
  name: z.string().min(1).max(120),
  initials: z.string().min(1).max(3),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/),
});
export type Vendor = z.infer<typeof vendorSchema>;

export const receiptUploadMetadataSchema = z.object({
  receiptId: z.string().uuid(),
  vendorId: z.string().min(1).max(64),
  capturedAtUnix: z.number().int().positive(),
  capturedQuantity: z.number().int().positive().max(1_000_000),
  imageSha256: z.string().regex(/^[a-f0-9]{64}$/),
  appVersion: z.string().min(1).max(32),
  configurationVersion: z.number().int().nonnegative(),
});
export type ReceiptUploadMetadata = z.infer<typeof receiptUploadMetadataSchema>;

export const receiptReviewSchema = z.object({
  action: z.enum(['VERIFY', 'REJECT']),
  version: z.number().int().positive(),
  challanNumber: z.string().trim().max(120).default(''),
  materialDescription: z.string().trim().min(1).max(500),
  verifiedQuantity: z.number().positive().max(1_000_000_000),
  unit: z.string().trim().min(1).max(24),
  notes: z.string().trim().max(1000).default(''),
});
export type ReceiptReview = z.infer<typeof receiptReviewSchema>;

export const enrollmentRequestSchema = z.object({
  enrollmentCode: z.string().regex(/^[A-Z0-9]{8}$/),
  deviceName: z.string().trim().min(1).max(80),
  appVersion: z.string().min(1).max(32),
});

export const pilotRequestSchema = z.object({
  name: z.string().trim().min(2).max(100),
  company: z.string().trim().min(2).max(160),
  email: z.string().trim().email().max(254),
  phone: z.string().trim().max(24).default(''),
  message: z.string().trim().max(1000).default(''),
  turnstileToken: z.string().min(1).max(4096),
  website: z.string().max(0).default(''),
});

export type BootstrapResponse = {
  site: { id: string; name: string };
  device: { id: string; name: string };
  vendors: Vendor[];
  allowedWifiSsids: string[];
  configurationVersion: number;
  limits: { dailyReceipts: number; imageBytes: number };
};

export type ReceiptListItem = {
  id: string;
  vendorId: string;
  vendorName: string;
  capturedAtUnix: number;
  capturedQuantity: number;
  status: ReceiptStatus;
  version: number;
  imageUrl: string;
  challanNumber: string;
  materialDescription: string;
  verifiedQuantity: number | null;
  unit: string;
  notes: string;
};
