import json
import logging
from dataclasses import dataclass
from typing import Any, Protocol

import boto3
import httpx

from .config import Settings


logger = logging.getLogger("challanse.enrichment.providers")


@dataclass(frozen=True)
class OcrResult:
    raw_json: dict[str, Any]
    raw_text: str
    confidence: float
    provider_version: str


@dataclass(frozen=True)
class GstResult:
    irn_hash: str
    e_invoice_quantity: float


class CreditQueue(Protocol):
    def enqueue(self, payload: dict[str, Any]) -> str: ...


class DisabledCreditQueue:
    def enqueue(self, payload: dict[str, Any]) -> str:
        raise RuntimeError("credit_provider_disabled")


class MemoryCreditQueue:
    def __init__(self) -> None:
        self.payloads: list[dict[str, Any]] = []

    def enqueue(self, payload: dict[str, Any]) -> str:
        self.payloads.append(payload)
        return f"mock-{len(self.payloads)}"


class SqsCreditQueue:
    def __init__(self, settings: Settings, client=None) -> None:
        if not settings.credit_queue_url:
            raise RuntimeError("credit_queue_url_unconfigured")
        self.queue_url = settings.credit_queue_url
        self.client = client or boto3.client("sqs", region_name=settings.aws_region)

    def enqueue(self, payload: dict[str, Any]) -> str:
        response = self.client.send_message(
            QueueUrl=self.queue_url,
            MessageBody=json.dumps(payload, separators=(",", ":")),
        )
        message_id = response.get("MessageId")
        if not message_id:
            raise RuntimeError("credit_message_id_missing")
        return str(message_id)


def credit_queue(settings: Settings) -> CreditQueue:
    if settings.credit_provider == "mock":
        if settings.environment == "production":
            raise RuntimeError("mock_credit_forbidden_in_production")
        return MemoryCreditQueue()
    if settings.credit_provider == "sqs":
        return SqsCreditQueue(settings)
    return DisabledCreditQueue()


def _confidence(blocks: list[dict[str, Any]]) -> float:
    values = [float(block["Confidence"]) for block in blocks if block.get("BlockType") == "WORD" and block.get("Confidence") is not None]
    return sum(values) / len(values) if values else 0.0


def run_ocr(settings: Settings, png_bytes: bytes, client=None) -> OcrResult:
    if settings.ocr_provider == "disabled":
        return OcrResult(raw_json={"provider": "disabled"}, raw_text="", confidence=0.0, provider_version="disabled")
    if settings.ocr_provider == "mock":
        if settings.environment == "production":
            raise RuntimeError("mock_ocr_forbidden_in_production")
        return OcrResult(raw_json={"provider": "mock", "blocks": []}, raw_text="Synthetic challan", confidence=95.0, provider_version="mock-v1")
    textract = client or boto3.client("textract", region_name=settings.aws_region)
    response = textract.detect_document_text(Document={"Bytes": png_bytes})
    blocks = list(response.get("Blocks", []))
    raw_text = "\n".join(str(block.get("Text", "")) for block in blocks if block.get("BlockType") == "LINE")
    return OcrResult(
        raw_json={"provider": "aws-textract", "document_metadata": response.get("DocumentMetadata", {}), "blocks": blocks},
        raw_text=raw_text,
        confidence=_confidence(blocks),
        provider_version="aws-textract-detect-document-text-v1",
    )


def fetch_gst(settings: Settings, vendor_gst_number: str, timestamp_unix: int, client: httpx.Client | None = None) -> GstResult:
    if settings.gst_provider == "disabled":
        raise RuntimeError("gst_provider_disabled")
    if settings.gst_provider == "mock":
        raise RuntimeError("mock_gst_requires_test_fixture")
    owned_client = client is None
    http_client = client or httpx.Client(timeout=settings.gst_timeout_seconds)
    try:
        logger.info("gst_request_started", extra={"provider": "gst-http"})
        response = http_client.post(
            settings.gst_api_url,
            json={"vendor_gst_number": vendor_gst_number, "timestamp_unix": timestamp_unix},
            timeout=settings.gst_timeout_seconds,
        )
        response.raise_for_status()
        body = response.json()
        logger.info("gst_response_received", extra={"provider": "gst-http", "status": str(response.status_code)})
        return GstResult(irn_hash=str(body["IRN_Hash"]), e_invoice_quantity=float(body["e_invoice_quantity"]))
    except Exception as error:
        logger.error("gst_request_failed", extra={"provider": "gst-http", "error_code": type(error).__name__})
        raise
    finally:
        if owned_client:
            http_client.close()
