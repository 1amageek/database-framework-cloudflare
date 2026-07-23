export const databaseTaskScheduleErrorReason = Object.freeze({
  duplicateTaskID: "duplicateTaskID",
  capacityExceeded: "capacityExceeded",
  closed: "closed",
} as const);

export type DatabaseTaskScheduleErrorReason =
  typeof databaseTaskScheduleErrorReason[
    keyof typeof databaseTaskScheduleErrorReason
  ];

export class DatabaseTaskScheduleError extends Error {
  readonly reason: DatabaseTaskScheduleErrorReason;
  readonly limit: number;
  readonly taskID: number;

  constructor(options: {
    reason: DatabaseTaskScheduleErrorReason;
    limit: number;
    taskID: number;
  }) {
    super(databaseTaskScheduleErrorMessage(
      options.reason,
      options.limit,
      options.taskID
    ));
    this.name = "DatabaseTaskScheduleError";
    this.reason = options.reason;
    this.limit = options.limit;
    this.taskID = options.taskID;
  }
}

function databaseTaskScheduleErrorMessage(
  reason: DatabaseTaskScheduleErrorReason,
  limit: number,
  taskID: number
): string {
  switch (reason) {
  case databaseTaskScheduleErrorReason.duplicateTaskID:
    return `Database task ID ${taskID} is already scheduled`;
  case databaseTaskScheduleErrorReason.capacityExceeded:
    return `Scheduled database task count exceeds ${limit}`;
  case databaseTaskScheduleErrorReason.closed:
    return "Database task scheduler is closed";
  }
}
