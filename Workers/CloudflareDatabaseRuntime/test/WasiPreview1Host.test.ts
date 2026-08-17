import assert from "node:assert/strict";
import test from "node:test";
import { WasiPreview1Host, wasiErrno } from "../src/WasiPreview1Host";

test("WasiPreview1Host writes fd_write byte counts from iovec lengths", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const fdWrite = wasiServiceFunction<[number, number, number, number]>(runtimeServices, "fd_write");

  writeUInt32(addressSpace, 32, 256);
  writeUInt32(addressSpace, 36, 5);
  writeUInt32(addressSpace, 40, 512);
  writeUInt32(addressSpace, 44, 7);

  assert.equal(fdWrite(1, 32, 2, 24), wasiErrno.success);
  assert.equal(readUInt32(addressSpace, 24), 12);
});

test("WasiPreview1Host rejects writes to non-output file descriptors", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const fdWrite = wasiServiceFunction<[number, number, number, number]>(runtimeServices, "fd_write");

  writeUInt32(addressSpace, 24, 99);

  assert.equal(fdWrite(9, 32, 0, 24), wasiErrno.badFileDescriptor);
  assert.equal(readUInt32(addressSpace, 24), 99);
});

test("WasiPreview1Host bounds iovec count without touching the result", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace, {
    maximumIovecCount: 1,
    maximumIovecBytes: 16,
  });
  const fdWrite = wasiServiceFunction<[number, number, number, number]>(
    runtimeServices,
    "fd_write"
  );
  writeUInt32(addressSpace, 24, 99);

  assert.equal(
    fdWrite(1, 32, 2, 24),
    wasiErrno.argumentListTooLong
  );
  assert.equal(readUInt32(addressSpace, 24), 99);
});

test("WasiPreview1Host bounds aggregate iovec bytes without copying", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace, {
    maximumIovecCount: 2,
    maximumIovecBytes: 8,
  });
  const fdWrite = wasiServiceFunction<[number, number, number, number]>(
    runtimeServices,
    "fd_write"
  );
  writeUInt32(addressSpace, 32, 256);
  writeUInt32(addressSpace, 36, 5);
  writeUInt32(addressSpace, 40, 512);
  writeUInt32(addressSpace, 44, 4);
  writeUInt32(addressSpace, 24, 99);

  assert.equal(
    fdWrite(1, 32, 2, 24),
    wasiErrno.argumentListTooLong
  );
  assert.equal(readUInt32(addressSpace, 24), 99);
});

test("WasiPreview1Host rejects out-of-bounds iovec tables and buffers", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const fdWrite = wasiServiceFunction<[number, number, number, number]>(
    runtimeServices,
    "fd_write"
  );
  writeUInt32(addressSpace, 32, addressSpace.buffer.byteLength - 1);
  writeUInt32(addressSpace, 36, 2);
  writeUInt32(addressSpace, 24, 99);

  assert.equal(fdWrite(1, 32, 1, 24), wasiErrno.fault);
  assert.equal(
    fdWrite(1, addressSpace.buffer.byteLength - 4, 1, 24),
    wasiErrno.fault
  );
  assert.equal(readUInt32(addressSpace, 24), 99);
});

test("WasiPreview1Host reports empty stdin reads through nread", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const fdRead = wasiServiceFunction<[number, number, number, number]>(runtimeServices, "fd_read");

  writeUInt32(addressSpace, 24, 99);

  assert.equal(fdRead(0, 32, 1, 24), wasiErrno.success);
  assert.equal(readUInt32(addressSpace, 24), 0);
  assert.equal(fdRead(1, 32, 1, 24), wasiErrno.badFileDescriptor);
});

test("WasiPreview1Host applies iovec limits to empty stdin reads", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace, {
    maximumIovecCount: 1,
    maximumIovecBytes: 8,
  });
  const fdRead = wasiServiceFunction<[number, number, number, number]>(
    runtimeServices,
    "fd_read"
  );
  writeUInt32(addressSpace, 24, 99);

  assert.equal(
    fdRead(0, 32, 2, 24),
    wasiErrno.argumentListTooLong
  );
  assert.equal(readUInt32(addressSpace, 24), 99);
});

