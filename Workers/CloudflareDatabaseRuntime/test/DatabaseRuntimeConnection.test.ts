import assert from "node:assert/strict";
import test from "node:test";
import { databaseCompletionStatus } from "../src/DatabaseCompletionStatus";
import type { DatabaseAlarmScheduler } from "../src/DatabaseAlarmScheduler";
import { DatabaseAlarmScheduleError } from "../src/DatabaseAlarmScheduleError";
import { DatabaseRuntimeInvocationError } from "../src/DatabaseRuntimeInvocationError";
import { DatabaseRuntimeFailureEncodingError } from "../src/DatabaseRuntimeFailureEncodingError";
import { DatabaseRuntimeFailurePayloadLimitError } from "../src/DatabaseRuntimeFailurePayloadLimitError";
import { DatabaseStorageResponseOwnershipError } from "../src/DatabaseStorageResponseOwnershipError";
import {
  databaseStorageResponseStateErrorReason,
  DatabaseStorageResponseStateError,
} from "../src/DatabaseStorageResponseStateError";
import { DatabaseRuntimeConnection } from "../src/DatabaseRuntimeConnection";
import { DatabaseRuntimeConnectionLimits } from "../src/DatabaseRuntimeConnectionLimits";
import { DatabaseRuntimeConnectionShutdownError } from "../src/DatabaseRuntimeConnectionShutdownError";
import { DatabaseInvocationTimeoutError } from "../src/DatabaseInvocationTimeoutError";
import type { DatabaseClockWaiter } from "../src/DatabaseClockWaiter";
import {
  databaseTaskScheduleErrorReason,
  DatabaseTaskScheduleError,
} from "../src/DatabaseTaskScheduleError";
import {
  databaseRuntimePayloadLimitReason,
  DatabaseRuntimePayloadLimitError,
} from "../src/DatabaseRuntimePayloadLimitError";
import { controllableDatabaseRuntimeInstantiator } from "./ControllableDatabaseRuntime";

const emptyRuntimeProgram = new WebAssembly.Module(
  new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
);
const testContextBytes = new Uint8Array([1]);

function executeDatabaseRequest(
  connection: DatabaseRuntimeConnection,
  requestBytes: Uint8Array
): Promise<Uint8Array> {
  return connection.invoke(requestBytes, testContextBytes);
}

test("runtime connection shutdown rejects subsequent calls without a fatal reset", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await connection.shutdown();
  await connection.shutdown();

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    DatabaseRuntimeConnectionShutdownError
  );
  assert.deepEqual(runtimeFailureReasons, []);
});

test("concurrent shutdown calls share one runtime shutdown", async () => {
  let shutdownCount = 0;
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(
      { kind: "echo" },
      { didShutdown: () => { shutdownCount += 1; } }
    ),
    limits(),
    () => {}
  );

  await Promise.all([connection.shutdown(), connection.shutdown()]);

  assert.equal(shutdownCount, 1);
});

test("shutdown reserves admission when the call registry is full", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({ kind: "hangOnceThenEcho" }),
    new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 1024,
      maximumResponseBytes: 1024,
      maximumPendingInvocations: 1,
    }),
    () => {}
  );

  const acceptedRequest = executeDatabaseRequest(
    connection,
    new Uint8Array([1])
  );
  const acceptedRequestFailure = assert.rejects(
    acceptedRequest,
    DatabaseRuntimeConnectionShutdownError
  );
  const shutdown = connection.shutdown();

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([2])),
    DatabaseRuntimeConnectionShutdownError
  );
  await shutdown;
  await acceptedRequestFailure;
});

test("application failure and cancellation remain non-terminal", async () => {
  for (const status of [
    databaseCompletionStatus.applicationFailed,
    databaseCompletionStatus.cancelled,
  ]) {
    const runtimeFailureReasons: string[] = [];
    const connection = await DatabaseRuntimeConnection.instantiate(
      emptyRuntimeProgram,
      { dispatchBytes: (bytes) => bytes },
      resolvingAlarmScheduler(),
      controllableDatabaseRuntimeInstantiator({
        kind: "failureOnceThenEcho",
        status,
        message: "application outcome",
      }),
      limits(),
      (reason) => runtimeFailureReasons.push(reason)
    );

    await assert.rejects(
      executeDatabaseRequest(connection, new Uint8Array([1])),
      (error: unknown) => error instanceof DatabaseRuntimeInvocationError
        && error.status === status
    );
    assert.deepEqual(
      await executeDatabaseRequest(connection, new Uint8Array([2])),
      new Uint8Array([2])
    );
    assert.deepEqual(runtimeFailureReasons, []);
    await connection.shutdown();
  }
});

