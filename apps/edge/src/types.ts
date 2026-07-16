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
  ENRICHMENT_URL?: string;
  EDGE_TO_ENRICHMENT_HMAC_KEY_ID?: string;
  EDGE_TO_ENRICHMENT_HMAC_KEY?: string;
  EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID?: string;
  EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY?: string;
  ENRICHMENT_TO_EDGE_HMAC_KEY_ID?: string;
  ENRICHMENT_TO_EDGE_HMAC_KEY?: string;
  ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID?: string;
  ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY?: string;
  ENRICHMENT_ACCESS_CLIENT_ID?: string;
  ENRICHMENT_ACCESS_CLIENT_SECRET?: string;
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
