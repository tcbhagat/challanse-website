import hashlib
import json
import os
import time
from io import BytesIO
from pathlib import Path
from uuid import uuid4

import boto3
import psycopg
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings, get_settings
from app.encryption import decrypt_json, encrypt_json
from app.gst import quantities_match, validate_gst
from app.images import InvalidReceiptImage, verify_webp, webp_to_png
from app.ingress import MemoryIngressStore, PostgresIngressStore
from app.jobs import apply_retention, generate_digests, generate_nightly_report, record_telemetry
from app.main import app, get_ingress_store_dependency
from app.notifications import DigestReceipt, aggregate_digests
from app.queueing import MemoryEventQueue, SqsEventQueue, get_event_queue
from app.providers import MemoryCreditQueue
from app.reconciliation import (
    delta_rows,
    digest_history_for_site,
    enrichment_status_for_site,
    import_tally_csv,
    parse_tally_csv,
    reconciliation_for_site,
    record_verified_review,
    set_site_manager,
)
from app.schemas import GstReceiptContext, ReceiptEvent, TelemetryBatch, VerifiedReviewEvent
from app.security import ServiceRequest, consume_service_nonce, sha256_hex, sign_service_request
from app.telemetry import SiteMetric, threshold_alerts


RECEIPT_ID = "11111111-1111-4111-8111-111111111111"
SITE_ID = "22222222-2222-4222-8222-222222222222"
HMAC_KEY_ID = "edge-current"
HMAC_SECRET = "test-edge-secret"


class FakeResponse:
    status_code = 200

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, object]:
        return {"IRN_Hash": "irn-001", "e_invoice_quantity": 110.0}


class FakeHttpClient:
    def post(self, *args, **kwargs) -> FakeResponse:
        assert kwargs["timeout"] == 3.0
        return FakeResponse()


class FakeKms:
    plaintext_key = b"k" * 32

    def generate_data_key(self, **kwargs):
        assert kwargs["EncryptionContext"]["service"] == "challanse-enrichment"
        return {"Plaintext": self.plaintext_key, "CiphertextBlob": b"encrypted-data-key"}

    def decrypt(self, **kwargs):
        assert kwargs["CiphertextBlob"] == b"encrypted-data-key"
        return {"Plaintext": self.plaintext_key}


def receipt_payload(receipt_id: str = RECEIPT_ID, quantity: float = 100.0) -> dict[str, object]:
    return {
        "receipt_id": receipt_id,
        "site_id": SITE_ID,
        "image_key": f"{SITE_ID}/{receipt_id}.webp",
        "vendor_id": "vendor-1",
        "captured_at_unix": 1_700_000_000,
        "site_captured_quantity": quantity,
        "image_sha256": "a" * 64,
        "image_bytes": 500_000,
        "schema_version": "1.0",
    }


def signed_headers(body: bytes, request_id: str | None = None) -> dict[str, str]:
    timestamp = str(int(time.time()))
    request_id = request_id or str(uuid4())
    content_sha256 = sha256_hex(body)
    return {
        "X-ChallanSe-Signature": sign_service_request(
            HMAC_SECRET,
            timestamp,
            request_id,
            HMAC_KEY_ID,
            "POST",
            "/v1/events/receipts",
            content_sha256,
        ),
        "X-ChallanSe-Timestamp": timestamp,
        "X-ChallanSe-Request-Id": request_id,
        "X-ChallanSe-Key-Id": HMAC_KEY_ID,
        "X-ChallanSe-Content-SHA256": content_sha256,
        "Content-Type": "application/json",
    }


@pytest.fixture
def signed_client():
    settings = Settings(
        EDGE_TO_ENRICHMENT_HMAC_KEY_ID=HMAC_KEY_ID,
        EDGE_TO_ENRICHMENT_HMAC_KEY=HMAC_SECRET,
        EVENT_QUEUE_PROVIDER="memory",
    )
    queue = MemoryEventQueue()
    ingress = MemoryIngressStore()
    app.dependency_overrides[get_settings] = lambda: settings
    app.dependency_overrides[get_event_queue] = lambda: queue
    app.dependency_overrides[get_ingress_store_dependency] = lambda: ingress
    try:
        yield TestClient(app), queue, ingress
    finally:
        app.dependency_overrides.clear()
        get_settings.cache_clear()


