import csv
import base64
import hashlib
import io
import json
import logging
import secrets
import time
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

import boto3
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .config import Settings
from .image_store import delete_all_object_versions
from .schemas import (
    EnrollmentRequest,
    MembershipAdminRequest,
    MembershipInvitationAcceptance,
    MembershipInvitationRequest,
    QuotaAdminRequest,
    ReceiptEvent,
    ReceiptReviewRequest,
    RevokeAllDevicesRequest,
    SiteAdminRequest,
    UploadSessionRequest,
    VendorAdminRequest,
)
from .tenancy import system_connection, tenant_connection


UPLOAD_PART_SIZE = 256_000
logger = logging.getLogger("challanse.enrichment.authoritative")


class AuthoritativeError(RuntimeError):
    def __init__(self, code: str, status_code: int = 400) -> None:
        super().__init__(code)
        self.code = code
        self.status_code = status_code


@dataclass(frozen=True)
class DeviceContext:
    id: UUID
    organization_id: UUID
    site_id: UUID
    name: str


@dataclass(frozen=True)
class ReviewerContext:
    user_id: UUID
    organization_id: UUID
    site_id: UUID
    role: str
    email: str
    issuer: str
    subject: str


def _token_hash(token: str, pepper: str) -> str:
    return hashlib.sha256(f"{token}:{pepper}".encode()).hexdigest()


def authenticate_device(settings: Settings, authorization: str) -> DeviceContext:
    if not settings.device_token_pepper or not authorization.startswith("Bearer "):
        raise AuthoritativeError("DEVICE_UNAUTHORIZED", 401)
    token = authorization.removeprefix("Bearer ").strip()
    if len(token) < 32:
        raise AuthoritativeError("DEVICE_UNAUTHORIZED", 401)
    with system_connection(settings.database_url, row_factory=dict_row) as connection:
        row = connection.execute(
            """
            SELECT d.id, d.organization_id, d.site_id, d.name
            FROM devices d
            JOIN organizations o ON o.id = d.organization_id AND o.active
            JOIN sites s ON s.id = d.site_id AND s.organization_id = d.organization_id AND s.active
            WHERE d.token_hash = %s AND d.active
            """,
            (_token_hash(token, settings.device_token_pepper),),
        ).fetchone()
        if row:
            connection.execute("UPDATE devices SET last_seen_at = NOW() WHERE id = %s", (row["id"],))
            connection.commit()
    if not row:
        raise AuthoritativeError("DEVICE_UNAUTHORIZED", 401)
    return DeviceContext(UUID(str(row["id"])), UUID(str(row["organization_id"])), UUID(str(row["site_id"])), str(row["name"]))


def consume_device_nonce(settings: Settings, device: DeviceContext, timestamp: str, nonce: str) -> None:
    try:
        timestamp_number = int(timestamp)
    except ValueError as error:
        raise AuthoritativeError("REPLAY_REJECTED", 409) from error
    if abs(int(time.time()) - timestamp_number) > 60 or not 16 <= len(nonce) <= 128:
        raise AuthoritativeError("REPLAY_REJECTED", 409)
    nonce_hash = hashlib.sha256(f"{device.id}:{nonce}".encode()).hexdigest()
    with tenant_connection(settings.database_url, str(device.organization_id)) as connection:
        connection.execute("DELETE FROM device_request_nonces WHERE expires_at < NOW()")
        connection.execute("DELETE FROM device_rate_limit_windows WHERE window_started_at < NOW() - INTERVAL '10 minutes'")
        accepted = connection.execute(
            """
            INSERT INTO device_request_nonces (nonce_hash, organization_id, device_id, expires_at)
            VALUES (%s, %s, %s, NOW() + INTERVAL '10 minutes')
            ON CONFLICT DO NOTHING RETURNING nonce_hash
            """,
            (nonce_hash, device.organization_id, device.id),
        ).fetchone()
        if accepted is None:
            connection.rollback()
            raise AuthoritativeError("REPLAY_REJECTED", 409)
        request_limit = connection.execute(
            "SELECT device_request_limit_per_minute FROM organizations WHERE id = %s AND active",
            (device.organization_id,),
        ).fetchone()
        if not request_limit:
            connection.rollback()
            raise AuthoritativeError("ORGANIZATION_INACTIVE", 403)
        rate_accepted = connection.execute(
            """
            INSERT INTO device_rate_limit_windows
              (organization_id, device_id, window_started_at, request_count)
            VALUES (%s, %s, date_trunc('minute', NOW()), 1)
            ON CONFLICT (device_id, window_started_at) DO UPDATE
              SET request_count = device_rate_limit_windows.request_count + 1
              WHERE device_rate_limit_windows.request_count < %s
            RETURNING request_count
            """,
            (device.organization_id, device.id, int(request_limit[0])),
        ).fetchone()
        if rate_accepted is None:
            connection.rollback()
            raise AuthoritativeError("DEVICE_RATE_LIMITED", 429)
        connection.commit()


