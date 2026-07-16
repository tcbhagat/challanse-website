import hashlib
import hmac
import time
from dataclasses import dataclass

import psycopg


def sign_payload(secret: str, payload: bytes) -> str:
    return hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()


def verify_payload(secret: str, payload: bytes, supplied_signature: str) -> bool:
    if not secret or not supplied_signature:
        return False
    return hmac.compare_digest(sign_payload(secret, payload), supplied_signature)


def sha256_hex(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def canonical_request(timestamp: str, request_id: str, key_id: str, method: str, path: str, content_sha256: str) -> bytes:
    return "\n".join((timestamp, request_id, key_id, method.upper(), path, content_sha256)).encode("utf-8")


def sign_service_request(
    secret: str,
    timestamp: str,
    request_id: str,
    key_id: str,
    method: str,
    path: str,
    content_sha256: str,
) -> str:
    return sign_payload(secret, canonical_request(timestamp, request_id, key_id, method, path, content_sha256))


@dataclass(frozen=True)
class ServiceRequest:
    request_id: str
    key_id: str
    content_sha256: str


def verify_service_request(
    keys: dict[str, str],
    payload: bytes,
    signature: str,
    timestamp: str,
    request_id: str,
    key_id: str,
    method: str,
    path: str,
    supplied_content_sha256: str,
) -> ServiceRequest | None:
    try:
        timestamp_number = int(timestamp)
    except (TypeError, ValueError):
        return None
    secret = keys.get(key_id, "")
    actual_content_sha256 = sha256_hex(payload)
    if (
        not secret
        or not request_id
        or abs(int(time.time()) - timestamp_number) > 60
        or not hmac.compare_digest(actual_content_sha256, supplied_content_sha256)
    ):
        return None
    expected = sign_service_request(secret, timestamp, request_id, key_id, method, path, actual_content_sha256)
    if not hmac.compare_digest(expected, signature):
        return None
    return ServiceRequest(request_id=request_id, key_id=key_id, content_sha256=actual_content_sha256)


def verify_access_service_token(expected_id: str, expected_secret: str, supplied_id: str, supplied_secret: str) -> bool:
    if not expected_id or not expected_secret or not supplied_id or not supplied_secret:
        return False
    return hmac.compare_digest(expected_id, supplied_id) and hmac.compare_digest(expected_secret, supplied_secret)


def consume_service_nonce(database_url: str, request: ServiceRequest) -> bool:
    if not database_url:
        return False
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            cursor.execute("DELETE FROM service_request_nonces WHERE expires_at < NOW()")
            cursor.execute(
                """
                INSERT INTO service_request_nonces (request_id, key_id, content_sha256)
                VALUES (%s, %s, %s)
                ON CONFLICT DO NOTHING
                RETURNING request_id
                """,
                (request.request_id, request.key_id, request.content_sha256),
            )
            accepted = cursor.fetchone() is not None
        connection.commit()
    return accepted
