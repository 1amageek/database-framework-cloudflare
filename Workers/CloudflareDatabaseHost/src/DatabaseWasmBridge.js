import { DatabaseStorageHost } from "./DatabaseStorageHost.js";

export class DatabaseWasmBridge {
  static async instantiate(wasmModule, host) {
    const bridge = new DatabaseWasmBridge(host);
    const instance = await WebAssembly.instantiate(wasmModule, {
      database_host: {
        dispatch: (pointer, length) => bridge.dispatchFromWasm(pointer, length),
      },
      wasi_snapshot_preview1: {
        args_get: () => 0,
        args_sizes_get: (argcPointer, argvBufferSizePointer) => {
          bridge.writeUInt32(argcPointer, 0);
          bridge.writeUInt32(argvBufferSizePointer, 0);
          return 0;
        },
        environ_get: () => 0,
        environ_sizes_get: (countPointer, bufferSizePointer) => {
          bridge.writeUInt32(countPointer, 0);
          bridge.writeUInt32(bufferSizePointer, 0);
          return 0;
        },
        fd_close: () => 0,
        fd_fdstat_get: () => 0,
        fd_prestat_dir_name: () => 0,
        fd_prestat_get: () => 0,
        fd_read: () => 0,
        fd_seek: () => 0,
        fd_write: () => 0,
        path_filestat_get: () => 44,
        path_open: () => 44,
        path_readlink: () => 44,
        proc_exit: (code) => {
          throw new Error(`WASM proc_exit(${code})`);
        },
        random_get: (pointer, length) => {
          bridge.fillRandom(pointer, length);
          return 0;
        },
      },
    });
    bridge.instance = instance instanceof WebAssembly.Instance ? instance : instance.instance;
    return bridge;
  }

  constructor(host) {
    this.host = host instanceof DatabaseStorageHost ? host : host;
    this.instance = null;
  }

  dispatch(bytes) {
    const exports = this.requireExports();
    const requestBytes = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    const requestPointer = exports.database_alloc(requestBytes.length);
    this.writeBytes(requestPointer, requestBytes);
    try {
      const framePointer = exports.database_dispatch(requestPointer, requestBytes.length);
      return this.takeFrame(framePointer);
    } finally {
      exports.database_dealloc(requestPointer, requestBytes.length);
    }
  }

  dispatchFromWasm(pointer, length) {
    const response = this.host.dispatchBytes(this.readBytes(pointer, length));
    return this.makeFrame(response);
  }

  makeFrame(payload) {
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

  takeFrame(pointer) {
    if (pointer === 0) {
      throw new Error("WASM dispatch returned no response frame");
    }
    const exports = this.requireExports();
    const header = new Uint8Array(this.memory().buffer, pointer, 4);
    const length = (header[0]
      | (header[1] << 8)
      | (header[2] << 16)
      | (header[3] << 24)) >>> 0;
    const payload = new Uint8Array(this.memory().buffer, pointer + 4, length).slice();
    exports.database_dealloc(pointer, length + 4);
    return payload;
  }

  readBytes(pointer, length) {
    return new Uint8Array(this.memory().buffer, pointer, length).slice();
  }

  writeBytes(pointer, bytes) {
    if (bytes.length === 0) {
      return;
    }
    new Uint8Array(this.memory().buffer, pointer, bytes.length).set(bytes);
  }

  writeUInt32(pointer, value) {
    if (this.instance === null) {
      return;
    }
    const view = new Uint8Array(this.memory().buffer, pointer, 4);
    view[0] = value & 0xff;
    view[1] = (value >>> 8) & 0xff;
    view[2] = (value >>> 16) & 0xff;
    view[3] = (value >>> 24) & 0xff;
  }

  fillRandom(pointer, length) {
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

  memory() {
    const memory = this.requireExports().memory;
    if (!(memory instanceof WebAssembly.Memory)) {
      throw new Error("WASM instance does not export memory");
    }
    return memory;
  }

  requireExports() {
    if (this.instance === null) {
      throw new Error("WASM bridge is not initialized");
    }
    return this.instance.exports;
  }
}
