import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { DatabaseStorageHost } from "../src/DatabaseStorageHost.js";
import { DatabaseWasmBridge } from "../src/DatabaseWasmBridge.js";
import {
  and,
  comparison,
  comparisonOperator,
  DatabaseWireCodec,
  entitySchema,
  fieldValue,
  fieldSchema,
  fieldType,
  indexDescriptor,
  indexKind,
  namedValue,
  not,
  or,
  record,
  requestOperation,
  responsePayload,
  responseStatus,
  schema,
  vectorMetric,
  value,
} from "../src/DatabaseWireCodec.js";
import { NodeSqlStorage } from "./NodeSqlStorage.js";

const wasmPath = fileURLToPath(new URL("../src/CloudflareDatabaseRuntime.wasm", import.meta.url));

test("Swift WASM runtime executes DatabaseWire through host SQLite storage", async () => {
  const wasmBytes = readFileSync(wasmPath);
  const host = new DatabaseStorageHost(new NodeSqlStorage(), (callback) => callback());
  host.migrate();
  const bridge = await DatabaseWasmBridge.instantiate(wasmBytes, host);

  assert.equal(decode(await dispatch(bridge, {
    operation: requestOperation.applySchema,
    schema: articleSchema(),
  })).payload, responsePayload.empty);

  assert.equal(decode(await dispatch(bridge, put(article("a", "draft", 1, "Local Swift", ["swift"])))).payload, responsePayload.empty);
  assert.equal(decode(await dispatch(bridge, put(article("b", "published", 5, "Workers Runtime", ["cloudflare"])))).payload, responsePayload.empty);
  assert.equal(decode(await dispatch(bridge, put(article("c", "published", 9, "Durable Swift", ["swift", "cloudflare"])))).payload, responsePayload.empty);

  const getResponse = decode(await dispatch(bridge, {
    operation: requestOperation.getRecord,
    typeName: "Article",
    id: "b",
  }));
  assert.equal(getResponse.status, responseStatus.ok);
  assert.equal(getResponse.record.id, "b");

  const queryResponse = decode(await dispatch(bridge, {
    operation: requestOperation.query,
    query: {
      typeName: "Article",
      predicate: and([
        comparison("status", comparisonOperator.equal, value(fieldValue.string, "published")),
        or([
          comparison("score", comparisonOperator.greaterThanOrEqual, value(fieldValue.int64, 9)),
          comparison("tags", comparisonOperator.contains, value(fieldValue.string, "cloudflare")),
        ]),
      ]),
      limit: 10,
    },
  }));

  assert.equal(queryResponse.status, responseStatus.ok);
  assert.equal(queryResponse.payload, responsePayload.records);
  assert.deepEqual(queryResponse.records.map((item) => item.id), ["b", "c"]);

  assert.deepEqual(await queryIds(bridge, null, 2), ["a", "b"]);
  assert.deepEqual(
    await queryIds(bridge, comparison("status", comparisonOperator.notEqual, value(fieldValue.string, "draft"))),
    ["b", "c"]
  );
  assert.deepEqual(
    await queryIds(bridge, comparison("score", comparisonOperator.lessThan, value(fieldValue.int64, 9))),
    ["a", "b"]
  );
  assert.deepEqual(
    await queryIds(bridge, comparison("score", comparisonOperator.lessThanOrEqual, value(fieldValue.int64, 5))),
    ["a", "b"]
  );
  assert.deepEqual(
    await queryIds(bridge, comparison("score", comparisonOperator.greaterThan, value(fieldValue.int64, 1))),
    ["b", "c"]
  );
  assert.deepEqual(
    await queryIds(bridge, comparison("rating", comparisonOperator.lessThan, value(fieldValue.double, 6.0))),
    ["a", "b"]
  );
  assert.deepEqual(
    await queryIds(bridge, comparison("featured", comparisonOperator.equal, value(fieldValue.bool, true))),
    ["b", "c"]
  );
  assert.deepEqual(
    await queryIds(bridge, comparison("title", comparisonOperator.contains, value(fieldValue.string, "Swift"))),
    ["a", "c"]
  );
  assert.deepEqual(
    await queryIds(bridge, comparison("tags", comparisonOperator.contains, value(fieldValue.string, "swift"))),
    ["a", "c"]
  );
  assert.deepEqual(
    await queryIds(bridge, comparison("signature", comparisonOperator.contains, value(fieldValue.bytes, new Uint8Array([0xee])))),
    ["b", "c"]
  );
  assert.deepEqual(
    await queryIds(bridge, not(comparison("status", comparisonOperator.equal, value(fieldValue.string, "published")))),
    ["a"]
  );

  assert.equal(decode(await dispatch(bridge, {
    operation: requestOperation.applySchema,
    schema: vectorDocumentSchema(),
  })).payload, responsePayload.empty);
  assert.equal(decode(await dispatch(bridge, put(vectorDocument("near", "published", "Near", [1, 0, 0])))).payload, responsePayload.empty);
  assert.equal(decode(await dispatch(bridge, put(vectorDocument("middle", "published", "Middle", [0.8, 0.2, 0])))).payload, responsePayload.empty);
  assert.equal(decode(await dispatch(bridge, put(vectorDocument("far", "published", "Far", [0, 1, 0])))).payload, responsePayload.empty);
  assert.equal(decode(await dispatch(bridge, put(vectorDocument("draft-near", "draft", "Draft", [1, 0, 0])))).payload, responsePayload.empty);

  const vectorResponse = decode(await dispatch(bridge, {
    operation: requestOperation.vectorQuery,
    query: {
      typeName: "Document",
      fieldName: "embedding",
      dimensions: 3,
      metric: vectorMetric.cosine,
      queryVector: [1, 0, 0],
      k: 2,
      predicate: comparison("status", comparisonOperator.equal, value(fieldValue.string, "published")),
    },
  }));
  assert.equal(vectorResponse.status, responseStatus.ok);
  assert.equal(vectorResponse.payload, responsePayload.scoredRecords);
  assert.deepEqual(vectorResponse.records.map((item) => item.record.id), ["near", "middle"]);
  assert.equal(vectorResponse.records[0].distance, 0);
  assert.ok(vectorResponse.records[1].distance > 0);
});

