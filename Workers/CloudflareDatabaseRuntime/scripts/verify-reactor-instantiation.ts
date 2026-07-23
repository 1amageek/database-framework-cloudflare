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
        ensureWakeUpNoLaterThan: async () => {},
      },
      captureRuntimeAddressSpace,
      new DatabaseRuntimeConnectionLimits({
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

  const capabilitiesRequestID = 0x0102_0304_0506_0708n;
  const capabilitiesOperation = 0x0101;
  const capabilitiesRequest = makeEmptyRequest(
    capabilitiesOperation,
    capabilitiesRequestID
  );
  const invocationStartedAt = performance.now();
  const capabilitiesResponse = await connection.execute(capabilitiesRequest);
  verifySuccessResponse(
    capabilitiesResponse,
    capabilitiesRequestID,
    capabilitiesOperation
  );

  const schemaRequestID = 0x1112_1314_1516_1718n;
  const schemaOperation = 0x0102;
  const schemaResponse = await connection.execute(
    makeEmptyRequest(schemaOperation, schemaRequestID)
  );
  verifySuccessResponse(schemaResponse, schemaRequestID, schemaOperation);
  verifyPayloadContains(schemaResponse, "RuntimeVerificationRecord");
  const invocationMilliseconds = performance.now() - invocationStartedAt;
  if (terminalFailure !== null) {
    throw new Error(`runtime entered terminal failure: ${terminalFailure}`);
  }
  const addressSpaceBytes = connection.runtimeAddressSpaceByteCount;
  connection.shutdown();

  console.log(JSON.stringify({
    artifactPath: verifiedArtifactPath,
    addressSpaceBytes,
    capabilitiesResponseBytes: capabilitiesResponse.byteLength,
    schemaResponseBytes: schemaResponse.byteLength,
    compilationMilliseconds,
    startupMilliseconds,
    invocationMilliseconds,
  }, null, 2));
}

function makeEmptyRequest(
  operation: number,
  requestID: bigint
): Uint8Array {
  const request = new Uint8Array(23);
  request.set([0x44, 0x42, 0x57, 0x52], 0);
  const bytes = new DataView(request.buffer);
  bytes.setUint16(4, 1, true);
  bytes.setUint8(6, 1);
  bytes.setBigUint64(7, requestID, true);
  bytes.setUint16(15, operation, true);
  bytes.setUint8(17, 0);
  bytes.setUint8(18, 0);
  bytes.setUint32(19, 0, true);
  return request;
}

function verifySuccessResponse(
  response: Uint8Array,
  requestID: bigint,
  operation: number
): void {
  if (response.byteLength < 22) {
    throw new Error("runtime response is shorter than the wire header");
  }
  const bytes = new DataView(
    response.buffer,
    response.byteOffset,
    response.byteLength
  );
  const expectedMagic = [0x44, 0x42, 0x57, 0x52];
  for (let index = 0; index < expectedMagic.length; index += 1) {
    if (bytes.getUint8(index) !== expectedMagic[index]) {
      throw new Error("runtime response has invalid DatabaseWire magic");
    }
  }
  if (bytes.getUint16(4, true) !== 1
      || bytes.getUint8(6) !== 2
      || bytes.getBigUint64(7, true) !== requestID
      || bytes.getUint16(15, true) !== operation
      || bytes.getUint8(17) !== 1) {
    throw new Error("runtime response has an invalid typed wire header");
  }
  const payloadByteCount = bytes.getUint32(18, true);
  if (payloadByteCount === 0 || payloadByteCount + 22 !== response.byteLength) {
    throw new Error("runtime response payload length is invalid");
  }
}

function verifyPayloadContains(
  response: Uint8Array,
  expectedText: string
): void {
  const expected = new TextEncoder().encode(expectedText);
  const payload = response.subarray(22);
  for (
    let start = 0;
    start + expected.byteLength <= payload.byteLength;
    start += 1
  ) {
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
  throw new Error(`runtime response does not contain ${expectedText}`);
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
