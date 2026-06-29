export const defaultMaxRequestBytes = 4 * 1024 * 1024;

export type RequestLimitEnvironment = {
  DATABASE_MAX_REQUEST_BYTES?: string | number | null;
};

export class PayloadTooLargeError extends Error {
  readonly limit: number;

  constructor(limit: number) {
    super(`Database wire request exceeds ${limit} bytes`);
    this.name = "PayloadTooLargeError";
    this.limit = limit;
  }
}

export class InvalidContentLengthError extends Error {
  constructor() {
    super("Invalid Content-Length");
    this.name = "InvalidContentLengthError";
  }
}

export function maxRequestBytes(env: RequestLimitEnvironment | null | undefined): number {
  const configured = env?.DATABASE_MAX_REQUEST_BYTES;
  if (configured === undefined || configured === null || configured === "") {
    return defaultMaxRequestBytes;
  }
  const value = Number(configured);
  if (!Number.isInteger(value) || value <= 0 || value > 0xffff_ffff) {
    return defaultMaxRequestBytes;
  }
  return value;
}

export function rejectOversizedContentLength(request: Request, limit: number): Response | null {
  const contentLength = parseContentLength(request);
  if (contentLength === null) {
    return null;
  }
  if (contentLength instanceof InvalidContentLengthError) {
    return new Response("Invalid Content-Length", { status: 400 });
  }
  return contentLength > limit ? payloadTooLargeResponse(limit) : null;
}

export async function readBoundedRequestBytes(request: Request, limit: number): Promise<Uint8Array> {
  const contentLength = parseContentLength(request);
  if (contentLength instanceof InvalidContentLengthError) {
    throw contentLength;
  }
  if (contentLength !== null && contentLength > limit) {
    throw new PayloadTooLargeError(limit);
  }
  if (request.body === null) {
    return new Uint8Array();
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      const chunk = value instanceof Uint8Array ? value : new Uint8Array(value);
      total += chunk.byteLength;
      if (total > limit) {
        await cancelReader(reader);
        throw new PayloadTooLargeError(limit);
      }
      chunks.push(chunk);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export function payloadTooLargeResponse(limit: number): Response {
  return new Response(`Database wire request exceeds ${limit} bytes`, { status: 413 });
}

export function invalidContentLengthResponse() {
  return new Response("Invalid Content-Length", { status: 400 });
}

function parseContentLength(request: Request): number | InvalidContentLengthError | null {
  const header = request.headers.get("content-length");
  if (header === null) {
    return null;
  }
  const value = Number(header);
  if (!Number.isInteger(value) || value < 0) {
    return new InvalidContentLengthError();
  }
  return value;
}

async function cancelReader(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<void> {
  try {
    await reader.cancel();
  } catch {
    // The payload limit error is the authoritative failure for this request.
  }
}
