export interface Env {
  ALLOWED_ORIGINS: string;
  ACCESS_TEAM_DOMAIN: string;
  ACCESS_AUD: string;
  TURNSTILE_SECRET: string;
  ENVIRONMENT: string;
  ENRICHMENT_URL?: string;
  EDGE_TO_ENRICHMENT_HMAC_KEY_ID?: string;
  EDGE_TO_ENRICHMENT_HMAC_KEY?: string;
  EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID?: string;
  EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY?: string;
  ENRICHMENT_ACCESS_CLIENT_ID?: string;
  ENRICHMENT_ACCESS_CLIENT_SECRET?: string;
}

export type AccessIdentity = {
  issuer: string;
  subject: string;
  email: string;
};
