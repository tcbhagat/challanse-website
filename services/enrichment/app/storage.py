from typing import Any
from uuid import UUID, uuid4

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .config import Settings
from .encryption import decrypt_json, encrypt_json
from .schemas import EnrichmentResult, GstReceiptContext, ReceiptEvent


def claim_stage(database_url: str, receipt_id: str, stage: str) -> bool:
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO workflow_stages (receipt_id, stage, status)
                VALUES (%s, %s, 'PROCESSING')
                ON CONFLICT (receipt_id, stage) DO UPDATE SET
                  status = 'PROCESSING', attempts = workflow_stages.attempts + 1,
                  last_error_code = NULL, updated_at = NOW()
                WHERE workflow_stages.status = 'FAILED_RETRYABLE' AND workflow_stages.attempts < 10
                RETURNING receipt_id
                """,
                (receipt_id, stage),
            )
            claimed = cursor.fetchone() is not None
        connection.commit()
    return claimed


def fail_stage(database_url: str, receipt_id: str, stage: str, error_code: str, terminal: bool = False) -> None:
    status = "FAILED_TERMINAL" if terminal else "FAILED_RETRYABLE"
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE workflow_stages SET status = %s, last_error_code = %s, updated_at = NOW()
                WHERE receipt_id = %s AND stage = %s
                """,
                (status, error_code[:120], receipt_id, stage),
            )
        connection.commit()


