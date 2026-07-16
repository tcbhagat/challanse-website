import logging
import json as json_module
from uuid import UUID, uuid4

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, status
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from pydantic import ValidationError

from .config import get_settings
from .ingress import IngressConflict, IngressStore, get_ingress_store
from .queueing import EventQueue, get_event_queue
from .jobs import record_telemetry
from .reconciliation import (
    digest_history_for_site,
    enrichment_status_for_site,
    import_tally_csv,
    reconciliation_for_site,
    record_verified_review,
    set_site_manager,
)
from .schemas import EnrichmentStatusQuery, ReceiptEvent, SiteManagerCommand, SiteQuery, TelemetryBatch, VerifiedReviewEvent
from .security import consume_service_nonce, verify_access_service_token, verify_service_request
from .observability import configure_observability
from .authoritative import (
    AuthoritativeError,
    authenticate_device,
    authenticate_reviewer,
    admin_configuration,
    accept_membership_invitation,
    admin_summary,
    complete_upload_session,
    consume_device_nonce,
    create_enrollment_code,
    create_membership_invitation,
    create_upload_session,
    enroll_device,
    export_audit,
    get_upload_session,
    list_receipts,
    mobile_bootstrap,
    put_upload_part,
    receipt_image,
    reviewer_access_context,
    revoke_device,
    revoke_all_devices,
    review_receipt,
    update_organization_quota,
    upsert_membership,
    upsert_site,
    upsert_vendor,
)
from .schemas import (
    EnrollmentRequest,
    MembershipAdminRequest,
    MembershipInvitationAcceptance,
    MembershipInvitationRequest,
    PilotRequest,
    QuotaAdminRequest,
    ReceiptReviewRequest,
    RevokeAllDevicesRequest,
    SiteAdminRequest,
    UploadSessionRequest,
    VendorAdminRequest,
)
from .tenancy import system_connection
from .integrity import assess_play_integrity


logger = logging.getLogger("challanse.enrichment")
configure_observability(get_settings())
app = FastAPI(title="ChallanSe Enrichment", version="1.0.0")
FastAPIInstrumentor.instrument_app(app, excluded_urls="health,ready")
MAX_INTERNAL_REQUEST_BYTES = 1_100_000


def _signed_request_target(request: Request) -> str:
    return request.url.path + (f"?{request.url.query}" if request.url.query else "")


def get_ingress_store_dependency(settings=Depends(get_settings)) -> IngressStore:
    return get_ingress_store(settings.database_url)


async def _limited_body(request: Request) -> bytes:
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > MAX_INTERNAL_REQUEST_BYTES:
            raise HTTPException(status_code=413, detail="request_too_large")
        chunks.append(chunk)
    return b"".join(chunks)


async def _verify_internal_request(request: Request, settings) -> bytes:
    raw = await _limited_body(request)
    if settings.environment == "production" and not verify_access_service_token(
        settings.cloudflare_access_client_id,
        settings.cloudflare_access_client_secret,
        request.headers.get("CF-Access-Client-Id", ""),
        request.headers.get("CF-Access-Client-Secret", ""),
    ):
        raise HTTPException(status_code=401, detail="invalid_access_service_token")
    verified = verify_service_request(
        settings.incoming_hmac_keys(),
        raw,
        request.headers.get("X-ChallanSe-Signature", ""),
        request.headers.get("X-ChallanSe-Timestamp", ""),
        request.headers.get("X-ChallanSe-Request-Id", ""),
        request.headers.get("X-ChallanSe-Key-Id", ""),
        request.method,
        _signed_request_target(request),
        request.headers.get("X-ChallanSe-Content-SHA256", ""),
    )
    if not verified:
        raise HTTPException(status_code=401, detail="invalid_service_signature")
    if not settings.database_url:
        if settings.environment == "production":
            raise HTTPException(status_code=503, detail="replay_store_unavailable")
    elif not consume_service_nonce(settings.database_url, verified):
        raise HTTPException(status_code=409, detail="request_replayed")
    return raw


def _authoritative_failure(error: AuthoritativeError) -> HTTPException:
    return HTTPException(status_code=error.status_code, detail=error.code)


def _reviewer_from_headers(request: Request, settings):
    try:
        return authenticate_reviewer(
            settings,
            request.headers.get("X-ChallanSe-OIDC-Issuer", ""),
            request.headers.get("X-ChallanSe-OIDC-Subject", ""),
            request.headers.get("X-ChallanSe-OIDC-Email", ""),
            request.headers.get("X-ChallanSe-Site-Id", ""),
        )
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


