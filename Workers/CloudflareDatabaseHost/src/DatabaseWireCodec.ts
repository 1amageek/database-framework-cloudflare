import { DatabaseBinaryReader } from "./DatabaseBinaryReader";
import { DatabaseBinaryWriter } from "./DatabaseBinaryWriter";

export const databaseWireProtocolVersion = 2;
export const requestOperation = Object.freeze({
  applySchema: 1,
  putRecord: 2,
  getRecord: 3,
  query: 4,
  vectorQuery: 5,
} as const);
export const responseStatus = Object.freeze({
  ok: 1,
  invalidRequest: 2,
  executionFailure: 3,
  unsupported: 4,
} as const);
export const responsePayload = Object.freeze({
  empty: 1,
  record: 2,
  records: 3,
  scoredRecords: 4,
} as const);
export const fieldValue = Object.freeze({
  null: 0,
  bool: 1,
  int64: 2,
  double: 3,
  string: 4,
  bytes: 5,
  array: 6,
  object: 7,
  reference: 8,
} as const);
export const fieldType = Object.freeze({
  bool: 1,
  int64: 2,
  double: 3,
  string: 4,
  bytes: 5,
  array: 6,
  object: 7,
  reference: 8,
} as const);
export const indexKind = Object.freeze({
  scalar: 1,
  vector: 2,
  fullText: 3,
  spatial: 4,
  rank: 5,
  permuted: 6,
  graph: 7,
  relationship: 8,
  aggregation: 9,
  version: 10,
  bitmap: 11,
  leaderboard: 12,
  custom: 255,
} as const);
export const comparisonOperator = Object.freeze({
  equal: 1,
  notEqual: 2,
  lessThan: 3,
  lessThanOrEqual: 4,
  greaterThan: 5,
  greaterThanOrEqual: 6,
  contains: 7,
} as const);
export const predicateKind = Object.freeze({
  comparison: 1,
  and: 2,
  or: 3,
  not: 4,
} as const);
export const vectorMetric = Object.freeze({
  cosine: 1,
  euclidean: 2,
  dotProduct: 3,
} as const);

export type DatabaseWireFieldValueData =
  | null
  | boolean
  | number
  | string
  | Uint8Array
  | DatabaseWireFieldValue[]
  | DatabaseWireNamedValue[];

export type DatabaseWireFieldValue = {
  tag: number;
  value: DatabaseWireFieldValueData;
};

export type DatabaseWireNamedValue = {
  name: string;
  value: DatabaseWireFieldValue;
};

export type DatabaseWireRecord = {
  typeName: string;
  id: string;
  fields: DatabaseWireNamedValue[];
};

export type DatabaseWireFieldSchema = {
  name: string;
  type: number;
  fieldNumber: number;
  isOptional: boolean;
};

export type DatabaseWireIndexDescriptor = {
  name: string;
  kind: number;
  fields: string[];
  unique: boolean;
  customIdentifier: string | null;
  parameters: DatabaseWireNamedValue[];
};

export type DatabaseWireEntitySchema = {
  typeName: string;
  version: number;
  fields: DatabaseWireFieldSchema[];
  indexes: DatabaseWireIndexDescriptor[];
};

export type DatabaseWireSchema = {
  entities: DatabaseWireEntitySchema[];
};

export type DatabaseWireComparisonPredicate = {
  kind: typeof predicateKind.comparison;
  field: string;
  op: number;
  value: DatabaseWireFieldValue;
};

export type DatabaseWireCompoundPredicate = {
  kind: typeof predicateKind.and | typeof predicateKind.or;
  predicates: DatabaseWirePredicate[];
};

export type DatabaseWireNotPredicate = {
  kind: typeof predicateKind.not;
  predicate: DatabaseWirePredicate;
};

export type DatabaseWirePredicate =
  | DatabaseWireComparisonPredicate
  | DatabaseWireCompoundPredicate
  | DatabaseWireNotPredicate;

export type DatabaseWireQuery = {
  typeName: string;
  predicate: DatabaseWirePredicate | null;
  limit: number;
};

export type DatabaseWireVectorQuery = {
  typeName: string;
  fieldName: string;
  dimensions: number;
  metric: number;
  queryVector: number[];
  k: number;
  predicate: DatabaseWirePredicate | null;
};

