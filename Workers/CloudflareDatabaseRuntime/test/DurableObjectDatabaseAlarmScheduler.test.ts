import assert from "node:assert/strict";
import test from "node:test";
import { DurableObjectDatabaseAlarmScheduler } from "../src/DurableObjectDatabaseAlarmScheduler";

test("Durable Object alarm scheduler persists the requested timestamp", async () => {
  const timestamps: Array<number | Date> = [];
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => undefined,
    getAlarm: async () => null,
    setAlarm: async (timestamp) => {
      timestamps.push(timestamp);
    },
  });

  await scheduler.ensureWakeUpNoLaterThan(1_700_000_000_001);

  assert.deepEqual(timestamps, [1_700_000_000_001]);
});

test("Durable Object alarm scheduler never postpones an earlier alarm", async () => {
  const timestamps: Array<number | Date> = [];
  let scheduledTimestamp: number | null = 1_700_000_000_000;
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => {
      scheduledTimestamp = null;
    },
    getAlarm: async () => scheduledTimestamp,
    setAlarm: async (timestamp) => {
      scheduledTimestamp = Number(timestamp);
      timestamps.push(timestamp);
    },
  });

  await scheduler.ensureWakeUpNoLaterThan(1_700_000_001_000);
  await scheduler.ensureWakeUpNoLaterThan(1_699_999_999_000);

  assert.deepEqual(timestamps, [1_699_999_999_000]);
  assert.equal(scheduledTimestamp, 1_699_999_999_000);
});

test("concurrent alarm requests preserve the earliest requested timestamp", async () => {
  let scheduledTimestamp: number | null = null;
  const laterTimestamp = 1_700_000_001_000;
  const earlierTimestamp = 1_699_999_999_000;
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => {
      scheduledTimestamp = null;
    },
    getAlarm: async () => scheduledTimestamp,
    setAlarm: async (timestamp) => {
      if (Number(timestamp) === laterTimestamp) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      scheduledTimestamp = Number(timestamp);
    },
  });

  await Promise.all([
    scheduler.ensureWakeUpNoLaterThan(laterTimestamp),
    scheduler.ensureWakeUpNoLaterThan(earlierTimestamp),
  ]);

  assert.equal(scheduledTimestamp, earlierTimestamp);
});

test("Durable Object alarm scheduler preserves storage failures", async () => {
  const failure = new Error("setAlarm failed");
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => undefined,
    getAlarm: async () => null,
    setAlarm: async () => {
      throw failure;
    },
  });

  await assert.rejects(
    scheduler.ensureWakeUpNoLaterThan(1),
    (error: unknown) => error === failure
  );
});

test("Durable Object alarm scheduler rejects inexact timestamps", async () => {
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => undefined,
    getAlarm: async () => null,
    setAlarm: async () => undefined,
  });

  await assert.rejects(
    scheduler.ensureWakeUpNoLaterThan(Number.MAX_SAFE_INTEGER + 1),
    RangeError
  );
});

test("successful alarm processing replaces its safety wake with requested work", async () => {
  let scheduledTimestamp: number | null = null;
  const recoveryTimestamp = 1_700_000_060_000;
  const requestedTimestamp = 1_700_000_120_000;
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => {
      scheduledTimestamp = null;
    },
    getAlarm: async () => scheduledTimestamp,
    setAlarm: async (timestamp) => {
      scheduledTimestamp = Number(timestamp);
    },
  });

  const lease = await scheduler.prepareAlarmRecovery(recoveryTimestamp);
  scheduler.beginAlarmProcessing(lease);
  await scheduler.ensureWakeUpNoLaterThan(requestedTimestamp);
  await scheduler.completeAlarmProcessing(lease);

  assert.equal(scheduledTimestamp, requestedTimestamp);
});

test("successful alarm processing removes an unused safety wake", async () => {
  let scheduledTimestamp: number | null = null;
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => {
      scheduledTimestamp = null;
    },
    getAlarm: async () => scheduledTimestamp,
    setAlarm: async (timestamp) => {
      scheduledTimestamp = Number(timestamp);
    },
  });

  const lease = await scheduler.prepareAlarmRecovery(1_700_000_060_000);
  scheduler.beginAlarmProcessing(lease);
  await scheduler.completeAlarmProcessing(lease);

  assert.equal(scheduledTimestamp, null);
});

test("failed alarm processing preserves its safety wake", async () => {
  let scheduledTimestamp: number | null = null;
  const recoveryTimestamp = 1_700_000_060_000;
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => {
      scheduledTimestamp = null;
    },
    getAlarm: async () => scheduledTimestamp,
    setAlarm: async (timestamp) => {
      scheduledTimestamp = Number(timestamp);
    },
  });

  const lease = await scheduler.prepareAlarmRecovery(recoveryTimestamp);
  scheduler.beginAlarmProcessing(lease);
  scheduler.preserveAlarmRecovery(lease);

  assert.equal(scheduledTimestamp, recoveryTimestamp);
});

test("alarm recovery preserves an earlier wake it does not own", async () => {
  const earlierTimestamp = 1_700_000_001_000;
  const scheduler = alarmSchedulerWithTimestamp(earlierTimestamp);

  const lease = await scheduler.scheduler.prepareAlarmRecovery(
    1_700_000_060_000
  );
  scheduler.scheduler.beginAlarmProcessing(lease);
  await scheduler.scheduler.completeAlarmProcessing(lease);

  assert.equal(scheduler.scheduledTimestamp(), earlierTimestamp);
  assert.equal(scheduler.deletedAlarmCount(), 0);
});

