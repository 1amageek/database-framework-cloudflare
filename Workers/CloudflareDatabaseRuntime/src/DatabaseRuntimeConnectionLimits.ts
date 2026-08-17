import {
  databaseMaximumPayloadBytes,
  defaultDatabaseMaxContextBytes,
} from "./DatabaseRuntimeLimits";

export class DatabaseRuntimeConnectionLimits {
  static readonly maximumPendingInvocations = 1024;
  static readonly maximumInvocationTimeoutMilliseconds = 30_000;
  static readonly maximumPayloadCountPerInvocationSet = 65_536;
  static readonly maximumPayloadBytesPerInvocationSet = 64 * 1024 * 1024;
  static readonly maximumRuntimeAddressSpaceBytes = 128 * 1024 * 1024;
  static readonly maximumScheduledTasks = 65_536;
  static readonly maximumScheduledClockWaits = 65_536;
  static readonly maximumWasiIovecCount = 65_536;
  static readonly maximumWasiIovecBytes = 16 * 1024 * 1024;
  static readonly maximumFailureBytes = 16 * 1024;

  readonly maximumContextBytes: number;
  readonly maximumRequestBytes: number;
  readonly maximumResponseBytes: number;
  readonly maximumFailureBytes: number;
  readonly maximumStorageRequestBytes: number;
  readonly maximumStorageResponseBytes: number;
  readonly maximumPendingInvocations: number;
  readonly invocationTimeoutMilliseconds: number;
  readonly maximumPayloadCountPerInvocationSet: number;
  readonly maximumPayloadBytesPerInvocationSet: number;
  readonly maximumRuntimeAddressSpaceBytes: number;
  readonly maximumScheduledTasks: number;
  readonly maximumScheduledClockWaits: number;
  readonly maximumWasiIovecCount: number;
  readonly maximumWasiIovecBytes: number;