def upsert_enrichment(
    settings: Settings,
    event: ReceiptEvent,
    status: str,
    raw_ocr_json: dict[str, Any],
    raw_text: str,
    confidence: float,
    gps_latitude: float | None,
    gps_longitude: float | None,
    provider_version: str,
    gst_status: str = "NOT_CHECKED",
    sensitive_audit: dict[str, object] | None = None,
) -> int:
    database_url = settings.database_url
    if not database_url:
        raise RuntimeError("database_url_unconfigured")
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO enrichment_receipts (
                  receipt_id, site_id, vendor_id, captured_at_unix, site_captured_quantity,
                  image_sha256, image_bytes, status, raw_ocr_json, raw_text, ocr_confidence,
                  gps_latitude, gps_longitude, provider_version, gst_status, processing_started_at, processing_completed_at
                ) VALUES (
                  %(receipt_id)s, %(site_id)s, %(vendor_id)s, %(captured_at_unix)s, %(site_captured_quantity)s,
                  %(image_sha256)s, %(image_bytes)s, %(status)s, %(raw_ocr_json)s, %(raw_text)s, %(ocr_confidence)s,
                  %(gps_latitude)s, %(gps_longitude)s, %(provider_version)s, %(gst_status)s, NOW(), NOW()
                )
                ON CONFLICT (receipt_id) DO UPDATE SET
                  status = excluded.status,
                  raw_ocr_json = excluded.raw_ocr_json,
                  raw_text = excluded.raw_text,
                  ocr_confidence = excluded.ocr_confidence,
                  gps_latitude = excluded.gps_latitude,
                  gps_longitude = excluded.gps_longitude,
                  provider_version = excluded.provider_version,
                  gst_status = excluded.gst_status,
                  processing_completed_at = NOW(),
                  version = enrichment_receipts.version + 1,
                  updated_at = NOW()
                RETURNING version
                """,
                {
                    **event.model_dump(mode="python"),
                    "status": status,
                    "raw_ocr_json": Jsonb(raw_ocr_json),
                    "raw_text": raw_text,
                    "ocr_confidence": confidence,
                    "gps_latitude": gps_latitude,
                    "gps_longitude": gps_longitude,
                    "provider_version": provider_version,
                    "gst_status": gst_status,
                },
            )
            version = int(cursor.fetchone()[0])
            result = EnrichmentResult(
                receipt_id=event.receipt_id,
                status=status,
                ocr_confidence=confidence,
                raw_ocr_json=raw_ocr_json,
                gst_status=gst_status,
                version=version,
            )
            cursor.execute(
                """
                INSERT INTO immutable_enrichment_audits (id, receipt_id, event_type, event_json)
                VALUES (%(audit_id)s, %(receipt_id)s, 'OCR_COMPLETED', %(event_json)s)
                """,
                {
                    "receipt_id": event.receipt_id,
                    "audit_id": uuid4(),
                    "event_json": Jsonb({"status": status, "confidence": confidence, "gps_present": gps_latitude is not None, "provider": provider_version}),
                },
            )
            if sensitive_audit:
                ciphertext = encrypt_json(settings, event.site_id, event.receipt_id, "gst_audit", sensitive_audit)
                cursor.execute(
                    """
                    INSERT INTO immutable_enrichment_audits (id, receipt_id, event_type, event_json, sensitive_event_ciphertext)
                    VALUES (%s, %s, 'GST_VALIDATED', %s, %s)
                    """,
                    (uuid4(), event.receipt_id, Jsonb({"gst_status": gst_status, "sensitive_fields": "kms_encrypted"}), ciphertext),
                )
            cursor.execute(
                """
                INSERT INTO transactional_outbox (id, aggregate_id, event_type, event_version, payload_json)
                VALUES (%s, %s, 'ENRICHMENT_CALLBACK', %s, %s)
                ON CONFLICT (aggregate_id, event_type, event_version) DO NOTHING
                """,
                (uuid4(), event.receipt_id, version, Jsonb(result.model_dump(mode="json"))),
            )
            cursor.execute(
                """
                UPDATE workflow_stages SET status = 'COMPLETED', completed_at = NOW(), updated_at = NOW()
                WHERE receipt_id = %s AND stage = 'ENRICHMENT'
                """,
                (event.receipt_id,),
            )
        connection.commit()
    return version


def load_gst_context(settings: Settings, event: ReceiptEvent, kms_client=None) -> GstReceiptContext:
    with psycopg.connect(settings.database_url, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT vendor_gst_number_encrypted, msme_udyam_number_encrypted,
                       recipient_bank_account_encrypted, site_geo_hash, material_description,
                       (SELECT developer_gst_number_encrypted FROM site_integration_profiles WHERE site_id = %s) AS developer_gst_number_encrypted
                FROM vendor_integration_profiles WHERE site_id = %s AND vendor_id = %s
                """,
                (event.site_id, event.site_id, event.vendor_id),
            )
            row = cursor.fetchone()
    if not row:
        return GstReceiptContext(
            receipt_id=event.receipt_id,
            timestamp_unix=event.captured_at_unix,
            site_captured_quantity=event.site_captured_quantity,
        )

    def decrypt_field(name: str) -> str | None:
        value = row[name]
        if value is None:
            return None
        return str(decrypt_json(settings, event.site_id, event.vendor_id, name, bytes(value), kms_client))

    developer_gst = row["developer_gst_number_encrypted"]
    developer_gst_number = None if developer_gst is None else str(
        decrypt_json(settings, event.site_id, event.site_id, "developer_gst_number_encrypted", bytes(developer_gst), kms_client)
    )

    return GstReceiptContext(
        receipt_id=event.receipt_id,
        vendor_gst_number=decrypt_field("vendor_gst_number_encrypted"),
        developer_gst_number=developer_gst_number,
        timestamp_unix=event.captured_at_unix,
        site_captured_quantity=event.site_captured_quantity,
        material_description=str(row["material_description"]),
        site_geo_hash=str(row["site_geo_hash"]),
        msme_udyam_number=decrypt_field("msme_udyam_number_encrypted"),
        recipient_bank_account=decrypt_field("recipient_bank_account_encrypted"),
    )


def pending_callback(database_url: str, receipt_id: str) -> tuple[UUID, EnrichmentResult] | None:
    with psycopg.connect(database_url, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT id, payload_json FROM transactional_outbox
                WHERE aggregate_id = %s AND event_type = 'ENRICHMENT_CALLBACK'
                  AND status IN ('PENDING', 'FAILED_RETRYABLE') AND available_at <= NOW()
                ORDER BY event_version DESC LIMIT 1
                """,
                (receipt_id,),
            )
            row = cursor.fetchone()
    if not row:
        return None
    return UUID(str(row["id"])), EnrichmentResult.model_validate(row["payload_json"])


def mark_callback_delivered(database_url: str, outbox_id: UUID) -> None:
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE transactional_outbox SET status = 'DELIVERED', attempts = attempts + 1, delivered_at = NOW() WHERE id = %s",
                (outbox_id,),
            )
        connection.commit()


def mark_callback_failed(database_url: str, outbox_id: UUID) -> None:
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE transactional_outbox SET status = 'FAILED_RETRYABLE', attempts = attempts + 1,
                  available_at = NOW() + (LEAST(3600, POWER(2, LEAST(attempts, 10))) * INTERVAL '1 second')
                WHERE id = %s
                """,
                (outbox_id,),
            )
        connection.commit()