def test_ten_percent_mismatch_blocks_credit_queue() -> None:
    settings = Settings(GST_PROVIDER="http", GST_TIMEOUT_SECONDS=3.0)
    queue = MemoryCreditQueue()
    status, audit = validate_gst(
        settings,
        GstReceiptContext(
            receipt_id="receipt-001",
            vendor_gst_number="27ABCDE1234F1Z5",
            developer_gst_number="27AAAAA0000A1Z5",
            timestamp_unix=1_700_000_000,
            site_captured_quantity=100.0,
            material_description="cement",
            site_geo_hash="site-hash",
        ),
        queue,
        FakeHttpClient(),
    )
    assert status == "GST_ANOMALY"
    assert audit["irn_hash"] == "irn-001"
    assert queue.payloads == []


def test_verified_gst_emits_exact_credit_contract() -> None:
    class MatchingResponse(FakeResponse):
        def json(self) -> dict[str, object]:
            return {"IRN_Hash": "irn-match", "e_invoice_quantity": 100.0}

    class MatchingClient(FakeHttpClient):
        def post(self, *args, **kwargs) -> FakeResponse:
            super().post(*args, **kwargs)
            return MatchingResponse()

    queue = MemoryCreditQueue()
    status, _ = validate_gst(
        Settings(GST_PROVIDER="http", GST_TIMEOUT_SECONDS=3.0),
        GstReceiptContext(
            receipt_id="receipt-verified",
            vendor_gst_number="27ABCDE1234F1Z5",
            developer_gst_number="27AAAAA0000A1Z5",
            timestamp_unix=1_700_000_000,
            site_captured_quantity=100.0,
            material_description="cement",
            site_geo_hash="site-hash",
        ),
        queue,
        MatchingClient(),
    )
    assert status == "VERIFIED_GST"
    assert queue.payloads[0]["schema_version"] == "AA_1.0.0"
    assert queue.payloads[0]["developer_gst_number"] == "27AAAAA0000A1Z5"
    assert queue.payloads[0]["irn_hash"] == "irn-match"


def test_tolerance_boundaries() -> None:
    assert quantities_match(100.0, 102.0)
    assert quantities_match(100.0, 98.0)
    assert not quantities_match(100.0, 102.01)


def test_production_requires_active_and_next_directional_keys() -> None:
    errors = Settings(ENVIRONMENT="production").production_errors()
    assert "EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID_missing" in errors
    assert "EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_missing" in errors
    assert "ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID_missing" in errors
    assert "ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_missing" in errors


def test_signed_event_is_queued_once(signed_client) -> None:
    client, queue, _ = signed_client
    body = json.dumps(receipt_payload(), separators=(",", ":")).encode()
    request_id = str(uuid4())
    first = client.post("/v1/events/receipts", content=body, headers=signed_headers(body, request_id))
    duplicate = client.post("/v1/events/receipts", content=body, headers=signed_headers(body, request_id))
    assert first.status_code == 202
    assert duplicate.status_code == 202
    assert duplicate.json()["status"] == "duplicate"
    assert [event.receipt_id for event in queue.events] == [RECEIPT_ID]


def test_reserved_event_is_reenqueued_after_crash_window(signed_client) -> None:
    client, queue, ingress = signed_client
    body = json.dumps(receipt_payload(), separators=(",", ":")).encode()
    request_id = str(uuid4())
    reservation = ingress.reserve(request_id, HMAC_KEY_ID, sha256_hex(body), ReceiptEvent.model_validate_json(body))
    assert reservation.status == "RESERVED"
    response = client.post("/v1/events/receipts", content=body, headers=signed_headers(body, request_id))
    assert response.status_code == 202
    assert response.json()["status"] == "accepted"
    assert [event.receipt_id for event in queue.events] == [RECEIPT_ID]


def test_request_id_cannot_be_reused_for_different_content(signed_client) -> None:
    client, _, _ = signed_client
    request_id = str(uuid4())
    first_body = json.dumps(receipt_payload(quantity=100), separators=(",", ":")).encode()
    changed_body = json.dumps(receipt_payload(quantity=110), separators=(",", ":")).encode()
    assert client.post("/v1/events/receipts", content=first_body, headers=signed_headers(first_body, request_id)).status_code == 202
    response = client.post("/v1/events/receipts", content=changed_body, headers=signed_headers(changed_body, request_id))
    assert response.status_code == 409
    assert response.json()["detail"] == "request_id_reused_with_different_content"


