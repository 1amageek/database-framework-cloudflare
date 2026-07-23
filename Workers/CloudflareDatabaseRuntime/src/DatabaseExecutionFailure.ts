import { databaseCompletionStatus } from "./DatabaseCompletionStatus";
import { DatabaseExecutionInputError } from "./DatabaseExecutionInputError";
import { DatabaseInvocationTimeoutError } from "./DatabaseInvocationTimeoutError";
import { DatabaseRequestQueueCapacityError } from "./DatabaseRequestQueueCapacityError";
import { DatabaseRuntimeConnectionShutdownError } from "./DatabaseRuntimeConnectionShutdownError";
import { DatabaseRuntimeInvocationError } from "./DatabaseRuntimeInvocationError";

export const databaseExecutionFailureCode = Object.freeze({
  invalidRequest: "database.execution.invalid_request",
  requestTooLarge: "database.execution.request_too_large",
  capacityExhausted: "database.execution.capacity_exhausted",
  timedOut: "database.execution.timed_out",
  invalidResponse: "database.execution.invalid_response",
  runtimeUnavailable: "database.execution.runtime_unavailable",
  runtimeFailure: "database.execution.runtime_failure",
} as const);

export type DatabaseExecutionFailureCode =
  typeof databaseExecutionFailureCode[keyof typeof databaseExecutionFailureCode];

const knownFailureCodes = new Set<string>(
  Object.values(databaseExecutionFailureCode),
);

export function encodeDatabaseExecutionFailure(error: unknown): Error {
  return new Error(classifyDatabaseExecutionFailure(error));
}

export function decodeDatabaseExecutionFailure(
  error: unknown,
): DatabaseExecutionFailureCode | null {
  if (typeof error !== "object" || error === null) {
    return null;
  }
  const name = Reflect.get(error, "name");
  const message = Reflect.get(error, "message");
  return name === "Error"
    && typeof message === "string"
    && knownFailureCodes.has(message)
    ? message as DatabaseExecutionFailureCode
    : null;
}

function classifyDatabaseExecutionFailure(
  error: unknown,
): DatabaseExecutionFailureCode {
  if (error instanceof DatabaseRequestQueueCapacityError) {
    return databaseExecutionFailureCode.capacityExhausted;
  }
  if (error instanceof DatabaseExecutionInputError) {
    return databaseExecutionFailureCode.invalidRequest;
  }
  if (error instanceof DatabaseInvocationTimeoutError) {
    return databaseExecutionFailureCode.timedOut;
  }
  if (error instanceof DatabaseRuntimeConnectionShutdownError) {
    return databaseExecutionFailureCode.runtimeUnavailable;
  }
  if (error instanceof DatabaseRuntimeInvocationError) {
    switch (error.status) {
      case databaseCompletionStatus.invalidRequestFrame:
        return databaseExecutionFailureCode.invalidRequest;
      case databaseCompletionStatus.requestTooLarge:
        return databaseExecutionFailureCode.requestTooLarge;
      case databaseCompletionStatus.responseTooLarge:
        return databaseExecutionFailureCode.invalidResponse;
      case databaseCompletionStatus.queueCapacityExceeded:
        return databaseExecutionFailureCode.capacityExhausted;
      case databaseCompletionStatus.invalidCallID:
      case databaseCompletionStatus.invalidPayload:
      case databaseCompletionStatus.runtimeFailed:
      case databaseCompletionStatus.success:
        return databaseExecutionFailureCode.runtimeFailure;
      case databaseCompletionStatus.notStarted:
      case databaseCompletionStatus.alreadyStarted:
      case databaseCompletionStatus.startupInProgress:
      case databaseCompletionStatus.startupFailed:
      case databaseCompletionStatus.cancelled:
        return databaseExecutionFailureCode.runtimeUnavailable;
    }
  }
  return databaseExecutionFailureCode.runtimeUnavailable;
}
