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
import {
  emptyDatabaseAuthorizationClaims,
  encodeDatabaseAuthenticatedPrincipal,
} from "../src/DatabaseAuthenticatedPrincipal";
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
const requestVectorURL = new URL(
  "../../../Protocol/runtime-verification-requests-v1.json",
  import.meta.url
);
const verificationAuthorization = encodeDatabaseAuthenticatedPrincipal({
  identifier: "runtime-verification",
  roles: ["admin"],
  claims: emptyDatabaseAuthorizationClaims(),
});

function executeDatabaseRequest(
  connection: DatabaseRuntimeConnection,
  requestBytes: Uint8Array
): Promise<Uint8Array> {
  return connection.execute(requestBytes, verificationAuthorization);
}

interface RuntimeVerificationRequests {
  capabilitiesDescribe: number[];
  schemaDescribe: number[];
  baseCreate: number[];
  mutationExecute: number[];
  queryExecute: number[];
  queryAsk: number[];
  vectorMutationExecute: number[];
  vectorIVFRebuild: number[];
  vectorPQRebuild: number[];
  vectorIVFQuery: number[];
  vectorPQQuery: number[];
  vectorFlatQuery: number[];
  vectorDelete: number[];
}

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

  const requests = await loadRuntimeVerificationRequests();
  const invocationStartedAt = performance.now();
  const capabilitiesResponse = await executeVerifiedRequest(
    connection,
    "capabilitiesDescribe",
    requests.capabilitiesDescribe
  );
  const schemaResponse = await executeVerifiedRequest(
    connection,
    "schemaDescribe",
    requests.schemaDescribe
  );
  verifyPayloadContains(schemaResponse, "RuntimeVerificationDocument");
  const baseCreateResponse = await executeVerifiedRequest(
    connection,
    "baseCreate",
    requests.baseCreate
  );
  await connection.alarm();
  const mutationResponse = await executeVerifiedRequest(
    connection,
    "mutationExecute",
    requests.mutationExecute
  );
  const queryResponse = await executeVerifiedRequest(
    connection,
    "queryExecute",
    requests.queryExecute
  );
  verifyPayloadContains(queryResponse, "Cloudflare runtime");
  const graphQueryResponse = await executeVerifiedRequest(
    connection,
    "queryAsk",
    requests.queryAsk
  );
  verifyBooleanResponse(graphQueryResponse, true);
  await executeVerifiedRequest(
    connection,
    "vectorMutationExecute",
    requests.vectorMutationExecute
  );
  await executeVerifiedRequest(
    connection,
    "vectorIVFRebuild",
    requests.vectorIVFRebuild
  );
  await executeVerifiedRequest(
    connection,
    "vectorPQRebuild",
    requests.vectorPQRebuild
  );
  const vectorIVFResponse = await executeVerifiedRequest(
    connection,
    "vectorIVFQuery",
    requests.vectorIVFQuery
  );
  verifyPayloadContains(
    vectorIVFResponse,
    "RuntimeVerificationIVFDocument-exact"
  );
  const vectorPQResponse = await executeVerifiedRequest(
    connection,
    "vectorPQQuery",
    requests.vectorPQQuery
  );
  verifyPayloadContains(
    vectorPQResponse,
    "RuntimeVerificationPQDocument-exact"
  );
  const vectorFlatResponse = await executeVerifiedRequest(
    connection,
    "vectorFlatQuery",
    requests.vectorFlatQuery
  );
  verifyPayloadContains(
    vectorFlatResponse,
    "RuntimeVerificationFlatDocument-exact"
  );
  await executeVerifiedRequest(
    connection,
    "vectorDelete",
    requests.vectorDelete
  );
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
    baseCreateResponseBytes: baseCreateResponse.byteLength,
    mutationResponseBytes: mutationResponse.byteLength,
    queryResponseBytes: queryResponse.byteLength,
    graphQueryResponseBytes: graphQueryResponse.byteLength,
    vectorIVFResponseBytes: vectorIVFResponse.byteLength,
    vectorPQResponseBytes: vectorPQResponse.byteLength,
    vectorFlatResponseBytes: vectorFlatResponse.byteLength,
    compilationMilliseconds,
    startupMilliseconds,
    invocationMilliseconds,
  }, null, 2));
}

