import { DurableObject } from "cloudflare:workers";
import { StorageKitDurableObjectHost } from "@storage-kit/cloudflare-durable-object-storage-host";
import {
  databaseAlarmRecoveryDelayMilliseconds,
  databaseMaxPendingRequests,
  databaseMaxQueuedRequestBytes,
  databaseMaxRequestBytes,
  databaseMaxResponseBytes,
  databaseInvocationTimeoutMilliseconds,
  type DatabaseRuntimeLimitEnvironment,
} from "./DatabaseRuntimeLimits";
import { DatabaseRuntimeEntryQueue } from "./DatabaseRuntimeEntryQueue";
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
  private readonly runtimeEntryQueue: DatabaseRuntimeEntryQueue;
  private readonly alarmScheduler: DurableObjectDatabaseAlarmScheduler;
  private readonly alarmRecoveryDelayMilliseconds: number;

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
    const invocationTimeoutMilliseconds =
      databaseInvocationTimeoutMilliseconds(env);
    this.connectionLimits = new DatabaseRuntimeConnectionLimits({
      maximumRequestBytes: databaseMaxRequestBytes(env),
      maximumResponseBytes: databaseMaxResponseBytes(env),
      invocationTimeoutMilliseconds,
    });
    this.runtimeEntryQueue = new DatabaseRuntimeEntryQueue({
      maximumPendingInvocations: databaseMaxPendingRequests(env),
      maximumPendingInvocationBytes: databaseMaxQueuedRequestBytes(env),
    });
    this.alarmScheduler = new DurableObjectDatabaseAlarmScheduler(
      this.ctx.storage
    );
    this.alarmRecoveryDelayMilliseconds =
      databaseAlarmRecoveryDelayMilliseconds(
        env,
        invocationTimeoutMilliseconds
      );

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
      return await this.runtimeEntryQueue.enqueueInvocation(
        requestBytes,
        async (ownedRequest) => {
          const connection = await this.runtimeConnection();
          const response = await connection.execute(ownedRequest);
          if (response.byteLength > this.connectionLimits.maximumResponseBytes) {
            throw new DatabaseRuntimeInvocationError(
              databaseCompletionStatus.responseTooLarge,
              "DatabaseWire response exceeds the Durable Object limit",
            );
          }
          return response;
        }
      );
    } catch (error) {
      console.error("Database execution failed", error);
      throw encodeDatabaseExecutionFailure(error);
    }
  }

  override async alarm(): Promise<void> {
    const recoveryLease = await this.alarmScheduler.prepareAlarmRecovery(
      Date.now() + this.alarmRecoveryDelayMilliseconds
    );
    return this.runtimeEntryQueue.enqueueScheduledWork(
      async () => {
        try {
          this.alarmScheduler.beginAlarmProcessing(recoveryLease);
          const connection = await this.runtimeConnection();
          await connection.alarm();
          await this.alarmScheduler.completeAlarmProcessing(recoveryLease);
        } catch (error) {
          this.alarmScheduler.preserveAlarmRecovery(recoveryLease);
          console.error(
            "Database scheduled work failed; recovery alarm retained",
            error
          );
          throw error;
        }
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
      this.alarmScheduler,
      this.instantiateRuntime,
      this.connectionLimits,
      (reason) => this.ctx.abort(reason)
    );
  }
}