  constructor(options: {
    maximumContextBytes?: number;
    maximumRequestBytes: number;
    maximumResponseBytes: number;
    maximumFailureBytes?: number;
    maximumStorageRequestBytes?: number;
    maximumStorageResponseBytes?: number;
    maximumPendingInvocations?: number;
    invocationTimeoutMilliseconds?: number;
    maximumPayloadCountPerInvocationSet?: number;
    maximumPayloadBytesPerInvocationSet?: number;
    maximumRuntimeAddressSpaceBytes?: number;
    maximumScheduledTasks?: number;
    maximumScheduledClockWaits?: number;
    maximumWasiIovecCount?: number;
    maximumWasiIovecBytes?: number;
  }) {
    this.maximumContextBytes = validatePayloadLimit(
      options.maximumContextBytes ?? defaultDatabaseMaxContextBytes,
      "maximumContextBytes"
    );
    this.maximumRequestBytes = validatePayloadLimit(
      options.maximumRequestBytes,
      "maximumRequestBytes"
    );
    this.maximumResponseBytes = validatePayloadLimit(
      options.maximumResponseBytes,
      "maximumResponseBytes"
    );
    this.maximumFailureBytes = validateIntegerLimit(
      options.maximumFailureBytes
        ?? DatabaseRuntimeConnectionLimits.maximumFailureBytes,
      "maximumFailureBytes",
      DatabaseRuntimeConnectionLimits.maximumFailureBytes
    );
    this.maximumStorageRequestBytes = validatePayloadLimit(
      options.maximumStorageRequestBytes ?? databaseMaximumPayloadBytes,
      "maximumStorageRequestBytes"
    );
    this.maximumStorageResponseBytes = validatePayloadLimit(
      options.maximumStorageResponseBytes ?? databaseMaximumPayloadBytes,
      "maximumStorageResponseBytes"
    );
    this.maximumPendingInvocations = validatePendingInvocations(
      options.maximumPendingInvocations ?? 64
    );
    this.invocationTimeoutMilliseconds = validateTimeout(
      options.invocationTimeoutMilliseconds ?? 30_000
    );
    this.maximumPayloadCountPerInvocationSet = validateIntegerLimit(
      options.maximumPayloadCountPerInvocationSet ?? 4_096,
      "maximumPayloadCountPerInvocationSet",
      DatabaseRuntimeConnectionLimits.maximumPayloadCountPerInvocationSet
    );
    this.maximumPayloadBytesPerInvocationSet = validateIntegerLimit(
      options.maximumPayloadBytesPerInvocationSet ?? 32 * 1024 * 1024,
      "maximumPayloadBytesPerInvocationSet",
      DatabaseRuntimeConnectionLimits.maximumPayloadBytesPerInvocationSet
    );
    const minimumPayloadByteLimit = this.maximumContextBytes
      + this.maximumRequestBytes;
    if (!Number.isSafeInteger(minimumPayloadByteLimit)) {
      throw new RangeError("combined invocation payload limit is invalid");
    }
    if (this.maximumPayloadBytesPerInvocationSet < minimumPayloadByteLimit) {
      throw new RangeError(
        `maximumPayloadBytesPerInvocationSet must be at least ${minimumPayloadByteLimit}`
      );
    }
    this.maximumRuntimeAddressSpaceBytes = validateIntegerLimit(
      options.maximumRuntimeAddressSpaceBytes ?? 64 * 1024 * 1024,
      "maximumRuntimeAddressSpaceBytes",
      DatabaseRuntimeConnectionLimits.maximumRuntimeAddressSpaceBytes
    );
    this.maximumScheduledTasks = validateIntegerLimit(
      options.maximumScheduledTasks ?? 4_096,
      "maximumScheduledTasks",
      DatabaseRuntimeConnectionLimits.maximumScheduledTasks
    );
    this.maximumScheduledClockWaits = validateIntegerLimit(
      options.maximumScheduledClockWaits ?? 4_096,
      "maximumScheduledClockWaits",
      DatabaseRuntimeConnectionLimits.maximumScheduledClockWaits
    );
    this.maximumWasiIovecCount = validateIntegerLimit(
      options.maximumWasiIovecCount ?? 1_024,
      "maximumWasiIovecCount",
      DatabaseRuntimeConnectionLimits.maximumWasiIovecCount
    );
    this.maximumWasiIovecBytes = validateIntegerLimit(
      options.maximumWasiIovecBytes ?? 1024 * 1024,
      "maximumWasiIovecBytes",
      DatabaseRuntimeConnectionLimits.maximumWasiIovecBytes
    );
  }
}

function validateTimeout(value: number): number {
  if (!Number.isInteger(value)
      || value <= 0
      || value > DatabaseRuntimeConnectionLimits.maximumInvocationTimeoutMilliseconds) {
    throw new RangeError(
      "invocationTimeoutMilliseconds must be an integer from 1 through "
        + DatabaseRuntimeConnectionLimits.maximumInvocationTimeoutMilliseconds
    );
  }
  return value;
}

function validatePayloadLimit(value: number, field: string): number {
  if (!Number.isInteger(value)
      || value <= 0
      || value > databaseMaximumPayloadBytes) {
    throw new RangeError(
      `${field} must be an integer from 1 through ${databaseMaximumPayloadBytes}`
    );
  }
  return value;
}

function validatePendingInvocations(value: number): number {
  if (!Number.isInteger(value)
      || value <= 0
      || value > DatabaseRuntimeConnectionLimits.maximumPendingInvocations) {
    throw new RangeError(
      `maximumPendingInvocations must be an integer from 1 through ${DatabaseRuntimeConnectionLimits.maximumPendingInvocations}`
    );
  }
  return value;
}

function validateIntegerLimit(
  value: number,
  field: string,
  maximumValue: number
): number {
  if (!Number.isInteger(value) || value <= 0 || value > maximumValue) {
    throw new RangeError(
      `${field} must be an integer from 1 through ${maximumValue}`
    );
  }
  return value;
}
