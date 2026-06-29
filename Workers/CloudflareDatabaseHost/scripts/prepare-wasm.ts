import { copyFileSync, existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const workerDirectory = resolve(scriptDirectory, "..");
const source = resolve(
  workerDirectory,
  "../../.build/wasm32-unknown-wasip1/release/CloudflareDatabaseRuntime.wasm"
);
const destination = resolve(workerDirectory, "src/CloudflareDatabaseRuntime.wasm");

if (!existsSync(source)) {
  throw new Error([
    "CloudflareDatabaseRuntime.wasm was not found.",
    "Build it first with:",
    "swiftly run swift build +6.3.1 --swift-sdk swift-6.3.1-RELEASE_wasm --product CloudflareDatabaseRuntime -c release",
  ].join(" "));
}

mkdirSync(dirname(destination), { recursive: true });
copyFileSync(source, destination);

const size = statSync(destination).size;
if (size <= 0) {
  throw new Error("Copied CloudflareDatabaseRuntime.wasm is empty.");
}

console.log(`Prepared ${destination} (${size} bytes)`);
