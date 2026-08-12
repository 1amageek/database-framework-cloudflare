import type { DatabaseRuntimeInstance } from "../src/DatabaseRuntimeInstance";
import { databaseCompletionStatus } from "../src/DatabaseCompletionStatus";
import type {
  DatabaseRuntimeInstantiator,
  DatabaseRuntimeInstantiationOptions,
} from "../src/DatabaseRuntimeTypes";

export type ControllableDatabaseRuntimeBehavior =
  | { kind: "echo" }
  | { kind: "failure"; status: number; message: string }
  | { kind: "alarmFailureOnce"; status: number; message: string }
  | { kind: "startupFailure"; status: number; message: string }
  | { kind: "failureBytes"; status: number; bytes: number[] }
  | { kind: "storage" }
  | { kind: "storageRepeated"; dispatchCount: number }
  | { kind: "completionPayloadInvalidated" }
  | { kind: "alarmPayload"; bytes: number[] }
  | {
      kind: "scheduleAlarm";
      secondsSinceUnixEpoch: bigint;
      nanoseconds: number;
    }
  | { kind: "oversizedCompletion"; length: number }
  | { kind: "oversizedCompletionOnceThenEcho"; length: number }
  | { kind: "hangOnceThenEcho" }
  | { kind: "scheduledTaskBurst"; taskCount: number }
  | { kind: "startupFailureWithPendingServices"; message: string }
  | { kind: "invalidRequestPayloadAddress" }
  | { kind: "zeroRequestPayloadAddress" }
  | { kind: "storageResponseLengthMismatch" }
  | {
      kind: "commandFailure";
      runtimeCommand: "start" | "invoke" | "alarm" | "scheduledTask";
      message: string;
    }
  | {
      kind: "invalidCompletion";
      violation:
        | "unknownCallID"
        | "duplicateCallID"
        | "unknownStatus"
        | "invalidPayloadAddress"
        | "invalidPayloadByteCount";
    };

export type DatabaseRuntimeLifecycleObserver = {
  didCreateRuntimeAddressSpace?(runtimeAddressSpace: WebAssembly.Memory): void;
  didReleasePayload?(payloadAddress: number, byteCount: number): void;
  didInvoke?(payloadAddress: number, byteCount: number): void;
  didRegisterRuntimeServices?(runtimeServices: WebAssembly.Imports): void;
  didResumeClockWait?(waitID: number): void;
  didRunScheduledTask?(taskID: number): void;
  didShutdown?(): void;
};

