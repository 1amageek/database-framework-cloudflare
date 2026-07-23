export class DatabaseAlarmScheduleError extends Error {
  readonly reason: Error;

  constructor(reason: Error) {
    super(`Durable Object alarm scheduling failed: ${reason.message}`);
    this.name = "DatabaseAlarmScheduleError";
    this.reason = reason;
  }
}