export type DatabaseWireRequest =
  | { operation: typeof requestOperation.applySchema; schema: DatabaseWireSchema }
  | { operation: typeof requestOperation.putRecord; record: DatabaseWireRecord }
  | { operation: typeof requestOperation.getRecord; typeName: string; id: string }
  | { operation: typeof requestOperation.query; query: DatabaseWireQuery }
  | { operation: typeof requestOperation.vectorQuery; query: DatabaseWireVectorQuery };

export type DatabaseWireScoredRecord = {
  record: DatabaseWireRecord;
  distance: number;
};

export type DatabaseWireDecodedRecord = DatabaseWireRecord & DatabaseWireScoredRecord;

export type DatabaseWireDecodedResponse = {
  status: number;
  message: string | null;
  payload: number | null;
  record: DatabaseWireRecord | null;
  records: DatabaseWireDecodedRecord[];
};

export class DatabaseWireCodec {
  static encodeRequest(request: DatabaseWireRequest): Uint8Array {
    const writer = new DatabaseBinaryWriter();
    writer.writeUInt8(databaseWireProtocolVersion);
    writer.writeUInt8(request.operation);
    switch (request.operation) {
      case requestOperation.applySchema:
        writeSchema(writer, request.schema);
        break;
      case requestOperation.putRecord:
        writeRecord(writer, request.record);
        break;
      case requestOperation.getRecord:
        writer.writeString(request.typeName);
        writer.writeString(request.id);
        break;
      case requestOperation.query:
        writeQuery(writer, request.query);
        break;
      case requestOperation.vectorQuery:
        writeVectorQuery(writer, request.query);
        break;
    }
    return writer.toBytes();
  }

  static decodeResponse(bytes: ArrayBuffer | ArrayBufferView): DatabaseWireDecodedResponse {
    const reader = new DatabaseBinaryReader(bytes);
    validateVersion(reader.readUInt8());
    const status = reader.readUInt8();
    if (status !== responseStatus.ok) {
      const response = {
        status,
        message: reader.readString(),
        payload: null,
        record: null,
        records: [],
      };
      reader.ensureFullyRead();
      return response;
    }

    const payload = reader.readUInt8();
    let response: DatabaseWireDecodedResponse;
    switch (payload) {
      case responsePayload.empty:
        response = { status, message: null, payload, record: null, records: [] };
        break;
      case responsePayload.record:
        response = {
          status,
          message: null,
          payload,
          record: reader.readBool() ? readRecord(reader) : null,
          records: [],
        };
        break;
      case responsePayload.records:
        response = {
          status,
          message: null,
          payload,
          record: null,
          records: readRecords(reader),
        };
        break;
      case responsePayload.scoredRecords:
        response = {
          status,
          message: null,
          payload,
          record: null,
          records: readScoredRecords(reader),
        };
        break;
      default:
        throw new Error(`Unknown response payload ${payload}`);
    }
    reader.ensureFullyRead();
    return response;
  }
}

export function record(typeName: string, id: string, fields: DatabaseWireNamedValue[]): DatabaseWireRecord {
  return { typeName, id, fields };
}

export function schema(entities: DatabaseWireEntitySchema[]): DatabaseWireSchema {
  return { entities };
}

export function entitySchema(
  typeName: string,
  version: number,
  fields: DatabaseWireFieldSchema[],
  indexes: DatabaseWireIndexDescriptor[] = []
): DatabaseWireEntitySchema {
  return { typeName, version, fields, indexes };
}

export function fieldSchema(
  name: string,
  type: number,
  fieldNumber: number,
  isOptional = false
): DatabaseWireFieldSchema {
  return { name, type, fieldNumber, isOptional };
}

export function indexDescriptor(
  name: string,
  kind: number,
  fields: string[],
  unique = false,
  customIdentifier: string | null = null,
  parameters: DatabaseWireNamedValue[] = []
): DatabaseWireIndexDescriptor {
  return { name, kind, fields, unique, customIdentifier, parameters };
}

export function namedValue(name: string, value: DatabaseWireFieldValue): DatabaseWireNamedValue {
  return { name, value };
}

export function value(tag: number, rawValue: DatabaseWireFieldValueData = null): DatabaseWireFieldValue {
  return { tag, value: rawValue };
}

export function comparison(field: string, op: number, expected: DatabaseWireFieldValue): DatabaseWireComparisonPredicate {
  return { kind: predicateKind.comparison, field, op, value: expected };
}

export function and(predicates: DatabaseWirePredicate[]): DatabaseWireCompoundPredicate {
  return { kind: predicateKind.and, predicates };
}

