import hashlib
import json
import os
import time
from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path
from uuid import UUID, uuid4

import boto3
import psycopg
import pytest
from fastapi.testclient import TestClient
from PIL import Image
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from app import outbox as outbox_module
from app.config import Settings, get_settings
from app.authoritative import (
    AuthoritativeError,
    DeviceContext,
    ReviewerContext,
    admin_configuration,
    accept_membership_invitation,
    complete_upload_session,
    consume_device_nonce,
    create_membership_invitation,
    create_upload_session,
    put_upload_part,
    update_organization_quota,
    upsert_membership,
    upsert_site,
    upsert_vendor,
)
from app.bootstrap import BootstrapVendor, TenantBootstrap, bootstrap_tenant
from app.encryption import decrypt_json, encrypt_json
from app.gst import quantities_match, validate_gst
from app.image_store import delete_all_object_versions
from app.images import InvalidReceiptImage, verify_webp, webp_to_png
from app.integrity import _trusted as trusted_play_integrity_payload
from app.ingress import MemoryIngressStore, PostgresIngressStore
from app.jobs import apply_retention, generate_digests, generate_nightly_report, record_telemetry
from app.main import app, get_ingress_store_dependency
from app.notifications import DigestReceipt, aggregate_digests
from app.outbox import dispatch_outbox_once
from app.queueing import MemoryEventQueue, SqsEventQueue, get_event_queue
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
from app.schemas import (
    GstReceiptContext,
    MembershipAdminRequest,
    MembershipInvitationAcceptance,
    MembershipInvitationRequest,
    QuotaAdminRequest,
    ReceiptEvent,
    SiteAdminRequest,
    TelemetryBatch,
    UploadSessionRequest,
    VendorAdminRequest,
    VerifiedReviewEvent,
)
from app.security import ServiceRequest, consume_service_nonce, sha256_hex, sign_service_request, verify_service_request
from app.storage import save_ocr_result
from app.telemetry import SiteMetric, threshold_alerts
from app.tenancy import system_connection, tenant_connection


RECEIPT_ID = "11111111-1111-4111-8111-111111111111"
SITE_ID = "22222222-2222-4222-8222-222222222222"
ORGANIZATION_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
HMAC_KEY_ID = "edge-current"
HMAC_SECRET = "test-edge-secret"
TENANT_CONTEXT_HMAC_KEY = "7f4b6d8e905ca22ddf3234f6c5551d9a2a712df06f28da7f13a4a92cadf1108c"


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
        "organization_id": ORGANIZATION_ID,
        "site_id": SITE_ID,
        "image_key": f"{SITE_ID}/{receipt_id}.webp",
        "vendor_id": "vendor-1",
        "captured_at_unix": 1_700_000_000,
        "site_captured_quantity": quantity,
        "image_sha256": "a" * 64,
        "image_bytes": 500_000,
        "schema_version": "1.0",
    }


