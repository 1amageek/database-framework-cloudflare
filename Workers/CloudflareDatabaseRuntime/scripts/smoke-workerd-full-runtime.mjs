import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFile, readFile, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const packageDirectory = fileURLToPath(new URL("..", import.meta.url));
const includesMultipleBases = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_MULTIPLE_BASES"
);
const includesGraphIndexes = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_GRAPH_INDEXES"
);
const includesVectorIndexes = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_VECTOR_INDEXES"
);
const requestVectorPath = fileURLToPath(
  new URL(
    includesMultipleBases
      ? "../../../Protocol/runtime-verification-requests-multiple-bases-v1.json"
      : "../../../Protocol/runtime-verification-requests-standard-v1.json",
    import.meta.url
  )
);
const fixtureArtifactPath = fileURLToPath(
  new URL(
    "../test/fixtures/CloudflareDatabaseRuntimeVerification.wasm",
    import.meta.url
  )
);
const runtimeArtifactPath = process.env.DATABASE_RUNTIME_ARTIFACT;
if (runtimeArtifactPath === undefined || runtimeArtifactPath.length === 0) {
  throw new Error("DATABASE_RUNTIME_ARTIFACT must name the verified WASI reactor");
}

const host = process.env.DATABASE_WORKERD_HOST ?? "127.0.0.1";
const port = Number(process.env.DATABASE_WORKERD_PORT ?? "18791");
const endpoint = `http://${host}:${port}`;
const statePath = fileURLToPath(
  new URL(`../.wrangler/full-runtime-smoke-${process.pid}`, import.meta.url)
);
const readyTimeoutMilliseconds = 60_000;
const vectors = JSON.parse(await readFile(requestVectorPath, "utf8"));

await copyFile(runtimeArtifactPath, fixtureArtifactPath);
await rm(statePath, { recursive: true, force: true });

