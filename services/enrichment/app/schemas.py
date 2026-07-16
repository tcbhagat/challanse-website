from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field
from pydantic import ConfigDict


class ApiModel(BaseModel):
    model_config = ConfigDict(populate_by_name=True)


class EnrollmentRequest(ApiModel):
    enrollment_code: str = Field(alias="enrollmentCode", pattern=r"^[A-HJ-NP-Z2-9]{8}$")
    device_name: str = Field(alias="deviceName", min_length=1, max_length=80)
    app_version: str = Field(alias="appVersion", min_length=1, max_length=32)


class UploadSessionRequest(ApiModel):
    receipt_id: UUID = Field(alias="receiptId")
    vendor_id: str = Field(alias="vendorId", min_length=1, max_length=64)
    captured_at_unix: int = Field(alias="capturedAtUnix", gt=0)
    captured_quantity: float = Field(alias="capturedQuantity", gt=0, le=1_000_000_000)
    image_sha256: str = Field(alias="imageSha256", pattern=r"^[a-f0-9]{64}$")
    app_version: str = Field(alias="appVersion", min_length=1, max_length=32)
    configuration_version: int = Field(alias="configurationVersion", ge=0)
    total_bytes: int = Field(alias="totalBytes", gt=0, le=5_000_000)
    mime_type: Literal["image/webp"] = Field(alias="mimeType")


class ReceiptReviewRequest(ApiModel):
    action: Literal["VERIFY", "REJECT"]
    version: int = Field(gt=0)
    challan_number: str = Field(default="", alias="challanNumber", max_length=120)
    po_number: str = Field(alias="poNumber", min_length=1, max_length=120)
    material_code: str = Field(alias="materialCode", min_length=1, max_length=120)
    material_description: str = Field(alias="materialDescription", min_length=1, max_length=500)
    verified_quantity: float = Field(alias="verifiedQuantity", gt=0, le=1_000_000_000)
    unit: str = Field(min_length=1, max_length=24)
    notes: str = Field(default="", max_length=1000)


class PilotRequest(ApiModel):
    name: str = Field(min_length=2, max_length=100)
    company: str = Field(min_length=2, max_length=160)
    email: str = Field(min_length=5, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
    phone: str = Field(default="", max_length=24)
    message: str = Field(default="", max_length=1000)
    website: str = Field(default="", max_length=0)


class SiteAdminRequest(ApiModel):
    site_id: UUID | None = Field(default=None, alias="siteId")
    name: str = Field(min_length=2, max_length=160)
    allowed_wifi_ssids: list[str] = Field(default_factory=list, alias="allowedWifiSsids", max_length=20)
    daily_receipt_limit: int = Field(default=1000, alias="dailyReceiptLimit", gt=0, le=100_000)
    image_byte_limit: int = Field(default=5_000_000, alias="imageByteLimit", ge=100_000, le=5_000_000)
    active: bool = True


class VendorAdminRequest(ApiModel):
    vendor_id: str = Field(alias="vendorId", min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._-]+$")
    name: str = Field(min_length=2, max_length=160)
    initials: str = Field(min_length=1, max_length=3)
    color: str = Field(pattern=r"^#[0-9A-Fa-f]{6}$")
    display_order: int = Field(default=0, alias="displayOrder", ge=0, le=1000)
    active: bool = True


class MembershipAdminRequest(ApiModel):
    issuer: str = Field(min_length=8, max_length=500)
    subject: str = Field(min_length=1, max_length=500)
    email: str = Field(min_length=5, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
    display_name: str = Field(default="", alias="displayName", max_length=160)
    role: Literal["ORG_ADMIN", "SITE_ADMIN", "CONTROLLER", "REVIEWER", "AUDITOR"]
    site_ids: list[UUID] = Field(default_factory=list, alias="siteIds", max_length=100)
    active: bool = True


class MembershipInvitationRequest(ApiModel):
    email: str = Field(min_length=5, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
    display_name: str = Field(default="", alias="displayName", max_length=160)
    role: Literal["ORG_ADMIN", "SITE_ADMIN", "CONTROLLER", "REVIEWER", "AUDITOR"]
    site_ids: list[UUID] = Field(default_factory=list, alias="siteIds", max_length=100)


class MembershipInvitationAcceptance(ApiModel):
    invitation_code: str = Field(alias="invitationCode", min_length=16, max_length=128)


class QuotaAdminRequest(ApiModel):
    device_limit: int = Field(alias="deviceLimit", gt=0, le=1000)
    device_request_limit_per_minute: int = Field(alias="deviceRequestLimitPerMinute", ge=30, le=600)
    daily_receipt_limit: int = Field(alias="dailyReceiptLimit", gt=0, le=100_000)
    storage_byte_limit: int = Field(alias="storageByteLimit", ge=100_000_000, le=10_000_000_000_000)


class RevokeAllDevicesRequest(ApiModel):
    confirmation: str = Field(min_length=10, max_length=200)


class ReceiptEvent(BaseModel):
    receipt_id: str
    organization_id: str
    site_id: str
    image_key: str
    vendor_id: str
    captured_at_unix: int
    site_captured_quantity: float
    image_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    image_bytes: int = Field(gt=0, le=5_000_000)
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
    organization_id: str
    site_id: str
    imported_by: str
    csv_content: str = Field(min_length=1, max_length=1_000_000)


class SiteQuery(BaseModel):
    organization_id: str
    site_id: str


class EnrichmentStatusQuery(SiteQuery):
    receipt_id: UUID | None = None


class SiteManagerCommand(SiteQuery):
    manager_id: str = Field(min_length=3, max_length=254)
    active: bool = True


class VerifiedReviewEvent(BaseModel):
    receipt_id: str
    organization_id: str
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
    organization_id: str
    site_id: str
    vendor_id: str | None = None
    metric_name: Literal["frontend_write_duration_ms", "sync_failure_rate"]
    metric_value: float = Field(ge=0)
    sample_count: int = Field(gt=0, le=10_000)
    period_start: datetime
    period_end: datetime


class TelemetryBatch(BaseModel):
    measurements: list[TelemetryMeasurement] = Field(min_length=1, max_length=100)
