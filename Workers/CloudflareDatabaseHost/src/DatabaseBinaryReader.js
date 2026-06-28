export class DatabaseBinaryReader {
  constructor(bytes) {
    this.bytes = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    this.offset = 0;
  }

  readUInt8() {
    this.ensure(1);
    const value = this.bytes[this.offset];
    this.offset += 1;
    return value;
  }

  readBool() {
    const value = this.readUInt8();
    if (value === 0) {
      return false;
    }
    if (value === 1) {
      return true;
    }
    throw new Error(`Invalid bool ${value}`);
  }

  readUInt32() {
    this.ensure(4);
    const value = (this.bytes[this.offset]
      | (this.bytes[this.offset + 1] << 8)
      | (this.bytes[this.offset + 2] << 16)
      | (this.bytes[this.offset + 3] << 24)) >>> 0;
    this.offset += 4;
    return value;
  }

  readInt64() {
    this.ensure(8);
    let value = 0n;
    for (let index = 0; index < 8; index += 1) {
      value |= BigInt(this.bytes[this.offset + index]) << BigInt(index * 8);
    }
    this.offset += 8;
    return BigInt.asIntN(64, value);
  }

  readDouble() {
    this.ensure(8);
    const value = new DataView(
      this.bytes.buffer,
      this.bytes.byteOffset + this.offset,
      8
    ).getFloat64(0, true);
    this.offset += 8;
    return value;
  }

  readBytes() {
    const count = this.readCount();
    this.ensure(count);
    const value = this.bytes.slice(this.offset, this.offset + count);
    this.offset += count;
    return value;
  }

  readString() {
    return new TextDecoder("utf-8", { fatal: true }).decode(this.readBytes());
  }

  readCount() {
    return this.readUInt32();
  }

  ensureFullyRead() {
    if (this.offset !== this.bytes.length) {
      throw new Error("Trailing bytes");
    }
  }

  ensure(count) {
    if (this.offset + count > this.bytes.length) {
      throw new Error("Truncated input");
    }
  }
}
