from typing import Any
from uuid import uuid4

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .config import Settings
from .encryption import decrypt_json, encrypt_json
from .schemas import EnrichmentResult, GstReceiptContext, ReceiptEvent
from .tenancy import tenant_connection


def claim_stage(database_url: str, organization_id: str, receipt_id: str, stage: str) -> bool:
    with tenant_connection(database_url, organization_id) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO workflow_stages (organization_id, receipt_id, stage, status, locked_until)
                VALUES (%s, %s, %s, 'PROCESSING', NOW() + INTERVAL '5 minutes')
                ON CONFLICT (receipt_id, stage) DO UPDATE SET
                  status = 'PROCESSING', attempts = workflow_stages.attempts + 1,
                  last_error_code = NULL, locked_until = NOW() + INTERVAL '5 minutes', updated_at = NOW()
                WHERE (workflow_stages.status = 'FAILED_RETRYABLE' OR
                       (workflow_stages.status = 'PROCESSING' AND workflow_stages.locked_until < NOW()))
                  AND workflow_stages.attempts < 5
                RETURNING receipt_id
                """,
                (organization_id, receipt_id, stage),
            )
            claimed = cursor.fetchone() is not None
        connection.commit()
    return claimed


def stage_status(database_url: str, organization_id: str, receipt_id: str, stage: str) -> str | None:
    with tenant_connection(database_url, organization_id) as connection:
        row = connection.execute(
            "SELECT status FROM workflow_stages WHERE receipt_id = %s AND stage = %s",
            (receipt_id, stage),
        ).fetchone()
    return None if row is None else str(row[0])


def complete_stage(database_url: str, organization_id: str, receipt_id: str, stage: str) -> None:
    with tenant_connection(database_url, organization_id) as connection:
        connection.execute(
            """
            UPDATE workflow_stages
            SET status = 'COMPLETED', completed_at = NOW(), locked_until = NULL, updated_at = NOW()
            WHERE receipt_id = %s AND stage = %s AND status = 'PROCESSING'
            """,
            (receipt_id, stage),
        )
        connection.commit()


def fail_stage(database_url: str, organization_id: str, receipt_id: str, stage: str, error_code: str, terminal: bool = False) -> bool:
    with tenant_connection(database_url, organization_id) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE workflow_stages
                SET status = CASE WHEN %s OR attempts >= 5 THEN 'FAILED_TERMINAL' ELSE 'FAILED_RETRYABLE' END,
                    last_error_code = %s, locked_until = NULL, updated_at = NOW()
                WHERE receipt_id = %s AND stage = %s
                RETURNING status
                """,
                (terminal, error_code[:120], receipt_id, stage),
            )
            row = cursor.fetchone()
        connection.commit()
    return row is not None and str(row[0]) == "FAILED_TERMINAL"


def _insert_callback(cursor, event: ReceiptEvent, result: EnrichmentResult) -> None:
    cursor.execute(
        """
        INSERT INTO transactional_outbox
          (id, organization_id, aggregate_id, event_type, event_version, destination, idempotency_key, payload_json)
        VALUES (%s, %s, %s, 'ENRICHMENT_CALLBACK', %s, 'POSTGRES_PROJECTION', %s, %s)
        ON CONFLICT (aggregate_id, event_type, event_version) DO NOTHING
        """,
        (
            uuid4(), event.organization_id, event.receipt_id, result.version,
            f"enrichment-callback:{event.receipt_id}:{result.version}",
            Jsonb(result.model_dump(mode="json")),
        ),
    )


def save_ocr_result(
    settings: Settings,
    event: ReceiptEvent,
    status: str,
    raw_ocr_json: dict[str, Any],
    raw_text: str,
    confidence: float,
    gps_latitude: float | None,
    gps_longitude: float | None,
    provider_version: str,
    finalize: bool,
) -> EnrichmentResult:
    database_url = settings.database_url
    if not database_url:
        raise RuntimeError("database_url_unconfigured")
    with tenant_connection(database_url, event.organization_id) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO enrichment_receipts (
                  receipt_id, organization_id, site_id, vendor_id, captured_at_unix, site_captured_quantity,
                  image_sha256, image_bytes, status, raw_ocr_json, raw_text, ocr_confidence,
                  gps_latitude, gps_longitude, provider_version, gst_status, processing_started_at, processing_completed_at
                ) VALUES (
                  %(receipt_id)s, %(organization_id)s, %(site_id)s, %(vendor_id)s, %(captured_at_unix)s, %(site_captured_quantity)s,
                  %(image_sha256)s, %(image_bytes)s, %(status)s, %(raw_ocr_json)s, %(raw_text)s, %(ocr_confidence)s,
                  %(gps_latitude)s, %(gps_longitude)s, %(provider_version)s, 'NOT_CHECKED', NOW(), NOW()
                )
                ON CONFLICT (receipt_id) DO UPDATE SET
                  status = excluded.status,
                  raw_ocr_json = excluded.raw_ocr_json,
                  raw_text = excluded.raw_text,
                  ocr_confidence = excluded.ocr_confidence,
                  gps_latitude = excluded.gps_latitude,
                  gps_longitude = excluded.gps_longitude,
                  provider_version = excluded.provider_version,
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
                },
            )
            version = int(cursor.fetchone()[0])
            result = EnrichmentResult(
                receipt_id=event.receipt_id,
                status=status,
                ocr_confidence=confidence,
                raw_ocr_json=raw_ocr_json,
                gst_status="NOT_CHECKED",
                version=version,
            )
            cursor.execute(
                """
                INSERT INTO immutable_enrichment_audits (id, organization_id, receipt_id, event_type, event_json)
                VALUES (%(audit_id)s, %(organization_id)s, %(receipt_id)s, 'OCR_COMPLETED', %(event_json)s)
                ON CONFLICT (receipt_id, event_type) DO NOTHING
                """,
                {
                    "receipt_id": event.receipt_id,
                    "organization_id": event.organization_id,
                    "audit_id": uuid4(),
                    "event_json": Jsonb({"status": status, "confidence": confidence, "gps_present": gps_latitude is not None, "provider": provider_version}),
                },
            )
            cursor.execute(
                """
                UPDATE workflow_stages
                SET status = 'COMPLETED', completed_at = NOW(), locked_until = NULL, updated_at = NOW()
                WHERE receipt_id = %s AND stage IN ('IMAGE_FETCH', 'OCR')
                """,
                (event.receipt_id,),
            )
            if finalize:
                _insert_callback(cursor, event, result)
        connection.commit()
    return result


