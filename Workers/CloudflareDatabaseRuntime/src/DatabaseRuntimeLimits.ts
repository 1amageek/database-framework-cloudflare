import { DatabaseRequestStreamChunkLimitError } from "./DatabaseRequestStreamChunkLimitError";

export { DatabaseRequestStreamChunkLimitError };

export const databaseWireMaximumFrameBytes = 16 * 1024 * 1024;
export const databaseMaximumQueuedRequestBytes = 64 * 1024 * 1024;
export const databaseMaximumPendingRequests = 1024;
export const databaseMaximumInvocationTimeoutMilliseconds = 30_000;
export const databaseMaximumRequestStreamChunks = 65_536;
export const defaultDatabaseMaxRequestBytes = 4 * 1024 * 1024;
export const defaultDatabaseMaxResponseBytes = 4 * 1024 * 1024;
export const defaultDatabaseMaxQueuedRequestBytes = 16 * 1024 * 1024;
export const defaultDatabaseMaxPendingRequests = 64;
export const defaultDatabaseInvocationTimeoutMilliseconds = 30_000;
export const defaultDatabaseMaxRequestStreamChunks = 1_024;

export type DatabaseRuntimeLimitEnvironment = {
  DATABASE_MAX_REQUEST_BYTES?: string | number | null;
  DATABASE_MAX_RESPONSE_BYTES?: string | number | null;
  DATABASE_MAX_QUEUED_REQUEST_BYTES?: string | number | null;
  DATABASE_MAX_PENDING_REQUESTS?: string | number | null;
  DATABASE_INVOCATION_TIMEOUT_MILLISECONDS?: string | number | null;
};

export class DatabasePayloadTooLargeError extends Error {
  readonly limit: number;

  constructor(limit: number) {
    super(`DatabaseWire request exceeds ${limit} bytes`);
    this.name = "DatabasePayloadTooLargeError";
    this.limit = limit;
  }
}

export class DatabaseInvalidContentLengthError extends Error {
  constructor() {
    super("Invalid Content-Length");
    this.name = "DatabaseInvalidContentLengthError";
  }
}

export class DatabaseRuntimeLimitConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DatabaseRuntimeLimitConfigurationError";
  }
}

export function databaseMaxRequestBytes(
  env: DatabaseRuntimeLimitEnvironment | null | undefined
): number {
  return configuredFrameLimit(
    env?.DATABASE_MAX_REQUEST_BYTES,
    "DATABASE_MAX_REQUEST_BYTES",
    defaultDatabaseMaxRequestBytes
  );
}

export function databaseMaxResponseBytes(
  env: DatabaseRuntimeLimitEnvironment | null | undefined
): number {
  return configuredFrameLimit(
    env?.DATABASE_MAX_RESPONSE_BYTES,
    "DATABASE_MAX_RESPONSE_BYTES",
    defaultDatabaseMaxResponseBytes
  );
}

export function databaseMaxQueuedRequestBytes(
  env: DatabaseRuntimeLimitEnvironment | null | undefined
): number {
  return configuredIntegerLimit(
    env?.DATABASE_MAX_QUEUED_REQUEST_BYTES,
    "DATABASE_MAX_QUEUED_REQUEST_BYTES",
    defaultDatabaseMaxQueuedRequestBytes,
    databaseMaximumQueuedRequestBytes
  );
}

export function databaseMaxPendingRequests(
  env: DatabaseRuntimeLimitEnvironment | null | undefined
): number {
  return configuredIntegerLimit(
    env?.DATABASE_MAX_PENDING_REQUESTS,
    "DATABASE_MAX_PENDING_REQUESTS",
    defaultDatabaseMaxPendingRequests,
    databaseMaximumPendingRequests
  );
}

export function databaseInvocationTimeoutMilliseconds(
  env: DatabaseRuntimeLimitEnvironment | null | undefined
): number {
  return configuredIntegerLimit(
    env?.DATABASE_INVOCATION_TIMEOUT_MILLISECONDS,
    "DATABASE_INVOCATION_TIMEOUT_MILLISECONDS",
    defaultDatabaseInvocationTimeoutMilliseconds,
    databaseMaximumInvocationTimeoutMilliseconds
  );
}

