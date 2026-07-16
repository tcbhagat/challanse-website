import json
from functools import lru_cache
from typing import Protocol

import boto3

from .config import get_settings
from .schemas import ReceiptEvent


class EventQueue(Protocol):
    def enqueue(self, event: ReceiptEvent) -> str: ...


class DisabledEventQueue:
    def enqueue(self, event: ReceiptEvent) -> str:
        raise RuntimeError("event_queue_disabled")


class MemoryEventQueue:
    def __init__(self) -> None:
        self.events: list[ReceiptEvent] = []

    def enqueue(self, event: ReceiptEvent) -> str:
        self.events.append(event)
        return event.receipt_id


class SqsEventQueue:
    def __init__(self, queue_url: str, region: str, client=None) -> None:
        if not queue_url:
            raise RuntimeError("receipt_queue_url_unconfigured")
        self.queue_url = queue_url
        self.client = client or boto3.client("sqs", region_name=region)

    def enqueue(self, event: ReceiptEvent) -> str:
        response = self.client.send_message(
            QueueUrl=self.queue_url,
            MessageBody=json.dumps(event.model_dump(mode="json"), separators=(",", ":")),
            MessageAttributes={
                "schema_version": {"DataType": "String", "StringValue": event.schema_version},
                "receipt_id": {"DataType": "String", "StringValue": event.receipt_id},
                "organization_id": {"DataType": "String", "StringValue": event.organization_id},
                "site_id": {"DataType": "String", "StringValue": event.site_id},
            },
        )
        message_id = response.get("MessageId")
        if not message_id:
            raise RuntimeError("sqs_message_id_missing")
        return str(message_id)


@lru_cache(maxsize=1)
def get_event_queue() -> EventQueue:
    settings = get_settings()
    if settings.event_queue_provider == "memory":
        return MemoryEventQueue()
    if settings.event_queue_provider == "sqs":
        return SqsEventQueue(settings.receipt_queue_url, settings.aws_region)
    return DisabledEventQueue()