async function dispatch(bridge, request) {
  return bridge.dispatch(DatabaseWireCodec.encodeRequest(request));
}

function decode(bytes) {
  return DatabaseWireCodec.decodeResponse(bytes);
}

async function queryIds(bridge, predicate, limit = 10) {
  const response = decode(await dispatch(bridge, {
    operation: requestOperation.query,
    query: {
      typeName: "Article",
      predicate,
      limit,
    },
  }));
  assert.equal(response.status, responseStatus.ok);
  assert.equal(response.payload, responsePayload.records);
  return response.records.map((item) => item.id);
}

function put(item) {
  return {
    operation: requestOperation.putRecord,
    record: item,
  };
}

function articleSchema() {
  return schema([
    entitySchema("Article", 1, [
      fieldSchema("status", fieldType.string, 1),
      fieldSchema("score", fieldType.int64, 2),
      fieldSchema("title", fieldType.string, 3),
      fieldSchema("tags", fieldType.array, 4),
      fieldSchema("featured", fieldType.bool, 5),
      fieldSchema("rating", fieldType.double, 6),
      fieldSchema("signature", fieldType.bytes, 7),
    ], [
      indexDescriptor("Article.status", indexKind.scalar, ["status"]),
    ]),
  ]);
}

function article(id, status, score, title, tags) {
  return record("Article", id, [
    namedValue("status", value(fieldValue.string, status)),
    namedValue("score", value(fieldValue.int64, score)),
    namedValue("title", value(fieldValue.string, title)),
    namedValue("tags", value(fieldValue.array, tags.map((tag) => value(fieldValue.string, tag)))),
    namedValue("featured", value(fieldValue.bool, status === "published")),
    namedValue("rating", value(fieldValue.double, score + 0.25)),
    namedValue("signature", value(fieldValue.bytes, new Uint8Array(score === 1 ? [0x01, 0x10] : [score, 0xee]))),
  ]);
}

function vectorDocumentSchema() {
  return schema([
    entitySchema("Document", 1, [
      fieldSchema("status", fieldType.string, 1),
      fieldSchema("title", fieldType.string, 2),
      fieldSchema("embedding", fieldType.array, 3),
    ], [
      indexDescriptor("Document.embedding.vector", indexKind.vector, ["embedding"], false, null, [
        namedValue("dimensions", value(fieldValue.int64, 3)),
        namedValue("metric", value(fieldValue.string, "cosine")),
      ]),
    ]),
  ]);
}

function vectorDocument(id, status, title, embedding) {
  return record("Document", id, [
    namedValue("status", value(fieldValue.string, status)),
    namedValue("title", value(fieldValue.string, title)),
    namedValue("embedding", value(fieldValue.array, embedding.map((scalar) => value(fieldValue.double, scalar)))),
  ]);
}
