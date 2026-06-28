import { DurableObject } from "cloudflare:workers";
import { DatabaseStorageHost } from "./DatabaseStorageHost.js";
import { DatabaseWasmBridge } from "./DatabaseWasmBridge.js";
import {
  InvalidContentLengthError,
  maxRequestBytes,
  PayloadTooLargeError,
  invalidContentLengthResponse,
  payloadTooLargeResponse,
  readBoundedRequestBytes,
} from "./DatabaseHostLimits.js";

export class CloudflareDatabaseHost extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.host = new DatabaseStorageHost(
      this.ctx.storage.sql,
      (callback) => this.ctx.storage.transactionSync(callback)
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

  async fetch(request) {
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
    return new Response(responseBytes, {
      headers: {
        "content-type": "application/octet-stream",
      },
    });
  }

  async dispatch(requestBytes) {
    const bridge = await this.bridge();
    return bridge.dispatch(requestBytes);
  }

  bridge() {
    if (this.bridgePromise === null) {
      this.bridgePromise = DatabaseWasmBridge.instantiate(
        this.env.DATABASE_WASM,
        this.host
      );
    }
    return this.bridgePromise;
  }
}
