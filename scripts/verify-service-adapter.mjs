import { spawnSync } from "node:child_process";
import {
  cp,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(
  dirname(fileURLToPath(import.meta.url)),
  ".."
);
const templateRoot = join(
  repositoryRoot,
  "Adapter",
  "Templates",
  "Service",
  "database"
);
const temporaryRoot = await mkdtemp(
  join(tmpdir(), "database-framework-cloudflare-adapter-")
);

try {
  await verifyTemplateReferences();
  const serviceRoot = join(temporaryRoot, "service");
  await cp(join(templateRoot, "cloudflare"), join(serviceRoot, "cloudflare"), {
    recursive: true,
  });
  await renderDirectory(join(serviceRoot, "cloudflare"));
  await writeFile(
    join(serviceRoot, "cloudflare", "src", "database.wasm"),
    Uint8Array.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
  );

  run("npm", ["install", "--ignore-scripts"], join(serviceRoot, "cloudflare"));
  run("npm", ["run", "types:generate"], join(serviceRoot, "cloudflare"));
  run("npm", ["run", "typecheck"], join(serviceRoot, "cloudflare"));
  run("npm", ["run", "deploy:check"], join(serviceRoot, "cloudflare"));

  console.log("Verified rendered Cloudflare database service adapter");
} finally {
  await rm(temporaryRoot, { recursive: true, force: true });
}

async function verifyTemplateReferences() {
  const manifestPath = join(repositoryRoot, "Adapter", "sweb.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const service = manifest.services?.database;
  if (service === undefined) {
    throw new Error("Adapter manifest does not define the database service");
  }
  for (const template of service.templates ?? []) {
    const source = resolve(repositoryRoot, template.source);
    if (relative(repositoryRoot, source).startsWith("..")) {
      throw new Error(`Adapter template escapes the repository: ${template.source}`);
    }
    await readdir(source);
  }

  await readFile(
    join(templateRoot, "wasm", "verify-exports.mjs"),
    "utf8"
  );
  await readFile(
    join(
      templateRoot,
      "cloudflare",
      "scripts",
      "validate-worker-bundle-size.mjs"
    ),
    "utf8"
  );
}

async function renderDirectory(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      await renderDirectory(path);
      continue;
    }
    const source = await readFile(path, "utf8");
    const rendered = source.replace(
      /\{\{([^}]+)\}\}/g,
      (_placeholder, key) => substitution(key)
    );
    if (/\{\{[^}]+\}\}/.test(rendered)) {
      throw new Error(`Unresolved adapter placeholder in ${path}`);
    }
    await writeFile(path, rendered);
  }
}

function substitution(key) {
  const values = {
    "service.adapter.root": repositoryRoot,
    "service.application.kebabName": "adapter-verification",
    "service.cloudflare.bindingName": "DATABASE",
    "service.cloudflare.className": "CloudflareDatabaseObject",
    "service.cloudflare.compatibilityDate": "2026-08-19",
    "service.cloudflare.databaseID": "adapter-verification",
    "service.cloudflare.objectName": "default",
    "service.cloudflare.workerName": "adapter-verification-database",
  };
  const value = values[key];
  if (value === undefined) {
    throw new Error(`Unknown adapter placeholder: ${key}`);
  }
  return value;
}

function run(executable, arguments_, workingDirectory) {
  const result = spawnSync(executable, arguments_, {
    cwd: workingDirectory,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    shell: false,
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `${executable} ${arguments_.join(" ")} failed with status ${result.status}`
    );
  }
}
