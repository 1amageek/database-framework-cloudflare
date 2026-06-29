export class DatabaseBinaryWriter {
  private readonly bytes: number[];

  constructor() {
    this.bytes = [];
  }

  writeUInt8(value: number): void {
    this.bytes.push(value & 0xff);
  }

  writeBool(value: boolean): void {
    this.writeUInt8(value ? 1 : 0);
  }

  writeUInt32(value: number): void {
    const unsigned = value >>> 0;
    this.bytes.push(
      unsigned & 0xff,
      (unsigned >>> 8) & 0xff,
      (unsigned >>> 16) & 0xff,
      (unsigned >>> 24) & 0xff
    );
  }

  writeInt64(value: bigint | number): void {
    let unsigned = BigInt.asUintN(64, BigInt(value));
    for (let index = 0; index < 8; index += 1) {
      this.bytes.push(Number(unsigned & 0xffn));
      unsigned >>= 8n;
    }
  }

  writeDouble(value: number): void {
    const buffer = new ArrayBuffer(8);
    new DataView(buffer).setFloat64(0, value, true);
    this.writeRawBytes(new Uint8Array(buffer));
  }

  writeBytes(value: ArrayBuffer | ArrayBufferView): void {
    const bytes = value instanceof Uint8Array ? value : toUint8Array(value);
    this.writeCount(bytes.length);
    this.writeRawBytes(bytes);
  }

  writeRawBytes(bytes: Uint8Array): void {
    for (const byte of bytes) {
      this.writeUInt8(byte);
    }
  }

  writeString(value: string): void {
    this.writeBytes(new TextEncoder().encode(value));
  }

  writeCount(count: number): void {
    if (!Number.isInteger(count) || count < 0 || count > 0xffff_ffff) {
      throw new Error("Byte count overflow");
    }
    this.writeUInt32(count);
  }

  toBytes(): Uint8Array {
    return new Uint8Array(this.bytes);
  }
}

function toUint8Array(bytes: ArrayBuffer | ArrayBufferView): Uint8Array {
  if (bytes instanceof ArrayBuffer) {
    return new Uint8Array(bytes);
  }
  return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}
