import type { DatabaseRuntimeInstance } from "./DatabaseRuntimeInstance";

export const wasiErrno = Object.freeze({
  success: 0,
  argumentListTooLong: 1,
  badFileDescriptor: 8,
  fault: 21,
  invalidArgument: 28,
  io: 29,
  noEntry: 44,
  notDirectory: 54,
  notSupported: 58,
} as const);

const wasiFileType = Object.freeze({
  characterDevice: 2,
} as const);

const wasiClock = Object.freeze({
  realtime: 0,
  monotonic: 1,
} as const);

const maximumSupportedIovecCount = 65_536;
const maximumSupportedIovecBytes = 16 * 1024 * 1024;

type IovecValidation =
  | { byteLength: number; error: null }
  | { byteLength: null; error: number };

export class WasiPreview1Host {
  readonly services: Record<string, WebAssembly.ImportValue>;

  private runtimeInstance: DatabaseRuntimeInstance | null = null;
  private lastMonotonicNanoseconds = 0n;
  private readonly closedFileDescriptors = new Set<number>();
  private readonly maximumIovecCount: number;
  private readonly maximumIovecBytes: number;

  constructor(options: {
    maximumIovecCount?: number;
    maximumIovecBytes?: number;
  } = {}) {
    this.maximumIovecCount = validateLimit(
      options.maximumIovecCount ?? 1_024,
      maximumSupportedIovecCount,
      "maximumIovecCount"
    );
    this.maximumIovecBytes = validateLimit(
      options.maximumIovecBytes ?? 1024 * 1024,
      maximumSupportedIovecBytes,
      "maximumIovecBytes"
    );
    this.services = {
      args_get: () => wasiErrno.success,
      args_sizes_get: (
        argcPointer: number,
        argvBufferSizePointer: number
      ) => this.writeEmptySequenceSizes(
        argcPointer,
        argvBufferSizePointer
      ),
      environ_get: () => wasiErrno.success,
      environ_sizes_get: (
        countPointer: number,
        bufferSizePointer: number
      ) => this.writeEmptySequenceSizes(
        countPointer,
        bufferSizePointer
      ),
      clock_res_get: (clockId: number, resolutionPointer: number) =>
        this.clockResolution(clockId, resolutionPointer),
      clock_time_get: (
        clockId: number,
        _precision: bigint,
        timePointer: number
      ) => this.clockTime(clockId, timePointer),
      fd_close: (fileDescriptor: number) => this.fdClose(fileDescriptor),
      fd_fdstat_get: (fileDescriptor: number, statPointer: number) =>
        this.fdFdstatGet(fileDescriptor, statPointer),
      fd_fdstat_set_flags: (fileDescriptor: number) =>
        this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_filestat_get: (fileDescriptor: number, statPointer: number) =>
        this.fdFilestatGet(fileDescriptor, statPointer),
      fd_filestat_set_size: (fileDescriptor: number) =>
        this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_filestat_set_times: (fileDescriptor: number) =>
        this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_pread: (fileDescriptor: number) =>
        this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_prestat_dir_name: () => wasiErrno.badFileDescriptor,
      fd_prestat_get: () => wasiErrno.badFileDescriptor,
      fd_pwrite: (fileDescriptor: number) =>
        this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_read: (
        fileDescriptor: number,
        iovsPointer: number,
        iovsLength: number,
        bytesReadPointer: number
      ) => this.fdRead(
        fileDescriptor,
        iovsPointer,
        iovsLength,
        bytesReadPointer
      ),
      fd_readdir: (fileDescriptor: number) => this.fdReaddir(fileDescriptor),
      fd_seek: (fileDescriptor: number) =>
        this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_sync: (fileDescriptor: number) =>
        this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_tell: (fileDescriptor: number) =>
        this.unsupportedStandardFileDescriptorResult(fileDescriptor),
      fd_write: (
        fileDescriptor: number,
        iovsPointer: number,
        iovsLength: number,
        bytesWrittenPointer: number
      ) => this.fdWrite(
        fileDescriptor,
        iovsPointer,
        iovsLength,
        bytesWrittenPointer
      ),
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
      poll_oneoff: (
        _inputPointer: number,
        _outputPointer: number,
        _subscriptionCount: number,
        _eventCountPointer: number
      ) => wasiErrno.notSupported,
      proc_exit: (code: number) => {
        throw new Error(`WASI proc_exit(${code})`);
      },
      random_get: (pointer: number, length: number) =>
        this.randomGet(pointer, length),
      sched_yield: () => wasiErrno.success,
    };
  }

  initializeRuntime(): void {
    const runtimeInstance = this.requireRuntimeInstance();
    const initialize = runtimeInstance.endpoints._initialize;
    if (typeof initialize === "function") {
      initialize();
    }
  }

  attachRuntime(runtimeInstance: DatabaseRuntimeInstance): void {
    const addressSpace = runtimeInstance.endpoints.memory;
    if (!(addressSpace instanceof WebAssembly.Memory)) {
      throw new Error("WASI reactor must export memory");
    }
    this.runtimeInstance = runtimeInstance;
  }