test("requested work never postpones an earlier unowned wake", async () => {
  const earlierTimestamp = 1_700_000_001_000;
  const scheduler = alarmSchedulerWithTimestamp(earlierTimestamp);

  const lease = await scheduler.scheduler.prepareAlarmRecovery(
    1_700_000_060_000
  );
  scheduler.scheduler.beginAlarmProcessing(lease);
  await scheduler.scheduler.ensureWakeUpNoLaterThan(1_700_000_120_000);
  await scheduler.scheduler.completeAlarmProcessing(lease);

  assert.equal(scheduler.scheduledTimestamp(), earlierTimestamp);
  assert.equal(scheduler.deletedAlarmCount(), 0);
});

test("a prepared safety wake cannot hide work scheduled before FIFO entry", async () => {
  const recoveryTimestamp = 1_700_000_060_000;
  const requestedTimestamp = 1_700_000_120_000;
  const scheduler = alarmSchedulerWithTimestamp(null);

  const lease = await scheduler.scheduler.prepareAlarmRecovery(
    recoveryTimestamp
  );
  await scheduler.scheduler.ensureWakeUpNoLaterThan(requestedTimestamp);
  scheduler.scheduler.beginAlarmProcessing(lease);
  await scheduler.scheduler.completeAlarmProcessing(lease);

  assert.equal(scheduler.scheduledTimestamp(), requestedTimestamp);
  assert.equal(scheduler.deletedAlarmCount(), 0);
});

test("completion getAlarm failure releases the lease for recovery", async () => {
  let getAlarmCount = 0;
  let scheduledTimestamp: number | null = null;
  const failure = new Error("completion getAlarm failed");
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => {
      scheduledTimestamp = null;
    },
    getAlarm: async () => {
      getAlarmCount += 1;
      if (getAlarmCount === 2) {
        throw failure;
      }
      return scheduledTimestamp;
    },
    setAlarm: async (timestamp) => {
      scheduledTimestamp = Number(timestamp);
    },
  });

  const failedLease = await scheduler.prepareAlarmRecovery(100);
  scheduler.beginAlarmProcessing(failedLease);
  await assert.rejects(
    scheduler.completeAlarmProcessing(failedLease),
    (error: unknown) => error === failure
  );
  scheduler.preserveAlarmRecovery(failedLease);

  const recoveredLease = await scheduler.prepareAlarmRecovery(200);
  scheduler.beginAlarmProcessing(recoveredLease);
  await scheduler.completeAlarmProcessing(recoveredLease);
  assert.equal(scheduledTimestamp, 100);
});

test("requested wake persistence failure keeps the recovery alarm", async () => {
  const recoveryTimestamp = 100;
  const requestedTimestamp = 200;
  let scheduledTimestamp: number | null = null;
  const failure = new Error("requested setAlarm failed");
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => {
      scheduledTimestamp = null;
    },
    getAlarm: async () => scheduledTimestamp,
    setAlarm: async (timestamp) => {
      if (Number(timestamp) === requestedTimestamp) {
        throw failure;
      }
      scheduledTimestamp = Number(timestamp);
    },
  });

  const lease = await scheduler.prepareAlarmRecovery(recoveryTimestamp);
  scheduler.beginAlarmProcessing(lease);
  await scheduler.ensureWakeUpNoLaterThan(requestedTimestamp);
  await assert.rejects(
    scheduler.completeAlarmProcessing(lease),
    (error: unknown) => error === failure
  );
  scheduler.preserveAlarmRecovery(lease);

  assert.equal(scheduledTimestamp, recoveryTimestamp);
});

test("safety alarm deletion failure keeps recovery visible", async () => {
  const recoveryTimestamp = 100;
  let scheduledTimestamp: number | null = null;
  const failure = new Error("deleteAlarm failed");
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
    deleteAlarm: async () => {
      throw failure;
    },
    getAlarm: async () => scheduledTimestamp,
    setAlarm: async (timestamp) => {
      scheduledTimestamp = Number(timestamp);
    },
  });

  const lease = await scheduler.prepareAlarmRecovery(recoveryTimestamp);
  scheduler.beginAlarmProcessing(lease);
  await assert.rejects(
    scheduler.completeAlarmProcessing(lease),
    (error: unknown) => error === failure
  );
  scheduler.preserveAlarmRecovery(lease);

  assert.equal(scheduledTimestamp, recoveryTimestamp);
});

function alarmSchedulerWithTimestamp(initialTimestamp: number | null): {
  scheduler: DurableObjectDatabaseAlarmScheduler;
  scheduledTimestamp(): number | null;
  deletedAlarmCount(): number;
} {
  let scheduledTimestamp: number | null = initialTimestamp;
  let deletedAlarmCount = 0;
  return {
    scheduler: new DurableObjectDatabaseAlarmScheduler({
      deleteAlarm: async () => {
        deletedAlarmCount += 1;
        scheduledTimestamp = null;
      },
      getAlarm: async () => scheduledTimestamp,
      setAlarm: async (timestamp) => {
        scheduledTimestamp = Number(timestamp);
      },
    }),
    scheduledTimestamp: () => scheduledTimestamp,
    deletedAlarmCount: () => deletedAlarmCount,
  };
}