test("WasiPreview1Host writes fdstat for standard file descriptors", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const fdFdstatGet = wasiServiceFunction<[number, number]>(runtimeServices, "fd_fdstat_get");
  const fdFilestatGet = wasiServiceFunction<[number, number]>(runtimeServices, "fd_filestat_get");

  new Uint8Array(addressSpace.buffer, 64, 24).fill(0xff);
  new Uint8Array(addressSpace.buffer, 128, 64).fill(0xff);

  assert.equal(fdFdstatGet(2, 64), wasiErrno.success);
  assert.equal(new Uint8Array(addressSpace.buffer, 64, 1)[0], 2);
  assert.deepEqual(Array.from(new Uint8Array(addressSpace.buffer, 65, 23)), new Array(23).fill(0));
  assert.equal(fdFdstatGet(9, 64), wasiErrno.badFileDescriptor);

  assert.equal(fdFilestatGet(1, 128), wasiErrno.success);
  assert.equal(new Uint8Array(addressSpace.buffer, 144, 1)[0], 2);
  assert.deepEqual(Array.from(new Uint8Array(addressSpace.buffer, 128, 16)), new Array(16).fill(0));
  assert.deepEqual(Array.from(new Uint8Array(addressSpace.buffer, 145, 47)), new Array(47).fill(0));
  assert.equal(fdFilestatGet(9, 128), wasiErrno.badFileDescriptor);
});

test("WasiPreview1Host does not report directories for standard file descriptors", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const fdReaddir = wasiServiceFunction<[number, number, number, bigint, number]>(runtimeServices, "fd_readdir");

  writeUInt32(addressSpace, 24, 99);

  assert.equal(fdReaddir(0, 128, 32, 0n, 24), wasiErrno.notDirectory);
  assert.equal(readUInt32(addressSpace, 24), 99);
  assert.equal(fdReaddir(9, 128, 32, 0n, 24), wasiErrno.badFileDescriptor);
});

test("WasiPreview1Host exposes no preopened filesystem", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const fdPrestatGet = wasiServiceFunction<[number, number]>(runtimeServices, "fd_prestat_get");
  const pathOpen = wasiServiceFunction<[number, number, number, number, number, bigint, bigint, number, number]>(runtimeServices, "path_open");

  assert.equal(fdPrestatGet(3, 64), wasiErrno.badFileDescriptor);
  assert.equal(pathOpen(3, 0, 128, 4, 0, 0n, 0n, 0, 64), wasiErrno.noEntry);
});

test("WasiPreview1Host separates realtime and monotonic clocks", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const clockTimeGet = wasiServiceFunction<[number, bigint, number]>(
    runtimeServices,
    "clock_time_get"
  );

  assert.equal(clockTimeGet(0, 0n, 32), wasiErrno.success);
  const realtime = readUInt64(addressSpace, 32);
  assert.ok(realtime > 1_000_000_000_000_000_000n);

  assert.equal(clockTimeGet(1, 0n, 40), wasiErrno.success);
  const firstMonotonic = readUInt64(addressSpace, 40);
  assert.equal(clockTimeGet(1, 0n, 48), wasiErrno.success);
  const secondMonotonic = readUInt64(addressSpace, 48);
  assert.ok(secondMonotonic >= firstMonotonic);
  assert.ok(secondMonotonic < realtime);
});

test("WasiPreview1Host rejects unsupported clocks and polling", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const clockTimeGet = wasiServiceFunction<[number, bigint, number]>(
    runtimeServices,
    "clock_time_get"
  );
  const pollOneoff = wasiServiceFunction<[number, number, number, number]>(
    runtimeServices,
    "poll_oneoff"
  );

  writeUInt64(addressSpace, 32, 99n);
  writeUInt32(addressSpace, 48, 99);
  assert.equal(clockTimeGet(99, 0n, 32), wasiErrno.invalidArgument);
  assert.equal(readUInt64(addressSpace, 32), 99n);
  assert.equal(pollOneoff(64, 128, 1, 48), wasiErrno.notSupported);
  assert.equal(readUInt32(addressSpace, 48), 99);
});