export function or(predicates: DatabaseWirePredicate[]): DatabaseWireCompoundPredicate {
  return { kind: predicateKind.or, predicates };
}

export function not(predicate: DatabaseWirePredicate): DatabaseWireNotPredicate {
  return { kind: predicateKind.not, predicate };
}

function writeSchema(writer: DatabaseBinaryWriter, value: DatabaseWireSchema): void {
  writer.writeCount(value.entities.length);
  for (const entity of value.entities) {
    writeEntitySchema(writer, entity);
  }
}

function writeEntitySchema(writer: DatabaseBinaryWriter, entity: DatabaseWireEntitySchema): void {
  writer.writeString(entity.typeName);
  writer.writeUInt32(entity.version);
  writer.writeCount(entity.fields.length);
  for (const field of entity.fields) {
    writeFieldSchema(writer, field);
  }
  writer.writeCount(entity.indexes.length);
  for (const index of entity.indexes) {
    writeIndexDescriptor(writer, index);
  }
}

function writeFieldSchema(writer: DatabaseBinaryWriter, field: DatabaseWireFieldSchema): void {
  writer.writeString(field.name);
  writer.writeUInt8(field.type);
  writer.writeBool(field.isOptional);
  writer.writeUInt32(field.fieldNumber);
}

function writeIndexDescriptor(writer: DatabaseBinaryWriter, index: DatabaseWireIndexDescriptor): void {
  writer.writeString(index.name);
  writer.writeUInt8(index.kind);
  if (index.kind === indexKind.custom) {
    if (index.customIdentifier === null) {
      throw new Error("Custom index identifier is required");
    }
    writer.writeString(index.customIdentifier);
  }
  writer.writeCount(index.fields.length);
  for (const field of index.fields) {
    writer.writeString(field);
  }
  writer.writeBool(index.unique);
  const parameters = index.parameters ?? [];
  writer.writeCount(parameters.length);
  for (const parameter of parameters) {
    writer.writeString(parameter.name);
    writeFieldValue(writer, parameter.value);
  }
}

function writeRecord(writer: DatabaseBinaryWriter, item: DatabaseWireRecord): void {
  writer.writeString(item.typeName);
  writer.writeString(item.id);
  writer.writeCount(item.fields.length);
  for (const field of item.fields) {
    writer.writeString(field.name);
    writeFieldValue(writer, field.value);
  }
}

function readRecord(reader: DatabaseBinaryReader): DatabaseWireRecord {
  const typeName = reader.readString();
  const id = reader.readString();
  const count = reader.readCount();
  const fields: DatabaseWireNamedValue[] = [];
  for (let index = 0; index < count; index += 1) {
    fields.push({
      name: reader.readString(),
      value: readFieldValue(reader),
    });
  }
  return { typeName, id, fields };
}

function readRecords(reader: DatabaseBinaryReader): DatabaseWireDecodedRecord[] {
  const count = reader.readCount();
  const records: DatabaseWireDecodedRecord[] = [];
  for (let index = 0; index < count; index += 1) {
    records.push(readRecord(reader) as DatabaseWireDecodedRecord);
  }
  return records;
}

function readScoredRecords(reader: DatabaseBinaryReader): DatabaseWireDecodedRecord[] {
  const count = reader.readCount();
  const records: DatabaseWireDecodedRecord[] = [];
  for (let index = 0; index < count; index += 1) {
    records.push({
      record: readRecord(reader),
      distance: reader.readDouble(),
    } as DatabaseWireDecodedRecord);
  }
  return records;
}

function writeQuery(writer: DatabaseBinaryWriter, query: DatabaseWireQuery): void {
  writer.writeString(query.typeName);
  writer.writeBool(query.predicate !== null);
  if (query.predicate !== null) {
    writePredicate(writer, query.predicate);
  }
  writer.writeUInt32(query.limit);
}

function writeVectorQuery(writer: DatabaseBinaryWriter, query: DatabaseWireVectorQuery): void {
  writer.writeString(query.typeName);
  writer.writeString(query.fieldName);
  writer.writeUInt32(query.dimensions);
  writer.writeUInt8(query.metric);
  writer.writeCount(query.queryVector.length);
  for (const value of query.queryVector) {
    writer.writeDouble(value);
  }
  writer.writeUInt32(query.k);
  writer.writeBool(query.predicate !== null);
  if (query.predicate !== null) {
    writePredicate(writer, query.predicate);
  }
}