def test_invalid_content_digest_is_rejected(signed_client) -> None:
    client, queue, _ = signed_client
    body = json.dumps(receipt_payload(), separators=(",", ":")).encode()
    headers = signed_headers(body)
    headers["X-ChallanSe-Content-SHA256"] = "0" * 64
    response = client.post("/v1/events/receipts", content=body, headers=headers)
    assert response.status_code == 401
    assert queue.events == []


def test_webp_integrity_and_in_memory_png_conversion() -> None:
    output = BytesIO()
    Image.new("RGB", (32, 32), "white").save(output, format="WEBP", quality=80)
    webp = output.getvalue()
    verify_webp(webp, hashlib.sha256(webp).hexdigest(), len(webp), 750_000)
    assert webp_to_png(webp).startswith(b"\x89PNG\r\n\x1a\n")
    with pytest.raises(InvalidReceiptImage, match="image_checksum_mismatch"):
        verify_webp(webp, "0" * 64, len(webp), 750_000)


def test_sensitive_envelope_requires_matching_context() -> None:
    settings = Settings(KMS_KEY_ARN="arn:aws:kms:ap-south-1:111122223333:key/test")
    envelope = encrypt_json(settings, SITE_ID, RECEIPT_ID, "gst_audit", {"irn_hash": "secret"}, FakeKms())
    assert b"secret" not in envelope
    assert decrypt_json(settings, SITE_ID, RECEIPT_ID, "gst_audit", envelope, FakeKms()) == {"irn_hash": "secret"}


def test_digest_is_grouped_and_never_per_receipt() -> None:
    digests = aggregate_digests([DigestReceipt("pm-1", False), DigestReceipt("pm-1", True)], "https://review.example")
    assert list(digests) == ["pm-1"]
    assert "2 receipts scanned. 1 failed to read" in digests["pm-1"]


def test_tally_delta_highlights_over_receipt() -> None:
    rows = parse_tally_csv("po_number,material_code,quantity,unit\nPO-1,CEM,100,BAGS\n")
    result = delta_rows({("PO-1", "CEM", "BAG"): 110.0}, rows)
    assert result[0]["is_over"] is True


def test_telemetry_thresholds() -> None:
    alerts = threshold_alerts([SiteMetric("site-1", 101)], [SiteMetric("site-1", 0.21)], [SiteMetric("vendor-1", 69)])
    assert len(alerts) == 3


def reset_test_database(database_url: str) -> None:
    migration_dir = Path(__file__).resolve().parents[1] / "migrations"
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute("DROP SCHEMA public CASCADE")
            cursor.execute("CREATE SCHEMA public")
            for migration in sorted(migration_dir.glob("*.sql")):
                cursor.execute(migration.read_text(encoding="utf-8"))
        connection.commit()


@pytest.mark.integration
def test_postgres_ingress_and_reconciliation_are_idempotent() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    event = ReceiptEvent.model_validate(receipt_payload())
    store = PostgresIngressStore(database_url)
    request_id = str(uuid4())
    first = store.reserve(request_id, HMAC_KEY_ID, "b" * 64, event)
    store.mark_queued(request_id, "sqs-message-1")
    duplicate = store.reserve(request_id, HMAC_KEY_ID, "b" * 64, event)
    assert first.duplicate is False
    assert duplicate.duplicate is True
    assert duplicate.task_id == "sqs-message-1"
    nonce = ServiceRequest(request_id=str(uuid4()), key_id=HMAC_KEY_ID, content_sha256="c" * 64)
    assert consume_service_nonce(database_url, nonce) is True
    assert consume_service_nonce(database_url, nonce) is False

    import_id, duplicate_import, row_count = import_tally_csv(
        database_url,
        SITE_ID,
        "reviewer@example.com",
        "po_number,material_code,quantity,unit\nPO-1,CEM,100,BAG\n",
    )
    repeated_id, repeated, _ = import_tally_csv(
        database_url,
        SITE_ID,
        "reviewer@example.com",
        "po_number,material_code,quantity,unit\nPO-1,CEM,100,BAG\n",
    )
    assert row_count == 1 and duplicate_import is False
    assert repeated is True and repeated_id == import_id
    record_verified_review(database_url, VerifiedReviewEvent(
        receipt_id=RECEIPT_ID,
        site_id=SITE_ID,
        po_number="PO-1",
        material_code="CEM",
        verified_quantity=110,
        unit="BAG",
        reviewer_id="reviewer@example.com",
        review_version=1,
        reviewed_at_iso8601="2026-07-16T00:00:00Z",
    ))
    rows = reconciliation_for_site(database_url, SITE_ID)
    assert rows[0]["site_received"] == 110
    assert rows[0]["is_over"] is True

    settings = Settings(DATABASE_URL=database_url)
    record_telemetry(settings, TelemetryBatch.model_validate({"measurements": [
        {
            "source_event_id": "device-1:write-1",
            "site_id": SITE_ID,
            "vendor_id": "vendor-1",
            "metric_name": "frontend_write_duration_ms",
            "metric_value": 101,
            "sample_count": 1,
            "period_start": "2026-07-16T00:00:00Z",
            "period_end": "2026-07-16T00:00:00Z",
        },
        {
            "source_event_id": "device-1:sync-1",
            "site_id": SITE_ID,
            "vendor_id": "vendor-1",
            "metric_name": "sync_failure_rate",
            "metric_value": 0.25,
            "sample_count": 4,
            "period_start": "2026-07-16T00:00:00Z",
            "period_end": "2026-07-16T00:00:00Z",
        },
    ]}))
    alerts = generate_nightly_report(settings)
    assert any(alert.startswith("UI_LAG") for alert in alerts)
    assert any(alert.startswith("SYNC_FAILURE") for alert in alerts)


