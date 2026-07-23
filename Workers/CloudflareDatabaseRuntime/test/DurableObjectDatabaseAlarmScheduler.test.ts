import assert from "node:assert/strict";
import test from "node:test";
import { DurableObjectDatabaseAlarmScheduler } from "../src/DurableObjectDatabaseAlarmScheduler";

test("Durable Object alarm scheduler persists the requested timestamp", async () => {
  const timestamps: Array<number | Date> = [];
  const scheduler = new DurableObjectDatabaseAlarmScheduler({
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
    getAlarm: async () => null,
    setAlarm: async () => undefined,
  });

  await assert.rejects(
    scheduler.ensureWakeUpNoLaterThan(Number.MAX_SAFE_INTEGER + 1),
    RangeError
  );
});
