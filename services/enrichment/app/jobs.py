import argparse
import logging
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import boto3
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .config import Settings, get_settings
from .notifications import DigestReceipt, aggregate_digests
from .telemetry import SiteMetric, threshold_alerts
from .schemas import TelemetryBatch
from .image_store import delete_all_object_versions
from .tenancy import system_connection, tenant_connection


logger = logging.getLogger("challanse.enrichment.jobs")


def record_telemetry(settings: Settings, batch: TelemetryBatch) -> int:
    inserted = 0
    organizations = {measurement.organization_id for measurement in batch.measurements}
    for organization_id in organizations:
        with tenant_connection(settings.database_url, organization_id) as connection:
            with connection.cursor() as cursor:
                for measurement in (item for item in batch.measurements if item.organization_id == organization_id):
                    cursor.execute(
                        """
                        INSERT INTO telemetry_measurements
                          (id, organization_id, source_event_id, site_id, vendor_id, metric_name, metric_value, sample_count, period_start, period_end)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (source_event_id) DO NOTHING
                        """,
                        (
                            uuid4(), measurement.organization_id, measurement.source_event_id, measurement.site_id,
                            measurement.vendor_id, measurement.metric_name, measurement.metric_value,
                            measurement.sample_count, measurement.period_start, measurement.period_end,
                        ),
                    )
                    inserted += cursor.rowcount
            connection.commit()
    return inserted