  private clockResolution(clockId: number, resolutionPointer: number): number {
    switch (clockId) {
    case wasiClock.realtime:
      if (!this.isAddressRange(resolutionPointer, 8)) {
        return wasiErrno.fault;
      }
      this.writeUInt64(resolutionPointer, 1_000_000n);
      return wasiErrno.success;
    case wasiClock.monotonic:
      if (globalThis.performance?.now === undefined) {
        return wasiErrno.notSupported;
      }
      if (!this.isAddressRange(resolutionPointer, 8)) {
        return wasiErrno.fault;
      }
      this.writeUInt64(resolutionPointer, 1_000n);
      return wasiErrno.success;
    default:
      return wasiErrno.invalidArgument;
    }
  }

  private clockTime(clockId: number, timePointer: number): number {
    switch (clockId) {
    case wasiClock.realtime:
      if (!this.isAddressRange(timePointer, 8)) {
        return wasiErrno.fault;
      }
      this.writeUInt64(timePointer, BigInt(Date.now()) * 1_000_000n);
      return wasiErrno.success;
    case wasiClock.monotonic: {
      const milliseconds = globalThis.performance?.now();
      if (milliseconds === undefined
          || !Number.isFinite(milliseconds)
          || milliseconds < 0) {
        return wasiErrno.notSupported;
      }
      if (!this.isAddressRange(timePointer, 8)) {
        return wasiErrno.fault;
      }
      const measured = BigInt(Math.floor(milliseconds * 1_000_000));
      const monotonic = measured < this.lastMonotonicNanoseconds
        ? this.lastMonotonicNanoseconds
        : measured;
      this.lastMonotonicNanoseconds = monotonic;
      this.writeUInt64(timePointer, monotonic);
      return wasiErrno.success;
    }
    default:
      return wasiErrno.invalidArgument;
    }
  }

  private fdClose(fileDescriptor: number): number {
    if (!this.isOpenStandardFileDescriptor(fileDescriptor)) {
      return wasiErrno.badFileDescriptor;
    }
    this.closedFileDescriptors.add(fileDescriptor);
    return wasiErrno.success;
  }

  private fdFdstatGet(fileDescriptor: number, statPointer: number): number {
    if (!this.isOpenStandardFileDescriptor(fileDescriptor)) {
      return wasiErrno.badFileDescriptor;
    }
    if (!this.isAddressRange(statPointer, 24)) {
      return wasiErrno.fault;
    }
    this.clearAddressRange(statPointer, 24);
    this.borrowBytes(statPointer, 24)[0] = wasiFileType.characterDevice;
    return wasiErrno.success;
  }

  private fdFilestatGet(fileDescriptor: number, statPointer: number): number {
    if (!this.isOpenStandardFileDescriptor(fileDescriptor)) {
      return wasiErrno.badFileDescriptor;
    }
    if (!this.isAddressRange(statPointer, 64)) {
      return wasiErrno.fault;
    }
    this.clearAddressRange(statPointer, 64);
    this.borrowBytes(statPointer + 16, 1)[0] = wasiFileType.characterDevice;
    return wasiErrno.success;
  }

  private fdRead(
    fileDescriptor: number,
    iovsPointer: number,
    iovsLength: number,
    bytesReadPointer: number
  ): number {
    if (fileDescriptor !== 0
        || !this.isOpenStandardFileDescriptor(fileDescriptor)) {
      return wasiErrno.badFileDescriptor;
    }
    if (!this.isAddressRange(bytesReadPointer, 4)) {
      return wasiErrno.fault;
    }
    const validation = this.validateIovecs(iovsPointer, iovsLength);
    if (validation.error !== null) {
      return validation.error;
    }
    this.writeUInt32(bytesReadPointer, 0);
    return wasiErrno.success;
  }

  private fdReaddir(fileDescriptor: number): number {
    return this.isOpenStandardFileDescriptor(fileDescriptor)
      ? wasiErrno.notDirectory
      : wasiErrno.badFileDescriptor;
  }

  private fdWrite(
    fileDescriptor: number,
    iovsPointer: number,
    iovsLength: number,
    bytesWrittenPointer: number
  ): number {
    if ((fileDescriptor !== 1 && fileDescriptor !== 2)
        || !this.isOpenStandardFileDescriptor(fileDescriptor)) {
      return wasiErrno.badFileDescriptor;
    }
    if (!this.isAddressRange(bytesWrittenPointer, 4)) {
      return wasiErrno.fault;
    }
    const validation = this.validateIovecs(iovsPointer, iovsLength);
    if (validation.error !== null) {
      return validation.error;
    }
    this.writeUInt32(bytesWrittenPointer, validation.byteLength);
    return wasiErrno.success;
  }