def signed_headers(
    body: bytes,
    request_id: str | None = None,
    path: str = "/v1/events/receipts",
    method: str = "POST",
) -> dict[str, str]:
    timestamp = str(int(time.time()))
    request_id = request_id or str(uuid4())
    content_sha256 = sha256_hex(body)
    return {
        "X-ChallanSe-Signature": sign_service_request(
            HMAC_SECRET,
            timestamp,
            request_id,
            HMAC_KEY_ID,
            method,
            path,
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
    result = validate_gst(
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
        FakeHttpClient(),
    )
    assert result.status == "GST_ANOMALY"
    assert result.audit["irn_hash"] == "irn-001"
    assert result.credit_payload is None


def test_verified_gst_emits_exact_credit_contract() -> None:
    class MatchingResponse(FakeResponse):
        def json(self) -> dict[str, object]:
            return {"IRN_Hash": "irn-match", "e_invoice_quantity": 100.0}

    class MatchingClient(FakeHttpClient):
        def post(self, *args, **kwargs) -> FakeResponse:
            super().post(*args, **kwargs)
            return MatchingResponse()

    result = validate_gst(
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
        MatchingClient(),
    )
    assert result.status == "VERIFIED_GST"
    assert result.credit_payload is not None
    assert result.credit_payload["schema_version"] == "AA_1.0.0"
    assert result.credit_payload["developer_gst_number"] == "27AAAAA0000A1Z5"
    assert result.credit_payload["irn_hash"] == "irn-match"


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


def test_play_integrity_is_a_risk_signal_bound_to_package_and_receipt_hash() -> None:
    payload = {
        "requestDetails": {"requestHash": "a" * 64, "requestPackageName": "com.constrovet.challanse"},
        "appIntegrity": {"appRecognitionVerdict": "PLAY_RECOGNIZED"},
        "deviceIntegrity": {"deviceRecognitionVerdict": ["MEETS_BASIC_INTEGRITY"]},
        "accountDetails": {"appLicensingVerdict": "LICENSED"},
    }
    assert trusted_play_integrity_payload(payload, "a" * 64)
    assert not trusted_play_integrity_payload(payload, "b" * 64)
    payload["requestDetails"]["requestPackageName"] = "com.example.forged"
    assert not trusted_play_integrity_payload(payload, "a" * 64)


def test_receipt_event_supports_the_five_megabyte_upload_contract() -> None:
    payload = receipt_payload()
    payload["image_bytes"] = 5_000_000
    assert ReceiptEvent.model_validate(payload).image_bytes == 5_000_000
    payload["image_bytes"] = 5_000_001
    with pytest.raises(ValueError):
        ReceiptEvent.model_validate(payload)


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


def test_service_signature_binds_query_string() -> None:
    body = b""
    timestamp = str(int(time.time()))
    request_id = str(uuid4())
    target = "/v1/reviewer/receipts?status=NEEDS_REVIEW&limit=25"
    digest = sha256_hex(body)
    signature = sign_service_request(HMAC_SECRET, timestamp, request_id, HMAC_KEY_ID, "GET", target, digest)
    assert verify_service_request(
        {HMAC_KEY_ID: HMAC_SECRET}, body, signature, timestamp, request_id, HMAC_KEY_ID, "GET", target, digest
    ) is not None
    assert verify_service_request(
        {HMAC_KEY_ID: HMAC_SECRET}, body, signature, timestamp, request_id, HMAC_KEY_ID,
        "GET", "/v1/reviewer/receipts?status=VERIFIED&limit=25", digest,
    ) is None


def test_s3_version_deletion_is_exact_and_paginated() -> None:
    deleted: list[dict[str, str]] = []

    class VersionedS3:
        def list_object_versions(self, **kwargs):
            if "KeyMarker" not in kwargs:
                return {
                    "Versions": [
                        {"Key": "tenant/site/image.webp", "VersionId": "v2"},
                        {"Key": "tenant/site/image.webp-copy", "VersionId": "unrelated"},
                    ],
                    "IsTruncated": True,
                    "NextKeyMarker": "tenant/site/image.webp",
                    "NextVersionIdMarker": "v2",
                }
            return {
                "Versions": [{"Key": "tenant/site/image.webp", "VersionId": "v1"}],
                "DeleteMarkers": [{"Key": "tenant/site/image.webp", "VersionId": "marker"}],
                "IsTruncated": False,
            }

        def delete_objects(self, **kwargs):
            deleted.extend(kwargs["Delete"]["Objects"])

    delete_all_object_versions(VersionedS3(), "receipts", "tenant/site/image.webp")
    assert deleted == [
        {"Key": "tenant/site/image.webp", "VersionId": "v2"},
        {"Key": "tenant/site/image.webp", "VersionId": "v1"},
        {"Key": "tenant/site/image.webp", "VersionId": "marker"},
    ]


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
    os.environ["TENANT_CONTEXT_HMAC_KEY"] = TENANT_CONTEXT_HMAC_KEY
    migration_dir = Path(__file__).resolve().parents[1] / "migrations"
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute("DROP SCHEMA public CASCADE")
            cursor.execute("CREATE SCHEMA public")
            for migration in sorted(migration_dir.glob("*.sql")):
                cursor.execute(migration.read_text(encoding="utf-8"))
            cursor.execute(
                "INSERT INTO tenant_context_secrets (singleton, secret) VALUES (TRUE, decode(%s, 'hex'))",
                (TENANT_CONTEXT_HMAC_KEY,),
            )
        connection.commit()


def seed_test_organization(database_url: str) -> None:
    with psycopg.connect(database_url) as connection:
        connection.execute(
            "INSERT INTO organizations (id, slug, name) VALUES (%s, 'test-org', 'Test organization') ON CONFLICT (id) DO NOTHING",
            (ORGANIZATION_ID,),
        )
        connection.commit()


def app_database_url(database_url: str) -> str:
    parameters = conninfo_to_dict(database_url)
    parameters.update(user="challanse_test_app", password="challanse-test-app-only")
    return make_conninfo(**parameters)


def configure_test_app_role(database_url: str) -> str:
    with psycopg.connect(database_url, autocommit=True) as connection:
        connection.execute(
            """
            DO $role$
            BEGIN
              IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'challanse_test_app') THEN
                CREATE ROLE challanse_test_app LOGIN PASSWORD 'challanse-test-app-only' NOBYPASSRLS;
              ELSE
                ALTER ROLE challanse_test_app WITH LOGIN PASSWORD 'challanse-test-app-only' NOBYPASSRLS;
              END IF;
            END
            $role$
            """
        )
        connection.execute("GRANT USAGE ON SCHEMA public TO challanse_test_app")
        connection.execute("GRANT SELECT ON organizations, sites TO challanse_test_app")
        connection.execute("REVOKE ALL ON tenant_context_secrets, tenant_session_contexts FROM PUBLIC, challanse_test_app")
        connection.execute("REVOKE ALL ON FUNCTION challanse_set_tenant_context(UUID, TEXT) FROM PUBLIC")
        connection.execute("GRANT EXECUTE ON FUNCTION challanse_set_tenant_context(UUID, TEXT) TO challanse_test_app")
        connection.execute("GRANT EXECUTE ON FUNCTION challanse_current_organization_id() TO challanse_test_app")
    return app_database_url(database_url)


@pytest.mark.integration
def test_postgres_rls_rejects_forged_tenant_context() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    second_organization_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    with psycopg.connect(database_url) as connection:
        connection.execute(
            "INSERT INTO organizations (id, slug, name) VALUES (%s, 'tenant-a', 'Tenant A'), (%s, 'tenant-b', 'Tenant B')",
            (ORGANIZATION_ID, second_organization_id),
        )
        connection.execute(
            "INSERT INTO sites (id, organization_id, name) VALUES (%s, %s, 'Site A'), (%s, %s, 'Site B')",
            (SITE_ID, ORGANIZATION_ID, "33333333-3333-4333-8333-333333333333", second_organization_id),
        )
        connection.commit()
    app_database_url = configure_test_app_role(database_url)
    with psycopg.connect(app_database_url) as connection:
        assert connection.execute("SELECT COUNT(*) FROM sites").fetchone()[0] == 0
        connection.execute("SELECT set_config('challanse.organization_id', %s, TRUE)", (second_organization_id,))
        assert connection.execute("SELECT COUNT(*) FROM sites").fetchone()[0] == 0
        with pytest.raises(psycopg.errors.RaiseException, match="tenant_context_signature_invalid"):
            connection.execute("SELECT challanse_set_tenant_context(%s::uuid, 'forged')", (second_organization_id,))
        connection.rollback()
    with tenant_connection(app_database_url, ORGANIZATION_ID) as connection:
        rows = connection.execute("SELECT organization_id FROM sites").fetchall()
        assert [str(row[0]) for row in rows] == [ORGANIZATION_ID]


@pytest.mark.integration
def test_tenant_admin_cannot_cross_link_or_remove_the_last_org_admin() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    second_organization_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    second_site_id = "33333333-3333-4333-8333-333333333333"
    reviewer_user_id = "77777777-7777-4777-8777-777777777777"
    issuer = "https://identity.example.com"
    subject = "user-001"
    with psycopg.connect(database_url) as connection:
        connection.execute(
            "INSERT INTO organizations (id, slug, name) VALUES (%s, 'tenant-a', 'Tenant A'), (%s, 'tenant-b', 'Tenant B')",
            (ORGANIZATION_ID, second_organization_id),
        )
        connection.execute(
            "INSERT INTO sites (id, organization_id, name) VALUES (%s, %s, 'Site A'), (%s, %s, 'Site B')",
            (SITE_ID, ORGANIZATION_ID, second_site_id, second_organization_id),
        )
        connection.execute(
            "INSERT INTO users (id, email, display_name) VALUES (%s, 'admin@example.com', 'Admin')",
            (reviewer_user_id,),
        )
        connection.execute(
            "INSERT INTO identity_links (id, user_id, issuer, subject, email) VALUES (%s, %s, %s, %s, 'admin@example.com')",
            (str(uuid4()), reviewer_user_id, issuer, subject),
        )
        connection.execute(
            "INSERT INTO organization_memberships (organization_id, user_id, role) VALUES (%s, %s, 'ORG_ADMIN')",
            (ORGANIZATION_ID, reviewer_user_id),
        )
        connection.commit()
    reviewer = ReviewerContext(
        user_id=UUID(reviewer_user_id),
        organization_id=UUID(ORGANIZATION_ID),
        site_id=UUID(SITE_ID),
        role="ORG_ADMIN",
        email="admin@example.com",
        issuer=issuer,
        subject=subject,
    )
    settings = Settings(DATABASE_URL=database_url, SYSTEM_DATABASE_URL=database_url)
    upsert_site(settings, reviewer, SiteAdminRequest.model_validate({
        "siteId": SITE_ID,
        "name": "Updated Site A",
        "allowedWifiSsids": ["Site Office"],
        "dailyReceiptLimit": 1000,
        "imageByteLimit": 5_000_000,
        "active": True,
    }))
    upsert_vendor(settings, reviewer, VendorAdminRequest.model_validate({
        "vendorId": "vendor-1", "name": "Vendor One", "initials": "V1", "color": "#0F766E",
    }))
    update_organization_quota(settings, reviewer, QuotaAdminRequest.model_validate({
        "deviceLimit": 100, "deviceRequestLimitPerMinute": 120,
        "dailyReceiptLimit": 1000, "storageByteLimit": 5_000_000_000,
    }))
    configuration = admin_configuration(settings, reviewer)
    assert [site["id"] for site in configuration["sites"]] == [SITE_ID]
    assert [vendor["id"] for vendor in configuration["vendors"]] == ["vendor-1"]
    assert configuration["organization"]["deviceRequestLimitPerMinute"] == 120
    upsert_membership(settings, reviewer, MembershipAdminRequest.model_validate({
        "issuer": issuer,
        "subject": "second-subject-with-same-email",
        "email": "admin@example.com",
        "role": "REVIEWER",
        "siteIds": [SITE_ID],
        "active": True,
    }))
    with psycopg.connect(database_url) as connection:
        distinct_identity_users = connection.execute(
            "SELECT COUNT(DISTINCT user_id) FROM identity_links WHERE issuer = %s AND email = %s",
            (issuer, "admin@example.com"),
        ).fetchone()[0]
    assert distinct_identity_users == 2
    with pytest.raises(AuthoritativeError, match="LAST_ORG_ADMIN"):
        upsert_membership(settings, reviewer, MembershipAdminRequest.model_validate({
            "issuer": issuer,
            "subject": subject,
            "email": "admin@example.com",
            "role": "REVIEWER",
            "siteIds": [SITE_ID],
            "active": True,
        }))
    with psycopg.connect(database_url) as connection:
        with pytest.raises(psycopg.errors.ForeignKeyViolation):
            connection.execute(
                "INSERT INTO devices (id, organization_id, site_id, name, token_hash, app_version) VALUES (%s, %s, %s, 'Cross tenant', %s, '1.0')",
                (str(uuid4()), ORGANIZATION_ID, second_site_id, "e" * 64),
            )


@pytest.mark.integration
def test_guarded_tenant_bootstrap_is_idempotent_and_binds_immutable_identity() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    payload = TenantBootstrap(
        organization_id=UUID(ORGANIZATION_ID),
        organization_slug="client-one",
        organization_name="Client One",
        site_id=UUID(SITE_ID),
        site_name="Main Site",
        allowed_wifi_ssids=["Site Office"],
        reviewer_issuer="https://identity.example.com",
        reviewer_subject="immutable-subject-001",
        reviewer_email="admin@client.example",
        reviewer_display_name="Client Admin",
        vendors=[BootstrapVendor(id="vendor-1", name="Vendor One", initials="V1", color="#0F766E")],
        confirmation=f"BOOTSTRAP {ORGANIZATION_ID}",
    )
    settings = Settings(ENVIRONMENT="production", DATABASE_ADMIN_URL=database_url)
    first = bootstrap_tenant(settings, payload)
    second = bootstrap_tenant(settings, payload)
    assert first == second == {"organization_id": ORGANIZATION_ID, "site_id": SITE_ID}
    with psycopg.connect(database_url, row_factory=psycopg.rows.dict_row) as connection:
        counts = connection.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM organizations WHERE id = %s) AS organizations,
              (SELECT COUNT(*) FROM sites WHERE id = %s AND organization_id = %s) AS sites,
              (SELECT COUNT(*) FROM identity_links WHERE issuer = %s AND subject = %s) AS identities,
              (SELECT COUNT(*) FROM organization_memberships WHERE organization_id = %s AND role = 'ORG_ADMIN') AS admins,
              (SELECT COUNT(*) FROM audit_events WHERE organization_id = %s AND event_type = 'TENANT_BOOTSTRAPPED') AS bootstrap_events
            """,
            (ORGANIZATION_ID, SITE_ID, ORGANIZATION_ID, payload.reviewer_issuer, payload.reviewer_subject, ORGANIZATION_ID, ORGANIZATION_ID),
        ).fetchone()
    assert counts == {"organizations": 1, "sites": 1, "identities": 1, "admins": 1, "bootstrap_events": 1}
    wrong_confirmation = payload.model_copy(update={"confirmation": "BOOTSTRAP wrong"})
    with pytest.raises(RuntimeError, match="tenant_bootstrap_confirmation_invalid"):
        bootstrap_tenant(settings, wrong_confirmation)


@pytest.mark.integration
def test_membership_invitation_binds_access_identity_once() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    bootstrap_payload = TenantBootstrap(
        organization_id=UUID(ORGANIZATION_ID), organization_slug="client-one", organization_name="Client One",
        site_id=UUID(SITE_ID), site_name="Main Site", allowed_wifi_ssids=["Site Office"],
        reviewer_issuer="https://identity.example.com", reviewer_subject="admin-subject",
        reviewer_email="admin@client.example", reviewer_display_name="Client Admin",
        vendors=[BootstrapVendor(id="vendor-1", name="Vendor One", initials="V1", color="#0F766E")],
        confirmation=f"BOOTSTRAP {ORGANIZATION_ID}",
    )
    bootstrap_tenant(Settings(ENVIRONMENT="production", DATABASE_ADMIN_URL=database_url), bootstrap_payload)
    with psycopg.connect(database_url, row_factory=psycopg.rows.dict_row) as connection:
        admin_id = connection.execute(
            "SELECT user_id FROM identity_links WHERE issuer = %s AND subject = %s",
            (bootstrap_payload.reviewer_issuer, bootstrap_payload.reviewer_subject),
        ).fetchone()["user_id"]
    settings = Settings(DATABASE_URL=database_url, SYSTEM_DATABASE_URL=database_url)
    reviewer = ReviewerContext(
        user_id=UUID(str(admin_id)), organization_id=UUID(ORGANIZATION_ID), site_id=UUID(SITE_ID), role="ORG_ADMIN",
        email=bootstrap_payload.reviewer_email, issuer=bootstrap_payload.reviewer_issuer,
        subject=bootstrap_payload.reviewer_subject,
    )
    invitation = create_membership_invitation(settings, reviewer, MembershipInvitationRequest.model_validate({
        "email": "reviewer@client.example", "displayName": "Site Reviewer", "role": "REVIEWER", "siteIds": [SITE_ID],
    }))
    acceptance = MembershipInvitationAcceptance.model_validate({"invitationCode": invitation["invitationCode"]})
    with pytest.raises(AuthoritativeError, match="MEMBERSHIP_INVITATION_IDENTITY_MISMATCH"):
        accept_membership_invitation(settings, bootstrap_payload.reviewer_issuer, "reviewer-subject", "wrong@client.example", acceptance)
    result = accept_membership_invitation(
        settings, bootstrap_payload.reviewer_issuer, "reviewer-subject", "reviewer@client.example", acceptance
    )
    assert result == {"status": "accepted", "organizationId": ORGANIZATION_ID}
    with pytest.raises(AuthoritativeError, match="MEMBERSHIP_INVITATION_EXPIRED"):
        accept_membership_invitation(
            settings, bootstrap_payload.reviewer_issuer, "reviewer-subject", "reviewer@client.example", acceptance
        )
    with psycopg.connect(database_url) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM site_memberships WHERE organization_id = %s AND site_id = %s AND role = 'REVIEWER' AND active",
            (ORGANIZATION_ID, SITE_ID),
        ).fetchone()[0] == 1


@pytest.mark.integration
def test_reviewer_routes_reject_cross_tenant_payload_scope() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    second_organization_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    second_site_id = "33333333-3333-4333-8333-333333333333"
    issuer = "https://identity.example.com"
    subject = "admin-subject"
    bootstrap_tenant(
        Settings(ENVIRONMENT="production", DATABASE_ADMIN_URL=database_url),
        TenantBootstrap(
            organization_id=UUID(ORGANIZATION_ID), organization_slug="client-one", organization_name="Client One",
            site_id=UUID(SITE_ID), site_name="Main Site", allowed_wifi_ssids=["Site Office"],
            reviewer_issuer=issuer, reviewer_subject=subject, reviewer_email="admin@client.example",
            reviewer_display_name="Client Admin",
            vendors=[BootstrapVendor(id="vendor-1", name="Vendor One", initials="V1", color="#0F766E")],
            confirmation=f"BOOTSTRAP {ORGANIZATION_ID}",
        ),
    )
    with psycopg.connect(database_url) as connection:
        connection.execute(
            "INSERT INTO organizations (id, slug, name) VALUES (%s, 'client-two', 'Client Two')",
            (second_organization_id,),
        )
        connection.execute(
            "INSERT INTO sites (id, organization_id, name) VALUES (%s, %s, 'Second Site')",
            (second_site_id, second_organization_id),
        )
        connection.commit()

    settings = Settings(
        DATABASE_URL=database_url,
        SYSTEM_DATABASE_URL=database_url,
        EDGE_TO_ENRICHMENT_HMAC_KEY_ID=HMAC_KEY_ID,
        EDGE_TO_ENRICHMENT_HMAC_KEY=HMAC_SECRET,
    )
    app.dependency_overrides[get_settings] = lambda: settings
    try:
        client = TestClient(app)
        path = "/v1/reviewer/reconciliation/query"
        body = json.dumps({"organization_id": second_organization_id, "site_id": second_site_id}).encode()
        headers = signed_headers(body, path=path)
        headers.update({
            "X-ChallanSe-OIDC-Issuer": issuer,
            "X-ChallanSe-OIDC-Subject": subject,
            "X-ChallanSe-OIDC-Email": "admin@client.example",
            "X-ChallanSe-Site-Id": SITE_ID,
        })
        response = client.post(path, content=body, headers=headers)
        assert response.status_code == 403
        assert response.json()["detail"] == "TENANT_SCOPE_FORBIDDEN"

        import_path = "/v1/reviewer/po-imports"
        import_body = json.dumps({"csvContent": "po_number,material_code,quantity,unit\nPO-1,CEM,1,BAG\n"}).encode()
        response = client.post(import_path, content=import_body, headers=signed_headers(import_body, path=import_path))
        assert response.status_code == 401
        assert response.json()["detail"] == "REVIEWER_UNAUTHORIZED"
    finally:
        app.dependency_overrides.clear()
        get_settings.cache_clear()


@pytest.mark.integration
def test_resumable_upload_commits_once_and_removes_all_part_versions() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    bootstrap_tenant(
        Settings(ENVIRONMENT="production", DATABASE_ADMIN_URL=database_url),
        TenantBootstrap(
            organization_id=UUID(ORGANIZATION_ID), organization_slug="client-one", organization_name="Client One",
            site_id=UUID(SITE_ID), site_name="Main Site", allowed_wifi_ssids=["Site Office"],
            reviewer_issuer="https://identity.example.com", reviewer_subject="admin-subject",
            reviewer_email="admin@client.example", reviewer_display_name="Client Admin",
            vendors=[BootstrapVendor(id="vendor-1", name="Vendor One", initials="V1", color="#0F766E")],
            confirmation=f"BOOTSTRAP {ORGANIZATION_ID}",
        ),
    )
    device_id = UUID("66666666-6666-4666-8666-666666666666")
    with tenant_connection(database_url, ORGANIZATION_ID) as connection:
        connection.execute(
            "INSERT INTO devices (id, organization_id, site_id, name, token_hash, app_version) VALUES (%s, %s, %s, 'Device', %s, '1.0')",
            (device_id, ORGANIZATION_ID, SITE_ID, "d" * 64),
        )
        connection.commit()

    class VersionedS3:
        def __init__(self) -> None:
            self.objects: dict[str, list[dict[str, object]]] = {}
            self.sequence = 0

        def put_object(self, **kwargs):
            self.sequence += 1
            self.objects.setdefault(str(kwargs["Key"]), []).append({
                "VersionId": f"v{self.sequence}",
                "Body": bytes(kwargs["Body"]),
                "Metadata": dict(kwargs.get("Metadata", {})),
                "ContentType": kwargs.get("ContentType"),
            })

        def get_object(self, **kwargs):
            current = self.objects[str(kwargs["Key"])][-1]
            return {
                "Body": BytesIO(current["Body"]),
                "Metadata": current["Metadata"],
                "ContentType": current["ContentType"],
            }

        def list_object_versions(self, **kwargs):
            key = str(kwargs["Prefix"])
            return {
                "Versions": [
                    {"Key": key, "VersionId": version["VersionId"]}
                    for version in self.objects.get(key, [])
                ],
                "IsTruncated": False,
            }

        def delete_objects(self, **kwargs):
            for deleted in kwargs["Delete"]["Objects"]:
                key = str(deleted["Key"])
                self.objects[key] = [
                    version for version in self.objects.get(key, [])
                    if version["VersionId"] != deleted["VersionId"]
                ]
                if not self.objects[key]:
                    self.objects.pop(key)

    fake_s3 = VersionedS3()
    image = b"RIFF" + b"\x00" * 4 + b"WEBP" + b"x" * 300_008
    image_hash = hashlib.sha256(image).hexdigest()
    request = UploadSessionRequest(
        receipt_id=UUID(RECEIPT_ID), vendor_id="vendor-1", captured_at_unix=1_700_000_000,
        captured_quantity=100, image_sha256=image_hash, app_version="1.0", configuration_version=1,
        total_bytes=len(image), mime_type="image/webp",
    )
    settings = Settings(
        DATABASE_URL=database_url,
        RECEIPT_BUCKET="challanse-test-receipts",
        KMS_KEY_ARN="arn:aws:kms:ap-south-1:111122223333:key/test",
    )
    device = DeviceContext(device_id, UUID(ORGANIZATION_ID), UUID(SITE_ID), "Device")
    upload = create_upload_session(settings, device, request)
    upload_id = UUID(str(upload["uploadId"]))
    for part_number, offset in enumerate(range(0, len(image), 256_000)):
        part = image[offset:offset + 256_000]
        put_upload_part(settings, device, upload_id, part_number, part, hashlib.sha256(part).hexdigest(), fake_s3)
    completed = complete_upload_session(settings, device, upload_id, fake_s3)
    assert completed == {"receiptId": RECEIPT_ID, "status": "RECEIVED", "duplicate": False}
    assert all("/uploads/" not in key for key in fake_s3.objects)
    final_key = next(iter(fake_s3.objects))
    assert final_key.startswith(f"{ORGANIZATION_ID}/{SITE_ID}/") and final_key.endswith(f"/{RECEIPT_ID}.webp")
    assert fake_s3.objects[final_key][-1]["Metadata"]["sha256"] == image_hash
    assert complete_upload_session(settings, device, upload_id, fake_s3)["duplicate"] is True
    assert create_upload_session(settings, device, request)["complete"] is True
    with tenant_connection(database_url, ORGANIZATION_ID, row_factory=psycopg.rows.dict_row) as connection:
        evidence = connection.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM receipts WHERE id = %s) AS receipts,
              (SELECT COUNT(*) FROM audit_events WHERE receipt_id = %s AND event_type = 'RECEIVED') AS audits,
              (SELECT COUNT(*) FROM transactional_outbox WHERE aggregate_id = %s AND event_type = 'RECEIPT_ENRICHMENT_QUEUE') AS queue_events,
              (SELECT COUNT(*) FROM upload_parts WHERE upload_id = %s) AS temporary_parts
            """,
            (RECEIPT_ID, RECEIPT_ID, RECEIPT_ID, upload_id),
        ).fetchone()
    assert evidence == {"receipts": 1, "audits": 1, "queue_events": 1, "temporary_parts": 0}


