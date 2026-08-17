import {
  databaseMaximumPendingRequests,
  databaseMaximumQueuedRequestBytes,
} from "./DatabaseRuntimeLimits";
import {
  databaseInvocationCapacityReason,
  DatabaseInvocationCapacityError,
} from "./DatabaseInvocationCapacityError";

export class DatabaseRuntimeEntryQueue {
  private readonly maximumPendingInvocations: number;
  private readonly maximumPendingInvocationBytes: number;

  private queueTail: Promise<void> = Promise.resolve();
  private admittedInvocationCount = 0;
  private admittedInvocationBytes = 0;
  private admittedAlarmCount = 0;

  constructor(options: {
    maximumPendingInvocations: number;
    maximumPendingInvocationBytes: number;
  }) {
    this.maximumPendingInvocations = validateLimit(
      options.maximumPendingInvocations,
      databaseMaximumPendingRequests,
      "maximumPendingInvocations"
    );
    this.maximumPendingInvocationBytes = validateLimit(
      options.maximumPendingInvocationBytes,
      databaseMaximumQueuedRequestBytes,
      "maximumPendingInvocationBytes"
    );
  }

  get pendingInvocationCount(): number {
    return this.admittedInvocationCount;
  }

  get pendingInvocationByteCount(): number {
    return this.admittedInvocationBytes;
  }

  get pendingAlarmCount(): number {
    return this.admittedAlarmCount;
  }

  /**
   * Takes exclusive ownership of requestBytes until operation settles.
   * The caller must not mutate its backing buffer after enqueue returns.
   */
  enqueueInvocation<Response>(
    requestBytes: Uint8Array,
    contextBytes: Uint8Array,
    operation: (
      ownedRequestBytes: Uint8Array,
      ownedContextBytes: Uint8Array
    ) => Promise<Response> | Response
  ): Promise<Response> {
    if (this.admittedInvocationCount >= this.maximumPendingInvocations) {
      return Promise.reject(
        new DatabaseInvocationCapacityError({
          reason: databaseInvocationCapacityReason.pendingInvocations,
          limit: this.maximumPendingInvocations,
          pending: this.admittedInvocationCount,
          requested: 1,
        })
      );
    }

    // Queueing retains the complete backing buffer, even when the logical
    // request is a view. Account for the memory actually kept alive instead
    // of silently allowing a small subarray to bypass the aggregate limit.
    const retainedByteCount = requestBytes.buffer.byteLength
      + contextBytes.buffer.byteLength;
    const nextPendingBytes = this.admittedInvocationBytes + retainedByteCount;
    if (!Number.isSafeInteger(nextPendingBytes)
        || nextPendingBytes > this.maximumPendingInvocationBytes) {
      return Promise.reject(
        new DatabaseInvocationCapacityError({
          reason: databaseInvocationCapacityReason.pendingInvocationBytes,
          limit: this.maximumPendingInvocationBytes,
          pending: this.admittedInvocationBytes,
          requested: retainedByteCount,
        })
      );
    }

    const ownedRequestBytes = requestBytes;
    const ownedContextBytes = contextBytes;
    this.admittedInvocationCount += 1;
    this.admittedInvocationBytes = nextPendingBytes;

    const operationPromise = this.queueTail.then(
      () => operation(ownedRequestBytes, ownedContextBytes)
    );
    const settledPromise = operationPromise.then(
      (response) => {
        this.releaseInvocation(retainedByteCount);
        return response;
      },
      (error: unknown) => {
        this.releaseInvocation(retainedByteCount);
        throw error;
      }
    );
    this.continueAfter(settledPromise);
    return settledPromise;
  }

  /**
   * Admits Durable Object alarm delivery independently of client invocation
   * capacity while preserving one FIFO across both entry kinds. Durable
   * Object alarm events are platform-owned and do not retain request bytes.
   */
  enqueueAlarm(
    operation: () => Promise<void> | void
  ): Promise<void> {
    this.admittedAlarmCount += 1;
    const operationPromise = this.queueTail.then(operation);
    const settledPromise = operationPromise.then(
      () => {
        this.admittedAlarmCount -= 1;
      },
      (error: unknown) => {
        this.admittedAlarmCount -= 1;
        throw error;
      }
    );
    this.continueAfter(settledPromise);
    return settledPromise;
  }

  private continueAfter(operation: Promise<unknown>): void {
    this.queueTail = operation.then(
      () => undefined,
      () => undefined
    );
  }

  private releaseInvocation(requestByteCount: number): void {
    this.admittedInvocationCount -= 1;
    this.admittedInvocationBytes -= requestByteCount;
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
