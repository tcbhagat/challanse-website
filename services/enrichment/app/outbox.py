from dataclasses import dataclass
from typing import Any
from uuid import UUID

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .config import Settings
from .providers import credit_queue
from .queueing import get_event_queue
from .schemas import EnrichmentResult, ReceiptEvent
from .tenancy import system_connection, tenant_connection


@dataclass(frozen=True)
class OutboxEvent:
    id: UUID
    organization_id: UUID
    aggregate_id: UUID
    event_type: str
    destination: str
    idempotency_key: str
    payload: dict[str, Any]
    attempts: int


def claim_outbox_events(database_url: str, limit: int = 20) -> list[OutboxEvent]:
    with system_connection(database_url, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                WITH candidates AS (
                  SELECT id FROM transactional_outbox
                  WHERE ((status IN ('PENDING', 'FAILED_RETRYABLE') AND available_at <= NOW())
                     OR (status = 'PROCESSING' AND locked_until < NOW()))
                  ORDER BY created_at
                  FOR UPDATE SKIP LOCKED
                  LIMIT %s
                )
                UPDATE transactional_outbox AS outbox
                SET status = 'PROCESSING', attempts = attempts + 1,
                    locked_until = NOW() + INTERVAL '2 minutes', updated_at = NOW()
                FROM candidates
                WHERE outbox.id = candidates.id
                RETURNING outbox.id, outbox.event_type, outbox.destination,
                          outbox.organization_id, outbox.aggregate_id, outbox.idempotency_key,
                          outbox.payload_json, outbox.attempts
                """,
                (limit,),
            )
            rows = cursor.fetchall()
            for row in rows:
                stage = _delivery_stage(str(row["event_type"]))
                if stage:
                    cursor.execute(
                        """
                        INSERT INTO workflow_stages
                          (organization_id, receipt_id, stage, status, attempts, locked_until)
                        VALUES (%s, %s, %s, 'PROCESSING', 1, NOW() + INTERVAL '2 minutes')
                        ON CONFLICT (receipt_id, stage) DO UPDATE SET
                          status = 'PROCESSING', attempts = workflow_stages.attempts + 1,
                          locked_until = NOW() + INTERVAL '2 minutes', last_error_code = NULL,
                          updated_at = NOW()
                        """,
                        (row["organization_id"], row["aggregate_id"], stage),
                    )
        connection.commit()
    return [
        OutboxEvent(
            id=UUID(str(row["id"])),
            organization_id=UUID(str(row["organization_id"])),
            aggregate_id=UUID(str(row["aggregate_id"])),
            event_type=str(row["event_type"]),
            destination=str(row["destination"]),
            idempotency_key=str(row["idempotency_key"]),
            payload=dict(row["payload_json"]),
            attempts=int(row["attempts"]),
        )
        for row in rows
    ]


def _delivery_stage(event_type: str) -> str | None:
    return {"ENRICHMENT_CALLBACK": "EDGE_CALLBACK", "CREDIT_DELIVERY": "CREDIT_DELIVERY"}.get(event_type)


def mark_outbox_delivered(database_url: str, event: OutboxEvent) -> None:
    with system_connection(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE transactional_outbox
                SET status = 'DELIVERED', delivered_at = NOW(), locked_until = NULL, updated_at = NOW()
                WHERE id = %s AND status = 'PROCESSING'
                """,
                (event.id,),
            )
            stage = _delivery_stage(event.event_type)
            if stage:
                cursor.execute(
                    """
                    UPDATE workflow_stages
                    SET status = 'COMPLETED', completed_at = NOW(), locked_until = NULL, updated_at = NOW()
                    WHERE receipt_id = %s AND stage = %s
                    """,
                    (event.aggregate_id, stage),
                )
        connection.commit()


def mark_outbox_failed(database_url: str, event: OutboxEvent, error_code: str) -> None:
    terminal = event.attempts >= 10
    with system_connection(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE transactional_outbox
                SET status = %s, last_error_code = %s, locked_until = NULL,
                    available_at = NOW() + (LEAST(3600, POWER(2, LEAST(attempts, 10))) * INTERVAL '1 second'),
                    updated_at = NOW()
                WHERE id = %s AND status = 'PROCESSING'
                """,
                ("FAILED_TERMINAL" if terminal else "FAILED_RETRYABLE", error_code[:120], event.id),
            )
            stage = _delivery_stage(event.event_type)
            if stage:
                cursor.execute(
                    """
                    UPDATE workflow_stages
                    SET status = %s, last_error_code = %s, locked_until = NULL, updated_at = NOW()
                    WHERE receipt_id = %s AND stage = %s
                    """,
                    ("FAILED_TERMINAL" if terminal else "FAILED_RETRYABLE", error_code[:120], event.aggregate_id, stage),
                )
        connection.commit()


def mark_outbox_disabled(database_url: str, event: OutboxEvent) -> None:
    with system_connection(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE transactional_outbox SET status = 'DISABLED', locked_until = NULL, updated_at = NOW() WHERE id = %s",
                (event.id,),
            )
            stage = _delivery_stage(event.event_type)
            if stage:
                cursor.execute(
                    "UPDATE workflow_stages SET status = 'DISABLED', locked_until = NULL, updated_at = NOW() WHERE receipt_id = %s AND stage = %s",
                    (event.aggregate_id, stage),
                )
        connection.commit()


def project_enrichment_result(settings: Settings, event: OutboxEvent) -> None:
    result = EnrichmentResult.model_validate(event.payload)
    receipt_status = "NEEDS_REVIEW" if result.status in {
        "READY_FOR_REVIEW", "NEEDS_HUMAN_REVIEW", "VERIFIED_GST", "GST_ANOMALY", "FAILED_TERMINAL"
    } else "RECEIVED"
    with tenant_connection(settings.database_url, str(event.organization_id)) as connection:
        updated = connection.execute(
            """
            UPDATE receipts
            SET status = CASE WHEN status = 'RECEIVED' THEN %s ELSE status END,
                enrichment_status = %s, ocr_confidence = %s, raw_ocr_json = %s,
                gst_status = %s, updated_at = NOW()
            WHERE id = %s AND organization_id = %s
            """,
            (
                receipt_status, result.status, result.ocr_confidence, Jsonb(result.raw_ocr_json),
                result.gst_status, event.aggregate_id, event.organization_id,
            ),
        )
        if updated.rowcount != 1:
            raise RuntimeError("authoritative_receipt_missing")
        connection.commit()


def dispatch_outbox_once(settings: Settings, limit: int = 20) -> int:
    delivered = 0
    for event in claim_outbox_events(settings.database_url, limit):
        try:
            if event.event_type == "ENRICHMENT_CALLBACK":
                project_enrichment_result(settings, event)
            elif event.event_type == "RECEIPT_ENRICHMENT_QUEUE":
                get_event_queue().enqueue(ReceiptEvent.model_validate(event.payload))
            elif event.event_type == "CREDIT_DELIVERY":
                if settings.credit_provider == "disabled":
                    mark_outbox_disabled(settings.database_url, event)
                    continue
                credit_queue(settings).enqueue(event.payload, event.idempotency_key)
            else:
                raise RuntimeError("unsupported_outbox_event")
            mark_outbox_delivered(settings.database_url, event)
            delivered += 1
        except Exception as error:
            mark_outbox_failed(settings.database_url, event, type(error).__name__)
    return delivered
