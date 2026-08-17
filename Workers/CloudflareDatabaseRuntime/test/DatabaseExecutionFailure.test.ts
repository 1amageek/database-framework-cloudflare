import assert from "node:assert/strict";
import test from "node:test";
import { databaseCompletionStatus } from "../src/DatabaseCompletionStatus";
import {
  databaseExecutionFailureCode,
  decodeDatabaseExecutionFailure,
  encodeDatabaseExecutionFailure,
} from "../src/DatabaseExecutionFailure";
import { DatabaseExecutionInputError } from "../src/DatabaseExecutionInputError";
import { DatabaseInvocationTimeoutError } from "../src/DatabaseInvocationTimeoutError";
import { DatabaseInvocationCapacityError } from "../src/DatabaseInvocationCapacityError";
import { DatabaseRuntimeInvocationError } from "../src/DatabaseRuntimeInvocationError";

test("database execution failures have a stable remote message contract", () => {
  const cases: [unknown, string][] = [
    [
      new DatabaseExecutionInputError("private input detail"),
      databaseExecutionFailureCode.invalidRequest,
    ],
    [
      new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.applicationFailed,
        "private decoder detail",
      ),
      databaseExecutionFailureCode.runtimeFailure,
    ],
    [
      new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.requestTooLarge,
        "private request detail",
      ),
      databaseExecutionFailureCode.requestTooLarge,
    ],
    [
      new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.responseTooLarge,
        "private response detail",
      ),
      databaseExecutionFailureCode.invalidResponse,
    ],
    [
      new DatabaseInvocationCapacityError({
        reason: "pendingInvocations",
        limit: 1,
        pending: 1,
        requested: 1,
      }),
      databaseExecutionFailureCode.capacityExhausted,
    ],
    [
      new DatabaseInvocationTimeoutError(30_000),
      databaseExecutionFailureCode.timedOut,
    ],
    [
      new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.cancelled,
        "private cancellation detail",
      ),
      databaseExecutionFailureCode.cancelled,
    ],
    [new Error("private runtime detail"), databaseExecutionFailureCode.runtimeUnavailable],
  ];

  for (const [source, expectedCode] of cases) {
    const encoded = encodeDatabaseExecutionFailure(source);
    assert.equal(encoded.message, expectedCode);
    assert.equal(decodeDatabaseExecutionFailure(encoded), expectedCode);
    assert.equal(encoded.message.includes("private"), false);
  }
});

test("database execution failure decoding rejects non-protocol errors", () => {
  assert.equal(decodeDatabaseExecutionFailure(new Error("unrelated")), null);
  assert.equal(decodeDatabaseExecutionFailure({
    name: "TypeError",
    message: databaseExecutionFailureCode.invalidRequest,
  }), null);
  assert.equal(decodeDatabaseExecutionFailure({ message: 42 }), null);
  assert.equal(decodeDatabaseExecutionFailure(null), null);
});
