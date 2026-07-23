import { readFile } from "node:fs/promises";

const artifactPath = process.argv[2];
if (artifactPath === undefined) {
  throw new Error("usage: node scripts/verify-reactor-abi.mjs <artifact.wasm>");
}

const requiredExports = new Map([
  ["memory", "memory"],
  ["_initialize", "function"],
  ["database_alloc", "function"],
  ["database_dealloc", "function"],
  ["database_start", "function"],
  ["database_invoke", "function"],
  ["database_alarm", "function"],
  ["database_executor_run", "function"],
  ["database_clock_resume", "function"],
]);
const requiredRuntimeImports = new Map([
  ["storage_host.dispatch", "function"],
  ["database_host.complete", "function"],
  ["database_executor.schedule", "function"],
  ["database_alarm.schedule", "function"],
  ["database_clock.schedule", "function"],
  ["database_clock.cancel", "function"],
]);
const allowedImportModules = new Set([
  "storage_host",
  "database_host",
  "database_executor",
  "database_alarm",
  "database_clock",
  "wasi_snapshot_preview1",
]);

const artifactBytes = await readFile(artifactPath);
const runtimeModule = await WebAssembly.compile(artifactBytes);
const exportsByName = new Map(
  WebAssembly.Module.exports(runtimeModule).map((endpoint) => [
    endpoint.name,
    endpoint.kind,
  ])
);
for (const [name, kind] of requiredExports) {
  if (exportsByName.get(name) !== kind) {
    throw new Error(`required reactor export ${name}:${kind} is missing`);
  }
}
if (exportsByName.has("_start")) {
  throw new Error("reactor artifact exports command entrypoint _start");
}

const imports = WebAssembly.Module.imports(runtimeModule);
const importsByName = new Map(
  imports.map((endpoint) => [
    `${endpoint.module}.${endpoint.name}`,
    endpoint.kind,
  ])
);
for (const [name, kind] of requiredRuntimeImports) {
  if (importsByName.get(name) !== kind) {
    throw new Error(`required reactor import ${name}:${kind} is missing`);
  }
}
for (const endpoint of imports) {
  if (!allowedImportModules.has(endpoint.module)) {
    throw new Error(
      `reactor imports undeclared service ${endpoint.module}.${endpoint.name}`
    );
  }
}

console.log(JSON.stringify({
  artifactPath,
  artifactBytes: artifactBytes.byteLength,
  exports: [...exportsByName.keys()].sort(),
  runtimeImports: imports
    .filter((endpoint) => endpoint.module !== "wasi_snapshot_preview1")
    .map((endpoint) => `${endpoint.module}.${endpoint.name}`)
    .sort(),
  wasiImportCount: imports.filter(
    (endpoint) => endpoint.module === "wasi_snapshot_preview1"
  ).length,
}, null, 2));
