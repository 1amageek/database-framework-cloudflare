export interface DatabaseAlarmScheduler {
  ensureWakeUpNoLaterThan(timestampMilliseconds: number): Promise<void>;
}
