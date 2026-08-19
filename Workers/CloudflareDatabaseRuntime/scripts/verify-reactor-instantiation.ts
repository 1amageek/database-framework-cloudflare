import { readFile } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { setTimeout as waitForDelay } from "node:timers/promises";
import {
  StorageKitDurableObjectHost,
  type StorageKitSQLBinding,
  type StorageKitSQLStorage,
} from "@storage-kit/cloudflare-durable-object-storage-host";
import { DatabaseRuntimeConnection } from "../src/DatabaseRuntimeConnection";
import { DatabaseRuntimeConnectionLimits } from "../src/DatabaseRuntimeConnectionLimits";
import { instantiateDatabaseRuntime } from "../src/instantiateDatabaseRuntime";
import type {
  DatabaseRuntimeInstantiator,
} from "../src/DatabaseRuntimeTypes";

const artifactPath = process.argv[2];
if (artifactPath === undefined) {
  throw new Error(
    "usage: node --import tsx scripts/verify-reactor-instantiation.ts <artifact.wasm>"
  );
}
const verifiedArtifactPath = artifactPath;
const includesMultiBase = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_MULTI_BASE"
);
const includesGraphIndexes = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_GRAPH_INDEXES"
);
const includesVectorIndexes = readRequiredFeatureFlag(
  "DATABASE_RUNTIME_VECTOR_INDEXES"
);
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });
const invocationContext = textEncoder.encode("runtime-verification");

async function verifyRuntime(): Promise<void> {
  const compilationStartedAt = performance.now();
  const runtimeProgram = await WebAssembly.compile(
    await readFile(verifiedArtifactPath)
  );
  const compilationMilliseconds = performance.now() - compilationStartedAt;
  const sqliteStorage = new NodeSQLiteStorage();
  const storageHost = new StorageKitDurableObjectHost(
    sqliteStorage,
    (operation) => sqliteStorage.transactionSync(operation)
  );
  storageHost.migrate();
  let terminalFailure: string | null = null;
  let instantiatedAddressSpace: WebAssembly.Memory | null = null;
  const scheduledAlarmTimestamps: number[] = [];
  const captureRuntimeAddressSpace: DatabaseRuntimeInstantiator = async (
    options
  ) => {
    const instance = await instantiateDatabaseRuntime(options);
    const addressSpace = instance.endpoints.memory;
    if (addressSpace instanceof WebAssembly.Memory) {
      instantiatedAddressSpace = addressSpace;
    }
    return instance;
  };

  let connection: DatabaseRuntimeConnection;
  const startupStartedAt = performance.now();
  try {
    connection = await DatabaseRuntimeConnection.instantiate(
      runtimeProgram,
      storageHost,
      {
        ensureWakeUpNoLaterThan: async (timestampMilliseconds) => {
          scheduledAlarmTimestamps.push(timestampMilliseconds);
        },
      },
      captureRuntimeAddressSpace,
      new DatabaseRuntimeConnectionLimits({
        maximumContextBytes: 1 * 1_024 * 1_024,
        maximumRequestBytes: 4 * 1_024 * 1_024,
        maximumResponseBytes: 4 * 1_024 * 1_024,
      }),
      (reason) => {
        terminalFailure = reason;
      },
      undefined,
      {
        wait: async (delayMilliseconds, signal) => {
          await waitForDelay(delayMilliseconds, undefined, { signal });
        },
      },
    );
  } catch (error) {
    const addressSpace = instantiatedAddressSpace as WebAssembly.Memory | null;
    console.error(JSON.stringify({
      addressSpaceBytes: addressSpace?.buffer.byteLength ?? null,
    }));
    throw error;
  }
  const startupMilliseconds = performance.now() - startupStartedAt;

  const invocationStartedAt = performance.now();
  const writeResponse = await invokeApplication(
    connection,
    "put:Cloudflare runtime"
  );
  assertTextResponse(writeResponse, "Cloudflare runtime", "write");
  const readResponse = await invokeApplication(connection, "get");
  assertTextResponse(readResponse, "Cloudflare runtime", "read");
  const echoResponse = await invokeApplication(connection, "echo:opaque");
  assertTextResponse(echoResponse, "opaque", "echo");
  if (includesVectorIndexes) {
    await verifyVectorLifecycle(connection);
  }
  await connection.alarm();
  const expectedAlarmTimestampMilliseconds = 4_102_444_800_000;
  if (scheduledAlarmTimestamps.length !== 1
      || scheduledAlarmTimestamps[0] !== expectedAlarmTimestampMilliseconds) {
    throw new Error(
      `alarm scheduled ${JSON.stringify(scheduledAlarmTimestamps)} instead of ${expectedAlarmTimestampMilliseconds}`
    );
  }
  const invocationMilliseconds = performance.now() - invocationStartedAt;

  if (terminalFailure !== null) {
    throw new Error(`runtime entered terminal failure: ${terminalFailure}`);
  }
  const addressSpaceBytes = connection.runtimeAddressSpaceByteCount;
  await connection.shutdown();

  console.log(JSON.stringify({
    artifactPath: verifiedArtifactPath,
    addressSpaceBytes,
    multiBase: includesMultiBase,
    graphIndexes: includesGraphIndexes,
    vectorIndexes: includesVectorIndexes,
    writeResponseBytes: writeResponse.byteLength,
    readResponseBytes: readResponse.byteLength,
    echoResponseBytes: echoResponse.byteLength,
    vectorLifecycle: includesVectorIndexes,
    alarmInvocation: true,
    scheduledAlarmTimestampMilliseconds: scheduledAlarmTimestamps[0],
    compilationMilliseconds,
    startupMilliseconds,
    invocationMilliseconds,
  }, null, 2));
}