test("runtime connection owns request bytes across asynchronous runtime execution", async () => {
  let releasedPayloadCount = 0;
  let invocationCount = 0;
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(
      { kind: "echo" },
      {
        didReleasePayload: () => {
          releasedPayloadCount += 1;
        },
        didInvoke: () => {
          invocationCount += 1;
        },
      }
    ),
    limits(),
    () => undefined
  );

  const response = await executeDatabaseRequest(connection, new Uint8Array([1, 2, 3]));

  assert.deepEqual([...response], [1, 2, 3]);
  assert.equal(invocationCount, 1);
  assert.equal(releasedPayloadCount, 0);
});

test("runtime connection honors the logical range of an offset request view", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(),
    limits(),
    () => undefined
  );
  const backing = new Uint8Array([0xff, 0x01, 0x02, 0x03, 0xff]);

  const response = await executeDatabaseRequest(connection, backing.subarray(1, 4));

  assert.deepEqual([...response], [0x01, 0x02, 0x03]);
});

test("runtime connection owns completion bytes before runtime memory is reused", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({ kind: "completionPayloadInvalidated" }),
    limits(),
    () => undefined
  );

  const response = await executeDatabaseRequest(connection, new Uint8Array([1, 2, 3]));

  assert.deepEqual([...response], [1, 2, 3]);
});

test("runtime connection releases request payload when copying fails before invoke", async () => {
  let releasedPayloadCount = 0;
  let invocationCount = 0;
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(
      { kind: "invalidRequestPayloadAddress" },
      {
        didReleasePayload: () => {
          releasedPayloadCount += 1;
        },
        didInvoke: () => {
          invocationCount += 1;
        },
      }
    ),
    limits(),
    () => undefined
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1, 2, 3])),
    (error: unknown) => error instanceof RangeError
      && error.message === "Database runtime payload range is out of bounds"
  );
  assert.equal(invocationCount, 0);
  assert.equal(releasedPayloadCount, 2);
});

test("runtime connection rejects a zero request payload address before copying or invoking", async () => {
  const runtimeFailureReasons: string[] = [];
  let releasedPayloadCount = 0;
  let invocationCount = 0;
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(
      { kind: "zeroRequestPayloadAddress" },
      {
        didReleasePayload: () => {
          releasedPayloadCount += 1;
        },
        didInvoke: () => {
          invocationCount += 1;
        },
      }
    ),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1, 2, 3])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.runtimeFailed
      && error.message === "Database runtime returned a zero request payload address"
  );
  assert.equal(invocationCount, 0);
  assert.equal(releasedPayloadCount, 1);
  assert.deepEqual(
    runtimeFailureReasons,
    ["Database runtime returned a zero request payload address"]
  );
});

test("call IDs remain positive across the JavaScript and WebAssembly i32 boundary", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(),
    limits(),
    () => undefined
  );
  const state = connection as unknown as { nextCallID: number };
  state.nextCallID = 0x7fff_ffff;

  const first = await executeDatabaseRequest(connection, new Uint8Array([7]));
  const second = await executeDatabaseRequest(connection, new Uint8Array([8]));

  assert.deepEqual([...first], [7]);
  assert.deepEqual([...second], [8]);
  assert.equal(state.nextCallID, 2);
});

test("a synchronous timeout handleExpiration cannot escape the pending invocation state", async () => {
  const runtimeFailureReasons: string[] = [];
  let cancellationCount = 0;

  await assert.rejects(
    DatabaseRuntimeConnection.instantiate(
      emptyRuntimeProgram,
      { dispatchBytes: (bytes) => bytes },
      resolvingAlarmScheduler(),
      controllableDatabaseRuntimeInstantiator(),
      limits(),
      (reason) => runtimeFailureReasons.push(reason),
      {
        schedule(handleExpiration) {
          handleExpiration();
          return Symbol("synchronous-timeout");
        },
        cancel() {
          cancellationCount += 1;
        },
      }
    ),
    (error: unknown) => error instanceof DatabaseInvocationTimeoutError
  );

  assert.equal(cancellationCount, 1);
  assert.deepEqual(
    runtimeFailureReasons,
    ["Database runtime call did not complete within 30000 milliseconds"]
  );
});

