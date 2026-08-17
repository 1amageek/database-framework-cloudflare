import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseRuntimeEntryQueue } from "../src/DatabaseRuntimeEntryQueue";
import {
  databaseInvocationCapacityReason,
  DatabaseInvocationCapacityError,
} from "../src/DatabaseInvocationCapacityError";

test("runtime entry queue bounds pending client invocations", async () => {
  const queue = runtimeEntryQueue(2, 1024);
  const first = deferred<number>();

  const firstResult = enqueueInvocation(queue,
    new Uint8Array([1]),
    () => first.promise
  );
  const secondResult = enqueueInvocation(queue,
    new Uint8Array([2]),
    () => 2
  );

  await assert.rejects(
    enqueueInvocation(queue, new Uint8Array([3]), () => 3),
    (error: unknown) => error instanceof DatabaseInvocationCapacityError
      && error.reason === databaseInvocationCapacityReason.pendingInvocations
      && error.limit === 2
      && error.pending === 2
      && error.requested === 1
  );

  first.resolve(1);
  assert.equal(await firstResult, 1);
  assert.equal(await secondResult, 2);
});

test("runtime entry queue bounds retained invocation bytes", async () => {
  const queue = runtimeEntryQueue(4, 7);
  const first = deferred<void>();
  const firstResult = enqueueInvocation(queue,
    new Uint8Array([1, 2, 3]),
    () => first.promise
  );
  const secondResult = enqueueInvocation(queue,
    new Uint8Array([4, 5]),
    () => undefined
  );

  await assert.rejects(
    enqueueInvocation(queue, new Uint8Array([6]), () => undefined),
    (error: unknown) => error instanceof DatabaseInvocationCapacityError
      && error.reason
        === databaseInvocationCapacityReason.pendingInvocationBytes
      && error.limit === 7
      && error.pending === 7
      && error.requested === 2
  );

  first.resolve();
  await firstResult;
  await secondResult;
});

test("runtime entry queue accounts for a retained backing buffer", async () => {
  const queue = runtimeEntryQueue(2, 4);
  const backing = new Uint8Array(8);
  const request = backing.subarray(3, 4);

  await assert.rejects(
    enqueueInvocation(queue, request, () => undefined),
    (error: unknown) => error instanceof DatabaseInvocationCapacityError
      && error.reason
        === databaseInvocationCapacityReason.pendingInvocationBytes
      && error.limit === 4
      && error.pending === 0
      && error.requested === 9
  );
});

test("runtime entry queue continues in FIFO order after failure", async () => {
  const queue = runtimeEntryQueue(3, 1024);
  const first = deferred<void>();
  const executionOrder: number[] = [];
  const firstResult = enqueueInvocation(queue, new Uint8Array([1]), async () => {
    executionOrder.push(1);
    await first.promise;
    throw new Error("simulated failure");
  });
  const secondResult = enqueueInvocation(queue, new Uint8Array([2]), () => {
    executionOrder.push(2);
    return 2;
  });

  first.resolve();
  await assert.rejects(firstResult, /simulated failure/);
  assert.equal(await secondResult, 2);
  assert.deepEqual(executionOrder, [1, 2]);
  assert.equal(queue.pendingInvocationCount, 0);
  assert.equal(queue.pendingInvocationByteCount, 0);
});

test("alarm work has reserved FIFO admission when invocations are full", async () => {
  const queue = runtimeEntryQueue(1, 1024);
  const invocation = deferred<void>();
  const executionOrder: string[] = [];
  const invocationResult = enqueueInvocation(queue,
    new Uint8Array([1]),
    async () => {
      executionOrder.push("invocation");
      await invocation.promise;
    }
  );
  const alarmResult = queue.enqueueAlarm(() => {
    executionOrder.push("alarm");
  });

  await assert.rejects(
    enqueueInvocation(queue, new Uint8Array([2]), () => undefined),
    DatabaseInvocationCapacityError
  );
  assert.equal(queue.pendingAlarmCount, 1);

  invocation.resolve();
  await invocationResult;
  await alarmResult;
  assert.deepEqual(executionOrder, ["invocation", "alarm"]);
  assert.equal(queue.pendingAlarmCount, 0);
});

test("runtime entry queue continues after alarm work fails", async () => {
  const queue = runtimeEntryQueue(2, 1024);
  const firstInvocation = deferred<void>();
  const executionOrder: string[] = [];
  const firstResult = enqueueInvocation(queue,
    new Uint8Array([1]),
    async () => {
      executionOrder.push("first-invocation");
      await firstInvocation.promise;
    }
  );
  const alarmResult = queue.enqueueAlarm(() => {
    executionOrder.push("alarm");
    throw new Error("simulated alarm failure");
  });
  const secondResult = enqueueInvocation(queue,
    new Uint8Array([2]),
    () => {
      executionOrder.push("second-invocation");
      return 2;
    }
  );

  firstInvocation.resolve();
  await firstResult;
  await assert.rejects(
    alarmResult,
    /simulated alarm failure/
  );
  assert.equal(await secondResult, 2);
  assert.deepEqual(executionOrder, [
    "first-invocation",
    "alarm",
    "second-invocation",
  ]);
  assert.equal(queue.pendingInvocationCount, 0);
  assert.equal(queue.pendingInvocationByteCount, 0);
  assert.equal(queue.pendingAlarmCount, 0);
});

function runtimeEntryQueue(
  maximumPendingInvocations: number,
  maximumPendingInvocationBytes: number
): DatabaseRuntimeEntryQueue {
  return new DatabaseRuntimeEntryQueue({
    maximumPendingInvocations,
    maximumPendingInvocationBytes,
  });
}

function enqueueInvocation<Response>(
  queue: DatabaseRuntimeEntryQueue,
  requestBytes: Uint8Array,
  operation: (ownedRequestBytes: Uint8Array) => Promise<Response> | Response
): Promise<Response> {
  return queue.enqueueInvocation(
    requestBytes,
    new Uint8Array([1]),
    (ownedRequestBytes) => operation(ownedRequestBytes)
  );
}

function deferred<Value>(): {
  promise: Promise<Value>;
  resolve(value: Value): void;
} {
  let resolvePromise: ((value: Value) => void) | null = null;
  const promise = new Promise<Value>((resolve) => {
    resolvePromise = resolve;
  });
  return {
    promise,
    resolve: (value) => {
      if (resolvePromise === null) {
        throw new Error("Deferred promise is not initialized");
      }
      resolvePromise(value);
    },
  };
}
