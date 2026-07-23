import type { DatabaseRuntimeEndpoints } from "./DatabaseRuntimeTypes";
import {
  databaseRuntimePayloadLimitReason,
  DatabaseRuntimePayloadLimitError,
} from "./DatabaseRuntimePayloadLimitError";

type ConnectionPayload = {
  byteCount: number;
};

/**
 * Owns connection-requested payloads until ownership transfers to the runtime.
 * Payload totals are cumulative for the active invocation set so repeated
 * short-lived reservations cannot bypass the resource budget.
 */
export class DatabaseRuntimePayloadOwnership {
  private readonly runtimeEndpoints: () => DatabaseRuntimeEndpoints;
  private readonly maximumPayloadCount: number;
  private readonly maximumPayloadBytes: number;
  private readonly maximumRuntimeAddressSpaceBytes: number;
  private readonly connectionPayloads = new Map<number, ConnectionPayload>();

  private payloadCount = 0;
  private payloadBytes = 0;

  constructor(
    runtimeEndpoints: () => DatabaseRuntimeEndpoints,
    options: {
      maximumPayloadCount: number;
      maximumPayloadBytes: number;
      maximumRuntimeAddressSpaceBytes: number;
    }
  ) {
    this.runtimeEndpoints = runtimeEndpoints;
    this.maximumPayloadCount = options.maximumPayloadCount;
    this.maximumPayloadBytes = options.maximumPayloadBytes;
    this.maximumRuntimeAddressSpaceBytes = options.maximumRuntimeAddressSpaceBytes;
  }

  beginInvocationSet(): void {
    if (this.payloadCount !== 0
        || this.payloadBytes !== 0
        || this.connectionPayloads.size !== 0) {
      throw new Error("Database runtime invocation set is already active");
    }
    this.assertAddressSpaceLimit();
  }

  reservePayload(byteCount: number): number {
    if (!Number.isInteger(byteCount) || byteCount < 0) {
      throw new RangeError("Database runtime payload length is invalid");
    }
    if (byteCount === 0) {
      return 0;
    }

    const nextPayloadCount = this.payloadCount + 1;
    if (nextPayloadCount > this.maximumPayloadCount) {
      throw new DatabaseRuntimePayloadLimitError({
        reason: databaseRuntimePayloadLimitReason.payloadCount,
        limit: this.maximumPayloadCount,
        requested: nextPayloadCount,
      });
    }
    const nextPayloadBytes = this.payloadBytes + byteCount;
    if (!Number.isSafeInteger(nextPayloadBytes)
        || nextPayloadBytes > this.maximumPayloadBytes) {
      throw new DatabaseRuntimePayloadLimitError({
        reason: databaseRuntimePayloadLimitReason.payloadBytes,
        limit: this.maximumPayloadBytes,
        requested: nextPayloadBytes,
      });
    }

    this.assertAddressSpaceLimit();
    const payloadAddress = this.runtimeEndpoints().reservePayload(byteCount);
    if (payloadAddress === 0) {
      return 0;
    }
    if (!Number.isInteger(payloadAddress) || payloadAddress < 0) {
      throw new RangeError("Database runtime returned an invalid payload address");
    }
    if (this.connectionPayloads.has(payloadAddress)) {
      throw new Error(
        "Database runtime reused a connection-owned payload address"
      );
    }
    this.connectionPayloads.set(payloadAddress, { byteCount });
    this.payloadCount = nextPayloadCount;
    this.payloadBytes = nextPayloadBytes;
    return payloadAddress;
  }

  releaseConnectionPayload(payloadAddress: number, byteCount: number): void {
    if (payloadAddress === 0 && byteCount === 0) {
      return;
    }
    this.requireConnectionPayload(payloadAddress, byteCount);
    this.connectionPayloads.delete(payloadAddress);
    this.runtimeEndpoints().releasePayload(payloadAddress, byteCount);
  }

  transferPayloadToRuntime(payloadAddress: number, byteCount: number): void {
    if (payloadAddress === 0 && byteCount === 0) {
      return;
    }
    this.requireConnectionPayload(payloadAddress, byteCount);
    this.connectionPayloads.delete(payloadAddress);
  }

  borrowBytes(payloadAddress: number, byteCount: number): Uint8Array {
    if (!Number.isInteger(payloadAddress)
        || !Number.isInteger(byteCount)
        || payloadAddress < 0
        || byteCount < 0) {
      throw new RangeError("Database runtime payload range is invalid");
    }
    const addressSpace = this.runtimeEndpoints().addressSpace;
    this.assertAddressSpaceLimit(addressSpace);
    const end = payloadAddress + byteCount;
    if (!Number.isSafeInteger(end) || end > addressSpace.buffer.byteLength) {
      throw new RangeError("Database runtime payload range is out of bounds");
    }
    return new Uint8Array(addressSpace.buffer, payloadAddress, byteCount);
  }

  finishInvocationSet(): void {
    if (this.connectionPayloads.size !== 0) {
      throw new Error(
        "Database invocation set completed with connection-owned payloads"
      );
    }
    this.payloadCount = 0;
    this.payloadBytes = 0;
    this.assertAddressSpaceLimit();
  }

  discardRuntimeGeneration(): void {
    this.connectionPayloads.clear();
    this.payloadCount = 0;
    this.payloadBytes = 0;
  }

  assertAddressSpaceLimit(
    addressSpace: WebAssembly.Memory = this.runtimeEndpoints().addressSpace
  ): void {
    const byteLength = addressSpace.buffer.byteLength;
    if (byteLength > this.maximumRuntimeAddressSpaceBytes) {
      throw new DatabaseRuntimePayloadLimitError({
        reason: databaseRuntimePayloadLimitReason.addressSpaceBytes,
        limit: this.maximumRuntimeAddressSpaceBytes,
        requested: byteLength,
      });
    }
  }

  private requireConnectionPayload(
    payloadAddress: number,
    byteCount: number
  ): ConnectionPayload {
    const payload = this.connectionPayloads.get(payloadAddress);
    if (payload === undefined) {
      throw new Error(
        "Database runtime payload is not owned by the connection"
      );
    }
    if (payload.byteCount !== byteCount) {
      throw new Error("Database runtime payload length does not match ownership");
    }
    return payload;
  }
}
