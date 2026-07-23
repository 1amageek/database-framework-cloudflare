import type { DatabaseAlarmScheduler } from "./DatabaseAlarmScheduler";

export class DurableObjectDatabaseAlarmScheduler implements DatabaseAlarmScheduler {
  private readonly storage: Pick<
    DurableObjectStorage,
    "getAlarm" | "setAlarm"
  >;
  private pendingWakeUpPersistence: Promise<void> = Promise.resolve();

  constructor(
    storage: Pick<DurableObjectStorage, "getAlarm" | "setAlarm">
  ) {
    this.storage = storage;
  }

  async ensureWakeUpNoLaterThan(timestampMilliseconds: number): Promise<void> {
    if (!Number.isSafeInteger(timestampMilliseconds)) {
      throw new RangeError("Database alarm timestamp is invalid");
    }

    const persistence = this.pendingWakeUpPersistence.then(() =>
      this.persistWakeUpNoLaterThan(timestampMilliseconds)
    );
    // Queue recovery only permits a later request to run. This call still
    // returns the original persistence promise and preserves its failure.
    this.pendingWakeUpPersistence = persistence.catch(() => undefined);
    return persistence;
  }

  private async persistWakeUpNoLaterThan(
    timestampMilliseconds: number
  ): Promise<void> {
    const scheduledTimestamp = await this.storage.getAlarm();
    if (
      scheduledTimestamp !== null &&
      scheduledTimestamp <= timestampMilliseconds
    ) {
      return;
    }
    await this.storage.setAlarm(timestampMilliseconds);
  }
}
