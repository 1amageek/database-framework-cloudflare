export const databaseStorageResponseStateErrorReason = {
  responseAlreadyPending: "responseAlreadyPending",
  responseUnavailable: "responseUnavailable",
  responseLengthMismatch: "responseLengthMismatch",
  emptyResponse: "emptyResponse",
} as const;

export type DatabaseStorageResponseStateErrorReason =
  typeof databaseStorageResponseStateErrorReason[
    keyof typeof databaseStorageResponseStateErrorReason
  ];

export class DatabaseStorageResponseStateError extends Error {
  readonly reason: DatabaseStorageResponseStateErrorReason;
  readonly expectedByteCount: number | null;
  readonly actualByteCount: number | null;

  constructor(options: {
    reason: DatabaseStorageResponseStateErrorReason;
    expectedByteCount?: number;
    actualByteCount?: number;
  }) {
    super(message(options));
    this.name = "DatabaseStorageResponseStateError";
    this.reason = options.reason;
    this.expectedByteCount = options.expectedByteCount ?? null;
    this.actualByteCount = options.actualByteCount ?? null;
  }
}

function message(options: {
  reason: DatabaseStorageResponseStateErrorReason;
  expectedByteCount?: number;
  actualByteCount?: number;
}): string {
  switch (options.reason) {
  case databaseStorageResponseStateErrorReason.responseAlreadyPending:
    return "A storage response is already pending guest receipt";
  case databaseStorageResponseStateErrorReason.responseUnavailable:
    return "No storage response is pending guest receipt";
  case databaseStorageResponseStateErrorReason.responseLengthMismatch:
    return `Storage response length ${options.actualByteCount} does not match ${options.expectedByteCount}`;
  case databaseStorageResponseStateErrorReason.emptyResponse:
    return "Storage dispatcher returned an empty response";
  }
}
