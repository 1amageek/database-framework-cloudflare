import type { DatabaseRuntimeInstance } from "./DatabaseRuntimeInstance";
import type { WasiPreview1Host } from "./WasiPreview1Host";

export type DatabaseRuntimeEndpoints = {
  reservePayload(byteCount: number): number;
  releasePayload(payloadAddress: number, byteCount: number): void;
  start(callID: number): void;
  invoke(
    callID: number,
    authorizationAddress: number,
    authorizationByteCount: number,
    requestAddress: number,
    requestByteCount: number
  ): void;
  alarm(callID: number): void;
  shutdown(callID: number): void;
  runScheduledTask(taskID: number): void;
  resumeClockWait(waitID: number): void;
  addressSpace: WebAssembly.Memory;
};

export type DatabaseRuntimeProgram = WebAssembly.Module;

export type DatabaseRuntimeInstantiationOptions = {
  program: DatabaseRuntimeProgram;
  wasi: WasiPreview1Host;
  registerRuntimeServices(
    services: WebAssembly.Imports
  ): void;
};

export type DatabaseRuntimeInstantiator = (
  options: DatabaseRuntimeInstantiationOptions
) => Promise<DatabaseRuntimeInstance>;

export type DatabaseStorageDispatcher = {
  /**
   * The input is borrowed only for the synchronous duration of this call.
   * The returned view must own storage independent from the input borrow.
   */
  dispatchBytes(bytes: Uint8Array): Uint8Array;
};