async function loadRuntimeVerificationRequests(
): Promise<RuntimeVerificationRequests> {
  const parsed: unknown = JSON.parse(await readFile(requestVectorURL, "utf8"));
  if (!isRuntimeVerificationRequests(parsed)) {
    throw new Error("runtime verification request vector is invalid");
  }
  return parsed;
}

function isRuntimeVerificationRequests(
  value: unknown
): value is RuntimeVerificationRequests {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const vectors = value as Record<string, unknown>;
  const names = [
    "capabilitiesDescribe",
    "schemaDescribe",
    "baseCreate",
    "mutationExecute",
    "queryExecute",
    "queryAsk",
    "vectorMutationExecute",
    "vectorIVFRebuild",
    "vectorPQRebuild",
    "vectorIVFQuery",
    "vectorPQQuery",
    "vectorFlatQuery",
    "vectorDelete",
  ];
  return Object.keys(vectors).length === names.length
    && names.every((name) => isByteArray(vectors[name]));
}

function isByteArray(value: unknown): value is number[] {
  return Array.isArray(value)
    && value.length > 0
    && value.every(
      (byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255
    );
}

async function executeVerifiedRequest(
  connection: DatabaseRuntimeConnection,
  name: string,
  requestBytes: number[]
): Promise<Uint8Array> {
  const request = Uint8Array.from(requestBytes);
  const requestHeader = readRequestHeader(request);
  let response: Uint8Array;
  try {
    response = await executeDatabaseRequest(connection, request);
  } catch (error) {
    throw new Error(`runtime request ${name} failed`, { cause: error });
  }
  verifySuccessResponse(
    response,
    requestHeader.requestID,
    requestHeader.operation
  );
  return response;
}

function readRequestHeader(
  request: Uint8Array
): { requestID: bigint; operation: number } {
  if (request.byteLength < 17) {
    throw new Error("runtime request vector is shorter than the wire header");
  }
  const bytes = new DataView(
    request.buffer,
    request.byteOffset,
    request.byteLength
  );
  return {
    requestID: bytes.getBigUint64(7, true),
    operation: bytes.getUint16(15, true),
  };
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
    const payloadHex = Array.from(response.subarray(22))
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    throw new Error(
      "runtime response has an invalid typed wire header: "
      + `version=${bytes.getUint16(4, true)}, `
      + `kind=${bytes.getUint8(6)}, `
      + `requestID=${bytes.getBigUint64(7, true)}, `
      + `operation=${bytes.getUint16(15, true)}, `
      + `status=${bytes.getUint8(17)}, `
      + `payload=${payloadHex}`
    );
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

function verifyBooleanResponse(
  response: Uint8Array,
  expectedValue: boolean
): void {
  const payload = new DataView(
    response.buffer,
    response.byteOffset + 22,
    response.byteLength - 22
  );
  let offset = 0;
  const requireBytes = (byteCount: number): void => {
    if (offset + byteCount > payload.byteLength) {
      throw new Error("runtime boolean response is truncated");
    }
  };
  requireBytes(4);
  if (payload.getUint8(offset) !== 2) {
    throw new Error("runtime response is not a boolean result");
  }
  offset += 1;
  if (payload.getUint8(offset) !== (expectedValue ? 1 : 0)) {
    throw new Error("runtime boolean response has the wrong value");
  }
  offset += 1;
  if (payload.getUint8(offset) !== 0) {
    throw new Error("Base-local boolean response unexpectedly has provenance");
  }
  offset += 1;
  if (payload.getUint8(offset) !== 0) {
    throw new Error("Base-local boolean response is not transactional");
  }
  offset += 1;
  requireBytes(4);
  const domainByteCount = payload.getUint32(offset, true);
  offset += 4;
  requireBytes(domainByteCount + 9);
  const domain = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(
      payload.buffer,
      payload.byteOffset + offset,
      domainByteCount
    )
  );
  offset += domainByteCount;
  if (domain !== "primary") {
    throw new Error(`runtime boolean response used unexpected domain ${domain}`);
  }
  if (payload.getUint8(offset) !== 0) {
    throw new Error("runtime boolean response did not use a version read point");
  }
  offset += 1;
  payload.getBigUint64(offset, true);
  offset += 8;
  if (offset !== payload.byteLength) {
    throw new Error("runtime boolean response contains trailing bytes");
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
