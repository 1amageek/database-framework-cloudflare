import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseBinaryReader } from "../src/DatabaseBinaryReader";
import { DatabaseBinaryWriter } from "../src/DatabaseBinaryWriter";
import { DatabaseStorageHost } from "../src/DatabaseStorageHost";
import {
  type DatabaseKeyValueRow,
  storageOperation,
  type StorageRequest,
  type StorageWrite,
} from "../src/DatabaseStorageHostCodec";
import { NodeSqlStorage } from "./NodeSqlStorage";

type DecodedStorageResponse = {
  status: number;
  operation?: number;
  value?: Uint8Array | null;
  rows?: DatabaseKeyValueRow[];
  message?: string;
};

test("storage host commits, reads, and scans SQLite rows", () => {
  const host = new DatabaseStorageHost(new NodeSqlStorage(), (callback) => callback());
  host.migrate();

  let response = decodeResponse(host.dispatchBytes(encodeCommit([
    { tag: 1, key: bytes(0x01), value: bytes(0x10) },
    { tag: 1, key: bytes(0x02), value: bytes(0x20) },
  ])));
  assert.equal(response.operation, storageOperation.commit);

  response = decodeResponse(host.dispatchBytes(encodeRead(bytes(0x01))));
  assert.deepEqual([...requireBytes(response.value)], [0x10]);

  response = decodeResponse(host.dispatchBytes(encodeScan(bytes(0x01), bytes(0x03), 10, false)));
  assert.deepEqual(requireRows(response).map((row) => [...row.key]), [[0x01], [0x02]]);
});

test("storage host treats zero scan limit as unlimited", () => {
  const host = new DatabaseStorageHost(new NodeSqlStorage(), (callback) => callback());
  host.migrate();
  const writes: StorageWrite[] = [];
  for (let index = 0; index < 1_050; index += 1) {
    writes.push({ tag: 1, key: key(index), value: bytes(index & 0xff) });
  }
  decodeResponse(host.dispatchBytes(encodeCommit(writes)));

  const response = decodeResponse(host.dispatchBytes(encodeScan(key(0), key(1_051), 0, false)));

  const rows = requireRows(response);
  assert.equal(rows.length, 1_050);
  assert.deepEqual([...requireRow(rows.at(-1)).key], [...key(1_049)]);
});

test("storage host rejects operations before migration", () => {
  const host = new DatabaseStorageHost(new NodeSqlStorage(), (callback) => callback());

  const response = decodeResponse(host.dispatchBytes(encodeRead(bytes(0x01))));

  assert.equal(response.status, 2);
  assert.match(response.message ?? "", /not initialized/);
});

function encodeRead(key: Uint8Array): Uint8Array {
  return encodeRequest({ operation: storageOperation.read, key });
}

function encodeScan(begin: Uint8Array, end: Uint8Array, limit: number, reverse: boolean): Uint8Array {
  return encodeRequest({ operation: storageOperation.scan, begin, end, limit, reverse });
}

function encodeCommit(writes: StorageWrite[]): Uint8Array {
  return encodeRequest({ operation: storageOperation.commit, writes });
}

function encodeRequest(request: StorageRequest): Uint8Array {
  const writer = new DatabaseBinaryWriter();
  writer.writeUInt8(1);
  writer.writeUInt8(request.operation);
  switch (request.operation) {
    case storageOperation.read:
      writer.writeBytes(request.key);
      break;
    case storageOperation.scan:
      writer.writeBytes(request.begin);
      writer.writeBytes(request.end);
      writer.writeCount(request.limit);
      writer.writeBool(request.reverse);
      break;
    case storageOperation.commit:
      writer.writeCount(request.writes.length);
      for (const write of request.writes) {
        writer.writeUInt8(write.tag);
        writer.writeBytes(write.key);
        if (write.tag === 1) {
          writer.writeBytes(write.value);
        }
      }
      break;
    default:
      throw new Error("Unsupported operation");
  }
  return writer.toBytes();
}

function decodeResponse(bytesValue: Uint8Array): DecodedStorageResponse {
  const reader = new DatabaseBinaryReader(bytesValue);
  reader.readUInt8();
  const status = reader.readUInt8();
  if (status !== 1) {
      return { status, message: reader.readString() };
  }
  const operation = reader.readUInt8();
  switch (operation) {
    case storageOperation.read:
      return {
        status,
        operation,
        value: reader.readBool() ? reader.readBytes() : null,
      };
    case storageOperation.scan: {
      const count = reader.readCount();
      const rows: DatabaseKeyValueRow[] = [];
      for (let index = 0; index < count; index += 1) {
        rows.push({ key: reader.readBytes(), value: reader.readBytes() });
      }
      return { status, operation, rows };
    }
    case storageOperation.commit:
      return { status, operation };
    default:
      throw new Error(`Unknown response operation ${operation}`);
  }
}

function bytes(...values: number[]): Uint8Array {
  return new Uint8Array(values);
}

function key(value: number): Uint8Array {
  return new Uint8Array([
    (value >>> 8) & 0xff,
    value & 0xff,
  ]);
}

function requireBytes(value: Uint8Array | null | undefined): Uint8Array {
  assert.notEqual(value, null);
  assert.notEqual(value, undefined);
  if (value === null || value === undefined) {
    throw new Error("Expected bytes");
  }
  return value;
}

function requireRows(response: DecodedStorageResponse): DatabaseKeyValueRow[] {
  assert.equal("rows" in response, true);
  if (response.rows === undefined) {
    throw new Error("Expected rows");
  }
  return response.rows;
}

function requireRow(row: DatabaseKeyValueRow | undefined): DatabaseKeyValueRow {
  assert.notEqual(row, undefined);
  if (row === undefined) {
    throw new Error("Missing row");
  }
  return row;
}
