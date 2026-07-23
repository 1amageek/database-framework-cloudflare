import {
  databaseMaximumPendingRequests,
  databaseMaximumQueuedRequestBytes,
} from "./DatabaseRuntimeLimits";
import {
  databaseRequestQueueCapacityReason,
  DatabaseRequestQueueCapacityError,
} from "./DatabaseRequestQueueCapacityError";

export class DatabaseRequestQueue {
  private readonly maximumPendingRequests: number;
  private readonly maximumPendingRequestBytes: number;

  private queueTail: Promise<void> = Promise.resolve();
  private pendingCount = 0;
  private pendingBytes = 0;

  constructor(options: {
    maximumPendingRequests: number;
    maximumPendingRequestBytes: number;
  }) {
    this.maximumPendingRequests = validateLimit(
      options.maximumPendingRequests,
      databaseMaximumPendingRequests,
      "maximumPendingRequests"
    );
    this.maximumPendingRequestBytes = validateLimit(
      options.maximumPendingRequestBytes,
      databaseMaximumQueuedRequestBytes,
      "maximumPendingRequestBytes"
    );
  }

  get pendingRequestCount(): number {
    return this.pendingCount;
  }

  get pendingRequestBytes(): number {
    return this.pendingBytes;
  }

  /**
   * Takes exclusive ownership of requestBytes until operation settles.
   * The caller must not mutate its backing buffer after enqueue returns.
   */
  enqueue<Response>(
    requestBytes: Uint8Array,
    operation: (ownedRequestBytes: Uint8Array) => Promise<Response> | Response
  ): Promise<Response> {
    if (this.pendingCount >= this.maximumPendingRequests) {
      return Promise.reject(
        new DatabaseRequestQueueCapacityError({
          reason: databaseRequestQueueCapacityReason.pendingRequests,
          limit: this.maximumPendingRequests,
          pending: this.pendingCount,
          requested: 1,
        })
      );
    }

    // Queueing retains the complete backing buffer, even when the logical
    // request is a view. Account for the memory actually kept alive instead
    // of silently allowing a small subarray to bypass the aggregate limit.
    const retainedByteCount = requestBytes.buffer.byteLength;
    const nextPendingBytes = this.pendingBytes + retainedByteCount;
    if (!Number.isSafeInteger(nextPendingBytes)
        || nextPendingBytes > this.maximumPendingRequestBytes) {
      return Promise.reject(
        new DatabaseRequestQueueCapacityError({
          reason: databaseRequestQueueCapacityReason.pendingRequestBytes,
          limit: this.maximumPendingRequestBytes,
          pending: this.pendingBytes,
          requested: retainedByteCount,
        })
      );
    }

    const ownedRequestBytes = requestBytes;
    this.pendingCount += 1;
    this.pendingBytes = nextPendingBytes;

    const operationPromise = this.queueTail.then(
      () => operation(ownedRequestBytes)
    );
    const settledPromise = operationPromise.then(
      (response) => {
        this.release(retainedByteCount);
        return response;
      },
      (error: unknown) => {
        this.release(retainedByteCount);
        throw error;
      }
    );
    this.queueTail = settledPromise.then(
      () => undefined,
      () => undefined
    );
    return settledPromise;
  }

  private release(requestByteCount: number): void {
    this.pendingCount -= 1;
    this.pendingBytes -= requestByteCount;
  }
}

function validateLimit(
  value: number,
  maximumValue: number,
  field: string
): number {
  if (!Number.isInteger(value) || value <= 0 || value > maximumValue) {
    throw new RangeError(
      `${field} must be an integer from 1 through ${maximumValue}`
    );
  }
  return value;
}