export function rejectOversizedContentLength(
  request: Request,
  limit: number
): Response | null {
  const contentLength = parseContentLength(request);
  if (contentLength === null) {
    return null;
  }
  if (contentLength instanceof DatabaseInvalidContentLengthError) {
    return invalidContentLengthResponse();
  }
  return contentLength > limit ? payloadTooLargeResponse(limit) : null;
}

export async function readBoundedRequestBytes(
  request: Request,
  limit: number,
  maximumChunkCount: number = defaultDatabaseMaxRequestStreamChunks
): Promise<Uint8Array> {
  const validatedMaximumChunkCount = configuredIntegerLimit(
    maximumChunkCount,
    "maximumChunkCount",
    defaultDatabaseMaxRequestStreamChunks,
    databaseMaximumRequestStreamChunks
  );
  const contentLength = parseContentLength(request);
  if (contentLength instanceof DatabaseInvalidContentLengthError) {
    throw contentLength;
  }
  if (contentLength !== null && contentLength > limit) {
    throw new DatabasePayloadTooLargeError(limit);
  }
  if (request.body === null) {
    return new Uint8Array();
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let chunkCount = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      if (!(value instanceof Uint8Array)) {
        throw new TypeError("DatabaseWire request body chunk is not binary");
      }
      chunkCount += 1;
      if (chunkCount > validatedMaximumChunkCount) {
        throw new DatabaseRequestStreamChunkLimitError(
          validatedMaximumChunkCount
        );
      }
      const chunk = value;
      total += chunk.byteLength;
      if (!Number.isSafeInteger(total) || total > limit) {
        throw new DatabasePayloadTooLargeError(limit);
      }
      chunks.push(chunk);
    }
  } catch (error) {
    await cancelReader(reader);
    throw error;
  } finally {
    reader.releaseLock();
  }

  if (chunks.length === 1) {
    return chunks[0]!;
  }

  // DatabaseWire execution requires one contiguous frame. Non-contiguous
  // stream chunks therefore need exactly one consolidation copy.
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export function payloadTooLargeResponse(limit: number): Response {
  return new Response(`DatabaseWire request exceeds ${limit} bytes`, {
    status: 413,
  });
}

export function invalidContentLengthResponse(): Response {
  return new Response("Invalid Content-Length", { status: 400 });
}

export function hasDatabaseWireContentType(request: Request): boolean {
  const value = request.headers.get("content-type");
  if (value === null) {
    return false;
  }
  return value.split(";", 1)[0]?.trim().toLowerCase()
    === "application/octet-stream";
}

function configuredFrameLimit(
  configured: string | number | null | undefined,
  field: string,
  defaultValue: number
): number {
  return configuredIntegerLimit(
    configured,
    field,
    defaultValue,
    databaseWireMaximumFrameBytes
  );
}

function configuredIntegerLimit(
  configured: string | number | null | undefined,
  field: string,
  defaultValue: number,
  maximumValue: number
): number {
  if (configured === undefined || configured === null || configured === "") {
    return defaultValue;
  }
  const value = Number(configured);
  if (!Number.isInteger(value)
      || value <= 0
      || value > maximumValue) {
    throw new DatabaseRuntimeLimitConfigurationError(
      `${field} must be an integer from 1 through ${maximumValue}`
    );
  }
  return value;
}

function parseContentLength(
  request: Request
): number | DatabaseInvalidContentLengthError | null {
  const header = request.headers.get("content-length");
  if (header === null) {
    return null;
  }
  if (!/^\d+$/.test(header)) {
    return new DatabaseInvalidContentLengthError();
  }
  const value = Number(header);
  if (!Number.isSafeInteger(value)) {
    return new DatabaseInvalidContentLengthError();
  }
  return value;
}

async function cancelReader(
  reader: ReadableStreamDefaultReader<Uint8Array>
): Promise<void> {
  try {
    await reader.cancel();
  } catch {
    // The payload limit error remains authoritative if cancellation fails.
  }
}
