import { DurableObject } from "cloudflare:workers";
import { DatabaseStorageHost } from "./DatabaseStorageHost";
import { DatabaseWasmBridge } from "./DatabaseWasmBridge";
import {
  InvalidContentLengthError,
  maxRequestBytes,
  PayloadTooLargeError,
  invalidContentLengthResponse,
  payloadTooLargeResponse,
  readBoundedRequestBytes,
} from "./DatabaseHostLimits";

export type CloudflareDatabaseHostEnvironment = Env & {
  DATABASE_WASM: WebAssembly.Module;
};

export class CloudflareDatabaseHost extends DurableObject<CloudflareDatabaseHostEnvironment> {
  private readonly host: DatabaseStorageHost;
  private bridgePromise: Promise<DatabaseWasmBridge> | null;

  constructor(ctx: DurableObjectState, env: CloudflareDatabaseHostEnvironment) {
    super(ctx, env);
    this.host = new DatabaseStorageHost(
      this.ctx.storage.sql,
      <Result>(callback: () => Result) => this.ctx.storage.transactionSync(callback)
    );
    this.bridgePromise = null;
    if (typeof this.ctx.blockConcurrencyWhile === "function") {
      this.ctx.blockConcurrencyWhile(async () => {
        this.host.migrate();
      });
    } else {
      this.host.migrate();
    }
  }

  override async fetch(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    let requestBytes;
    try {
      requestBytes = await readBoundedRequestBytes(request, maxRequestBytes(this.env));
    } catch (error) {
      if (error instanceof PayloadTooLargeError) {
        return payloadTooLargeResponse(error.limit);
      }
      if (error instanceof InvalidContentLengthError) {
        return invalidContentLengthResponse();
      }
      throw error;
    }
    const responseBytes = await this.dispatch(requestBytes);
    const responseBody = responseBytes.buffer.slice(
      responseBytes.byteOffset,
      responseBytes.byteOffset + responseBytes.byteLength
    ) as ArrayBuffer;
    return new Response(
      responseBody,
      {
        headers: {
          "content-type": "application/octet-stream",
        },
      }
    );
  }

  async dispatch(requestBytes: Uint8Array): Promise<Uint8Array> {
    const bridge = await this.bridge();
    return bridge.dispatch(requestBytes);
  }

  bridge(): Promise<DatabaseWasmBridge> {
    if (this.bridgePromise === null) {
      this.bridgePromise = DatabaseWasmBridge.instantiate(
        this.env.DATABASE_WASM,
        this.host
      );
    }
    return this.bridgePromise;
  }
}
