import assert from "node:assert/strict";
import test from "node:test";
import { databaseAlarmTimestampMilliseconds } from "../src/DatabaseAlarmTimestamp";

test("alarm timestamps never round later than the requested instant", () => {
  assert.equal(databaseAlarmTimestampMilliseconds(0n, 0), 0);
  assert.equal(databaseAlarmTimestampMilliseconds(10n, 1), 10_000);
  assert.equal(
    databaseAlarmTimestampMilliseconds(10n, 999_000_001),
    10_999
  );
  assert.equal(databaseAlarmTimestampMilliseconds(-1n, 500_000_000), -500);
  assert.equal(databaseAlarmTimestampMilliseconds(-1n, 999_999_999), -1);
});

test("alarm timestamps preserve JavaScript safe-integer boundaries", () => {
  assert.equal(
    databaseAlarmTimestampMilliseconds(
      9_007_199_254_740n,
      991_999_999
    ),
    Number.MAX_SAFE_INTEGER
  );
  assert.equal(
    databaseAlarmTimestampMilliseconds(
      -9_007_199_254_741n,
      9_000_000
    ),
    Number.MIN_SAFE_INTEGER
  );
});

test("alarm timestamps reject invalid or inexact values", () => {
  assert.throws(
    () => databaseAlarmTimestampMilliseconds(0n, 1_000_000_000),
    RangeError
  );
  assert.throws(
    () => databaseAlarmTimestampMilliseconds(
      9_007_199_254_740n,
      992_000_000
    ),
    RangeError
  );
  assert.throws(
    () => databaseAlarmTimestampMilliseconds(
      -9_007_199_254_741n,
      8_000_000
    ),
    RangeError
  );
});
