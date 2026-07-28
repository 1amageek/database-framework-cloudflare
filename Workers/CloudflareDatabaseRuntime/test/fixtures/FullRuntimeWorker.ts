import runtimeProgram from "./CloudflareDatabaseRuntimeVerification.wasm";
import {
  CloudflareDatabaseDurableObject,
  DatabaseInvalidContentLengthError,
  DatabasePayloadTooLargeError,
  databaseMaxRequestBytes,
  hasDatabaseWireContentType,
  invalidContentLengthResponse,
  payloadTooLargeResponse,
  readBoundedRequestBytes,
  rejectOversizedContentLength,
  type DatabaseRuntimeLimitEnvironment,
} from "../../src/index";

interface RuntimeVerificationEnvironment
  extends DatabaseRuntimeLimitEnvironment {
  DATABASE: DurableObjectNamespace<RuntimeVerificationDurableObject>;
}

export class RuntimeVerificationDurableObject
  extends CloudflareDatabaseDurableObject<RuntimeVerificationEnvironment> {
  constructor(
    state: DurableObjectState,
    environment: RuntimeVerificationEnvironment
  ) {
    super(state, environment, runtimeProgram);
  }
}

export default {
  async fetch(
    request: Request,
    environment: RuntimeVerificationEnvironment
  ): Promise<Response> {
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { allow: "POST" },
      });
    }
    if (!hasDatabaseWireContentType(request)) {
      return new Response("DatabaseWire requires application/octet-stream", {
        status: 415,
      });
    }

    const requestLimit = databaseMaxRequestBytes(environment);
    const contentLengthFailure = rejectOversizedContentLength(
      request,
      requestLimit
    );
    if (contentLengthFailure !== null) {
      return contentLengthFailure;
    }

    let requestBytes: Uint8Array;
    try {
      requestBytes = await readBoundedRequestBytes(request, requestLimit);
    } catch (error) {
      if (error instanceof DatabasePayloadTooLargeError) {
        return payloadTooLargeResponse(error.limit);
      }
      if (error instanceof DatabaseInvalidContentLengthError) {
        return invalidContentLengthResponse();
      }
      throw error;
    }

    const identifier = environment.DATABASE.idFromName(
      "runtime-verification"
    );
    const database = environment.DATABASE.get(identifier);
    const responseBytes = await database.execute(requestBytes);
    const responseBuffer = responseBytes.buffer;
    if (!(responseBuffer instanceof ArrayBuffer)
        || responseBytes.byteOffset !== 0
        || responseBytes.byteLength !== responseBuffer.byteLength) {
      throw new TypeError(
        "Durable Object RPC returned a non-owning DatabaseWire response view"
      );
    }
    return new Response(responseBuffer, {
      status: 200,
      headers: {
        "content-type": "application/octet-stream",
        "cache-control": "no-store",
      },
    });
  },
} satisfies ExportedHandler<RuntimeVerificationEnvironment>;