def save_gst_result(
    settings: Settings,
    event: ReceiptEvent,
    status: str,
    sensitive_audit: dict[str, object],
    credit_payload: dict[str, Any] | None,
) -> EnrichmentResult:
    with tenant_connection(settings.database_url, event.organization_id, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE enrichment_receipts
                SET status = %s, gst_status = %s, version = version + 1,
                    processing_completed_at = NOW(), updated_at = NOW()
                WHERE receipt_id = %s
                RETURNING receipt_id, status, ocr_confidence, raw_ocr_json, gst_status, version
                """,
                (status, status, event.receipt_id),
            )
            row = cursor.fetchone()
            if row is None:
                raise RuntimeError("ocr_result_missing")
            result = EnrichmentResult.model_validate(row)
            ciphertext = encrypt_json(settings, event.site_id, event.receipt_id, "gst_audit", sensitive_audit)
            cursor.execute(
                """
                INSERT INTO immutable_enrichment_audits
                  (id, organization_id, receipt_id, event_type, event_json, sensitive_event_ciphertext)
                VALUES (%s, %s, %s, 'GST_VALIDATED', %s, %s)
                ON CONFLICT (receipt_id, event_type) DO NOTHING
                """,
                (uuid4(), event.organization_id, event.receipt_id, Jsonb({"gst_status": status, "sensitive_fields": "kms_encrypted"}), ciphertext),
            )
            _insert_callback(cursor, event, result)
            if credit_payload is not None and settings.credit_provider != "disabled":
                cursor.execute(
                    """
                    INSERT INTO transactional_outbox
                      (id, organization_id, aggregate_id, event_type, event_version, destination, idempotency_key, payload_json)
                    VALUES (%s, %s, %s, 'CREDIT_DELIVERY', %s, 'CREDIT_QUEUE', %s, %s)
                    ON CONFLICT (aggregate_id, event_type, event_version) DO NOTHING
                    """,
                    (uuid4(), event.organization_id, event.receipt_id, result.version, f"credit:{event.receipt_id}:{result.version}", Jsonb(credit_payload)),
                )
            cursor.execute(
                """
                UPDATE workflow_stages
                SET status = 'COMPLETED', completed_at = NOW(), locked_until = NULL, updated_at = NOW()
                WHERE receipt_id = %s AND stage = 'GST'
                """,
                (event.receipt_id,),
            )
        connection.commit()
    return result


def finalize_provider_failure(settings: Settings, event: ReceiptEvent, stage: str, error_code: str) -> EnrichmentResult:
    with tenant_connection(settings.database_url, event.organization_id, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO enrichment_receipts (
                  receipt_id, organization_id, site_id, vendor_id, captured_at_unix, site_captured_quantity,
                  image_sha256, image_bytes, status, raw_ocr_json, provider_version, gst_status,
                  processing_started_at, processing_completed_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'NEEDS_HUMAN_REVIEW', %s, 'provider-failure', 'NOT_CHECKED', NOW(), NOW())
                ON CONFLICT (receipt_id) DO UPDATE SET
                  status = 'NEEDS_HUMAN_REVIEW', version = enrichment_receipts.version + 1,
                  processing_completed_at = NOW(), updated_at = NOW()
                RETURNING receipt_id, status, ocr_confidence, raw_ocr_json, gst_status, version
                """,
                (
                    event.receipt_id, event.organization_id, event.site_id, event.vendor_id,
                    event.captured_at_unix, event.site_captured_quantity, event.image_sha256,
                    event.image_bytes, Jsonb({"provider_error": error_code[:120]}),
                ),
            )
            result = EnrichmentResult.model_validate(cursor.fetchone())
            cursor.execute(
                """
                INSERT INTO immutable_enrichment_audits (id, organization_id, receipt_id, event_type, event_json)
                VALUES (%s, %s, %s, 'PROVIDER_FAILED_TERMINAL', %s)
                ON CONFLICT (receipt_id, event_type) DO NOTHING
                """,
                (uuid4(), event.organization_id, event.receipt_id, Jsonb({"stage": stage, "error_code": error_code[:120]})),
            )
            _insert_callback(cursor, event, result)
        connection.commit()
    return result


def existing_enrichment_result(database_url: str, organization_id: str, receipt_id: str) -> EnrichmentResult | None:
    with tenant_connection(database_url, organization_id, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT receipt_id, status, ocr_confidence, raw_ocr_json, gst_status, version
                FROM enrichment_receipts WHERE receipt_id = %s
                """,
                (receipt_id,),
            )
            row = cursor.fetchone()
    return None if row is None else EnrichmentResult.model_validate(row)


def load_gst_context(settings: Settings, event: ReceiptEvent, kms_client=None) -> GstReceiptContext:
    with tenant_connection(settings.database_url, event.organization_id, row_factory=dict_row) as connection:
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
