import { DatabaseStorageHost } from "./DatabaseStorageHost";

export type DatabaseHostDispatcher = {
  dispatchBytes(bytes: Uint8Array): Uint8Array;
};

type DatabaseRuntimeExports = {
  database_alloc(byteCount: number): number;
  database_dealloc(pointer: number, byteCount: number): void;
  database_dispatch(pointer: number, length: number): number;
  memory: WebAssembly.Memory;
};

type WasmModuleInput = ArrayBuffer | ArrayBufferView | WebAssembly.Module;

export const wasiErrno = Object.freeze({
  success: 0,
  badFileDescriptor: 8,
  io: 29,
  noEntry: 44,
  notDirectory: 54,
  notSupported: 58,
} as const);

const wasiFileType = Object.freeze({
  characterDevice: 2,
} as const);

export class WasiPreview1Host {
  private readonly memoryProvider: () => WebAssembly.Memory;

  constructor(memoryProvider: () => WebAssembly.Memory) {
    this.memoryProvider = memoryProvider;
  }

  imports(): Record<string, WebAssembly.ImportValue> {
    return {
      args_get: () => wasiErrno.success,
      args_sizes_get: (argcPointer: number, argvBufferSizePointer: number) => {
        this.writeUInt32(argcPointer, 0);
        this.writeUInt32(argvBufferSizePointer, 0);
        return wasiErrno.success;
      },
      environ_get: () => wasiErrno.success,
      environ_sizes_get: (countPointer: number, bufferSizePointer: number) => {
        this.writeUInt32(countPointer, 0);
        this.writeUInt32(bufferSizePointer, 0);
        return wasiErrno.success;
      },
      clock_res_get: (_clockId: number, resolutionPointer: number) => {
        this.writeUInt64(resolutionPointer, 1_000_000n);
        return wasiErrno.success;
      },
      clock_time_get: (_clockId: number, _precision: bigint, timePointer: number) => {
        this.writeUInt64(timePointer, BigInt(Date.now()) * 1_000_000n);
        return wasiErrno.success;
      },
      fd_close: (fileDescriptor: number) => this.fdClose(fileDescriptor),
      fd_fdstat_get: (fileDescriptor: number, statPointer: number) => this.fdFdstatGet(fileDescriptor, statPointer),
      fd_fdstat_set_flags: (fileDescriptor: number) => this.stdFileDescriptorResult(fileDescriptor),
      fd_filestat_get: (fileDescriptor: number, statPointer: number) => this.fdFilestatGet(fileDescriptor, statPointer),
      fd_filestat_set_size: (fileDescriptor: number) => this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_filestat_set_times: (fileDescriptor: number) => this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_pread: (fileDescriptor: number, _iovsPointer: number, _iovsLength: number, _offset: bigint, bytesReadPointer: number) =>
        this.fdRead(fileDescriptor, bytesReadPointer),
      fd_prestat_dir_name: () => wasiErrno.badFileDescriptor,
      fd_prestat_get: () => wasiErrno.badFileDescriptor,
      fd_pwrite: (fileDescriptor: number, iovsPointer: number, iovsLength: number, _offset: bigint, bytesWrittenPointer: number) =>
        this.fdWrite(fileDescriptor, iovsPointer, iovsLength, bytesWrittenPointer),
      fd_read: (fileDescriptor: number, _iovsPointer: number, _iovsLength: number, bytesReadPointer: number) =>
        this.fdRead(fileDescriptor, bytesReadPointer),
      fd_readdir: (fileDescriptor: number) => this.fdReaddir(fileDescriptor),
      fd_seek: (fileDescriptor: number, _offset: bigint, _whence: number, newOffsetPointer: number) =>
        this.fdSeek(fileDescriptor, newOffsetPointer),
      fd_sync: (fileDescriptor: number) => this.stdFileDescriptorResult(fileDescriptor),
      fd_tell: (fileDescriptor: number, offsetPointer: number) => this.fdSeek(fileDescriptor, offsetPointer),
      fd_write: (fileDescriptor: number, iovsPointer: number, iovsLength: number, bytesWrittenPointer: number) =>
        this.fdWrite(fileDescriptor, iovsPointer, iovsLength, bytesWrittenPointer),
      path_create_directory: () => wasiErrno.noEntry,
      path_filestat_get: () => wasiErrno.noEntry,
      path_filestat_set_times: () => wasiErrno.noEntry,
      path_link: () => wasiErrno.noEntry,
      path_open: () => wasiErrno.noEntry,
      path_readlink: () => wasiErrno.noEntry,
      path_remove_directory: () => wasiErrno.noEntry,
      path_rename: () => wasiErrno.noEntry,
      path_symlink: () => wasiErrno.noEntry,
      path_unlink_file: () => wasiErrno.noEntry,
      poll_oneoff: (_inputPointer: number, _outputPointer: number, _subscriptionCount: number, eventsPointer: number) => {
        this.writeUInt32(eventsPointer, 0);
        return wasiErrno.success;
      },
      proc_exit: (code: number) => {
        throw new Error(`WASM proc_exit(${code})`);
      },
      random_get: (pointer: number, length: number) => this.randomGet(pointer, length),
    };
  }