def generate_digests(settings: Settings) -> int:
    now = datetime.now(timezone.utc).replace(microsecond=0)
    period_start = now.replace(hour=(now.hour // 4) * 4, minute=0, second=0)
    period_end = period_start + timedelta(hours=4)
    with system_connection(settings.database_url, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT m.organization_id, m.site_id, m.manager_id, COUNT(r.receipt_id) AS receipt_count,
                       COUNT(r.receipt_id) FILTER (WHERE r.status = 'NEEDS_HUMAN_REVIEW') AS failed_count
                FROM site_managers m
                LEFT JOIN enrichment_receipts r ON r.site_id = m.site_id AND r.created_at >= %s AND r.created_at < %s
                WHERE m.active = TRUE
                GROUP BY m.organization_id, m.site_id, m.manager_id
                """,
                (period_start, period_end),
            )
            rows = cursor.fetchall()
            inserted = 0
            for row in rows:
                if int(row["receipt_count"]) == 0:
                    continue
                receipts = [DigestReceipt(str(row["manager_id"]), index < int(row["failed_count"])) for index in range(int(row["receipt_count"]))]
                body = aggregate_digests(receipts, settings.review_dashboard_url)[str(row["manager_id"])]
                cursor.execute(
                    """
                    INSERT INTO notification_digests
                      (id, organization_id, site_id, manager_id, period_start, period_end, receipt_count, failed_count, body, provider_status)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, 'DISABLED')
                    ON CONFLICT (site_id, manager_id, period_start, period_end) DO NOTHING
                    """,
                    (uuid4(), row["organization_id"], row["site_id"], row["manager_id"], period_start, period_end, row["receipt_count"], row["failed_count"], body),
                )
                inserted += cursor.rowcount
        connection.commit()
    return inserted


def generate_nightly_report(settings: Settings) -> list[str]:
    with system_connection(settings.database_url, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT organization_id, site_id, metric_name, SUM(metric_value * sample_count) / SUM(sample_count) AS value
                FROM telemetry_measurements WHERE period_end >= NOW() - INTERVAL '24 hours'
                GROUP BY organization_id, site_id, metric_name
                """
            )
            telemetry = cursor.fetchall()
            cursor.execute(
                """
                SELECT organization_id, vendor_id, AVG(ocr_confidence) AS value FROM enrichment_receipts
                WHERE processing_completed_at >= NOW() - INTERVAL '24 hours' AND ocr_confidence IS NOT NULL
                GROUP BY organization_id, vendor_id
                """
            )
            ocr = cursor.fetchall()
            alerts: list[str] = []
            organization_ids = {str(row["organization_id"]) for row in telemetry} | {str(row["organization_id"]) for row in ocr}
            for organization_id in organization_ids:
                organization_alerts = threshold_alerts(
                    [SiteMetric(str(row["site_id"]), float(row["value"])) for row in telemetry if str(row["organization_id"]) == organization_id and row["metric_name"] == "frontend_write_duration_ms"],
                    [SiteMetric(str(row["site_id"]), float(row["value"])) for row in telemetry if str(row["organization_id"]) == organization_id and row["metric_name"] == "sync_failure_rate"],
                    [SiteMetric(str(row["vendor_id"]), float(row["value"])) for row in ocr if str(row["organization_id"]) == organization_id],
                )
                alerts.extend(organization_alerts)
                cursor.execute(
                    """
                    INSERT INTO nightly_friction_reports (id, organization_id, report_date, alerts_json, provider_status)
                    VALUES (%s, %s, CURRENT_DATE, %s, 'DISABLED')
                    ON CONFLICT (organization_id, report_date) DO UPDATE SET alerts_json = excluded.alerts_json
                    """,
                    (uuid4(), organization_id, Jsonb(organization_alerts)),
                )
        connection.commit()
    return alerts


def cleanup_orphan_uploads(settings: Settings) -> int:
    if not settings.receipt_bucket:
        raise RuntimeError("receipt_bucket_unconfigured")
    s3 = boto3.client("s3", region_name=settings.aws_region)
    with system_connection(settings.database_url, row_factory=dict_row) as connection:
        rows = connection.execute(
            """
            SELECT id, organization_id, status, final_object_key
            FROM upload_sessions
            WHERE (status IN ('OPEN', 'COMPLETING') AND expires_at < NOW())
               OR (status = 'COMPLETING' AND updated_at < NOW() - INTERVAL '15 minutes')
               OR (status = 'COMPLETE' AND updated_at < NOW() - INTERVAL '15 minutes'
                   AND EXISTS (SELECT 1 FROM upload_parts WHERE upload_id = upload_sessions.id))
            ORDER BY updated_at LIMIT 500
            """
        ).fetchall()
    cleaned = 0
    for row in rows:
        organization_id = str(row["organization_id"])
        with tenant_connection(settings.database_url, organization_id, row_factory=dict_row) as connection:
            parts = connection.execute(
                "SELECT object_key FROM upload_parts WHERE upload_id = %s ORDER BY part_number",
                (row["id"],),
            ).fetchall()
        object_keys = [str(part["object_key"]) for part in parts]
        if row["status"] != "COMPLETE" and row["final_object_key"]:
            object_keys.append(str(row["final_object_key"]))
        try:
            for object_key in object_keys:
                delete_all_object_versions(s3, settings.receipt_bucket, object_key)
        except Exception as cleanup_error:
            logger.warning(
                "expired_upload_cleanup_failed",
                extra={"error_code": type(cleanup_error).__name__},
            )
            continue
        with tenant_connection(settings.database_url, organization_id) as connection:
            connection.execute("DELETE FROM upload_parts WHERE upload_id = %s", (row["id"],))
            connection.execute(
                "UPDATE upload_sessions SET status = 'EXPIRED', updated_at = NOW() WHERE id = %s AND status IN ('OPEN', 'COMPLETING')",
                (row["id"],),
            )
            connection.commit()
        cleaned += 1
    cutoff = datetime.now(timezone.utc) - timedelta(hours=25)
    continuation_token: str | None = None
    untracked_candidates: list[str] = []
    while len(untracked_candidates) < 500:
        request: dict[str, object] = {"Bucket": settings.receipt_bucket, "MaxKeys": 1000}
        if continuation_token:
            request["ContinuationToken"] = continuation_token
        response = s3.list_objects_v2(**request)
        for item in response.get("Contents", []):
            key = str(item.get("Key", ""))
            last_modified = item.get("LastModified")
            if "/uploads/" not in key or not isinstance(last_modified, datetime):
                continue
            if last_modified.astimezone(timezone.utc) < cutoff:
                untracked_candidates.append(key)
                if len(untracked_candidates) >= 500:
                    break
        if len(untracked_candidates) >= 500 or not response.get("IsTruncated"):
            break
        continuation_token = str(response.get("NextContinuationToken", "")) or None
    if untracked_candidates:
        with system_connection(settings.database_url) as connection:
            tracked_rows = connection.execute(
                "SELECT object_key FROM upload_parts WHERE object_key = ANY(%s)",
                (untracked_candidates,),
            ).fetchall()
        tracked_keys = {str(row[0]) for row in tracked_rows}
        for object_key in (key for key in untracked_candidates if key not in tracked_keys):
            try:
                delete_all_object_versions(s3, settings.receipt_bucket, object_key)
            except Exception as cleanup_error:
                logger.warning(
                    "untracked_upload_cleanup_failed",
                    extra={"error_code": type(cleanup_error).__name__},
                )
                continue
            cleaned += 1
    with system_connection(settings.database_url) as connection:
        connection.execute("DELETE FROM device_request_nonces WHERE expires_at < NOW()")
        connection.commit()
    return cleaned


def apply_retention(settings: Settings) -> tuple[int, int]:
    if not settings.receipt_bucket:
        raise RuntimeError("receipt_bucket_unconfigured")
    s3 = boto3.client("s3", region_name=settings.aws_region)
    with system_connection(settings.database_url, row_factory=dict_row) as connection:
        images = connection.execute(
            """
            SELECT id, organization_id, site_id, image_key, image_bytes
            FROM receipts
            WHERE image_deleted_at IS NULL AND created_at < NOW() - INTERVAL '90 days'
            ORDER BY created_at LIMIT 500
            """
        ).fetchall()
    deleted_images = 0
    for image in images:
        organization_id = str(image["organization_id"])
        with tenant_connection(settings.database_url, organization_id) as connection:
            connection.execute(
                """
                INSERT INTO retention_tombstones (id, organization_id, receipt_id, resource_type, status)
                VALUES (%s, %s, %s, 'S3_IMAGE', 'PENDING')
                ON CONFLICT (receipt_id, resource_type) DO UPDATE
                SET status = 'PENDING', completed_at = NULL, requested_at = NOW()
                """,
                (uuid4(), image["organization_id"], image["id"]),
            )
            connection.commit()
        try:
            delete_all_object_versions(s3, settings.receipt_bucket, str(image["image_key"]))
        except Exception:
            with tenant_connection(settings.database_url, organization_id) as connection:
                connection.execute(
                    """
                    UPDATE retention_tombstones SET status = 'FAILED_RETRYABLE', completed_at = NULL
                    WHERE receipt_id = %s AND resource_type = 'S3_IMAGE'
                    """,
                    (image["id"],),
                )
                connection.commit()
            continue
        with tenant_connection(settings.database_url, organization_id) as connection:
            connection.execute(
                """
                INSERT INTO retention_tombstones (id, organization_id, receipt_id, resource_type, status, completed_at)
                VALUES (%s, %s, %s, 'S3_IMAGE', 'COMPLETED', NOW())
                ON CONFLICT (receipt_id, resource_type) DO UPDATE SET status = 'COMPLETED', completed_at = NOW()
                """,
                (uuid4(), image["organization_id"], image["id"]),
            )
            updated = connection.execute(
                "UPDATE receipts SET image_deleted_at = NOW(), updated_at = NOW() WHERE id = %s AND image_deleted_at IS NULL RETURNING image_bytes",
                (image["id"],),
            ).fetchone()
            if updated:
                connection.execute(
                    "UPDATE organizations SET stored_image_bytes = GREATEST(0, stored_image_bytes - %s), updated_at = NOW() WHERE id = %s",
                    (int(updated[0]), image["organization_id"]),
                )
            connection.commit()
        deleted_images += 1

    with system_connection(settings.database_url, row_factory=dict_row) as connection:
        expired_rows = connection.execute(
            "SELECT id, organization_id FROM receipts WHERE created_at < NOW() - INTERVAL '1 year' ORDER BY created_at LIMIT 1000"
        ).fetchall()
    expired_count = 0
    for organization_id in {str(row["organization_id"]) for row in expired_rows}:
        receipt_ids = [row["id"] for row in expired_rows if str(row["organization_id"]) == organization_id]
        with tenant_connection(settings.database_url, organization_id) as connection:
            connection.execute("DELETE FROM audit_events WHERE receipt_id = ANY(%s)", (receipt_ids,))
            connection.execute("DELETE FROM immutable_enrichment_audits WHERE receipt_id = ANY(%s)", (receipt_ids,))
            connection.execute("DELETE FROM transactional_outbox WHERE aggregate_id = ANY(%s)", (receipt_ids,))
            connection.execute("DELETE FROM workflow_stages WHERE receipt_id = ANY(%s)", (receipt_ids,))
            connection.execute("DELETE FROM service_ingress_requests WHERE receipt_id = ANY(%s)", (receipt_ids,))
            connection.execute("DELETE FROM verified_receipts WHERE receipt_id = ANY(%s)", (receipt_ids,))
            connection.execute("DELETE FROM enrichment_receipts WHERE receipt_id = ANY(%s)", (receipt_ids,))
            connection.execute("DELETE FROM upload_sessions WHERE receipt_id = ANY(%s)", (receipt_ids,))
            connection.execute("DELETE FROM receipts WHERE id = ANY(%s)", (receipt_ids,))
            connection.commit()
        expired_count += len(receipt_ids)
    cleanup_orphan_uploads(settings)
    return deleted_images, expired_count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("job", choices=("digest", "telemetry", "retention"))
    job = parser.parse_args().job
    settings = get_settings()
    if not settings.database_url:
        raise RuntimeError("database_url_unconfigured")
    if job == "digest":
        generate_digests(settings)
    elif job == "telemetry":
        generate_nightly_report(settings)
    else:
        apply_retention(settings)


if __name__ == "__main__":
    main()