@pytest.mark.integration
def test_device_mutation_rate_limit_is_tenant_scoped_and_rolls_back_nonce() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    seed_test_organization(database_url)
    device_id = UUID("66666666-6666-4666-8666-666666666666")
    with psycopg.connect(database_url) as connection:
        connection.execute(
            "INSERT INTO sites (id, organization_id, name) VALUES (%s, %s, 'Rate-limited site')",
            (SITE_ID, ORGANIZATION_ID),
        )
        connection.execute(
            "INSERT INTO devices (id, organization_id, site_id, name, token_hash, app_version) VALUES (%s, %s, %s, 'Device', %s, '1.0')",
            (device_id, ORGANIZATION_ID, SITE_ID, "d" * 64),
        )
        connection.execute(
            "UPDATE organizations SET device_request_limit_per_minute = 30 WHERE id = %s",
            (ORGANIZATION_ID,),
        )
        connection.commit()
    settings = Settings(DATABASE_URL=database_url)
    device = DeviceContext(device_id, UUID(ORGANIZATION_ID), UUID(SITE_ID), "Device")
    timestamp = str(int(time.time()))
    for index in range(30):
        consume_device_nonce(settings, device, timestamp, f"rate-limit-nonce-{index:04d}")
    with pytest.raises(AuthoritativeError, match="DEVICE_RATE_LIMITED"):
        consume_device_nonce(settings, device, timestamp, "rate-limit-nonce-0030")
    with tenant_connection(database_url, ORGANIZATION_ID) as connection:
        nonce_count = connection.execute(
            "SELECT COUNT(*) FROM device_request_nonces WHERE device_id = %s",
            (device_id,),
        ).fetchone()[0]
        request_count = connection.execute(
            "SELECT request_count FROM device_rate_limit_windows WHERE device_id = %s",
            (device_id,),
        ).fetchone()[0]
    assert nonce_count == 30
    assert request_count == 30


