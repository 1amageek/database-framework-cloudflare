import { DatabaseBinaryReader } from "./DatabaseBinaryReader";
import { DatabaseBinaryWriter } from "./DatabaseBinaryWriter";

export const storageProtocolVersion = 1;
export const storageOperation = Object.freeze({
  read: 1,
  scan: 2,
  commit: 3,
} as const);
export const storageStatus = Object.freeze({
  ok: 1,
  failure: 2,
} as const);
export const storageWriteOperation = Object.freeze({
  set: 1,
  clear: 2,
} as const);

export type StorageOperation = (typeof storageOperation)[keyof typeof storageOperation];
export type StorageStatus = (typeof storageStatus)[keyof typeof storageStatus];
export type StorageWriteOperation = (typeof storageWriteOperation)[keyof typeof storageWriteOperation];

export type StorageReadRequest = {
  operation: typeof storageOperation.read;
  key: Uint8Array;
};

export type StorageScanRequest = {
  operation: typeof storageOperation.scan;
  begin: Uint8Array;
  end: Uint8Array;
  limit: number;
  reverse: boolean;
};

export type StorageSetWrite = {
  tag: typeof storageWriteOperation.set;
  key: Uint8Array;
  value: Uint8Array;
};

export type StorageClearWrite = {
  tag: typeof storageWriteOperation.clear;
  key: Uint8Array;
};

export type StorageWrite = StorageSetWrite | StorageClearWrite;

export type StorageCommitRequest = {
  operation: typeof storageOperation.commit;
  writes: StorageWrite[];
};

export type StorageRequest = StorageReadRequest | StorageScanRequest | StorageCommitRequest;

export type DatabaseKeyValueRow = {
  key: Uint8Array;
  value: Uint8Array;
};

export type StorageReadResponse = {
  operation: typeof storageOperation.read;
  value: Uint8Array | null;
};

export type StorageScanResponse = {
  operation: typeof storageOperation.scan;
  rows: DatabaseKeyValueRow[];
};

export type StorageCommitResponse = {
  operation: typeof storageOperation.commit;
};

export type StorageSuccessResponse =
  | StorageReadResponse
  | StorageScanResponse
  | StorageCommitResponse;

export type StorageFailureResponse = {
  status: typeof storageStatus.failure;
  message: string;
};

export type StorageResponse = StorageSuccessResponse | StorageFailureResponse;

export class DatabaseStorageHostCodec {
  static decodeRequest(bytes: ArrayBuffer | ArrayBufferView): StorageRequest {
    const reader = new DatabaseBinaryReader(bytes);
    validateVersion(reader.readUInt8());
    const operation = reader.readUInt8();
    let request: StorageRequest;
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

  static encodeResponse(response: StorageResponse): Uint8Array {
    const writer = new DatabaseBinaryWriter();
    writer.writeUInt8(storageProtocolVersion);
    if (isStorageFailureResponse(response)) {
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
    }
    return writer.toBytes();
  }

  static encodeFailure(message: string): Uint8Array {
    return this.encodeResponse({
      status: storageStatus.failure,
      message,
    });
  }
}

function isStorageFailureResponse(response: StorageResponse): response is StorageFailureResponse {
  return "status" in response && response.status === storageStatus.failure;
}

function readWrites(reader: DatabaseBinaryReader): StorageWrite[] {
  const count = reader.readCount();
  const writes: StorageWrite[] = [];
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

function validateVersion(version: number): void {
  if (version !== storageProtocolVersion) {
    throw new Error(`Unsupported storage protocol version ${version}`);
  }
}
