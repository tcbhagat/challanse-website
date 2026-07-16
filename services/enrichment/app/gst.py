import hashlib
from datetime import datetime, timezone

import httpx

from .config import Settings
from .providers import CreditQueue, GstResult, fetch_gst
from .schemas import AAFIData, GstReceiptContext


def quantities_match(site_quantity: float, invoice_quantity: float, tolerance: float = 0.02) -> bool:
    if site_quantity == 0:
        return invoice_quantity == 0
    return abs(invoice_quantity - site_quantity) <= abs(site_quantity) * tolerance


def build_aafi(context: GstReceiptContext, result: GstResult) -> AAFIData:
    timestamp = datetime.fromtimestamp(context.timestamp_unix, tz=timezone.utc).isoformat()
    signature = hashlib.sha256(f"{result.irn_hash}{timestamp}".encode("utf-8")).hexdigest()
    return AAFIData(
        msme_udyam_number=context.msme_udyam_number,
        recipient_bank_account=context.recipient_bank_account,
        developer_gst_number=context.developer_gst_number or "",
        irn_hash=result.irn_hash,
        material_description=context.material_description,
        verified_quantity=result.e_invoice_quantity,
        site_geo_hash=context.site_geo_hash,
        timestamp_iso8601=timestamp,
        cryptographic_signature=signature,
    )


def validate_gst(
    settings: Settings,
    context: GstReceiptContext,
    credit_queue: CreditQueue,
    client: httpx.Client | None = None,
) -> tuple[str, dict[str, object]]:
    if not context.vendor_gst_number or not context.developer_gst_number or context.site_captured_quantity is None:
        return "NEEDS_HUMAN_REVIEW", {}
    try:
        result = fetch_gst(settings, context.vendor_gst_number, context.timestamp_unix, client)
    except Exception:
        return "NEEDS_HUMAN_REVIEW", {}
    audit = {"irn_hash": result.irn_hash, "e_invoice_quantity": result.e_invoice_quantity}
    if not quantities_match(context.site_captured_quantity, result.e_invoice_quantity):
        return "GST_ANOMALY", audit
    payload = build_aafi(context, result)
    credit_queue.enqueue(payload.model_dump(mode="json"))
    return "VERIFIED_GST", audit
