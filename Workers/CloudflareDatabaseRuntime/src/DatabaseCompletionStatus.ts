export const databaseCompletionStatus = Object.freeze({
  success: 0,
  invalidCallID: 1,
  invalidPayload: 2,
  requestTooLarge: 3,
  responseTooLarge: 4,
  queueCapacityExceeded: 5,
  notStarted: 6,
  alreadyStarted: 7,
  startupInProgress: 8,
  startupFailed: 9,
  cancelled: 10,
  runtimeFailed: 11,
  contextTooLarge: 12,
  alarmFailed: 13,
  applicationFailed: 14,
} as const);

export type DatabaseCompletionStatus =
  typeof databaseCompletionStatus[keyof typeof databaseCompletionStatus];
