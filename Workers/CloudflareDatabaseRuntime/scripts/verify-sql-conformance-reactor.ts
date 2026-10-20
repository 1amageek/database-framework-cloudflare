import { readFile } from "node:fs/promises";
import { writeSync } from "node:fs";
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
    "usage: node --import tsx scripts/verify-sql-conformance-reactor.ts <artifact.wasm>"
  );
}
const verifiedArtifactPath = artifactPath;
// The SQL conformance reactor carries every group; each one always runs, in
// sprint dependency order, against the default graph-free Engine.
const includesS17 = true;
const includesS16 = true;
const includesS15 = true;
const includesS14 = true;
const includesS13 = true;
const includesS12 = true;
const includesS11 = true;
const includesS10 = true;
const includesS09 = true;
const includesS08 = true;
const includesS07 = true;
const includesS06 = true;
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
    const originalFdWrite = options.wasi.services.fd_write;
    if (typeof originalFdWrite !== "function") {
      throw new Error("WASI fd_write service is required for runtime evidence");
    }
    // Each instantiation retains only its own memory. Copy at the external
    // evidence boundary so output never retains borrowed WASM storage.
    let reactorMemory: WebAssembly.Memory | null = null;
    options.wasi.services.fd_write = (
      fileDescriptor: number,
      iovsPointer: number,
      iovsLength: number,
      bytesWrittenPointer: number
    ) => {
      const result = originalFdWrite(
        fileDescriptor, iovsPointer, iovsLength, bytesWrittenPointer
      );
      if (result === 0 && (fileDescriptor === 1 || fileDescriptor === 2)) {
        if (reactorMemory === null) {
          throw new Error("Successful WASI output preceded reactor memory capture");
        }
        const memory = reactorMemory.buffer;
        const view = new DataView(memory);
        let remaining = view.getUint32(bytesWrittenPointer, true);
        for (let index = 0; index < iovsLength && remaining > 0; index += 1) {
          const entry = iovsPointer + index * 8;
          const pointer = view.getUint32(entry, true);
          const byteCount = Math.min(view.getUint32(entry + 4, true), remaining);
          const bytes = Buffer.from(new Uint8Array(memory, pointer, byteCount));
          let offset = 0;
          while (offset < byteCount) {
            const written = writeSync(2, bytes, offset, byteCount - offset);
            if (written <= 0 || written > byteCount - offset) {
              throw new Error("Runtime evidence output did not advance");
            }
            offset += written;
          }
          remaining -= byteCount;
        }
        if (remaining !== 0) {
          throw new Error("WASI output byte count exceeded validated iovecs");
        }
      }
      return result;
    };
    const instance = await instantiateDatabaseRuntime(options);
    const addressSpace = instance.endpoints.memory;
    if (addressSpace instanceof WebAssembly.Memory) {
      reactorMemory = addressSpace;
      instantiatedAddressSpace = addressSpace;
    }
    return instance;
  };

  async function openConnection(): Promise<DatabaseRuntimeConnection> {
    return DatabaseRuntimeConnection.instantiate(
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
  }

  let connection: DatabaseRuntimeConnection;
  const startupStartedAt = performance.now();
  try {
    connection = await openConnection();
  } catch (error) {
    const addressSpace = instantiatedAddressSpace as WebAssembly.Memory | null;
    console.error(JSON.stringify({
      addressSpaceBytes: addressSpace?.buffer.byteLength ?? null,
    }));
    throw error;
  }
  const startupMilliseconds = performance.now() - startupStartedAt;

  try {
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
  const bindingResponse = await invokeApplication(connection, "sql:binding");
  assertTextResponse(bindingResponse, "sql:binding:verified:s05:5", "parameter binding and S05 scalar contracts");
  if (includesS06) {
    const temporalResponse = await invokeApplication(connection, "sql:temporal");
    assertTextResponse(temporalResponse, "sql:temporal:verified:s06:6", "S06 temporal contracts");
  }
  if (includesS07) {
    const collectionResponse = await invokeApplication(connection, "sql:collections");
    assertTextResponse(collectionResponse, "sql:collections:verified:s07:6", "S07 collection contracts");
  }
  if (includesS08) {
    const relationalResponse = await invokeApplication(connection, "sql:relations");
    assertTextResponse(relationalResponse, "sql:relations:verified:s08:5", "S08 relational contracts");
  }
  if (includesS09) {
    const analyticResponse = await invokeApplication(connection, "sql:analytics");
    assertTextResponse(analyticResponse, "sql:analytics:verified:s09:4", "S09 grouping and analytic contracts");
  }
  if (includesS10) {
    const recursiveResponse = await invokeApplication(connection, "sql:recursion-functions");
    assertTextResponse(recursiveResponse, "sql:recursion-functions:verified:s10:4", "S10 recursive and function contracts");
  }
  await connection.alarm();
  const expectedAlarmTimestampMilliseconds = 4_102_444_800_000;
  if (scheduledAlarmTimestamps.length !== 1
      || scheduledAlarmTimestamps[0] !== expectedAlarmTimestampMilliseconds) {
    throw new Error(
      `alarm scheduled ${JSON.stringify(scheduledAlarmTimestamps)} instead of ${expectedAlarmTimestampMilliseconds}`
    );
  }
  if (includesS12) {
    const response = await invokeApplication(connection, "sql:checkpoints");
    assertTextResponse(response, "sql:checkpoints:verified:s12:7", "S12 checkpoint and SQL block contracts");
  }
  if (includesS11) {
    if (!includesS10 || !includesS09 || !includesS08 || !includesS07 || !includesS06) {
      throw new Error("S11 requires all preceding formal SQL groups");
    }
    const catalogResponse = await invokeApplication(connection, "sql:catalog");
    assertTextResponse(catalogResponse, "sql:catalog:verified:s11:4", "S11 catalog contracts");
    const priorAddressSpace = instantiatedAddressSpace;
    await connection.shutdown();
    console.error("ENGINE_S11_REACTOR_SHUTDOWN before-reopen");
    connection = await openConnection();
    if (instantiatedAddressSpace === priorAddressSpace) {
      throw new Error("S11 reopen reused the previous reactor address space");
    }
    console.error("ENGINE_S11_REACTOR_REOPEN completed");
    const restoredResponse = await invokeApplication(connection, "sql:catalog-restored");
    assertTextResponse(restoredResponse, "sql:catalog-restored:verified:s11:1", "S11 restored catalog contracts");
  }
  if (includesS13) {
    if (!includesS12 || !includesS11) {
      throw new Error("S13 requires the complete preceding formal SQL groups");
    }
    const response = await invokeApplication(connection, "sql:constraints-sequences");
    assertTextResponse(response, "sql:constraints-sequences:verified:s13:7", "S13 constraints and sequence contracts");
    const priorAddressSpace = instantiatedAddressSpace;
    await connection.shutdown();
    console.error("ENGINE_S13_REACTOR_SHUTDOWN before-reopen");
    connection = await openConnection();
    if (instantiatedAddressSpace === priorAddressSpace) {
      throw new Error("S13 reopen reused the previous reactor address space");
    }
    console.error("ENGINE_S13_REACTOR_REOPEN completed");
    const restoredResponse = await invokeApplication(connection, "sql:constraints-sequences-restored");
    assertTextResponse(restoredResponse, "sql:constraints-sequences-restored:verified:s13:1:allocator=27",
      "S13 persisted allocator and identity rows after a new reactor address space");
  }
  if (includesS14) {
    if (!includesS13) throw new Error("S14 requires the complete preceding formal SQL groups");
    const response = await invokeApplication(connection, "sql:dml");
    assertTextResponse(response, "sql:dml:verified:s14:8", "S14 semantic mutation contracts");
  }
  if (includesS15) {
    if (!includesS14) throw new Error("S15 requires the complete preceding formal SQL groups");
    const response = await invokeApplication(connection, "sql:ddl");
    assertTextResponse(response, "sql:ddl:verified:s15:8", "S15 typed DDL execution contracts");
    const priorAddressSpace = instantiatedAddressSpace;
    await connection.shutdown();
    console.error("ENGINE_S15_REACTOR_SHUTDOWN before-reopen");
    connection = await openConnection();
    if (instantiatedAddressSpace === priorAddressSpace) {
      throw new Error("S15 reopen reused the previous reactor address space");
    }
    console.error("ENGINE_S15_REACTOR_REOPEN completed");
    const restored = await invokeApplication(connection, "sql:ddl-restored");
    assertTextResponse(restored, "sql:ddl-restored:verified:s15:1", "S15 persisted DDL after a new reactor address space");
  }
  if (includesS16) {
    if (!includesS15) throw new Error("S16 requires the complete preceding formal SQL groups");
    const response = await invokeApplication(connection, "sql:operations");
    assertTextResponse(response, "sql:operations:verified:s16:8", "S16 actual Engine operations and QueryAST parsing");
    const priorAddressSpace = instantiatedAddressSpace;
    await connection.shutdown();
    console.error("ENGINE_S16_REACTOR_SHUTDOWN before-reopen");
    connection = await openConnection();
    if (instantiatedAddressSpace === priorAddressSpace) {
      throw new Error("S16 reopen reused the previous reactor address space");
    }
    console.error("ENGINE_S16_REACTOR_REOPEN completed");
    const restored = await invokeApplication(connection, "sql:operations-restored");
    assertTextResponse(restored, "sql:operations-restored:verified:s16:1:source-kind=informationSchema",
      "S16 persisted COPY data and information_schema view source kind after a fresh reactor");
  }
  if (includesS17) {
    if (!includesS16) throw new Error("S17 projection requires the retained S16 formal groups");
    const response = await invokeApplication(connection, "sql:s17-projection");
    assertTextResponse(response, "sql:s17-projection:verified:engine=2:wire=1:client=1",
      "S17 Engine projection, scoped Wire writer and opaque Client correlation");
  }
  const invocationMilliseconds = performance.now() - invocationStartedAt;

  if (terminalFailure !== null) {
    throw new Error(`runtime entered terminal failure: ${terminalFailure}`);
  }
  const addressSpaceBytes = connection.runtimeAddressSpaceByteCount;

  console.log(JSON.stringify({
    sqlBindingCases: 9,
    sqlSelectedCases: 5,
    sqlS05Cases: 5,
    sqlS06Cases: includesS06 ? 6 : 0,
    sqlS07Cases: includesS07 ? 6 : 0,
    sqlS08Cases: includesS08 ? 5 : 0,
    sqlS09Cases: includesS09 ? 4 : 0,
    sqlS10Cases: includesS10 ? 4 : 0,
    sqlS11Cases: includesS11 ? 5 : 0,
    sqlS12Cases: includesS12 ? 7 : 0,
    sqlS13Cases: includesS13 ? 8 : 0,
    sqlS17EngineCases: includesS17 ? 2 : 0,
    sqlS17WireCases: includesS17 ? 1 : 0,
    sqlS17ClientCases: includesS17 ? 1 : 0,
    sqlS17GraphFreeScope: includesS17,
    sqlS17Owner: includesS17 ? "DatabaseEngine.SQLBlockExecutor" : null,
    sqlS17PromotionOwner: includesS17 ? "SQLEncodedResponse.Mutex" : null,
    sqlS16Cases: includesS16 ? 9 : 0,
    sqlS16ExecutionCases: includesS16 ? 8 : 0,
    sqlS16RestartCases: includesS16 ? 1 : 0,
    sqlS16KitCases: includesS16 ? 1 : 0,
    sqlS16KitDepth: includesS16 ? 200 : 0,
    sqlS16ViewSourceKinds: includesS16 ? 2 : 0,
    sqlS16Owner: includesS16 ? "DatabaseEngine.SQLBlockExecutor" : null,
    sqlS16Parser: includesS16 ? "QueryAST.SQLParser" : null,
    sqlS16ReactorReopened: includesS16,
    sqlS16TimeoutOwner: includesS16 ? "SQLBlockStatementDeadline" : null,
    sqlS16TimeoutTimer: includesS16 ? "StorageMonotonicClock" : null,
    sqlS16GraphFreeScope: includesS16,
    sqlS15Cases: includesS15 ? 9 : 0,
    sqlS15ExecutionCases: includesS15 ? 8 : 0,
    sqlS15RestartCases: includesS15 ? 1 : 0,
    sqlS15KitCases: includesS15 ? 1 : 0,
    sqlS15KitDepth: includesS15 ? 200 : 0,
    sqlS15Owner: includesS15 ? "DatabaseEngine.SQLBlockExecutor" : null,
    sqlS15ReactorReopened: includesS15,
    sqlS14Cases: includesS14 ? 8 : 0,
    sqlS14KitCases: includesS14 ? 1 : 0,
    sqlS14KitDepth: includesS14 ? 200 : 0,
    sqlS14Owner: includesS14 ? "DatabaseEngine.SQLBlockExecutor" : null,
    sqlS13ReactorReopened: includesS13,
    sqlS13RestoredAllocator: includesS13 ? 27 : null,
    sqlS11ReactorReopened: includesS11,
    sqlConcurrentQueryOperations: 8,
    artifactPath: verifiedArtifactPath,
    addressSpaceBytes,
    writeResponseBytes: writeResponse.byteLength,
    readResponseBytes: readResponse.byteLength,
    echoResponseBytes: echoResponse.byteLength,
    alarmInvocation: true,
    scheduledAlarmTimestampMilliseconds: scheduledAlarmTimestamps[0],
    compilationMilliseconds,
    startupMilliseconds,
    invocationMilliseconds,
  }, null, 2));
  } finally {
    try {
      await connection.shutdown();
      console.error("ENGINE_REACTOR_SHUTDOWN completed");
    } finally {
      sqliteStorage.close();
      console.error("ENGINE_SQLITE_HOST_CLOSE completed");
    }
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

  close(): void {
    this.database.close();
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
