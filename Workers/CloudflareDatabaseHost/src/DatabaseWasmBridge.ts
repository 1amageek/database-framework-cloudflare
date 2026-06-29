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
const wasiNoEntry = 44;

export class DatabaseWasmBridge {
  private readonly host: DatabaseHostDispatcher;
  private instance: WebAssembly.Instance | null;

  static async instantiate(wasmModule: WasmModuleInput, host: DatabaseHostDispatcher): Promise<DatabaseWasmBridge> {
    const bridge = new DatabaseWasmBridge(host);
    const imports: WebAssembly.Imports = {
      database_host: {
        dispatch: (pointer: number, length: number) => bridge.dispatchFromWasm(pointer, length),
      },
      wasi_snapshot_preview1: {
        args_get: () => 0,
        args_sizes_get: (argcPointer: number, argvBufferSizePointer: number) => {
          bridge.writeUInt32(argcPointer, 0);
          bridge.writeUInt32(argvBufferSizePointer, 0);
          return 0;
        },
        environ_get: () => 0,
        environ_sizes_get: (countPointer: number, bufferSizePointer: number) => {
          bridge.writeUInt32(countPointer, 0);
          bridge.writeUInt32(bufferSizePointer, 0);
          return 0;
        },
        clock_res_get: (_clockId: number, resolutionPointer: number) => {
          bridge.writeUInt64(resolutionPointer, 1_000_000n);
          return 0;
        },
        clock_time_get: (_clockId: number, _precision: bigint, timePointer: number) => {
          bridge.writeUInt64(timePointer, BigInt(Date.now()) * 1_000_000n);
          return 0;
        },
        fd_close: () => 0,
        fd_fdstat_get: () => 0,
        fd_fdstat_set_flags: () => 0,
        fd_filestat_get: () => wasiNoEntry,
        fd_filestat_set_size: () => wasiNoEntry,
        fd_filestat_set_times: () => wasiNoEntry,
        fd_pread: () => 0,
        fd_prestat_dir_name: () => 0,
        fd_prestat_get: () => 0,
        fd_pwrite: () => 0,
        fd_read: () => 0,
        fd_readdir: () => 0,
        fd_seek: () => 0,
        fd_sync: () => 0,
        fd_tell: (_fd: number, offsetPointer: number) => {
          bridge.writeUInt64(offsetPointer, 0n);
          return 0;
        },
        fd_write: () => 0,
        path_create_directory: () => wasiNoEntry,
        path_filestat_get: () => wasiNoEntry,
        path_filestat_set_times: () => wasiNoEntry,
        path_link: () => wasiNoEntry,
        path_open: () => wasiNoEntry,
        path_readlink: () => wasiNoEntry,
        path_remove_directory: () => wasiNoEntry,
        path_rename: () => wasiNoEntry,
        path_symlink: () => wasiNoEntry,
        path_unlink_file: () => wasiNoEntry,
        poll_oneoff: (_inputPointer: number, _outputPointer: number, _subscriptionCount: number, eventsPointer: number) => {
          bridge.writeUInt32(eventsPointer, 0);
          return 0;
        },
        proc_exit: (code: number) => {
          throw new Error(`WASM proc_exit(${code})`);
        },
        random_get: (pointer: number, length: number) => {
          bridge.fillRandom(pointer, length);
          return 0;
        },
      },
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

  writeUInt32(pointer: number, value: number): void {
    if (this.instance === null) {
      return;
    }
    const view = new Uint8Array(this.memory().buffer, pointer, 4);
    view[0] = value & 0xff;
    view[1] = (value >>> 8) & 0xff;
    view[2] = (value >>> 16) & 0xff;
    view[3] = (value >>> 24) & 0xff;
  }

  writeUInt64(pointer: number, value: bigint): void {
    if (this.instance === null) {
      return;
    }
    let remaining = BigInt.asUintN(64, value);
    const view = new Uint8Array(this.memory().buffer, pointer, 8);
    for (let index = 0; index < 8; index += 1) {
      view[index] = Number(remaining & 0xffn);
      remaining >>= 8n;
    }
  }

  fillRandom(pointer: number, length: number): void {
    if (this.instance === null) {
      return;
    }
    const view = new Uint8Array(this.memory().buffer, pointer, length);
    if (globalThis.crypto?.getRandomValues !== undefined) {
      globalThis.crypto.getRandomValues(view);
      return;
    }
    view.fill(0);
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
