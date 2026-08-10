import type { DatabaseRuntimeInstance } from "./DatabaseRuntimeInstance";
import type { DatabaseRuntimeEndpoints } from "./DatabaseRuntimeTypes";

export function requireDatabaseRuntimeEndpoints(
  runtimeInstance: DatabaseRuntimeInstance
): DatabaseRuntimeEndpoints {
  const unvalidatedEndpoints = runtimeInstance.endpoints;
  const reservePayloadEndpoint = unvalidatedEndpoints.database_alloc;
  const releasePayloadEndpoint = unvalidatedEndpoints.database_dealloc;
  const startEndpoint = unvalidatedEndpoints.database_start;
  const invokeEndpoint = unvalidatedEndpoints.database_invoke;
  const alarmEndpoint = unvalidatedEndpoints.database_alarm;
  const runScheduledTaskEndpoint = unvalidatedEndpoints.database_executor_run;
  const resumeClockWaitEndpoint = unvalidatedEndpoints.database_clock_resume;
  const addressSpace = unvalidatedEndpoints.memory;
  if (typeof reservePayloadEndpoint !== "function") {
    throw new Error("runtime instance does not export database_alloc");
  }
  if (typeof releasePayloadEndpoint !== "function") {
    throw new Error("runtime instance does not export database_dealloc");
  }
  if (typeof startEndpoint !== "function") {
    throw new Error("runtime instance does not export database_start");
  }
  if (typeof invokeEndpoint !== "function") {
    throw new Error("runtime instance does not export database_invoke");
  }
  if (typeof alarmEndpoint !== "function") {
    throw new Error("runtime instance does not export database_alarm");
  }
  if (typeof runScheduledTaskEndpoint !== "function") {
    throw new Error("runtime instance does not export database_executor_run");
  }
  if (typeof resumeClockWaitEndpoint !== "function") {
    throw new Error("runtime instance does not export database_clock_resume");
  }
  if (!(addressSpace instanceof WebAssembly.Memory)) {
    throw new Error("runtime instance does not export memory");
  }
  return {
    reservePayload: reservePayloadEndpoint as (byteCount: number) => number,
    releasePayload: releasePayloadEndpoint as (
      payloadAddress: number,
      byteCount: number
    ) => void,
    start: startEndpoint as (callID: number) => void,
    invoke: invokeEndpoint as (
      callID: number,
      authorizationAddress: number,
      authorizationByteCount: number,
      requestAddress: number,
      requestByteCount: number
    ) => void,
    alarm: alarmEndpoint as (callID: number) => void,
    runScheduledTask: runScheduledTaskEndpoint as (taskID: number) => void,
    resumeClockWait: resumeClockWaitEndpoint as (waitID: number) => void,
    addressSpace,
  };
}
