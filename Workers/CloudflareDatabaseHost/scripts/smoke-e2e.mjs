import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
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

const port = Number(process.env.CLOUDFLARE_DATABASE_E2E_PORT ?? "18788");
const origin = `http://127.0.0.1:${port}`;
const packageRoot = new URL("..", import.meta.url);
const devVarsPath = join(packageRoot.pathname, ".dev.vars");
const accessToken = "local-smoke-token";
const durableScope = {
  databaseID: `database-e2e-${Date.now()}`,
  tenantID: "tenant-alpha",
  workspaceID: "workspace-main",
};

let wrangler = null;

try {
  writeDevVars();
  wrangler = startWrangler();
  await waitForWorker();
  await assertMethodGuard();
  await assertAuthorizationGuard();
  await assertWireRuntime();
  await assertQueryMatrix();
  await assertVectorSearch();
  await assertScopeIsolation();
  await assertInvalidRequestEnvelope();
  console.log("Cloudflare database host E2E smoke passed");
} finally {
  await stopWrangler(wrangler);
  removeDevVars();
}

function startWrangler() {
  const localWrangler = join(packageRoot.pathname, "node_modules", ".bin", "wrangler");
  const command = existsSync(localWrangler) ? localWrangler : "npx";
  const args = existsSync(localWrangler)
    ? ["dev", "--port", String(port), "--ip", "127.0.0.1"]
    : ["wrangler", "dev", "--port", String(port), "--ip", "127.0.0.1"];
  const child = spawn(command, args, {
    cwd: packageRoot,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.output = "";
  child.stdout.on("data", (chunk) => {
    child.output = trimOutput(child.output + chunk.toString());
  });
  child.stderr.on("data", (chunk) => {
    child.output = trimOutput(child.output + chunk.toString());
  });
  return child;
}

async function waitForWorker() {
  const startedAt = Date.now();
  while (Date.now() - startedAt < 60_000) {
    if (wrangler.exitCode !== null) {
      throw new Error(`wrangler dev exited early\n${wrangler.output}`);
    }
    try {
      const response = await fetchWithTimeout(origin, { method: "GET" }, 2_000);
      if (response.status === 405) {
        return;
      }
    } catch {
      await sleep(500);
      continue;
    }
    await sleep(500);
  }
  throw new Error(`wrangler dev did not become ready\n${wrangler.output}`);
}

async function assertMethodGuard() {
  const response = await fetchWithTimeout(origin, { method: "GET" }, 5_000);
  assert.equal(response.status, 405);
}

async function assertAuthorizationGuard() {
  const response = await fetchWithTimeout(origin, {
    method: "POST",
    body: new Uint8Array([0x01]),
  }, 5_000);
  assert.equal(response.status, 401);
}

async function assertWireRuntime() {
  await applySchema(articleSchema(), durableScope);
  await put(article("a", "draft", 1, "Local Swift", ["swift"]), durableScope);
  await put(article("b", "published", 5, "Workers Runtime", ["cloudflare"]), durableScope);
  await put(article("c", "published", 9, "Durable Swift", ["swift", "cloudflare"]), durableScope);

  const getResponse = await dispatch({
    operation: requestOperation.getRecord,
    typeName: "Article",
    id: "b",
  }, durableScope);
  assert.equal(getResponse.status, responseStatus.ok);
  assert.equal(getResponse.payload, responsePayload.record);
  assert.equal(getResponse.record.id, "b");

  const queryResponse = await dispatch({
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
  }, durableScope);
  assert.equal(queryResponse.status, responseStatus.ok);
  assert.equal(queryResponse.payload, responsePayload.records);
  assert.deepEqual(queryResponse.records.map((item) => item.id), ["b", "c"]);
}

async function assertScopeIsolation() {
  const isolatedScope = {
    databaseID: durableScope.databaseID,
    tenantID: "tenant-beta",
    workspaceID: durableScope.workspaceID,
  };
  const missing = await dispatch({
    operation: requestOperation.getRecord,
    typeName: "Article",
    id: "b",
  }, isolatedScope);
  assert.equal(missing.status, responseStatus.ok);
  assert.equal(missing.payload, responsePayload.record);
  assert.equal(missing.record, null);
}

async function assertQueryMatrix() {
  const matrixScope = {
    databaseID: `database-query-matrix-${Date.now()}`,
    tenantID: "tenant-alpha",
    workspaceID: "workspace-main",
  };
  await applySchema(articleSchema(), matrixScope);
  for (const item of [
    article("a", "draft", 1, "Local Swift", ["swift"]),
    article("b", "published", 5, "Workers Runtime", ["cloudflare"]),
    article("c", "published", 9, "Durable Swift", ["swift", "cloudflare"]),
    article("d", "archived", 13, "Database Runtime", ["database"]),
    article("e", "published", 15, "Edge Storage", ["edge", "swift"]),
  ]) {
    await put(item, matrixScope);
  }

  const patterns = [
    {
      predicate: null,
      expected: ["a", "b", "c", "d", "e"],
    },
    {
      predicate: comparison("status", comparisonOperator.equal, value(fieldValue.string, "published")),
      expected: ["b", "c", "e"],
    },
    {
      predicate: comparison("status", comparisonOperator.notEqual, value(fieldValue.string, "archived")),
      expected: ["a", "b", "c", "e"],
    },
    {
      predicate: comparison("score", comparisonOperator.lessThan, value(fieldValue.int64, 5)),
      expected: ["a"],
    },
    {
      predicate: comparison("score", comparisonOperator.lessThanOrEqual, value(fieldValue.int64, 5)),
      expected: ["a", "b"],
    },
    {
      predicate: comparison("score", comparisonOperator.greaterThan, value(fieldValue.int64, 9)),
      expected: ["d", "e"],
    },
    {
      predicate: comparison("score", comparisonOperator.greaterThanOrEqual, value(fieldValue.int64, 9)),
      expected: ["c", "d", "e"],
    },
    {
      predicate: comparison("title", comparisonOperator.contains, value(fieldValue.string, "Runtime")),
      expected: ["b", "d"],
    },
    {
      predicate: comparison("tags", comparisonOperator.contains, value(fieldValue.string, "swift")),
      expected: ["a", "c", "e"],
    },
    {
      predicate: not(comparison("status", comparisonOperator.equal, value(fieldValue.string, "draft"))),
      expected: ["b", "c", "d", "e"],
    },
    {
      predicate: and([
        comparison("status", comparisonOperator.equal, value(fieldValue.string, "published")),
        comparison("score", comparisonOperator.greaterThanOrEqual, value(fieldValue.int64, 9)),
      ]),
      expected: ["c", "e"],
    },
    {
      predicate: or([
        comparison("score", comparisonOperator.lessThan, value(fieldValue.int64, 2)),
        comparison("tags", comparisonOperator.contains, value(fieldValue.string, "database")),
      ]),
      expected: ["a", "d"],
    },
    {
      predicate: comparison("missing", comparisonOperator.equal, value(fieldValue.string, "value")),
      expected: [],
    },
  ];

  for (const pattern of patterns) {
    assert.deepEqual(await queryIDs(matrixScope, pattern.predicate, 0), pattern.expected);
  }
  assert.deepEqual(
    await queryIDs(
      matrixScope,
      comparison("status", comparisonOperator.equal, value(fieldValue.string, "published")),
      2
    ),
    ["b", "c"]
  );
}

async function assertVectorSearch() {
  const vectorScope = {
    databaseID: `database-vector-${Date.now()}`,
    tenantID: "tenant-alpha",
    workspaceID: "workspace-main",
  };
  await applySchema(vectorDocumentSchema(), vectorScope);
  for (const item of [
    vectorDocument("near", "published", "Near", [1, 0, 0]),
    vectorDocument("middle", "published", "Middle", [0.8, 0.2, 0]),
    vectorDocument("far", "published", "Far", [0, 1, 0]),
    vectorDocument("draft-near", "draft", "Draft", [1, 0, 0]),
  ]) {
    await put(item, vectorScope);
  }

  const response = await dispatch({
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
  }, vectorScope);

  assert.equal(response.status, responseStatus.ok);
  assert.equal(response.payload, responsePayload.scoredRecords);
  assert.deepEqual(response.records.map((item) => item.record.id), ["near", "middle"]);
  assert.equal(response.records[0].distance, 0);
  assert.ok(response.records[1].distance > 0);
}

async function assertInvalidRequestEnvelope() {
  const response = await postBytes(new Uint8Array([0xff]), durableScope);
  const decoded = DatabaseWireCodec.decodeResponse(response);
  assert.equal(decoded.status, responseStatus.invalidRequest);
}

async function put(item, scope) {
  const response = await dispatch({
    operation: requestOperation.putRecord,
    record: item,
  }, scope);
  assert.equal(response.status, responseStatus.ok);
  assert.equal(response.payload, responsePayload.empty);
}

async function applySchema(value, scope) {
  const response = await dispatch({
    operation: requestOperation.applySchema,
    schema: value,
  }, scope);
  assert.equal(response.status, responseStatus.ok);
  assert.equal(response.payload, responsePayload.empty);
}

async function dispatch(request, scope) {
  return DatabaseWireCodec.decodeResponse(
    await postBytes(DatabaseWireCodec.encodeRequest(request), scope)
  );
}

async function queryIDs(scope, predicate, limit) {
  const response = await dispatch({
    operation: requestOperation.query,
    query: {
      typeName: "Article",
      predicate,
      limit,
    },
  }, scope);
  assert.equal(response.status, responseStatus.ok);
  assert.equal(response.payload, responsePayload.records);
  return response.records.map((item) => item.id);
}

async function postBytes(bytes, scope) {
  const response = await fetchWithTimeout(origin, {
    method: "POST",
    headers: scopeHeaders(scope),
    body: bytes,
  }, 10_000);
  if (response.status !== 200) {
    assert.equal(response.status, 200, await response.text());
  }
  return new Uint8Array(await response.arrayBuffer());
}

function scopeHeaders(scope) {
  return {
    "content-type": "application/octet-stream",
    "authorization": `Bearer ${accessToken}`,
    "x-database-id": scope.databaseID,
    "x-tenant-id": scope.tenantID,
    "x-workspace-id": scope.workspaceID,
  };
}

function writeDevVars() {
  writeFileSync(devVarsPath, [
    `DATABASE_ACCESS_TOKEN=${accessToken}`,
    "DATABASE_MAX_REQUEST_BYTES=4194304",
    "",
  ].join("\n"));
}

function removeDevVars() {
  rmSync(devVarsPath, { force: true });
}

function article(id, status, score, title, tags) {
  return record("Article", id, [
    namedValue("status", value(fieldValue.string, status)),
    namedValue("score", value(fieldValue.int64, score)),
    namedValue("title", value(fieldValue.string, title)),
    namedValue("tags", value(fieldValue.array, tags.map((tag) => value(fieldValue.string, tag)))),
  ]);
}

function articleSchema() {
  return schema([
    entitySchema("Article", 1, [
      fieldSchema("status", fieldType.string, 1),
      fieldSchema("score", fieldType.int64, 2),
      fieldSchema("title", fieldType.string, 3),
      fieldSchema("tags", fieldType.array, 4),
    ], [
      indexDescriptor("Article.status", indexKind.scalar, ["status"]),
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

async function fetchWithTimeout(url, init, timeout) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    return await fetch(url, {
      ...init,
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

async function stopWrangler(child) {
  if (child === null || child.exitCode !== null) {
    return;
  }
  child.kill("SIGTERM");
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    sleep(5_000).then(() => {
      if (child.exitCode === null) {
        child.kill("SIGKILL");
      }
    }),
  ]);
}

function trimOutput(output) {
  const maxLength = 12_000;
  return output.length <= maxLength ? output : output.slice(output.length - maxLength);
}