  private fdClose(fileDescriptor: number): number {
    return this.isStandardFileDescriptor(fileDescriptor) ? wasiErrno.success : wasiErrno.badFileDescriptor;
  }

  private fdFdstatGet(fileDescriptor: number, statPointer: number): number {
    if (!this.isStandardFileDescriptor(fileDescriptor)) {
      return wasiErrno.badFileDescriptor;
    }
    this.zeroMemory(statPointer, 24);
    this.bytes(statPointer, 24)[0] = wasiFileType.characterDevice;
    return wasiErrno.success;
  }

  private fdFilestatGet(fileDescriptor: number, statPointer: number): number {
    if (!this.isStandardFileDescriptor(fileDescriptor)) {
      return wasiErrno.badFileDescriptor;
    }
    this.zeroMemory(statPointer, 64);
    this.bytes(statPointer + 16, 1)[0] = wasiFileType.characterDevice;
    return wasiErrno.success;
  }

  private fdRead(fileDescriptor: number, bytesReadPointer: number): number {
    if (fileDescriptor !== 0) {
      return wasiErrno.badFileDescriptor;
    }
    this.writeUInt32(bytesReadPointer, 0);
    return wasiErrno.success;
  }

  private fdReaddir(fileDescriptor: number): number {
    return this.isStandardFileDescriptor(fileDescriptor) ? wasiErrno.notDirectory : wasiErrno.badFileDescriptor;
  }

  private fdSeek(fileDescriptor: number, offsetPointer: number): number {
    if (!this.isStandardFileDescriptor(fileDescriptor)) {
      return wasiErrno.badFileDescriptor;
    }
    this.writeUInt64(offsetPointer, 0n);
    return wasiErrno.success;
  }

  private fdWrite(fileDescriptor: number, iovsPointer: number, iovsLength: number, bytesWrittenPointer: number): number {
    if (fileDescriptor !== 1 && fileDescriptor !== 2) {
      return wasiErrno.badFileDescriptor;
    }
    this.writeUInt32(bytesWrittenPointer, this.iovByteLength(iovsPointer, iovsLength));
    return wasiErrno.success;
  }

  private randomGet(pointer: number, length: number): number {
    if (globalThis.crypto?.getRandomValues === undefined) {
      return wasiErrno.io;
    }
    const randomBytes = new Uint8Array(length);
    globalThis.crypto.getRandomValues(randomBytes);
    this.bytes(pointer, length).set(randomBytes);
    return wasiErrno.success;
  }

  private stdFileDescriptorResult(fileDescriptor: number): number {
    return this.isStandardFileDescriptor(fileDescriptor) ? wasiErrno.success : wasiErrno.badFileDescriptor;
  }

  private unsupportedStandardFileDescriptorResult(fileDescriptor: number): number {
    return this.isStandardFileDescriptor(fileDescriptor) ? wasiErrno.notSupported : wasiErrno.badFileDescriptor;
  }

  private isStandardFileDescriptor(fileDescriptor: number): boolean {
    return fileDescriptor === 0 || fileDescriptor === 1 || fileDescriptor === 2;
  }

  private iovByteLength(iovsPointer: number, iovsLength: number): number {
    let total = 0;
    for (let index = 0; index < iovsLength; index += 1) {
      total += this.readUInt32(iovsPointer + index * 8 + 4);
    }
    return total;
  }

  private zeroMemory(pointer: number, length: number): void {
    this.bytes(pointer, length).fill(0);
  }

  private readUInt32(pointer: number): number {
    const view = this.bytes(pointer, 4);
    return ((view[0] ?? 0)
      | ((view[1] ?? 0) << 8)
      | ((view[2] ?? 0) << 16)
      | ((view[3] ?? 0) << 24)) >>> 0;
  }

  private writeUInt32(pointer: number, value: number): void {
    const view = this.bytes(pointer, 4);
    view[0] = value & 0xff;
    view[1] = (value >>> 8) & 0xff;
    view[2] = (value >>> 16) & 0xff;
    view[3] = (value >>> 24) & 0xff;
  }

  private writeUInt64(pointer: number, value: bigint): void {
    let remaining = BigInt.asUintN(64, value);
    const view = this.bytes(pointer, 8);
    for (let index = 0; index < 8; index += 1) {
      view[index] = Number(remaining & 0xffn);
      remaining >>= 8n;
    }
  }

  private bytes(pointer: number, length: number): Uint8Array {
    return new Uint8Array(this.memoryProvider().buffer, pointer, length);
  }
}

export class DatabaseWasmBridge {
  private readonly host: DatabaseHostDispatcher;
  private instance: WebAssembly.Instance | null;

