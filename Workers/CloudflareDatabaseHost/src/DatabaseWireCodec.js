import { DatabaseBinaryReader } from "./DatabaseBinaryReader.js";
import { DatabaseBinaryWriter } from "./DatabaseBinaryWriter.js";

export const databaseWireProtocolVersion = 2;
export const requestOperation = Object.freeze({
  applySchema: 1,
  putRecord: 2,
  getRecord: 3,
  query: 4,
  vectorQuery: 5,
});
export const responseStatus = Object.freeze({
  ok: 1,
  invalidRequest: 2,
  executionFailure: 3,
  unsupported: 4,
});
export const responsePayload = Object.freeze({
  empty: 1,
  record: 2,
  records: 3,
  scoredRecords: 4,
});
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
});
export const fieldType = Object.freeze({
  bool: 1,
  int64: 2,
  double: 3,
  string: 4,
  bytes: 5,
  array: 6,
  object: 7,
  reference: 8,
});
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
});
export const comparisonOperator = Object.freeze({
  equal: 1,
  notEqual: 2,
  lessThan: 3,
  lessThanOrEqual: 4,
  greaterThan: 5,
  greaterThanOrEqual: 6,
  contains: 7,
});
export const predicateKind = Object.freeze({
  comparison: 1,
  and: 2,
  or: 3,
  not: 4,
});
export const vectorMetric = Object.freeze({
  cosine: 1,
  euclidean: 2,
  dotProduct: 3,
});

export class DatabaseWireCodec {
  static encodeRequest(request) {
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
      default:
        throw new Error(`Unsupported test request operation ${request.operation}`);
    }
    return writer.toBytes();
  }

  static decodeResponse(bytes) {
    const reader = new DatabaseBinaryReader(bytes);
    validateVersion(reader.readUInt8());
    const status = reader.readUInt8();
    if (status !== responseStatus.ok) {
      const response = {
        status,
        message: reader.readString(),
      };
      reader.ensureFullyRead();
      return response;
    }

    const payload = reader.readUInt8();
    let response;
    switch (payload) {
      case responsePayload.empty:
        response = { status, payload };
        break;
      case responsePayload.record:
        response = {
          status,
          payload,
          record: reader.readBool() ? readRecord(reader) : null,
        };
        break;
      case responsePayload.records:
        response = {
          status,
          payload,
          records: readRecords(reader),
        };
        break;
      case responsePayload.scoredRecords:
        response = {
          status,
          payload,
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

export function record(typeName, id, fields) {
  return { typeName, id, fields };
}

export function schema(entities) {
  return { entities };
}

export function entitySchema(typeName, version, fields, indexes = []) {
  return { typeName, version, fields, indexes };
}

export function fieldSchema(name, type, fieldNumber, isOptional = false) {
  return { name, type, fieldNumber, isOptional };
}

export function indexDescriptor(name, kind, fields, unique = false, customIdentifier = null, parameters = []) {
  return { name, kind, fields, unique, customIdentifier, parameters };
}

export function namedValue(name, value) {
  return { name, value };
}

export function value(tag, value = null) {
  return { tag, value };
}

export function comparison(field, op, expected) {
  return { kind: predicateKind.comparison, field, op, value: expected };
}

export function and(predicates) {
  return { kind: predicateKind.and, predicates };
}

export function or(predicates) {
  return { kind: predicateKind.or, predicates };
}

export function not(predicate) {
  return { kind: predicateKind.not, predicate };
}

function writeSchema(writer, value) {
  writer.writeCount(value.entities.length);
  for (const entity of value.entities) {
    writeEntitySchema(writer, entity);
  }
}

function writeEntitySchema(writer, entity) {
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

function writeFieldSchema(writer, field) {
  writer.writeString(field.name);
  writer.writeUInt8(field.type);
  writer.writeBool(field.isOptional);
  writer.writeUInt32(field.fieldNumber);
}

function writeIndexDescriptor(writer, index) {
  writer.writeString(index.name);
  writer.writeUInt8(index.kind);
  if (index.kind === indexKind.custom) {
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

function writeRecord(writer, item) {
  writer.writeString(item.typeName);
  writer.writeString(item.id);
  writer.writeCount(item.fields.length);
  for (const field of item.fields) {
    writer.writeString(field.name);
    writeFieldValue(writer, field.value);
  }
}

function readRecord(reader) {
  const typeName = reader.readString();
  const id = reader.readString();
  const count = reader.readCount();
  const fields = [];
  for (let index = 0; index < count; index += 1) {
    fields.push({
      name: reader.readString(),
      value: readFieldValue(reader),
    });
  }
  return { typeName, id, fields };
}

function readRecords(reader) {
  const count = reader.readCount();
  const records = [];
  for (let index = 0; index < count; index += 1) {
    records.push(readRecord(reader));
  }
  return records;
}

function readScoredRecords(reader) {
  const count = reader.readCount();
  const records = [];
  for (let index = 0; index < count; index += 1) {
    records.push({
      record: readRecord(reader),
      distance: reader.readDouble(),
    });
  }
  return records;
}

function writeQuery(writer, query) {
  writer.writeString(query.typeName);
  writer.writeBool(query.predicate !== null);
  if (query.predicate !== null) {
    writePredicate(writer, query.predicate);
  }
  writer.writeUInt32(query.limit);
}

function writeVectorQuery(writer, query) {
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

function writePredicate(writer, predicate) {
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
    default:
      throw new Error(`Unknown predicate kind ${predicate.kind}`);
  }
}

function writeFieldValue(writer, field) {
  writer.writeUInt8(field.tag);
  switch (field.tag) {
    case fieldValue.null:
      break;
    case fieldValue.bool:
      writer.writeBool(field.value);
      break;
    case fieldValue.int64:
      writer.writeInt64(field.value);
      break;
    case fieldValue.double:
      writer.writeDouble(field.value);
      break;
    case fieldValue.string:
    case fieldValue.reference:
      writer.writeString(field.value);
      break;
    case fieldValue.bytes:
      writer.writeBytes(field.value);
      break;
    case fieldValue.array:
      writer.writeCount(field.value.length);
      for (const element of field.value) {
        writeFieldValue(writer, element);
      }
      break;
    case fieldValue.object:
      writer.writeCount(field.value.length);
      for (const entry of field.value) {
        writer.writeString(entry.name);
        writeFieldValue(writer, entry.value);
      }
      break;
    default:
      throw new Error(`Unknown field value ${field.tag}`);
  }
}

function readFieldValue(reader) {
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
      const values = [];
      for (let index = 0; index < count; index += 1) {
        values.push(readFieldValue(reader));
      }
      return value(tag, values);
    }
    case fieldValue.object: {
      const count = reader.readCount();
      const values = [];
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

function validateVersion(version) {
  if (version !== databaseWireProtocolVersion) {
    throw new Error(`Unsupported DatabaseWire version ${version}`);
  }
}
