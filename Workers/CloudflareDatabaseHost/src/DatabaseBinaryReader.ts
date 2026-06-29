export class DatabaseBinaryReader {
  private readonly bytes: Uint8Array;
  private offset: number;

  constructor(bytes: ArrayBuffer | ArrayBufferView) {
    this.bytes = bytes instanceof Uint8Array ? bytes : toUint8Array(bytes);
    this.offset = 0;
  }

  readUInt8(): number {
    this.ensure(1);
    const value = this.bytes[this.offset] ?? 0;
    this.offset += 1;
    return value;
  }

  readBool(): boolean {
    const value = this.readUInt8();
    if (value === 0) {
      return false;
    }
    if (value === 1) {
      return true;
    }
    throw new Error(`Invalid bool ${value}`);
  }

  readUInt32(): number {
    this.ensure(4);
    const value = ((this.bytes[this.offset] ?? 0)
      | ((this.bytes[this.offset + 1] ?? 0) << 8)
      | ((this.bytes[this.offset + 2] ?? 0) << 16)
      | ((this.bytes[this.offset + 3] ?? 0) << 24)) >>> 0;
    this.offset += 4;
    return value;
  }

  readInt64(): bigint {
    this.ensure(8);
    let value = 0n;
    for (let index = 0; index < 8; index += 1) {
      value |= BigInt(this.bytes[this.offset + index] ?? 0) << BigInt(index * 8);
    }
    this.offset += 8;
    return BigInt.asIntN(64, value);
  }

  readDouble(): number {
    this.ensure(8);
    const value = new DataView(
      this.bytes.buffer,
      this.bytes.byteOffset + this.offset,
      8
    ).getFloat64(0, true);
    this.offset += 8;
    return value;
  }

  readBytes(): Uint8Array {
    const count = this.readCount();
    this.ensure(count);
    const value = this.bytes.slice(this.offset, this.offset + count);
    this.offset += count;
    return value;
  }

  readString(): string {
    return new TextDecoder("utf-8", { fatal: true }).decode(this.readBytes());
  }

  readCount(): number {
    return this.readUInt32();
  }

  ensureFullyRead(): void {
    if (this.offset !== this.bytes.length) {
      throw new Error("Trailing bytes");
    }
  }

  private ensure(count: number): void {
    if (this.offset + count > this.bytes.length) {
      throw new Error("Truncated input");
    }
  }
}

function toUint8Array(bytes: ArrayBuffer | ArrayBufferView): Uint8Array {
  if (bytes instanceof ArrayBuffer) {
    return new Uint8Array(bytes);
  }
  return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}
