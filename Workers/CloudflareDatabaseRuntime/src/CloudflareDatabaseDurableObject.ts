import { DurableObject } from "cloudflare:workers";
import { StorageKitDurableObjectHost } from "@storage-kit/cloudflare-durable-object-storage-host";
import {
  databaseMaxPendingRequests,
  databaseMaxQueuedRequestBytes,
  databaseMaxRequestBytes,
  databaseMaxResponseBytes,
  databaseInvocationTimeoutMilliseconds,
  type DatabaseRuntimeLimitEnvironment,
} from "./DatabaseRuntimeLimits";
import { DatabaseRequestQueue } from "./DatabaseRequestQueue";
import { DurableObjectDatabaseAlarmScheduler } from "./DurableObjectDatabaseAlarmScheduler";
import type {
  DatabaseRuntimeInstantiator,
  DatabaseRuntimeProgram,
} from "./DatabaseRuntimeTypes";
import { instantiateDatabaseRuntime } from "./instantiateDatabaseRuntime";
import { DatabaseRuntimeConnection } from "./DatabaseRuntimeConnection";
import { DatabaseRuntimeConnectionLimits } from "./DatabaseRuntimeConnectionLimits";
import { databaseCompletionStatus } from "./DatabaseCompletionStatus";
import { encodeDatabaseExecutionFailure } from "./DatabaseExecutionFailure";
import { DatabaseExecutionInputError } from "./DatabaseExecutionInputError";
import { DatabaseRuntimeInvocationError } from "./DatabaseRuntimeInvocationError";

export abstract class CloudflareDatabaseDurableObject<
  Environment extends DatabaseRuntimeLimitEnvironment,
> extends DurableObject<Environment> {
  private readonly storageAdapter: StorageKitDurableObjectHost;
  private readonly runtimeProgram: DatabaseRuntimeProgram;
  private readonly instantiateRuntime: DatabaseRuntimeInstantiator;
  private readonly connectionLimits: DatabaseRuntimeConnectionLimits;
  private readonly requestQueue: DatabaseRequestQueue;

  private runtimeConnectionPromise: Promise<DatabaseRuntimeConnection> | null = null;

  protected constructor(
    ctx: DurableObjectState,
    env: Environment,
    runtimeProgram: DatabaseRuntimeProgram,
    instantiateRuntime: DatabaseRuntimeInstantiator = instantiateDatabaseRuntime
  ) {
    super(ctx, env);
    this.storageAdapter = new StorageKitDurableObjectHost(
      this.ctx.storage.sql,
      <Result>(operation: () => Result) =>
        this.ctx.storage.transactionSync(operation)
    );
    this.runtimeProgram = runtimeProgram;
    this.instantiateRuntime = instantiateRuntime;
    this.connectionLimits = new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: databaseMaxRequestBytes(env),
      maximumResponseBytes: databaseMaxResponseBytes(env),
      invocationTimeoutMilliseconds:
        databaseInvocationTimeoutMilliseconds(env),
    });
    this.requestQueue = new DatabaseRequestQueue({
      maximumPendingRequests: databaseMaxPendingRequests(env),
      maximumPendingRequestBytes: databaseMaxQueuedRequestBytes(env),
    });

    this.ctx.blockConcurrencyWhile(async () => {
      try {
        await this.runtimeConnection();
      } catch (error) {
        console.error("Database runtime bootstrap failed", error);
        throw encodeDatabaseExecutionFailure(error);
      }
    });
  }

  /** Consumes the Durable Object RPC-owned request view. */
  async execute(requestBytes: Uint8Array): Promise<Uint8Array> {
    try {
      if (!(requestBytes instanceof Uint8Array)) {
        throw new DatabaseExecutionInputError(
          "Database execute input must be Uint8Array"
        );
      }
      if (requestBytes.byteLength > this.connectionLimits.maximumRequestBytes) {
        throw new DatabaseRuntimeInvocationError(
          databaseCompletionStatus.requestTooLarge,
          "DatabaseWire request exceeds the Durable Object limit",
        );
      }
      return await this.requestQueue.enqueue(requestBytes, async (ownedRequest) => {
        const connection = await this.runtimeConnection();
        const response = await connection.execute(ownedRequest);
        if (response.byteLength > this.connectionLimits.maximumResponseBytes) {
          throw new DatabaseRuntimeInvocationError(
            databaseCompletionStatus.responseTooLarge,
            "DatabaseWire response exceeds the Durable Object limit",
          );
        }
        return response;
      });
    } catch (error) {
      console.error("Database execution failed", error);
      throw encodeDatabaseExecutionFailure(error);
    }
  }

  override async alarm(): Promise<void> {
    return this.requestQueue.enqueue(
      new Uint8Array(),
      async () => {
        const connection = await this.runtimeConnection();
        await connection.alarm();
      }
    );
  }

  private async runtimeConnection(): Promise<DatabaseRuntimeConnection> {
    let promise = this.runtimeConnectionPromise;
    if (promise === null) {
      promise = this.createRuntimeConnection();
      this.runtimeConnectionPromise = promise;
    }
    try {
      return await promise;
    } catch (error) {
      if (this.runtimeConnectionPromise === promise) {
        this.runtimeConnectionPromise = null;
      }
      throw error;
    }
  }

  private async createRuntimeConnection(): Promise<DatabaseRuntimeConnection> {
    this.storageAdapter.migrate();
    return DatabaseRuntimeConnection.instantiate(
      this.runtimeProgram,
      this.storageAdapter,
      new DurableObjectDatabaseAlarmScheduler(this.ctx.storage),
      this.instantiateRuntime,
      this.connectionLimits,
      (reason) => this.ctx.abort(reason)
    );
  }
}
