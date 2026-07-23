export const databaseClockServiceErrorReason = Object.freeze({
  duplicateWaitID: "duplicateWaitID",
  unknownWaitID: "unknownWaitID",
  capacityExceeded: "capacityExceeded",
  closed: "closed",
  waitFailed: "waitFailed",
} as const);

export type DatabaseClockServiceErrorReason =
  typeof databaseClockServiceErrorReason[
    keyof typeof databaseClockServiceErrorReason
  ];

export class DatabaseClockServiceError extends Error {
  readonly reason: DatabaseClockServiceErrorReason;
  readonly limit: number;
  readonly waitID: number;
  readonly underlyingError: Error | null;

  constructor(options: {
    reason: DatabaseClockServiceErrorReason;
    limit: number;
    waitID: number;
    underlyingError?: Error;
  }) {
    super(databaseClockServiceErrorMessage(options));
    this.name = "DatabaseClockServiceError";
    this.reason = options.reason;
    this.limit = options.limit;
    this.waitID = options.waitID;
    this.underlyingError = options.underlyingError ?? null;
  }
}

function databaseClockServiceErrorMessage(options: {
  reason: DatabaseClockServiceErrorReason;
  limit: number;
  waitID: number;
  underlyingError?: Error;
}): string {
  switch (options.reason) {
  case databaseClockServiceErrorReason.duplicateWaitID:
    return `Clock wait ID ${options.waitID} is already scheduled`;
  case databaseClockServiceErrorReason.unknownWaitID:
    return `Clock wait ID ${options.waitID} is not scheduled`;
  case databaseClockServiceErrorReason.capacityExceeded:
    return `Clock wait count exceeds ${options.limit}`;
  case databaseClockServiceErrorReason.closed:
    return "Database clock service is closed";
  case databaseClockServiceErrorReason.waitFailed:
    return `Clock wait ID ${options.waitID} failed: ${
      options.underlyingError?.message ?? "unknown failure"
    }`;
  }
}
