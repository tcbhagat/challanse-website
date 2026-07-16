import json
import logging
import signal
import threading
import time

import boto3

from .config import get_settings
from .observability import configure_observability
from .schemas import ReceiptEvent
from .workflow import process_receipt_event


logger = logging.getLogger("challanse.enrichment.worker")
stopping = threading.Event()
VISIBILITY_TIMEOUT_SECONDS = 300
VISIBILITY_HEARTBEAT_SECONDS = 120


def _stop(_signal_number, _frame) -> None:
    stopping.set()


def _extend_visibility(sqs, queue_url: str, receipt_handle: str, finished: threading.Event) -> None:
    while not finished.wait(VISIBILITY_HEARTBEAT_SECONDS):
        try:
            sqs.change_message_visibility(
                QueueUrl=queue_url,
                ReceiptHandle=receipt_handle,
                VisibilityTimeout=VISIBILITY_TIMEOUT_SECONDS,
            )
        except Exception as error:
            logger.error("receipt_visibility_extension_failed", extra={"error_code": type(error).__name__})


def run_worker() -> None:
    settings = get_settings()
    configure_observability(settings)
    if not settings.receipt_queue_url:
        raise RuntimeError("receipt_queue_url_unconfigured")
    sqs = boto3.client("sqs", region_name=settings.aws_region)
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    while not stopping.is_set():
        response = sqs.receive_message(
            QueueUrl=settings.receipt_queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,
            VisibilityTimeout=VISIBILITY_TIMEOUT_SECONDS,
            AttributeNames=["ApproximateReceiveCount"],
        )
        for message in response.get("Messages", []):
            receipt_handle = message["ReceiptHandle"]
            finished = threading.Event()
            heartbeat = threading.Thread(
                target=_extend_visibility,
                args=(sqs, settings.receipt_queue_url, receipt_handle, finished),
                daemon=True,
            )
            heartbeat.start()
            try:
                event = ReceiptEvent.model_validate(json.loads(message["Body"]))
                process_receipt_event(settings, event)
                sqs.delete_message(QueueUrl=settings.receipt_queue_url, ReceiptHandle=receipt_handle)
            except Exception as error:
                logger.error("receipt_processing_failed", extra={"error_code": type(error).__name__})
            finally:
                finished.set()
                heartbeat.join(timeout=1)
        time.sleep(0.1)


if __name__ == "__main__":
    run_worker()