test("runtime connection propagates typed Unicode completion failures", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "failure",
      status: databaseCompletionStatus.runtimeFailed,
      message: "simulated failure 🚫",
    }),
    limits(),
    () => undefined
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.runtimeFailed
      && error.message === "simulated failure 🚫"
  );
});

test("runtime failure completion terminates the runtime generation", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "failure",
      status: databaseCompletionStatus.runtimeFailed,
      message: "runtime invariant failed",
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.runtimeFailed
      && error.message === "runtime invariant failed"
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([2])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.runtimeFailed
      && error.message === "runtime invariant failed"
  );
  assert.deepEqual(runtimeFailureReasons, ["runtime invariant failed"]);
});

test("startup failure discards pending runtime services before retry", async () => {
  let clockWaitWasAborted = false;
  let scheduledTaskRunCount = 0;
  const runtimeFailureReasons: string[] = [];

  await assert.rejects(
    DatabaseRuntimeConnection.instantiate(
      emptyRuntimeProgram,
      { dispatchBytes: (bytes) => bytes },
      resolvingAlarmScheduler(),
      controllableDatabaseRuntimeInstantiator(
        {
          kind: "startupFailureWithPendingServices",
          message: "startup unavailable",
        },
        {
          didRunScheduledTask: () => {
            scheduledTaskRunCount += 1;
          },
        }
      ),
      limits(),
      (reason) => runtimeFailureReasons.push(reason),
      undefined,
      {
        wait(_delayMilliseconds, signal) {
          return new Promise<void>((_resolve, reject) => {
            signal.addEventListener("abort", () => {
              clockWaitWasAborted = true;
              reject(new DOMException("Aborted", "AbortError"));
            }, { once: true });
          });
        },
      }
    ),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.startupFailed
  );

  await new Promise<void>((resolve) => setTimeout(resolve, 20));
  assert.equal(clockWaitWasAborted, true);
  assert.equal(scheduledTaskRunCount, 0);
  assert.deepEqual(runtimeFailureReasons, []);
});

test("ABI invariant completion failures terminate the runtime generation", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "failure",
      status: databaseCompletionStatus.invalidPayload,
      message: "payload ownership failed",
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.invalidPayload
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([2])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.invalidPayload
  );
  assert.deepEqual(runtimeFailureReasons, ["payload ownership failed"]);
});

test("oversized failure payloads terminate before UTF-8 decoding", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "failureBytes",
      status: databaseCompletionStatus.applicationFailed,
      bytes: new Array(9).fill(0x41),
    }),
    new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 1024,
      maximumResponseBytes: 1024,
      maximumFailureBytes: 8,
    }),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseRuntimeFailurePayloadLimitError
      && error.message === "Database runtime failure payload exceeds the connection limit"
  );
  assert.deepEqual(
    runtimeFailureReasons,
    ["Database runtime failure payload exceeds the connection limit"]
  );
});

test("terminal failure status wins over the success response limit", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "failure",
      status: databaseCompletionStatus.runtimeFailed,
      message: "fatal",
    }),
    new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 1024,
      maximumResponseBytes: 4,
      maximumFailureBytes: 8,
    }),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.runtimeFailed
      && error.message === "fatal"
  );
  assert.deepEqual(runtimeFailureReasons, ["fatal"]);
});

test("malformed UTF-8 failure payloads terminally poison the runtime", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "failureBytes",
      status: databaseCompletionStatus.runtimeFailed,
      bytes: [0xf0, 0x9f, 0x98],
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    DatabaseRuntimeFailureEncodingError
  );
  assert.deepEqual(
    runtimeFailureReasons,
    ["Database runtime returned a malformed UTF-8 failure payload"]
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([2])),
    DatabaseRuntimeFailureEncodingError
  );
});

test("runtime connection routes storage services through the StorageKit dispatcher", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    {
      dispatchBytes: (bytes) => new Uint8Array([...bytes, 9]),
    },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({ kind: "storage" }),
    limits(),
    () => undefined
  );

  const response = await executeDatabaseRequest(connection, new Uint8Array([4, 5]));

  assert.deepEqual([...response], [4, 5, 9]);
});