function writePredicate(writer: DatabaseBinaryWriter, predicate: DatabaseWirePredicate): void {
  writer.writeUInt8(predicate.kind);
  switch (predicate.kind) {
    case predicateKind.comparison:
      writer.writeString(predicate.field);
      writer.writeUInt8(predicate.op);
      writeFieldValue(writer, predicate.value);
      break;
    case predicateKind.and:
    case predicateKind.or:
      writer.writeCount(predicate.predicates.length);
      for (const child of predicate.predicates) {
        writePredicate(writer, child);
      }
      break;
    case predicateKind.not:
      writePredicate(writer, predicate.predicate);
      break;
  }
}

function writeFieldValue(writer: DatabaseBinaryWriter, field: DatabaseWireFieldValue): void {
  writer.writeUInt8(field.tag);
  switch (field.tag) {
    case fieldValue.null:
      break;
    case fieldValue.bool:
      writer.writeBool(requireBoolean(field.value));
      break;
    case fieldValue.int64:
      writer.writeInt64(requireNumber(field.value));
      break;
    case fieldValue.double:
      writer.writeDouble(requireNumber(field.value));
      break;
    case fieldValue.string:
    case fieldValue.reference:
      writer.writeString(requireString(field.value));
      break;
    case fieldValue.bytes:
      writer.writeBytes(requireBytes(field.value));
      break;
    case fieldValue.array:
      writer.writeCount(requireFieldValues(field.value).length);
      for (const element of requireFieldValues(field.value)) {
        writeFieldValue(writer, element);
      }
      break;
    case fieldValue.object:
      writer.writeCount(requireNamedValues(field.value).length);
      for (const entry of requireNamedValues(field.value)) {
        writer.writeString(entry.name);
        writeFieldValue(writer, entry.value);
      }
      break;
    default:
      throw new Error(`Unknown field value ${field.tag}`);
  }
}

function readFieldValue(reader: DatabaseBinaryReader): DatabaseWireFieldValue {
  const tag = reader.readUInt8();
  switch (tag) {
    case fieldValue.null:
      return value(tag);
    case fieldValue.bool:
      return value(tag, reader.readBool());
    case fieldValue.int64:
      return value(tag, Number(reader.readInt64()));
    case fieldValue.double:
      return value(tag, reader.readDouble());
    case fieldValue.string:
    case fieldValue.reference:
      return value(tag, reader.readString());
    case fieldValue.bytes:
      return value(tag, reader.readBytes());
    case fieldValue.array: {
      const count = reader.readCount();
      const values: DatabaseWireFieldValue[] = [];
      for (let index = 0; index < count; index += 1) {
        values.push(readFieldValue(reader));
      }
      return value(tag, values);
    }
    case fieldValue.object: {
      const count = reader.readCount();
      const values: DatabaseWireNamedValue[] = [];
      for (let index = 0; index < count; index += 1) {
        values.push({
          name: reader.readString(),
          value: readFieldValue(reader),
        });
      }
      return value(tag, values);
    }
    default:
      throw new Error(`Unknown field value ${tag}`);
  }
}

function validateVersion(version: number): void {
  if (version !== databaseWireProtocolVersion) {
    throw new Error(`Unsupported DatabaseWire version ${version}`);
  }
}

function requireBoolean(value: DatabaseWireFieldValueData): boolean {
  if (typeof value !== "boolean") {
    throw new Error("Expected boolean field value");
  }
  return value;
}

function requireNumber(value: DatabaseWireFieldValueData): number {
  if (typeof value !== "number") {
    throw new Error("Expected numeric field value");
  }
  return value;
}

function requireString(value: DatabaseWireFieldValueData): string {
  if (typeof value !== "string") {
    throw new Error("Expected string field value");
  }
  return value;
}

function requireBytes(value: DatabaseWireFieldValueData): Uint8Array {
  if (!(value instanceof Uint8Array)) {
    throw new Error("Expected bytes field value");
  }
  return value;
}

function requireFieldValues(value: DatabaseWireFieldValueData): DatabaseWireFieldValue[] {
  if (!Array.isArray(value)) {
    throw new Error("Expected array field value");
  }
  return value as DatabaseWireFieldValue[];
}

function requireNamedValues(value: DatabaseWireFieldValueData): DatabaseWireNamedValue[] {
  if (!Array.isArray(value)) {
    throw new Error("Expected object field value");
  }
  return value as DatabaseWireNamedValue[];
}
