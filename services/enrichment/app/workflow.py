import logging

from opentelemetry import trace

from .config import Settings
from .exif import extract_gps
from .images import InvalidReceiptImage, verify_webp, webp_to_png
from .image_store import fetch_receipt_image
from .gst import validate_gst
from .providers import run_ocr
from .schemas import EnrichmentResult, ReceiptEvent
from .storage import (
    claim_stage,
    complete_stage,
    existing_enrichment_result,
    fail_stage,
    finalize_provider_failure,
    load_gst_context,
    save_gst_result,
    save_ocr_result,
    stage_status,
)


logger = logging.getLogger("challanse.enrichment.workflow")
tracer = trace.get_tracer("challanse.enrichment.workflow")


def process_receipt_event(settings: Settings, event: ReceiptEvent) -> EnrichmentResult:
    with tracer.start_as_current_span("receipt.enrichment") as span:
        span.set_attribute("challanse.receipt_id", event.receipt_id)
        span.set_attribute("challanse.site_id", event.site_id)
        return _process_receipt_event(settings, event)


def _process_receipt_event(settings: Settings, event: ReceiptEvent) -> EnrichmentResult:
    existing = existing_enrichment_result(settings.database_url, event.organization_id, event.receipt_id)
    if existing and (settings.gst_provider == "disabled" or existing.gst_status != "NOT_CHECKED"):
        return existing

    if existing is None:
        image_stage = stage_status(settings.database_url, event.organization_id, event.receipt_id, "IMAGE_FETCH")
        if image_stage != "COMPLETED" and not claim_stage(
            settings.database_url, event.organization_id, event.receipt_id, "IMAGE_FETCH"
        ):
            raise RuntimeError("image_fetch_stage_not_retryable")
        try:
            image_bytes = fetch_receipt_image(settings, event)
            verify_webp(image_bytes, event.image_sha256, event.image_bytes, settings.image_byte_limit)
            complete_stage(settings.database_url, event.organization_id, event.receipt_id, "IMAGE_FETCH")
        except InvalidReceiptImage as error:
            fail_stage(settings.database_url, event.organization_id, event.receipt_id, "IMAGE_FETCH", str(error), terminal=True)
            return finalize_provider_failure(settings, event, "IMAGE_FETCH", str(error))
        except Exception as error:
            terminal = fail_stage(
                settings.database_url, event.organization_id, event.receipt_id, "IMAGE_FETCH", type(error).__name__
            )
            if terminal:
                return finalize_provider_failure(settings, event, "IMAGE_FETCH", type(error).__name__)
            raise

        if not claim_stage(settings.database_url, event.organization_id, event.receipt_id, "OCR"):
            existing = existing_enrichment_result(settings.database_url, event.organization_id, event.receipt_id)
            if existing is not None:
                return existing
            raise RuntimeError("ocr_stage_not_retryable")
        try:
            gps_latitude, gps_longitude = extract_gps(image_bytes)
            png_bytes = webp_to_png(image_bytes)
            ocr = run_ocr(settings, png_bytes)
            status = "READY_FOR_REVIEW" if ocr.confidence >= 60 else "NEEDS_HUMAN_REVIEW"
            existing = save_ocr_result(
                settings,
                event,
                status if settings.gst_provider == "disabled" else "PROCESSING",
                ocr.raw_json,
                ocr.raw_text,
                ocr.confidence,
                gps_latitude,
                gps_longitude,
                ocr.provider_version,
                finalize=settings.gst_provider == "disabled",
            )
        except Exception as error:
            terminal = fail_stage(settings.database_url, event.organization_id, event.receipt_id, "OCR", type(error).__name__)
            if terminal:
                return finalize_provider_failure(settings, event, "OCR", type(error).__name__)
            raise

    if settings.gst_provider == "disabled":
        if existing is None:
            raise RuntimeError("ocr_result_missing")
        return existing

    if not claim_stage(settings.database_url, event.organization_id, event.receipt_id, "GST"):
        existing = existing_enrichment_result(settings.database_url, event.organization_id, event.receipt_id)
        if existing is not None and existing.gst_status != "NOT_CHECKED":
            return existing
        raise RuntimeError("gst_stage_not_retryable")
    try:
        validation = validate_gst(settings, load_gst_context(settings, event))
        result = save_gst_result(
            settings,
            event,
            validation.status,
            validation.audit,
            validation.credit_payload,
        )
        logger.info(
            "receipt_enriched receipt_id=%s site_id=%s status=%s confidence=%.1f",
            event.receipt_id,
            event.site_id,
            result.status,
            result.ocr_confidence or 0.0,
        )
        return result
    except Exception as error:
        terminal = fail_stage(settings.database_url, event.organization_id, event.receipt_id, "GST", type(error).__name__)
        if terminal:
            return finalize_provider_failure(settings, event, "GST", type(error).__name__)
        raise
