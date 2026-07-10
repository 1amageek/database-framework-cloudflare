import assert from "node:assert/strict";
import test from "node:test";
import { WasiPreview1Host, wasiErrno } from "../src/DatabaseWasmBridge";

test("WasiPreview1Host writes fd_write byte counts from iovec lengths", () => {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const imports = new WasiPreview1Host(() => memory).imports();
  const fdWrite = wasiFunction<[number, number, number, number]>(imports, "fd_write");

  writeUInt32(memory, 32, 256);
  writeUInt32(memory, 36, 5);
  writeUInt32(memory, 40, 512);
  writeUInt32(memory, 44, 7);

  assert.equal(fdWrite(1, 32, 2, 24), wasiErrno.success);
  assert.equal(readUInt32(memory, 24), 12);
});

test("WasiPreview1Host rejects writes to non-output file descriptors", () => {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const imports = new WasiPreview1Host(() => memory).imports();
  const fdWrite = wasiFunction<[number, number, number, number]>(imports, "fd_write");

  writeUInt32(memory, 24, 99);

  assert.equal(fdWrite(9, 32, 0, 24), wasiErrno.badFileDescriptor);
  assert.equal(readUInt32(memory, 24), 99);
});

test("WasiPreview1Host reports empty stdin reads through nread", () => {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const imports = new WasiPreview1Host(() => memory).imports();
  const fdRead = wasiFunction<[number, number, number, number]>(imports, "fd_read");

  writeUInt32(memory, 24, 99);

  assert.equal(fdRead(0, 32, 1, 24), wasiErrno.success);
  assert.equal(readUInt32(memory, 24), 0);
  assert.equal(fdRead(1, 32, 1, 24), wasiErrno.badFileDescriptor);
});

test("WasiPreview1Host writes fdstat for standard file descriptors", () => {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const imports = new WasiPreview1Host(() => memory).imports();
  const fdFdstatGet = wasiFunction<[number, number]>(imports, "fd_fdstat_get");
  const fdFilestatGet = wasiFunction<[number, number]>(imports, "fd_filestat_get");

  new Uint8Array(memory.buffer, 64, 24).fill(0xff);
  new Uint8Array(memory.buffer, 128, 64).fill(0xff);

  assert.equal(fdFdstatGet(2, 64), wasiErrno.success);
  assert.equal(new Uint8Array(memory.buffer, 64, 1)[0], 2);
  assert.deepEqual(Array.from(new Uint8Array(memory.buffer, 65, 23)), new Array(23).fill(0));
  assert.equal(fdFdstatGet(9, 64), wasiErrno.badFileDescriptor);

  assert.equal(fdFilestatGet(1, 128), wasiErrno.success);
  assert.equal(new Uint8Array(memory.buffer, 144, 1)[0], 2);
  assert.deepEqual(Array.from(new Uint8Array(memory.buffer, 128, 16)), new Array(16).fill(0));
  assert.deepEqual(Array.from(new Uint8Array(memory.buffer, 145, 47)), new Array(47).fill(0));
  assert.equal(fdFilestatGet(9, 128), wasiErrno.badFileDescriptor);
});

test("WasiPreview1Host does not report directories for standard file descriptors", () => {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const imports = new WasiPreview1Host(() => memory).imports();
  const fdReaddir = wasiFunction<[number, number, number, bigint, number]>(imports, "fd_readdir");

  writeUInt32(memory, 24, 99);

  assert.equal(fdReaddir(0, 128, 32, 0n, 24), wasiErrno.notDirectory);
  assert.equal(readUInt32(memory, 24), 99);
  assert.equal(fdReaddir(9, 128, 32, 0n, 24), wasiErrno.badFileDescriptor);
});

test("WasiPreview1Host exposes no preopened filesystem", () => {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const imports = new WasiPreview1Host(() => memory).imports();
  const fdPrestatGet = wasiFunction<[number, number]>(imports, "fd_prestat_get");
  const pathOpen = wasiFunction<[number, number, number, number, number, bigint, bigint, number, number]>(imports, "path_open");

  assert.equal(fdPrestatGet(3, 64), wasiErrno.badFileDescriptor);
  assert.equal(pathOpen(3, 0, 128, 4, 0, 0n, 0n, 0, 64), wasiErrno.noEntry);
});

function wasiFunction<Args extends unknown[]>(
  imports: Record<string, WebAssembly.ImportValue>,
  name: string
): (...args: Args) => number {
  const value = imports[name];
  assert.equal(typeof value, "function");
  return value as (...args: Args) => number;
}

function readUInt32(memory: WebAssembly.Memory, pointer: number): number {
  return new DataView(memory.buffer).getUint32(pointer, true);
}

function writeUInt32(memory: WebAssembly.Memory, pointer: number, value: number): void {
  new DataView(memory.buffer).setUint32(pointer, value, true);
}
