import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const [reactorArtifact, buildDataDirectory] = process.argv.slice(2);

if (reactorArtifact === undefined || buildDataDirectory === undefined) {
  throw new Error(
    "Usage: extract-reactor-link-arguments.mjs <reactor-artifact> <build-data-directory>",
  );
}

const pendingDirectories = [buildDataDirectory];
const manifestPaths = [];

while (pendingDirectories.length > 0) {
  const directory = pendingDirectories.pop();
  if (directory === undefined) {
    continue;
  }
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      pendingDirectories.push(path);
    } else if (entry.isFile() && entry.name === "manifest.json") {
      manifestPaths.push(path);
    }
  }
}

const matchingArgumentLists = [];
for (const manifestPath of manifestPaths.sort()) {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  for (const command of Object.values(manifest.commands ?? {})) {
    if (
      Array.isArray(command.outputs) &&
      command.outputs.includes(reactorArtifact) &&
      Array.isArray(command.args)
    ) {
      matchingArgumentLists.push(command.args);
    }
  }
}

if (matchingArgumentLists.length === 0) {
  throw new Error(`No linker command produces ${reactorArtifact}`);
}

const canonicalArguments = JSON.stringify(matchingArgumentLists[0]);
if (
  matchingArgumentLists.some(
    (argumentsList) => JSON.stringify(argumentsList) !== canonicalArguments,
  )
) {
  throw new Error(`Conflicting linker commands produce ${reactorArtifact}`);
}

process.stdout.write(`${matchingArgumentLists[0].join("\n")}\n`);
