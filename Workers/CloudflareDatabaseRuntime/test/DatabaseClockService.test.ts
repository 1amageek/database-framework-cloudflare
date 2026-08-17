import assert from "node:assert/strict";
import test from "node:test";
import { databaseRuntimeABIVersion } from "../src/DatabaseRuntimeABIVersion";
import type { DatabaseRuntimeEndpoints } from "../src/DatabaseRuntimeTypes";
import {
  databaseClockServiceErrorReason,
  DatabaseClockServiceError,
} from "../src/DatabaseClockServiceError";
import { DatabaseClockService } from "../src/DatabaseClockService";
import type { DatabaseClockWaiter } from "../src/DatabaseClockWaiter";

type ControllableWait = {
  readonly delayMilliseconds: number;
  readonly signal: AbortSignal;
  complete(): void;
  fail(error: Error): void;
};

class ControllableClock implements DatabaseClockWaiter {
  readonly waits: ControllableWait[] = [];

  wait(delayMilliseconds: number, signal: AbortSignal): Promise<void> {
    let completeWait: () => void = () => undefined;
    let failWait: (error: Error) => void = () => undefined;
    const waitCompletion = new Promise<void>((resolve, reject) => {
      completeWait = resolve;
      failWait = reject;
    });
    this.waits.push({
      delayMilliseconds,
      signal,
      complete: completeWait,
      fail: failWait,
    });
    return waitCompletion;
  }
}

test("database clock service resumes a completed wait exactly once", async () => {
  const resumedWaitIDs: number[] = [];
  const clock = new ControllableClock();
  const clockService = makeClockService(
    (waitID) => resumedWaitIDs.push(waitID),
    (error) => {
      throw error;
    },
    2,
    clock
  );

  clockService.schedule(17, 25.5);

  assert.equal(clockService.scheduledWaitCount, 1);
  assert.equal(clock.waits[0]?.delayMilliseconds, 25.5);
  assert.equal(clock.waits[0]?.signal.aborted, false);

  clock.waits[0]?.complete();
  await settleWaitCompletion();
  clock.waits[0]?.complete();
  await settleWaitCompletion();

  assert.deepEqual(resumedWaitIDs, [17]);
  assert.equal(clockService.scheduledWaitCount, 0);
});

test("database clock service rejects invalid wait identifiers, delays, and limits", () => {
  const clock = new ControllableClock();
  const clockService = makeClockService(
    () => undefined,
    (error) => {
      throw error;
    },
    2,
    clock
  );

  assert.throws(() => clockService.schedule(0, 0), RangeError);
  assert.throws(() => clockService.schedule(-1, 0), RangeError);
  assert.throws(() => clockService.schedule(1.5, 0), RangeError);
  assert.throws(() => clockService.schedule(0x1_0000_0000, 0), RangeError);
  assert.throws(() => clockService.schedule(1, -1), RangeError);
  assert.throws(() => clockService.schedule(1, Number.NaN), RangeError);
  assert.throws(() => clockService.schedule(1, Number.POSITIVE_INFINITY), RangeError);
  assert.throws(() => clockService.cancel(0), RangeError);
  assert.throws(() => clockService.cancel(0x1_0000_0000), RangeError);
  assert.throws(
    () => makeClockService(() => undefined, () => undefined, 0, clock),
    RangeError
  );
});

test("database clock service bounds waits and rejects duplicate identifiers", () => {
  const clock = new ControllableClock();
  const clockService = makeClockService(
    () => undefined,
    (error) => {
      throw error;
    },
    1,
    clock
  );

  clockService.schedule(1, 10);

  assert.throws(
    () => clockService.schedule(1, 20),
    (error: unknown) => error instanceof DatabaseClockServiceError
      && error.reason === databaseClockServiceErrorReason.duplicateWaitID
  );
  assert.throws(
    () => clockService.schedule(2, 20),
    (error: unknown) => error instanceof DatabaseClockServiceError
      && error.reason === databaseClockServiceErrorReason.capacityExceeded
  );
  assert.equal(clockService.scheduledWaitCount, 1);
});