  private randomGet(pointer: number, length: number): number {
    if (!this.isAddressRange(pointer, length)) {
      return wasiErrno.fault;
    }
    if (globalThis.crypto?.getRandomValues === undefined) {
      return wasiErrno.io;
    }
    try {
      const destination = this.borrowBytes(pointer, length);
      const maximumRandomChunkBytes = 65_536;
      for (
        let offset = 0;
        offset < destination.byteLength;
        offset += maximumRandomChunkBytes
      ) {
        globalThis.crypto.getRandomValues(
          destination.subarray(
            offset,
            Math.min(offset + maximumRandomChunkBytes, destination.byteLength)
          )
        );
      }
      return wasiErrno.success;
    } catch {
      return wasiErrno.io;
    }
  }

  private unsupportedStandardFileDescriptorResult(
    fileDescriptor: number
  ): number {
    return this.isOpenStandardFileDescriptor(fileDescriptor)
      ? wasiErrno.notSupported
      : wasiErrno.badFileDescriptor;
  }

  private isStandardFileDescriptor(fileDescriptor: number): boolean {
    return fileDescriptor === 0
      || fileDescriptor === 1
      || fileDescriptor === 2;
  }

  private isOpenStandardFileDescriptor(fileDescriptor: number): boolean {
    return this.isStandardFileDescriptor(fileDescriptor)
      && !this.closedFileDescriptors.has(fileDescriptor);
  }

  private writeEmptySequenceSizes(
    countPointer: number,
    bufferSizePointer: number
  ): number {
    if (!this.isAddressRange(countPointer, 4)
        || !this.isAddressRange(bufferSizePointer, 4)) {
      return wasiErrno.fault;
    }
    this.writeUInt32(countPointer, 0);
    this.writeUInt32(bufferSizePointer, 0);
    return wasiErrno.success;
  }

  private validateIovecs(
    iovsPointer: number,
    iovsLength: number
  ): IovecValidation {
    if (!Number.isInteger(iovsLength) || iovsLength < 0) {
      return { byteLength: null, error: wasiErrno.invalidArgument };
    }
    if (iovsLength > this.maximumIovecCount) {
      return { byteLength: null, error: wasiErrno.argumentListTooLong };
    }
    const tableByteLength = iovsLength * 8;
    if (!Number.isSafeInteger(tableByteLength)
        || !this.isAddressRange(iovsPointer, tableByteLength)) {
      return { byteLength: null, error: wasiErrno.fault };
    }

    const table = new DataView(
      this.runtimeAddressSpace().buffer,
      iovsPointer,
      tableByteLength
    );
    let total = 0;
    for (let index = 0; index < iovsLength; index += 1) {
      const entryOffset = index * 8;
      const pointer = table.getUint32(entryOffset, true);
      const byteLength = table.getUint32(entryOffset + 4, true);
      const nextTotal = total + byteLength;
      if (!Number.isSafeInteger(nextTotal)
          || nextTotal > this.maximumIovecBytes) {
        return { byteLength: null, error: wasiErrno.argumentListTooLong };
      }
      if (!this.isAddressRange(pointer, byteLength)) {
        return { byteLength: null, error: wasiErrno.fault };
      }
      total = nextTotal;
    }
    return { byteLength: total, error: null };
  }

  private clearAddressRange(pointer: number, length: number): void {
    this.borrowBytes(pointer, length).fill(0);
  }

  private writeUInt32(pointer: number, value: number): void {
    new DataView(
      this.runtimeAddressSpace().buffer,
      pointer,
      4
    ).setUint32(0, value, true);
  }

  private writeUInt64(pointer: number, value: bigint): void {
    new DataView(
      this.runtimeAddressSpace().buffer,
      pointer,
      8
    ).setBigUint64(0, BigInt.asUintN(64, value), true);
  }

  private borrowBytes(pointer: number, length: number): Uint8Array<ArrayBuffer> {
    return new Uint8Array(this.runtimeAddressSpace().buffer, pointer, length);
  }

  private isAddressRange(pointer: number, length: number): boolean {
    if (!Number.isInteger(pointer)
        || !Number.isInteger(length)
        || pointer < 0
        || length < 0) {
      return false;
    }
    const end = pointer + length;
    return Number.isSafeInteger(end) && end <= this.runtimeAddressSpace().buffer.byteLength;
  }

  private runtimeAddressSpace(): WebAssembly.Memory {
    const addressSpace = this.requireRuntimeInstance().endpoints.memory;
    if (!(addressSpace instanceof WebAssembly.Memory)) {
      throw new Error("WASI reactor must export memory");
    }
    return addressSpace;
  }

  private requireRuntimeInstance(): DatabaseRuntimeInstance {
    if (this.runtimeInstance === null) {
      throw new Error("WASI runtime is not attached");
    }
    return this.runtimeInstance;
  }
}

function validateLimit(candidate: number, maximum: number, field: string): number {
  if (!Number.isInteger(candidate) || candidate <= 0 || candidate > maximum) {
    throw new RangeError(
      `${field} must be an integer from 1 through ${maximum}`
    );
  }
  return candidate;
}
