export const databaseRequestQueueCapacityReason = Object.freeze({
  pendingRequests: "pendingRequests",
  pendingRequestBytes: "pendingRequestBytes",
} as const);

export type DatabaseRequestQueueCapacityReason =
  typeof databaseRequestQueueCapacityReason[
    keyof typeof databaseRequestQueueCapacityReason
  ];

export class DatabaseRequestQueueCapacityError extends Error {
  readonly reason: DatabaseRequestQueueCapacityReason;
  readonly limit: number;
  readonly pending: number;
  readonly requested: number;

  constructor(options: {
    reason: DatabaseRequestQueueCapacityReason;
    limit: number;
    pending: number;
    requested: number;
  }) {
    super(databaseRequestQueueCapacityMessage(options.reason, options.limit));
    this.name = "DatabaseRequestQueueCapacityError";
    this.reason = options.reason;
    this.limit = options.limit;
    this.pending = options.pending;
    this.requested = options.requested;
  }
}

function databaseRequestQueueCapacityMessage(
  reason: DatabaseRequestQueueCapacityReason,
  limit: number
): string {
  switch (reason) {
  case databaseRequestQueueCapacityReason.pendingRequests:
    return `Database request queue accepts at most ${limit} pending requests`;
  case databaseRequestQueueCapacityReason.pendingRequestBytes:
    return `Database request queue accepts at most ${limit} pending request bytes`;
  }
}