test("storage responses do not consume connection-owned payload count", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: () => new Uint8Array([9]) },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "storageRepeated",
      dispatchCount: 2,
    }),
    new DatabaseRuntimeConnectionLimits({
      maximumContextBytes: 1,
      maximumRequestBytes: 1,
      maximumResponseBytes: 1,
      maximumStorageRequestBytes: 1,
      maximumStorageResponseBytes: 1,
      maximumPayloadCountPerInvocationSet: 2,
      maximumPayloadBytesPerInvocationSet: 64,
    }),
    (reason) => runtimeFailureReasons.push(reason)
  );

  assert.deepEqual(
    [...(await executeDatabaseRequest(connection, new Uint8Array([1])))],
    [9]
  );
  assert.deepEqual(runtimeFailureReasons, []);
});

test("storage responses do not consume connection-owned payload bytes", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: () => new Uint8Array([9]) },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "storageRepeated",
      dispatchCount: 2,
    }),
    new DatabaseRuntimeConnectionLimits({
      maximumContextBytes: 1,
      maximumRequestBytes: 1,
      maximumResponseBytes: 1,
      maximumStorageRequestBytes: 1,
      maximumStorageResponseBytes: 1,
      maximumPayloadCountPerInvocationSet: 2,
      maximumPayloadBytesPerInvocationSet: 2,
    }),
    () => undefined
  );

  assert.deepEqual(
    [...(await executeDatabaseRequest(connection, new Uint8Array([1])))],
    [9]
  );
});

test("runtime connection resets payload budgets after each call", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes.slice() },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(),
    new DatabaseRuntimeConnectionLimits({
      maximumContextBytes: 1,
      maximumRequestBytes: 1,
      maximumResponseBytes: 1,
      maximumStorageRequestBytes: 1,
      maximumStorageResponseBytes: 1,
      maximumPayloadCountPerInvocationSet: 2,
      maximumPayloadBytesPerInvocationSet: 5,
    }),
    () => undefined
  );

  assert.deepEqual([...(await executeDatabaseRequest(connection, new Uint8Array([1])))], [1]);
  assert.deepEqual([...(await executeDatabaseRequest(connection, new Uint8Array([2])))], [2]);
});

test("runtime connection rejects an oversized initial address space", async () => {
  await assert.rejects(
    DatabaseRuntimeConnection.instantiate(
      emptyRuntimeProgram,
      { dispatchBytes: (bytes) => bytes },
      resolvingAlarmScheduler(),
      controllableDatabaseRuntimeInstantiator(),
      new DatabaseRuntimeConnectionLimits({
        maximumRequestBytes: 1,
        maximumResponseBytes: 1,
        maximumRuntimeAddressSpaceBytes: 64 * 1024,
      }),
      () => undefined
    ),
    (error: unknown) => error instanceof DatabaseRuntimePayloadLimitError
      && error.reason === databaseRuntimePayloadLimitReason.addressSpaceBytes
      && error.requested === 2 * 64 * 1024
  );
});

test("storage response length mismatch is terminal", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: () => new Uint8Array([4, 5, 9]) },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(
      { kind: "storageResponseLengthMismatch" }
    ),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseStorageResponseStateError
      && error.reason
        === databaseStorageResponseStateErrorReason.responseLengthMismatch
      && error.expectedByteCount === 3
      && error.actualByteCount === 4
  );
  assert.deepEqual(
    runtimeFailureReasons,
    ["Storage response length 4 does not match 3"]
  );
});

test("runtime connection honors an offset storage response view", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    {
      dispatchBytes: () => {
        const backing = new Uint8Array([0xff, 4, 5, 9, 0xff]);
        return backing.subarray(1, 4);
      },
    },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({ kind: "storage" }),
    limits(),
    () => undefined
  );

  const response = await executeDatabaseRequest(connection, new Uint8Array([0]));

  assert.deepEqual([...response], [4, 5, 9]);
});

test("runtime connection rejects storage responses that alias runtime memory", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({ kind: "storage" }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    DatabaseStorageResponseOwnershipError
  );
  assert.deepEqual(
    runtimeFailureReasons,
    ["Storage response must not alias the borrowed runtime request"]
  );
});

test("runtime connection enforces request and response limits", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(),
    new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 2,
      maximumResponseBytes: 1,
    }),
    () => undefined
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1, 2, 3])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.requestTooLarge
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1, 2])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.responseTooLarge
  );
});

test("response limits are checked before reading runtime memory", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "oversizedCompletionOnceThenEcho",
      length: 2,
    }),
    new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 2,
      maximumResponseBytes: 1,
    }),
    () => undefined
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.responseTooLarge
  );

  const response = await executeDatabaseRequest(connection, new Uint8Array([7]));
  assert.deepEqual([...response], [7]);
});

