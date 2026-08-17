import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { databaseCompletionStatus } from "../src/DatabaseCompletionStatus";

test("TypeScript statuses match the canonical ABI v3 vector", async () => {
  const vectorURL = new URL(
    "../../../Protocol/database-completion-status-v3.json",
    import.meta.url
  );
  const vector = JSON.parse(
    await readFile(vectorURL, { encoding: "utf8" })
  ) as Record<string, number>;

  assert.deepEqual(databaseCompletionStatus, vector);
});