def _require_reviewer_scope(reviewer, organization_id: str, site_id: str) -> None:
    if str(reviewer.organization_id) != organization_id or str(reviewer.site_id) != site_id:
        raise HTTPException(status_code=403, detail="TENANT_SCOPE_FORBIDDEN")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/ready")
def ready(settings=Depends(get_settings)) -> dict[str, object]:
    errors = settings.production_errors()
    if errors:
        raise HTTPException(status_code=503, detail={"status": "configuration_required", "errors": errors})
    return {"status": "ready", "providers": {
        "ocr": settings.ocr_provider,
        "gst": settings.gst_provider,
        "notifications": settings.notification_provider,
        "credit": settings.credit_provider,
        "slack": settings.slack_provider,
    }}


@app.post("/v1/pilot-requests", status_code=status.HTTP_201_CREATED)
async def authoritative_pilot_request(request: Request, settings=Depends(get_settings)) -> dict[str, str]:
    raw = await _verify_internal_request(request, settings)
    if request.headers.get("X-ChallanSe-Turnstile-Verified") != "true":
        raise HTTPException(status_code=401, detail="TURNSTILE_REQUIRED")
    try:
        payload = PilotRequest.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_PILOT_REQUEST") from error
    with system_connection(settings.database_url) as connection:
        request_id = uuid4()
        connection.execute(
            """
            INSERT INTO pilot_requests (id, name, company, email, phone, message)
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (request_id, payload.name, payload.company, payload.email.lower(), payload.phone, payload.message),
        )
        connection.commit()
    return {"requestId": str(request_id), "status": "received"}


@app.post("/v1/devices/enroll", status_code=status.HTTP_201_CREATED)
async def authoritative_enroll(request: Request, settings=Depends(get_settings)) -> dict[str, str]:
    raw = await _verify_internal_request(request, settings)
    try:
        return enroll_device(settings, EnrollmentRequest.model_validate_json(raw))
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_ENROLLMENT") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.get("/v1/mobile/bootstrap")
async def authoritative_bootstrap(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    await _verify_internal_request(request, settings)
    try:
        device = authenticate_device(settings, request.headers.get("Authorization", ""))
        return mobile_bootstrap(settings, device)
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.post("/v1/mobile/telemetry", status_code=status.HTTP_202_ACCEPTED)
async def authoritative_mobile_telemetry(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        device = authenticate_device(settings, request.headers.get("Authorization", ""))
        consume_device_nonce(
            settings, device, request.headers.get("X-ChallanSe-Device-Timestamp", ""), request.headers.get("X-ChallanSe-Nonce", "")
        )
        payload = json_module.loads(raw)
        measurements = [
            {**measurement, "organization_id": str(device.organization_id), "site_id": str(device.site_id)}
            for measurement in payload.get("measurements", [])
        ]
        batch = TelemetryBatch.model_validate({"measurements": measurements})
        return {"accepted": record_telemetry(settings, batch)}
    except (ValidationError, ValueError, TypeError, AttributeError) as error:
        raise HTTPException(status_code=422, detail="INVALID_TELEMETRY") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.post("/v1/uploads", status_code=status.HTTP_201_CREATED)
async def authoritative_upload_create(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        device = authenticate_device(settings, request.headers.get("Authorization", ""))
        consume_device_nonce(
            settings, device, request.headers.get("X-ChallanSe-Device-Timestamp", ""), request.headers.get("X-ChallanSe-Nonce", "")
        )
        payload = UploadSessionRequest.model_validate_json(raw)
        integrity_status = assess_play_integrity(
            settings,
            request.headers.get("X-ChallanSe-Play-Integrity", ""),
            payload.image_sha256,
        )
        return create_upload_session(settings, device, payload, integrity_status)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_UPLOAD_SESSION") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.get("/v1/uploads/{upload_id}")
async def authoritative_upload_status(upload_id: UUID, request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    await _verify_internal_request(request, settings)
    try:
        return get_upload_session(settings, authenticate_device(settings, request.headers.get("Authorization", "")), upload_id)
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.put("/v1/uploads/{upload_id}/parts/{part_number}", status_code=status.HTTP_204_NO_CONTENT)
async def authoritative_upload_part(upload_id: UUID, part_number: int, request: Request, settings=Depends(get_settings)) -> Response:
    raw = await _verify_internal_request(request, settings)
    try:
        device = authenticate_device(settings, request.headers.get("Authorization", ""))
        consume_device_nonce(
            settings, device, request.headers.get("X-ChallanSe-Device-Timestamp", ""), request.headers.get("X-ChallanSe-Nonce", "")
        )
        put_upload_part(settings, device, upload_id, part_number, raw, request.headers.get("X-Part-Sha256", ""))
        return Response(status_code=204)
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.post("/v1/uploads/{upload_id}/complete", status_code=status.HTTP_202_ACCEPTED)
async def authoritative_upload_complete(upload_id: UUID, request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    await _verify_internal_request(request, settings)
    try:
        device = authenticate_device(settings, request.headers.get("Authorization", ""))
        consume_device_nonce(
            settings, device, request.headers.get("X-ChallanSe-Device-Timestamp", ""), request.headers.get("X-ChallanSe-Nonce", "")
        )
        return complete_upload_session(settings, device, upload_id)
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.get("/v1/reviewer/receipts")
async def authoritative_receipts(
    request: Request,
    receipt_status: str = Query(default="NEEDS_REVIEW", alias="status"),
    limit: int = Query(default=25, ge=1, le=50),
    settings=Depends(get_settings),
) -> dict[str, object]:
    await _verify_internal_request(request, settings)
    try:
        reviewer = _reviewer_from_headers(request, settings)
        return {"receipts": list_receipts(settings, reviewer, receipt_status, limit), "nextCursor": None}
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.get("/v1/reviewer/context")
async def authoritative_reviewer_context(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    await _verify_internal_request(request, settings)
    try:
        return reviewer_access_context(
            settings,
            request.headers.get("X-ChallanSe-OIDC-Issuer", ""),
            request.headers.get("X-ChallanSe-OIDC-Subject", ""),
            request.headers.get("X-ChallanSe-OIDC-Email", ""),
        )
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.get("/v1/reviewer/receipts/{receipt_id}/image")
async def authoritative_receipt_image(receipt_id: UUID, request: Request, settings=Depends(get_settings)) -> Response:
    await _verify_internal_request(request, settings)
    try:
        body, image_hash = receipt_image(settings, _reviewer_from_headers(request, settings), receipt_id)
        return Response(
            body,
            media_type="image/webp",
            headers={"Cache-Control": "private, no-store", "ETag": f'"{image_hash}"', "X-Content-Type-Options": "nosniff"},
        )
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.patch("/v1/reviewer/receipts/{receipt_id}")
async def authoritative_review(receipt_id: UUID, request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        reviewer = _reviewer_from_headers(request, settings)
        source_class = request.headers.get("X-ChallanSe-Source-Class", "service")
        if source_class not in {"cloudflare-access", "service"}:
            source_class = "service"
        return review_receipt(settings, reviewer, receipt_id, ReceiptReviewRequest.model_validate_json(raw), source_class)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_REVIEW") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.get("/v1/reviewer/audit-export")
async def authoritative_audit_export(
    request: Request,
    output_format: str = Query(default="csv", alias="format", pattern="^(csv|json)$"),
    settings=Depends(get_settings),
) -> Response:
    await _verify_internal_request(request, settings)
    try:
        body, media_type = export_audit(settings, _reviewer_from_headers(request, settings), output_format)
        return Response(body, media_type=media_type, headers={"Content-Disposition": f'attachment; filename="challanse-audit.{output_format}"'})
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.post("/v1/events/receipts", status_code=status.HTTP_202_ACCEPTED)
async def receipt_event(
    request: Request,
    x_challanse_signature: str = Header(default=""),
    x_challanse_timestamp: str = Header(default=""),
    x_challanse_request_id: str = Header(default=""),
    x_challanse_key_id: str = Header(default=""),
    x_challanse_content_sha256: str = Header(default=""),
    cf_access_client_id: str = Header(default=""),
    cf_access_client_secret: str = Header(default=""),
    settings=Depends(get_settings),
    event_queue: EventQueue = Depends(get_event_queue),
    ingress_store: IngressStore = Depends(get_ingress_store_dependency),
) -> dict[str, str]:
    raw = await _limited_body(request)
    if settings.environment == "production" and not verify_access_service_token(
        settings.cloudflare_access_client_id,
        settings.cloudflare_access_client_secret,
        cf_access_client_id,
        cf_access_client_secret,
    ):
        raise HTTPException(status_code=401, detail="invalid_access_service_token")
    verified = verify_service_request(
        settings.incoming_hmac_keys(),
        raw,
        x_challanse_signature,
        x_challanse_timestamp,
        x_challanse_request_id,
        x_challanse_key_id,
        request.method,
        _signed_request_target(request),
        x_challanse_content_sha256,
    )
    if not verified:
        raise HTTPException(status_code=401, detail="invalid_service_signature")
    try:
        event = ReceiptEvent.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_receipt_event") from error
    try:
        reservation = ingress_store.reserve(verified.request_id, verified.key_id, verified.content_sha256, event)
    except IngressConflict as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    if reservation.duplicate and reservation.status != "RESERVED":
        return {
            "status": "duplicate",
            "receipt_id": event.receipt_id,
            "task_id": reservation.task_id or event.receipt_id,
        }
    try:
        task_id = event_queue.enqueue(event)
    except Exception as error:
        ingress_store.release(reservation.request_id)
        logger.error("receipt_event_queue_failed", extra={"receipt_id": event.receipt_id, "site_id": event.site_id, "error_code": type(error).__name__})
        raise HTTPException(status_code=503, detail="event_queue_unavailable") from error
    ingress_store.mark_queued(reservation.request_id, task_id)
    logger.info("receipt_event_accepted", extra={"receipt_id": event.receipt_id, "site_id": event.site_id, "request_id": verified.request_id})
    return {"status": "accepted", "receipt_id": event.receipt_id, "task_id": task_id}


@app.post("/v1/events/reviews", status_code=status.HTTP_202_ACCEPTED)
async def review_event(request: Request, settings=Depends(get_settings)) -> dict[str, str]:
    raw = await _verify_internal_request(request, settings)
    try:
        event = VerifiedReviewEvent.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_review_event") from error
    record_verified_review(settings.database_url, event)
    return {"status": "accepted", "receipt_id": event.receipt_id}


@app.post("/v1/events/telemetry", status_code=status.HTTP_202_ACCEPTED)
async def telemetry_event(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        batch = TelemetryBatch.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_telemetry_batch") from error
    return {"status": "accepted", "measurements": record_telemetry(settings, batch)}


@app.post("/v1/reviewer/po-imports", status_code=status.HTTP_201_CREATED)
async def tally_import(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    reviewer = _reviewer_from_headers(request, settings)
    try:
        browser_payload = json_module.loads(raw)
        csv_content = str(browser_payload["csvContent"])
    except (ValueError, TypeError, KeyError) as error:
        raise HTTPException(status_code=422, detail="invalid_tally_import") from error
    import_id, duplicate, row_count = import_tally_csv(
        settings.database_url, str(reviewer.organization_id), str(reviewer.site_id), reviewer.email, csv_content
    )
    return {"import_id": import_id, "duplicate": duplicate, "row_count": row_count}


@app.get("/v1/reviewer/reconciliation")
async def authoritative_reconciliation(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    await _verify_internal_request(request, settings)
    reviewer = _reviewer_from_headers(request, settings)
    rows = reconciliation_for_site(settings.database_url, str(reviewer.organization_id), str(reviewer.site_id))
    return {"rows": [
        {
            "poNumber": row["po_number"], "materialCode": row["material_code"], "unit": row["unit"],
            "poQuantity": row["po_quantity"], "siteReceived": row["site_received"], "isOver": row["is_over"],
        }
        for row in rows
    ]}


@app.post("/v1/admin/enrollment-codes", status_code=status.HTTP_201_CREATED)
async def authoritative_enrollment_code(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = json_module.loads(raw)
        device_name = str(payload["deviceName"]).strip()
        if not 1 <= len(device_name) <= 80:
            raise ValueError("invalid_device_name")
        return create_enrollment_code(settings, _reviewer_from_headers(request, settings), device_name)
    except (ValueError, TypeError, KeyError) as error:
        raise HTTPException(status_code=422, detail="INVALID_DEVICE_NAME") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.get("/v1/admin/summary")
async def authoritative_admin_summary(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    await _verify_internal_request(request, settings)
    try:
        return admin_summary(settings, _reviewer_from_headers(request, settings))
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.get("/v1/admin/configuration")
async def authoritative_admin_configuration(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    await _verify_internal_request(request, settings)
    try:
        return admin_configuration(settings, _reviewer_from_headers(request, settings))
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.put("/v1/admin/sites")
async def authoritative_admin_site(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = SiteAdminRequest.model_validate_json(raw)
        return upsert_site(settings, _reviewer_from_headers(request, settings), payload)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_SITE_CONFIGURATION") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.put("/v1/admin/vendors")
async def authoritative_admin_vendor(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = VendorAdminRequest.model_validate_json(raw)
        return upsert_vendor(settings, _reviewer_from_headers(request, settings), payload)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_VENDOR_CONFIGURATION") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.put("/v1/admin/memberships")
async def authoritative_admin_membership(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = MembershipAdminRequest.model_validate_json(raw)
        return upsert_membership(settings, _reviewer_from_headers(request, settings), payload)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_MEMBERSHIP_CONFIGURATION") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.post("/v1/admin/membership-invitations", status_code=status.HTTP_201_CREATED)
async def authoritative_admin_membership_invitation(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = MembershipInvitationRequest.model_validate_json(raw)
        return create_membership_invitation(settings, _reviewer_from_headers(request, settings), payload)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_MEMBERSHIP_INVITATION") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.post("/v1/reviewer/membership-invitations/accept")
async def authoritative_accept_membership_invitation(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = MembershipInvitationAcceptance.model_validate_json(raw)
        return accept_membership_invitation(
            settings,
            request.headers.get("X-ChallanSe-OIDC-Issuer", ""),
            request.headers.get("X-ChallanSe-OIDC-Subject", ""),
            request.headers.get("X-ChallanSe-OIDC-Email", ""),
            payload,
        )
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_MEMBERSHIP_INVITATION") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.put("/v1/admin/quotas")
async def authoritative_admin_quota(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = QuotaAdminRequest.model_validate_json(raw)
        return update_organization_quota(settings, _reviewer_from_headers(request, settings), payload)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_QUOTA_CONFIGURATION") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.post("/v1/admin/devices/revoke-all")
async def authoritative_revoke_all_devices(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = RevokeAllDevicesRequest.model_validate_json(raw)
        return revoke_all_devices(settings, _reviewer_from_headers(request, settings), payload)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="INVALID_REVOCATION_CONFIRMATION") from error
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.delete("/v1/admin/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
async def authoritative_revoke_device(device_id: UUID, request: Request, settings=Depends(get_settings)) -> Response:
    await _verify_internal_request(request, settings)
    try:
        revoke_device(settings, _reviewer_from_headers(request, settings), device_id)
        return Response(status_code=204)
    except AuthoritativeError as error:
        raise _authoritative_failure(error) from error


@app.post("/v1/reviewer/reconciliation/query")
async def reconciliation_query(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    reviewer = _reviewer_from_headers(request, settings)
    try:
        payload = SiteQuery.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_site_query") from error
    _require_reviewer_scope(reviewer, payload.organization_id, payload.site_id)
    return {"rows": reconciliation_for_site(settings.database_url, payload.organization_id, payload.site_id)}


@app.post("/v1/reviewer/digests/query")
async def digest_history_query(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    reviewer = _reviewer_from_headers(request, settings)
    try:
        payload = SiteQuery.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_site_query") from error
    _require_reviewer_scope(reviewer, payload.organization_id, payload.site_id)
    return {"digests": digest_history_for_site(settings.database_url, payload.organization_id, payload.site_id)}


@app.post("/v1/reviewer/enrichment-status/query")
async def enrichment_status_query(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    reviewer = _reviewer_from_headers(request, settings)
    try:
        payload = EnrichmentStatusQuery.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_enrichment_status_query") from error
    _require_reviewer_scope(reviewer, payload.organization_id, payload.site_id)
    return {"rows": enrichment_status_for_site(settings.database_url, payload.organization_id, payload.site_id, str(payload.receipt_id) if payload.receipt_id else None)}


@app.post("/v1/admin/site-managers", status_code=status.HTTP_204_NO_CONTENT)
async def site_manager_command(request: Request, settings=Depends(get_settings)) -> None:
    raw = await _verify_internal_request(request, settings)
    reviewer = _reviewer_from_headers(request, settings)
    try:
        payload = SiteManagerCommand.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_site_manager_command") from error
    if reviewer.role not in {"ORG_ADMIN", "SITE_ADMIN"}:
        raise HTTPException(status_code=403, detail="ADMIN_REQUIRED")
    _require_reviewer_scope(reviewer, payload.organization_id, payload.site_id)
    set_site_manager(settings.database_url, payload.organization_id, payload.site_id, payload.manager_id, payload.active)
