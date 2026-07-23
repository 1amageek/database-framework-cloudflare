export interface DatabaseClockWaiter {
  wait(delayMilliseconds: number, signal: AbortSignal): Promise<void>;
}

export const cloudflareDatabaseClockWaiter: DatabaseClockWaiter = {
  wait: (delayMilliseconds, signal) =>
    scheduler.wait(delayMilliseconds, { signal }),
};
