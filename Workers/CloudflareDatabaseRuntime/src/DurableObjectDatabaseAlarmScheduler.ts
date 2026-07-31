import type { DatabaseAlarmScheduler } from "./DatabaseAlarmScheduler";

export interface DatabaseAlarmRecoveryLease {
  readonly recoveryTimestampMilliseconds: number;
}

type DatabaseAlarmRecoveryState = {
  installedRecovery: boolean;
  earliestRequestedTimestampMilliseconds: number | null;
  phase: "prepared" | "active";
};

export class DurableObjectDatabaseAlarmScheduler implements DatabaseAlarmScheduler {
  private readonly storage: Pick<
    DurableObjectStorage,
    "deleteAlarm" | "getAlarm" | "setAlarm"
  >;
  private pendingWakeUpPersistence: Promise<void> = Promise.resolve();
  private readonly recoveryStates =
    new Map<DatabaseAlarmRecoveryLease, DatabaseAlarmRecoveryState>();
  private activeAlarm: DatabaseAlarmRecoveryLease | null = null;

  constructor(
    storage: Pick<
      DurableObjectStorage,
      "deleteAlarm" | "getAlarm" | "setAlarm"
    >
  ) {
    this.storage = storage;
  }

  async prepareAlarmRecovery(
    recoveryTimestampMilliseconds: number
  ): Promise<DatabaseAlarmRecoveryLease> {
    validateTimestamp(recoveryTimestampMilliseconds);
    const lease = Object.freeze({ recoveryTimestampMilliseconds });
    const state: DatabaseAlarmRecoveryState = {
      installedRecovery: false,
      earliestRequestedTimestampMilliseconds: null,
      phase: "prepared",
    };
    this.recoveryStates.set(lease, state);
    try {
      await this.enqueuePersistence(async () => {
        const scheduledTimestamp = await this.storage.getAlarm();
        if (scheduledTimestamp === null
            || scheduledTimestamp > recoveryTimestampMilliseconds) {
          await this.storage.setAlarm(recoveryTimestampMilliseconds);
          state.installedRecovery = true;
        }
      });
    } catch (error) {
      this.recoveryStates.delete(lease);
      throw error;
    }
    return lease;
  }

  beginAlarmProcessing(lease: DatabaseAlarmRecoveryLease): void {
    const state = this.recoveryState(lease);
    if (this.activeAlarm !== null || state.phase !== "prepared") {
      throw new Error("Database alarm processing is already active");
    }
    state.phase = "active";
    this.activeAlarm = lease;
  }

  async completeAlarmProcessing(
    lease: DatabaseAlarmRecoveryLease
  ): Promise<void> {
    const state = this.activeRecoveryState(lease);
    await this.enqueuePersistence(async () => {
      const requestedTimestamp =
        state.earliestRequestedTimestampMilliseconds;
      const scheduledTimestamp = await this.storage.getAlarm();
      if (requestedTimestamp !== null) {
        const scheduledRecoveryIsOwned = state.installedRecovery
          && scheduledTimestamp === lease.recoveryTimestampMilliseconds;
        if (scheduledTimestamp === null
            || scheduledTimestamp > requestedTimestamp
            || (scheduledRecoveryIsOwned
              && scheduledTimestamp !== requestedTimestamp)) {
          await this.storage.setAlarm(requestedTimestamp);
        }
        return;
      }
      if (state.installedRecovery
          && scheduledTimestamp === lease.recoveryTimestampMilliseconds) {
        await this.storage.deleteAlarm();
      }
    });
    this.finishAlarmProcessing(lease);
  }

  preserveAlarmRecovery(lease: DatabaseAlarmRecoveryLease): void {
    if (!this.recoveryStates.has(lease)) {
      return;
    }
    this.finishAlarmProcessing(lease);
  }

  private recoveryState(
    lease: DatabaseAlarmRecoveryLease
  ): DatabaseAlarmRecoveryState {
    const state = this.recoveryStates.get(lease);
    if (state === undefined) {
      throw new Error("Database alarm recovery lease is invalid");
    }
    return state;
  }

  private activeRecoveryState(
    lease: DatabaseAlarmRecoveryLease
  ): DatabaseAlarmRecoveryState {
    const state = this.recoveryState(lease);
    if (this.activeAlarm !== lease || state.phase !== "active") {
      throw new Error("Database alarm processing is not active");
    }
    return state;
  }

  private finishAlarmProcessing(lease: DatabaseAlarmRecoveryLease): void {
    if (this.activeAlarm === lease) {
      this.activeAlarm = null;
    }
    this.recoveryStates.delete(lease);
  }

  async ensureWakeUpNoLaterThan(timestampMilliseconds: number): Promise<void> {
    validateTimestamp(timestampMilliseconds);
    for (const state of this.recoveryStates.values()) {
      const earliestRequested = state.earliestRequestedTimestampMilliseconds;
      if (earliestRequested === null
          || timestampMilliseconds < earliestRequested) {
        state.earliestRequestedTimestampMilliseconds =
          timestampMilliseconds;
      }
    }

    return this.enqueuePersistence(() =>
      this.persistWakeUpNoLaterThan(timestampMilliseconds)
    );
  }

  private enqueuePersistence(operation: () => Promise<void>): Promise<void> {
    const persistence = this.pendingWakeUpPersistence.then(operation);
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

function validateTimestamp(timestampMilliseconds: number): void {
  if (!Number.isSafeInteger(timestampMilliseconds)) {
    throw new RangeError("Database alarm timestamp is invalid");
  }
}