test("WasiPreview1Host fills random bytes and rejects invalid output ranges", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const invalidPointer = addressSpace.buffer.byteLength - 2;
  const argsSizesGet = wasiServiceFunction<[number, number]>(
    runtimeServices,
    "args_sizes_get"
  );
  const environSizesGet = wasiServiceFunction<[number, number]>(
    runtimeServices,
    "environ_sizes_get"
  );
  const clockResolutionGet = wasiServiceFunction<[number, number]>(
    runtimeServices,
    "clock_res_get"
  );
  const clockTimeGet = wasiServiceFunction<[number, bigint, number]>(
    runtimeServices,
    "clock_time_get"
  );
  const fdFdstatGet = wasiServiceFunction<[number, number]>(
    runtimeServices,
    "fd_fdstat_get"
  );
  const fdFilestatGet = wasiServiceFunction<[number, number]>(
    runtimeServices,
    "fd_filestat_get"
  );
  const randomGet = wasiServiceFunction<[number, number]>(
    runtimeServices,
    "random_get"
  );
  const randomDestination = 64;
  const randomByteCount = 32;

  assert.equal(
    randomGet(randomDestination, randomByteCount),
    wasiErrno.success
  );
  const randomBytes = new Uint8Array(
    addressSpace.buffer,
    randomDestination,
    randomByteCount
  );
  assert.ok(randomBytes.some((byte) => byte !== 0));

  assert.equal(argsSizesGet(invalidPointer, 32), wasiErrno.fault);
  assert.equal(environSizesGet(32, invalidPointer), wasiErrno.fault);
  assert.equal(clockResolutionGet(0, invalidPointer), wasiErrno.fault);
  assert.equal(clockTimeGet(0, 0n, invalidPointer), wasiErrno.fault);
  assert.equal(fdFdstatGet(0, invalidPointer), wasiErrno.fault);
  assert.equal(fdFilestatGet(1, invalidPointer), wasiErrno.fault);
  assert.equal(randomGet(invalidPointer, 4), wasiErrno.fault);
});

test("WasiPreview1Host reports unsupported stream positioning operations", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const unsupportedOperations = [
    "fd_fdstat_set_flags",
    "fd_filestat_set_size",
    "fd_filestat_set_times",
    "fd_pread",
    "fd_pwrite",
    "fd_seek",
    "fd_sync",
    "fd_tell",
  ] as const;

  for (const operation of unsupportedOperations) {
    const service = wasiServiceFunction<[number]>(runtimeServices, operation);
    assert.equal(service(1), wasiErrno.notSupported);
    assert.equal(service(9), wasiErrno.badFileDescriptor);
  }
});

test("WasiPreview1Host keeps closed descriptors closed", () => {
  const addressSpace = new WebAssembly.Memory({ initial: 1 });
  const runtimeServices = wasiServicesForTesting(addressSpace);
  const fdClose = wasiServiceFunction<[number]>(runtimeServices, "fd_close");
  const fdWrite = wasiServiceFunction<[number, number, number, number]>(
    runtimeServices,
    "fd_write"
  );
  const fdFdstatGet = wasiServiceFunction<[number, number]>(
    runtimeServices,
    "fd_fdstat_get"
  );

  assert.equal(fdClose(1), wasiErrno.success);
  assert.equal(fdClose(1), wasiErrno.badFileDescriptor);
  assert.equal(fdWrite(1, 32, 0, 24), wasiErrno.badFileDescriptor);
  assert.equal(fdFdstatGet(1, 64), wasiErrno.badFileDescriptor);
});

function wasiServiceFunction<Args extends unknown[]>(
  runtimeServices: Record<string, WebAssembly.ImportValue>,
  name: string
): (...args: Args) => number {
  const value = runtimeServices[name];
  assert.equal(typeof value, "function");
  return value as (...args: Args) => number;
}

function wasiServicesForTesting(
  addressSpace: WebAssembly.Memory,
  options: {
    maximumIovecCount?: number;
    maximumIovecBytes?: number;
  } = {}
): Record<string, WebAssembly.ImportValue> {
  const adapter = new WasiPreview1Host(options);
  adapter.attachRuntime({
    endpoints: { memory: addressSpace },
  });
  return adapter.services;
}

function readUInt32(addressSpace: WebAssembly.Memory, pointer: number): number {
  return new DataView(addressSpace.buffer).getUint32(pointer, true);
}

function readUInt64(addressSpace: WebAssembly.Memory, pointer: number): bigint {
  return new DataView(addressSpace.buffer).getBigUint64(pointer, true);
}

function writeUInt32(addressSpace: WebAssembly.Memory, pointer: number, value: number): void {
  new DataView(addressSpace.buffer).setUint32(pointer, value, true);
}

function writeUInt64(
  addressSpace: WebAssembly.Memory,
  pointer: number,
  value: bigint
): void {
  new DataView(addressSpace.buffer).setBigUint64(pointer, value, true);
}
