import assert from "node:assert/strict";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { existsSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Readable } from "node:stream";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import {
  DatabaseWireCodec,
  type DatabaseWireDecodedResponse,
  type DatabaseWireNamedValue,
  type DatabaseWireRecord,
  type DatabaseWireRequest,
  type DatabaseWireSchema,
  entitySchema,
  fieldSchema,
  fieldType,
  namedValue,
  record,
  requestOperation,
  responsePayload,
  responseStatus,
  schema,
  value,
  fieldValue,
} from "../src/DatabaseWireCodec";

type WranglerProcess = ChildProcessByStdio<null, Readable, Readable> & {
  output: string;
};

type SmokeScope = {
  databaseID: string;
  tenantID: string;
  workspaceID: string;
};

const port = Number(process.env.CLOUDFLARE_DATABASE_PERSISTENCE_PORT ?? "18790");
const origin = `http://127.0.0.1:${port}`;
const packageRoot = fileURLToPath(new URL("..", import.meta.url));
const devVarsPath = join(packageRoot, ".dev.vars");
const statePath = join(packageRoot, ".wrangler", "database-persistence-smoke");
const accessToken = "local-database-persistence-token";
const durableScope = {
  databaseID: `database-local-persistence-${process.pid}-${Date.now()}`,
  tenantID: "tenant-persistence",
  workspaceID: "workspace-persistence",
};
let wrangler: WranglerProcess | null = null;

rmSync(statePath, { recursive: true, force: true });
writeDevVars();

try {
  wrangler = startWrangler();
  await waitForWorker(wrangler);
  await writeRecord();
  await stopWrangler(wrangler);
  wrangler = null;

  wrangler = startWrangler();
  await waitForWorker(wrangler);
  await readRecord();
  console.log("Cloudflare database host local persistence smoke passed");
} finally {
  await stopWrangler(wrangler);
  removeDevVars();
  rmSync(statePath, { recursive: true, force: true });
}

function startWrangler(): WranglerProcess {
  const localWrangler = join(packageRoot, "node_modules", ".bin", "wrangler");
  const command = existsSync(localWrangler) ? localWrangler : "npx";
  const args = existsSync(localWrangler)
    ? ["dev", "--port", String(port), "--ip", "127.0.0.1", "--persist-to", statePath]
    : ["wrangler", "dev", "--port", String(port), "--ip", "127.0.0.1", "--persist-to", statePath];
  const child = spawn(command, args, {
    cwd: packageRoot,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  }) as WranglerProcess;
  child.output = "";
  child.stdout.on("data", (chunk) => {
    child.output = trimOutput(child.output + chunk.toString());
  });
  child.stderr.on("data", (chunk) => {
    child.output = trimOutput(child.output + chunk.toString());
  });
  return child;
}

async function waitForWorker(child: WranglerProcess): Promise<void> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < 60_000) {
    if (child.exitCode !== null) {
      throw new Error(`wrangler dev exited early\n${child.output}`);
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
  throw new Error(`wrangler dev did not become ready\n${child.output}`);
}

async function writeRecord() {
  await applySchema(articleSchema(), durableScope);
  const response = await dispatch({
    operation: requestOperation.putRecord,
    record: article("persistent", "published", 42, "Persisted Durable Object"),
  }, durableScope);
  assert.equal(response.status, responseStatus.ok);
  assert.equal(response.payload, responsePayload.empty);
}

async function readRecord() {
  const response = await dispatch({
    operation: requestOperation.getRecord,
    typeName: "Article",
    id: "persistent",
  }, durableScope);
  assert.equal(response.status, responseStatus.ok);
  assert.equal(response.payload, responsePayload.record);
  const item = requireRecord(response);
  assert.equal(item.id, "persistent");
  assert.deepEqual(field(item, "title").value, value(fieldValue.string, "Persisted Durable Object"));
}

async function applySchema(value: DatabaseWireSchema, scope: SmokeScope): Promise<void> {
  const response = await dispatch({
    operation: requestOperation.applySchema,
    schema: value,
  }, scope);
  assert.equal(response.status, responseStatus.ok);
  assert.equal(response.payload, responsePayload.empty);
}

async function dispatch(request: DatabaseWireRequest, scope: SmokeScope): Promise<DatabaseWireDecodedResponse> {
  return DatabaseWireCodec.decodeResponse(
    await postBytes(DatabaseWireCodec.encodeRequest(request), scope)
  );
}

async function postBytes(bytes: Uint8Array, scope: SmokeScope): Promise<Uint8Array> {
  const response = await fetchWithTimeout(origin, {
    method: "POST",
    headers: scopeHeaders(scope),
    body: toArrayBuffer(bytes),
  }, 10_000);
  if (response.status !== 200) {
    assert.equal(response.status, 200, await response.text());
  }
  return new Uint8Array(await response.arrayBuffer());
}

function scopeHeaders(scope: SmokeScope): HeadersInit {
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

function article(id: string, status: string, score: number, title: string): DatabaseWireRecord {
  return record("Article", id, [
    namedValue("status", value(fieldValue.string, status)),
    namedValue("score", value(fieldValue.int64, score)),
    namedValue("title", value(fieldValue.string, title)),
  ]);
}

function articleSchema(): DatabaseWireSchema {
  return schema([
    entitySchema("Article", 1, [
      fieldSchema("status", fieldType.string, 1),
      fieldSchema("score", fieldType.int64, 2),
      fieldSchema("title", fieldType.string, 3),
    ]),
  ]);
}

function field(item: DatabaseWireRecord, name: string): DatabaseWireNamedValue {
  const match = item.fields.find((candidate) => candidate.name === name);
  assert.notEqual(match, undefined);
  if (match === undefined) {
    throw new Error(`Missing field ${name}`);
  }
  return match;
}

async function fetchWithTimeout(url: string, init: RequestInit, timeout: number): Promise<Response> {
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

async function stopWrangler(child: WranglerProcess | null): Promise<void> {
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

function trimOutput(output: string): string {
  const maxLength = 12_000;
  return output.length <= maxLength ? output : output.slice(output.length - maxLength);
}

function requireRecord(response: DatabaseWireDecodedResponse): DatabaseWireRecord {
  assert.notEqual(response.record, null);
  if (response.record === null) {
    throw new Error("Expected record response");
  }
  return response.record;
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}