def enroll_device(settings: Settings, request: EnrollmentRequest) -> dict[str, str]:
    if not settings.device_token_pepper:
        raise AuthoritativeError("DEVICE_ENROLLMENT_UNCONFIGURED", 503)
    code_hash = hashlib.sha256(request.enrollment_code.encode()).hexdigest()
    device_id = uuid4()
    token = secrets.token_urlsafe(32)
    with system_connection(settings.database_url, row_factory=dict_row) as connection:
        enrollment = connection.execute(
            """
            SELECT e.organization_id, e.site_id, e.device_name, o.device_limit
            FROM enrollment_codes e
            JOIN organizations o ON o.id = e.organization_id AND o.active
            JOIN sites s ON s.id = e.site_id AND s.organization_id = e.organization_id AND s.active
            WHERE e.code_hash = %s AND e.used_at IS NULL AND e.expires_at > NOW()
            FOR UPDATE OF e, o
            """,
            (code_hash,),
        ).fetchone()
        if not enrollment:
            raise AuthoritativeError("ENROLLMENT_EXPIRED", 410)
        active_devices = connection.execute(
            "SELECT COUNT(*) AS active_count FROM devices WHERE organization_id = %s AND active",
            (enrollment["organization_id"],),
        ).fetchone()["active_count"]
        if int(active_devices) >= int(enrollment["device_limit"]):
            raise AuthoritativeError("DEVICE_LIMIT", 409)
        connection.execute(
            """
            INSERT INTO devices (id, organization_id, site_id, name, token_hash, app_version)
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (
                device_id, enrollment["organization_id"], enrollment["site_id"],
                request.device_name or enrollment["device_name"],
                _token_hash(token, settings.device_token_pepper), request.app_version,
            ),
        )
        updated = connection.execute(
            "UPDATE enrollment_codes SET used_at = NOW() WHERE code_hash = %s AND used_at IS NULL RETURNING code_hash",
            (code_hash,),
        ).fetchone()
        if not updated:
            raise AuthoritativeError("ENROLLMENT_ALREADY_USED", 409)
        connection.commit()
    return {"deviceId": str(device_id), "deviceToken": token}


def mobile_bootstrap(settings: Settings, device: DeviceContext) -> dict[str, Any]:
    with tenant_connection(settings.database_url, str(device.organization_id), row_factory=dict_row) as connection:
        site = connection.execute(
            """
            SELECT id, name, allowed_wifi_ssids, configuration_version, daily_receipt_limit, image_byte_limit
            FROM sites WHERE id = %s AND active
            """,
            (device.site_id,),
        ).fetchone()
        vendors = connection.execute(
            "SELECT id, name, initials, color FROM vendors WHERE site_id = %s AND active ORDER BY display_order, name",
            (device.site_id,),
        ).fetchall()
    if not site:
        raise AuthoritativeError("SITE_INACTIVE", 403)
    return {
        "site": {"id": str(site["id"]), "name": site["name"]},
        "device": {"id": str(device.id), "name": device.name},
        "vendors": [dict(vendor) for vendor in vendors],
        "allowedWifiSsids": list(site["allowed_wifi_ssids"]),
        "configurationVersion": int(site["configuration_version"]),
        "limits": {"dailyReceipts": int(site["daily_receipt_limit"]), "imageBytes": int(site["image_byte_limit"])},
        "retention": {"acknowledgedDeviceGraceDays": 7, "imageDays": 90, "receiptDays": 365},
    }


def _s3(settings: Settings, client=None):
    if not settings.receipt_bucket:
        raise AuthoritativeError("RECEIPT_BUCKET_UNCONFIGURED", 503)
    return client or boto3.client("s3", region_name=settings.aws_region)


def _s3_put(
    settings: Settings,
    key: str,
    body: bytes,
    content_type: str,
    metadata: dict[str, str],
    client=None,
    retention_tag: bool = False,
) -> None:
    encryption_context = {
        "organization_id": metadata.get("organization-id", "unknown"),
        "site_id": metadata.get("site-id", "unknown"),
        "object_key": key,
    }
    request: dict[str, Any] = {
        "Bucket": settings.receipt_bucket,
        "Key": key,
        "Body": body,
        "ContentType": content_type,
        "CacheControl": "private, no-store",
        "ServerSideEncryption": "aws:kms",
        "SSEKMSKeyId": settings.kms_key_arn,
        "SSEKMSEncryptionContext": base64.b64encode(json.dumps(encryption_context, separators=(",", ":")).encode()).decode(),
        "Metadata": metadata,
    }
    if retention_tag:
        request["Tagging"] = "retention=receipt-image"
    _s3(settings, client).put_object(
        **request,
    )


def _s3_get(settings: Settings, key: str, client=None) -> bytes:
    response = _s3(settings, client).get_object(Bucket=settings.receipt_bucket, Key=key)
    return bytes(response["Body"].read())


def create_upload_session(
    settings: Settings,
    device: DeviceContext,
    request: UploadSessionRequest,
    integrity_status: str = "UNAVAILABLE",
) -> dict[str, Any]:
    with tenant_connection(settings.database_url, str(device.organization_id), row_factory=dict_row) as connection:
        receipt = connection.execute(
            """
            SELECT id, status, image_sha256 FROM receipts
            WHERE organization_id = %s AND site_id = %s AND device_id = %s AND id = %s
            """,
            (device.organization_id, device.site_id, device.id, request.receipt_id),
        ).fetchone()
        if receipt:
            if str(receipt["image_sha256"]) != request.image_sha256:
                raise AuthoritativeError("RECEIPT_CHECKSUM_CONFLICT", 409)
            return {"receiptId": str(receipt["id"]), "status": receipt["status"], "complete": True}
        existing = connection.execute(
            """
            SELECT id, status, image_sha256 FROM upload_sessions
            WHERE organization_id = %s AND site_id = %s AND device_id = %s AND receipt_id = %s
            """,
            (device.organization_id, device.site_id, device.id, request.receipt_id),
        ).fetchone()
        if existing:
            if str(existing["image_sha256"]) != request.image_sha256:
                raise AuthoritativeError("UPLOAD_CHECKSUM_CONFLICT", 409)
            return {"uploadId": str(existing["id"]), "receiptId": str(request.receipt_id), "status": existing["status"], "partSize": UPLOAD_PART_SIZE}
        policy = connection.execute(
            """
            SELECT s.image_byte_limit, o.storage_byte_limit, o.stored_image_bytes
            FROM sites s JOIN organizations o ON o.id = s.organization_id
            WHERE s.id = %s AND s.organization_id = %s AND s.active AND o.active
            """,
            (device.site_id, device.organization_id),
        ).fetchone()
        if not policy:
            raise AuthoritativeError("SITE_INACTIVE", 403)
        if request.total_bytes > int(policy["image_byte_limit"]):
            raise AuthoritativeError("IMAGE_TOO_LARGE", 413)
        if int(policy["stored_image_bytes"]) + request.total_bytes > int(policy["storage_byte_limit"]) * 0.9:
            raise AuthoritativeError("TENANT_STORAGE_PAUSED", 507)
        vendor = connection.execute(
            "SELECT id FROM vendors WHERE organization_id = %s AND site_id = %s AND id = %s AND active",
            (device.organization_id, device.site_id, request.vendor_id),
        ).fetchone()
        if not vendor:
            raise AuthoritativeError("INVALID_VENDOR", 400)
        upload_id = uuid4()
        connection.execute(
            """
            INSERT INTO upload_sessions
              (id, receipt_id, organization_id, site_id, device_id, vendor_id, metadata_json,
               total_bytes, image_sha256, mime_type, expires_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, NOW() + INTERVAL '24 hours')
            """,
            (
                upload_id, request.receipt_id, device.organization_id, device.site_id, device.id,
                request.vendor_id, Jsonb(request.model_dump(mode="json", by_alias=False)),
                request.total_bytes, request.image_sha256, request.mime_type,
            ),
        )
        connection.execute(
            "UPDATE upload_sessions SET integrity_status = %s WHERE id = %s",
            (integrity_status, upload_id),
        )
        connection.commit()
    return {"uploadId": str(upload_id), "receiptId": str(request.receipt_id), "status": "OPEN", "partSize": UPLOAD_PART_SIZE}


def get_upload_session(settings: Settings, device: DeviceContext, upload_id: UUID) -> dict[str, Any]:
    with tenant_connection(settings.database_url, str(device.organization_id), row_factory=dict_row) as connection:
        session = connection.execute(
            """
            SELECT id, receipt_id, total_bytes, status FROM upload_sessions
            WHERE id = %s AND organization_id = %s AND site_id = %s AND device_id = %s
            """,
            (upload_id, device.organization_id, device.site_id, device.id),
        ).fetchone()
        if not session:
            raise AuthoritativeError("UPLOAD_NOT_FOUND", 404)
        parts = connection.execute(
            "SELECT part_number, byte_offset, byte_length, sha256 FROM upload_parts WHERE upload_id = %s ORDER BY part_number",
            (upload_id,),
        ).fetchall()
    return {
        "uploadId": str(upload_id), "receiptId": str(session["receipt_id"]), "status": session["status"],
        "totalBytes": int(session["total_bytes"]), "uploadedBytes": sum(int(part["byte_length"]) for part in parts),
        "parts": [
            {"partNumber": int(part["part_number"]), "byteOffset": int(part["byte_offset"]), "byteLength": int(part["byte_length"]), "sha256": part["sha256"]}
            for part in parts
        ],
    }


def put_upload_part(settings: Settings, device: DeviceContext, upload_id: UUID, part_number: int, body: bytes, declared_hash: str, s3_client=None) -> None:
    with tenant_connection(settings.database_url, str(device.organization_id), row_factory=dict_row) as connection:
        connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
            (f"upload-part:{upload_id}:{part_number}",),
        )
        session = connection.execute(
            """
            SELECT total_bytes, status FROM upload_sessions
            WHERE id = %s AND organization_id = %s AND site_id = %s AND device_id = %s AND expires_at > NOW()
            """,
            (upload_id, device.organization_id, device.site_id, device.id),
        ).fetchone()
        if not session or session["status"] != "OPEN":
            raise AuthoritativeError("UPLOAD_NOT_OPEN", 409)
        expected_offset = part_number * UPLOAD_PART_SIZE
        expected_length = min(UPLOAD_PART_SIZE, int(session["total_bytes"]) - expected_offset)
        if part_number < 0 or expected_offset >= int(session["total_bytes"]):
            raise AuthoritativeError("PART_OUT_OF_RANGE", 416)
        if len(body) != expected_length:
            raise AuthoritativeError("PART_LENGTH_MISMATCH", 400)
        actual_hash = hashlib.sha256(body).hexdigest()
        if actual_hash != declared_hash:
            raise AuthoritativeError("PART_CHECKSUM_MISMATCH", 422)
        existing = connection.execute(
            "SELECT sha256, byte_length FROM upload_parts WHERE upload_id = %s AND part_number = %s",
            (upload_id, part_number),
        ).fetchone()
        if existing:
            if existing["sha256"] != actual_hash or int(existing["byte_length"]) != len(body):
                raise AuthoritativeError("PART_CONFLICT", 409)
            return
        object_key = f"{device.organization_id}/{device.site_id}/uploads/{upload_id}/part-{part_number:04d}"
        _s3_put(
            settings,
            object_key,
            body,
            "application/octet-stream",
            {"sha256": actual_hash, "organization-id": str(device.organization_id), "site-id": str(device.site_id)},
            s3_client,
        )
        connection.execute(
            """
            INSERT INTO upload_parts
              (upload_id, organization_id, part_number, byte_offset, byte_length, sha256, object_key)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            """,
            (upload_id, device.organization_id, part_number, expected_offset, len(body), actual_hash, object_key),
        )
        connection.commit()


def _is_webp(body: bytes) -> bool:
    return len(body) >= 12 and body[:4] == b"RIFF" and body[8:12] == b"WEBP"


def _audit_hash(previous_hash: str, event: dict[str, Any]) -> str:
    canonical = json.dumps(event, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(f"{previous_hash}:{canonical}".encode()).hexdigest()


def _row_value(row: Any, key: str, index: int = 0) -> Any:
    return row[key] if isinstance(row, Mapping) else row[index]


def _set_upload_status(
    settings: Settings,
    organization_id: UUID,
    upload_id: UUID,
    expected_status: str,
    next_status: str,
) -> None:
    with tenant_connection(settings.database_url, str(organization_id)) as connection:
        connection.execute(
            """
            UPDATE upload_sessions SET status = %s, updated_at = NOW()
            WHERE id = %s AND organization_id = %s AND status = %s
            """,
            (next_status, upload_id, organization_id, expected_status),
        )
        connection.commit()


def complete_upload_session(settings: Settings, device: DeviceContext, upload_id: UUID, s3_client=None) -> dict[str, Any]:
    with tenant_connection(settings.database_url, str(device.organization_id), row_factory=dict_row) as connection:
        session = connection.execute(
            """
            UPDATE upload_sessions SET status = 'COMPLETING', updated_at = NOW()
            WHERE id = %s AND organization_id = %s AND site_id = %s AND device_id = %s AND status = 'OPEN'
            RETURNING *
            """,
            (upload_id, device.organization_id, device.site_id, device.id),
        ).fetchone()
        if not session:
            complete = connection.execute(
                "SELECT receipt_id, status FROM upload_sessions WHERE id = %s AND device_id = %s",
                (upload_id, device.id),
            ).fetchone()
            if complete and complete["status"] == "COMPLETE":
                return {"receiptId": str(complete["receipt_id"]), "status": "RECEIVED", "duplicate": True}
            raise AuthoritativeError("UPLOAD_NOT_OPEN", 409)
        parts = connection.execute(
            "SELECT part_number, byte_offset, byte_length, object_key FROM upload_parts WHERE upload_id = %s ORDER BY part_number",
            (upload_id,),
        ).fetchall()
        connection.commit()
    try:
        combined = bytearray()
        confirmed_offset = 0
        for part in parts:
            if int(part["byte_offset"]) != confirmed_offset:
                raise AuthoritativeError("UPLOAD_INCOMPLETE", 409)
            part_bytes = _s3_get(settings, str(part["object_key"]), s3_client)
            if len(part_bytes) != int(part["byte_length"]):
                raise AuthoritativeError("UPLOAD_PART_MISSING", 409)
            combined.extend(part_bytes)
            confirmed_offset += len(part_bytes)
        if len(combined) != int(session["total_bytes"]):
            raise AuthoritativeError("UPLOAD_INCOMPLETE", 409)
        body = bytes(combined)
    except Exception:
        _set_upload_status(settings, device.organization_id, upload_id, "COMPLETING", "OPEN")
        raise
    if not _is_webp(body):
        _set_upload_status(settings, device.organization_id, upload_id, "COMPLETING", "FAILED")
        raise AuthoritativeError("INVALID_IMAGE", 415)
    image_hash = hashlib.sha256(body).hexdigest()
    if image_hash != session["image_sha256"]:
        _set_upload_status(settings, device.organization_id, upload_id, "COMPLETING", "FAILED")
        raise AuthoritativeError("CHECKSUM_MISMATCH", 422)
    date_prefix = datetime.now(timezone.utc).date().isoformat()
    image_key = f"{device.organization_id}/{device.site_id}/{date_prefix}/{session['receipt_id']}.webp"
    with tenant_connection(settings.database_url, str(device.organization_id)) as connection:
        connection.execute(
            "UPDATE upload_sessions SET final_object_key = %s, updated_at = NOW() WHERE id = %s AND status = 'COMPLETING'",
            (image_key, upload_id),
        )
        connection.commit()
    _s3_put(
        settings, image_key, body, "image/webp",
        {"receipt-id": str(session["receipt_id"]), "organization-id": str(device.organization_id), "site-id": str(device.site_id), "sha256": image_hash},
        s3_client, True,
    )
    metadata = UploadSessionRequest.model_validate(session["metadata_json"])
    event = ReceiptEvent(
        receipt_id=str(metadata.receipt_id), organization_id=str(device.organization_id), site_id=str(device.site_id),
        image_key=image_key, vendor_id=metadata.vendor_id, captured_at_unix=metadata.captured_at_unix,
        site_captured_quantity=metadata.captured_quantity, image_sha256=image_hash, image_bytes=len(body),
    )
    quota_date = datetime.now(timezone.utc).date().isoformat()
    try:
        with tenant_connection(settings.database_url, str(device.organization_id), row_factory=dict_row) as connection:
            connection.execute(
                "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
                (f"receipt:{device.organization_id}:{session['receipt_id']}",),
            )
            locked = connection.execute(
                "SELECT status FROM upload_sessions WHERE id = %s AND device_id = %s FOR UPDATE",
                (upload_id, device.id),
            ).fetchone()
            if not locked or locked["status"] != "COMPLETING":
                raise AuthoritativeError("UPLOAD_COMPLETION_CONFLICT", 409)
            policy = connection.execute(
                """
                SELECT s.daily_receipt_limit AS site_daily_limit,
                       o.daily_receipt_limit AS organization_daily_limit,
                       o.storage_byte_limit
                FROM sites s JOIN organizations o ON o.id = s.organization_id
                WHERE s.id = %s AND s.organization_id = %s AND s.active AND o.active
                """,
                (device.site_id, device.organization_id),
            ).fetchone()
            connection.execute(
                "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
                (f"daily-organization:{device.organization_id}:{quota_date}",),
            )
            connection.execute(
                "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
                (f"daily-site:{device.organization_id}:{device.site_id}:{quota_date}",),
            )
            site_daily_count = connection.execute(
                "SELECT COUNT(*) AS receipt_count FROM receipts WHERE site_id = %s AND created_at >= CURRENT_DATE",
                (device.site_id,),
            ).fetchone()["receipt_count"]
            organization_daily_count = connection.execute(
                "SELECT COUNT(*) AS receipt_count FROM receipts WHERE organization_id = %s AND created_at >= CURRENT_DATE",
                (device.organization_id,),
            ).fetchone()["receipt_count"]
            if not policy:
                raise AuthoritativeError("SITE_INACTIVE", 403)
            if int(site_daily_count) >= int(policy["site_daily_limit"]):
                raise AuthoritativeError("DAILY_LIMIT", 429)
            if int(organization_daily_count) >= int(policy["organization_daily_limit"]):
                raise AuthoritativeError("TENANT_DAILY_LIMIT", 429)
            upload_storage_limit = int(int(policy["storage_byte_limit"]) * 0.9)
            quota = connection.execute(
                """
                UPDATE organizations SET stored_image_bytes = stored_image_bytes + %s, updated_at = NOW()
                WHERE id = %s AND active AND stored_image_bytes + %s <= %s
                RETURNING id
                """,
                (len(body), device.organization_id, len(body), upload_storage_limit),
            ).fetchone()
            if not quota:
                raise AuthoritativeError("TENANT_STORAGE_LIMIT", 507)
            connection.execute(
                """
                INSERT INTO receipts
                  (id, organization_id, site_id, device_id, vendor_id, captured_at_unix, captured_quantity,
                   image_key, image_bytes, image_sha256, status, integrity_status, app_version, configuration_version)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'RECEIVED', %s, %s, %s)
                """,
                (
                    metadata.receipt_id, device.organization_id, device.site_id, device.id, metadata.vendor_id,
                    metadata.captured_at_unix, metadata.captured_quantity, image_key, len(body), image_hash,
                    session["integrity_status"], metadata.app_version, metadata.configuration_version,
                ),
            )
            audit_body = {"event": "RECEIVED", "imageBytes": len(body), "resumable": True}
            connection.execute(
                "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
                (f"audit:{device.organization_id}:{device.site_id}",),
            )
            previous = connection.execute(
                "SELECT event_hash FROM audit_events WHERE organization_id = %s AND site_id = %s ORDER BY created_at DESC, id DESC LIMIT 1",
                (device.organization_id, device.site_id),
            ).fetchone()
            previous_hash = "" if previous is None else str(_row_value(previous, "event_hash"))
            connection.execute(
                """
                INSERT INTO audit_events
                  (id, organization_id, site_id, receipt_id, event_type, actor_type, actor_id, event_json, source_class, previous_hash, event_hash)
                VALUES (%s, %s, %s, %s, 'RECEIVED', 'DEVICE', %s, %s, 'cloudflare', %s, %s)
                """,
                (
                    uuid4(), device.organization_id, device.site_id, metadata.receipt_id, str(device.id),
                    Jsonb(audit_body), previous_hash or None, _audit_hash(previous_hash, audit_body),
                ),
            )
            connection.execute(
                """
                INSERT INTO transactional_outbox
                  (id, organization_id, aggregate_id, event_type, event_version, destination, idempotency_key, payload_json)
                VALUES (%s, %s, %s, 'RECEIPT_ENRICHMENT_QUEUE', 1, 'SQS', %s, %s)
                """,
                (uuid4(), device.organization_id, metadata.receipt_id, f"receipt-enrichment:{metadata.receipt_id}:1", Jsonb(event.model_dump(mode="json"))),
            )
            connection.execute("UPDATE upload_sessions SET status = 'COMPLETE', updated_at = NOW() WHERE id = %s", (upload_id,))
            connection.commit()
    except Exception:
        try:
            delete_all_object_versions(_s3(settings, s3_client), settings.receipt_bucket, image_key)
        except Exception as cleanup_error:
            logger.warning(
                "upload_final_object_cleanup_failed",
                extra={"error_code": type(cleanup_error).__name__},
            )
        _set_upload_status(settings, device.organization_id, upload_id, "COMPLETING", "OPEN")
        raise
    s3 = _s3(settings, s3_client)
    parts_cleaned = True
    for part in parts:
        try:
            delete_all_object_versions(s3, settings.receipt_bucket, str(part["object_key"]))
        except Exception as cleanup_error:
            parts_cleaned = False
            logger.warning(
                "upload_part_cleanup_failed",
                extra={"error_code": type(cleanup_error).__name__},
            )
    if parts_cleaned:
        with tenant_connection(settings.database_url, str(device.organization_id)) as connection:
            connection.execute("DELETE FROM upload_parts WHERE upload_id = %s", (upload_id,))
            connection.commit()
    return {"receiptId": str(metadata.receipt_id), "status": "RECEIVED", "duplicate": False}


def authenticate_reviewer(
    settings: Settings,
    issuer: str,
    subject: str,
    email: str,
    requested_site_id: str = "",
) -> ReviewerContext:
    if not issuer or not subject:
        raise AuthoritativeError("REVIEWER_UNAUTHORIZED", 401)
    rows = _reviewer_access_rows(settings, issuer, subject, email, requested_site_id)
    if not rows:
        raise AuthoritativeError("REVIEWER_UNAUTHORIZED", 401)
    if not requested_site_id and len(rows) > 1:
        raise AuthoritativeError("SITE_SELECTION_REQUIRED", 409)
    row = rows[0]
    return ReviewerContext(
        UUID(str(row["user_id"])), UUID(str(row["organization_id"])), UUID(str(row["site_id"])),
        str(row["role"]), email or str(row["email"]), issuer, subject,
    )


def _reviewer_access_rows(
    settings: Settings,
    issuer: str,
    subject: str,
    email: str,
    requested_site_id: str = "",
) -> list[dict[str, Any]]:
    with system_connection(settings.database_url, row_factory=dict_row) as connection:
        rows = connection.execute(
            """
            SELECT u.id AS user_id, om.organization_id, s.id AS site_id, s.name AS site_name,
                   CASE WHEN om.role = 'ORG_ADMIN' THEN om.role ELSE sm.role END AS role, u.email
            FROM identity_links i
            JOIN users u ON u.id = i.user_id AND u.active
            JOIN organization_memberships om ON om.user_id = u.id AND om.active
            JOIN sites s ON s.organization_id = om.organization_id AND s.active
            LEFT JOIN site_memberships sm
              ON sm.user_id = u.id AND sm.organization_id = om.organization_id AND sm.site_id = s.id AND sm.active
            WHERE i.issuer = %s AND i.subject = %s AND i.active
              AND (om.role = 'ORG_ADMIN' OR sm.site_id IS NOT NULL)
              AND (%s = '' OR s.id = %s::uuid)
            ORDER BY om.organization_id, s.created_at
            """,
            (issuer, subject, requested_site_id, requested_site_id or None),
        ).fetchall()
        if rows and email and str(rows[0]["email"]).lower() != email.lower():
            connection.execute("UPDATE users SET email = %s, updated_at = NOW() WHERE id = %s", (email, rows[0]["user_id"]))
            connection.commit()
    return [dict(row) for row in rows]


def reviewer_access_context(settings: Settings, issuer: str, subject: str, email: str) -> dict[str, Any]:
    if not issuer or not subject:
        raise AuthoritativeError("REVIEWER_UNAUTHORIZED", 401)
    rows = _reviewer_access_rows(settings, issuer, subject, email)
    if not rows:
        raise AuthoritativeError("REVIEWER_UNAUTHORIZED", 401)
    return {
        "user": {"id": str(rows[0]["user_id"]), "email": email or str(rows[0]["email"])},
        "sites": [
            {
                "organizationId": str(row["organization_id"]),
                "siteId": str(row["site_id"]),
                "siteName": str(row["site_name"]),
                "role": str(row["role"]),
            }
            for row in rows
        ],
        "providers": {"ocr": "ACTIVE", "gst": "DISABLED", "credit": "DISABLED", "whatsapp": "DISABLED", "slack": "DISABLED"},
    }


def list_receipts(settings: Settings, reviewer: ReviewerContext, status: str = "NEEDS_REVIEW", limit: int = 25) -> list[dict[str, Any]]:
    with tenant_connection(settings.database_url, str(reviewer.organization_id), row_factory=dict_row) as connection:
        rows = connection.execute(
            """
            SELECT r.*, v.name AS vendor_name
            FROM receipts r JOIN vendors v ON v.site_id = r.site_id AND v.id = r.vendor_id
            WHERE r.site_id = %s AND r.status = %s
            ORDER BY r.created_at DESC LIMIT %s
            """,
            (reviewer.site_id, status, min(max(limit, 1), 50)),
        ).fetchall()
    return [
        {
            "id": str(row["id"]), "vendorId": row["vendor_id"], "vendorName": row["vendor_name"],
            "capturedAtUnix": int(row["captured_at_unix"]), "capturedQuantity": float(row["captured_quantity"]),
            "status": row["status"], "version": int(row["version"]),
            "imageUrl": f"/v1/reviewer/receipts/{row['id']}/image", "challanNumber": row["challan_number"],
            "poNumber": row["po_number"], "materialCode": row["material_code"],
            "materialDescription": row["material_description"], "verifiedQuantity": row["verified_quantity"],
            "unit": row["unit"], "notes": row["notes"], "enrichmentStatus": row["enrichment_status"],
            "ocrConfidence": row["ocr_confidence"], "rawOcrJson": dict(row["raw_ocr_json"]),
            "gstStatus": row["gst_status"],
            "integrityStatus": row["integrity_status"],
        }
        for row in rows
    ]


def receipt_image(settings: Settings, reviewer: ReviewerContext, receipt_id: UUID, s3_client=None) -> tuple[bytes, str]:
    with tenant_connection(settings.database_url, str(reviewer.organization_id), row_factory=dict_row) as connection:
        row = connection.execute(
            "SELECT image_key, image_sha256 FROM receipts WHERE id = %s AND site_id = %s AND image_deleted_at IS NULL",
            (receipt_id, reviewer.site_id),
        ).fetchone()
    if not row:
        raise AuthoritativeError("IMAGE_NOT_FOUND", 404)
    image_key = str(row["image_key"])
    expected_prefix = f"{reviewer.organization_id}/{reviewer.site_id}/"
    if not image_key.startswith(expected_prefix) or not image_key.endswith(f"/{receipt_id}.webp"):
        raise AuthoritativeError("IMAGE_SCOPE_INVALID", 500)
    body = _s3_get(settings, image_key, s3_client)
    image_hash = str(row["image_sha256"])
    if hashlib.sha256(body).hexdigest() != image_hash:
        raise AuthoritativeError("IMAGE_INTEGRITY_FAILED", 502)
    return body, image_hash


def review_receipt(settings: Settings, reviewer: ReviewerContext, receipt_id: UUID, request: ReceiptReviewRequest, source_class: str) -> dict[str, Any]:
    next_status = "VERIFIED" if request.action == "VERIFY" else "REJECTED"
    with tenant_connection(settings.database_url, str(reviewer.organization_id), row_factory=dict_row) as connection:
        previous = connection.execute(
            "SELECT * FROM receipts WHERE id = %s AND site_id = %s FOR UPDATE",
            (receipt_id, reviewer.site_id),
        ).fetchone()
        if not previous:
            raise AuthoritativeError("RECEIPT_NOT_FOUND", 404)
        if int(previous["version"]) != request.version:
            raise AuthoritativeError("VERSION_CONFLICT", 409)
        updated = connection.execute(
            """
            UPDATE receipts SET status = %s, challan_number = %s, po_number = %s, material_code = %s,
              material_description = %s, verified_quantity = %s, unit = %s, notes = %s,
              version = version + 1, updated_at = NOW()
            WHERE id = %s AND site_id = %s AND version = %s RETURNING version
            """,
            (
                next_status, request.challan_number, request.po_number, request.material_code,
                request.material_description, request.verified_quantity, request.unit, request.notes,
                receipt_id, reviewer.site_id, request.version,
            ),
        ).fetchone()
        if not updated:
            raise AuthoritativeError("VERSION_CONFLICT", 409)
        if next_status == "VERIFIED":
            connection.execute(
                """
                INSERT INTO verified_receipts
                  (receipt_id, organization_id, site_id, po_number, material_code, verified_quantity,
                   unit, reviewer_id, review_version, reviewed_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, NOW())
                ON CONFLICT (receipt_id) DO UPDATE SET
                  po_number = excluded.po_number, material_code = excluded.material_code,
                  verified_quantity = excluded.verified_quantity, unit = excluded.unit,
                  reviewer_id = excluded.reviewer_id, review_version = excluded.review_version,
                  reviewed_at = excluded.reviewed_at, updated_at = NOW()
                WHERE verified_receipts.review_version < excluded.review_version
                """,
                (
                    receipt_id, reviewer.organization_id, reviewer.site_id, request.po_number.upper(),
                    request.material_code.upper(), request.verified_quantity, request.unit.upper(),
                    reviewer.email, int(updated["version"]),
                ),
            )
        event_body = {
            "before": {
                "status": previous["status"], "version": int(previous["version"]),
                "challanNumber": previous["challan_number"], "poNumber": previous["po_number"],
                "materialCode": previous["material_code"], "materialDescription": previous["material_description"],
                "verifiedQuantity": previous["verified_quantity"], "unit": previous["unit"], "notes": previous["notes"],
            },
            "after": {
                "status": next_status, "version": int(updated["version"]),
                "challanNumber": request.challan_number, "poNumber": request.po_number,
                "materialCode": request.material_code, "materialDescription": request.material_description,
                "verifiedQuantity": request.verified_quantity, "unit": request.unit, "notes": request.notes,
            },
            "reason": request.notes, "fields": request.model_dump(mode="json", by_alias=True),
        }
        connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
            (f"audit:{reviewer.organization_id}:{reviewer.site_id}",),
        )
        prior_hash = connection.execute(
            "SELECT event_hash FROM audit_events WHERE organization_id = %s AND site_id = %s ORDER BY created_at DESC, id DESC LIMIT 1",
            (reviewer.organization_id, reviewer.site_id),
        ).fetchone()
        previous_hash = "" if prior_hash is None else str(_row_value(prior_hash, "event_hash"))
        connection.execute(
            """
            INSERT INTO audit_events
              (id, organization_id, site_id, receipt_id, event_type, actor_type, actor_id, event_json, source_class, previous_hash, event_hash)
            VALUES (%s, %s, %s, %s, 'REVIEWED', 'USER', %s, %s, %s, %s, %s)
            """,
            (
                uuid4(), reviewer.organization_id, reviewer.site_id, receipt_id, str(reviewer.user_id),
                Jsonb(event_body), source_class, previous_hash or None, _audit_hash(previous_hash, event_body),
            ),
        )
        connection.commit()
    return {"receiptId": str(receipt_id), "status": next_status, "version": int(updated["version"])}


def export_audit(settings: Settings, reviewer: ReviewerContext, output_format: str) -> tuple[bytes, str]:
    if reviewer.role not in {"ORG_ADMIN", "SITE_ADMIN", "CONTROLLER", "AUDITOR"}:
        raise AuthoritativeError("AUDIT_EXPORT_FORBIDDEN", 403)
    with tenant_connection(settings.database_url, str(reviewer.organization_id), row_factory=dict_row) as connection:
        rows = connection.execute(
            """
            SELECT id, site_id, receipt_id, event_type, actor_type, actor_id, source_class, event_hash, created_at
            FROM audit_events WHERE site_id = %s ORDER BY created_at, id LIMIT 100000
            """,
            (reviewer.site_id,),
        ).fetchall()
    serializable = [{key: str(value) if value is not None else "" for key, value in row.items()} for row in rows]
    if output_format == "json":
        return json.dumps(serializable, separators=(",", ":")).encode(), "application/json"
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=list(serializable[0]) if serializable else ["id", "event_type", "created_at"])
    writer.writeheader()
    writer.writerows(serializable)
    return output.getvalue().encode(), "text/csv"


def create_enrollment_code(settings: Settings, reviewer: ReviewerContext, device_name: str) -> dict[str, Any]:
    if reviewer.role not in {"ORG_ADMIN", "SITE_ADMIN"}:
        raise AuthoritativeError("ADMIN_REQUIRED", 403)
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    code = "".join(secrets.choice(alphabet) for _ in range(8))
    code_hash = hashlib.sha256(code.encode()).hexdigest()
    with tenant_connection(settings.database_url, str(reviewer.organization_id)) as connection:
        connection.execute(
            """
            INSERT INTO enrollment_codes
              (code_hash, organization_id, site_id, device_name, expires_at, created_by)
            VALUES (%s, %s, %s, %s, NOW() + INTERVAL '10 minutes', %s)
            """,
            (code_hash, reviewer.organization_id, reviewer.site_id, device_name, reviewer.user_id),
        )
        connection.commit()
    return {"enrollmentCode": code, "expiresInSeconds": 600, "deviceName": device_name}


def revoke_device(settings: Settings, reviewer: ReviewerContext, device_id: UUID) -> None:
    if reviewer.role not in {"ORG_ADMIN", "SITE_ADMIN"}:
        raise AuthoritativeError("ADMIN_REQUIRED", 403)
    with tenant_connection(settings.database_url, str(reviewer.organization_id)) as connection:
        updated = connection.execute(
            "UPDATE devices SET active = FALSE WHERE id = %s AND organization_id = %s AND site_id = %s AND active RETURNING id",
            (device_id, reviewer.organization_id, reviewer.site_id),
        ).fetchone()
        connection.commit()
    if not updated:
        raise AuthoritativeError("DEVICE_NOT_FOUND", 404)


def admin_summary(settings: Settings, reviewer: ReviewerContext) -> dict[str, Any]:
    if reviewer.role not in {"ORG_ADMIN", "SITE_ADMIN"}:
        raise AuthoritativeError("ADMIN_REQUIRED", 403)
    with tenant_connection(settings.database_url, str(reviewer.organization_id), row_factory=dict_row) as connection:
        site = connection.execute(
            """
            SELECT s.name, o.stored_image_bytes, o.storage_byte_limit, s.daily_receipt_limit
            FROM sites s JOIN organizations o ON o.id = s.organization_id
            WHERE s.id = %s AND s.organization_id = %s
            """,
            (reviewer.site_id, reviewer.organization_id),
        ).fetchone()
        counts = connection.execute(
            "SELECT status, COUNT(*) AS count FROM receipts WHERE site_id = %s GROUP BY status",
            (reviewer.site_id,),
        ).fetchall()
        devices = connection.execute(
            """
            SELECT id, name, app_version, active, enrolled_at, last_seen_at
            FROM devices WHERE site_id = %s ORDER BY enrolled_at DESC
            """,
            (reviewer.site_id,),
        ).fetchall()
    if not site:
        raise AuthoritativeError("SITE_NOT_FOUND", 404)
    return {
        "site": {
            "name": site["name"], "storedImageBytes": int(site["stored_image_bytes"]),
            "storageByteLimit": int(site["storage_byte_limit"]), "dailyReceiptLimit": int(site["daily_receipt_limit"]),
        },
        "counts": {str(row["status"]): int(row["count"]) for row in counts},
        "devices": [
            {
                "id": str(row["id"]), "name": row["name"], "appVersion": row["app_version"],
                "active": bool(row["active"]), "enrolledAt": row["enrolled_at"].isoformat(),
                "lastSeenAt": None if row["last_seen_at"] is None else row["last_seen_at"].isoformat(),
            }
            for row in devices
        ],
        "providers": {"ocr": "ACTIVE", "gst": "DISABLED", "credit": "DISABLED", "whatsapp": "DISABLED", "slack": "DISABLED"},
    }


def _append_admin_audit(connection, reviewer: ReviewerContext, event_type: str, event_body: dict[str, Any]) -> None:
    connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
        (f"audit:{reviewer.organization_id}:{reviewer.site_id}",),
    )
    prior = connection.execute(
        "SELECT event_hash FROM audit_events WHERE organization_id = %s AND site_id = %s ORDER BY created_at DESC, id DESC LIMIT 1",
        (reviewer.organization_id, reviewer.site_id),
    ).fetchone()
    previous_hash = "" if prior is None else str(_row_value(prior, "event_hash"))
    connection.execute(
        """
        INSERT INTO audit_events
          (id, organization_id, site_id, event_type, actor_type, actor_id, event_json, source_class, previous_hash, event_hash)
        VALUES (%s, %s, %s, %s, 'USER', %s, %s, 'cloudflare-access', %s, %s)
        """,
        (
            uuid4(), reviewer.organization_id, reviewer.site_id, event_type, str(reviewer.user_id),
            Jsonb(event_body), previous_hash or None, _audit_hash(previous_hash, event_body),
        ),
    )


def admin_configuration(settings: Settings, reviewer: ReviewerContext) -> dict[str, Any]:
    if reviewer.role not in {"ORG_ADMIN", "SITE_ADMIN"}:
        raise AuthoritativeError("ADMIN_REQUIRED", 403)
    with system_connection(settings.system_database_url or settings.database_url, row_factory=dict_row) as connection:
        organization = connection.execute(
            """
            SELECT id, slug, name, device_limit, device_request_limit_per_minute,
                   daily_receipt_limit, storage_byte_limit, stored_image_bytes
            FROM organizations WHERE id = %s AND active
            """,
            (reviewer.organization_id,),
        ).fetchone()
        sites = connection.execute(
            """
            SELECT id, name, allowed_wifi_ssids, configuration_version, daily_receipt_limit, image_byte_limit, active
            FROM sites WHERE organization_id = %s
              AND (%s = 'ORG_ADMIN' OR id = %s)
            ORDER BY name
            """,
            (reviewer.organization_id, reviewer.role, reviewer.site_id),
        ).fetchall()
        vendors = connection.execute(
            """
            SELECT id, site_id, name, initials, color, display_order, active
            FROM vendors WHERE organization_id = %s
              AND (%s = 'ORG_ADMIN' OR site_id = %s)
            ORDER BY site_id, display_order, name
            """,
            (reviewer.organization_id, reviewer.role, reviewer.site_id),
        ).fetchall()
        memberships = connection.execute(
            """
            SELECT u.id AS user_id, u.email, u.display_name, om.role, om.active,
                   COALESCE(array_agg(sm.site_id) FILTER (WHERE sm.active), '{}') AS site_ids
            FROM organization_memberships om
            JOIN users u ON u.id = om.user_id
            LEFT JOIN site_memberships sm
              ON sm.organization_id = om.organization_id AND sm.user_id = om.user_id
            WHERE om.organization_id = %s
              AND (%s = 'ORG_ADMIN' OR sm.site_id = %s)
            GROUP BY u.id, u.email, u.display_name, om.role, om.active
            ORDER BY LOWER(u.email)
            """,
            (reviewer.organization_id, reviewer.role, reviewer.site_id),
        ).fetchall()
    if not organization:
        raise AuthoritativeError("ORGANIZATION_INACTIVE", 403)
    return {
        "organization": {
            "id": str(organization["id"]), "slug": organization["slug"], "name": organization["name"],
            "deviceLimit": int(organization["device_limit"]),
            "deviceRequestLimitPerMinute": int(organization["device_request_limit_per_minute"]),
            "dailyReceiptLimit": int(organization["daily_receipt_limit"]),
            "storageByteLimit": int(organization["storage_byte_limit"]),
            "storedImageBytes": int(organization["stored_image_bytes"]),
        },
        "sites": [
            {
                "id": str(row["id"]), "name": row["name"], "allowedWifiSsids": list(row["allowed_wifi_ssids"]),
                "configurationVersion": int(row["configuration_version"]),
                "dailyReceiptLimit": int(row["daily_receipt_limit"]), "imageByteLimit": int(row["image_byte_limit"]),
                "active": bool(row["active"]),
            }
            for row in sites
        ],
        "vendors": [
            {
                "id": row["id"], "siteId": str(row["site_id"]), "name": row["name"], "initials": row["initials"],
                "color": row["color"], "displayOrder": int(row["display_order"]), "active": bool(row["active"]),
            }
            for row in vendors
        ],
        "memberships": [
            {
                "userId": str(row["user_id"]), "email": row["email"], "displayName": row["display_name"],
                "role": row["role"], "active": bool(row["active"]),
                "siteIds": [str(site_id) for site_id in row["site_ids"]],
            }
            for row in memberships
        ],
    }


def upsert_site(settings: Settings, reviewer: ReviewerContext, request: SiteAdminRequest) -> dict[str, Any]:
    if reviewer.role not in {"ORG_ADMIN", "SITE_ADMIN"}:
        raise AuthoritativeError("ADMIN_REQUIRED", 403)
    if reviewer.role == "SITE_ADMIN" and request.site_id != reviewer.site_id:
        raise AuthoritativeError("SITE_ADMIN_SCOPE_VIOLATION", 403)
    site_id = request.site_id or uuid4()
    ssids = list(dict.fromkeys(value.strip() for value in request.allowed_wifi_ssids if value.strip()))
    if len(ssids) != len(request.allowed_wifi_ssids):
        raise AuthoritativeError("INVALID_WIFI_POLICY", 422)
    with tenant_connection(settings.database_url, str(reviewer.organization_id), row_factory=dict_row) as connection:
        organization = connection.execute(
            "SELECT daily_receipt_limit FROM organizations WHERE id = %s AND active",
            (reviewer.organization_id,),
        ).fetchone()
        if not organization or request.daily_receipt_limit > int(organization["daily_receipt_limit"]):
            raise AuthoritativeError("SITE_QUOTA_EXCEEDS_ORGANIZATION", 422)
        existing = connection.execute(
            "SELECT image_byte_limit, active FROM sites WHERE id = %s AND organization_id = %s FOR UPDATE",
            (site_id, reviewer.organization_id),
        ).fetchone()
        if reviewer.role == "SITE_ADMIN" and not existing:
            raise AuthoritativeError("SITE_NOT_FOUND", 404)
        image_byte_limit = int(existing["image_byte_limit"]) if reviewer.role == "SITE_ADMIN" else request.image_byte_limit
        active = bool(existing["active"]) if reviewer.role == "SITE_ADMIN" else request.active
        connection.execute(
            """
            INSERT INTO sites
              (id, organization_id, name, allowed_wifi_ssids, daily_receipt_limit, image_byte_limit, active)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (organization_id, id) DO UPDATE SET
              name = excluded.name, allowed_wifi_ssids = excluded.allowed_wifi_ssids,
              daily_receipt_limit = excluded.daily_receipt_limit, image_byte_limit = excluded.image_byte_limit,
              active = excluded.active, configuration_version = sites.configuration_version + 1, updated_at = NOW()
            """,
            (
                site_id, reviewer.organization_id, request.name, Jsonb(ssids), request.daily_receipt_limit,
                image_byte_limit, active,
            ),
        )
        _append_admin_audit(connection, reviewer, "SITE_CONFIGURED", {"siteId": str(site_id), "active": active})
        connection.commit()
    return {"siteId": str(site_id), "status": "configured"}


def upsert_vendor(settings: Settings, reviewer: ReviewerContext, request: VendorAdminRequest) -> dict[str, Any]:
    if reviewer.role not in {"ORG_ADMIN", "SITE_ADMIN"}:
        raise AuthoritativeError("ADMIN_REQUIRED", 403)
    with tenant_connection(settings.database_url, str(reviewer.organization_id)) as connection:
        connection.execute(
            """
            INSERT INTO vendors
              (id, organization_id, site_id, name, initials, color, display_order, active)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (site_id, id) DO UPDATE SET
              name = excluded.name, initials = excluded.initials, color = excluded.color,
              display_order = excluded.display_order, active = excluded.active
            """,
            (
                request.vendor_id, reviewer.organization_id, reviewer.site_id, request.name, request.initials.upper(),
                request.color.upper(), request.display_order, request.active,
            ),
        )
        connection.execute(
            "UPDATE sites SET configuration_version = configuration_version + 1, updated_at = NOW() WHERE id = %s",
            (reviewer.site_id,),
        )
        _append_admin_audit(
            connection, reviewer, "VENDOR_CONFIGURED", {"vendorId": request.vendor_id, "active": request.active}
        )
        connection.commit()
    return {"vendorId": request.vendor_id, "status": "configured"}


def upsert_membership(settings: Settings, reviewer: ReviewerContext, request: MembershipAdminRequest) -> dict[str, Any]:
    if reviewer.role != "ORG_ADMIN":
        raise AuthoritativeError("ORG_ADMIN_REQUIRED", 403)
    if request.issuer != reviewer.issuer:
        raise AuthoritativeError("IDENTITY_ISSUER_MISMATCH", 422)
    if request.role != "ORG_ADMIN" and not request.site_ids:
        raise AuthoritativeError("SITE_MEMBERSHIP_REQUIRED", 422)
    with system_connection(settings.system_database_url or settings.database_url, row_factory=dict_row) as connection:
        valid_sites = connection.execute(
            "SELECT id FROM sites WHERE organization_id = %s AND id = ANY(%s) AND active",
            (reviewer.organization_id, request.site_ids),
        ).fetchall()
        if request.role != "ORG_ADMIN" and len(valid_sites) != len(set(request.site_ids)):
            raise AuthoritativeError("INVALID_SITE_MEMBERSHIP", 422)
        identity = connection.execute(
            "SELECT user_id FROM identity_links WHERE issuer = %s AND subject = %s FOR UPDATE",
            (request.issuer, request.subject),
        ).fetchone()
        if identity:
            user_id = UUID(str(identity["user_id"]))
        else:
            user_id = uuid4()
            connection.execute(
                "INSERT INTO users (id, email, display_name) VALUES (%s, %s, %s)",
                (user_id, request.email.lower(), request.display_name),
            )
            connection.execute(
                "INSERT INTO identity_links (id, user_id, issuer, subject, email) VALUES (%s, %s, %s, %s, %s)",
                (uuid4(), user_id, request.issuer, request.subject, request.email.lower()),
            )
        current = connection.execute(
            "SELECT role, active FROM organization_memberships WHERE organization_id = %s AND user_id = %s FOR UPDATE",
            (reviewer.organization_id, user_id),
        ).fetchone()
        if current and current["role"] == "ORG_ADMIN" and bool(current["active"]) and (request.role != "ORG_ADMIN" or not request.active):
            admin_count = connection.execute(
                "SELECT COUNT(*) AS admin_count FROM organization_memberships WHERE organization_id = %s AND role = 'ORG_ADMIN' AND active",
                (reviewer.organization_id,),
            ).fetchone()["admin_count"]
            if int(admin_count) <= 1:
                raise AuthoritativeError("LAST_ORG_ADMIN", 409)
        connection.execute(
            "UPDATE users SET email = %s, display_name = %s, updated_at = NOW() WHERE id = %s",
            (request.email.lower(), request.display_name, user_id),
        )
        connection.execute(
            "UPDATE identity_links SET email = %s, active = TRUE WHERE issuer = %s AND subject = %s",
            (request.email.lower(), request.issuer, request.subject),
        )
        connection.execute(
            """
            INSERT INTO organization_memberships (organization_id, user_id, role, active)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (organization_id, user_id) DO UPDATE SET role = excluded.role, active = excluded.active
            """,
            (reviewer.organization_id, user_id, request.role, request.active),
        )
        connection.execute(
            "DELETE FROM site_memberships WHERE organization_id = %s AND user_id = %s",
            (reviewer.organization_id, user_id),
        )
        if request.role != "ORG_ADMIN":
            for site_id in request.site_ids:
                connection.execute(
                    """
                    INSERT INTO site_memberships (organization_id, site_id, user_id, role, active)
                    VALUES (%s, %s, %s, %s, %s)
                    """,
                    (reviewer.organization_id, site_id, user_id, request.role, request.active),
                )
        _append_admin_audit(
            connection,
            reviewer,
            "MEMBERSHIP_CONFIGURED",
            {"targetUserId": str(user_id), "role": request.role, "active": request.active, "siteIds": [str(value) for value in request.site_ids]},
        )
        connection.commit()
    return {"userId": str(user_id), "status": "configured"}


def create_membership_invitation(
    settings: Settings, reviewer: ReviewerContext, request: MembershipInvitationRequest
) -> dict[str, Any]:
    if reviewer.role != "ORG_ADMIN":
        raise AuthoritativeError("ORG_ADMIN_REQUIRED", 403)
    if request.role != "ORG_ADMIN" and not request.site_ids:
        raise AuthoritativeError("SITE_MEMBERSHIP_REQUIRED", 422)
    invitation_code = secrets.token_urlsafe(24)
    code_hash = hashlib.sha256(invitation_code.encode()).hexdigest()
    with tenant_connection(settings.database_url, str(reviewer.organization_id), row_factory=dict_row) as connection:
        valid_sites = connection.execute(
            "SELECT id FROM sites WHERE organization_id = %s AND id = ANY(%s) AND active",
            (reviewer.organization_id, request.site_ids),
        ).fetchall()
        if request.role != "ORG_ADMIN" and len(valid_sites) != len(set(request.site_ids)):
            raise AuthoritativeError("INVALID_SITE_MEMBERSHIP", 422)
        connection.execute(
            """
            UPDATE membership_invitations SET used_at = NOW()
            WHERE organization_id = %s AND LOWER(email) = LOWER(%s) AND used_at IS NULL
            """,
            (reviewer.organization_id, request.email),
        )
        connection.execute(
            """
            INSERT INTO membership_invitations
              (id, code_hash, organization_id, created_site_id, issuer, email, display_name,
               role, site_ids, expires_at, created_by)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, NOW() + INTERVAL '24 hours', %s)
            """,
            (
                uuid4(), code_hash, reviewer.organization_id, reviewer.site_id, reviewer.issuer,
                request.email.lower(), request.display_name, request.role, request.site_ids, reviewer.user_id,
            ),
        )
        _append_admin_audit(
            connection,
            reviewer,
            "MEMBERSHIP_INVITED",
            {"emailHash": hashlib.sha256(request.email.lower().encode()).hexdigest(), "role": request.role},
        )
        connection.commit()
    return {"invitationCode": invitation_code, "expiresInSeconds": 86400, "role": request.role}


def accept_membership_invitation(
    settings: Settings,
    issuer: str,
    subject: str,
    email: str,
    request: MembershipInvitationAcceptance,
) -> dict[str, Any]:
    if not issuer or not subject or not email:
        raise AuthoritativeError("REVIEWER_IDENTITY_REQUIRED", 401)
    code_hash = hashlib.sha256(request.invitation_code.encode()).hexdigest()
    with system_connection(settings.system_database_url or settings.database_url, row_factory=dict_row) as connection:
        invitation = connection.execute(
            """
            SELECT * FROM membership_invitations
            WHERE code_hash = %s AND used_at IS NULL AND expires_at > NOW()
            FOR UPDATE
            """,
            (code_hash,),
        ).fetchone()
        if not invitation:
            raise AuthoritativeError("MEMBERSHIP_INVITATION_EXPIRED", 410)
        if invitation["issuer"] != issuer or invitation["email"].lower() != email.lower():
            raise AuthoritativeError("MEMBERSHIP_INVITATION_IDENTITY_MISMATCH", 403)
        identity = connection.execute(
            "SELECT user_id FROM identity_links WHERE issuer = %s AND subject = %s FOR UPDATE",
            (issuer, subject),
        ).fetchone()
        if identity:
            user_id = UUID(str(identity["user_id"]))
            connection.execute(
                "UPDATE users SET email = %s, display_name = %s, active = TRUE, updated_at = NOW() WHERE id = %s",
                (email.lower(), invitation["display_name"], user_id),
            )
            connection.execute(
                "UPDATE identity_links SET email = %s, active = TRUE WHERE issuer = %s AND subject = %s",
                (email.lower(), issuer, subject),
            )
        else:
            user_id = uuid4()
            connection.execute(
                "INSERT INTO users (id, email, display_name) VALUES (%s, %s, %s)",
                (user_id, email.lower(), invitation["display_name"]),
            )
            connection.execute(
                "INSERT INTO identity_links (id, user_id, issuer, subject, email) VALUES (%s, %s, %s, %s, %s)",
                (uuid4(), user_id, issuer, subject, email.lower()),
            )
        connection.execute(
            """
            INSERT INTO organization_memberships (organization_id, user_id, role, active)
            VALUES (%s, %s, %s, TRUE)
            ON CONFLICT (organization_id, user_id) DO UPDATE SET role = excluded.role, active = TRUE
            """,
            (invitation["organization_id"], user_id, invitation["role"]),
        )
        connection.execute(
            "DELETE FROM site_memberships WHERE organization_id = %s AND user_id = %s",
            (invitation["organization_id"], user_id),
        )
        if invitation["role"] != "ORG_ADMIN":
            for site_id in invitation["site_ids"]:
                connection.execute(
                    """
                    INSERT INTO site_memberships (organization_id, site_id, user_id, role, active)
                    VALUES (%s, %s, %s, %s, TRUE)
                    """,
                    (invitation["organization_id"], site_id, user_id, invitation["role"]),
                )
        connection.execute("UPDATE membership_invitations SET used_at = NOW() WHERE id = %s", (invitation["id"],))
        event_body = {"targetUserId": str(user_id), "role": invitation["role"]}
        connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
            (f"audit:{invitation['organization_id']}:{invitation['created_site_id']}",),
        )
        prior = connection.execute(
            """
            SELECT event_hash FROM audit_events
            WHERE organization_id = %s AND site_id = %s
            ORDER BY created_at DESC, id DESC LIMIT 1
            """,
            (invitation["organization_id"], invitation["created_site_id"]),
        ).fetchone()
        previous_hash = "" if prior is None else str(prior["event_hash"])
        connection.execute(
            """
            INSERT INTO audit_events
              (id, organization_id, site_id, event_type, actor_type, actor_id, event_json,
               source_class, previous_hash, event_hash)
            VALUES (%s, %s, %s, 'MEMBERSHIP_ACCEPTED', 'USER', %s, %s, 'cloudflare-access', %s, %s)
            """,
            (
                uuid4(), invitation["organization_id"], invitation["created_site_id"], str(user_id),
                Jsonb(event_body), previous_hash or None, _audit_hash(previous_hash, event_body),
            ),
        )
        connection.commit()
    return {"status": "accepted", "organizationId": str(invitation["organization_id"])}


def update_organization_quota(settings: Settings, reviewer: ReviewerContext, request: QuotaAdminRequest) -> dict[str, Any]:
    if reviewer.role != "ORG_ADMIN":
        raise AuthoritativeError("ORG_ADMIN_REQUIRED", 403)
    with tenant_connection(settings.database_url, str(reviewer.organization_id)) as connection:
        connection.execute(
            """
            UPDATE organizations SET device_limit = %s, device_request_limit_per_minute = %s,
              daily_receipt_limit = %s, storage_byte_limit = %s, updated_at = NOW()
            WHERE id = %s AND active
            """,
            (
                request.device_limit, request.device_request_limit_per_minute,
                request.daily_receipt_limit, request.storage_byte_limit, reviewer.organization_id,
            ),
        )
        _append_admin_audit(
            connection,
            reviewer,
            "QUOTA_CONFIGURED",
            {
                "deviceLimit": request.device_limit,
                "deviceRequestLimitPerMinute": request.device_request_limit_per_minute,
                "dailyReceiptLimit": request.daily_receipt_limit,
                "storageByteLimit": request.storage_byte_limit,
            },
        )
        connection.commit()
    return {"status": "configured"}


def revoke_all_devices(settings: Settings, reviewer: ReviewerContext, request: RevokeAllDevicesRequest) -> dict[str, Any]:
    if reviewer.role != "ORG_ADMIN":
        raise AuthoritativeError("ORG_ADMIN_REQUIRED", 403)
    expected = f"REVOKE ALL DEVICES {reviewer.organization_id}"
    if not secrets.compare_digest(request.confirmation, expected):
        raise AuthoritativeError("REVOCATION_CONFIRMATION_REQUIRED", 422)
    with tenant_connection(settings.database_url, str(reviewer.organization_id)) as connection:
        updated = connection.execute(
            "UPDATE devices SET active = FALSE WHERE organization_id = %s AND active",
            (reviewer.organization_id,),
        )
        _append_admin_audit(connection, reviewer, "ALL_DEVICES_REVOKED", {"revokedCount": updated.rowcount})
        connection.commit()
    return {"revoked": updated.rowcount}
