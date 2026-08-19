import {
  CloudflareDatabaseDurableObject,
  type DatabaseRuntimeLimitEnvironment,
} from "@database-framework-cloudflare/cloudflare-database-runtime";
import databaseRuntimeProgram from "./database.wasm";

type DatabaseEnvironment = CloudflareBindings
  & DatabaseRuntimeLimitEnvironment;

export class {{service.cloudflare.className}}
  extends CloudflareDatabaseDurableObject<DatabaseEnvironment> {
  constructor(state: DurableObjectState, environment: DatabaseEnvironment) {
    super(state, environment, databaseRuntimeProgram);
  }
}

export default {
  fetch(_request: Request, environment: DatabaseEnvironment): Response {
    return Response.json({
      service: environment.DATABASE_ID,
      status: "ok",
      object: environment.DATABASE_OBJECT_NAME,
    });
  },
} satisfies ExportedHandler<DatabaseEnvironment>;
