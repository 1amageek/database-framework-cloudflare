export const databaseRuntimePayloadLimitReason = Object.freeze({
  payloadCount: "payloadCount",
  payloadBytes: "payloadBytes",
  addressSpaceBytes: "addressSpaceBytes",
} as const);

export type DatabaseRuntimePayloadLimitReason =
  typeof databaseRuntimePayloadLimitReason[
    keyof typeof databaseRuntimePayloadLimitReason
  ];

export class DatabaseRuntimePayloadLimitError extends Error {
  readonly reason: DatabaseRuntimePayloadLimitReason;
  readonly limit: number;
  readonly requested: number;

  constructor(options: {
    reason: DatabaseRuntimePayloadLimitReason;
    limit: number;
    requested: number;
  }) {
    super(databaseRuntimePayloadLimitMessage(options.reason, options.limit));
    this.name = "DatabaseRuntimePayloadLimitError";
    this.reason = options.reason;
    this.limit = options.limit;
    this.requested = options.requested;
  }
}

function databaseRuntimePayloadLimitMessage(
  reason: DatabaseRuntimePayloadLimitReason,
  limit: number
): string {
  switch (reason) {
  case databaseRuntimePayloadLimitReason.payloadCount:
    return `Database runtime payload count exceeds ${limit} per active invocation set`;
  case databaseRuntimePayloadLimitReason.payloadBytes:
    return `Database runtime payload bytes exceed ${limit} per active invocation set`;
  case databaseRuntimePayloadLimitReason.addressSpaceBytes:
    return `Database runtime address space exceeds ${limit} bytes`;
  }
}