test("a runtime startup trap requests exactly one fatal reset", async () => {
  const runtimeFailureReasons: string[] = [];

  await assert.rejects(
    DatabaseRuntimeConnection.instantiate(
      emptyRuntimeProgram,
      { dispatchBytes: (bytes) => bytes },
      resolvingAlarmScheduler(),
      controllableDatabaseRuntimeInstantiator({
        kind: "commandFailure",
        runtimeCommand: "start",
        message: "startup trap",
      }),
      limits(),
      (reason) => runtimeFailureReasons.push(reason)
    ),
    (error: unknown) => error instanceof Error
      && error.message === "startup trap"
  );

  assert.deepEqual(runtimeFailureReasons, ["startup trap"]);
});

test("a runtime invocation trap permanently poisons its runtime generation", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "commandFailure",
      runtimeCommand: "invoke",
      message: "invoke trap",
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof Error
      && error.message === "invoke trap"
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([2])),
    (error: unknown) => error instanceof Error
      && error.message === "invoke trap"
  );
  await assert.rejects(
    connection.shutdown(),
    (error: unknown) => error instanceof Error
      && error.message === "invoke trap"
  );
  assert.deepEqual(runtimeFailureReasons, ["invoke trap"]);
});

test("a runtime alarm trap permanently poisons its runtime generation", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "commandFailure",
      runtimeCommand: "alarm",
      message: "alarm trap",
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    connection.alarm(),
    (error: unknown) => error instanceof Error
      && error.message === "alarm trap"
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof Error
      && error.message === "alarm trap"
  );
  assert.deepEqual(runtimeFailureReasons, ["alarm trap"]);
});

test("a scheduled task failure rejects every pending call and cancels every timer", async () => {
  const timer = controlledInvocationTimer();
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "commandFailure",
      runtimeCommand: "scheduledTask",
      message: "scheduled task failed",
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason),
    timer.timer
  );

  const resultsPromise = Promise.allSettled([
    executeDatabaseRequest(connection, new Uint8Array([1])),
    executeDatabaseRequest(connection, new Uint8Array([2])),
  ]);
  assert.equal(timer.activeCount(), 2);

  const results = await resultsPromise;

  assert.deepEqual(
    results.map((result) => result.status === "rejected"
      ? (result.reason as Error).message
      : "resolved"),
    ["scheduled task failed", "scheduled task failed"]
  );
  assert.equal(timer.activeCount(), 0);
  assert.deepEqual(runtimeFailureReasons, ["scheduled task failed"]);
});

test("task scheduling capacity failure resets the runtime generation", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "scheduledTaskBurst",
      taskCount: 2,
    }),
    new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 1,
      maximumResponseBytes: 1,
      maximumScheduledTasks: 1,
    }),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseTaskScheduleError
      && error.reason
        === databaseTaskScheduleErrorReason.capacityExceeded
  );
  assert.deepEqual(
    runtimeFailureReasons,
    ["Scheduled database task count exceeds 1"]
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    DatabaseTaskScheduleError
  );
});

test("runtime connection installs cancellable clock services and routes resume", async () => {
  let registeredRuntimeServices: WebAssembly.Imports | null = null;
  const resumedWaitIDs: number[] = [];
  const waits: Array<{
    delayMilliseconds: number;
    signal: AbortSignal;
    resolve(): void;
  }> = [];
  const waiter: DatabaseClockWaiter = {
    wait: (delayMilliseconds, signal) => new Promise<void>((resolve) => {
      waits.push({ delayMilliseconds, signal, resolve });
    }),
  };
  const invocationTimer = controlledInvocationTimer();
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(
      { kind: "echo" },
      {
        didRegisterRuntimeServices: (runtimeServices) => {
          registeredRuntimeServices = runtimeServices;
        },
        didResumeClockWait: (waitID) => resumedWaitIDs.push(waitID),
      }
    ),
    limits(),
    () => undefined,
    invocationTimer.timer,
    waiter
  );
  const runtimeServices = registeredRuntimeServices as WebAssembly.Imports | null;
  assert.notEqual(runtimeServices, null);

  scheduleClockWait(runtimeServices ?? {}, 53, 12.5);
  assert.equal(connection.scheduledClockWaitCount, 1);
  assert.equal(waits[0]?.delayMilliseconds, 12.5);
  waits[0]?.resolve();
  await Promise.resolve();
  assert.deepEqual(resumedWaitIDs, [53]);
  assert.equal(connection.scheduledClockWaitCount, 0);

  scheduleClockWait(runtimeServices ?? {}, 59, 100);
  cancelClockWait(runtimeServices ?? {}, 59);
  assert.equal(waits[1]?.signal.aborted, true);
  assert.equal(connection.scheduledClockWaitCount, 0);
  waits[1]?.resolve();
  await Promise.resolve();
  assert.deepEqual(resumedWaitIDs, [53]);

  await connection.shutdown();
});

