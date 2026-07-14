import { insertReceiptEvent, type ReceiptCaptureInput, type ReceiptEventRecord } from './receiptStore';

export type QueueResult = ReceiptEventRecord & {
  latencyMs: number;
};

class ReceiptIngestionQueue {
  private tail: Promise<void> = Promise.resolve();
  private pendingCount = 0;

  get depth(): number {
    return this.pendingCount;
  }

  enqueue(task: () => Promise<ReceiptEventRecord>): Promise<QueueResult> {
    const startedAt = Date.now();
    this.pendingCount += 1;

    const queued = this.tail.then(task, task);
    this.tail = queued.then(
      () => undefined,
      () => undefined,
    );

    return queued.finally(() => {
      this.pendingCount -= 1;
    }).then((result) => ({
      ...result,
      latencyMs: Math.max(
        0,
        Date.now() - startedAt,
      ),
    }));
  }

  capture(input: ReceiptCaptureInput): Promise<QueueResult> {
    return this.enqueue(() => insertReceiptEvent(input));
  }
}

export const receiptIngestionQueue = new ReceiptIngestionQueue();