test("clock cancellation aborts immediately and makes completion inert", async () => {
  const resumedWaitIDs: number[] = [];
  const clock = new ControllableClock();
  const clockService = makeClockService(
    (waitID) => resumedWaitIDs.push(waitID),
    (error) => {
      throw error;
    },
    1,
    clock
  );

  clockService.schedule(23, 100);
  const wait = clock.waits[0];
  clockService.cancel(23);

  assert.equal(wait?.signal.aborted, true);
  assert.equal(clockService.scheduledWaitCount, 0);
  wait?.complete();
  await settleWaitCompletion();
  assert.deepEqual(resumedWaitIDs, []);
  assert.throws(
    () => clockService.cancel(23),
    (error: unknown) => error instanceof DatabaseClockServiceError
      && error.reason === databaseClockServiceErrorReason.unknownWaitID
  );
});

test("cancellation wins when a resolved wait has not resumed the runtime", async () => {
  const resumedWaitIDs: number[] = [];
  const clock = new ControllableClock();
  const clockService = makeClockService(
    (waitID) => resumedWaitIDs.push(waitID),
    (error) => {
      throw error;
    },
    1,
    clock
  );

  clockService.schedule(29, 0);
  clock.waits[0]?.complete();
  clockService.cancel(29);
  await settleWaitCompletion();

  assert.deepEqual(resumedWaitIDs, []);
  assert.equal(clockService.scheduledWaitCount, 0);
});

test("reused wait identifiers reject completions from the prior token", async () => {
  const resumedWaitIDs: number[] = [];
  const reportedFailures: Error[] = [];
  const clock = new ControllableClock();
  const clockService = makeClockService(
    (waitID) => resumedWaitIDs.push(waitID),
    (error) => reportedFailures.push(error),
    1,
    clock
  );

  clockService.schedule(30, 100);
  clockService.cancel(30);
  clockService.schedule(30, 200);
  clock.waits[0]?.fail(new Error("stale wait failure"));
  await settleWaitCompletion();

  assert.deepEqual(reportedFailures, []);
  assert.equal(clockService.scheduledWaitCount, 1);
  clock.waits[1]?.complete();
  await settleWaitCompletion();

  assert.deepEqual(resumedWaitIDs, [30]);
  assert.equal(clockService.scheduledWaitCount, 0);
});

test("database clock service shutdown aborts waits and ignores stale completions", async () => {
  const resumedWaitIDs: number[] = [];
  const clock = new ControllableClock();
  const clockService = makeClockService(
    (waitID) => resumedWaitIDs.push(waitID),
    (error) => {
      throw error;
    },
    2,
    clock
  );

  clockService.schedule(31, 100);
  clockService.schedule(32, 200);
  clockService.shutdown();
  clockService.shutdown();

  assert.deepEqual(
    clock.waits.map((wait) => wait.signal.aborted),
    [true, true]
  );
  assert.equal(clockService.scheduledWaitCount, 0);
  clock.waits[0]?.complete();
  clock.waits[1]?.fail(new Error("stale failure"));
  await settleWaitCompletion();
  assert.deepEqual(resumedWaitIDs, []);
  assert.throws(
    () => clockService.schedule(33, 1),
    (error: unknown) => error instanceof DatabaseClockServiceError
      && error.reason === databaseClockServiceErrorReason.closed
  );
  assert.throws(
    () => clockService.cancel(31),
    (error: unknown) => error instanceof DatabaseClockServiceError
      && error.reason === databaseClockServiceErrorReason.closed
  );
});

