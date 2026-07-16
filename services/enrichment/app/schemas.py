from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field


class ReceiptEvent(BaseModel):
    receipt_id: str
    site_id: str
    image_key: str
    vendor_id: str
    captured_at_unix: int
    site_captured_quantity: float
    image_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    image_bytes: int = Field(gt=0, le=750_000)
    schema_version: Literal["1.0"] = "1.0"


class AAFIData(BaseModel):
    schema_version: Literal["AA_1.0.0"] = "AA_1.0.0"
    msme_udyam_number: str | None = None
    recipient_bank_account: str | None = None
    developer_gst_number: str
    irn_hash: str
    material_description: str
    verified_quantity: float
    site_geo_hash: str
    timestamp_iso8601: str
    cryptographic_signature: str


class EnrichmentResult(BaseModel):
    receipt_id: str
    status: Literal[
        "PENDING",
        "QUEUED",
        "PROCESSING",
        "READY_FOR_REVIEW",
        "NEEDS_HUMAN_REVIEW",
        "VERIFIED_GST",
        "GST_ANOMALY",
        "FAILED_RETRYABLE",
        "FAILED_TERMINAL",
    ]
    ocr_confidence: float | None = None
    raw_ocr_json: dict[str, Any] = Field(default_factory=dict)
    gst_status: str = "NOT_CHECKED"
    version: int = 1


class GstReceiptContext(BaseModel):
    receipt_id: str
    vendor_gst_number: str | None = None
    developer_gst_number: str | None = None
    timestamp_unix: int
    site_captured_quantity: float | None = None
    material_description: str = ""
    site_geo_hash: str = ""
    msme_udyam_number: str | None = None
    recipient_bank_account: str | None = None


class TallyImportRequest(BaseModel):
    site_id: str
    imported_by: str
    csv_content: str = Field(min_length=1, max_length=1_000_000)


class SiteQuery(BaseModel):
    site_id: str


class EnrichmentStatusQuery(SiteQuery):
    receipt_id: UUID | None = None


class SiteManagerCommand(SiteQuery):
    manager_id: str = Field(min_length=3, max_length=254)
    active: bool = True


class VerifiedReviewEvent(BaseModel):
    receipt_id: str
    site_id: str
    po_number: str = Field(min_length=1, max_length=120)
    material_code: str = Field(min_length=1, max_length=120)
    verified_quantity: float = Field(gt=0)
    unit: str = Field(min_length=1, max_length=24)
    reviewer_id: str = Field(min_length=1, max_length=254)
    review_version: int = Field(gt=0)
    reviewed_at_iso8601: str
    schema_version: Literal["1.0"] = "1.0"


class TelemetryMeasurement(BaseModel):
    source_event_id: str = Field(min_length=3, max_length=160)
    site_id: str
    vendor_id: str | None = None
    metric_name: Literal["frontend_write_duration_ms", "sync_failure_rate"]
    metric_value: float = Field(ge=0)
    sample_count: int = Field(gt=0, le=10_000)
    period_start: datetime
    period_end: datetime


class TelemetryBatch(BaseModel):
    measurements: list[TelemetryMeasurement] = Field(min_length=1, max_length=100)
