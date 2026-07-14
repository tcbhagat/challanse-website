export interface Env {
  DB: D1Database;
  RECEIPTS: R2Bucket;
  RECEIPT_QUEUE: Queue<ReceiptQueueMessage>;
  ALLOWED_ORIGINS: string;
  ACCESS_TEAM_DOMAIN: string;
  ACCESS_AUD: string;
  DEVICE_TOKEN_PEPPER: string;
  TURNSTILE_SECRET: string;
  ENVIRONMENT: string;
}

export type ReceiptQueueMessage = {
  receiptId: string;
  siteId: string;
};

export type DeviceIdentity = {
  id: string;
  siteId: string;
  name: string;
};

export type ReviewerIdentity = {
  email: string;
  siteId: string;
  role: 'ADMIN' | 'CONTROLLER';
};
