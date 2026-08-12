import assert from "node:assert/strict";
import test from "node:test";
import type { DatabaseRuntimeEndpoints } from "../src/DatabaseRuntimeTypes";
import { DatabaseTaskScheduler } from "../src/DatabaseTaskScheduler";
import {
  databaseTaskScheduleErrorReason,
  DatabaseTaskScheduleError,
} from "../src/DatabaseTaskScheduleError";

test("database task scheduler routes immediate and delayed tasks", () => {
  const completed: number[] = [];
  const immediateTasks: Array<() => void> = [];
  const timers: Array<{ handleExpiration: () => void; delay: number }> = [];
  const runtime = runtimeEndpoints((taskID) => completed.push(taskID));
  const scheduler = new DatabaseTaskScheduler(
    () => runtime,
    (error) => {
      throw error;
    },
    2,
    (handleExpiration) => immediateTasks.push(handleExpiration),
    {
      schedule(handleExpiration, delay) {
        const timer = { handleExpiration, delay };
        timers.push(timer);
        return timer;
      },
      cancel: () => undefined,
    }
  );

  scheduler.schedule(11, 0);
  scheduler.schedule(12, 25);

  assert.equal(immediateTasks.length, 1);
  assert.deepEqual(timers.map((timer) => timer.delay), [25]);
  immediateTasks[0]?.();
  timers[0]?.handleExpiration();
  assert.deepEqual(completed, [11, 12]);
});

test("database task scheduler rejects invalid task identifiers and delays", () => {
  const scheduler = new DatabaseTaskScheduler(
    () => runtimeEndpoints(() => undefined),
    (error) => {
      throw error;
    },
    2
  );

  assert.throws(() => scheduler.schedule(0, 0), RangeError);
  assert.throws(() => scheduler.schedule(1.5, 0), RangeError);
  assert.throws(() => scheduler.schedule(0x8000_0000, 0), RangeError);
  assert.throws(() => scheduler.schedule(1, -1), RangeError);
  assert.throws(() => scheduler.schedule(1, Number.NaN), RangeError);
  assert.throws(() => scheduler.schedule(1, Number.POSITIVE_INFINITY), RangeError);
});

test("database task scheduler segments delays beyond the platform timer limit", () => {
  const completed: number[] = [];
  const expirationHandlers: Array<() => void> = [];
  const delays: number[] = [];
  const scheduler = new DatabaseTaskScheduler(
    () => runtimeEndpoints((taskID) => completed.push(taskID)),
    (error) => {
      throw error;
    },
    1,
    queueMicrotask,
    {
      schedule(handleExpiration, delay) {
        expirationHandlers.push(handleExpiration);
        delays.push(delay);
        return Symbol("timer");
      },
      cancel: () => undefined,
    }
  );

  scheduler.schedule(1, 0x8000_0018);
  assert.deepEqual(delays, [0x7fff_ffff]);
  expirationHandlers[0]?.();
  assert.deepEqual(delays, [0x7fff_ffff, 25]);
  expirationHandlers[1]?.();
  assert.deepEqual(completed, [1]);
  assert.equal(scheduler.scheduledTaskCount, 0);
});

test("database task scheduler reports scheduled task failures through its fatal handler", () => {
  const immediateTasks: Array<() => void> = [];
  const reportedFailures: Error[] = [];
  const scheduler = new DatabaseTaskScheduler(
    () => runtimeEndpoints(() => {
      throw new Error("scheduled task failed");
    }),
    (error) => reportedFailures.push(error),
    1,
    (handleExpiration) => immediateTasks.push(handleExpiration)
  );

  scheduler.schedule(19, 0);
  immediateTasks[0]?.();

  assert.deepEqual(reportedFailures.map((error) => error.message), ["scheduled task failed"]);
});

test("database task scheduler bounds and releases its scheduled task capacity", () => {
  const immediateTasks: Array<() => void> = [];
  const completed: number[] = [];
  const scheduler = new DatabaseTaskScheduler(
    () => runtimeEndpoints((taskID) => completed.push(taskID)),
    (error) => {
      throw error;
    },
    1,
    (handleExpiration) => immediateTasks.push(handleExpiration)
  );

  scheduler.schedule(1, 0);
  assert.equal(scheduler.scheduledTaskCount, 1);
  assert.throws(
    () => scheduler.schedule(2, 0),
    (error: unknown) => error instanceof DatabaseTaskScheduleError
      && error.reason
        === databaseTaskScheduleErrorReason.capacityExceeded
  );

  immediateTasks[0]?.();
  assert.equal(scheduler.scheduledTaskCount, 0);
  assert.deepEqual(completed, [1]);

  scheduler.schedule(2, 0);
  assert.equal(scheduler.scheduledTaskCount, 1);
});

test("database task scheduler rejects duplicate scheduled task identifiers", () => {
  const immediateTasks: Array<() => void> = [];
  const scheduler = new DatabaseTaskScheduler(
    () => runtimeEndpoints(() => undefined),
    (error) => {
      throw error;
    },
    2,
    (handleExpiration) => immediateTasks.push(handleExpiration)
  );

  scheduler.schedule(7, 0);

  assert.throws(
    () => scheduler.schedule(7, 0),
    (error: unknown) => error instanceof DatabaseTaskScheduleError
      && error.reason === databaseTaskScheduleErrorReason.duplicateTaskID
  );
  assert.equal(scheduler.scheduledTaskCount, 1);
});

test("task scheduler shutdown cancels timers and makes queued expirations inert", () => {
  const immediateTasks: Array<() => void> = [];
  const canceled: unknown[] = [];
  const completed: number[] = [];
  const timerExpirations = new Map<number, () => void>();
  const scheduler = new DatabaseTaskScheduler(
    () => runtimeEndpoints((taskID) => completed.push(taskID)),
    (error) => {
      throw error;
    },
    2,
    (handleExpiration) => immediateTasks.push(handleExpiration),
    {
      schedule(handleExpiration) {
        timerExpirations.set(1, handleExpiration);
        return 1;
      },
      cancel(handle) {
        canceled.push(handle);
        if (typeof handle === "number") {
          timerExpirations.delete(handle);
        }
      },
    }
  );

  scheduler.schedule(1, 0);
  scheduler.schedule(2, 10);
  scheduler.shutdown();

  immediateTasks[0]?.();
  timerExpirations.get(1)?.();
  assert.equal(scheduler.scheduledTaskCount, 0);
  assert.deepEqual(canceled, [1]);
  assert.deepEqual(completed, []);
  assert.throws(
    () => scheduler.schedule(3, 0),
    (error: unknown) => error instanceof DatabaseTaskScheduleError
      && error.reason === databaseTaskScheduleErrorReason.closed
  );
});

function runtimeEndpoints(
  runScheduledTask: (taskID: number) => void
): DatabaseRuntimeEndpoints {
  return {
    reservePayload: () => 0,
    releasePayload: () => undefined,
    start: () => undefined,
    invoke: () => undefined,
    alarm: () => undefined,
    shutdown: () => undefined,
    runScheduledTask,
    resumeClockWait: () => undefined,
    addressSpace: new WebAssembly.Memory({ initial: 1 }),
  };
}
