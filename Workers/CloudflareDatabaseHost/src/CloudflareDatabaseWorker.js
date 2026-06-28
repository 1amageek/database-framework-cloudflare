import wasmModule from "./CloudflareDatabaseRuntime.wasm";
import {
  CloudflareDatabaseHost as BaseCloudflareDatabaseHost,
} from "./CloudflareDatabaseHost.js";
import {
  maxRequestBytes,
  rejectOversizedContentLength,
} from "./DatabaseHostLimits.js";
import { nameForScope, scopeFromRequest } from "./DatabaseScope.js";
import { RequestAuthorizer } from "./RequestAuthorizer.js";

const durableObjectBindingName = "DATABASE_DURABLE_OBJECT";

export class CloudflareDatabaseHost extends BaseCloudflareDatabaseHost {
  constructor(ctx, env) {
    super(ctx, Object.assign({}, env, {
      DATABASE_WASM: env?.DATABASE_WASM ?? wasmModule,
    }));
  }
}

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const authorization = await new RequestAuthorizer(env?.DATABASE_ACCESS_TOKEN).authorize(request);
    if (!authorization.allowed) {
      return authorization.response;
    }

    const oversizedResponse = rejectOversizedContentLength(request, maxRequestBytes(env));
    if (oversizedResponse !== null) {
      return oversizedResponse;
    }

    const namespace = env?.[durableObjectBindingName];
    if (namespace === undefined || namespace === null) {
      return new Response("Cloudflare Durable Object binding is not configured", { status: 503 });
    }

    let stub;
    try {
      const durableObjectName = nameForScope(scopeFromRequest(request));
      const id = namespace.idFromName(durableObjectName);
      stub = namespace.get(id);
    } catch (error) {
      return new Response(errorMessage(error), { status: 400 });
    }

    return stub.fetch(request);
  },
};

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