test("database clock service reports asynchronous non-abort failures", async () => {
  const reportedFailures: Error[] = [];
  const clock = new ControllableClock();
  const clockService = makeClockService(
    () => undefined,
    (error) => reportedFailures.push(error),
    1,
    clock
  );

  clockService.schedule(37, 10);
  clock.waits[0]?.fail(new Error("wait service unavailable"));
  await settleWaitCompletion();

  assert.equal(clockService.scheduledWaitCount, 0);
  assert.equal(reportedFailures.length, 1);
  const failure = reportedFailures[0];
  assert.equal(failure instanceof DatabaseClockServiceError, true);
  assert.equal(
    (failure as DatabaseClockServiceError).reason,
    databaseClockServiceErrorReason.waitFailed
  );
  assert.equal(
    (failure as DatabaseClockServiceError).underlyingError?.message,
    "wait service unavailable"
  );
});

test("database clock service reports an unsolicited abort rejection", async () => {
  const reportedFailures: Error[] = [];
  const clock = new ControllableClock();
  const clockService = makeClockService(
    () => undefined,
    (error) => reportedFailures.push(error),
    1,
    clock
  );

  clockService.schedule(41, 10);
  clock.waits[0]?.fail(new DOMException("canceled", "AbortError"));
  await settleWaitCompletion();

  assert.equal(clockService.scheduledWaitCount, 0);
  assert.equal(reportedFailures.length, 1);
  const failure = reportedFailures[0];
  assert.equal(failure instanceof DatabaseClockServiceError, true);
  assert.equal(
    (failure as DatabaseClockServiceError).reason,
    databaseClockServiceErrorReason.waitFailed
  );
  assert.equal(
    (failure as DatabaseClockServiceError).underlyingError?.name,
    "AbortError"
  );
});

test("database clock service reports synchronous clock failures without retaining state", () => {
  const reportedFailures: Error[] = [];
  const clockService = makeClockService(
    () => undefined,
    (error) => reportedFailures.push(error),
    1,
    {
      wait: () => {
        throw new Error("synchronous wait failure");
      },
    }
  );

  assert.throws(
    () => clockService.schedule(43, 10),
    (error: unknown) => error instanceof DatabaseClockServiceError
      && error.reason === databaseClockServiceErrorReason.waitFailed
  );
  assert.equal(clockService.scheduledWaitCount, 0);
  assert.equal(reportedFailures.length, 1);
});

test("database clock service reports runtime resume traps once", async () => {
  const reportedFailures: Error[] = [];
  const clock = new ControllableClock();
  const clockService = makeClockService(
    () => {
      throw new Error("clock resume trap");
    },
    (error) => reportedFailures.push(error),
    1,
    clock
  );

  clockService.schedule(47, 0);
  clock.waits[0]?.complete();
  await settleWaitCompletion();

  assert.deepEqual(
    reportedFailures.map((error) => error.message),
    ["clock resume trap"]
  );
  assert.equal(clockService.scheduledWaitCount, 0);
});

function makeClockService(
  resumeScheduledWait: (waitID: number) => void,
  handleClockFailure: (error: Error) => void,
  maximumScheduledWaits: number,
  clock: DatabaseClockWaiter
): DatabaseClockService {
  const endpoints = runtimeEndpoints(resumeScheduledWait);
  return new DatabaseClockService(
    () => endpoints,
    handleClockFailure,
    maximumScheduledWaits,
    clock
  );
}

function runtimeEndpoints(
  resumeScheduledWait: (waitID: number) => void
): DatabaseRuntimeEndpoints {
  return {
    abiVersion: () => databaseRuntimeABIVersion,
    reservePayload: () => 0,
    releasePayload: () => undefined,
    start: () => undefined,
    invoke: () => undefined,
    alarm: () => undefined,
    shutdown: () => undefined,
    runScheduledTask: () => undefined,
    resumeClockWait: resumeScheduledWait,
    addressSpace: new WebAssembly.Memory({ initial: 1 }),
  };
}

async function settleWaitCompletion(): Promise<void> {
  await Promise.resolve();
}
