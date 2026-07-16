import logging

from opentelemetry import trace

from .cloudflare import fetch_private_image, send_callback
from .config import Settings
from .exif import extract_gps
from .images import InvalidReceiptImage, verify_webp, webp_to_png
from .gst import validate_gst
from .providers import credit_queue, run_ocr
from .schemas import EnrichmentResult, ReceiptEvent
from .storage import (
    claim_stage,
    fail_stage,
    mark_callback_delivered,
    mark_callback_failed,
    pending_callback,
    load_gst_context,
    upsert_enrichment,
)


logger = logging.getLogger("challanse.enrichment.workflow")
tracer = trace.get_tracer("challanse.enrichment.workflow")


def _deliver_pending_callback(settings: Settings, receipt_id: str) -> EnrichmentResult | None:
    pending = pending_callback(settings.database_url, receipt_id)
    if not pending:
        return None
    outbox_id, result = pending
    try:
        send_callback(settings, result)
        mark_callback_delivered(settings.database_url, outbox_id)
    except Exception:
        mark_callback_failed(settings.database_url, outbox_id)
        raise
    return result


def process_receipt_event(settings: Settings, event: ReceiptEvent) -> EnrichmentResult:
    with tracer.start_as_current_span("receipt.enrichment") as span:
        span.set_attribute("challanse.receipt_id", event.receipt_id)
        span.set_attribute("challanse.site_id", event.site_id)
        return _process_receipt_event(settings, event)


def _process_receipt_event(settings: Settings, event: ReceiptEvent) -> EnrichmentResult:
    if not claim_stage(settings.database_url, event.receipt_id, "ENRICHMENT"):
        existing = _deliver_pending_callback(settings, event.receipt_id)
        if existing:
            return existing
        raise RuntimeError("workflow_stage_not_retryable")
    try:
        image_bytes = fetch_private_image(settings, event.receipt_id)
        verify_webp(image_bytes, event.image_sha256, event.image_bytes, settings.image_byte_limit)
        gps_latitude, gps_longitude = extract_gps(image_bytes)
        png_bytes = webp_to_png(image_bytes)
        ocr = run_ocr(settings, png_bytes)
        status = "READY_FOR_REVIEW" if ocr.confidence >= 60 else "NEEDS_HUMAN_REVIEW"
        gst_status = "NOT_CHECKED"
        sensitive_audit: dict[str, object] | None = None
        if settings.gst_provider != "disabled":
            gst_status, sensitive_audit = validate_gst(settings, load_gst_context(settings, event), credit_queue(settings))
            status = gst_status
        version = upsert_enrichment(
            settings,
            event,
            status,
            ocr.raw_json,
            ocr.raw_text,
            ocr.confidence,
            gps_latitude,
            gps_longitude,
            ocr.provider_version,
            gst_status,
            sensitive_audit,
        )
        result = EnrichmentResult(
            receipt_id=event.receipt_id,
            status=status,
            ocr_confidence=ocr.confidence,
            raw_ocr_json=ocr.raw_json,
            gst_status=gst_status,
            version=version,
        )
        _deliver_pending_callback(settings, event.receipt_id)
        logger.info(
            "receipt_enriched receipt_id=%s site_id=%s status=%s confidence=%.1f gps_present=%s",
            event.receipt_id,
            event.site_id,
            status,
            ocr.confidence,
            gps_latitude is not None,
        )
        return result
    except InvalidReceiptImage as error:
        fail_stage(settings.database_url, event.receipt_id, "ENRICHMENT", str(error), terminal=True)
        raise
    except Exception as error:
        fail_stage(settings.database_url, event.receipt_id, "ENRICHMENT", type(error).__name__)
        raise
