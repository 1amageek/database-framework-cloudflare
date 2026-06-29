import wasmModule from "./CloudflareDatabaseRuntime.wasm";
import {
  CloudflareDatabaseHost as BaseCloudflareDatabaseHost,
  type CloudflareDatabaseHostEnvironment,
} from "./CloudflareDatabaseHost";
import {
  maxRequestBytes,
  rejectOversizedContentLength,
} from "./DatabaseHostLimits";
import { nameForScope, scopeFromRequest } from "./DatabaseScope";
import { RequestAuthorizer } from "./RequestAuthorizer";

const durableObjectBindingName = "DATABASE_DURABLE_OBJECT";

type CloudflareDatabaseWorkerEnvironment = Env & {
  DATABASE_ACCESS_TOKEN?: string;
  DATABASE_WASM?: WebAssembly.Module;
};

export class CloudflareDatabaseHost extends BaseCloudflareDatabaseHost {
  constructor(ctx: DurableObjectState, env: CloudflareDatabaseWorkerEnvironment) {
    const hostEnvironment: CloudflareDatabaseHostEnvironment = Object.assign({}, env, {
      DATABASE_WASM: env?.DATABASE_WASM ?? wasmModule,
    });
    super(ctx, hostEnvironment);
  }
}

export default {
  async fetch(request: Request, env: CloudflareDatabaseWorkerEnvironment): Promise<Response> {
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const authorization = await new RequestAuthorizer(env.DATABASE_ACCESS_TOKEN).authorize(request);
    if (!authorization.allowed) {
      return authorization.response ?? new Response("Unauthorized", { status: 401 });
    }

    const oversizedResponse = rejectOversizedContentLength(request, maxRequestBytes(env));
    if (oversizedResponse !== null) {
      return oversizedResponse;
    }

    const namespace = env[durableObjectBindingName];
    if (namespace === undefined || namespace === null) {
      return new Response("Cloudflare Durable Object binding is not configured", { status: 503 });
    }

    let stub: DurableObjectStub;
    try {
      const durableObjectName = nameForScope(scopeFromRequest(request));
      const id = namespace.idFromName(durableObjectName);
      stub = namespace.get(id);
    } catch (error) {
      return new Response(errorMessage(error), { status: 400 });
    }

    return stub.fetch(request);
  },
} satisfies ExportedHandler<CloudflareDatabaseWorkerEnvironment>;

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