test("runtime connection supplies monotonic and wall-clock values", async () => {
  let registeredRuntimeServices: WebAssembly.Imports | null = null;
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(
      { kind: "echo" },
      {
        didRegisterRuntimeServices: (runtimeServices) => {
          registeredRuntimeServices = runtimeServices;
        },
      }
    ),
    limits(),
    () => undefined,
    controlledInvocationTimer().timer
  );
  const runtimeServices = registeredRuntimeServices as WebAssembly.Imports | null;
  assert.notEqual(runtimeServices, null);

  const monotonicNanoseconds = runtimeServices?.database_clock
    ?.monotonic_nanoseconds;
  const wallTimeMilliseconds = runtimeServices?.database_clock
    ?.wall_time_milliseconds;
  assert.equal(typeof monotonicNanoseconds, "function");
  assert.equal(typeof wallTimeMilliseconds, "function");

  const monotonic = (monotonicNanoseconds as () => bigint)();
  const wallTime = (wallTimeMilliseconds as () => bigint)();
  assert.ok(monotonic >= 0n);
  assert.ok(wallTime >= BigInt(Date.now() - 1_000));
  assert.ok(wallTime <= BigInt(Date.now() + 1_000));

  await connection.shutdown();
});

test("clock wait IDs preserve unsigned WebAssembly i32 bit patterns", async () => {
  let registeredRuntimeServices: WebAssembly.Imports | null = null;
  const resumedWaitIDs: number[] = [];
  let resolveWait: () => void = () => undefined;
  const waiter: DatabaseClockWaiter = {
    wait: () => new Promise<void>((resolve) => {
      resolveWait = resolve;
    }),
  };
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(
      { kind: "echo" },
      {
        didRegisterRuntimeServices: (runtimeServices) => {
          registeredRuntimeServices = runtimeServices;
        },
        didResumeClockWait: (waitID) => resumedWaitIDs.push(waitID),
      }
    ),
    limits(),
    () => undefined,
    controlledInvocationTimer().timer,
    waiter
  );
  const runtimeServices = registeredRuntimeServices as WebAssembly.Imports | null;

  scheduleClockWait(runtimeServices ?? {}, -1, 0);
  resolveWait();
  await Promise.resolve();

  assert.deepEqual(resumedWaitIDs, [0xffff_ffff]);
  assert.equal(connection.scheduledClockWaitCount, 0);
  await connection.shutdown();
});

const completionProtocolViolations = [
  ["unknownCallID", "Database runtime completed unknown call ID 4294967295"],
  ["duplicateCallID", "Database runtime completed call ID 2 more than once"],
  ["unknownStatus", "Database runtime returned unknown completion status 4294967295"],
  ["invalidPayloadAddress", "Database runtime payload range is out of bounds"],
  ["invalidPayloadByteCount", "Database completion length is invalid"],
] as const;

for (const [violation, expectedMessage] of completionProtocolViolations) {
  test(`${violation} completion terminally poisons the runtime`, async () => {
    const timer = controlledInvocationTimer();
    const runtimeFailureReasons: string[] = [];
    const connection = await DatabaseRuntimeConnection.instantiate(
      emptyRuntimeProgram,
      { dispatchBytes: (bytes) => bytes },
      resolvingAlarmScheduler(),
      controllableDatabaseRuntimeInstantiator({
        kind: "invalidCompletion",
        violation,
      }),
      limits(),
      (reason) => runtimeFailureReasons.push(reason),
      timer.timer
    );

    await assert.rejects(
      executeDatabaseRequest(connection, new Uint8Array([1])),
      (error: unknown) => error instanceof Error
        && error.message === expectedMessage
    );
    assert.equal(timer.activeCount(), 0);
    assert.deepEqual(runtimeFailureReasons, [expectedMessage]);

    await assert.rejects(
      executeDatabaseRequest(connection, new Uint8Array([2])),
      (error: unknown) => error instanceof Error
        && error.message === expectedMessage
    );
    assert.deepEqual(runtimeFailureReasons, [expectedMessage]);
  });
}