async function verifyVectorLifecycle(
  connection: DatabaseRuntimeConnection
): Promise<void> {
  const steps = [
    ["vector:write", "vector:written"],
    ["vector:query-initial", "vector:initial"],
    ["vector:update", "vector:updated"],
    ["vector:query-updated", "vector:updated-query"],
    ["vector:delete", "vector:deleted"],
    ["vector:query-deleted", "vector:deleted-query"],
  ] as const;
  for (const [request, expected] of steps) {
    const response = await invokeApplication(connection, request);
    assertTextResponse(response, expected, request);
  }
}

async function invokeApplication(
  connection: DatabaseRuntimeConnection,
  request: string
): Promise<Uint8Array> {
  try {
    return await connection.invoke(
      textEncoder.encode(request),
      invocationContext
    );
  } catch (error) {
    throw new Error(`application invocation '${request}' failed`, {
      cause: error,
    });
  }
}

function assertTextResponse(
  response: Uint8Array,
  expected: string,
  operation: string
): void {
  const actual = textDecoder.decode(response);
  if (actual !== expected) {
    throw new Error(
      `${operation} returned '${actual}' instead of '${expected}'`
    );
  }
}

function readRequiredFeatureFlag(name: string): boolean {
  const value = process.env[name];
  if (value === "1") {
    return true;
  }
  if (value === "0") {
    return false;
  }
  throw new Error(`${name} must be either 0 or 1`);
}

class NodeSQLiteStorage implements StorageKitSQLStorage {
  private readonly database = new DatabaseSync(":memory:");

  exec(
    statement: string,
    ...bindings: StorageKitSQLBinding[]
  ): unknown {
    const normalizedBindings = bindings.map((value) => {
      if (value instanceof ArrayBuffer) {
        return new Uint8Array(value);
      }
      if (ArrayBuffer.isView(value)) {
        return new Uint8Array(
          value.buffer,
          value.byteOffset,
          value.byteLength
        );
      }
      return value;
    });
    const prepared = this.database.prepare(statement);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(statement)) {
      return prepared.all(...normalizedBindings);
    }
    prepared.run(...normalizedBindings);
    return [];
  }

  transactionSync<Result>(operation: () => Result): Result {
    this.database.exec("BEGIN IMMEDIATE");
    try {
      const result = operation();
      this.database.exec("COMMIT");
      return result;
    } catch (error) {
      this.database.exec("ROLLBACK");
      throw error;
    }
  }
}

await verifyRuntime();
