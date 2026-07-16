import argparse
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .config import Settings, get_settings
from .notifications import DigestReceipt, aggregate_digests
from .telemetry import SiteMetric, threshold_alerts
from .schemas import TelemetryBatch


def record_telemetry(settings: Settings, batch: TelemetryBatch) -> int:
    with psycopg.connect(settings.database_url) as connection:
        with connection.cursor() as cursor:
            for measurement in batch.measurements:
                cursor.execute(
                    """
                    INSERT INTO telemetry_measurements
                      (id, source_event_id, site_id, vendor_id, metric_name, metric_value, sample_count, period_start, period_end)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (source_event_id) DO NOTHING
                    """,
                    (
                        uuid4(), measurement.source_event_id, measurement.site_id, measurement.vendor_id, measurement.metric_name,
                        measurement.metric_value, measurement.sample_count, measurement.period_start, measurement.period_end,
                    ),
                )
        connection.commit()
    return len(batch.measurements)


def generate_digests(settings: Settings) -> int:
    now = datetime.now(timezone.utc).replace(microsecond=0)
    period_start = now.replace(hour=(now.hour // 4) * 4, minute=0, second=0)
    period_end = period_start + timedelta(hours=4)
    with psycopg.connect(settings.database_url, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT m.site_id, m.manager_id, COUNT(r.receipt_id) AS receipt_count,
                       COUNT(r.receipt_id) FILTER (WHERE r.status = 'NEEDS_HUMAN_REVIEW') AS failed_count
                FROM site_managers m
                LEFT JOIN enrichment_receipts r ON r.site_id = m.site_id AND r.created_at >= %s AND r.created_at < %s
                WHERE m.active = TRUE
                GROUP BY m.site_id, m.manager_id
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
                      (id, site_id, manager_id, period_start, period_end, receipt_count, failed_count, body, provider_status)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'DISABLED')
                    ON CONFLICT (site_id, manager_id, period_start, period_end) DO NOTHING
                    """,
                    (uuid4(), row["site_id"], row["manager_id"], period_start, period_end, row["receipt_count"], row["failed_count"], body),
                )
                inserted += cursor.rowcount
        connection.commit()
    return inserted


def generate_nightly_report(settings: Settings) -> list[str]:
    with psycopg.connect(settings.database_url, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT site_id, metric_name, SUM(metric_value * sample_count) / SUM(sample_count) AS value
                FROM telemetry_measurements WHERE period_end >= NOW() - INTERVAL '24 hours'
                GROUP BY site_id, metric_name
                """
            )
            telemetry = cursor.fetchall()
            cursor.execute(
                """
                SELECT vendor_id, AVG(ocr_confidence) AS value FROM enrichment_receipts
                WHERE processing_completed_at >= NOW() - INTERVAL '24 hours' AND ocr_confidence IS NOT NULL
                GROUP BY vendor_id
                """
            )
            ocr = cursor.fetchall()
            alerts = threshold_alerts(
                [SiteMetric(str(row["site_id"]), float(row["value"])) for row in telemetry if row["metric_name"] == "frontend_write_duration_ms"],
                [SiteMetric(str(row["site_id"]), float(row["value"])) for row in telemetry if row["metric_name"] == "sync_failure_rate"],
                [SiteMetric(str(row["vendor_id"]), float(row["value"])) for row in ocr],
            )
            cursor.execute(
                """
                INSERT INTO nightly_friction_reports (id, report_date, alerts_json, provider_status)
                VALUES (%s, CURRENT_DATE, %s, 'DISABLED')
                ON CONFLICT (report_date) DO UPDATE SET alerts_json = excluded.alerts_json
                """,
                (uuid4(), Jsonb(alerts)),
            )
        connection.commit()
    return alerts


def apply_retention(settings: Settings) -> tuple[int, int]:
    with psycopg.connect(settings.database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO retention_tombstones (id, receipt_id, resource_type)
                SELECT gen_random_uuid(), receipt_id, 'EDGE_IMAGE'
                FROM enrichment_receipts WHERE created_at < NOW() - INTERVAL '90 days'
                ON CONFLICT (receipt_id, resource_type) DO NOTHING
                """
            )
            image_tombstones = cursor.rowcount
            cursor.execute("SELECT receipt_id FROM enrichment_receipts WHERE created_at < NOW() - INTERVAL '1 year'")
            expired = [row[0] for row in cursor.fetchall()]
            if expired:
                cursor.execute("DELETE FROM immutable_enrichment_audits WHERE receipt_id = ANY(%s)", (expired,))
                cursor.execute("DELETE FROM transactional_outbox WHERE aggregate_id = ANY(%s)", (expired,))
                cursor.execute("DELETE FROM workflow_stages WHERE receipt_id = ANY(%s)", (expired,))
                cursor.execute("DELETE FROM service_ingress_requests WHERE receipt_id = ANY(%s)", (expired,))
                cursor.execute("DELETE FROM verified_receipts WHERE receipt_id = ANY(%s)", (expired,))
                cursor.execute("DELETE FROM enrichment_receipts WHERE receipt_id = ANY(%s)", (expired,))
        connection.commit()
    return image_tombstones, len(expired)


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
