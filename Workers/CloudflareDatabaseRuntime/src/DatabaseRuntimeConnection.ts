import { databaseCompletionStatus } from "./DatabaseCompletionStatus";
import type { DatabaseAlarmScheduler } from "./DatabaseAlarmScheduler";
import { DatabaseAlarmScheduleError } from "./DatabaseAlarmScheduleError";
import { databaseAlarmTimestampMilliseconds } from "./DatabaseAlarmTimestamp";
import { DatabaseRuntimeInvocationError } from "./DatabaseRuntimeInvocationError";
import { DatabaseRuntimeFailureEncodingError } from "./DatabaseRuntimeFailureEncodingError";
import { DatabaseRuntimeFailurePayloadLimitError } from "./DatabaseRuntimeFailurePayloadLimitError";
import { DatabaseStorageResponseOwnershipError } from "./DatabaseStorageResponseOwnershipError";
import {
  databaseStorageResponseStateErrorReason,
  DatabaseStorageResponseStateError,
} from "./DatabaseStorageResponseStateError";
import { DatabaseInvocationTimeoutError } from "./DatabaseInvocationTimeoutError";
import type {
  DatabaseRuntimeEndpoints,
  DatabaseRuntimeInstantiator,
  DatabaseRuntimeProgram,
  DatabaseStorageDispatcher,
} from "./DatabaseRuntimeTypes";
import { DatabaseRuntimeConnectionLimits } from "./DatabaseRuntimeConnectionLimits";
import { DatabaseRuntimeConnectionShutdownError } from "./DatabaseRuntimeConnectionShutdownError";
import { DatabaseClockService } from "./DatabaseClockService";
import type { DatabaseClockWaiter } from "./DatabaseClockWaiter";
import { DatabaseTaskScheduler } from "./DatabaseTaskScheduler";
import type { DatabaseRuntimeFailureHandler } from "./DatabaseRuntimeFailureHandler";
import { DatabaseRuntimePayloadOwnership } from "./DatabaseRuntimePayloadOwnership";
import { WasiPreview1Host } from "./WasiPreview1Host";
import {
  requireDatabaseRuntimeEndpoints,
} from "./RequiredDatabaseRuntimeEndpoints";
import {
  databaseAuthorizationMaximumFrameBytes,
} from "./DatabaseAuthenticatedPrincipal";

type PendingInvocation = {
  purpose: DatabaseRuntimeCallPurpose;
  succeed(bytes: Uint8Array): void;
  fail(error: Error): void;
  timeoutHandle: unknown | null;
  completionReceived: boolean;
};

type DatabaseRuntimeCallPurpose =
  | "startup"
  | "request"
  | "scheduledWork"
  | "shutdown";

type RuntimeCompletion = {
  payload: Uint8Array | null;
  error: Error | null;
};

export type DatabaseInvocationTimer = {
  schedule(handleExpiration: () => void, delayMilliseconds: number): unknown;
  cancel(handle: unknown): void;
};

const databaseInvocationTimer: DatabaseInvocationTimer = {
  schedule: (handleExpiration, delayMilliseconds) =>
    setTimeout(handleExpiration, delayMilliseconds),
  cancel: (handle) =>
    clearTimeout(handle as ReturnType<typeof setTimeout>),
};

