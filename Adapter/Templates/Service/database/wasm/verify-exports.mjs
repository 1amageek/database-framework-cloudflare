import { readFile } from "node:fs/promises";

const [artifactPath] = process.argv.slice(2);
if (artifactPath === undefined) {
  throw new Error("A WebAssembly artifact path is required");
}

const bytes = await readFile(artifactPath);
const module = await WebAssembly.compile(bytes);
const exports = new Set(
  WebAssembly.Module.exports(module).map((entry) => entry.name),
);
const requiredExports = [
  "_initialize",
  "memory",
  "database_abi_version",
  "database_alloc",
  "database_dealloc",
  "database_start",
  "database_invoke",
  "database_alarm",
  "database_shutdown",
  "database_executor_run",
  "database_clock_resume",
];

for (const name of requiredExports) {
  if (!exports.has(name)) {
    throw new Error(`Missing WebAssembly export: ${name}`);
  }
}

if (exports.has("_start") || exports.has("database_dispatch")) {
  throw new Error("Legacy command or executable exports are not allowed");
}
