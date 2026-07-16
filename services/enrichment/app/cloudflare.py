import json
import time
from uuid import uuid4

import httpx

from .config import Settings
from .schemas import EnrichmentResult
from .security import sha256_hex, sign_service_request


def _headers(settings: Settings, method: str, path: str, payload: bytes) -> dict[str, str]:
    if not settings.enrichment_to_edge_key or not settings.enrichment_to_edge_key_id:
        raise RuntimeError("enrichment_to_edge_auth_unconfigured")
    timestamp = str(int(time.time()))
    request_id = str(uuid4())
    content_sha256 = sha256_hex(payload)
    signature = sign_service_request(
        settings.enrichment_to_edge_key,
        timestamp,
        request_id,
        settings.enrichment_to_edge_key_id,
        method,
        path,
        content_sha256,
    )
    return {
        "X-ChallanSe-Timestamp": timestamp,
        "X-ChallanSe-Request-Id": request_id,
        "X-ChallanSe-Key-Id": settings.enrichment_to_edge_key_id,
        "X-ChallanSe-Content-SHA256": content_sha256,
        "X-ChallanSe-Signature": signature,
    }


def fetch_private_image(settings: Settings, receipt_id: str, client: httpx.Client | None = None) -> bytes:
    if not settings.cloudflare_api_url:
        raise RuntimeError("cloudflare_api_url_unconfigured")
    path = f"/v1/internal/receipts/{receipt_id}/image"
    owned_client = client is None
    http_client = client or httpx.Client(timeout=15.0)
    try:
        response = http_client.get(
            f"{settings.cloudflare_api_url.rstrip('/')}{path}",
            headers=_headers(settings, "GET", path, b""),
        )
        response.raise_for_status()
        return response.content
    finally:
        if owned_client:
            http_client.close()


def send_callback(settings: Settings, result: EnrichmentResult, client: httpx.Client | None = None) -> None:
    raw = json.dumps(result.model_dump(mode="json"), separators=(",", ":")).encode("utf-8")
    path = f"/v1/internal/receipts/{result.receipt_id}/enrichment"
    owned_client = client is None
    http_client = client or httpx.Client(timeout=15.0)
    try:
        response = http_client.post(
            f"{settings.cloudflare_api_url.rstrip('/')}{path}",
            content=raw,
            headers={"Content-Type": "application/json", **_headers(settings, "POST", path, raw)},
        )
        if response.status_code != 409:
            response.raise_for_status()
    finally:
        if owned_client:
            http_client.close()
