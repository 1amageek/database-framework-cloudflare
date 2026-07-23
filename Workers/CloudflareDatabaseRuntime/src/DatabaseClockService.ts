import type { DatabaseRuntimeEndpoints } from "./DatabaseRuntimeTypes";
import {
  databaseClockServiceErrorReason,
  DatabaseClockServiceError,
  type DatabaseClockServiceErrorReason,
} from "./DatabaseClockServiceError";
import {
  cloudflareDatabaseClockWaiter,
  type DatabaseClockWaiter,
} from "./DatabaseClockWaiter";

const maximumWaitID = 0xffff_ffff;

type ClockFailureHandler = (error: Error) => void;

type ScheduledWait = {
  token: symbol;
  controller: AbortController;
};

/// Owns cancellable monotonic waits without interpreting database operations.
export class DatabaseClockService {
  private readonly runtimeEndpoints: () => DatabaseRuntimeEndpoints;
  private readonly handleClockFailure: ClockFailureHandler;
  private readonly maximumScheduledWaits: number;
  private readonly waiter: DatabaseClockWaiter;
  private readonly scheduledWaits = new Map<number, ScheduledWait>();

  private closed = false;

  constructor(
    runtimeEndpoints: () => DatabaseRuntimeEndpoints,
    handleClockFailure: ClockFailureHandler,
    maximumScheduledWaits: number,
    waiter: DatabaseClockWaiter = cloudflareDatabaseClockWaiter
  ) {
    this.runtimeEndpoints = runtimeEndpoints;
    this.handleClockFailure = handleClockFailure;
    this.maximumScheduledWaits = validateMaximumScheduledWaits(
      maximumScheduledWaits
    );
    this.waiter = waiter;
  }

  get scheduledWaitCount(): number {
    return this.scheduledWaits.size;
  }

  schedule(waitID: number, delayMilliseconds: number): void {
    validateWaitID(waitID);
    validateDelay(delayMilliseconds);
    if (this.closed) {
      throw this.makeError(databaseClockServiceErrorReason.closed, waitID);
    }
    if (this.scheduledWaits.has(waitID)) {
      throw this.makeError(
        databaseClockServiceErrorReason.duplicateWaitID,
        waitID
      );
    }
    if (this.scheduledWaits.size >= this.maximumScheduledWaits) {
      throw this.makeError(
        databaseClockServiceErrorReason.capacityExceeded,
        waitID
      );
    }

    const scheduledWait: ScheduledWait = {
      token: Symbol("database-clock-wait"),
      controller: new AbortController(),
    };
    this.scheduledWaits.set(waitID, scheduledWait);

    let completion: Promise<void>;
    try {
      completion = this.waiter.wait(
        delayMilliseconds,
        scheduledWait.controller.signal
      );
    } catch (error) {
      this.scheduledWaits.delete(waitID);
      const failure = this.makeWaitFailure(waitID, error);
      this.handleClockFailure(failure);
      throw failure;
    }

    void completion.then(
      () => this.resume(waitID, scheduledWait.token),
      (error: unknown) => this.fail(waitID, scheduledWait.token, error)
    );
  }

  cancel(waitID: number): void {
    validateWaitID(waitID);
    if (this.closed) {
      throw this.makeError(databaseClockServiceErrorReason.closed, waitID);
    }
    const scheduledWait = this.scheduledWaits.get(waitID);
    if (scheduledWait === undefined) {
      throw this.makeError(databaseClockServiceErrorReason.unknownWaitID, waitID);
    }
    this.scheduledWaits.delete(waitID);
    scheduledWait.controller.abort();
  }

  shutdown(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    const waits = [...this.scheduledWaits.values()];
    this.scheduledWaits.clear();
    for (const wait of waits) {
      wait.controller.abort();
    }
  }

  private resume(waitID: number, token: symbol): void {
    const scheduledWait = this.scheduledWaits.get(waitID);
    if (this.closed
        || scheduledWait === undefined
        || scheduledWait.token !== token) {
      return;
    }
    this.scheduledWaits.delete(waitID);
    try {
      this.runtimeEndpoints().resumeClockWait(waitID);
    } catch (error) {
      this.handleClockFailure(asError(error));
    }
  }

  private fail(waitID: number, token: symbol, error: unknown): void {
    const scheduledWait = this.scheduledWaits.get(waitID);
    if (this.closed
        || scheduledWait === undefined
        || scheduledWait.token !== token) {
      return;
    }
    this.scheduledWaits.delete(waitID);
    this.handleClockFailure(this.makeWaitFailure(waitID, error));
  }

  private makeWaitFailure(
    waitID: number,
    error: unknown
  ): DatabaseClockServiceError {
    return new DatabaseClockServiceError({
      reason: databaseClockServiceErrorReason.waitFailed,
      limit: this.maximumScheduledWaits,
      waitID,
      underlyingError: asError(error),
    });
  }

  private makeError(
    reason: DatabaseClockServiceErrorReason,
    waitID: number
  ): DatabaseClockServiceError {
    return new DatabaseClockServiceError({
      reason,
      limit: this.maximumScheduledWaits,
      waitID,
    });
  }
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function validateWaitID(waitID: number): void {
  if (!Number.isInteger(waitID) || waitID <= 0 || waitID > maximumWaitID) {
    throw new RangeError("Clock wait ID is not a positive UInt32 value");
  }
}

function validateDelay(delayMilliseconds: number): void {
  if (!Number.isFinite(delayMilliseconds) || delayMilliseconds < 0) {
    throw new RangeError("Clock wait delay is not finite and nonnegative");
  }
}

function validateMaximumScheduledWaits(value: number): number {
  if (!Number.isInteger(value) || value <= 0 || value > maximumWaitID) {
    throw new RangeError("Maximum scheduled clock waits is invalid");
  }
  return value;
}