let worker = null;
try {
  worker = startWorker();
  await waitForWorker(worker);
  const capabilitiesResponse = await execute(vectors.capabilitiesDescribe);
  verifySuccessResponse(capabilitiesResponse, vectors.capabilitiesDescribe);
  const schemaResponse = await execute(vectors.schemaDescribe);
  verifySuccessResponse(schemaResponse, vectors.schemaDescribe);
  assertPayloadContains(schemaResponse, "RuntimeVerificationDocument");
  let baseCreateResponse = null;
  if (includesMultipleBases) {
    baseCreateResponse = await execute(vectors.baseCreate);
    verifySuccessResponse(baseCreateResponse, vectors.baseCreate);
    await runScheduledWork();
  }
  const mutationResponse = await execute(vectors.mutationExecute);
  verifySuccessResponse(mutationResponse, vectors.mutationExecute);
  const queryResponse = await execute(vectors.queryExecute);
  verifySuccessResponse(queryResponse, vectors.queryExecute);
  assertPayloadContains(queryResponse, "Cloudflare runtime");
  let graphQueryResponse = null;
  if (includesGraphIndexes) {
    graphQueryResponse = await execute(vectors.queryAsk);
    verifySuccessResponse(graphQueryResponse, vectors.queryAsk);
    assertBooleanResponse(graphQueryResponse, true);
  }
  let vectorIVFResponse = null;
  let vectorPQResponse = null;
  let vectorFlatResponse = null;
  if (includesVectorIndexes) {
    const vectorMutationResponse = await execute(vectors.vectorMutationExecute);
    verifySuccessResponse(vectorMutationResponse, vectors.vectorMutationExecute);
    const vectorIVFRebuildResponse = await execute(vectors.vectorIVFRebuild);
    verifySuccessResponse(vectorIVFRebuildResponse, vectors.vectorIVFRebuild);
    const vectorPQRebuildResponse = await execute(vectors.vectorPQRebuild);
    verifySuccessResponse(vectorPQRebuildResponse, vectors.vectorPQRebuild);
    vectorIVFResponse = await execute(vectors.vectorIVFQuery);
    verifySuccessResponse(vectorIVFResponse, vectors.vectorIVFQuery);
    assertPayloadContains(
      vectorIVFResponse,
      "RuntimeVerificationIVFDocument-exact"
    );
    vectorPQResponse = await execute(vectors.vectorPQQuery);
    verifySuccessResponse(vectorPQResponse, vectors.vectorPQQuery);
    assertPayloadContains(
      vectorPQResponse,
      "RuntimeVerificationPQDocument-exact"
    );
    vectorFlatResponse = await execute(vectors.vectorFlatQuery);
    verifySuccessResponse(vectorFlatResponse, vectors.vectorFlatQuery);
    assertPayloadContains(
      vectorFlatResponse,
      "RuntimeVerificationFlatDocument-exact"
    );
    const vectorDeleteResponse = await execute(vectors.vectorDelete);
    verifySuccessResponse(vectorDeleteResponse, vectors.vectorDelete);
  }

  await stopWorker(worker);
  worker = null;

  worker = startWorker();
  await waitForWorker(worker);
  const persistedQueryResponse = await execute(vectors.queryExecute);
  verifySuccessResponse(persistedQueryResponse, vectors.queryExecute);
  assertPayloadContains(persistedQueryResponse, "Cloudflare runtime");
  let persistedGraphQueryResponse = null;
  if (includesGraphIndexes) {
    persistedGraphQueryResponse = await execute(vectors.queryAsk);
    verifySuccessResponse(persistedGraphQueryResponse, vectors.queryAsk);
    assertBooleanResponse(persistedGraphQueryResponse, true);
  }

  console.log(JSON.stringify({
    runtimeArtifactPath,
    workerdDurableObjectRPC: true,
    sqlitePersistenceAfterRestart: true,
    multipleBases: includesMultipleBases,
    graphIndexes: includesGraphIndexes,
    vectorIndexes: includesVectorIndexes,
    capabilitiesResponseBytes: capabilitiesResponse.byteLength,
    schemaResponseBytes: schemaResponse.byteLength,
    baseCreateResponseBytes: baseCreateResponse?.byteLength ?? null,
    mutationResponseBytes: mutationResponse.byteLength,
    queryResponseBytes: queryResponse.byteLength,
    graphQueryResponseBytes: graphQueryResponse?.byteLength ?? null,
    vectorIVFResponseBytes: vectorIVFResponse?.byteLength ?? null,
    vectorPQResponseBytes: vectorPQResponse?.byteLength ?? null,
    vectorFlatResponseBytes: vectorFlatResponse?.byteLength ?? null,
    persistedGraphQueryResponseBytes:
      persistedGraphQueryResponse?.byteLength ?? null,
  }, null, 2));
} finally {
  if (worker !== null) {
    await stopWorker(worker);
  }
  await rm(statePath, { recursive: true, force: true });
  await rm(fixtureArtifactPath, { force: true });
}

function readRequiredFeatureFlag(name) {
  const value = process.env[name];
  if (value === "1") {
    return true;
  }
  if (value === "0") {
    return false;
  }
  throw new Error(`${name} must be either 0 or 1`);
}

function startWorker() {
  const wrangler = process.platform === "win32"
    ? "node_modules/.bin/wrangler.cmd"
    : "node_modules/.bin/wrangler";
  const child = spawn(wrangler, [
    "dev",
    "--config",
    "wrangler.jsonc",
    "--port",
    String(port),
    "--ip",
    host,
    "--persist-to",
    statePath,
  ], {
    cwd: packageDirectory,
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => process.stdout.write(chunk));
  child.stderr.on("data", (chunk) => process.stderr.write(chunk));
  return child;
}

async function waitForWorker(child) {
  const deadline = Date.now() + readyTimeoutMilliseconds;
  let lastError = null;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`wrangler dev exited early with code ${child.exitCode}`);
    }
    try {
      const response = await fetch(endpoint, { method: "GET" });
      if (response.status === 405) {
        return;
      }
    } catch (error) {
      lastError = error;
    }
    await delay(250);
  }
  throw new Error(`Worker did not become ready: ${String(lastError)}`);
}

