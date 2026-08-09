import assert from "node:assert/strict";
import test from "node:test";
import {
  databaseAlarmRecoveryDelayMilliseconds,
  databaseMaxPendingRequests,
  databaseMaxQueuedRequestBytes,
  databaseMaxRequestBytes,
  databaseMaxRowsWrittenPerUTCDate,
  databaseInvocationTimeoutMilliseconds,
  DatabaseRuntimeLimitConfigurationError,
  DatabaseInvalidContentLengthError,
  DatabasePayloadTooLargeError,
  readBoundedRequestBytes,
  rejectOversizedContentLength,
} from "../src/DatabaseRuntimeLimits";
import { DatabaseRequestStreamChunkLimitError } from "../src/DatabaseRequestStreamChunkLimitError";

test("bounded request reader accepts payloads within the configured limit", async () => {
  const bytes = await readBoundedRequestBytes(new Request("https://database.local", {
    method: "POST",
    body: new Uint8Array([0x01, 0x02, 0x03]),
  }), 3);

  assert.deepEqual([...bytes], [0x01, 0x02, 0x03]);
});

test("bounded request reader returns a sole stream chunk without copying", async () => {
  const backing = new Uint8Array([0xff, 0xff, 0x01, 0x02, 0x03, 0xff]);
  const chunk = backing.subarray(2, 5);
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(chunk);
      controller.close();
    },
  });
  const request = {
    body: stream,
    headers: new Headers(),
  } as Request;

  const bytes = await readBoundedRequestBytes(request, 3);

  assert.equal(bytes, chunk);
  assert.equal(bytes.byteOffset, 2);
  assert.deepEqual([...bytes], [0x01, 0x02, 0x03]);
});

test("bounded request reader rejects oversized payloads while streaming", async () => {
  await assert.rejects(
    readBoundedRequestBytes(new Request("https://database.local", {
      method: "POST",
      body: new Uint8Array([0x01, 0x02, 0x03, 0x04]),
    }), 3),
    DatabasePayloadTooLargeError
  );
});

test("bounded request reader cancels the stream after exceeding the limit", async () => {
  let canceled = false;
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array([0x01, 0x02]));
      controller.enqueue(new Uint8Array([0x03, 0x04]));
    },
    cancel() {
      canceled = true;
    },
  });

  await assert.rejects(
    readBoundedRequestBytes(new Request("https://database.local", {
      method: "POST",
      body: stream,
      duplex: "half",
    } as RequestInit), 3),
    DatabasePayloadTooLargeError
  );
  assert.equal(canceled, true);
});

test("bounded request reader limits zero-length stream chunk fan-out", async () => {
  let canceled = false;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array());
      controller.enqueue(new Uint8Array());
      controller.enqueue(new Uint8Array());
    },
    cancel() {
      canceled = true;
    },
  });
  const request = {
    body: stream,
    headers: new Headers(),
  } as Request;

  await assert.rejects(
    readBoundedRequestBytes(request, 1, 2),
    (error: unknown) => error instanceof DatabaseRequestStreamChunkLimitError
      && error.limit === 2
  );
  assert.equal(canceled, true);
});

test("bounded request reader cancels a stream after its reader fails", async () => {
  let canceled = false;
  let released = false;
  const request = {
    headers: new Headers(),
    body: {
      getReader() {
        return {
          async read() {
            throw new Error("reader failed");
          },
          async cancel() {
            canceled = true;
          },
          releaseLock() {
            released = true;
          },
        };
      },
    },
  } as unknown as Request;

  await assert.rejects(
    readBoundedRequestBytes(request, 1),
    /reader failed/
  );
  assert.equal(canceled, true);
  assert.equal(released, true);
});

test("bounded request reader preserves cancellation failures as secondary", async () => {
  let released = false;
  const request = {
    headers: new Headers(),
    body: {
      getReader() {
        return {
          async read() {
            throw new Error("reader failed");
          },
          async cancel() {
            throw new Error("cancel failed");
          },
          releaseLock() {
            released = true;
          },
        };
      },
    },
  } as unknown as Request;

  await assert.rejects(
    readBoundedRequestBytes(request, 1),
    /reader failed/
  );
  assert.equal(released, true);
});

test("content length guard rejects invalid and oversized lengths", () => {
  const invalid = rejectOversizedContentLength(new Request("https://database.local", {
    method: "POST",
    headers: {
      "content-length": "invalid",
    },
  }), 3);
  const oversized = rejectOversizedContentLength(new Request("https://database.local", {
    method: "POST",
    headers: {
      "content-length": "4",
    },
  }), 3);

  assert.equal(invalid?.status, 400);
  assert.equal(oversized?.status, 413);
});

test("bounded request reader rejects invalid content length", async () => {
  for (const contentLength of ["invalid", "1e3", "+1", "9007199254740992"]) {
    await assert.rejects(
      readBoundedRequestBytes(new Request("https://database.local", {
        method: "POST",
        headers: { "content-length": contentLength },
      }), 3),
      DatabaseInvalidContentLengthError
    );
  }
});

test("invalid configured limits fail fast", () => {
  assert.throws(
    () => databaseMaxRequestBytes({ DATABASE_MAX_REQUEST_BYTES: "invalid" }),
    DatabaseRuntimeLimitConfigurationError
  );
  assert.throws(
    () => databaseMaxPendingRequests({
      DATABASE_MAX_PENDING_REQUESTS: 0,
    }),
    DatabaseRuntimeLimitConfigurationError
  );
  assert.throws(
    () => databaseMaxQueuedRequestBytes({
      DATABASE_MAX_QUEUED_REQUEST_BYTES: 64 * 1024 * 1024 + 1,
    }),
    DatabaseRuntimeLimitConfigurationError
  );
  assert.throws(
    () => databaseInvocationTimeoutMilliseconds({
      DATABASE_INVOCATION_TIMEOUT_MILLISECONDS: 30_001,
    }),
    DatabaseRuntimeLimitConfigurationError
  );
  assert.throws(
    () => databaseAlarmRecoveryDelayMilliseconds({
      DATABASE_ALARM_RECOVERY_DELAY_MILLISECONDS: 30_000,
    }, 30_000),
    DatabaseRuntimeLimitConfigurationError
  );
  assert.throws(
    () => databaseMaxRowsWrittenPerUTCDate({
      DATABASE_MAX_ROWS_WRITTEN_PER_UTC_DAY: 0,
    }),
    DatabaseRuntimeLimitConfigurationError
  );
});

test("daily SQLite write budget is optional and uses the configured value", () => {
  assert.equal(databaseMaxRowsWrittenPerUTCDate(undefined), null);
  assert.equal(
    databaseMaxRowsWrittenPerUTCDate({
      DATABASE_MAX_ROWS_WRITTEN_PER_UTC_DAY: "50000",
    }),
    50_000
  );
});

test("alarm recovery delay must outlive the invocation deadline", () => {
  assert.equal(
    databaseAlarmRecoveryDelayMilliseconds(undefined, 30_000),
    60_000
  );
  assert.equal(
    databaseAlarmRecoveryDelayMilliseconds({
      DATABASE_ALARM_RECOVERY_DELAY_MILLISECONDS: 45_000,
    }, 30_000),
    45_000
  );
});