const knownCompletionStatuses = new Set<number>(
  Object.values(databaseCompletionStatus)
);
const terminalCompletionStatuses = new Set<number>([
  databaseCompletionStatus.invalidCallID,
  databaseCompletionStatus.invalidPayload,
  databaseCompletionStatus.notStarted,
  databaseCompletionStatus.alreadyStarted,
  databaseCompletionStatus.startupInProgress,
  databaseCompletionStatus.runtimeFailed,
]);
const maximumCallID = 0x7fff_ffff;
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export class DatabaseRuntimeConnection {
  private readonly storageDispatcher: DatabaseStorageDispatcher;
  private readonly alarmScheduler: DatabaseAlarmScheduler;
  private readonly limits: DatabaseRuntimeConnectionLimits;
  private readonly taskScheduler: DatabaseTaskScheduler;
  private readonly clockService: DatabaseClockService;
  private readonly payloadOwnership: DatabaseRuntimePayloadOwnership;
  private readonly timer: DatabaseInvocationTimer;
  private readonly handleRuntimeFailure: DatabaseRuntimeFailureHandler;
  private readonly pendingInvocations = new Map<number, PendingInvocation>();

  private runtimeInstance: import("./DatabaseRuntimeInstance").DatabaseRuntimeInstance | null = null;
  private nextCallID = 1;
  private terminalError: Error | null = null;
  private shutdownPromise: Promise<void> | null = null;
  private alarmScheduleTail: Promise<void> = Promise.resolve();
  private pendingStorageResponse: Uint8Array | null = null;

  static async instantiate(
    runtimeProgram: DatabaseRuntimeProgram,
    storageDispatcher: DatabaseStorageDispatcher,
    alarmScheduler: DatabaseAlarmScheduler,
    instantiateRuntime: DatabaseRuntimeInstantiator,
    limits: DatabaseRuntimeConnectionLimits,
    handleRuntimeFailure: DatabaseRuntimeFailureHandler,
    timer: DatabaseInvocationTimer = databaseInvocationTimer,
    clockWaiter?: DatabaseClockWaiter
  ): Promise<DatabaseRuntimeConnection> {
    const connection = new DatabaseRuntimeConnection(
      storageDispatcher,
      alarmScheduler,
      limits,
      handleRuntimeFailure,
      timer,
      clockWaiter
    );
    const wasiAdapter = new WasiPreview1Host({
      maximumIovecCount: limits.maximumWasiIovecCount,
      maximumIovecBytes: limits.maximumWasiIovecBytes,
    });
    try {
      const runtimeInstance = await instantiateRuntime({
        program: runtimeProgram,
        wasi: wasiAdapter,
        registerRuntimeServices: (runtimeServices) => {
          runtimeServices.storage_host = {
            dispatch: (payloadAddress: number, byteCount: number) =>
              connection.dispatchStorageRequest(payloadAddress, byteCount),
            receive: (payloadAddress: number, byteCount: number) =>
              connection.receiveStorageResponse(payloadAddress, byteCount),
            discard: () => connection.discardStorageResponse(),
          };
          runtimeServices.database_host = {
            complete: (
              callID: number,
              status: number,
              payloadAddress: number,
              byteCount: number
            ) => connection.receiveCompletion(
              callID,
              status,
              payloadAddress,
              byteCount
            ),
          };
          runtimeServices.database_executor = {
            schedule: (taskID: number, delayMilliseconds: number) =>
              connection.taskScheduler.schedule(taskID, delayMilliseconds),
          };
          runtimeServices.database_clock = {
            monotonic_nanoseconds: () =>
              BigInt(Math.floor(performance.now() * 1_000_000)),
            wall_time_milliseconds: () => BigInt(Date.now()),
            schedule: (waitID: number, delayMilliseconds: number) =>
              connection.clockService.schedule(
                normalizedClockWaitID(waitID),
                delayMilliseconds
              ),
            cancel: (waitID: number) =>
              connection.clockService.cancel(normalizedClockWaitID(waitID)),
          };
          runtimeServices.database_random = {
            random_u64: () => randomUInt64(),
          };
          runtimeServices.database_alarm = {
            schedule: (
              secondsSinceUnixEpoch: bigint,
              nanoseconds: number
            ) => connection.scheduleAlarm(
              secondsSinceUnixEpoch,
              nanoseconds
            ),
          };
        },
      });
      connection.runtimeInstance = runtimeInstance;
      wasiAdapter.attachRuntime(runtimeInstance);
      connection.payloadOwnership.assertAddressSpaceLimit(
        connection.runtimeEndpoints().addressSpace
      );
      wasiAdapter.initializeRuntime();
      connection.payloadOwnership.assertAddressSpaceLimit(
        connection.runtimeEndpoints().addressSpace
      );
      await connection.start();
      return connection;
    } catch (error) {
      const initializationError = asError(error);
      connection.discardFailedInitialization(initializationError);
      throw initializationError;
    }
  }

  constructor(
    storageDispatcher: DatabaseStorageDispatcher,
    alarmScheduler: DatabaseAlarmScheduler,
    limits: DatabaseRuntimeConnectionLimits,
    handleRuntimeFailure: DatabaseRuntimeFailureHandler,
    timer: DatabaseInvocationTimer = databaseInvocationTimer,
    clockWaiter?: DatabaseClockWaiter
  ) {
    this.storageDispatcher = storageDispatcher;
    this.alarmScheduler = alarmScheduler;
    this.limits = limits;
    this.handleRuntimeFailure = handleRuntimeFailure;
    this.timer = timer;
    this.taskScheduler = new DatabaseTaskScheduler(
      () => this.runtimeEndpoints(),
      (error) => this.enterTerminal(error),
      limits.maximumScheduledTasks
    );
    this.clockService = new DatabaseClockService(
      () => this.runtimeEndpoints(),
      (error) => this.enterTerminal(error),
      limits.maximumScheduledClockWaits,
      clockWaiter
    );
    this.payloadOwnership = new DatabaseRuntimePayloadOwnership(
      () => this.runtimeEndpoints(),
      {
        maximumPayloadCount: limits.maximumPayloadCountPerInvocationSet,
        maximumPayloadBytes: limits.maximumPayloadBytesPerInvocationSet,
        maximumRuntimeAddressSpaceBytes: limits.maximumRuntimeAddressSpaceBytes,
      }
    );
  }

  async execute(
    requestBytes: Uint8Array,
    authorizationBytes: Uint8Array
  ): Promise<Uint8Array> {
    const runtimeEndpoints = this.runtimeEndpoints();
    if (requestBytes.byteLength > this.limits.maximumRequestBytes) {
      throw new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.requestTooLarge,
        "DatabaseWire request exceeds the runtime connection limit"
      );
    }
    if (!(authorizationBytes instanceof Uint8Array)
        || authorizationBytes.byteLength === 0
        || authorizationBytes.byteLength > databaseAuthorizationMaximumFrameBytes) {
      throw new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.invalidPayload,
        "Database authorization frame is invalid"
      );
    }
    return this.performInvocation("request", (callID) => {
      const authorizationAddress = this.payloadOwnership.reservePayload(
        authorizationBytes.byteLength
      );
      if (authorizationAddress === 0) {
        throw new DatabaseRuntimeInvocationError(
          databaseCompletionStatus.runtimeFailed,
          "Database runtime returned a zero authorization payload address"
        );
      }
      let authorizationTransferred = false;
      let requestAddress = 0;
      let requestTransferred = false;
      try {
        this.storeInvocationRequest(authorizationAddress, authorizationBytes);
        requestAddress = this.payloadOwnership.reservePayload(
        requestBytes.byteLength
        );
        if (requestBytes.byteLength > 0 && requestAddress === 0) {
          throw new DatabaseRuntimeInvocationError(
            databaseCompletionStatus.runtimeFailed,
            "Database runtime returned a zero request payload address"
          );
        }
        this.storeInvocationRequest(requestAddress, requestBytes);
        this.payloadOwnership.transferPayloadToRuntime(
          authorizationAddress,
          authorizationBytes.byteLength
        );
        authorizationTransferred = true;
        this.payloadOwnership.transferPayloadToRuntime(
          requestAddress,
          requestBytes.byteLength
        );
        requestTransferred = true;
        runtimeEndpoints.invoke(
          callID,
          authorizationAddress,
          authorizationBytes.byteLength,
          requestAddress,
          requestBytes.byteLength
        );
      } catch (error) {
        if (!requestTransferred && requestAddress !== 0) {
          this.payloadOwnership.releaseConnectionPayload(
            requestAddress,
            requestBytes.byteLength
          );
        }
        if (!authorizationTransferred) {
          this.payloadOwnership.releaseConnectionPayload(
            authorizationAddress,
            authorizationBytes.byteLength
          );
        }
        throw error;
      }
    });
  }

  async alarm(): Promise<void> {
    const runtimeEndpoints = this.runtimeEndpoints();
    const payload = await this.performInvocation("scheduledWork", (callID) => {
      runtimeEndpoints.alarm(callID);
    });
    if (payload.byteLength !== 0) {
      const error = new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.runtimeFailed,
        "Database alarm execution returned an unexpected payload"
      );
      this.enterTerminal(error);
      throw error;
    }
  }

  get scheduledClockWaitCount(): number {
    return this.clockService.scheduledWaitCount;
  }

  get runtimeAddressSpaceByteCount(): number {
    return this.runtimeEndpoints().addressSpace.buffer.byteLength;
  }

  shutdown(): Promise<void> {
    if (this.shutdownPromise !== null) {
      return this.shutdownPromise;
    }
    if (this.terminalError !== null) {
      return Promise.reject(this.terminalError);
    }
    const shutdownPromise = this.performShutdown();
    this.shutdownPromise = shutdownPromise;
    return shutdownPromise;
  }

  private async performShutdown(): Promise<void> {
    const runtimeEndpoints = this.runtimeEndpoints();
    const payload = await this.performInvocation("shutdown", (callID) => {
      runtimeEndpoints.shutdown(callID);
    });
    if (payload.byteLength !== 0) {
      const error = new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.runtimeFailed,
        "Database runtime shutdown returned an unexpected payload"
      );
      this.enterTerminal(error);
      throw error;
    }
    const shutdownError = new DatabaseRuntimeConnectionShutdownError();
    this.terminalError = shutdownError;
    this.taskScheduler.shutdown();
    this.clockService.shutdown();
    this.pendingStorageResponse = null;
    this.payloadOwnership.discardRuntimeGeneration();
    this.rejectAllPendingInvocations(shutdownError);
  }

  private async start(): Promise<void> {
    const runtimeEndpoints = this.runtimeEndpoints();
    const payload = await this.performInvocation("startup", (callID) => {
      runtimeEndpoints.start(callID);
    });
    if (payload.byteLength !== 0) {
      const error = new DatabaseRuntimeInvocationError(
        databaseCompletionStatus.startupFailed,
        "Database runtime startup returned an unexpected payload"
      );
      this.enterTerminal(error);
      throw error;
    }
  }

  private performInvocation(
    purpose: DatabaseRuntimeCallPurpose,
    invoke: (callID: number) => void
  ): Promise<Uint8Array> {
    if (this.terminalError !== null) {
      return Promise.reject(this.terminalError);
    }
    if (this.pendingInvocations.size >= this.limits.maximumPendingInvocations) {
      return Promise.reject(
        new DatabaseRuntimeInvocationError(
          databaseCompletionStatus.queueCapacityExceeded,
          "Database runtime call registry is full"
        )
      );
    }
    if (this.pendingInvocations.size === 0) {
      try {
        this.payloadOwnership.beginInvocationSet();
      } catch (error) {
        const terminalError = asError(error);
        this.enterTerminal(terminalError);
        return Promise.reject(terminalError);
      }
    }
    let callID: number;
    try {
      callID = this.reserveCallID();
    } catch (error) {
      try {
        this.finishInvocationSetIfIdle();
      } catch (finishError) {
        const terminalError = asError(finishError);
        this.enterTerminal(terminalError);
        return Promise.reject(terminalError);
      }
      return Promise.reject(asError(error));
    }
    return new Promise<Uint8Array>((resolve, reject) => {
      const pendingInvocation: PendingInvocation = {
        purpose,
        succeed: resolve,
        fail: reject,
        timeoutHandle: null,
        completionReceived: false,
      };
      this.pendingInvocations.set(callID, pendingInvocation);

      let timeoutHandle: unknown;
      try {
        timeoutHandle = this.timer.schedule(
          () => this.expireInvocation(callID),
          this.limits.invocationTimeoutMilliseconds
        );
      } catch (error) {
        this.pendingInvocations.delete(callID);
        const timerError = asError(error);
        try {
          this.finishInvocationSetIfIdle();
        } catch (finishError) {
          const terminalError = asError(finishError);
          this.enterTerminal(terminalError);
          pendingInvocation.fail(terminalError);
          return;
        }
        pendingInvocation.fail(timerError);
        return;
      }
      if (this.pendingInvocations.get(callID) !== pendingInvocation) {
        this.cancelInvocationTimeout(timeoutHandle);
        return;
      }
      pendingInvocation.timeoutHandle = timeoutHandle;
      try {
        invoke(callID);
      } catch (error) {
        this.enterTerminal(asError(error));
      }
    });
  }

  private expireInvocation(callID: number): void {
    const pendingInvocation = this.pendingInvocations.get(callID);
    if (pendingInvocation === undefined) {
      return;
    }
    const timeoutError = new DatabaseInvocationTimeoutError(
      this.limits.invocationTimeoutMilliseconds
    );
    this.enterTerminal(timeoutError);
  }

  private rejectAllPendingInvocations(error: Error): void {
    const pendingInvocations = [...this.pendingInvocations.values()];
    this.pendingInvocations.clear();
    for (const pendingInvocation of pendingInvocations) {
      this.cancelInvocationTimeout(pendingInvocation.timeoutHandle);
      pendingInvocation.fail(error);
    }
  }

  private receiveCompletion(
    callID: number,
    status: number,
    payloadAddress: number,
    byteCount: number
  ): void {
    if (this.terminalError !== null) {
      return;
    }
    const pendingInvocation = this.pendingInvocations.get(callID);
    if (pendingInvocation === undefined) {
      this.enterTerminal(
        new Error(`Database runtime completed unknown call ID ${callID}`)
      );
      return;
    }
    if (pendingInvocation.completionReceived) {
      this.enterTerminal(
        new Error(`Database runtime completed call ID ${callID} more than once`)
      );
      return;
    }
    if (!Number.isInteger(status) || !knownCompletionStatuses.has(status)) {
      this.enterTerminal(
        new Error(`Database runtime returned unknown completion status ${status}`)
      );
      return;
    }
    if (status === databaseCompletionStatus.scheduledWorkFailed
        && pendingInvocation.purpose !== "scheduledWork") {
      this.enterTerminal(
        new Error(
          "Database runtime returned a scheduled-work failure for a "
            + `${pendingInvocation.purpose} call`
        )
      );
      return;
    }
    if (!Number.isInteger(byteCount) || byteCount < 0) {
      this.enterTerminal(
        new RangeError("Database completion length is invalid")
      );
      return;
    }
    pendingInvocation.completionReceived = true;

    let completion: RuntimeCompletion;
    if (status !== databaseCompletionStatus.success
        && byteCount > this.limits.maximumFailureBytes) {
      this.enterTerminal(
        new DatabaseRuntimeFailurePayloadLimitError(
          this.limits.maximumFailureBytes,
          byteCount
        )
      );
      return;
    }
    if (status === databaseCompletionStatus.success
        && byteCount > this.limits.maximumResponseBytes) {
      completion = {
        payload: null,
        error: new DatabaseRuntimeInvocationError(
          databaseCompletionStatus.responseTooLarge,
          "DatabaseWire response exceeds the runtime connection limit"
        ),
      };
    } else {
      try {
        const borrowedCompletionBytes = this.payloadOwnership.borrowBytes(
          payloadAddress,
          byteCount
        );
        if (status === databaseCompletionStatus.success) {
          // The runtime lends this range only until the synchronous import
          // returns. WebAssembly.Memory cannot transfer ownership to
          // JavaScript, so this is the single required completion copy.
          completion = { payload: borrowedCompletionBytes.slice(), error: null };
        } else {
          const failureMessage = decodeFailureMessage(borrowedCompletionBytes);
          const invocationError = new DatabaseRuntimeInvocationError(
            status,
            failureMessage.length === 0
              ? `Database runtime failed without an error payload (length ${byteCount})`
              : failureMessage
          );
          if (terminalCompletionStatuses.has(status)) {
            this.enterTerminal(invocationError);
            return;
          }
          completion = {
            payload: null,
            error: invocationError,
          };
        }
      } catch (error) {
        this.enterTerminal(asError(error));
        return;
      }
    }

    void this.alarmScheduleTail.then(
      () => this.finishInvocation(callID, completion),
      (error: unknown) => this.enterTerminal(this.alarmError(error))
    );
  }

  private finishInvocation(
    callID: number,
    completion: RuntimeCompletion
  ): void {
    const pendingInvocation = this.pendingInvocations.get(callID);
    if (pendingInvocation === undefined) {
      return;
    }
    this.pendingInvocations.delete(callID);
    this.cancelInvocationTimeout(pendingInvocation.timeoutHandle);
    try {
      this.finishInvocationSetIfIdle();
    } catch (error) {
      const terminalError = asError(error);
      this.enterTerminal(terminalError);
      pendingInvocation.fail(terminalError);
      return;
    }
    if (completion.error !== null) {
      pendingInvocation.fail(completion.error);
      return;
    }
    if (completion.payload === null) {
      pendingInvocation.fail(
        new Error("Database completion payload is unavailable")
      );
      return;
    }
    pendingInvocation.succeed(completion.payload);
  }

  private scheduleAlarm(
    secondsSinceUnixEpoch: bigint,
    nanoseconds: number
  ): void {
    if (this.terminalError !== null) {
      throw this.terminalError;
    }

    let timestampMilliseconds: number;
    try {
      timestampMilliseconds = databaseAlarmTimestampMilliseconds(
        secondsSinceUnixEpoch,
        nanoseconds
      );
    } catch (error) {
      const terminalError = this.alarmError(error);
      this.enterTerminal(terminalError);
      throw terminalError;
    }

    const operation = this.alarmScheduleTail.then(() =>
      this.alarmScheduler.ensureWakeUpNoLaterThan(timestampMilliseconds)
    );
    this.alarmScheduleTail = operation;
    void operation.catch((error: unknown) => {
      this.enterTerminal(this.alarmError(error));
    });
  }

  private alarmError(error: unknown): DatabaseAlarmScheduleError {
    if (error instanceof DatabaseAlarmScheduleError) {
      return error;
    }
    return new DatabaseAlarmScheduleError(asError(error));
  }

  private enterTerminal(error: Error): void {
    if (this.terminalError !== null) {
      return;
    }
    this.terminalError = error;
    this.taskScheduler.shutdown();
    this.clockService.shutdown();
    this.pendingStorageResponse = null;
    this.payloadOwnership.discardRuntimeGeneration();
    this.rejectAllPendingInvocations(error);
    this.handleRuntimeFailure(error.message);
  }

  private discardFailedInitialization(error: Error): void {
    if (this.terminalError !== null) {
      return;
    }
    this.terminalError = error;
    this.taskScheduler.shutdown();
    this.clockService.shutdown();
    this.pendingStorageResponse = null;
    this.payloadOwnership.discardRuntimeGeneration();
    this.rejectAllPendingInvocations(error);
  }

  private dispatchStorageRequest(
    payloadAddress: number,
    byteCount: number
  ): number {
    if (this.pendingStorageResponse !== null) {
      throw new DatabaseStorageResponseStateError({
        reason: databaseStorageResponseStateErrorReason.responseAlreadyPending,
      });
    }
    if (byteCount > this.limits.maximumStorageRequestBytes) {
      throw new RangeError(
        "Storage request exceeds the runtime connection limit"
      );
    }
    const requestBytes = this.payloadOwnership.borrowBytes(
      payloadAddress,
      byteCount
    );
    const responseBytes = this.storageDispatcher.dispatchBytes(requestBytes);
    if (responseBytes.buffer === requestBytes.buffer) {
      throw new DatabaseStorageResponseOwnershipError();
    }
    if (responseBytes.byteLength > this.limits.maximumStorageResponseBytes) {
      throw new RangeError(
        "Storage response exceeds the runtime connection limit"
      );
    }
    if (responseBytes.byteLength === 0) {
      throw new DatabaseStorageResponseStateError({
        reason: databaseStorageResponseStateErrorReason.emptyResponse,
      });
    }
    this.pendingStorageResponse = responseBytes;
    return responseBytes.byteLength;
  }

  private cancelInvocationTimeout(handle: unknown | null): void {
    if (handle === null) {
      return;
    }
    try {
      this.timer.cancel(handle);
    } catch {
      // The completed call is authoritative even if timer cancellation fails.
    }
  }

  private receiveStorageResponse(
    payloadAddress: number,
    byteCount: number
  ): void {
    const response = this.pendingStorageResponse;
    if (response === null) {
      throw new DatabaseStorageResponseStateError({
        reason: databaseStorageResponseStateErrorReason.responseUnavailable,
      });
    }
    if (byteCount !== response.byteLength) {
      throw new DatabaseStorageResponseStateError({
        reason: databaseStorageResponseStateErrorReason.responseLengthMismatch,
        expectedByteCount: response.byteLength,
        actualByteCount: byteCount,
      });
    }
    try {
      const destination = this.payloadOwnership.borrowBytes(
        payloadAddress,
        byteCount
      );
      if (destination.buffer === response.buffer) {
        throw new DatabaseStorageResponseOwnershipError();
      }
      destination.set(response);
    } finally {
      this.pendingStorageResponse = null;
    }
  }

  private discardStorageResponse(): void {
    if (this.pendingStorageResponse === null) {
      throw new DatabaseStorageResponseStateError({
        reason: databaseStorageResponseStateErrorReason.responseUnavailable,
      });
    }
    this.pendingStorageResponse = null;
  }

  private reserveCallID(): number {
    for (let attempt = 0; attempt < this.limits.maximumPendingInvocations + 1; attempt += 1) {
      const candidate = this.nextCallID;
      this.nextCallID = candidate === maximumCallID ? 1 : candidate + 1;
      if (!this.pendingInvocations.has(candidate)) {
        return candidate;
      }
    }
    throw new DatabaseRuntimeInvocationError(
      databaseCompletionStatus.queueCapacityExceeded,
      "Database runtime call ID space is exhausted"
    );
  }

  private storeInvocationRequest(
    payloadAddress: number,
    bytes: Uint8Array
  ): void {
    if (bytes.byteLength === 0) {
      return;
    }
    this.payloadOwnership.borrowBytes(
      payloadAddress,
      bytes.byteLength
    ).set(bytes);
  }

  private finishInvocationSetIfIdle(): void {
    if (this.pendingInvocations.size === 0) {
      if (this.pendingStorageResponse !== null) {
        throw new DatabaseStorageResponseStateError({
          reason: databaseStorageResponseStateErrorReason.responseAlreadyPending,
        });
      }
      this.payloadOwnership.finishInvocationSet();
    }
  }

  private runtimeEndpoints(): DatabaseRuntimeEndpoints {
    if (this.terminalError !== null) {
      throw this.terminalError;
    }
    if (this.runtimeInstance === null) {
      throw new Error("Database runtime connection is not initialized");
    }
    return requireDatabaseRuntimeEndpoints(this.runtimeInstance);
  }
}

function randomUInt64(): bigint {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return new DataView(bytes.buffer).getBigUint64(0, false);
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function decodeFailureMessage(bytes: Uint8Array): string {
  try {
    return utf8Decoder.decode(bytes);
  } catch {
    throw new DatabaseRuntimeFailureEncodingError();
  }
}

function normalizedClockWaitID(signedWaitID: number): number {
  if (!Number.isInteger(signedWaitID)
      || signedWaitID < -0x8000_0000
      || signedWaitID > 0xffff_ffff) {
    throw new RangeError("Clock wait ID is not a WebAssembly i32 value");
  }
  return signedWaitID >>> 0;
}
