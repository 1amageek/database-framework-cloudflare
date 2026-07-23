import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseRequestQueue } from "../src/DatabaseRequestQueue";
import {
  databaseRequestQueueCapacityReason,
  DatabaseRequestQueueCapacityError,
} from "../src/DatabaseRequestQueueCapacityError";

test("request queue bounds the number of pending requests", async () => {
  const queue = new DatabaseRequestQueue({
    maximumPendingRequests: 2,
    maximumPendingRequestBytes: 1024,
  });
  const first = deferred<number>();

  const firstResult = queue.enqueue(
    new Uint8Array([1]),
    () => first.promise
  );
  const secondResult = queue.enqueue(
    new Uint8Array([2]),
    () => 2
  );

  await assert.rejects(
    queue.enqueue(new Uint8Array([3]), () => 3),
    (error: unknown) => error instanceof DatabaseRequestQueueCapacityError
      && error.reason === databaseRequestQueueCapacityReason.pendingRequests
      && error.limit === 2
      && error.pending === 2
      && error.requested === 1
  );

  first.resolve(1);
  assert.equal(await firstResult, 1);
  assert.equal(await secondResult, 2);
});

test("request queue bounds aggregate pending request bytes", async () => {
  const queue = new DatabaseRequestQueue({
    maximumPendingRequests: 4,
    maximumPendingRequestBytes: 5,
  });
  const first = deferred<void>();
  const firstResult = queue.enqueue(
    new Uint8Array([1, 2, 3]),
    () => first.promise
  );
  const secondResult = queue.enqueue(
    new Uint8Array([4, 5]),
    () => undefined
  );

  await assert.rejects(
    queue.enqueue(new Uint8Array([6]), () => undefined),
    (error: unknown) => error instanceof DatabaseRequestQueueCapacityError
      && error.reason === databaseRequestQueueCapacityReason.pendingRequestBytes
      && error.limit === 5
      && error.pending === 5
      && error.requested === 1
  );

  first.resolve();
  await firstResult;
  await secondResult;
});

test("request queue accounts for the backing buffer retained by a view", async () => {
  const queue = new DatabaseRequestQueue({
    maximumPendingRequests: 2,
    maximumPendingRequestBytes: 4,
  });
  const backing = new Uint8Array(8);
  const request = backing.subarray(3, 4);

  await assert.rejects(
    queue.enqueue(request, () => undefined),
    (error: unknown) => error instanceof DatabaseRequestQueueCapacityError
      && error.reason === databaseRequestQueueCapacityReason.pendingRequestBytes
      && error.limit === 4
      && error.pending === 0
      && error.requested === 8
  );
});

test("request queue continues in FIFO order after an operation fails", async () => {
  const queue = new DatabaseRequestQueue({
    maximumPendingRequests: 3,
    maximumPendingRequestBytes: 1024,
  });
  const first = deferred<void>();
  const executionOrder: number[] = [];
  const firstResult = queue.enqueue(new Uint8Array([1]), async () => {
    executionOrder.push(1);
    await first.promise;
    throw new Error("simulated failure");
  });
  const secondResult = queue.enqueue(new Uint8Array([2]), () => {
    executionOrder.push(2);
    return 2;
  });

  first.resolve();
  await assert.rejects(firstResult, /simulated failure/);
  assert.equal(await secondResult, 2);
  assert.deepEqual(executionOrder, [1, 2]);
  assert.equal(queue.pendingRequestCount, 0);
  assert.equal(queue.pendingRequestBytes, 0);
});

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