test("a timed out call resets and permanently poisons its runtime instance", async () => {
  const timer = controlledInvocationTimer();
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({ kind: "hangOnceThenEcho" }),
    new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 1024,
      maximumResponseBytes: 1024,
      maximumPendingInvocations: 1,
      invocationTimeoutMilliseconds: 25,
    }),
    (reason) => runtimeFailureReasons.push(reason),
    timer.timer
  );

  const timedOutCall = executeDatabaseRequest(connection, new Uint8Array([1]));
  assert.equal(timer.activeCount(), 1);
  timer.fireNext();

  await assert.rejects(
    timedOutCall,
    (error: unknown) => error instanceof DatabaseInvocationTimeoutError
      && error.timeoutMilliseconds === 25
  );
  assert.equal(timer.activeCount(), 0);
  assert.deepEqual(
    runtimeFailureReasons,
    ["Database runtime call did not complete within 25 milliseconds"]
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([2, 3])),
    (error: unknown) => error instanceof DatabaseInvocationTimeoutError
      && error.timeoutMilliseconds === 25
  );
  assert.equal(timer.activeCount(), 0);
});

test("runtime connection runs a Durable Object alarm through the runtime export", async () => {
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator(),
    limits(),
    () => undefined
  );

  await connection.alarm();
});

test("a non-empty successful alarm payload poisons its runtime generation", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "alarmPayload",
      bytes: [1],
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    connection.alarm(),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.runtimeFailed
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.runtimeFailed
  );
  assert.deepEqual(
    runtimeFailureReasons,
    ["Database alarm execution returned an unexpected payload"]
  );
});

test("runtime connection preserves runtime alarm failures for platform retry", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "alarmFailureOnce",
      status: databaseCompletionStatus.alarmFailed,
      message: "alarm failed",
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    connection.alarm(),
    (error: unknown) => error instanceof DatabaseRuntimeInvocationError
      && error.status === databaseCompletionStatus.alarmFailed
      && error.message === "alarm failed"
  );
  await connection.alarm();
  assert.deepEqual(
    await executeDatabaseRequest(connection, new Uint8Array([1, 2, 3])),
    new Uint8Array([1, 2, 3])
  );
  assert.deepEqual(runtimeFailureReasons, []);
});

test("alarm failure status from a request poisons the runtime", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    resolvingAlarmScheduler(),
    controllableDatabaseRuntimeInstantiator({
      kind: "failure",
      status: databaseCompletionStatus.alarmFailed,
      message: "invalid request completion",
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );
  const expectedMessage =
    "Database runtime returned an alarm failure for a request call";

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof Error
      && error.message === expectedMessage
  );
  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([2])),
    (error: unknown) => error instanceof Error
      && error.message === expectedMessage
  );
  assert.deepEqual(runtimeFailureReasons, [expectedMessage]);
});

test("alarm failure status cannot complete runtime startup", async () => {
  const runtimeFailureReasons: string[] = [];
  const expectedMessage =
    "Database runtime returned an alarm failure for a startup call";

  await assert.rejects(
    DatabaseRuntimeConnection.instantiate(
      emptyRuntimeProgram,
      { dispatchBytes: (bytes) => bytes },
      resolvingAlarmScheduler(),
      controllableDatabaseRuntimeInstantiator({
        kind: "startupFailure",
        status: databaseCompletionStatus.alarmFailed,
        message: "invalid startup completion",
      }),
      limits(),
      (reason) => runtimeFailureReasons.push(reason)
    ),
    (error: unknown) => error instanceof Error
      && error.message === expectedMessage
  );
  assert.deepEqual(runtimeFailureReasons, [expectedMessage]);
});

test("runtime completion waits for Durable Object alarm persistence", async () => {
  let finishSchedule: (() => void) | undefined;
  const timestamps: number[] = [];
  const scheduleBarrier = new Promise<void>((resolve) => {
    finishSchedule = resolve;
  });
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    {
      ensureWakeUpNoLaterThan: (timestampMilliseconds) => {
        timestamps.push(timestampMilliseconds);
        return scheduleBarrier;
      },
    },
    controllableDatabaseRuntimeInstantiator({
      kind: "scheduleAlarm",
      secondsSinceUnixEpoch: 1_700_000_000n,
      nanoseconds: 1,
    }),
    limits(),
    () => undefined
  );

  let settled = false;
  const responsePromise = executeDatabaseRequest(connection, new Uint8Array([8])).then(
    (response) => {
      settled = true;
      return response;
    }
  );
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(timestamps, [1_700_000_000_000]);
  assert.equal(settled, false);
  finishSchedule?.();
  assert.deepEqual([...(await responsePromise)], [8]);
});