@pytest.mark.integration
def test_digest_and_retention_jobs_are_idempotent() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    recent_id = "33333333-3333-4333-8333-333333333333"
    expired_id = "44444444-4444-4444-8444-444444444444"
    current_id = "55555555-5555-4555-8555-555555555555"
    set_site_manager(database_url, SITE_ID, "manager@example.com", True)
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO enrichment_receipts
                  (receipt_id, site_id, vendor_id, captured_at_unix, site_captured_quantity, status, created_at)
                VALUES (%s, %s, 'vendor-1', 1700000000, 10, 'NEEDS_HUMAN_REVIEW', NOW() - INTERVAL '91 days'),
                       (%s, %s, 'vendor-1', 1600000000, 10, 'READY_FOR_REVIEW', NOW() - INTERVAL '366 days'),
                       (%s, %s, 'vendor-1', 1800000000, 10, 'NEEDS_HUMAN_REVIEW', NOW())
                """,
                (recent_id, SITE_ID, expired_id, SITE_ID, current_id, SITE_ID),
            )
            cursor.execute(
                "INSERT INTO workflow_stages (receipt_id, stage, status, attempts) VALUES (%s, 'OCR', 'FAILED_RETRYABLE', 2)",
                (current_id,),
            )
        connection.commit()
    settings = Settings(DATABASE_URL=database_url)
    assert generate_digests(settings) == 1
    assert generate_digests(settings) == 0
    assert digest_history_for_site(database_url, SITE_ID)[0]["manager_id"] == "manager@example.com"
    status_rows = enrichment_status_for_site(database_url, SITE_ID, current_id)
    assert status_rows[0]["retry_status"] == "FAILED_RETRYABLE"
    assert status_rows[0]["attempts"] == 2
    first_tombstones, deleted = apply_retention(settings)
    second_tombstones, deleted_again = apply_retention(settings)
    assert first_tombstones == 2 and deleted == 1
    assert second_tombstones == 0 and deleted_again == 0
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) FROM enrichment_receipts")
            assert cursor.fetchone()[0] == 2


@pytest.mark.integration
def test_localstack_sqs_accepts_versioned_receipt_event() -> None:
    endpoint = os.getenv("AWS_ENDPOINT_URL")
    if not endpoint:
        pytest.skip("AWS_ENDPOINT_URL is not configured")
    client = boto3.client("sqs", region_name="ap-south-1", endpoint_url=endpoint)
    queue_url = client.create_queue(QueueName=f"challanse-test-{uuid4()}")["QueueUrl"]
    event = ReceiptEvent.model_validate(receipt_payload())
    message_id = SqsEventQueue(queue_url, "ap-south-1", client).enqueue(event)
    received = client.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1, WaitTimeSeconds=1)
    assert message_id
    assert json.loads(received["Messages"][0]["Body"])["receipt_id"] == RECEIPT_ID
