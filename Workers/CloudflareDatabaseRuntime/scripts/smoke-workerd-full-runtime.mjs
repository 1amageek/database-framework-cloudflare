import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFile, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const packageDirectory = fileURLToPath(new URL("..", import.meta.url));
const includesMultiBase = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_MULTI_BASE"
);
const includesGraphIndexes = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_GRAPH_INDEXES"
);
const includesVectorIndexes = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_VECTOR_INDEXES"
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

await copyFile(runtimeArtifactPath, fixtureArtifactPath);
await rm(statePath, { recursive: true, force: true });

let worker = null;
try {
  worker = startWorker();
  await waitForWorker(worker);
  const writeResponse = await invoke("put:Cloudflare runtime");
  assert.equal(writeResponse, "Cloudflare runtime");
  const readResponse = await invoke("get");
  assert.equal(readResponse, "Cloudflare runtime");
  if (includesVectorIndexes) {
    assert.equal(await invoke("vector:write"), "vector:written");
    assert.equal(await invoke("vector:query-initial"), "vector:initial");
    assert.equal(await invoke("vector:update"), "vector:updated");
    assert.equal(
      await invoke("vector:query-updated"),
      "vector:updated-query"
    );
  }

  await stopWorker(worker);
  worker = null;

  worker = startWorker();
  await waitForWorker(worker);
  const persistedReadResponse = await invoke("get");
  assert.equal(persistedReadResponse, "Cloudflare runtime");
  if (includesVectorIndexes) {
    assert.equal(
      await invoke("vector:query-updated"),
      "vector:updated-query"
    );
    assert.equal(await invoke("vector:delete"), "vector:deleted");
    assert.equal(
      await invoke("vector:query-deleted"),
      "vector:deleted-query"
    );
  }

  console.log(JSON.stringify({
    runtimeArtifactPath,
    workerdDurableObjectRPC: true,
    sqlitePersistenceAfterRestart: true,
    multiBase: includesMultiBase,
    graphIndexes: includesGraphIndexes,
    vectorIndexes: includesVectorIndexes,
    vectorLifecycle: includesVectorIndexes,
    writeResponseBytes: new TextEncoder().encode(writeResponse).byteLength,
    readResponseBytes: new TextEncoder().encode(readResponse).byteLength,
    persistedReadResponseBytes:
      new TextEncoder().encode(persistedReadResponse).byteLength,
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

async function invoke(requestText) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/octet-stream",
      accept: "application/octet-stream",
    },
    body: new TextEncoder().encode(requestText),
  });
  if (response.status !== 200) {
    assert.fail(
      `workerd returned HTTP ${response.status}: ${await response.text()}`
    );
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(
    await response.arrayBuffer()
  );
}

async function stopWorker(child) {
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGTERM");
    const exited = await Promise.race([
      once(child, "exit").then(() => true),
      delay(5_000).then(() => false),
    ]);
    assert.equal(exited, true, "wrangler dev did not stop after SIGTERM");
  }
  await requireWorkerStopped();
}

async function requireWorkerStopped() {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      await fetch(endpoint, { method: "GET", signal: AbortSignal.timeout(500) });
    } catch {
      return;
    }
    await delay(100);
  }
  assert.fail("wrangler dev remained reachable after shutdown");
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