export function controllableDatabaseRuntimeInstantiator(
  behavior: ControllableDatabaseRuntimeBehavior = { kind: "echo" },
  lifecycleObserver: DatabaseRuntimeLifecycleObserver = {}
): DatabaseRuntimeInstantiator {
  return async (
    options: DatabaseRuntimeInstantiationOptions
  ): Promise<DatabaseRuntimeInstance> => {
    const runtimeAddressSpace = new WebAssembly.Memory({ initial: 2 });
    lifecycleObserver.didCreateRuntimeAddressSpace?.(runtimeAddressSpace);
    let nextPayloadAddress = 1024;
    let runtimeInstance: DatabaseRuntimeInstance;
    let nextTaskID = 1;
    let invocationCount = 0;
    let alarmInvocationCount = 0;
    let invocationPayloadReservationCount = 0;
    const scheduledTasks = new Map<number, () => void>();
    const runtimeServices: WebAssembly.Imports = {};

    const enqueueTask = (scheduledTask: () => void): void => {
      const taskID = nextTaskID;
      nextTaskID += 1;
      scheduledTasks.set(taskID, scheduledTask);
      scheduleTask(runtimeServices, taskID, 0);
    };

    const reservePayload = (byteCount: number): number => {
      if (!Number.isInteger(byteCount) || byteCount < 0) {
        throw new RangeError("Controllable runtime payload length is invalid");
      }
      if (byteCount === 0) {
        return 0;
      }
      const payloadAddress = nextPayloadAddress;
      nextPayloadAddress += byteCount;
      if (nextPayloadAddress > runtimeAddressSpace.buffer.byteLength) {
        throw new RangeError("Controllable runtime address space is exhausted");
      }
      return payloadAddress;
    };

    const borrowRuntimeBytes = (
      payloadAddress: number,
      byteCount: number
    ): Uint8Array => {
      if (!Number.isInteger(payloadAddress)
          || !Number.isInteger(byteCount)
          || payloadAddress < 0
          || byteCount < 0
          || payloadAddress + byteCount > runtimeAddressSpace.buffer.byteLength) {
        throw new RangeError("Controllable runtime address-space range is invalid");
      }
      return new Uint8Array(runtimeAddressSpace.buffer, payloadAddress, byteCount);
    };

    const storeRuntimePayload = (bytes: Uint8Array): number => {
      const payloadAddress = reservePayload(bytes.byteLength);
      borrowRuntimeBytes(payloadAddress, bytes.byteLength).set(bytes);
      return payloadAddress;
    };

    const deliverCompletionBytes = (
      callID: number,
      status: number,
      bytes: Uint8Array
    ): void => {
      const payloadAddress = storeRuntimePayload(bytes);
      deliverRuntimeCompletion(
        runtimeServices,
        callID,
        status,
        payloadAddress,
        bytes.byteLength
      );
    };

    const runtimeEndpoints: WebAssembly.Exports = {
      memory: runtimeAddressSpace,
      database_alloc: (byteCount: number) => {
        if (byteCount > 0) {
          invocationPayloadReservationCount += 1;
        }
        if (behavior.kind === "zeroRequestPayloadAddress"
            && byteCount > 0
            && invocationPayloadReservationCount === 2) {
          return 0;
        }
        if (behavior.kind === "invalidRequestPayloadAddress"
            && byteCount > 0
            && invocationPayloadReservationCount === 2) {
          return runtimeAddressSpace.buffer.byteLength;
        }
        return reservePayload(byteCount);
      },
      database_dealloc: (payloadAddress: number, byteCount: number) => {
        lifecycleObserver.didReleasePayload?.(payloadAddress, byteCount);
        if (behavior.kind === "invalidRequestPayloadAddress") {
          return;
        }
        borrowRuntimeBytes(payloadAddress, byteCount).fill(0xa5);
      },
      database_start: (callID: number) => {
        if (behavior.kind === "commandFailure"
            && behavior.runtimeCommand === "start") {
          throw new Error(behavior.message);
        }
        if (behavior.kind === "startupFailureWithPendingServices") {
          const taskID = nextTaskID;
          nextTaskID += 1;
          scheduledTasks.set(taskID, () => undefined);
          scheduleTask(runtimeServices, taskID, 10);
          scheduleClockWait(runtimeServices, 1, 60_000);
          deliverCompletionBytes(
            callID,
            databaseCompletionStatus.startupFailed,
            new TextEncoder().encode(behavior.message)
          );
          return;
        }
        if (behavior.kind === "startupFailure") {
          enqueueTask(() => deliverCompletionBytes(
            callID,
            behavior.status,
            new TextEncoder().encode(behavior.message)
          ));
          return;
        }
        enqueueTask(() => deliverRuntimeCompletion(runtimeServices, callID, 0, 0, 0));
      },
      database_invoke: (
        callID: number,
        authorizationAddress: number,
        authorizationByteCount: number,
        payloadAddress: number,
        byteCount: number
      ) => {
        invocationPayloadReservationCount = 0;
        borrowRuntimeBytes(
          authorizationAddress,
          authorizationByteCount
        );
        lifecycleObserver.didInvoke?.(payloadAddress, byteCount);
        if (behavior.kind === "commandFailure"
            && behavior.runtimeCommand === "invoke") {
          throw new Error(behavior.message);
        }
        const requestBytes = borrowRuntimeBytes(
          payloadAddress,
          byteCount
        ).slice();
        invocationCount += 1;
        if (behavior.kind === "hangOnceThenEcho" && invocationCount === 1) {
          return;
        }
        if (behavior.kind === "scheduledTaskBurst") {
          for (let index = 0; index < behavior.taskCount; index += 1) {
            enqueueTask(() => deliverCompletionBytes(callID, 0, requestBytes));
          }
          return;
        }
        enqueueTask(() => {
          switch (behavior.kind) {
          case "echo":
          case "alarmFailureOnce":
          case "hangOnceThenEcho":
          case "startupFailureWithPendingServices":
          case "startupFailure":
          case "invalidRequestPayloadAddress":
          case "zeroRequestPayloadAddress":
            deliverCompletionBytes(callID, 0, requestBytes);
            return;
          case "completionPayloadInvalidated": {
            const responsePayloadAddress = storeRuntimePayload(requestBytes);
            deliverRuntimeCompletion(
              runtimeServices,
              callID,
              0,
              responsePayloadAddress,
              requestBytes.byteLength
            );
            borrowRuntimeBytes(
              responsePayloadAddress,
              requestBytes.byteLength
            ).fill(0xa5);
            return;
          }
          case "failure": {
            const bytes = new TextEncoder().encode(behavior.message);
            deliverCompletionBytes(callID, behavior.status, bytes);
            return;
          }
          case "failureBytes":
            deliverCompletionBytes(
              callID,
              behavior.status,
              new Uint8Array(behavior.bytes)
            );
            return;
          case "storage":
          case "storageRepeated":
          case "storageResponseLengthMismatch": {
            const dispatchCount = behavior.kind === "storageRepeated"
              ? behavior.dispatchCount
              : 1;
            let responseAddress = 0;
            let responseByteCount = 0;
            for (let index = 0; index < dispatchCount; index += 1) {
              const requestPayloadAddress = storeRuntimePayload(requestBytes);
              responseByteCount = dispatchStorageRequest(
                runtimeServices,
                requestPayloadAddress,
                requestBytes.byteLength
              );
              responseAddress = reservePayload(responseByteCount);
              receiveStorageResponse(
                runtimeServices,
                responseAddress,
                behavior.kind === "storageResponseLengthMismatch"
                  ? responseByteCount + 1
                  : responseByteCount
              );
            }
            deliverRuntimeCompletion(
              runtimeServices,
              callID,
              0,
              responseAddress,
              responseByteCount
            );
            return;
          }
          case "scheduleAlarm":
            scheduleAlarm(
              runtimeServices,
              behavior.secondsSinceUnixEpoch,
              behavior.nanoseconds
            );
            deliverCompletionBytes(callID, 0, requestBytes);
            return;
          case "oversizedCompletion":
            deliverRuntimeCompletion(
              runtimeServices,
              callID,
              0,
              runtimeAddressSpace.buffer.byteLength,
              behavior.length
            );
            return;
          case "oversizedCompletionOnceThenEcho":
            if (invocationCount === 1) {
              deliverRuntimeCompletion(
                runtimeServices,
                callID,
                0,
                runtimeAddressSpace.buffer.byteLength,
                behavior.length
              );
              return;
            }
            deliverCompletionBytes(callID, 0, requestBytes);
            return;
          case "commandFailure":
            if (behavior.runtimeCommand === "scheduledTask") {
              throw new Error(behavior.message);
            }
            deliverCompletionBytes(callID, 0, requestBytes);
            return;
          case "invalidCompletion":
            switch (behavior.violation) {
            case "unknownCallID":
              deliverRuntimeCompletion(runtimeServices, 0xffff_ffff, 0, 0, 0);
              return;
            case "duplicateCallID":
              deliverCompletionBytes(callID, 0, requestBytes);
              deliverCompletionBytes(callID, 0, requestBytes);
              return;
            case "unknownStatus":
              deliverRuntimeCompletion(runtimeServices, callID, 0xffff_ffff, 0, 0);
              return;
            case "invalidPayloadAddress":
              deliverRuntimeCompletion(
                runtimeServices,
                callID,
                0,
                runtimeAddressSpace.buffer.byteLength + 1,
                0
              );
              return;
            case "invalidPayloadByteCount":
              deliverRuntimeCompletion(runtimeServices, callID, 0, 0, -1);
              return;
            }
          }
        });
      },
      database_alarm: (callID: number) => {
        if (behavior.kind === "commandFailure"
            && behavior.runtimeCommand === "alarm") {
          throw new Error(behavior.message);
        }
        alarmInvocationCount += 1;
        enqueueTask(() => {
          if (behavior.kind === "alarmFailureOnce"
              && alarmInvocationCount === 1) {
            deliverCompletionBytes(
              callID,
              behavior.status,
              new TextEncoder().encode(behavior.message)
            );
            return;
          }
          if (behavior.kind === "alarmPayload") {
            deliverCompletionBytes(
              callID,
              0,
              new Uint8Array(behavior.bytes)
            );
            return;
          }
          if (behavior.kind !== "failure"
              && behavior.kind !== "failureBytes") {
            deliverRuntimeCompletion(runtimeServices, callID, 0, 0, 0);
            return;
          }
          const bytes = behavior.kind === "failure"
            ? new TextEncoder().encode(behavior.message)
            : new Uint8Array(behavior.bytes);
          deliverCompletionBytes(callID, behavior.status, bytes);
        });
      },
      database_shutdown: (callID: number) => {
        lifecycleObserver.didShutdown?.();
        enqueueTask(() => {
          deliverRuntimeCompletion(runtimeServices, callID, 0, 0, 0);
        });
      },
      database_executor_run: (taskID: number) => {
        lifecycleObserver.didRunScheduledTask?.(taskID);
        const scheduledTask = scheduledTasks.get(taskID);
        if (scheduledTask === undefined) {
          return;
        }
        scheduledTasks.delete(taskID);
        scheduledTask();
      },
      database_clock_resume: (waitID: number) => {
        lifecycleObserver.didResumeClockWait?.(waitID);
      },
    };
    runtimeInstance = { endpoints: runtimeEndpoints };
    options.registerRuntimeServices(runtimeServices);
    lifecycleObserver.didRegisterRuntimeServices?.(runtimeServices);
    return runtimeInstance;
  };
}

