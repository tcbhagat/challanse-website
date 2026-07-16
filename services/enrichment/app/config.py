from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    environment: str = Field(default="development", alias="ENVIRONMENT")
    database_url: str = Field(default="", alias="DATABASE_URL")
    system_database_url: str = Field(default="", alias="SYSTEM_DATABASE_URL")
    database_admin_url: str = Field(default="", alias="DATABASE_ADMIN_URL")
    database_app_password: str = Field(default="", alias="DATABASE_APP_PASSWORD")
    database_system_password: str = Field(default="", alias="DATABASE_SYSTEM_PASSWORD")
    aws_region: str = Field(default="ap-south-1", alias="AWS_REGION")
    receipt_queue_url: str = Field(default="", alias="RECEIPT_QUEUE_URL")
    receipt_bucket: str = Field(default="", alias="RECEIPT_BUCKET")
    credit_queue_url: str = Field(default="", alias="CREDIT_QUEUE_URL")
    edge_to_enrichment_key_id: str = Field(default="", alias="EDGE_TO_ENRICHMENT_HMAC_KEY_ID")
    edge_to_enrichment_key: str = Field(default="", alias="EDGE_TO_ENRICHMENT_HMAC_KEY")
    edge_to_enrichment_next_key_id: str = Field(default="", alias="EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID")
    edge_to_enrichment_next_key: str = Field(default="", alias="EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY")
    enrichment_to_edge_key_id: str = Field(default="", alias="ENRICHMENT_TO_EDGE_HMAC_KEY_ID")
    enrichment_to_edge_key: str = Field(default="", alias="ENRICHMENT_TO_EDGE_HMAC_KEY")
    enrichment_to_edge_next_key_id: str = Field(default="", alias="ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID")
    enrichment_to_edge_next_key: str = Field(default="", alias="ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY")
    cloudflare_access_client_id: str = Field(default="", alias="CLOUDFLARE_ACCESS_CLIENT_ID")
    cloudflare_access_client_secret: str = Field(default="", alias="CLOUDFLARE_ACCESS_CLIENT_SECRET")
    device_token_pepper: str = Field(default="", alias="DEVICE_TOKEN_PEPPER")
    tenant_context_hmac_key: str = Field(default="", alias="TENANT_CONTEXT_HMAC_KEY")
    kms_key_arn: str = Field(default="", alias="KMS_KEY_ARN")
    ocr_provider: Literal["disabled", "mock", "textract"] = Field(default="disabled", alias="OCR_PROVIDER")
    gst_provider: Literal["disabled", "mock", "http"] = Field(default="disabled", alias="GST_PROVIDER")
    notification_provider: Literal["disabled", "mock", "whatsapp"] = Field(default="disabled", alias="NOTIFICATION_PROVIDER")
    credit_provider: Literal["disabled", "mock", "sqs"] = Field(default="disabled", alias="CREDIT_PROVIDER")
    slack_provider: Literal["disabled", "mock", "webhook"] = Field(default="disabled", alias="SLACK_PROVIDER")
    event_queue_provider: Literal["disabled", "memory", "sqs"] = Field(default="disabled", alias="EVENT_QUEUE_PROVIDER")
    gst_api_url: str = Field(default="https://mock-gst-portal.in/api/irn", alias="GST_API_URL")
    gst_timeout_seconds: float = Field(default=3.0, alias="GST_TIMEOUT_SECONDS")
    otel_service_name: str = Field(default="challanse-enrichment", alias="OTEL_SERVICE_NAME")
    otel_exporter_otlp_endpoint: str = Field(default="", alias="OTEL_EXPORTER_OTLP_ENDPOINT")
    image_byte_limit: int = Field(default=5_000_000, alias="IMAGE_BYTE_LIMIT")
    review_dashboard_url: str = Field(default="https://review.challanse.constrovet.com", alias="REVIEW_DASHBOARD_URL")
    public_api_url: str = Field(default="https://api.challanse.constrovet.com", alias="PUBLIC_API_URL")
    play_integrity_provider: Literal["disabled", "google"] = Field(default="disabled", alias="PLAY_INTEGRITY_PROVIDER")
    play_integrity_credentials_json: str = Field(default="", alias="PLAY_INTEGRITY_CREDENTIALS_JSON")
    play_integrity_cloud_project_number: int = Field(default=0, alias="PLAY_INTEGRITY_CLOUD_PROJECT_NUMBER")

    def incoming_hmac_keys(self) -> dict[str, str]:
        keys = {self.edge_to_enrichment_key_id: self.edge_to_enrichment_key}
        if self.edge_to_enrichment_next_key_id and self.edge_to_enrichment_next_key:
            keys[self.edge_to_enrichment_next_key_id] = self.edge_to_enrichment_next_key
        return {key_id: secret for key_id, secret in keys.items() if key_id and secret}

    def production_errors(self) -> list[str]:
        if self.environment != "production":
            return []
        required = {
            "DATABASE_URL": self.database_url,
            "SYSTEM_DATABASE_URL": self.system_database_url,
            "RECEIPT_QUEUE_URL": self.receipt_queue_url,
            "RECEIPT_BUCKET": self.receipt_bucket,
            "EDGE_TO_ENRICHMENT_HMAC_KEY_ID": self.edge_to_enrichment_key_id,
            "EDGE_TO_ENRICHMENT_HMAC_KEY": self.edge_to_enrichment_key,
            "EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID": self.edge_to_enrichment_next_key_id,
            "EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY": self.edge_to_enrichment_next_key,
            "ENRICHMENT_TO_EDGE_HMAC_KEY_ID": self.enrichment_to_edge_key_id,
            "ENRICHMENT_TO_EDGE_HMAC_KEY": self.enrichment_to_edge_key,
            "ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID": self.enrichment_to_edge_next_key_id,
            "ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY": self.enrichment_to_edge_next_key,
            "CLOUDFLARE_ACCESS_CLIENT_ID": self.cloudflare_access_client_id,
            "CLOUDFLARE_ACCESS_CLIENT_SECRET": self.cloudflare_access_client_secret,
            "DEVICE_TOKEN_PEPPER": self.device_token_pepper,
            "TENANT_CONTEXT_HMAC_KEY": self.tenant_context_hmac_key,
            "KMS_KEY_ARN": self.kms_key_arn,
            "PLAY_INTEGRITY_CREDENTIALS_JSON": self.play_integrity_credentials_json,
        }
        errors = [f"{name}_missing" for name, value in required.items() if not value]
        if self.database_url and self.system_database_url and self.database_url == self.system_database_url:
            errors.append("SYSTEM_DATABASE_URL_must_use_distinct_bypassrls_role")
        if self.event_queue_provider != "sqs":
            errors.append("EVENT_QUEUE_PROVIDER_must_be_sqs")
        if self.ocr_provider != "textract":
            errors.append("OCR_PROVIDER_must_be_textract")
        if self.play_integrity_provider != "google":
            errors.append("PLAY_INTEGRITY_PROVIDER_must_be_google")
        if self.play_integrity_cloud_project_number <= 0:
            errors.append("PLAY_INTEGRITY_CLOUD_PROJECT_NUMBER_missing")
        for provider_name in ("gst_provider", "notification_provider", "credit_provider", "slack_provider"):
            if getattr(self, provider_name) != "disabled":
                errors.append(f"{provider_name.upper()}_must_be_disabled")
        if self.gst_timeout_seconds != 3.0:
            errors.append("GST_TIMEOUT_SECONDS_must_equal_3")
        if self.gst_provider != "disabled" and self.credit_provider != "sqs":
            errors.append("CREDIT_PROVIDER_must_be_sqs_when_GST_is_enabled")
        if self.credit_provider == "sqs" and not self.credit_queue_url:
            errors.append("CREDIT_QUEUE_URL_missing")
        if self.credit_provider == "sqs" and not self.credit_queue_url.endswith(".fifo"):
            errors.append("CREDIT_QUEUE_URL_must_be_fifo")
        for provider_name in ("ocr_provider", "gst_provider", "notification_provider", "credit_provider", "slack_provider"):
            if getattr(self, provider_name) == "mock":
                errors.append(f"{provider_name.upper()}_mock_forbidden")
        return errors


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
