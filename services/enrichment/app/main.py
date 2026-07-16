import logging

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
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
from .schemas import EnrichmentStatusQuery, ReceiptEvent, SiteManagerCommand, SiteQuery, TallyImportRequest, TelemetryBatch, VerifiedReviewEvent
from .security import consume_service_nonce, verify_access_service_token, verify_service_request
from .observability import configure_observability


logger = logging.getLogger("challanse.enrichment")
configure_observability(get_settings())
app = FastAPI(title="ChallanSe Enrichment", version="1.0.0")
FastAPIInstrumentor.instrument_app(app, excluded_urls="health,ready")
MAX_INTERNAL_REQUEST_BYTES = 1_100_000


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
        request.url.path,
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
        request.url.path,
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
    try:
        payload = TallyImportRequest.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_tally_import") from error
    import_id, duplicate, row_count = import_tally_csv(
        settings.database_url,
        payload.site_id,
        payload.imported_by,
        payload.csv_content,
    )
    return {"import_id": import_id, "duplicate": duplicate, "row_count": row_count}


@app.post("/v1/reviewer/reconciliation/query")
async def reconciliation_query(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = SiteQuery.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_site_query") from error
    return {"rows": reconciliation_for_site(settings.database_url, payload.site_id)}


@app.post("/v1/reviewer/digests/query")
async def digest_history_query(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = SiteQuery.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_site_query") from error
    return {"digests": digest_history_for_site(settings.database_url, payload.site_id)}


@app.post("/v1/reviewer/enrichment-status/query")
async def enrichment_status_query(request: Request, settings=Depends(get_settings)) -> dict[str, object]:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = EnrichmentStatusQuery.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_enrichment_status_query") from error
    return {"rows": enrichment_status_for_site(settings.database_url, payload.site_id, str(payload.receipt_id) if payload.receipt_id else None)}


@app.post("/v1/admin/site-managers", status_code=status.HTTP_204_NO_CONTENT)
async def site_manager_command(request: Request, settings=Depends(get_settings)) -> None:
    raw = await _verify_internal_request(request, settings)
    try:
        payload = SiteManagerCommand.model_validate_json(raw)
    except ValidationError as error:
        raise HTTPException(status_code=422, detail="invalid_site_manager_command") from error
    set_site_manager(settings.database_url, payload.site_id, payload.manager_id, payload.active)
