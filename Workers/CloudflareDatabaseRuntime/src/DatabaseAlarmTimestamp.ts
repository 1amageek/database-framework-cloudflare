const nanosecondsPerSecond = 1_000_000_000;
const nanosecondsPerMillisecond = 1_000_000;
const millisecondsPerSecond = 1_000n;
const maximumSafeMilliseconds = BigInt(Number.MAX_SAFE_INTEGER);
const minimumSafeMilliseconds = BigInt(Number.MIN_SAFE_INTEGER);

export function databaseAlarmTimestampMilliseconds(
  secondsSinceUnixEpoch: bigint,
  nanoseconds: number
): number {
  if (typeof secondsSinceUnixEpoch !== "bigint") {
    throw new RangeError("Database alarm seconds are invalid");
  }
  if (!Number.isInteger(nanoseconds)
      || nanoseconds < 0
      || nanoseconds >= nanosecondsPerSecond) {
    throw new RangeError("Database alarm nanoseconds are invalid");
  }

  const wholeMilliseconds = Math.floor(
    nanoseconds / nanosecondsPerMillisecond
  );
  const timestampMilliseconds = secondsSinceUnixEpoch
    * millisecondsPerSecond
    + BigInt(wholeMilliseconds);
  if (timestampMilliseconds < minimumSafeMilliseconds
      || timestampMilliseconds > maximumSafeMilliseconds) {
    throw new RangeError("Database alarm timestamp exceeds JavaScript precision");
  }
  return Number(timestampMilliseconds);
}
