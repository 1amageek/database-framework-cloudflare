import { DatabaseBinaryReader } from "./DatabaseBinaryReader.js";
import { DatabaseBinaryWriter } from "./DatabaseBinaryWriter.js";

export const storageProtocolVersion = 1;
export const storageOperation = Object.freeze({
  read: 1,
  scan: 2,
  commit: 3,
});
export const storageStatus = Object.freeze({
  ok: 1,
  failure: 2,
});
export const storageWriteOperation = Object.freeze({
  set: 1,
  clear: 2,
});

export class DatabaseStorageHostCodec {
  static decodeRequest(bytes) {
    const reader = new DatabaseBinaryReader(bytes);
    validateVersion(reader.readUInt8());
    const operation = reader.readUInt8();
    let request;
    switch (operation) {
      case storageOperation.read:
        request = { operation, key: reader.readBytes() };
        break;
      case storageOperation.scan:
        request = {
          operation,
          begin: reader.readBytes(),
          end: reader.readBytes(),
          limit: reader.readCount(),
          reverse: reader.readBool(),
        };
        break;
      case storageOperation.commit:
        request = {
          operation,
          writes: readWrites(reader),
        };
        break;
      default:
        throw new Error(`Unknown storage operation ${operation}`);
    }
    reader.ensureFullyRead();
    return request;
  }

  static encodeResponse(response) {
    const writer = new DatabaseBinaryWriter();
    writer.writeUInt8(storageProtocolVersion);
    if (response.status === storageStatus.failure) {
      writer.writeUInt8(storageStatus.failure);
      writer.writeString(response.message);
      return writer.toBytes();
    }

    writer.writeUInt8(storageStatus.ok);
    writer.writeUInt8(response.operation);
    switch (response.operation) {
      case storageOperation.read:
        writer.writeBool(response.value !== null);
        if (response.value !== null) {
          writer.writeBytes(response.value);
        }
        break;
      case storageOperation.scan:
        writer.writeCount(response.rows.length);
        for (const row of response.rows) {
          writer.writeBytes(row.key);
          writer.writeBytes(row.value);
        }
        break;
      case storageOperation.commit:
        break;
      default:
        throw new Error(`Unknown storage operation ${response.operation}`);
    }
    return writer.toBytes();
  }

  static encodeFailure(message) {
    return this.encodeResponse({
      status: storageStatus.failure,
      message,
    });
  }
}

function readWrites(reader) {
  const count = reader.readCount();
  const writes = [];
  for (let index = 0; index < count; index += 1) {
    const tag = reader.readUInt8();
    switch (tag) {
      case storageWriteOperation.set:
        writes.push({ tag, key: reader.readBytes(), value: reader.readBytes() });
        break;
      case storageWriteOperation.clear:
        writes.push({ tag, key: reader.readBytes() });
        break;
      default:
        throw new Error(`Unknown storage write operation ${tag}`);
    }
  }
  return writes;
}

function validateVersion(version) {
  if (version !== storageProtocolVersion) {
    throw new Error(`Unsupported storage protocol version ${version}`);
  }
}