test("alarm persistence failure poisons the runtime and requests a reset", async () => {
  const runtimeFailureReasons: string[] = [];
  const connection = await DatabaseRuntimeConnection.instantiate(
    emptyRuntimeProgram,
    { dispatchBytes: (bytes) => bytes },
    {
      ensureWakeUpNoLaterThan: async () => {
        throw new Error("alarm storage unavailable");
      },
    },
    controllableDatabaseRuntimeInstantiator({
      kind: "scheduleAlarm",
      secondsSinceUnixEpoch: 1_700_000_000n,
      nanoseconds: 0,
    }),
    limits(),
    (reason) => runtimeFailureReasons.push(reason)
  );

  await assert.rejects(
    executeDatabaseRequest(connection, new Uint8Array([1])),
    (error: unknown) => error instanceof DatabaseAlarmScheduleError
      && error.reason.message === "alarm storage unavailable"
  );
  assert.deepEqual(
    runtimeFailureReasons,
    ["Durable Object alarm scheduling failed: alarm storage unavailable"]
  );
  await assert.rejects(
    connection.alarm(),
    (error: unknown) => error instanceof DatabaseAlarmScheduleError
  );
});

function limits(): DatabaseRuntimeConnectionLimits {
  return new DatabaseRuntimeConnectionLimits({
    maximumRequestBytes: 1024,
    maximumResponseBytes: 1024,
  });
}

test("runtime connection resource limits reject inconsistent configurations", () => {
  assert.throws(
    () => new DatabaseRuntimeConnectionLimits({
      maximumContextBytes: 4,
      maximumRequestBytes: 8,
      maximumResponseBytes: 8,
      maximumStorageResponseBytes: 8,
      maximumPayloadBytesPerInvocationSet: 11,
    }),
    (error: unknown) => error instanceof RangeError
      && error.message === "maximumPayloadBytesPerInvocationSet must be at least 12"
  );
  assert.throws(
    () => new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 1,
      maximumResponseBytes: 1,
      maximumScheduledTasks: 0,
    }),
    RangeError
  );
  assert.throws(
    () => new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 1,
      maximumResponseBytes: 1,
      maximumScheduledClockWaits: 0,
    }),
    RangeError
  );
  assert.throws(
    () => new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: 1,
      maximumResponseBytes: 1,
      maximumWasiIovecCount: 65_537,
    }),
    RangeError
  );
});

function resolvingAlarmScheduler(): DatabaseAlarmScheduler {
  return {
    ensureWakeUpNoLaterThan: async () => undefined,
  };
}

function scheduleClockWait(
  runtimeServices: WebAssembly.Imports,
  waitID: number,
  delayMilliseconds: number
): void {
  const scheduleWait = runtimeServices.database_clock?.schedule;
  if (typeof scheduleWait !== "function") {
    throw new Error("database_clock.schedule is not installed");
  }
  scheduleWait(waitID, delayMilliseconds);
}

function cancelClockWait(
  runtimeServices: WebAssembly.Imports,
  waitID: number
): void {
  const cancelWait = runtimeServices.database_clock?.cancel;
  if (typeof cancelWait !== "function") {
    throw new Error("database_clock.cancel is not installed");
  }
  cancelWait(waitID);
}

function controlledInvocationTimer(): {
  timer: {
    schedule(handleExpiration: () => void, delayMilliseconds: number): unknown;
    cancel(handle: unknown): void;
  };
  activeCount(): number;
  fireNext(): void;
} {
  let nextHandle = 1;
  const expirationHandlers = new Map<number, () => void>();
  return {
    timer: {
      schedule: (handleExpiration, _delayMilliseconds) => {
        const handle = nextHandle;
        nextHandle += 1;
        expirationHandlers.set(handle, handleExpiration);
        return handle;
      },
      cancel: (handle) => {
        if (typeof handle === "number") {
          expirationHandlers.delete(handle);
        }
      },
    },
    activeCount: () => expirationHandlers.size,
    fireNext: () => {
      const entry = expirationHandlers.entries().next().value;
      if (entry === undefined) {
        throw new Error("No active timer is available");
      }
      const [handle, handleExpiration] = entry;
      expirationHandlers.delete(handle);
      handleExpiration();
    },
  };
}
