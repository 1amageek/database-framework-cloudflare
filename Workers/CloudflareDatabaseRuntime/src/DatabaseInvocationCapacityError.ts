export const databaseInvocationCapacityReason = Object.freeze({
  pendingInvocations: "pendingInvocations",
  pendingInvocationBytes: "pendingInvocationBytes",
} as const);

export type DatabaseInvocationCapacityReason =
  typeof databaseInvocationCapacityReason[
    keyof typeof databaseInvocationCapacityReason
  ];

export class DatabaseInvocationCapacityError extends Error {
  readonly reason: DatabaseInvocationCapacityReason;
  readonly limit: number;
  readonly pending: number;
  readonly requested: number;

  constructor(options: {
    reason: DatabaseInvocationCapacityReason;
    limit: number;
    pending: number;
    requested: number;
  }) {
    super(databaseInvocationCapacityMessage(options.reason, options.limit));
    this.name = "DatabaseInvocationCapacityError";
    this.reason = options.reason;
    this.limit = options.limit;
    this.pending = options.pending;
    this.requested = options.requested;
  }
}

function databaseInvocationCapacityMessage(
  reason: DatabaseInvocationCapacityReason,
  limit: number
): string {
  switch (reason) {
  case databaseInvocationCapacityReason.pendingInvocations:
    return `Database runtime accepts at most ${limit} pending invocations`;
  case databaseInvocationCapacityReason.pendingInvocationBytes:
    return `Database runtime accepts at most ${limit} pending invocation bytes`;
  }
}