  static async instantiate(wasmModule: WasmModuleInput, host: DatabaseHostDispatcher): Promise<DatabaseWasmBridge> {
    const bridge = new DatabaseWasmBridge(host);
    const wasi = new WasiPreview1Host(() => bridge.memory());
    const imports: WebAssembly.Imports = {
      database_host: {
        dispatch: (pointer: number, length: number) => bridge.dispatchFromWasm(pointer, length),
      },
      wasi_snapshot_preview1: wasi.imports(),
    };
    const module = wasmModule instanceof WebAssembly.Module
      ? wasmModule
      : await WebAssembly.compile(toArrayBuffer(wasmModule));
    const instance = await WebAssembly.instantiate(module, imports);
    bridge.instance = instance;
    return bridge;
  }

  constructor(host: DatabaseHostDispatcher) {
    this.host = host instanceof DatabaseStorageHost ? host : host;
    this.instance = null;
  }

  dispatch(bytes: ArrayBuffer | ArrayBufferView): Uint8Array {
    const exports = this.requireExports();
    const requestBytes = bytes instanceof Uint8Array ? bytes : toUint8Array(bytes);
    const requestPointer = exports.database_alloc(requestBytes.length);
    this.writeBytes(requestPointer, requestBytes);
    try {
      const framePointer = exports.database_dispatch(requestPointer, requestBytes.length);
      return this.takeFrame(framePointer);
    } finally {
      exports.database_dealloc(requestPointer, requestBytes.length);
    }
  }

  dispatchFromWasm(pointer: number, length: number): number {
    const response = this.host.dispatchBytes(this.readBytes(pointer, length));
    return this.makeFrame(response);
  }

  makeFrame(payload: Uint8Array): number {
    const exports = this.requireExports();
    const frameLength = payload.length + 4;
    const pointer = exports.database_alloc(frameLength);
    const view = new Uint8Array(this.memory().buffer, pointer, frameLength);
    view[0] = payload.length & 0xff;
    view[1] = (payload.length >>> 8) & 0xff;
    view[2] = (payload.length >>> 16) & 0xff;
    view[3] = (payload.length >>> 24) & 0xff;
    view.set(payload, 4);
    return pointer;
  }

  takeFrame(pointer: number): Uint8Array {
    if (pointer === 0) {
      throw new Error("WASM dispatch returned no response frame");
    }
    const exports = this.requireExports();
    const header = new Uint8Array(this.memory().buffer, pointer, 4);
    const length = ((header[0] ?? 0)
      | ((header[1] ?? 0) << 8)
      | ((header[2] ?? 0) << 16)
      | ((header[3] ?? 0) << 24)) >>> 0;
    const payload = new Uint8Array(this.memory().buffer, pointer + 4, length).slice();
    exports.database_dealloc(pointer, length + 4);
    return payload;
  }

  readBytes(pointer: number, length: number): Uint8Array {
    return new Uint8Array(this.memory().buffer, pointer, length).slice();
  }

  writeBytes(pointer: number, bytes: Uint8Array): void {
    if (bytes.length === 0) {
      return;
    }
    new Uint8Array(this.memory().buffer, pointer, bytes.length).set(bytes);
  }

  memory(): WebAssembly.Memory {
    return this.requireExports().memory;
  }

  requireExports(): DatabaseRuntimeExports {
    if (this.instance === null) {
      throw new Error("WASM bridge is not initialized");
    }
    const exports = this.instance.exports;
    const databaseAlloc = exports.database_alloc;
    const databaseDealloc = exports.database_dealloc;
    const databaseDispatch = exports.database_dispatch;
    const memory = exports.memory;
    if (typeof databaseAlloc !== "function") {
      throw new Error("WASM instance does not export database_alloc");
    }
    if (typeof databaseDealloc !== "function") {
      throw new Error("WASM instance does not export database_dealloc");
    }
    if (typeof databaseDispatch !== "function") {
      throw new Error("WASM instance does not export database_dispatch");
    }
    if (!(memory instanceof WebAssembly.Memory)) {
      throw new Error("WASM instance does not export memory");
    }
    return {
      database_alloc: databaseAlloc as (byteCount: number) => number,
      database_dealloc: databaseDealloc as (pointer: number, byteCount: number) => void,
      database_dispatch: databaseDispatch as (pointer: number, length: number) => number,
      memory,
    };
  }
}

function toUint8Array(bytes: ArrayBuffer | ArrayBufferView): Uint8Array {
  if (bytes instanceof ArrayBuffer) {
    return new Uint8Array(bytes);
  }
  return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

function toArrayBuffer(bytes: ArrayBuffer | ArrayBufferView): ArrayBuffer {
  if (bytes instanceof ArrayBuffer) {
    return bytes;
  }
  const view = toUint8Array(bytes);
  return view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength) as ArrayBuffer;
}
