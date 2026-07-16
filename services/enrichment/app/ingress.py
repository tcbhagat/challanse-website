from dataclasses import dataclass

import psycopg
from psycopg.types.json import Jsonb

from .schemas import ReceiptEvent


@dataclass(frozen=True)
class IngressReservation:
    duplicate: bool
    status: str
    task_id: str | None
    request_id: str


class IngressStore:
    def reserve(self, request_id: str, key_id: str, content_sha256: str, event: ReceiptEvent) -> IngressReservation:
        raise NotImplementedError

    def mark_queued(self, request_id: str, task_id: str) -> None:
        raise NotImplementedError

    def release(self, request_id: str) -> None:
        raise NotImplementedError


class IngressConflict(RuntimeError):
    pass


class MemoryIngressStore(IngressStore):
    def __init__(self) -> None:
        self.requests: dict[str, tuple[str, str | None, str, str]] = {}
        self.request_receipts: dict[str, str] = {}
        self.receipts: set[str] = set()

    def reserve(self, request_id: str, key_id: str, content_sha256: str, event: ReceiptEvent) -> IngressReservation:
        existing = self.requests.get(request_id)
        if existing:
            if existing[2] != key_id or existing[3] != content_sha256:
                raise IngressConflict("request_id_reused_with_different_content")
            return IngressReservation(True, existing[0], existing[1], request_id)
        if event.receipt_id in self.receipts:
            self.requests[request_id] = ("DUPLICATE", event.receipt_id, key_id, content_sha256)
            return IngressReservation(True, "DUPLICATE", event.receipt_id, request_id)
        self.requests[request_id] = ("RESERVED", None, key_id, content_sha256)
        self.request_receipts[request_id] = event.receipt_id
        self.receipts.add(event.receipt_id)
        return IngressReservation(False, "RESERVED", None, request_id)

    def mark_queued(self, request_id: str, task_id: str) -> None:
        current = self.requests[request_id]
        self.requests[request_id] = ("QUEUED", task_id, current[2], current[3])

    def release(self, request_id: str) -> None:
        self.requests.pop(request_id, None)
        receipt_id = self.request_receipts.pop(request_id, None)
        if receipt_id:
            self.receipts.discard(receipt_id)


class PostgresIngressStore(IngressStore):
    def __init__(self, database_url: str) -> None:
        if not database_url:
            raise RuntimeError("database_url_unconfigured")
        self.database_url = database_url

    def reserve(self, request_id: str, key_id: str, content_sha256: str, event: ReceiptEvent) -> IngressReservation:
        with psycopg.connect(self.database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT status, task_id, key_id, content_sha256 FROM service_ingress_requests WHERE request_id = %s",
                    (request_id,),
                )
                existing = cursor.fetchone()
                if existing:
                    if str(existing[2]) != key_id or str(existing[3]) != content_sha256:
                        raise IngressConflict("request_id_reused_with_different_content")
                    return IngressReservation(True, str(existing[0]), str(existing[1]) if existing[1] else None, request_id)
                cursor.execute(
                    "SELECT request_id, status, task_id FROM service_ingress_requests WHERE receipt_id = %s ORDER BY created_at DESC LIMIT 1",
                    (event.receipt_id,),
                )
                receipt_existing = cursor.fetchone()
                if receipt_existing:
                    return IngressReservation(
                        True,
                        str(receipt_existing[1]),
                        str(receipt_existing[2]) if receipt_existing[2] else None,
                        str(receipt_existing[0]),
                    )
                cursor.execute(
                    """
                    INSERT INTO service_ingress_requests
                      (request_id, receipt_id, key_id, content_sha256, status, event_json)
                    VALUES (%s, %s, %s, %s, 'RESERVED', %s)
                    ON CONFLICT DO NOTHING
                    RETURNING request_id
                    """,
                    (request_id, event.receipt_id, key_id, content_sha256, Jsonb(event.model_dump(mode="json"))),
                )
                inserted = cursor.fetchone()
                if not inserted:
                    cursor.execute(
                        "SELECT request_id, status, task_id, key_id, content_sha256 FROM service_ingress_requests WHERE request_id = %s OR receipt_id = %s ORDER BY request_id = %s DESC LIMIT 1",
                        (request_id, event.receipt_id, request_id),
                    )
                    concurrent = cursor.fetchone()
                    if not concurrent:
                        raise IngressConflict("ingress_reservation_conflict")
                    if str(concurrent[0]) == request_id and (str(concurrent[3]) != key_id or str(concurrent[4]) != content_sha256):
                        raise IngressConflict("request_id_reused_with_different_content")
                    return IngressReservation(
                        True,
                        str(concurrent[1]),
                        str(concurrent[2]) if concurrent[2] else None,
                        str(concurrent[0]),
                    )
            connection.commit()
        return IngressReservation(False, "RESERVED", None, request_id)

    def mark_queued(self, request_id: str, task_id: str) -> None:
        with psycopg.connect(self.database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "UPDATE service_ingress_requests SET status = 'QUEUED', task_id = %s, queued_at = NOW() WHERE request_id = %s",
                    (task_id, request_id),
                )
            connection.commit()

    def release(self, request_id: str) -> None:
        with psycopg.connect(self.database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "DELETE FROM service_ingress_requests WHERE request_id = %s AND status = 'RESERVED'",
                    (request_id,),
                )
            connection.commit()


def get_ingress_store(database_url: str) -> IngressStore:
    return PostgresIngressStore(database_url)
