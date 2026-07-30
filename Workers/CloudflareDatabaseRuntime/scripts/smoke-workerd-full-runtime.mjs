import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFile, readFile, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const packageDirectory = fileURLToPath(new URL("..", import.meta.url));
const requestVectorPath = fileURLToPath(
  new URL("../../../Protocol/runtime-verification-requests-v1.json", import.meta.url)
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
  const mutationResponse = await execute(vectors.mutationExecute);
  verifySuccessResponse(mutationResponse, vectors.mutationExecute);
  const queryResponse = await execute(vectors.queryExecute);
  verifySuccessResponse(queryResponse, vectors.queryExecute);
  assertPayloadContains(queryResponse, "Cloudflare runtime");
  const graphQueryResponse = await execute(vectors.queryAsk);
  verifySuccessResponse(graphQueryResponse, vectors.queryAsk);
  assertBooleanResponse(graphQueryResponse, true);

  await stopWorker(worker);
  worker = null;

  worker = startWorker();
  await waitForWorker(worker);
  const persistedQueryResponse = await execute(vectors.queryExecute);
  verifySuccessResponse(persistedQueryResponse, vectors.queryExecute);
  assertPayloadContains(persistedQueryResponse, "Cloudflare runtime");
  const persistedGraphQueryResponse = await execute(vectors.queryAsk);
  verifySuccessResponse(persistedGraphQueryResponse, vectors.queryAsk);
  assertBooleanResponse(persistedGraphQueryResponse, true);

  console.log(JSON.stringify({
    runtimeArtifactPath,
    workerdDurableObjectRPC: true,
    sqlitePersistenceAfterRestart: true,
    capabilitiesResponseBytes: capabilitiesResponse.byteLength,
    schemaResponseBytes: schemaResponse.byteLength,
    mutationResponseBytes: mutationResponse.byteLength,
    queryResponseBytes: queryResponse.byteLength,
    graphQueryResponseBytes: graphQueryResponse.byteLength,
    persistedGraphQueryResponseBytes:
      persistedGraphQueryResponse.byteLength,
  }, null, 2));
} finally {
  if (worker !== null) {
    await stopWorker(worker);
  }
  await rm(statePath, { recursive: true, force: true });
  await rm(fixtureArtifactPath, { force: true });
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
  assert.equal(response.byteLength, 24);
  assert.equal(response[22], 2);
  assert.equal(response[23], expectedValue ? 1 : 0);
}

async function stopWorker(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  child.stdin.write("x");
  const exit = once(child, "exit");
  const forcedStop = delay(5_000).then(() => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
    }
  });
  await Promise.race([exit, forcedStop]);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