function scheduleAlarm(
  runtimeServices: WebAssembly.Imports,
  secondsSinceUnixEpoch: bigint,
  nanoseconds: number
): void {
  const schedule = runtimeServices.database_alarm?.schedule;
  if (typeof schedule !== "function") {
    throw new Error("database_alarm.schedule is not installed");
  }
  schedule(secondsSinceUnixEpoch, nanoseconds);
}

function scheduleTask(
  runtimeServices: WebAssembly.Imports,
  taskID: number,
  delayMilliseconds: number
): void {
  const schedule = runtimeServices.database_executor?.schedule;
  if (typeof schedule !== "function") {
    throw new Error("database_executor.schedule is not installed");
  }
  schedule(taskID, delayMilliseconds);
}

function scheduleClockWait(
  runtimeServices: WebAssembly.Imports,
  waitID: number,
  delayMilliseconds: number
): void {
  const schedule = runtimeServices.database_clock?.schedule;
  if (typeof schedule !== "function") {
    throw new Error("database_clock.schedule is not installed");
  }
  schedule(waitID, delayMilliseconds);
}

function deliverRuntimeCompletion(
  runtimeServices: WebAssembly.Imports,
  callID: number,
  status: number,
  payloadAddress: number,
  byteCount: number
): void {
  const receiveCompletion = runtimeServices.database_host?.complete;
  if (typeof receiveCompletion !== "function") {
    throw new Error("database_host.complete is not installed");
  }
  receiveCompletion(callID, status, payloadAddress, byteCount);
}

function dispatchStorageRequest(
  runtimeServices: WebAssembly.Imports,
  payloadAddress: number,
  byteCount: number
): number {
  const dispatch = runtimeServices.storage_host?.dispatch;
  if (typeof dispatch !== "function") {
    throw new Error("storage_host.dispatch is not installed");
  }
  return Number(dispatch(payloadAddress, byteCount));
}

function receiveStorageResponse(
  runtimeServices: WebAssembly.Imports,
  payloadAddress: number,
  byteCount: number
): void {
  const receive = runtimeServices.storage_host?.receive;
  if (typeof receive !== "function") {
    throw new Error("storage_host.receive is not installed");
  }
  receive(payloadAddress, byteCount);
}