async function execute(requestBytes) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/octet-stream",
      accept: "application/octet-stream",
    },
    body: Uint8Array.from(requestBytes),
  });
  if (response.status !== 200) {
    assert.fail(
      `workerd returned HTTP ${response.status}: ${await response.text()}`
    );
  }
  return new Uint8Array(await response.arrayBuffer());
}

async function runScheduledWork() {
  const response = await fetch(`${endpoint}/scheduled-work`, {
    method: "POST",
  });
  if (response.status !== 204) {
    assert.fail(
      `scheduled work returned HTTP ${response.status}: ${await response.text()}`
    );
  }
}

function verifySuccessResponse(response, request) {
  assert.ok(response.byteLength >= 22);
  const responseView = new DataView(
    response.buffer,
    response.byteOffset,
    response.byteLength
  );
  const requestView = new DataView(
    Uint8Array.from(request).buffer
  );
  assert.deepEqual([...response.subarray(0, 4)], [0x44, 0x42, 0x57, 0x52]);
  assert.equal(responseView.getUint16(4, true), 1);
  assert.equal(responseView.getUint8(6), 2);
  assert.equal(responseView.getBigUint64(7, true), requestView.getBigUint64(7, true));
  assert.equal(responseView.getUint16(15, true), requestView.getUint16(15, true));
  assert.equal(responseView.getUint8(17), 1);
  assert.equal(responseView.getUint32(18, true) + 22, response.byteLength);
}

function assertPayloadContains(response, expectedText) {
  const expected = new TextEncoder().encode(expectedText);
  const payload = response.subarray(22);
  for (let start = 0; start + expected.byteLength <= payload.byteLength; start += 1) {
    let matches = true;
    for (let index = 0; index < expected.byteLength; index += 1) {
      if (payload[start + index] !== expected[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return;
    }
  }
  assert.fail(`response does not contain ${expectedText}`);
}

function assertBooleanResponse(response, expectedValue) {
  const payload = new DataView(
    response.buffer,
    response.byteOffset + 22,
    response.byteLength - 22
  );
  let offset = 0;
  const requireBytes = (byteCount) => {
    assert.ok(
      offset + byteCount <= payload.byteLength,
      "boolean response is truncated"
    );
  };
  requireBytes(4);
  assert.equal(payload.getUint8(offset), 2);
  offset += 1;
  assert.equal(payload.getUint8(offset), expectedValue ? 1 : 0);
  offset += 1;
  assert.equal(
    payload.getUint8(offset),
    0,
    "Base-local boolean response unexpectedly has provenance"
  );
  offset += 1;
  assert.equal(
    payload.getUint8(offset),
    0,
    "Base-local boolean response is not transactional"
  );
  offset += 1;
  requireBytes(4);
  const domainByteCount = payload.getUint32(offset, true);
  offset += 4;
  requireBytes(domainByteCount + 9);
  const domain = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(
      payload.buffer,
      payload.byteOffset + offset,
      domainByteCount
    )
  );
  offset += domainByteCount;
  assert.equal(domain, "primary");
  assert.equal(
    payload.getUint8(offset),
    0,
    "boolean response did not use a version read point"
  );
  offset += 1;
  payload.getBigUint64(offset, true);
  offset += 8;
  assert.equal(offset, payload.byteLength, "boolean response has trailing bytes");
}

async function stopWorker(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    await waitForWorkerStopped();
    return;
  }
  const exit = once(child, "exit");
  child.stdin.end("x");
  if (!await waitForProcessExit(exit, 5_000)) {
    child.kill("SIGTERM");
    if (!await waitForProcessExit(exit, 5_000)) {
      child.kill("SIGKILL");
      await exit;
    }
  }
  await waitForWorkerStopped();
}

async function waitForProcessExit(exit, timeoutMilliseconds) {
  return Promise.race([
    exit.then(() => true),
    delay(timeoutMilliseconds).then(() => false),
  ]);
}

async function waitForWorkerStopped() {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      await fetch(endpoint, { signal: AbortSignal.timeout(500) });
    } catch {
      return;
    }
    await delay(100);
  }
  throw new Error("Worker endpoint remained reachable after process exit");
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