@pytest.mark.integration
def test_postgres_ingress_and_reconciliation_are_idempotent() -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    seed_test_organization(database_url)
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
        ORGANIZATION_ID,
        SITE_ID,
        "reviewer@example.com",
        "po_number,material_code,quantity,unit\nPO-1,CEM,100,BAG\n",
    )
    repeated_id, repeated, _ = import_tally_csv(
        database_url,
        ORGANIZATION_ID,
        SITE_ID,
        "reviewer@example.com",
        "po_number,material_code,quantity,unit\nPO-1,CEM,100,BAG\n",
    )
    assert row_count == 1 and duplicate_import is False
    assert repeated is True and repeated_id == import_id
    record_verified_review(database_url, VerifiedReviewEvent(
        receipt_id=RECEIPT_ID,
        site_id=SITE_ID,
        organization_id=ORGANIZATION_ID,
        po_number="PO-1",
        material_code="CEM",
        verified_quantity=110,
        unit="BAG",
        reviewer_id="reviewer@example.com",
        review_version=1,
        reviewed_at_iso8601="2026-07-16T00:00:00Z",
    ))
    rows = reconciliation_for_site(database_url, ORGANIZATION_ID, SITE_ID)
    assert rows[0]["site_received"] == 110
    assert rows[0]["is_over"] is True

    settings = Settings(DATABASE_URL=database_url)
    record_telemetry(settings, TelemetryBatch.model_validate({"measurements": [
        {
            "source_event_id": "device-1:write-1",
            "organization_id": ORGANIZATION_ID,
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
            "organization_id": ORGANIZATION_ID,
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
def test_digest_and_retention_jobs_are_idempotent(monkeypatch) -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    seed_test_organization(database_url)
    recent_id = "33333333-3333-4333-8333-333333333333"
    expired_id = "44444444-4444-4444-8444-444444444444"
    current_id = "55555555-5555-4555-8555-555555555555"
    device_id = "66666666-6666-4666-8666-666666666666"
    deleted_keys: list[str] = []
    orphan_key = f"{ORGANIZATION_ID}/{SITE_ID}/uploads/orphaned-upload/part-0000"
    removed_keys: set[str] = set()

    class FakeS3:
        def list_objects_v2(self, **kwargs):
            if orphan_key in removed_keys:
                return {"Contents": [], "IsTruncated": False}
            return {
                "Contents": [{"Key": orphan_key, "LastModified": datetime.now(timezone.utc) - timedelta(hours=26)}],
                "IsTruncated": False,
            }

        def list_object_versions(self, **kwargs):
            key = str(kwargs["Prefix"])
            if key in removed_keys:
                return {"Versions": [], "DeleteMarkers": [], "IsTruncated": False}
            return {
                "Versions": [{"Key": key, "VersionId": f"{key}-v1"}],
                "DeleteMarkers": [{"Key": key, "VersionId": f"{key}-marker"}],
                "IsTruncated": False,
            }

        def delete_objects(self, **kwargs):
            key = str(kwargs["Delete"]["Objects"][0]["Key"])
            if key not in removed_keys:
                deleted_keys.append(key)
                removed_keys.add(key)

    monkeypatch.setattr("app.jobs.boto3.client", lambda *args, **kwargs: FakeS3())
    set_site_manager(database_url, ORGANIZATION_ID, SITE_ID, "manager@example.com", True)
    with tenant_connection(database_url, ORGANIZATION_ID) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "INSERT INTO sites (id, organization_id, name) VALUES (%s, %s, 'Test site')",
                (SITE_ID, ORGANIZATION_ID),
            )
            cursor.execute(
                "INSERT INTO vendors (id, organization_id, site_id, name, initials, color) VALUES ('vendor-1', %s, %s, 'Vendor', 'V', '#0F766E')",
                (ORGANIZATION_ID, SITE_ID),
            )
            cursor.execute(
                "INSERT INTO devices (id, organization_id, site_id, name, token_hash, app_version) VALUES (%s, %s, %s, 'Device', %s, '1.0')",
                (device_id, ORGANIZATION_ID, SITE_ID, "d" * 64),
            )
            cursor.execute(
                """
                INSERT INTO receipts
                  (id, organization_id, site_id, device_id, vendor_id, captured_at_unix, captured_quantity,
                   image_key, image_bytes, image_sha256, app_version, configuration_version, created_at)
                VALUES (%s, %s, %s, %s, 'vendor-1', 1700000000, 10, 'old-91.webp', 1000, %s, '1.0', 1, NOW() - INTERVAL '91 days'),
                       (%s, %s, %s, %s, 'vendor-1', 1600000000, 10, 'old-366.webp', 2000, %s, '1.0', 1, NOW() - INTERVAL '366 days'),
                       (%s, %s, %s, %s, 'vendor-1', 1800000000, 10, 'current.webp', 3000, %s, '1.0', 1, NOW())
                """,
                (
                    recent_id, ORGANIZATION_ID, SITE_ID, device_id, "a" * 64,
                    expired_id, ORGANIZATION_ID, SITE_ID, device_id, "b" * 64,
                    current_id, ORGANIZATION_ID, SITE_ID, device_id, "c" * 64,
                ),
            )
            cursor.execute(
                "UPDATE organizations SET stored_image_bytes = 6000 WHERE id = %s",
                (ORGANIZATION_ID,),
            )
            cursor.execute(
                """
                INSERT INTO enrichment_receipts
                  (receipt_id, organization_id, site_id, vendor_id, captured_at_unix, site_captured_quantity, status, created_at)
                VALUES (%s, %s, %s, 'vendor-1', 1700000000, 10, 'NEEDS_HUMAN_REVIEW', NOW() - INTERVAL '91 days'),
                       (%s, %s, %s, 'vendor-1', 1600000000, 10, 'READY_FOR_REVIEW', NOW() - INTERVAL '366 days'),
                       (%s, %s, %s, 'vendor-1', 1800000000, 10, 'NEEDS_HUMAN_REVIEW', NOW())
                """,
                (recent_id, ORGANIZATION_ID, SITE_ID, expired_id, ORGANIZATION_ID, SITE_ID, current_id, ORGANIZATION_ID, SITE_ID),
            )
            cursor.execute(
                "INSERT INTO workflow_stages (organization_id, receipt_id, stage, status, attempts) VALUES (%s, %s, 'OCR', 'FAILED_RETRYABLE', 2)",
                (ORGANIZATION_ID, current_id),
            )
        connection.commit()
    settings = Settings(DATABASE_URL=database_url, RECEIPT_BUCKET="challanse-test-receipts")
    assert generate_digests(settings) == 1
    assert generate_digests(settings) == 0
    assert digest_history_for_site(database_url, ORGANIZATION_ID, SITE_ID)[0]["manager_id"] == "manager@example.com"
    status_rows = enrichment_status_for_site(database_url, ORGANIZATION_ID, SITE_ID, current_id)
    assert status_rows[0]["retry_status"] == "FAILED_RETRYABLE"
    assert status_rows[0]["attempts"] == 2
    first_tombstones, deleted = apply_retention(settings)
    second_tombstones, deleted_again = apply_retention(settings)
    assert first_tombstones == 2 and deleted == 1
    assert second_tombstones == 0 and deleted_again == 0
    assert deleted_keys == ["old-366.webp", "old-91.webp", orphan_key]
    with system_connection(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) FROM enrichment_receipts")
            assert cursor.fetchone()[0] == 2


@pytest.mark.integration
def test_callback_retry_does_not_repeat_ocr_or_create_credit(monkeypatch) -> None:
    database_url = os.getenv("TEST_DATABASE_URL")
    if not database_url:
        pytest.skip("TEST_DATABASE_URL is not configured")
    reset_test_database(database_url)
    seed_test_organization(database_url)
    device_id = "66666666-6666-4666-8666-666666666666"
    with tenant_connection(database_url, ORGANIZATION_ID) as connection:
        connection.execute(
            "INSERT INTO sites (id, organization_id, name) VALUES (%s, %s, 'Test site')",
            (SITE_ID, ORGANIZATION_ID),
        )
        connection.execute(
            "INSERT INTO vendors (id, organization_id, site_id, name, initials, color) VALUES ('vendor-1', %s, %s, 'Vendor', 'V', '#0F766E')",
            (ORGANIZATION_ID, SITE_ID),
        )
        connection.execute(
            "INSERT INTO devices (id, organization_id, site_id, name, token_hash, app_version) VALUES (%s, %s, %s, 'Device', %s, '1.0')",
            (device_id, ORGANIZATION_ID, SITE_ID, "d" * 64),
        )
        connection.execute(
            """
            INSERT INTO receipts
              (id, organization_id, site_id, device_id, vendor_id, captured_at_unix, captured_quantity,
               image_key, image_bytes, image_sha256, app_version, configuration_version)
            VALUES (%s, %s, %s, %s, 'vendor-1', 1700000000, 100, %s, 500000, %s, '1.0', 1)
            """,
            (RECEIPT_ID, ORGANIZATION_ID, SITE_ID, device_id, f"{ORGANIZATION_ID}/{SITE_ID}/{RECEIPT_ID}.webp", "a" * 64),
        )
        connection.execute(
            "INSERT INTO workflow_stages (organization_id, receipt_id, stage, status) VALUES (%s, %s, 'OCR', 'PROCESSING')",
            (ORGANIZATION_ID, RECEIPT_ID),
        )
        connection.commit()

    settings = Settings(DATABASE_URL=database_url, CREDIT_PROVIDER="disabled")
    save_ocr_result(
        settings,
        ReceiptEvent.model_validate(receipt_payload()),
        "READY_FOR_REVIEW",
        {"Blocks": []},
        "synthetic OCR result",
        92.0,
        None,
        None,
        "textract:test",
        finalize=True,
    )
    original_projection = outbox_module.project_enrichment_result

    def fail_projection(*_args, **_kwargs):
        raise RuntimeError("simulated_callback_failure")

    monkeypatch.setattr(outbox_module, "project_enrichment_result", fail_projection)
    assert dispatch_outbox_once(settings) == 0
    with tenant_connection(database_url, ORGANIZATION_ID) as connection:
        connection.execute(
            "UPDATE transactional_outbox SET available_at = NOW() WHERE aggregate_id = %s",
            (RECEIPT_ID,),
        )
        connection.commit()
    monkeypatch.setattr(outbox_module, "project_enrichment_result", original_projection)
    assert dispatch_outbox_once(settings) == 1

    with tenant_connection(database_url, ORGANIZATION_ID, row_factory=psycopg.rows.dict_row) as connection:
        evidence = connection.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM immutable_enrichment_audits WHERE receipt_id = %s AND event_type = 'OCR_COMPLETED') AS ocr_audits,
              (SELECT COUNT(*) FROM transactional_outbox WHERE aggregate_id = %s AND event_type = 'CREDIT_DELIVERY') AS credit_events,
              (SELECT attempts FROM transactional_outbox WHERE aggregate_id = %s AND event_type = 'ENRICHMENT_CALLBACK') AS callback_attempts,
              (SELECT status FROM transactional_outbox WHERE aggregate_id = %s AND event_type = 'ENRICHMENT_CALLBACK') AS callback_status,
              (SELECT version FROM enrichment_receipts WHERE receipt_id = %s) AS enrichment_version
            """,
            (RECEIPT_ID, RECEIPT_ID, RECEIPT_ID, RECEIPT_ID, RECEIPT_ID),
        ).fetchone()
    assert evidence == {
        "ocr_audits": 1,
        "credit_events": 0,
        "callback_attempts": 2,
        "callback_status": "DELIVERED",
        "enrichment_version": 1,
    }


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
